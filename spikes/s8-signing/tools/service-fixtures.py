#!/usr/bin/env python3
"""Own disposable artifacts only. No service launch/registration, keychain or signing lookup."""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import plistlib
import stat
import struct
import subprocess
import sys
import uuid

PACKAGE = Path(__file__).resolve().parents[1]
PREFIX = '/private/tmp/sanjbox-s8-services-'
EVENT_PREFIX = '/private/tmp/sanjbox-s8-event-'
APP = 'S8ServiceFixture.app'
HOST_ID = 'org.sanjbox.s8.fixture.host'
PRODUCTS = ('S8ServiceHost', 'S8LoginItem', 'S8LaunchAgent', 'S8LaunchDaemon')
LIBC = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
LIBC.acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
LIBC.acl_get_fd_np.restype = ctypes.c_void_p
LIBC.acl_get_entry.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_void_p)]
LIBC.acl_free.argtypes = [ctypes.c_void_p]

class Refused(Exception):
    pass

def require(condition, message):
    if not condition:
        raise Refused(message)

def canonical_uuid(value):
    require(str(uuid.UUID(value)).upper() == value, 'canonical uppercase UUID required')
    return value

def no_acl(fd):
    ctypes.set_errno(0)
    acl = LIBC.acl_get_fd_np(fd, 0x100)  # ACL_TYPE_EXTENDED from Apple sys/acl.h
    if not acl:
        require(ctypes.get_errno() == 2, 'cannot establish absence of extended ACL')
        return
    try:
        entry = ctypes.c_void_p()
        ctypes.set_errno(0)
        result = LIBC.acl_get_entry(acl, 0, ctypes.byref(entry))
        require(result == -1 and ctypes.get_errno() == 22, 'extended ACL present/unknown')
    finally:
        LIBC.acl_free(acl)

def scoped_root(value, prefix):
    require(value.startswith(prefix), 'outside own fixed root prefix')
    canonical_uuid(value[len(prefix):])
    require(os.path.realpath(value) == value, 'noncanonical/symlink root')
    fd = os.open(value, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    st = os.fstat(fd)
    try:
        require(st.st_uid == os.geteuid() and stat.S_IMODE(st.st_mode) == 0o700 and st.st_flags == 0,
                'unsafe root owner/mode/flags')
        no_acl(fd)
    except BaseException:
        os.close(fd)
        raise
    return fd

def snapshot(fd, name):
    s = os.stat(name, dir_fd=fd, follow_symlinks=False)
    require(s.st_uid == os.geteuid() and s.st_flags == 0, 'owner/flags conflict: ' + name)
    result = dict(device=s.st_dev, inode=s.st_ino, mode=s.st_mode, uid=s.st_uid, gid=s.st_gid,
                  flags=s.st_flags)
    if stat.S_ISLNK(s.st_mode):
        result['link'] = os.readlink(name, dir_fd=fd)
    elif stat.S_ISREG(s.st_mode) or stat.S_ISDIR(s.st_mode):
        item = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
        try:
            actual = os.fstat(item)
            require((actual.st_dev, actual.st_ino) == (s.st_dev, s.st_ino), 'inode changed')
            no_acl(item)
            require(not s.st_mode & 0o022, 'group/world writable artifact')
            if stat.S_ISREG(s.st_mode):
                require(s.st_nlink == 1 and s.st_size <= 64 * 1024 * 1024, 'link/size conflict')
                h = hashlib.sha256()
                total = 0
                while block := os.read(item, 65536):
                    total += len(block)
                    require(total <= s.st_size, "file grew beyond snapshot bound")
                    h.update(block)
                require(total == s.st_size, "file shrank during snapshot")
                result.update(size=s.st_size, sha256=h.hexdigest())
                end = os.fstat(item)
                require((s.st_size, s.st_mtime_ns, s.st_ctime_ns) == (end.st_size, end.st_mtime_ns, end.st_ctime_ns), 'file changed')
        finally:
            os.close(item)
    else:
        raise Refused('non-file artifact: ' + name)
    return result

def inventory(fd, prefix='', budget=None):
    if budget is None: budget = [20000]
    require(prefix.count('/') <= 16, 'artifact nesting limit')
    result = {}
    names = os.listdir(fd)
    require(len(names) <= 20000, 'excessive artifact entries')
    for name in sorted(names):
        require(name not in ('.', '..') and '/' not in name, 'invalid entry')
        if not prefix and name == 'artifact-manifest.json':
            continue
        budget[0] -= 1
        require(budget[0] >= 0, 'artifact entry limit')
        info = snapshot(fd, name)
        result[prefix + name] = info
        if stat.S_ISDIR(info['mode']):
            child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            try:
                result.update(inventory(child, prefix + name + '/', budget))
            finally:
                os.close(child)
    return result

def write_new(path, data, mode=0o600):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
    try:
        with os.fdopen(fd, 'wb', closefd=False) as output:
            output.write(data)
            output.flush()
            os.fsync(fd)
    finally:
        os.close(fd)

def read_json(fd, name, maximum=4 * 1024 * 1024):
    info = snapshot(fd, name)
    require(stat.S_ISREG(info['mode']) and info['size'] <= maximum, 'invalid JSON file')
    f = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=fd)
    try:
        data = os.read(f, maximum + 1)
        require(hashlib.sha256(data).hexdigest() == info['sha256'], 'JSON changed')
        def pairs(items):
            result = {}
            for key, value in items:
                require(key not in result, 'duplicate JSON key')
                result[key] = value
            return result
        return json.loads(data, object_pairs_hook=pairs)
    finally:
        os.close(f)

