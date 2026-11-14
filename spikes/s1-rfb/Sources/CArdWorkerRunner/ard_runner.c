#include "include/ard_runner.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/acl.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

struct ard_cancel { atomic_bool cancelled; };
ard_cancel *ard_cancel_create(void) {
    ard_cancel *c=malloc(sizeof(*c));
    if(c) atomic_init(&c->cancelled,0);
    return c;
}
void ard_cancel_set(ard_cancel *c) { if(c) atomic_store_explicit(&c->cancelled,1,memory_order_relaxed); }
void ard_cancel_destroy(ard_cancel *c) { free(c); }
static int cancelled(const ard_cancel *c) { return c && atomic_load_explicit(&c->cancelled,memory_order_relaxed); }
static uint64_t now_ns(void) {
    struct timespec t;
    if(clock_gettime(CLOCK_MONOTONIC,&t)) return UINT64_MAX;
    return (uint64_t)t.tv_sec*1000000000ULL+(uint64_t)t.tv_nsec;
}

static int empty_acl(int fd) {
    errno=0;
    acl_t acl=acl_get_fd_np(fd,ACL_TYPE_EXTENDED);
    if(!acl) return errno==ENOENT;
    acl_flagset_t flags;
    const acl_flag_t known[]={ACL_FLAG_DEFER_INHERIT,ACL_FLAG_NO_INHERIT,
        ACL_ENTRY_INHERITED,ACL_ENTRY_FILE_INHERIT,ACL_ENTRY_DIRECTORY_INHERIT,
        ACL_ENTRY_LIMIT_INHERIT,ACL_ENTRY_ONLY_INHERIT};
    int ok=acl_valid(acl)==0 && acl_get_flagset_np(acl,&flags)==0;
    for(size_t i=0;ok && i<sizeof(known)/sizeof(known[0]);i++)
        ok=acl_get_flag_np(flags,known[i])==0;
    acl_entry_t entry=NULL;
    errno=0;
    /* Darwin: an entry returns 0; empty/end returns -1 with EINVAL. */
    ok=ok && acl_get_entry(acl,ACL_FIRST_ENTRY,&entry)==-1 && errno==EINVAL;
    acl_free(acl);
    return ok;
}

static int caller_owns_reaping(void) {
    struct sigaction action;
    return sigaction(SIGCHLD,NULL,&action)==0 && action.sa_handler==SIG_DFL
        && !(action.sa_flags&SA_NOCLDWAIT);
}

/* Pin the parent directory by descriptor; refuse symlinks and writable-by-others
 * ancestors, except root-owned sticky temporary directories. This protects against
 * other UIDs, not a malicious process controlling this same user's build files. */
static int parent_directory(const char *path, char leaf[NAME_MAX+1]) {
    if(!path || path[0]!='/' || strlen(path)>=PATH_MAX) return -1;
    char copy[PATH_MAX]; memcpy(copy,path,strlen(path)+1);
    int dir=open("/",O_RDONLY|O_DIRECTORY|O_NONBLOCK|O_CLOEXEC);
    char *save=NULL,*part=strtok_r(copy,"/",&save);
    struct stat root;
    if(dir<0 || !part || fstat(dir,&root) || root.st_uid!=0
        || (root.st_mode&(S_IWGRP|S_IWOTH)) || !empty_acl(dir)) {
        if(dir>=0)close(dir); return -1;
    }
    while(part) {
        char *next=strtok_r(NULL,"/",&save);
        if(!strcmp(part,".") || !strcmp(part,"..") || strlen(part)>NAME_MAX) break;
        if(!next) {
            struct stat before,st;
            if(fstatat(dir,part,&before,AT_SYMLINK_NOFOLLOW) || !S_ISREG(before.st_mode)) break;
            /* Never open a FIFO/device in blocking mode before classifying it. */
            int file=openat(dir,part,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);
            int ok=file>=0 && fstat(file,&st)==0 && S_ISREG(st.st_mode)
                && st.st_dev==before.st_dev && st.st_ino==before.st_ino
                && empty_acl(file)
                && (st.st_uid==geteuid() || st.st_uid==0)
                && !(st.st_mode & (S_IWGRP|S_IWOTH|S_ISUID|S_ISGID))
                && (st.st_mode & 0111) && st.st_size>0 && st.st_size<=64*1024*1024;
            if(file>=0)close(file);
            if(ok) { memcpy(leaf,part,strlen(part)+1); return dir; }
            break;
        }
        int child=openat(dir,part,O_RDONLY|O_DIRECTORY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);
        struct stat st;
        int ok=child>=0 && fstat(child,&st)==0 && empty_acl(child) && (st.st_uid==geteuid() || st.st_uid==0)
            && (!(st.st_mode & (S_IWGRP|S_IWOTH)) || (st.st_uid==0 && (st.st_mode&S_ISVTX)));
        close(dir); dir=child;
        if(!ok) break;
        part=next;
    }
    if(dir>=0)close(dir);
    return -1;
}

