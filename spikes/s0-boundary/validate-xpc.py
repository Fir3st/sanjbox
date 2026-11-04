#!/usr/bin/env python3
"""Own disposable XPC fixture validation. No service registration, arbitrary binary or PID input."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import select
import selectors
import shutil
import stat
import subprocess
import tempfile
import time
import uuid

if not __debug__:
    raise RuntimeError('Fixture validation requires Python assertions; -O is unsupported')

PACKAGE = Path(__file__).resolve().parent
CLIENT_ID = 'org.sanjbox.a4.fixture-client'
SERVICE_ID = 'org.sanjbox.a4.fixture-service'


def run(args, **kwargs):
    return subprocess.run(args, check=True, timeout=180, **kwargs)


def plist(path, data):
    path.write_bytes(plistlib.dumps(data))


def seal(path, identifier, entitlements, log):
    run(['/usr/bin/codesign', '--force', '--sign', '-', '--identifier', identifier,
         '--options', 'runtime', '--timestamp=none', '--entitlements', str(entitlements), str(path)],
        stdout=log, stderr=log)
    run(['/usr/bin/codesign', '--verify', '--strict', str(path)], stdout=log, stderr=log)
    output = run(['/usr/bin/codesign', '-d', '--verbose=4', str(path)], capture_output=True, text=True).stderr
    assert 'runtime' in output
    digest = re.search(r'^CDHash=([0-9a-f]{40})$', output, re.M)[1]
    log.write(output); log.flush()
    return digest


def receipt(root):
    """Only newly created fixture contents; no following links or foreign objects."""
    result = {}
    for path in [root, *root.rglob('*')]:
        info = path.lstat()
        assert info.st_uid == os.geteuid() and (stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode))
        assert not stat.S_ISREG(info.st_mode) or info.st_nlink == 1
        result[path] = (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid, info.st_flags,
                        hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None)
    return result


def cleanup(root, before):
    assert receipt(root) == before, 'changed fixture retained for manual review'
    for path in sorted(before, key=lambda p: len(p.parts), reverse=True):
        if stat.S_ISDIR(before[path][2]): path.rmdir()
        else: path.unlink()
    assert not root.exists()



OUTPUT_LIMIT = 65_536
JOURNAL_LIMIT = 64 * 2049


class BoundedOutput:
    def __init__(self, limit=OUTPUT_LIMIT):
        self.limit = limit
        self.data = bytearray()
        self.received = 0

    def append(self, data):
        self.received += len(data)
        self.data.extend(data[:max(0, self.limit - len(self.data))])

    @property
    def truncated(self):
        return self.received > self.limit


class ChildCapture:
    """Drain both pipes during observation and finalization; never retain unbounded output."""
    def __init__(self, child):
        self.streams = {'stdout': BoundedOutput(), 'stderr': BoundedOutput()}
        self.selector = selectors.DefaultSelector()
        self.pipes = [child.stdout, child.stderr]
        for name, pipe in zip(self.streams, self.pipes):
            os.set_blocking(pipe.fileno(), False)
            self.selector.register(pipe, selectors.EVENT_READ, name)

    def pump(self, timeout=0):
        for key, _ in self.selector.select(timeout):
            try:
                data = os.read(key.fileobj.fileno(), 4096)
            except BlockingIOError:
                continue
            if data:
                self.streams[key.data].append(data)
            else:
                self.selector.unregister(key.fileobj)

    @property
    def overflowed(self):
        return any(stream.truncated for stream in self.streams.values())

    def finish(self):
        deadline = time.monotonic() + 1
        while self.selector.get_map() and time.monotonic() < deadline:
            self.pump(min(0.05, max(0, deadline - time.monotonic())))
        if self.selector.get_map():
            raise RuntimeError('child pipe drain deadline exceeded; available prefix retained')

    def close(self):
        self.selector.close()
        for pipe in self.pipes:
            pipe.close()


def error_record(error):
    return {'type': type(error).__name__, 'message': str(error)[:2048]}


def journal_snapshot(trace):
    """Read only the own fixed journal, preserving a bounded raw prefix even when JSON is malformed."""
    try:
        fd = os.open(trace, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return b'', {'journalPresent': False, 'journalTruncated': False}
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_nlink != 1:
            raise RuntimeError('own journal type/ownership/link conflict; fixture retained')
        raw = bytearray()
        while len(raw) <= JOURNAL_LIMIT:
            part = os.read(fd, min(4096, JOURNAL_LIMIT + 1 - len(raw)))
            if not part:
                break
            raw.extend(part)
        return bytes(raw[:JOURNAL_LIMIT]), {'journalPresent': True, 'journalTruncated': len(raw) > JOURNAL_LIMIT}
    finally:
        os.close(fd)


class RunnerFailure(RuntimeError):
    def __init__(self, state, outcome_path):
        self.state = state
        super().__init__(f"{state['primaryError']}; diagnostics: {outcome_path}; fixture retained unless cleanupState says removed")


def supervise_case(root, name, fixture, trace, child, monitor, verify, capture_factory=ChildCapture):
    """Every post-spawn path reaps/drains/persists before reporting its primary error.

    monitor/verify injection exists only for deterministic tests, never for CLI input.
    """
    state = {'case': name, 'clientPID': child.pid, 'clientExit': None, 'clientReaped': False,
             'servicePID': None, 'serviceExitObserved': False, 'cancelled': False,
             'cleanupState': 'retained', 'fixtureRemoved': False, 'primaryError': None, 'secondaryErrors': []}
    primary = None
    result = None
    capture = None
    raw = b''
    try:
        capture = capture_factory(child)
        monitor(state, capture)
    except BaseException as error:
        primary = error
    finally:
        # Only the owned Popen child is ever signalled. Failed service observation grants no PID authority.
        try:
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait(timeout=1)
            else:
                child.wait(timeout=0)
            state['clientReaped'] = True
        except BaseException as error:
            state['secondaryErrors'].append(dict(phase='child-reap', **error_record(error)))
        state['clientExit'] = child.returncode
        if capture is None:
            # Initialization failure still gets a second attempt to drain the now-stopped owned child.
            try:
                capture = capture_factory(child)
            except BaseException as error:
                state['secondaryErrors'].append(dict(phase='capture-init', **error_record(error)))
        if capture is not None:
            try:
                capture.finish()
            except BaseException as error:
                state['secondaryErrors'].append(dict(phase='pipe-drain', **error_record(error)))
        outputs = {}
        for stream in ('stdout', 'stderr'):
            value = capture.streams[stream] if capture is not None else BoundedOutput()
            outputs[stream] = bytes(value.data)
            state[stream] = {'capturedBytes': len(value.data), 'observedBytes': value.received,
                             'truncated': value.truncated, 'captureAvailable': capture is not None}
        if capture is not None:
            try:
                capture.close()
            except BaseException as error:
                state['secondaryErrors'].append(dict(phase='capture-close', **error_record(error)))
        try:
            raw, metadata = journal_snapshot(trace)
            state.update(metadata)
        except BaseException as error:
            state['journalPresent'] = None
            state['journalTruncated'] = None
            state['secondaryErrors'].append(dict(phase='journal-capture', **error_record(error)))
        # Do not parse the journal or assert any oracle before all available bytes have been saved.
        for suffix, data in [('client.json', outputs['stdout']), ('stderr.txt', outputs['stderr']), ('server.jsonl', raw)]:
            try:
                (root / f'{name}-{suffix}').write_bytes(data)
            except BaseException as error:
                state['secondaryErrors'].append(dict(phase='persist-' + suffix, **error_record(error)))
    if primary is None and (state['secondaryErrors'] or any(state[s]['truncated'] for s in ('stdout', 'stderr'))):
        primary = RuntimeError('runner finalization incomplete or output bound exceeded')
    if primary is None:
        try:
            result = verify(state, outputs['stdout'], outputs['stderr'], raw)
        except BaseException as error:
            primary = error
    state['fixtureRemoved'] = not fixture.exists()
    state['cleanupState'] = 'removed' if state['fixtureRemoved'] else 'retained'
    state['primaryError'] = error_record(primary) if primary is not None else None
    outcome = root / f'{name}-outcome.json'
    try:
        outcome.write_text(json.dumps(state, indent=2))
    except BaseException as error:
        state['secondaryErrors'].append(dict(phase='persist-outcome', **error_record(error)))
        if primary is None:
            primary = error
            state['primaryError'] = error_record(error)
    if primary is not None:
        raise RunnerFailure(state, outcome) from primary
    return result


def case(root, binaries, expected, name):
    work = root / name
    work.mkdir(mode=0o700)
    app = work / 'Fixture.app'
    contents = app / 'Contents'
    (contents / 'MacOS').mkdir(parents=True)
    records = work / 'Control'
    records.mkdir(mode=0o700)
    client = contents / 'MacOS' / 'xpc-probe'
    shutil.copy2(binaries / 'xpc-probe', client)
    plist(contents / 'Info.plist', {'CFBundleIdentifier': CLIENT_ID, 'CFBundleExecutable': 'xpc-probe',
          'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1',
          'SanjboxFixtureScenario': 'wait' if name in ('deadline', 'cancel-client') else 'normal'})
    empty = work / 'empty.plist'
    plist(empty, {})
    service = contents / 'XPCServices' / 'FixtureService.xpc'
    (service / 'Contents' / 'MacOS').mkdir(parents=True)
    shutil.copy2(binaries / 'xpc-fixture-service', service / 'Contents' / 'MacOS' / 'xpc-fixture-service')
    run_id = str(uuid.uuid4()).upper()
    with (root / f'{name}-signing.log').open('w') as log:
        service_info = {'CFBundleIdentifier': SERVICE_ID, 'CFBundleExecutable': 'xpc-fixture-service',
            'CFBundlePackageType': 'XPC!', 'CFBundleVersion': '1',
            'XPCService': {'ServiceType': 'Application', 'RunLoopType': 'dispatch_main', 'JoinExistingSession': True},
            'SanjboxFixtureExpectation': json.dumps(expected, separators=(',', ':')),
            'SanjboxFixtureRunID': run_id}
        if name == 'wrong-peer-session':
            service_info['SanjboxFixturePeerASID'] = expected['auditSessionID'] + 1
        plist(service / 'Contents' / 'Info.plist', service_info)
        service_hash = seal(service, SERVICE_ID, empty, log)
        client_hash = seal(app, CLIENT_ID, empty, log)
    policy_file = records / 'client-codehash'
    policy_file.write_text('0' * 40 if name == 'wrong-signature' else client_hash)
    policy_file.chmod(0o400)
    expectation = dict(expected, xpc={'runID': str(uuid.uuid4()).upper() if name == 'cross-run' else run_id,
                                    'clientCodeHash': client_hash, 'serviceCodeHash': service_hash})
    if name == 'identity-mismatch':
        expectation['auditSessionID'] += 1
    (root / f'{name}-preregistration.json').write_text(json.dumps({
        'expectation': expectation, 'serviceRunID': run_id, 'case': name,
        'serviceActivationExpected': name != 'identity-mismatch',
        'expectedOperations': 2 if name == 'positive-denials-positive' else 0,
        'expectedExit': 0 if name == 'positive-denials-positive' else -15 if name == 'cancel-client' else 3}, indent=2))
    baseline = receipt(work)
    trace = records / 'server.jsonl'
    marker = records / 'observer-ready'
    child = subprocess.Popen([str(client), '--apply', '--expect-json', json.dumps(expectation)],
                             stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             env={'PATH': '/usr/bin:/bin', 'LC_ALL': 'C'})

    def monitor(state, capture):
        queue = select.kqueue()
        try:
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                capture.pump()
                if capture.overflowed:
                    raise RuntimeError('client output bound exceeded; bounded prefix retained')
                raw, metadata = journal_snapshot(trace)
                if metadata['journalTruncated']:
                    raise RuntimeError('server journal bound exceeded; bounded prefix retained')
                # The finalizer preserves partial/malformed bytes even if this parser raises.
                events = [json.loads(line) for line in raw.splitlines(keepends=True) if line.endswith(b'\n')]
                starts = [e for e in events if e['event'] == 'serviceStart']
                if state['servicePID'] is None and starts:
                    assert len(starts) == 1 and starts[0]['codeHash'] == service_hash and starts[0]['runID'] == run_id
                    service_pid = int(starts[0]['pid'])
                    assert service_pid > 0 and service_pid != child.pid
                    state['servicePID'] = service_pid
                    queue.control([select.kevent(service_pid, filter=select.KQ_FILTER_PROC,
                                  flags=select.KQ_EV_ADD | select.KQ_EV_ENABLE, fflags=select.KQ_NOTE_EXIT)], 0, 0)
                    pending = records / 'observer-ready-pending'
                    with pending.open('x') as output:
                        output.write(run_id)
                    pending.chmod(0o400)
                    os.link(pending, marker)
                    pending.unlink()
                if state['servicePID'] is not None and not state['serviceExitObserved']:
                    signals = queue.control([], 1, 0)
                    if signals:
                        assert signals[0].ident == state['servicePID'] and signals[0].fflags & select.KQ_NOTE_EXIT
                        assert not signals[0].flags & select.KQ_EV_ERROR
                        state['serviceExitObserved'] = True
                if name == 'cancel-client' and not state['cancelled'] and any(e['event'] == 'replyWithheld' for e in events):
                    child.terminate()
                    state['cancelled'] = True
                if child.poll() is not None:
                    if name == 'identity-mismatch':
                        return  # verify requires a self-gate mismatch and no service/journal activation.
                    if state['servicePID'] is None:
                        raise RuntimeError('client exited before service activation; inspect saved client identity report')
                    if state['serviceExitObserved']:
                        return
                time.sleep(0.005)
            raise RuntimeError('service exit not observed; retained fixture requires review')
        finally:
            queue.close()

    def verify(state, stdout, stderr, raw):
        assert state['clientReaped']
        if name == 'identity-mismatch':
            report = json.loads(stdout)
            assert child.returncode == 3 and report['status'] == 'invalidMeasurement'
            assert report['acceptanceEvidence'] is False and 'auditSessionID (exact)' in report['mismatches']
            assert report['context']['audit']['sessionID'] == expected['auditSessionID']
            assert state['servicePID'] is None and not state['journalPresent'] and raw == b''
            assert not marker.exists()
            assert receipt(work) == baseline
            cleanup(work, baseline)
            return {'case': name, 'runID': run_id, 'operations': 0, 'clientExit': child.returncode,
                    'serviceExitObserved': None, 'noServiceActivated': True, 'clientReaped': True, 'fixtureRemoved': True}
        assert state['serviceExitObserved'], 'service exit not observed'
        assert raw.endswith(b'\n')
        events = [json.loads(line) for line in raw.splitlines()]
        assert [int(e['sequence']) for e in events] == list(range(1, len(events) + 1))
        assert len(events) <= 64 and all(len(line) <= 2048 for line in raw.splitlines())
        operations = [e for e in events if e['event'] == 'operation']
        assert len(operations) == (2 if name == 'positive-denials-positive' else 0)
        for index, event in enumerate(events):
            if event['event'] == 'operation':
                assert index > 0 and events[index - 1]['event'] == 'messageAuthenticated'
                assert event['runID'] == run_id and event['operation'] == 'read-canary'
            if event['event'] == 'connectionObserved':
                assert int(event['pid']) == child.pid
                assert int(event['euid']) == expected['effectiveUID']
                assert int(event['egid']) == expected['effectiveGID']
                assert int(event['asid']) == expected['auditSessionID']
        exit_record = any(e['event'] == 'serviceExit' for e in events)
        assert b'SANJBOX-A4-' not in stdout and b'SANJBOX-A4-' not in stderr
        if name == 'cancel-client':
            assert state['cancelled'] and child.returncode == -15
        else:
            report = json.loads(stdout)
            assert report['acceptanceEvidence'] is False
            assert child.returncode == (0 if name == 'positive-denials-positive' else 3)
            assert report['status'] == ('fixturePassed' if child.returncode == 0 else 'invalidMeasurement')
        if name == 'wrong-signature':
            assert not any(e['event'] in ('messageAuthenticated', 'operation') for e in events)
        if name == 'wrong-peer-session':
            assert any(e['event'] == 'connectionCredentialsDenied' for e in events)
            assert not any(e['event'] == 'messageAuthenticated' for e in events)
        if name in ('deadline', 'cancel-client'):
            assert sum(e['event'] == 'replyWithheld' for e in events) == 1
            if name == 'deadline':
                assert any(e['event'] == 'serviceExit' and e['reason'] == 'fixed-watchdog' for e in events)
        if name == 'positive-denials-positive':
            assert sum(e['event'] == 'operationDenied' for e in events) == 5
        final = receipt(work)
        assert {p: value for p, value in final.items() if p not in (trace, marker)} == baseline
        assert marker.read_text() == run_id and marker.stat().st_mode & 0o7777 == 0o400
        cleanup(work, final)
        return {'case': name, 'runID': run_id, 'operations': len(operations), 'clientExit': child.returncode,
                'serviceExitObserved': True, 'serviceExitRecord': exit_record, 'clientReaped': True, 'fixtureRemoved': True}

    return supervise_case(root, name, work, trace, child, monitor, verify)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--expect-json')
    args = parser.parse_args()
    if not args.apply:
        assert args.expect_json is None
        print('Dry run: build/test Release in a new private scratch, seal only own binaries; run six bundled XPC cases and one signed self-identity rejection; observe service exits and reap own clients; remove verified temporary bundles; retain raw results. No launchctl, service installation, root, TCC or global service lookup.')
        return
    assert args.expect_json and len(args.expect_json.encode()) <= 16384
    expected = json.loads(args.expect_json)
    assert isinstance(expected, dict) and 'xpc' not in expected and expected.get('scope') == 'synthetic-self-fixture'
    root = Path(tempfile.mkdtemp(prefix='sanjbox-a4-xpc-validation-', dir='/private/tmp'))
    print(f'Validation root: {root}', flush=True)
    (root / 'preregistered-self.json').write_text(args.expect_json)
    environment = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(root / 'clang'), SWIFTPM_MODULECACHE_OVERRIDE=str(root / 'modules'))
    swift = ['/usr/bin/swift', 'test', '--build-system', 'native', '--configuration', 'release',
             '--package-path', str(PACKAGE), '--scratch-path', str(root / 'build'), '--cache-path', str(root / 'cache'),
             '--disable-sandbox', '-Xswiftc', '-module-cache-path', '-Xswiftc', str(root / 'modules')]
    with (root / 'release-tests.log').open('w') as log:
        run(swift, stdout=log, stderr=subprocess.STDOUT, env=environment)
    binary_path = run([*swift[:1], 'build', *swift[2:], '--show-bin-path'], capture_output=True, text=True, env=environment).stdout.strip()
    with (root / 'runner-tests.log').open('w') as log:
        run(['python3', '-m', 'unittest', 'discover', '-s', str(PACKAGE / 'Tests/RunnerTests'), '-v'],
            stdout=log, stderr=subprocess.STDOUT)
    results = []
    for name in ('positive-denials-positive', 'wrong-signature', 'wrong-peer-session', 'cross-run', 'deadline', 'cancel-client', 'identity-mismatch'):
        result = case(root, Path(binary_path), expected, name)
        results.append(result)
        print(json.dumps(result), flush=True)
    (root / 'results.json').write_text(json.dumps(results, indent=2))
    print(f'PASS: 6 live XPC cases plus 1 signed identity rejection, no skips. Raw records retained: {root}', flush=True)


if __name__ == '__main__':
    main()
