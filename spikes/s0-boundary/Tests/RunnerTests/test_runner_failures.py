"""Deterministic failure-finalization tests. No XPC activation or external process/PID input."""
import json
from pathlib import Path
import runpy
import tempfile
import unittest

RUNNER = runpy.run_path(str(Path(__file__).resolve().parents[2] / 'validate-xpc.py'))
BoundedOutput = RUNNER['BoundedOutput']
RunnerFailure = RUNNER['RunnerFailure']
supervise = RUNNER['supervise_case']


class FakeChild:
    pid = 123  # Synthetic metadata only; this test never passes it to any OS API.

    def __init__(self, returncode=3, wait_error=None):
        self.returncode = returncode
        self.wait_error = wait_error
        self.signals = []

    def poll(self):
        return self.returncode

    def terminate(self):
        self.signals.append('terminate')

    def kill(self):
        self.signals.append('kill')

    def wait(self, timeout):
        if self.wait_error:
            raise self.wait_error
        return self.returncode


class FakeCapture:
    def __init__(self, stdout, stderr, drain_error=None):
        self.streams = {'stdout': BoundedOutput(), 'stderr': BoundedOutput()}
        self.streams['stdout'].append(stdout)
        self.streams['stderr'].append(stderr)
        self.drain_error = drain_error
        self.closed = False

    def finish(self):
        if self.drain_error:
            raise self.drain_error

    def close(self):
        self.closed = True


class RunnerFailureTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='sanjbox-a4-runner-unit-', dir='/private/tmp')
        self.root = Path(self.temporary.name)
        self.fixture = self.root / 'owned-fixture'
        self.fixture.mkdir()
        self.trace = self.fixture / 'server.jsonl'
        self.stdout = json.dumps({'status': 'invalidMeasurement', 'acceptanceEvidence': False,
                                  'context': {'audit': {'sessionID': 100002}},
                                  'mismatches': ['auditSessionID (exact)']}).encode()
        self.stderr = b'synthetic client diagnostic\n'
        self.capture = FakeCapture(self.stdout, self.stderr)
        self.child = FakeChild()

    def tearDown(self):
        self.temporary.cleanup()  # Only this test's freshly created synthetic files.

    def invoke(self, monitor, verify=None):
        if verify is None:
            def verify(*args):
                self.fail('failed observation must not run cleanup/verification')
        return supervise(self.root, 'case', self.fixture, self.trace, self.child,
                         monitor, verify, capture_factory=lambda child: self.capture)

    def saved(self):
        self.assertEqual((self.root / 'case-client.json').read_bytes(), bytes(self.capture.streams['stdout'].data))
        self.assertEqual((self.root / 'case-stderr.txt').read_bytes(), self.stderr)
        self.assertTrue(self.capture.closed)
        return json.loads((self.root / 'case-outcome.json').read_text())

    def test_identity_rejection_without_service_preserves_context(self):
        def monitor(state, capture):
            raise RuntimeError('client exited before service activation')
        with self.assertRaises(RunnerFailure):
            self.invoke(monitor)
        state = self.saved()
        self.assertEqual(json.loads((self.root / 'case-client.json').read_bytes())['mismatches'], ['auditSessionID (exact)'])
        self.assertEqual((self.root / 'case-server.jsonl').read_bytes(), b'')
        self.assertFalse(state['journalPresent'])
        self.assertEqual(state['clientExit'], 3)
        self.assertTrue(state['clientReaped'])
        self.assertFalse(state['serviceExitObserved'])
        self.assertEqual(state['cleanupState'], 'retained')
        self.assertEqual(self.child.signals, [])

    def test_registration_failure_keeps_primary_and_available_journal(self):
        raw = b'{"event":"serviceStart","pid":"456"}\n'
        self.trace.write_bytes(raw)
        def monitor(state, capture):
            state['servicePID'] = 456
            raise ProcessLookupError('synthetic NOTE_EXIT registration failure')
        with self.assertRaises(RunnerFailure):
            self.invoke(monitor)
        state = self.saved()
        self.assertEqual(state['primaryError']['type'], 'ProcessLookupError')
        self.assertEqual((self.root / 'case-server.jsonl').read_bytes(), raw)
        self.assertFalse(state['serviceExitObserved'])
        self.assertTrue(self.fixture.exists())

    def test_malformed_journal_raw_is_saved_before_parser_error_is_reported(self):
        raw = b'{not-json}\npartial-tail'
        self.trace.write_bytes(raw)
        def monitor(state, capture):
            json.loads(raw)
        with self.assertRaises(RunnerFailure):
            self.invoke(monitor)
        state = self.saved()
        self.assertEqual(state['primaryError']['type'], 'JSONDecodeError')
        self.assertEqual((self.root / 'case-server.jsonl').read_bytes(), raw)

    def test_missing_exit_does_not_erase_client_output(self):
        self.trace.write_bytes(b'{"event":"replyWithheld"}\n')
        def monitor(state, capture):
            state['servicePID'] = 456
            raise RuntimeError('service exit not observed')
        with self.assertRaises(RunnerFailure):
            self.invoke(monitor)
        state = self.saved()
        self.assertEqual(state['primaryError']['message'], 'service exit not observed')
        self.assertTrue(state['clientReaped'])
        self.assertFalse(state['serviceExitObserved'])

    def test_cleanup_conflict_preserves_raw_before_verification_raises(self):
        raw = b'{"event":"serviceExit"}\n'
        self.trace.write_bytes(raw)
        def monitor(state, capture):
            state['serviceExitObserved'] = True
        def verify(state, stdout, stderr, journal):
            self.assertEqual((self.root / 'case-server.jsonl').read_bytes(), raw)
            self.assertEqual((self.root / 'case-client.json').read_bytes(), self.stdout)
            raise RuntimeError('synthetic changed fixture conflict')
        with self.assertRaises(RunnerFailure):
            self.invoke(monitor, verify)
        state = self.saved()
        self.assertEqual(state['primaryError']['message'], 'synthetic changed fixture conflict')
        self.assertTrue(state['serviceExitObserved'])
        self.assertEqual(state['cleanupState'], 'retained')
        self.assertTrue(self.trace.exists())

    def test_reap_error_is_secondary_to_original_observation_error(self):
        self.child = FakeChild(returncode=None, wait_error=RuntimeError('synthetic wait failure'))
        def monitor(state, capture):
            raise ValueError('original failure')
        with self.assertRaises(RunnerFailure):
            self.invoke(monitor)
        state = self.saved()
        self.assertEqual(state['primaryError']['message'], 'original failure')
        self.assertFalse(state['clientReaped'])
        self.assertEqual(state['secondaryErrors'][0]['phase'], 'child-reap')
        self.assertEqual(self.child.signals, ['terminate'])

    def test_drain_error_preserves_existing_prefix_and_primary(self):
        self.capture.drain_error = RuntimeError('synthetic drain timeout')
        def monitor(state, capture):
            raise ValueError('original failure')
        with self.assertRaises(RunnerFailure):
            self.invoke(monitor)
        state = self.saved()
        self.assertEqual(state['primaryError']['message'], 'original failure')
        self.assertEqual(state['secondaryErrors'][0]['phase'], 'pipe-drain')

    def test_output_collector_retains_only_bounded_prefix(self):
        output = BoundedOutput(limit=8)
        output.append(b'1234')
        output.append(b'56789012')
        self.assertEqual(bytes(output.data), b'12345678')
        self.assertEqual(output.received, 12)
        self.assertTrue(output.truncated)

    def test_oversized_journal_is_saved_as_bounded_prefix(self):
        raw = b'x' * (RUNNER['JOURNAL_LIMIT'] + 64)
        self.trace.write_bytes(raw)
        def monitor(state, capture):
            raise RuntimeError('journal bound exceeded')
        with self.assertRaises(RunnerFailure):
            self.invoke(monitor)
        state = self.saved()
        self.assertTrue(state['journalTruncated'])
        self.assertEqual((self.root / 'case-server.jsonl').read_bytes(), raw[:RUNNER['JOURNAL_LIMIT']])

    def test_output_overflow_cannot_be_reported_as_success(self):
        self.capture.streams['stdout'].append(b'x' * RUNNER['OUTPUT_LIMIT'])
        with self.assertRaises(RunnerFailure):
            self.invoke(lambda state, capture: None)
        state = self.saved()
        self.assertTrue(state['stdout']['truncated'])
        self.assertEqual(state['stdout']['capturedBytes'], RUNNER['OUTPUT_LIMIT'])
        self.assertIsNotNone(state['primaryError'])

    def test_one_artifact_error_does_not_prevent_other_artifacts(self):
        (self.root / 'case-client.json').mkdir()
        self.trace.write_bytes(b'available raw\n')
        def monitor(state, capture):
            raise ValueError('original failure')
        with self.assertRaises(RunnerFailure):
            self.invoke(monitor)
        state = json.loads((self.root / 'case-outcome.json').read_text())
        self.assertEqual(state['primaryError']['message'], 'original failure')
        self.assertEqual((self.root / 'case-stderr.txt').read_bytes(), self.stderr)
        self.assertEqual((self.root / 'case-server.jsonl').read_bytes(), b'available raw\n')
        self.assertEqual(state['secondaryErrors'][0]['phase'], 'persist-client.json')

    def test_success_runs_verification_only_after_output_is_saved(self):
        def verify(state, stdout, stderr, raw):
            self.assertEqual((self.root / 'case-client.json').read_bytes(), self.stdout)
            self.fixture.rmdir()
            return 'verified'
        self.assertEqual(self.invoke(lambda state, capture: None, verify), 'verified')
        state = self.saved()
        self.assertIsNone(state['primaryError'])
        self.assertTrue(state['fixtureRemoved'])
        self.assertEqual(state['cleanupState'], 'removed')


if __name__ == '__main__':
    unittest.main()
