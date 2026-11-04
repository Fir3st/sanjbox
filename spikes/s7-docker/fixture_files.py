#!/usr/bin/env python3
"""Own flat synthetic build fixtures only. Dry-run by default; no runtime calls."""
import argparse
import json
import os
from pathlib import Path
import re
import stat
import sys
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent))
from s7 import STATUS, ZONES, decode, keys, path, require

STATE = 's7-state.json'
PATTERN = re.compile(r'sanjbox-s7-fixtures-[0-9a-f]{32}\Z')


def payloads(zone):
    require(zone in ZONES, 'unknown fixture zone')
    return {'Dockerfile': b'FROM scratch\nCOPY canary.txt /s7-canary.txt\n',
            'canary.txt': ('S7_SYNTHETIC:' + zone + ':build-copy\n').encode(),
            'config.json': b'{}\n'}


def identity(info):
    return {'device': info.st_dev, 'inode': info.st_ino, 'uid': info.st_uid,
            'gid': info.st_gid, 'mode': stat.S_IMODE(info.st_mode)}


def directory(value):
    value = Path(path(str(value)))
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in value.parts[1:]:
            nextfd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = nextfd
            info = os.fstat(fd)
            mode = stat.S_IMODE(info.st_mode)
            require(info.st_uid in (0, os.getuid()) and
                    (mode & 0o022 == 0 or (info.st_uid == 0 and mode & stat.S_ISVTX)),
                    'untrusted fixture ancestor')
        return fd
    except BaseException:
        os.close(fd)
        raise


def binding(value, fd):
    current = directory(value)
    try:
        require(identity(os.fstat(current)) == identity(os.fstat(fd)), 'parent path binding changed')
    finally:
        os.close(current)


def write_all(fd, data):
    while data:
        try:
            count = os.write(fd, data)
        except InterruptedError:
            continue
        require(count > 0, 'short write with no progress')
        data = data[count:]
    os.fsync(fd)


def journal(fd, value):
    raw = (json.dumps(value, sort_keys=True) + '\n').encode()
    os.lseek(fd, 0, os.SEEK_SET)
    write_all(fd, raw)
    os.ftruncate(fd, len(raw))
    os.fsync(fd)


def prepare(parent, zone='t001', apply=False):
    parent = Path(path(str(parent)))
    data = payloads(zone)
    proposal = {'action': 'prepare', 'dry_run': not apply, 'parent': str(parent), 'zone': zone,
                'files': sorted(data), 'original_state': 'new random child; must be absent', 'acceptance_status': STATUS}
    if not apply:
        return proposal
    require(os.getuid() != 0 and os.geteuid() == os.getuid(), 'fixtures require an unprivileged user')
    pfd = directory(parent)
    try:
        name = 'sanjbox-s7-fixtures-' + uuid.uuid4().hex
        binding(parent, pfd)
        os.mkdir(name, 0o700, dir_fd=pfd)
        root = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=pfd)
        try:
            require(stat.S_IMODE(os.fstat(root).st_mode) == 0o700, 'fixture mode must be 0700')
            binding(parent, pfd)
            require(identity(os.stat(name, dir_fd=pfd, follow_symlinks=False)) == identity(os.fstat(root)),
                    'new root binding changed')
            record = {'schema': 'sanjbox.s7-fixtures.v1', 'phase': 'planned', 'before': 'absent',
                      'zone': zone, 'root': identity(os.fstat(root)), 'files': {}}
            state = os.open(STATE, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=root)
            try:
                journal(state, record)
                os.fsync(root)
                for filename, content in data.items():
                    fd = os.open(filename, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=root)
                    try:
                        write_all(fd, content)
                        record['files'][filename] = identity(os.fstat(fd))
                    finally:
                        os.close(fd)
                record['phase'] = 'ready'
                journal(state, record)
                os.fsync(root)
            finally:
                os.close(state)
        finally:
            os.close(root)
        proposal['root'] = str(parent / name)
        return proposal
    finally:
        os.close(pfd)