/* Reserve the exceptional cleanup capability BEFORE creating a child. No allocation
 * or thread creation may fail after a bounded reap has handed off ownership. */
struct reaper { pthread_mutex_t mutex; pthread_cond_t ready; int released; pid_t pid; };
static void *reap_later(void *value) {
    struct reaper *r=value;
    pthread_mutex_lock(&r->mutex);
    while(!r->released) pthread_cond_wait(&r->ready,&r->mutex);
    pid_t pid=r->pid;
    pthread_mutex_unlock(&r->mutex);
    if(pid>0) while(waitpid(pid,NULL,0)<0 && errno==EINTR) {}
    pthread_cond_destroy(&r->ready); pthread_mutex_destroy(&r->mutex); free(r);
    return NULL;
}
static struct reaper *reserve_reaper(void) {
    struct reaper *r=calloc(1,sizeof(*r));
    if(!r)return NULL;
    if(pthread_mutex_init(&r->mutex,NULL)) { free(r); return NULL; }
    if(pthread_cond_init(&r->ready,NULL)) { pthread_mutex_destroy(&r->mutex); free(r); return NULL; }
    pthread_attr_t attr;
    if(pthread_attr_init(&attr)) goto fail;
    if(pthread_attr_setdetachstate(&attr,PTHREAD_CREATE_DETACHED)) { pthread_attr_destroy(&attr); goto fail; }
    pthread_t thread;
    int status=pthread_create(&thread,&attr,reap_later,r);
    pthread_attr_destroy(&attr);
    if(status)goto fail;
    return r;
fail:
    pthread_cond_destroy(&r->ready); pthread_mutex_destroy(&r->mutex); free(r); return NULL;
}
static void release_reaper(struct reaper *r,pid_t pid) {
    pthread_mutex_lock(&r->mutex);
    r->pid=pid; r->released=1;
    pthread_cond_signal(&r->ready);
    pthread_mutex_unlock(&r->mutex);
}
static int stop_and_reap(pid_t pid,struct reaper *reserved,int *handed_off) {
    /* pid has NOT been reaped: its identifier cannot be reused here. The child
     * was placed in its own process group before exec. Our worker never forks. */
    siginfo_t info; memset(&info,0,sizeof(info));
    if(!caller_owns_reaping()) { release_reaper(reserved,pid); *handed_off=1; return 0; }
    int observed;
    do { observed=waitid(P_PID,(id_t)pid,&info,WEXITED|WNOHANG|WNOWAIT); } while(observed<0 && errno==EINTR);
    if(observed<0) {
        /* ECHILD loses ownership: never signal a possibly reused PID. For any
         * other unexpected error, retain a waiting owner without signalling. */
        if(errno!=ECHILD) { release_reaper(reserved,pid); *handed_off=1; }
        return 0;
    }
    (void)kill(-pid,SIGKILL);
    (void)kill(pid,SIGKILL);
    uint64_t until=now_ns()+1000000000ULL;
    for(;;) {
        pid_t result=waitpid(pid,NULL,WNOHANG);
        if(result==pid) return 1;
        if(result<0 && errno==EINTR) continue;
        if(result<0) {
            if(errno!=ECHILD) { release_reaper(reserved,pid); *handed_off=1; }
            return 0;
        }
        if(now_ns()>=until) break;
        struct timespec pause={0,1000000}; nanosleep(&pause,NULL);
    }
    release_reaper(reserved,pid); *handed_off=1;
    return 0;
}