def run(args, root, log, timeout=180):
    env = {'PATH': '/usr/bin:/bin', 'LC_ALL': 'C', 'TMPDIR': str(root),
           'CLANG_MODULE_CACHE_PATH': str(root/'clang'), 'SWIFTPM_MODULECACHE_OVERRIDE': str(root/'modules'),
           'SWIFTPM_ENABLE_PLUGINS': '0'}
    with open(log, 'ab') as out:
        completed = subprocess.run(args, env=env, stdin=subprocess.DEVNULL, stdout=out,
                                   stderr=subprocess.STDOUT, timeout=timeout, check=False)
    require(completed.returncode == 0, 'tool failed; inspect own build.log')

def plist(path, value):
    write_new(path, plistlib.dumps(value, sort_keys=True))

def source_hashes():
    files = [PACKAGE/'Package.swift']
    for folder, pattern in [('Sources', '*.swift'), ('Tests', '*.swift'), ('tools', '*.py')]:
        files.extend(sorted((PACKAGE/folder).rglob(pattern)))
    common = PACKAGE.parent/'common'
    files.append(common/'Package.swift')
    files.extend(sorted((common/'Sources').rglob('*.swift')))
    return {os.path.relpath(path, PACKAGE): hashlib.sha256(path.read_bytes()).hexdigest() for path in files}

def build(root):
    sources = source_hashes()
    write_new(root/'source-manifest.json', json.dumps(sources, sort_keys=True).encode())
    run_id = root.name[len('sanjbox-s8-services-'):]
    log = root/'build.log'
    write_new(log, b'')
    args = ['/usr/bin/swift', 'build', '--configuration', 'release', '--build-system', 'native',
            '--package-path', str(PACKAGE), '--scratch-path', str(root/'build'),
            '--cache-path', str(root/'cache'), '--disable-sandbox']
    run(args, root, log)
    binary_dir = root/'build'/'arm64-apple-macosx'/'release'
    app = root/APP
    for directory in ('MacOS', 'Resources', 'Library/LaunchAgents', 'Library/LaunchDaemons',
                      'Library/LoginItems/S8LoginItem.app/Contents/MacOS'):
        (app/'Contents'/directory).mkdir(parents=True, exist_ok=True, mode=0o700)
    base = {'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0',
            'LSMinimumSystemVersion': '15.0', 'S8FixtureSchema': 1, 'S8FixtureRunID': run_id}
    plist(app/'Contents/Info.plist', dict(base, CFBundleIdentifier=HOST_ID,
          CFBundleExecutable='S8ServiceHost', CFBundleName='S8 Service Fixture'))
    login = app/'Contents/Library/LoginItems/S8LoginItem.app'
    plist(login/'Contents/Info.plist', dict(base, CFBundleIdentifier='org.sanjbox.s8.fixture.loginItem',
          CFBundleExecutable='S8LoginItem', CFBundleName='S8 Login Item', LSUIElement=True))
    for product in PRODUCTS:
        dest = login/'Contents/MacOS'/product if product == 'S8LoginItem' else app/'Contents/MacOS'/product
        write_new(dest, (binary_dir/product).read_bytes(), 0o700)
    for kind, target, folder in [('agent', 'S8LaunchAgent', 'LaunchAgents'), ('daemon', 'S8LaunchDaemon', 'LaunchDaemons')]:
        label = 'org.sanjbox.s8.fixture.' + kind
        plist(app/'Contents/Library'/folder/(label+'.plist'),
              {'Label': label, 'BundleProgram': 'Contents/MacOS/'+target, 'RunAtLoad': True, 'ProcessType': 'Background'})
    entitlements = root/'empty-entitlements.plist'
    plist(entitlements, {})
    for target in [app/'Contents/MacOS/S8LaunchAgent', app/'Contents/MacOS/S8LaunchDaemon', login, app]:
        run(['/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none', '--options', 'runtime',
             '--entitlements', str(entitlements), str(target)], root, log, 30)
    require(source_hashes() == sources, 'source changed during build; discard this artifact')
    verify_app(root)
    return run_id

