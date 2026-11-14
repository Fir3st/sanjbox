/* Own synthetic adversarial child. Never used by the normal provider. */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <signal.h>
#include <ard_runner.h>
#include <sys/wait.h>
#include <unistd.h>
static void hang(void) { for(;;)pause(); }
int main(int argc, char **argv) {
    uint8_t mode=0;
    if(read(0,&mode,1)!=1)return 1;
    if(mode=='i' || mode=='n') {
        /* Alter SIGCHLD only in this isolated fixture child, never XCTest. */
        struct sigaction action={0};
        action.sa_handler=mode=='i'?SIG_IGN:SIG_DFL;
        action.sa_flags=mode=='n'?SA_NOCLDWAIT:0;
        sigemptyset(&action.sa_mask);
        if(sigaction(SIGCHLD,&action,NULL) || argc<1)return 1;
        uint8_t out[648],request='s'; size_t count=0;
        /* Preflight must refuse before path validation or any child creation. */
        uint8_t code=(uint8_t)ard_run_worker(argv[0],&request,1,out,&count,100,NULL);
        (void)write(1,&code,1); return count==0?0:1;
    }
    if(mode=='A') {
        uint8_t rest[1163]; size_t count=0;
        for(;;) {
            ssize_t n=read(0,rest+count,sizeof(rest)-count);
            if(n<0&&errno==EINTR)continue;
            if(n<0)return 1;
            if(!n)break;
            count+=(size_t)n;
            if(count==sizeof(rest))return 1;
        }
        if(!count)return 1;
        mode=rest[count-1];
    }
    if(mode=='h')hang();
    if(mode=='e')return 9;
    if(mode=='p') { (void)write(1,"x",1); hang(); }
    if(mode=='o') { uint8_t bytes[1000]={0}; (void)write(1,bytes,sizeof(bytes)); return 0; }
    if(mode=='d') {
        pid_t child=fork();
        if(child<0)return 1;
        if(child==0) { close(0); close(1); close(2); hang(); }
        (void)write(1,&child,sizeof(child)); return 0;
    }
    if(mode=='f') {
        uint8_t count=0;
        for(int fd=3;fd<1024;fd++) if(fcntl(fd,F_GETFD)>=0)count++;
        (void)write(1,&count,1); return 0;
    }
    if(mode=='r') { close(1); hang(); }
    if(mode=='c') { close(0); return 0; }
    if(mode=='m') { (void)write(1,"A3R1\0\5\0\0",8); return 0; }
    if(mode=='l') { (void)write(1,"A3R1\0\1\0\1x",9); return 0; }
    if(mode=='t') { (void)write(1,"A3R1\0\0\0\1x",9); return 0; }
    if(mode=='z') { (void)write(1,"A3R1\0\0\0\0",8); return 0; }
    if(mode=='b') { (void)write(1,"B3R1\0\0\0\0",8); return 0; }
    if(mode=='q') { (void)write(1,"A3R1\0\1\0\0",8); return 0; }
    if(mode=='s') {
        char scratch[256];
        while(read(0,scratch,sizeof(scratch))>0){}
        (void)write(1,"ok",2); return 0;
    }
    return 2;
}