int ard_run_worker(const char *path, const uint8_t *request, size_t request_len,
    uint8_t *output, size_t *output_len, unsigned timeout_ms, const ard_cancel *cancel) {
    int result=ARD_RUN_IO, sockets[2]={-1,-1}, dir=-1, nullfd=-1;
    pid_t pid=-1;
    size_t sent=0, received=0;
    int eof=0, write_closed=0, exited=0;
    char leaf[NAME_MAX+1];
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attrs;
    int have_actions=0,have_attrs=0;
    struct reaper *reserved=NULL;
    int handed_off=0;
    if(!output || !output_len) return ARD_RUN_IO;
    memset(output,0,648); *output_len=0;
    if(!request || request_len==0 || request_len>1162 || timeout_ms==0 || timeout_ms>10000) return ARD_RUN_IO;
    uint64_t start=now_ns(), deadline=start+(uint64_t)timeout_ms*1000000ULL;
    if(start==UINT64_MAX) return ARD_RUN_IO;
    if(cancelled(cancel)) return ARD_RUN_CANCELLED;
    if(!caller_owns_reaping()) return ARD_RUN_CALLER;
    if((dir=parent_directory(path,leaf))<0) return ARD_RUN_EXECUTABLE;
    reserved=reserve_reaper();
    if(!reserved)goto done;
    if(socketpair(AF_UNIX,SOCK_STREAM,0,sockets)) goto done;
    for(int i=0;i<2;i++) if(fcntl(sockets[i],F_SETFD,FD_CLOEXEC)<0) goto done;
    int yes=1;
    if(setsockopt(sockets[0],SOL_SOCKET,SO_NOSIGPIPE,&yes,sizeof(yes))
        || fcntl(sockets[0],F_SETFL,O_NONBLOCK)<0) goto done;
    nullfd=open("/dev/null",O_WRONLY|O_CLOEXEC);
    if(nullfd<0 || posix_spawn_file_actions_init(&actions)) goto done;
    have_actions=1;
    if(posix_spawnattr_init(&attrs)) goto done;
    have_attrs=1;
    sigset_t empty,defaults;
    sigemptyset(&empty); sigfillset(&defaults);
    if(posix_spawn_file_actions_addfchdir(&actions,dir)
        || posix_spawn_file_actions_adddup2(&actions,sockets[1],STDIN_FILENO)
        || posix_spawn_file_actions_adddup2(&actions,sockets[1],STDOUT_FILENO)
        || posix_spawn_file_actions_adddup2(&actions,nullfd,STDERR_FILENO)
        || posix_spawnattr_setflags(&attrs,POSIX_SPAWN_CLOEXEC_DEFAULT|POSIX_SPAWN_SETPGROUP
            |POSIX_SPAWN_SETSIGDEF|POSIX_SPAWN_SETSIGMASK)
        || posix_spawnattr_setpgroup(&attrs,0)
        || posix_spawnattr_setsigdefault(&attrs,&defaults)
        || posix_spawnattr_setsigmask(&attrs,&empty)) goto done;
    if(cancelled(cancel)) { result=ARD_RUN_CANCELLED; goto done; }
    if(now_ns()>=deadline) { result=ARD_RUN_TIMEOUT; goto done; }
    char *argv[]={leaf,"--synthetic-stdio-v1",NULL};
    char *env[]={"PATH=/usr/bin:/bin", "OPENSSL_CONF=/dev/null", NULL};
    if(posix_spawn(&pid,leaf,&actions,&attrs,argv,env)) { pid=-1; result=ARD_RUN_EXECUTABLE; goto done; }
    close(sockets[1]); sockets[1]=-1;
    for(;;) {
        if(cancelled(cancel)) { result=ARD_RUN_CANCELLED; break; }
        uint64_t current=now_ns();
        if(current>=deadline) { result=ARD_RUN_TIMEOUT; break; }
        siginfo_t info; memset(&info,0,sizeof(info));
        if(waitid(P_PID,(id_t)pid,&info,WEXITED|WNOHANG|WNOWAIT)<0) {
            if(errno==EINTR)continue;
            if(errno==ECHILD) { pid=-1; result=ARD_RUN_CALLER; }
            break;
        }
        exited=info.si_pid==pid;
        if(exited && (info.si_code!=CLD_EXITED || info.si_status!=0)) { result=ARD_RUN_EXIT; break; }
        if(eof && exited && write_closed) { result=ARD_RUN_OK; break; }
        struct pollfd fd={sockets[0],(short)((eof?0:POLLIN)|(write_closed?0:POLLOUT)),0};
        uint64_t remaining=(deadline-current+999999ULL)/1000000ULL;
        int wait_ms=remaining<10?(int)remaining:10;
        if(poll(&fd,1,wait_ms)<0) { if(errno==EINTR)continue; break; }
        if(fd.revents&POLLNVAL) break;
        if(!write_closed && (fd.revents&POLLOUT)) {
            ssize_t n=write(sockets[0],request+sent,request_len-sent);
            if(n>0) sent+=(size_t)n;
            else if(n<0 && errno!=EINTR && errno!=EAGAIN) break;
            if(sent==request_len) {
                if(shutdown(sockets[0],SHUT_WR))break;
                write_closed=1;
            }
        }
        if(!eof && (fd.revents&(POLLIN|POLLHUP|POLLERR))) {
            uint8_t scratch[649];
            ssize_t n=read(sockets[0],scratch,sizeof(scratch));
            if(n>0) {
                if((size_t)n>648-received) { result=ARD_RUN_OUTPUT; break; }
                memcpy(output+received,scratch,(size_t)n); received+=(size_t)n;
            } else if(n==0) eof=1;
            else if(errno!=EINTR && errno!=EAGAIN) break;
        }
    }
done:
    if(sockets[0]>=0)close(sockets[0]);
    if(sockets[1]>=0)close(sockets[1]);
    if(dir>=0)close(dir);
    if(nullfd>=0)close(nullfd);
    if(have_actions)posix_spawn_file_actions_destroy(&actions);
    if(have_attrs)posix_spawnattr_destroy(&attrs);
    if(pid>0 && !stop_and_reap(pid,reserved,&handed_off)) result=ARD_RUN_CLEANUP;
    if(reserved && !handed_off)release_reaper(reserved,0);
    if(result==ARD_RUN_OK) *output_len=received;
    else memset(output,0,648);
    return result;
}
