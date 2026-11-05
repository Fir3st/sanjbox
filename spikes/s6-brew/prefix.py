#!/usr/bin/env python3
"""User-run empty prefix scaffolding, NOT an APFS/Homebrew installer."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from s6 import PREFIX, absolute, decode, require

JOURNAL = 's6-prefix-state.json'


def metadata(st):
    return {'device': st.st_dev, 'inode': st.st_ino, 'uid': st.st_uid, 'gid': st.st_gid,
            'mode': stat.S_IMODE(st.st_mode)}


def no_acl(path):
    proc = subprocess.run(['/bin/ls', '-lde', str(path)], check=True, capture_output=True, text=True)
    require(not any(re.match(r'^\s*\d+:', line) for line in proc.stdout.splitlines()),
            'ACL requires independent review; refusing: ' + str(path))


def trusted_directory(path, private=False):
    """Walk by descriptors, reject symlinks and any writable/untrusted ancestor."""
    absolute(str(path))
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    current = Path('/')
    try:
        for part in path.parts[1:]:
            nxt = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = nxt
            current /= part
            st = os.fstat(fd)
            require(st.st_uid == 0 and stat.S_IMODE(st.st_mode) & 0o022 == 0,
                    'non-root/writable ancestor: ' + str(current))
            no_acl(current)
        require(not private or stat.S_IMODE(os.fstat(fd).st_mode) == 0o700, 'state directory must be 0700')
        return fd
    except BaseException:
        os.close(fd)
        raise


def journal_write(fd, value):
    raw = (json.dumps(value, sort_keys=True, indent=2) + '\n').encode()
    os.lseek(fd, 0, os.SEEK_SET)
    remaining = memoryview(raw)
    while remaining:
        try:
            written = os.write(fd, remaining)
        except InterruptedError:
            continue
        require(written > 0, 'journal write made no progress; manual review required')
        remaining = remaining[written:]
    os.ftruncate(fd, len(raw))
    os.fsync(fd)


def create_empty(parent_fd, name, uid, gid):
    # Parent is root-owned, not writable by zone; do not touch existing paths.
    os.mkdir(name, mode=0o700, dir_fd=parent_fd)
    fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent_fd)
    try:
        os.fchown(fd, uid, gid)
        os.fchmod(fd, 0o700)
        os.fsync(parent_fd)
        return metadata(os.fstat(fd))
    finally:
        os.close(fd)


def remove_empty(parent_fd, name, expected):
    fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent_fd)
    try:
        current = metadata(os.fstat(fd))
        require(current == expected, 'prefix identity/ownership/mode changed; no cleanup')
        require(current['device'] == os.fstat(parent_fd).st_dev, 'mounted prefix; B3/B4 cleanup required')
        require(os.listdir(fd) == [], 'prefix is not empty; no recursive cleanup')
        require(metadata(os.stat(name, dir_fd=parent_fd, follow_symlinks=False)) == expected,
                'prefix replaced; no cleanup')
        # Any newly inserted entry makes rmdir fail; never unlink content or recurse.
        os.rmdir(name, dir_fd=parent_fd)
        os.fsync(parent_fd)
    finally:
        os.close(fd)


def cleanup_record(parent_fd, name, record, path):
    require(record['phase'] in ('created', 'removed'), 'interrupted preparation; manual review required')
    try:
        os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        record['phase'] = 'removed'
        return
    require(record['phase'] == 'created', 'path recreated after cleanup; refusing')
    no_acl(path)
    remove_empty(parent_fd, name, record['created'])
    record['phase'] = 'removed'


def operation(action, state_dir, uid, gid, apply=False):
    state_dir = Path(absolute(str(state_dir)))
    require(not (str(state_dir) == '/opt' or str(state_dir).startswith('/opt/')),
            'host-owned state must be outside /opt')
    require(type(uid) is int and type(gid) is int and 0 < uid < 2**32 - 1 and 0 < gid < 2**32 - 1, 'non-root UID/GID required')
    proposal = {'action': action, 'dry_run': not apply, 'prefix': PREFIX, 'uid': uid, 'gid': gid,
                'state': str(state_dir / JOURNAL), 'before': 'must be absent for prepare',
                'changes': ['prepare: create only empty t001, mode 0700, specified owner',
                            'cleanup: rmdir only same recorded empty directory; never uninstall brew'],
                'requirements': ['user runs host-side as root', '/opt/snj exists with trusted ancestors, no ACL',
                                 'preexisting private root-owned state directory outside /opt',
                                 'exclusive lab slot; area stopped; B3/B4 mount lifecycle separate']}
    if not apply:
        return proposal
    require(sys.platform == 'darwin' and os.getuid() == 0 and os.geteuid() == 0,
            '--apply is user-only host-root preparation on macOS')
    parent = trusted_directory(Path('/opt/snj'))
    try:
        state = trusted_directory(state_dir, private=True)
        try:
            if action == 'prepare':
                # Refuse even an existing empty prefix, symlink, or mounted volume.
                try:
                    os.stat('t001', dir_fd=parent, follow_symlinks=False)
                except FileNotFoundError:
                    pass
                else:
                    raise ValueError('prefix already exists; provision through B3/B4 or review conflict')
                jf = os.open(JOURNAL, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=state)
                try:
                    fcntl.flock(jf, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    record = {'schema': 'sanjbox.s6-prefix.v1', 'prefix': PREFIX, 'phase': 'planned',
                              'before': None, 'parent': metadata(os.fstat(parent)), 'uid': uid, 'gid': gid}
                    journal_write(jf, record)  # durable original state BEFORE first mutation
                    os.fsync(state)
                    record['created'] = create_empty(parent, 't001', uid, gid)
                    record['phase'] = 'created'
                    journal_write(jf, record)
                finally:
                    os.close(jf)
            else:
                jf = os.open(JOURNAL, os.O_RDWR | os.O_NOFOLLOW, dir_fd=state)
                try:
                    st = os.fstat(jf)
                    require(stat.S_ISREG(st.st_mode) and st.st_uid == 0 and st.st_nlink == 1 and
                            stat.S_IMODE(st.st_mode) == 0o600 and st.st_size < 16384, 'untrusted journal')
                    fcntl.flock(jf, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    no_acl(state_dir / JOURNAL)
                    record = decode(os.read(jf, 16384))
                    require(record['schema'] == 'sanjbox.s6-prefix.v1' and record['prefix'] == PREFIX and
                            record['uid'] == uid and record['gid'] == gid and record['before'] is None and
                            record['parent'] == metadata(os.fstat(parent)), 'journal identity/parent conflict')
                    cleanup_record(parent, 't001', record, Path(PREFIX))
                    journal_write(jf, record)
                finally:
                    os.close(jf)
            proposal['result'] = record
        finally:
            os.close(state)
    finally:
        os.close(parent)
    return proposal


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('action', choices=['prepare', 'cleanup'])
    p.add_argument('--state-dir', required=True, type=Path)
    p.add_argument('--uid', required=True, type=int)
    p.add_argument('--gid', required=True, type=int)
    mode = p.add_mutually_exclusive_group()
    mode.add_argument('--apply', action='store_true')
    mode.add_argument('--dry-run', action='store_true')
    args = p.parse_args()
    print(json.dumps(operation(args.action, args.state_dir, args.uid, args.gid, args.apply), indent=2))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError) as exc:
        print('S6 prefix refused: ' + str(exc), file=sys.stderr)
        sys.exit(2)
