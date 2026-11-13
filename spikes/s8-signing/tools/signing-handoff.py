#!/usr/bin/env python3
"""Offline copy/signing handoff. Never selects an identity or executes a signing command."""
import argparse
import contextlib
import fcntl
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import stat
import struct
import subprocess
import sys

spec = importlib.util.spec_from_file_location('service_fixtures', Path(__file__).with_name('service-fixtures.py'))
f = importlib.util.module_from_spec(spec)
spec.loader.exec_module(f)
PREFIX = '/private/tmp/sanjbox-s8-signing-'
PREPARED = 'prepared-inventory.json'
HANDOFF = 'handoff.json'
SIGNED = 'signed-inventory.json'
CONTROL = {PREPARED, HANDOFF, SIGNED}
LOGIN = f.APP + '/Contents/Library/LoginItems/S8LoginItem.app'
TARGETS = (f.APP + '/Contents/MacOS/S8LaunchAgent', f.APP + '/Contents/MacOS/S8LaunchDaemon', LOGIN, f.APP)
BINARIES = tuple(f.APP + '/Contents/MacOS/' + p for p in ('S8LaunchAgent', 'S8LaunchDaemon', 'S8ServiceHost')) + (LOGIN + '/Contents/MacOS/S8LoginItem',)
RESOURCES = {f.APP + '/Contents/_CodeSignature/CodeResources', LOGIN + '/Contents/_CodeSignature/CodeResources'}


def root_path(value):
    f.require(value.startswith(PREFIX), 'outside signing-copy prefix')
    f.canonical_uuid(value[len(PREFIX):])
    f.require(os.path.realpath(value) == value, 'noncanonical/symlink signing root')
    return Path(value)


def profile_check(profile, fallback):
    f.require(profile in ('personal-team', 'self-signed'), 'unknown requested profile')
    f.require(fallback == (profile == 'self-signed'),
              'self-signed requires --personal-team-failed; Personal Team must not use that flag')


def entries(fd):
    # The old helper intentionally ignores artifact-manifest.json. It is forbidden here.
    names = set(os.listdir(fd))
    f.require(names <= {f.APP, 'empty-entitlements.plist', 'provenance.json'} | CONTROL,
              'unexpected signing-root entry')
    result = f.inventory(fd)
    for name, info in result.items():
        f.require(not stat.S_ISLNK(info['mode']), 'no symlinks in signing copy: ' + name)
    return result


def without_controls(value):
    return {name: info for name, info in value.items() if name not in CONTROL}


def read_bytes(fd, name):
    # Every intermediate component is opened without following symlinks.
    parts = name.split('/')
    f.require(all(p not in ('', '.', '..') for p in parts), 'unsafe relative inventory path')
    parent = os.dup(fd)
    try:
        for part in parts[:-1]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
            os.close(parent)
            parent = child
        before = f.snapshot(parent, parts[-1])
        f.require(stat.S_ISREG(before['mode']), 'expected regular file')
        item = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
        try:
            with os.fdopen(item, 'rb', closefd=False) as stream:
                data = stream.read(before['size'] + 1)
        finally:
            os.close(item)
        f.require(len(data) == before['size'] and hashlib.sha256(data).hexdigest() == before['sha256'] and
                  f.snapshot(parent, parts[-1]) == before, 'file changed during read')
        return data
    finally:
        os.close(parent)


