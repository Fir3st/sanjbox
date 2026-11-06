#!/usr/bin/env python3
"""Signed native CLI validation on explicit owned child registrations only.
Default dry-run. --expect-file must be independently reviewed and preregistered before this run;
this script never substitutes observed credentials. All outputs/failures are kept in a new directory.
"""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import select
import stat
import subprocess
import time
import uuid


def read_owned(path, bound):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as stream:
        info = os.fstat(stream.fileno())
        assert stat.S_ISREG(info.st_mode) and info.st_uid == os.geteuid() and info.st_nlink == 1 and 0 < info.st_size <= bound
        raw = stream.read(bound + 1)
        assert len(raw) == info.st_size
        return raw


def run(binary, expected_file, output):
    expected_raw = read_owned(expected_file, 16384)
    expected = json.loads(expected_raw)
    output.mkdir(mode=0o700)  # exclusive; never reuse old evidence
    (output / 'expected-preregistered.json').write_bytes(expected_raw)
    namespace = 'a2-series-' + uuid.uuid4().hex[:12]
    datasets, results, staged, children = [], [], [], []

    def keep(name, value):
        path = output / name
        with path.open('x') as stream:
            json.dump(value, stream, indent=2)

    def check(label, args, code=0, timeout=25):
        result = subprocess.run([str(binary), *args], capture_output=True, text=True, timeout=timeout, env={})
        entry = dict(label=label, arguments=args, expectedExit=code, exit=result.returncode, stdout=result.stdout, stderr=result.stderr)
        results.append(entry)
        keep(f'{len(results):02}-{label}.json', entry)
        assert result.returncode == code, (label, result.returncode, result.stdout, result.stderr)
        path = result.stdout.strip()
        if re.fullmatch(r'/private/tmp/sanjbox-a2-[A-Za-z0-9-]+-uid\d+-(process-series|report)', path):
            if path not in datasets:
                datasets.append(path)
            return Path(path)
        return None

    def line(child, timeout=4):
        # Unbuffered, bounded one-line protocol; never block indefinitely on a worker.
        data = bytearray()
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            ready, _, _ = select.select([child.stdout], [], [], max(0, deadline-time.monotonic()))
            assert ready, 'fixture handshake timeout'
            byte = os.read(child.stdout.fileno(), 1)
            assert byte, 'fixture ended before protocol line'
            if byte == b'\n':
                return json.loads(data)
            data += byte
            assert len(data) <= 16384, 'oversize fixture protocol'
        raise AssertionError('fixture protocol timeout')

    def evaluate(label, raw, code):
        name = namespace + '-' + label
        path = Path(f'/private/tmp/sanjbox-a2-fixture-{os.geteuid()}-{name}.json')
        data = json.dumps(raw).encode()
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
        staged.append((path, path.lstat().st_ino))
        keep(label + '-input.json', raw)
        report_path = check(label, ['evaluate-process-series', '--fixture', name, '--run-id', name, '--apply'], code)
        return json.loads((report_path / 'report.json').read_text()) if report_path else None

    try:
        signatures = []
        for args in [['--verify', '--strict'], ['-dvvv'], ['-d', '--entitlements', ':-']]:
            value = subprocess.run(['/usr/bin/codesign', *args, str(binary)], capture_output=True, text=True, timeout=10)
            signatures.append(dict(arguments=args, exit=value.returncode, stdout=value.stdout, stderr=value.stderr))
            assert value.returncode == 0, 'signature command failed'
        keep('signature.json', signatures)
        assert 'runtime' in signatures[1]['stderr'], 'hardened runtime required'
        xml = signatures[2]['stdout'].encode()
        entitlements = plistlib.loads(xml) if xml.strip() else {}
        assert isinstance(entitlements, dict) and not {'get-task-allow', 'com.apple.security.get-task-allow'} & entitlements.keys()

        sample_target = dict(slot=1, identity=dict(pid=os.getpid(), uid=expected['uid'], realUID=expected['uid'], startSeconds=1, startMicroseconds=0), role='application', provenanceSHA256=hashlib.sha256(expected_raw).hexdigest())
        plan = dict(runID=namespace+'-dry', seconds=1, registrations=[sample_target])
        args = ['process-series', '--series-json', json.dumps(plan), '--expect-json', json.dumps(expected)]
        check('dry-registry', args)
        assert not Path(f'/private/tmp/sanjbox-a2-{plan["runID"]}-uid{os.geteuid()}-process-series').exists()
        check('no-pid-option', args+['--pid', str(os.getpid())], 2)
        bad = copy.deepcopy(plan); bad['registrations'][0]['identity']['uid'] += 1; bad['registrations'][0]['identity']['realUID'] += 1
        check('cross-uid-before-read', ['process-series', '--series-json', json.dumps(bad), '--expect-json', json.dumps(expected), '--apply'], 2)
        assert not Path(f'/private/tmp/sanjbox-a2-{plan["runID"]}-uid{os.geteuid()}-process-series').exists()
        bad = copy.deepcopy(plan); bad['registrations'].append(copy.deepcopy(sample_target))
        check('duplicate-registry', ['process-series', '--series-json', json.dumps(bad), '--expect-json', json.dumps(expected), '--apply'], 2)
        bad = copy.deepcopy(plan); bad['registrations'][0]['name'] = 'forbidden'
        check('no-process-names', ['process-series', '--series-json', json.dumps(bad), '--expect-json', json.dumps(expected)], 2)
        check('dry-owned', ['owned-process-series', '--run-id', namespace+'-owned-dry', '--expect-json', json.dumps(expected)])
        mismatch = copy.deepcopy(expected); mismatch['auditSessionID'] += 1
        plan['runID'] = namespace+'-identity-mismatch'
        path = check('identity-rejection', ['process-series', '--series-json', json.dumps(plan), '--expect-json', json.dumps(mismatch), '--apply'], 3)
        raw = json.loads((path / 'recording.json').read_text())
        assert raw['samples'] == [] and raw['bindings'] == [] and 'window' not in raw
        assert not (path / 'registry.json').exists()
        path = check('owned-identity-rejection', ['owned-process-series', '--run-id', namespace+'-owned-mismatch', '--expect-json', json.dumps(mismatch), '--apply'], 3)
        raw = json.loads((path / 'recording.json').read_text())
        assert not raw['bindings'] and not raw['samples'] and 'ownedFixtureResults' not in raw

        request = dict(slot=1, parentPID=os.getpid(), expected=expected)
        child = subprocess.Popen([str(binary), 'owned-memory-fixture', '--fixture-json', json.dumps(request), '--apply'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0, env={})
        children.append(child)
        hello = line(child)
        keep('owned-child-registration.json', hello)
        assert hello['process']['pid'] == child.pid and hello['parentPID'] == os.getpid() and hello['process']['uid'] == expected['uid']
        assert hello['signature']['hardenedRuntime'] and not hello['signature']['forbiddenEntitlementPresent']
        target = dict(slot=1, identity=hello['process'], role='ownedAllocationFixture', provenanceSHA256=hashlib.sha256((output / 'owned-child-registration.json').read_bytes()).hexdigest())
        live = dict(runID=namespace+'-positive', seconds=4, registrations=[target])
        # Seal registry and oracle before arming the allocation and invoking the actual collector CLI.
        keep('positive-preregistration.json', dict(plan=live, expected=expected, oracle=dict(exit=0, minimumGrowthBytes=8*1024*1024, noSessionVerdict=True)))
        child.stdin.write(b'G'); child.stdin.flush()
        path = check('signed-live-registry', ['process-series', '--series-json', json.dumps(live), '--expect-json', json.dumps(expected), '--apply'])
        raw = json.loads((path / 'recording.json').read_text()); report = json.loads((path / 'report.json').read_text())
        assert report['acquisitionComplete'] and not report['fullSessionAttributionComplete']
        values = [p['physicalFootprintBytes'] for p in raw['samples'] if p['state'] == 'sampled']
        assert len(values) >= 5 and max(values)-min(values) >= 8*1024*1024, 'known child allocation was not observed'
        assert all(p['before'] == hello['process'] == p['after'] for p in raw['samples'])
        digest_before = hashlib.sha256((path / 'recording.json').read_bytes()).hexdigest()
        check('preserve-live-conflict', ['process-series', '--series-json', json.dumps(live), '--expect-json', json.dumps(expected), '--apply'], 2)
        assert hashlib.sha256((path / 'recording.json').read_bytes()).hexdigest() == digest_before
        evaluate('offline-positive', raw, 0)
        wrong_instance = copy.deepcopy(live); wrong_instance['runID'] = namespace+'-wrong-start'; wrong_instance['seconds'] = 1
        wrong_instance['registrations'][0]['identity']['startMicroseconds'] = (hello['process']['startMicroseconds']+1) % 1000000
        wrong_path = check('wrong-instance', ['process-series', '--series-json', json.dumps(wrong_instance), '--expect-json', json.dumps(expected), '--apply'], 3)
        wrong_raw = json.loads((wrong_path / 'recording.json').read_text())
        assert all(p['state'] == 'identityChangedBefore' and 'physicalFootprintBytes' not in p for p in wrong_raw['samples'])
        child.stdin.close()
        outcome = line(child); keep('owned-child-completion.json', outcome)
        assert child.wait(timeout=4) == 0
        assert outcome['allocatedAt'] >= outcome['started'] and outcome['fixtureMiB'] == 16
        # A dead registered owned PID and deliberately wrong start are retained, never read as zero.
        dead = copy.deepcopy(live); dead['runID'] = namespace+'-exited'; dead['seconds'] = 1
        path = check('registered-exit', ['process-series', '--series-json', json.dumps(dead), '--expect-json', json.dumps(expected), '--apply'], 3)
        exited = json.loads((path / 'recording.json').read_text())
        assert all(p['state'] != 'sampled' and 'physicalFootprintBytes' not in p for p in exited['samples'])
        path = check('native-birth-allocation-exit', ['owned-process-series', '--run-id', namespace+'-lifecycle', '--expect-json', json.dumps(expected), '--apply'], 3)
        lifecycle = json.loads((path / 'recording.json').read_text()); summary = json.loads((path / 'report.json').read_text())
        assert lifecycle['ownedCleanupComplete'] and len(lifecycle['ownedFixtureResults']) == 2
        transient = [p for p in lifecycle['samples'] if p['slot'] == 2]
        assert transient[0]['state'] == 'notRegistered' and any(p['state'] == 'sampled' for p in transient) and any(p['state'] in ('unreadableBefore', 'unreadableAfter') for p in transient)
        assert not summary['acquisitionComplete'] and 'process arrival inside window' in summary['processes'][1]['issues']
        assert len(lifecycle['bindings']) == 2 and lifecycle['bindings'][1]['registeredAt'] > lifecycle['window']['start']
        evaluate('offline-lifecycle', lifecycle, 3)
        keep('passed.json', dict(checks=len(results), positiveSamples=len(values), allocationGrowthBytes=max(values)-min(values), fullSessionAttributionComplete=False, ownedChildrenExited=True))
    finally:
        for child in children:
            if not child.stdin.closed:
                child.stdin.close()
            try:
                child.wait(timeout=17)  # worker also has its own 15-second watchdog
            except subprocess.TimeoutExpired:
                # Do not signal a numeric PID that could have been reused. Report the owned-cleanup failure.
                keep('cleanup-failure.json', dict(ownedChildPID=child.pid, reason='self watchdog did not exit'))
            child.stdout.close(); child.stderr.close()
        for path, inode in staged:
            info = path.lstat()
            assert stat.S_ISREG(info.st_mode) and info.st_uid == os.geteuid() and info.st_ino == inode and info.st_nlink == 1
            path.unlink()
        keep('datasets.json', datasets)
        keep('results.json', results)
        manifest = {}
        for path in sorted(output.iterdir()):
            if path.is_file():
                manifest[path.name] = hashlib.sha256(path.read_bytes()).hexdigest()
        keep('manifest.json', manifest)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--expect-file', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    if not args.apply:
        print('dry-run: verify signed CLI; bounded owned children + explicit same-UID registrations; preserve evidence in a fresh output directory')
        return
    run(args.binary, args.expect_file, args.output)


if __name__ == '__main__':
    main()