def verify_app(root):
    app = root/APP
    info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
    run_id = canonical_uuid(info['S8FixtureRunID'])
    require(info['CFBundleIdentifier'] == HOST_ID and info['CFBundleExecutable'] == 'S8ServiceHost', 'wrong host layout')
    login = app/'Contents/Library/LoginItems/S8LoginItem.app'
    li = plistlib.loads((login/'Contents/Info.plist').read_bytes())
    require(li['CFBundleIdentifier'] == 'org.sanjbox.s8.fixture.loginItem' and li['S8FixtureRunID'] == run_id, 'login layout/run ID')
    for kind, product, folder in [('agent', 'S8LaunchAgent', 'LaunchAgents'), ('daemon', 'S8LaunchDaemon', 'LaunchDaemons')]:
        label = 'org.sanjbox.s8.fixture.'+kind
        actual = plistlib.loads((app/'Contents/Library'/folder/(label+'.plist')).read_bytes())
        require(actual == {'Label': label, 'BundleProgram': 'Contents/MacOS/'+product, 'RunAtLoad': True,
                           'ProcessType': 'Background'}, 'unexpected launch plist keys/paths')
    hashes = {}
    for product in PRODUCTS:
        target = login/'Contents/MacOS'/product if product == 'S8LoginItem' else app/'Contents/MacOS'/product
        data = target.read_bytes()
        require(len(data) < 64 * 1024 * 1024 and len(data) >= 12, 'invalid executable size')
        require(struct.unpack('<II', data[:8]) == (0xfeedfacf, 0x100000c), 'fixture must be thin arm64 Mach-O')
        hashes[product] = hashlib.sha256(data).hexdigest()
    checks = []
    for target in [app, login, app/'Contents/MacOS/S8LaunchAgent', app/'Contents/MacOS/S8LaunchDaemon']:
        env = {'PATH': '/usr/bin:/bin', 'LC_ALL': 'C'}
        subprocess.run(['/usr/bin/codesign', '--verify', '--strict', '--all-architectures', str(target)],
                       env=env, check=True, capture_output=True, timeout=15)
        metadata = subprocess.run(['/usr/bin/codesign', '-dvv', '--entitlements', ':-', str(target)],
                       env=env, check=True, capture_output=True, timeout=15)
        require(b'runtime' in metadata.stderr and b'adhoc' in metadata.stderr, 'missing runtime/ad-hoc')
        require(plistlib.loads(metadata.stdout) == {}, 'nonempty entitlements')
        checks.append(str(target.relative_to(root)))
    print(json.dumps({'staticVerified': checks, 'runID': run_id, 'servicesExecuted': False, 'thinArchitecture': 'arm64', 'executableSHA256': hashes}))

def seal_artifact(root):
    fd = scoped_root(str(root), PREFIX)
    try:
        rs = os.fstat(fd)
        manifest = {'schema': 1, 'kind': 's8-disposable-build', 'runID': root.name[len('sanjbox-s8-services-'):],
                    'uid': rs.st_uid, 'gid': rs.st_gid, 'device': rs.st_dev, 'inode': rs.st_ino,
                    'entries': inventory(fd)}
        write_new(root/'artifact-manifest.json', json.dumps(manifest, sort_keys=True).encode())
    finally:
        os.close(fd)

def validated_artifact(root):
    fd = scoped_root(root, PREFIX)
    try:
        m = read_json(fd, 'artifact-manifest.json')
        s = os.fstat(fd)
        require(m['schema'] == 1 and m['kind'] == 's8-disposable-build' and
                m['runID'] == root[len(PREFIX):] and
                (m['uid'], m['gid'], m['device'], m['inode']) == (s.st_uid, s.st_gid, s.st_dev, s.st_ino), 'manifest/root identity conflict')
        require(inventory(fd) == m['entries'], 'artifact content/metadata/name conflict; nothing removed')
        return fd, m
    except BaseException:
        os.close(fd)
        raise

def remove_tree(fd, entries, prefix=''):
    # Every name is from the already validated inventory, never from a path argument.
    for name in sorted(os.listdir(fd)):
        if not prefix and name == 'artifact-manifest.json':
            continue
        expected = entries[prefix+name]
        require(snapshot(fd, name) == expected, 'entry changed before removal')
        if stat.S_ISDIR(expected['mode']):
            child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            try:
                remove_tree(child, entries, prefix+name+'/')
            finally:
                os.close(child)
            require(snapshot(fd, name) == expected, 'directory identity changed')
            os.rmdir(name, dir_fd=fd)
        else:
            os.unlink(name, dir_fd=fd)