def checked_file(root, filename, expected=None):
    fd = os.open(filename, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=root)
    try:
        info = os.fstat(fd)
        require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_uid == os.getuid() and
                stat.S_IMODE(info.st_mode) == 0o600 and info.st_size <= 16384, 'changed fixture type/mode/size')
        if expected is not None:
            require(identity(info) == expected, 'changed fixture identity')
        chunks, total = [], 0
        while True:
            try:
                chunk = os.read(fd, min(4096, 16385 - total))
            except InterruptedError:
                continue
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            require(total <= 16384, 'fixture grew during read')
        def fingerprint(st):
            return identity(st), st.st_size, st.st_nlink, st.st_mtime_ns, st.st_ctime_ns
        require(fingerprint(os.fstat(fd)) == fingerprint(info) and
                fingerprint(os.stat(filename, dir_fd=root, follow_symlinks=False)) == fingerprint(info),
                'fixture changed or replaced during read')
        return b''.join(chunks), identity(info)
    finally:
        os.close(fd)


def cleanup(rootpath, apply=False):
    rootpath = Path(path(str(rootpath)))
    require(PATTERN.fullmatch(rootpath.name), 'not a generated S7 fixture name')
    proposal = {'action': 'cleanup', 'dry_run': not apply, 'root': str(rootpath),
                'changes': 'unlink only same recorded fixed files; rmdir own empty root', 'acceptance_status': STATUS}
    if not apply:
        return proposal
    require(os.getuid() != 0 and os.geteuid() == os.getuid(), 'fixtures require an unprivileged user')
    parent = directory(rootpath.parent)
    try:
        try:
            root = os.open(rootpath.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
        except FileNotFoundError:
            return dict(proposal, result='already-absent')
        try:
            info = os.fstat(root)
            require(info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) == 0o700, 'untrusted fixture root')
            raw, state_identity = checked_file(root, STATE)
            record = decode(raw, 16384)
            keys(record, 'schema phase before zone root files')
            require(record['schema'] == 'sanjbox.s7-fixtures.v1' and record['phase'] == 'ready' and
                    record['before'] == 'absent' and record['root'] == identity(info), 'invalid fixture journal/root')
            data = payloads(record['zone'])
            require(type(record['files']) is dict and set(record['files']) == set(data), 'unexpected journal inventory')
            require(set(os.listdir(root)) <= set(data) | {STATE}, 'unknown fixture entries; no cleanup')
            pending = []
            # Validate every file before any removal. Missing own files allow interrupted cleanup retry.
            for filename, content in data.items():
                try:
                    raw, ident = checked_file(root, filename, record['files'][filename])
                except FileNotFoundError:
                    continue
                require(raw == content, 'changed fixture bytes; no cleanup')
                pending.append((filename, ident))
            binding(rootpath.parent, parent)
            require(identity(os.stat(rootpath.name, dir_fd=parent, follow_symlinks=False)) == identity(info),
                    'root binding changed before cleanup')
            for filename, ident in pending:
                require(identity(os.stat(filename, dir_fd=root, follow_symlinks=False)) == ident, 'fixture replaced')
                os.unlink(filename, dir_fd=root)
            require(set(os.listdir(root)) == {STATE}, 'new fixture entries; no recursive cleanup')
            require(identity(os.stat(STATE, dir_fd=root, follow_symlinks=False)) == state_identity, 'journal replaced')
            os.unlink(STATE, dir_fd=root)
            require(identity(os.stat(rootpath.name, dir_fd=parent, follow_symlinks=False)) == identity(info), 'root replaced')
            os.rmdir(rootpath.name, dir_fd=parent)
            os.fsync(parent)
            return dict(proposal, result='removed')
        finally:
            os.close(root)
    finally:
        os.close(parent)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    prep = sub.add_parser('prepare')
    prep.add_argument('--parent', type=Path, required=True)
    prep.add_argument('--zone', choices=ZONES, default='t001')
    clean = sub.add_parser('cleanup')
    clean.add_argument('--root', type=Path, required=True)
    for command in (prep, clean):
        mode = command.add_mutually_exclusive_group()
        mode.add_argument('--apply', action='store_true')
        mode.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    result = prepare(args.parent, args.zone, args.apply) if args.command == 'prepare' else cleanup(args.root, args.apply)
    print(json.dumps(result, indent=2, ensure_ascii=False))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError, UnicodeError) as exc:
        print('S7 fixture action refused: ' + str(exc), file=sys.stderr)
        sys.exit(2)