def payload_hash(data):
    """Thin arm64 fixture only; exclude the trailing signature and its size bookkeeping.

    Re-signing can resize LC_CODE_SIGNATURE and __LINKEDIT. All other load commands,
    sections and payload bytes must remain identical to the original ad-hoc copy.
    """
    f.require(32 <= len(data) <= 64 * 1024 * 1024, 'Mach-O size')
    magic, cpu, _, _, count, size, _, _ = struct.unpack_from('<8I', data)
    f.require((magic, cpu) == (0xfeedfacf, 0x100000c) and 0 < count <= 4096 and size <= len(data) - 32,
              'expected bounded thin arm64 Mach-O')
    cursor = 32
    signature = linkedit = None
    for _ in range(count):
        f.require(cursor + 8 <= 32 + size, 'truncated load command')
        kind, length = struct.unpack_from('<II', data, cursor)
        f.require(length >= 8 and length % 8 == 0 and cursor + length <= 32 + size, 'invalid load command')
        if kind == 0x1d:  # LC_CODE_SIGNATURE, linkedit_data_command
            f.require(signature is None and length == 16, 'ambiguous signature load command')
            offset, length_bytes = struct.unpack_from('<II', data, cursor + 8)
            signature = (cursor, offset, length_bytes)
        if kind == 0x19:  # LC_SEGMENT_64
            f.require(length >= 72, 'short segment command')
            if data[cursor + 8:cursor + 24].rstrip(b'\0') == b'__LINKEDIT':
                f.require(linkedit is None and length == 72, 'ambiguous/sectioned LINKEDIT')
                linkedit = cursor
        cursor += length
    f.require(cursor == 32 + size and signature is not None and linkedit is not None, 'incomplete Mach-O layout')
    command, offset, signature_size = signature
    f.require(offset >= cursor and offset % 16 == 0 and signature_size > 0 and
              offset + signature_size == len(data), 'signature must be a bounded trailing blob')
    vm_size, file_offset, file_size = struct.unpack_from('<QQQ', data, linkedit + 32)
    f.require(cursor <= file_offset <= offset and file_offset + file_size == len(data) and
              vm_size == ((file_size + 16383) // 16384) * 16384,
              'inconsistent LINKEDIT bounds')
    canonical = bytearray(data[:offset])
    canonical[command + 12:command + 16] = bytes(4)  # preserve dataoff
    canonical[linkedit + 32:linkedit + 40] = bytes(8)
    canonical[linkedit + 48:linkedit + 56] = bytes(8)
    return hashlib.sha256(canonical).hexdigest()


def identity(fd):
    s = os.fstat(fd)
    return dict(uid=s.st_uid, gid=s.st_gid, device=s.st_dev, inode=s.st_ino)


def linked_root(root, fd):
    s = os.lstat(root)
    f.require(identity(fd) == dict(uid=s.st_uid, gid=s.st_gid, device=s.st_dev, inode=s.st_ino), 'root replaced')
    f.require(stat.S_ISDIR(s.st_mode) and stat.S_IMODE(s.st_mode) == 0o700 and s.st_flags == 0, 'root metadata changed')
    f.no_acl(fd)


def lock_root(fd):
    """Serialize cooperating processes on this directory inode, including dry-runs.

    No lockfile is created or adopted. The caller retains this fd until its entire
    operation completes; close also releases the lock on refusal or process exit.
    This advisory lock does not constrain a user signing outside this tool.
    """
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise f.Refused('signing root busy; another handoff operation holds its directory lock')


def write_record(root, fd, name, value):
    linked_root(root, fd)
    data = json.dumps(value, sort_keys=True, indent=2).encode() + b'\n'
    f.write_new(root/name, data)
    os.fsync(fd)


def adhoc_verify(root):
    # Keep the original verifier's ad-hoc requirement completely unchanged.
    with contextlib.redirect_stdout(io.StringIO()):
        f.verify_app(root)


def prepare(source, destination, profile, fallback=False, apply=False):
    profile_check(profile, fallback)
    root = root_path(destination)
    f.require(not os.path.lexists(root), 'destination already exists; never adopt or overwrite')
    source_fd, manifest = f.validated_artifact(source)
    try:
        app_entries = {n: v for n, v in manifest['entries'].items() if n == f.APP or n.startswith(f.APP + '/')}
        f.require(f.APP in app_entries and RESOURCES <= app_entries.keys(), 'incomplete source app')
        f.require(all(stat.S_ISREG(v['mode']) or stat.S_ISDIR(v['mode']) for v in app_entries.values()),
                  'source app must contain only owned files/directories, no links')
        adhoc_verify(Path(source))
        payloads = {name: payload_hash(read_bytes(source_fd, name)) for name in BINARIES}
        manifest_info = f.snapshot(source_fd, 'artifact-manifest.json')
        provenance = dict(schema=1, kind='s8-signing-copy-provenance', sourceRoot=source,
                          sourceRunID=manifest['runID'], sourceManifest=manifest_info,
                          sourceAppEntries=app_entries, requestedProfile=profile,
                          personalTeamFailureAcknowledged=fallback, originalDestination='absent')
        plan = dict(dryRun=not apply, source=source, destination=destination,
                    sourceUnchanged=True, sourceManifestSHA256=manifest_info['sha256'],
                    requestedProfile=profile, copyEntries=sorted(app_entries),
                    changes=['create new 0700 root', 'copy only app files/directories, never build cache',
                             'write empty-entitlements.plist, provenance.json, prepared-inventory.json'],
                    insideOutTargets=[str(root/n) for n in TARGETS],
                    signingExecuted=False, servicesExecuted=False,
                    next='handoff is a separate user-only step; cleanup becomes blocked once issued')
        if not apply:
            f.require(f.inventory(source_fd) == manifest['entries'], 'source changed during plan')
            return plan
        root.mkdir(mode=0o700)
        # On failure retain this exact root. Never bless a partial copy as a complete inventory.
        print('OWN_SIGNING_ROOT=' + str(root), file=sys.stderr, flush=True)
        fd = f.scoped_root(str(root), PREFIX)
        try:
            lock_root(fd)
            linked_root(root, fd)
            f.write_new(root/'provenance.json', json.dumps(provenance, sort_keys=True).encode())
            for name, before in sorted(app_entries.items()):
                if stat.S_ISDIR(before['mode']):
                    (root/name).mkdir(mode=stat.S_IMODE(before['mode']))
                else:
                    data = read_bytes(source_fd, name)
                    f.require(hashlib.sha256(data).hexdigest() == before['sha256'], 'source changed before copy')
                    f.write_new(root/name, data, stat.S_IMODE(before['mode']))
            f.write_new(root/'empty-entitlements.plist', plistlib.dumps({}))
            f.require(f.inventory(source_fd) == manifest['entries'] and
                      f.snapshot(source_fd, 'artifact-manifest.json') == manifest_info, 'source changed during copy')
            adhoc_verify(root)
            copied = entries(fd)
            for name, before in app_entries.items():
                for field in ('mode', 'uid', 'size', 'sha256'):
                    f.require(copied[name].get(field) == before.get(field), 'copied content/metadata mismatch')
            record = dict(schema=1, kind='s8-prepared-signing-copy', root=str(root), rootIdentity=identity(fd),
                          requestedProfile=profile, personalTeamFailureAcknowledged=fallback,
                          entries=copied, payloadSHA256=payloads)
            write_record(root, fd, PREPARED, record)
        finally:
            os.close(fd)
        return plan
    finally:
        os.close(source_fd)


def open_prepared(value):
    root = root_path(value)
    fd = f.scoped_root(value, PREFIX)
    try:
        lock_root(fd)
        actual = entries(fd)
        record = f.read_json(fd, PREPARED)
        f.require(record['schema'] == 1 and record['kind'] == 's8-prepared-signing-copy' and
                  record['root'] == value and record['rootIdentity'] == identity(fd), 'prepared root identity conflict')
        profile_check(record['requestedProfile'], record['personalTeamFailureAcknowledged'])
        f.require(set(record['payloadSHA256']) == set(BINARIES), 'incomplete original payload hashes')
        f.require(all(n not in CONTROL for n in record['entries']), 'control files in baseline')
        linked_root(root, fd)
        return root, fd, record, actual
    except BaseException:
        os.close(fd)
        raise


def require_pristine(root, fd, record, actual):
    f.require(set(actual) == set(record['entries']) | {PREPARED} and
              without_controls(actual) == record['entries'], 'prepared copy changed or handoff already issued')
    adhoc_verify(root)
    f.require(entries(fd) == actual, 'copy changed during ad-hoc preflight')


def commands(root):
    # This is text only. No API in this module accepts or discovers an identity.
    result = ['set -euo pipefail', 'umask 077', ': "${S8_USER_SIGNING_IDENTITY:?Set this yourself outside the agent; never send its value to the agent}"']
    for name in TARGETS:
        result.append('/usr/bin/codesign --force --sign "$S8_USER_SIGNING_IDENTITY" --timestamp=none --options runtime --entitlements ' +
                      shlex.quote(str(root/'empty-entitlements.plist')) + ' ' + shlex.quote(str(root/name)))
    return '\n'.join(result)


def handoff(value, apply=False):
    root, fd, record, actual = open_prepared(value)
    try:
        require_pristine(root, fd, record, actual)
        if not apply:
            return dict(dryRun=True, root=value, requestedProfile=record['requestedProfile'],
                        wouldWrite=str(root/HANDOFF), targets=[str(root/n) for n in TARGETS],
                        flags=['--force', '--timestamp=none', '--options', 'runtime', '--entitlements', str(root/'empty-entitlements.plist')],
                        identity='selected and used exclusively by user; no identity accepted by this tool',
                        cleanupAfterHandoff='REFUSED: registration state unknown', signingExecuted=False)
        write_record(root, fd, HANDOFF, dict(schema=1, kind='s8-user-signing-handoff', root=value,
                     rootIdentity=identity(fd), preparedManifest=actual[PREPARED],
                     requestedProfile=record['requestedProfile'], registrationState='unknown',
                     automaticArtifactCleanup='blocked', servicesAuthorized=False))
        return dict(dryRun=False, root=value, userOnlyCommands=commands(root), signingExecuted=False,
                    next='user runs commands; then record-signed dry-run and --apply; never launch/register this copy',
                    cleanup='blocked from this point, even if signing fails')
    finally:
        os.close(fd)


def signature_check(root, name):
    env = {'PATH': '/usr/bin:/bin', 'LC_ALL': 'C'}
    target = str(root/name)
    # Inspect the embedded signature, never extract certificates or query a Keychain.
    for args in (['--verify', '--strict', '--all-architectures', target],
                 ['-dvv', '--entitlements', ':-', target]):
        result = subprocess.run(['/usr/bin/codesign'] + args, env=env, stdin=subprocess.DEVNULL,
                                capture_output=True, timeout=15, check=False)
        f.require(result.returncode == 0, 'codesign verification/display failed for ' + name)
    matches = re.findall(rb'^CodeDirectory .*? flags=0x([0-9a-fA-F]+)\b', result.stderr, re.MULTILINE)
    f.require(len(matches) == 1, 'missing/ambiguous signing flags for ' + name)
    flags = int(matches[0], 16)
    f.require(flags & 0x10000 != 0 and flags & 2 == 0, 'runtime required and ad-hoc forbidden for ' + name)
    try:
        entitlements = plistlib.loads(result.stdout)
    except (ValueError, plistlib.InvalidFileException):
        raise f.Refused('unknown entitlements for ' + name)
    f.require(entitlements == {}, 'all entitlements forbidden, including false-valued get-task-allow: ' + name)
    # Do not store/emit Authority, TeamIdentifier, certificate material or identity strings.
    return dict(target=name, strictAllArchitectures=True, hardenedRuntime=True, adHoc=False,
                getTaskAllow='absent', entitlements='empty')


def checked_signed(root, fd, record, actual):
    f.require(HANDOFF in actual, 'explicit handoff record required')
    handoff_record = f.read_json(fd, HANDOFF)
    f.require(handoff_record == dict(schema=1, kind='s8-user-signing-handoff', root=str(root),
              rootIdentity=identity(fd), preparedManifest=actual[PREPARED],
              requestedProfile=record['requestedProfile'], registrationState='unknown',
              automaticArtifactCleanup='blocked', servicesAuthorized=False), 'handoff provenance conflict')
    baseline = record['entries']
    current = without_controls(actual)
    f.require(set(current) == set(baseline), 'added/missing signed-copy entry')
    mutable = set(BINARIES) | RESOURCES
    for name, before in baseline.items():
        if name in mutable:
            f.require(stat.S_ISREG(current[name]['mode']), 'signed target type changed')
            f.require(all(current[name][key] == before[key] for key in ('device', 'mode', 'uid', 'gid', 'flags')),
                      'signing changed protected metadata: ' + name)
        else:
            f.require(current[name] == before, 'non-signature content/metadata changed: ' + name)
    for name in BINARIES:
        f.require(payload_hash(read_bytes(fd, name)) == record['payloadSHA256'][name], 'executable payload changed: ' + name)
    observations = [signature_check(root, name) for name in TARGETS]
    f.require(entries(fd) == actual, 'copy changed during signing preflight')
    linked_root(root, fd)
    return observations


def record_signed(value, apply=False):
    root, fd, record, actual = open_prepared(value)
    try:
        observations = checked_signed(root, fd, record, actual)
        evidence = dict(schema=1, kind='s8-signed-copy-inventory', root=value, rootIdentity=identity(fd),
                        requestedProfile=record['requestedProfile'], profileVerified=False,
                        entries={n: v for n, v in actual.items() if n != SIGNED},
                        observations=observations, registrationState='unknown', lifecycleVerified=False)
        if SIGNED in actual:
            f.require(f.read_json(fd, SIGNED) == evidence, 'signed inventory changed; never reseal drift')
        elif apply:
            write_record(root, fd, SIGNED, evidence)
        return dict(dryRun=not apply, inventory=str(root/SIGNED), alreadyRecorded=SIGNED in actual,
                    observations=observations, requestedProfile=record['requestedProfile'], profileVerified=False,
                    cleanup='REFUSED: registration state unknown', lifecycleVerified=False)
    finally:
        os.close(fd)


def cleanup(value, apply=False):
    root = root_path(value)
    if not os.path.lexists(root):
        return dict(alreadyAbsent=True, serviceStateChecked=False)
    root, fd, record, actual = open_prepared(value)
    try:
        f.require(HANDOFF not in actual and SIGNED not in actual,
                  'registration state unknown after handoff; preserve copy for reviewed L2 ownership/cleanup; no unregister')
        require_pristine(root, fd, record, actual)
        if apply:
            linked_root(root, fd)
            f.remove_tree(fd, actual)
            linked_root(root, fd)
            os.rmdir(root)
        return dict(dryRun=not apply, removed=apply, paths=sorted(actual), root=value,
                    scope='unchanged ad-hoc prepared copy before handoff only', serviceStateChecked=False)
    finally:
        os.close(fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    prep = sub.add_parser('prepare')
    prep.add_argument('--source', required=True)
    prep.add_argument('--destination', required=True)
    prep.add_argument('--profile', choices=('personal-team', 'self-signed'), required=True)
    prep.add_argument('--personal-team-failed', action='store_true')
    prep.add_argument('--apply', action='store_true')
    for name in ('handoff', 'record-signed', 'cleanup'):
        p = sub.add_parser(name)
        p.add_argument('--root', required=True)
        p.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    os.umask(0o077)
    f.require(os.geteuid() != 0, 'never run as root')
    if args.command == 'prepare':
        result = prepare(args.source, args.destination, args.profile, args.personal_team_failed, args.apply)
    else:
        result = {'handoff': handoff, 'record-signed': record_signed, 'cleanup': cleanup}[args.command](args.root, args.apply)
    if args.command == 'handoff' and args.apply:
        print('# USER ONLY: signing commands; never launch or register this copy.')
        print('# handoff.json was saved first; automatic artifact cleanup is now blocked.')
        print(result['userOnlyCommands'])
    else:
        print(json.dumps(result, sort_keys=True, indent=2))


if __name__ == '__main__':
    try:
        main()
    except (f.Refused, OSError, ValueError, KeyError, TypeError, struct.error, subprocess.SubprocessError) as error:
        print('REFUSED: ' + str(error), file=sys.stderr)
        sys.exit(1)