def cleanup(root, apply):
    if not os.path.lexists(root):
        require(root.startswith(PREFIX), 'outside own root')
        canonical_uuid(root[len(PREFIX):])
        print('already absent; no service state was checked')
        return
    fd, m = validated_artifact(root)
    try:
        if apply:
            remove_tree(fd, m['entries'])
            os.unlink('artifact-manifest.json', dir_fd=fd)
            s = os.lstat(root)
            require((s.st_dev, s.st_ino) == (m['device'], m['inode']), 'root changed before rmdir')
            os.rmdir(root)
        print('removed own uninstalled artifact' if apply else 'dry-run: validated exact own artifact; would unlink inventoried objects and empty root')
    finally:
        os.close(fd)

def cleanup_event(root, run_id, session, apply):
    canonical_uuid(run_id)
    require(session > 0, 'explicit original audit session required')
    if not os.path.lexists(root):
        require(root.startswith(EVENT_PREFIX), 'outside event root')
        canonical_uuid(root[len(EVENT_PREFIX):])
        print('event already absent')
        return
    fd = scoped_root(root, EVENT_PREFIX)
    try:
        require(set(os.listdir(fd)) == {'event.json', 'manifest.json'}, 'partial/extra event files; preserve conflict')
        before = {n: snapshot(fd, n) for n in ('event.json', 'manifest.json')}
        m = read_json(fd, 'manifest.json', 4096)
        e = read_json(fd, 'event.json', 16384)
        s = os.fstat(fd)
        require(m['schema'] == 1 and m['kind'] == 's8-event-cleanup' and m['runID'] == run_id and m['session'] == session,
                'wrong event run/session')
        require((m['ownerUID'], m['ownerGID'], m['rootDevice'], m['rootInode']) == (s.st_uid, s.st_gid, s.st_dev, s.st_ino), 'event root conflict')
        require(m['eventInode'] == before['event.json']['inode'] and m['eventSHA256'] == before['event.json']['sha256'], 'event changed')
        require(e['runID'] == run_id and e['context']['effectiveUID'] == s.st_uid and
                e['context']['audit']['sessionID'] == session, 'event identity conflict')
        if apply:
            require(all(snapshot(fd, n) == original for n, original in before.items()), 'event changed before cleanup')
            os.unlink('event.json', dir_fd=fd)
            os.unlink('manifest.json', dir_fd=fd)
            current = os.lstat(root)
            require((current.st_dev, current.st_ino) == (s.st_dev, s.st_ino), 'event root changed')
            os.rmdir(root)
        print('removed own event' if apply else 'dry-run: exact event validated; would remove its two files and empty root')
    finally:
        os.close(fd)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    prep = sub.add_parser('prepare'); prep.add_argument('--apply', action='store_true')
    for command in ('verify', 'cleanup'):
        p = sub.add_parser(command); p.add_argument('--root', required=True)
        if command == 'cleanup': p.add_argument('--apply', action='store_true')
    p = sub.add_parser('cleanup-event'); p.add_argument('--root', required=True)
    p.add_argument('--run-id', required=True); p.add_argument('--session', required=True, type=int)
    p.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    os.umask(0o077)
    require(os.geteuid() != 0, 'never run as root')
    if args.command == 'prepare':
        if not args.apply:
            print('DRY-RUN: create fresh 0700 '+PREFIX+'UUID; native Release build four targets, fixed app/plists, ad-hoc runtime/empty-entitlement sign and static verify; seal inventory. No execution, installation or ServiceManagement calls. Cleanup accepts only this owned inventory.')
            return
        root = Path(PREFIX+str(uuid.uuid4()).upper())
        root.mkdir(mode=0o700)
        print('OWN_ROOT='+str(root), flush=True)
        try:
            build(root)
        finally:
            # Failed builds are also inventoried for conflict-refusing cleanup.
            seal_artifact(root)
    elif args.command == 'verify':
        fd, _ = validated_artifact(args.root)
        try: verify_app(Path(args.root))
        finally: os.close(fd)
    elif args.command == 'cleanup':
        cleanup(args.root, args.apply)
    else:
        cleanup_event(args.root, args.run_id, args.session, args.apply)

if __name__ == '__main__':
    try:
        main()
    except (Refused, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print('REFUSED: '+str(error), file=sys.stderr)
        sys.exit(1)
