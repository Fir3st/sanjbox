#!/usr/bin/python3
"""Offline synthetic contradictions and historical-preservation checks."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('current_decisions', HERE / 'current_decisions.py')
current = importlib.util.module_from_spec(spec)
spec.loader.exec_module(current)

# Independent fingerprints from main 7b20c41496f9a8d2a8e49604e31c7598a4943adb.
# README/VALIDATION may add current entrypoints; these historical artifacts may not change.
HISTORICAL_HASHES = {
    'matrix.py': '673faba14e09fd4e4504b7fd8cc1a5299e7edc3ab11693040686459166f45035',
    'matrix.json': 'e4b5f320444fd74226746ec72ffe9b34c4ca9333bfa4f2ad43391a5077ae4c28',
    'sources.json': '6e5ec71684fd818f472110d037620541354344787e9d2062e9263834b0514818',
    'REPORT.md': '04bbda9a9fd1208d81c3ddc172e0a51ad3e801a30b0a86479aa0784fb773f129',
    'tests.py': '6d4c20e5339323fd24944f594184593c152c75d35ff1f16695320a4646470839',
    'fixtures/invalid-cases.json': '476e384a0c0d2757879b596bcdfb4e5becf80098aece4be32a72b43ae147a13b',
}
# Each case attempts a concrete broadening or false promotion of accepted scope.
ROW_CONTRADICTIONS = [
    ('claude-oauth', ('client',), 'Another client', 'client/provider/auth mismatch'),
    ('codex-oauth', ('provider_scope',), 'GitHub', 'client/provider/auth mismatch'),
    ('opencode-oauth', ('provider_scope',), 'all providers', 'client/provider/auth mismatch'),
    ('claude-oauth', ('auth_mode',), 'api_key', 'client/provider/auth mismatch'),
    ('claude-oauth', ('contract', 'opt_in'), 'global', 'decision constraints changed'),
    ('codex-oauth', ('contract', 'opt_in'), 'optional', 'decision constraints changed'),
    ('opencode-oauth', ('contract', 'opt_in'), None, 'decision constraints changed'),
    ('claude-oauth', ('contract', 'domain_scope'), 'all_provider_domains', 'decision constraints changed'),
    ('claude-oauth', ('contract', 'key_insertion'), 'host_gateway_only', 'decision constraints changed'),
    ('codex-oauth', ('contract', 'credential_custody'), 'area_safe', 'decision constraints changed'),
    ('opencode-oauth', ('contract', 'account_scope'), 'project_only', 'decision constraints changed'),
    ('claude-oauth', ('known_gaps', 'reviewed_provider_domains'), ['invented.invalid'], 'missing evidence'),
    ('codex-oauth', ('known_gaps', 'disable_and_delete_revocation'), 'verified', 'missing evidence'),
    ('opencode-oauth', ('known_gaps', 'account_identity_and_actual_scopes'), ['invented-scope'], 'missing evidence'),
    ('claude-oauth', ('known_gaps', 's5_provider_domain_exfiltration_measurement'), 'passed_r3', 'missing evidence'),
    ('claude-oauth', ('implementation_status',), 'implemented', 'accepted decision is not implementation'),
    ('codex-oauth', ('implementation_status',), 'ready', 'accepted decision is not implementation'),
    ('opencode-oauth', ('implementation_status',), 'supported', 'accepted decision is not implementation'),
    ('claude-oauth', ('implementation_evidence',), ['c003'], 'no reviewed implementation evidence'),
    ('codex-oauth', ('live_evidence',), ['f0.7'], 'no reviewed live evidence'),
    ('opencode-oauth', ('live_status',), 'verified', 'accepted decision is not live verification'),
    ('claude-oauth', ('full_r3',), 'passed', 'never establishes full R3'),
    ('codex-oauth', ('full_r3',), 'unverified', 'never establishes full R3'),
    ('opencode-oauth', ('full_r3',), 'accepted_residual_pass', 'never establishes full R3'),
    ('opencode-api-key', ('contract', 'credential_custody'), 'area', 'decision constraints changed'),
    ('opencode-api-key', ('contract', 'route'), 'tls_passthrough', 'decision constraints changed'),
    ('opencode-api-key', ('contract', 'provider_scope'), 'all_providers', 'decision constraints changed'),
    ('opencode-api-key', ('contract', 'caller_auth'), 'allowed', 'decision constraints changed'),
    ('opencode-api-key', ('contract', 'passthrough_fallback'), 'allowed', 'decision constraints changed'),
    ('opencode-api-key', ('implementation_status',), 'implemented', 'accepted decision is not implementation'),
    ('github-classic-pat', ('contract', 'credential_custody'), 'area', 'decision constraints changed'),
    ('github-classic-pat', ('contract', 'repository_scope'), 'all_account_repositories', 'decision constraints changed'),
    ('github-classic-pat', ('contract', 'operations'), ['fetch', 'push', 'api'], 'decision constraints changed'),
    ('github-classic-pat', ('contract', 'gh_cli'), 'supported', 'decision constraints changed'),
    ('github-classic-pat', ('contract', 'github_api'), 'supported', 'decision constraints changed'),
    ('github-classic-pat', ('contract', 'area_token'), 'allowed', 'decision constraints changed'),
    ('github-classic-pat', ('contract', 'route'), 'ssh', 'decision constraints changed'),
    ('github-classic-pat', ('implementation_evidence',), ['historical'], 'no reviewed implementation evidence'),
    ('xcode-simulator', ('contract', 'signing'), 'supported', 'decision constraints changed'),
    ('xcode-simulator', ('contract', 'apple_id'), 'allowed', 'decision constraints changed'),
    ('xcode-simulator', ('contract', 'app_store_connect_key'), 'allowed', 'decision constraints changed'),
    ('xcode-simulator', ('live_status',), 'verified', 'accepted decision is not live verification'),
    ('unlisted', ('decision_status',), 'accepted', 'decision scope changed'),
    ('unlisted', ('contract', 'fallback'), 'tls_passthrough', 'decision constraints changed'),
]


class CurrentDecisionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.good = current.load_json(HERE / 'current-decisions.json')

    def test_acceptance_implementation_live_and_r3_are_independent(self):
        current.validate(self.good)
        accepted = [r for r in self.good['integrations'] if r['decision_status'] == 'accepted']
        self.assertEqual(len(accepted), 6)
        self.assertEqual({r['implementation_status'] for r in accepted}, {'blocked'})
        self.assertEqual({r['live_status'] for r in accepted}, {'unverified'})
        self.assertEqual({r['id'] for r in accepted if r['full_r3'] == 'not_met_under_c003'},
                         {'claude-oauth', 'codex-oauth', 'opencode-oauth'})
        self.assertTrue(all(not r['implementation_evidence'] and not r['live_evidence'] for r in accepted))

    def test_44_synthetic_scope_and_evidence_contradictions(self):
        self.assertEqual(len(ROW_CONTRADICTIONS), 44)
        for rid, path, value, reason in ROW_CONTRADICTIONS:
            with self.subTest(integration=rid, path=path, value=value):
                document = copy.deepcopy(self.good)
                target = next(r for r in document['integrations'] if r['id'] == rid)
                for key in path[:-1]:
                    target = target[key]
                target[path[-1]] = copy.deepcopy(value)
                with self.assertRaisesRegex(current.Invalid, reason):
                    current.validate(document)

    def test_catalog_cannot_shrink_expand_duplicate_or_gain_runtime_fields(self):
        for mode in ('missing', 'new', 'duplicate', 'runtime'):
            with self.subTest(mode=mode):
                document = copy.deepcopy(self.good)
                if mode == 'missing':
                    document['integrations'].pop()
                elif mode in ('new', 'duplicate'):
                    row = copy.deepcopy(document['integrations'][0])
                    if mode == 'new':
                        row['id'] = 'unreviewed-oauth'
                    document['integrations'].append(row)
                else:
                    document['area_id'] = 'synthetic-area'
                with self.assertRaises(current.Invalid):
                    current.validate(document)

    def test_missing_opt_in_and_revocation_cannot_be_omitted(self):
        for section, field in (('contract', 'opt_in'), ('known_gaps', 'reviewed_provider_domains'),
                               ('known_gaps', 'disable_and_delete_revocation')):
            document = copy.deepcopy(self.good)
            del document['integrations'][0][section][field]
            with self.subTest(section=section, field=field), self.assertRaises(current.Invalid):
                current.validate(document)

    def test_global_gate_promotion_and_historical_revision_drift_reject(self):
        for gate in ('S5', 'GW-19', 'R3', 'R8'):
            document = copy.deepcopy(self.good)
            document['gate_status'][gate] = 'passed'
            with self.subTest(gate=gate), self.assertRaisesRegex(current.Invalid, 'not a passed gate'):
                current.validate(document)
        document = copy.deepcopy(self.good)
        document['historical']['baseline_revision'] = current.SOURCE_REVISION
        with self.assertRaisesRegex(current.Invalid, 'historical layer must remain separate'):
            current.validate(document)

    def test_source_pins_and_decision_provenance_are_required(self):
        document = copy.deepcopy(self.good)
        document['sources'][0]['revision'] = current.historical.BASELINE
        with self.assertRaisesRegex(current.Invalid, 'source pin/locator mismatch'):
            current.validate(document)
        document = copy.deepcopy(self.good)
        document['integrations'][0]['basis']['refs'] = ['historical']
        with self.assertRaisesRegex(current.Invalid, 'decision and implementation provenance required'):
            current.validate(document)

    def test_report_exact_regeneration_and_blockers_are_visible(self):
        report = current.markdown_report(self.good)
        self.assertEqual(report, (HERE / 'CURRENT-DECISIONS.md').read_text())
        reordered = json.loads(json.dumps(self.good, sort_keys=True))
        reordered['integrations'].reverse()
        reordered['sources'].reverse()
        self.assertEqual(current.markdown_report(reordered), report)
        for required in ('opt-in per area', 'closed, reviewed domain allowlist',
                         'Full R3 is not met', 'disable/delete revocation',
                         'classic PAT is not repo-scoped', 'gh CLI, GitHub API',
                         'without signing', 'Unlisted integrations remain unsupported',
                         current.historical.BASELINE, current.historical.PROPOSED):
            self.assertIn(required, report)
        for rid in current.CATALOG:
            self.assertIn('## ' + rid + '\n', report)

    def test_all_six_historical_artifacts_are_byte_unchanged(self):
        for name, expected in HISTORICAL_HASHES.items():
            with self.subTest(file=name):
                self.assertEqual(hashlib.sha256((HERE / name).read_bytes()).hexdigest(), expected)
        matrix = current.load_json(HERE / 'matrix.json')
        self.assertEqual(len(matrix['rows']), 50)
        sources = current.load_json(HERE / 'sources.json')
        self.assertEqual(current.historical.markdown_report(matrix, sources), (HERE / 'REPORT.md').read_text())

    def test_cli_runs_read_only_from_empty_directory_and_json_round_trips(self):
        with tempfile.TemporaryDirectory(prefix='sanjbox-d6-current-test-') as temporary:
            command = [sys.executable, '-I', '-B', str(HERE / 'current_decisions.py')]
            result = subprocess.run(command + ['validate'], cwd=temporary, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)['implementation_blocked'], 6)
            result = subprocess.run(command + ['report', '--format', 'json'], cwd=temporary, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout), self.good)
            result = subprocess.run(command + ['report'], cwd=temporary, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, (HERE / 'CURRENT-DECISIONS.md').read_text())
            self.assertEqual(list(Path(temporary).iterdir()), [])

    def test_cli_rejects_contradiction_and_malformed_json_without_report(self):
        bad = copy.deepcopy(self.good)
        bad['integrations'][0]['implementation_status'] = 'implemented'
        payloads = [json.dumps(bad), '{"schema_version":1,"schema_version":1}', '{"schema_version":NaN}']
        with tempfile.TemporaryDirectory(prefix='sanjbox-d6-current-test-') as temporary:
            path = Path(temporary) / 'invalid.json'
            for payload in payloads:
                path.write_text(payload)
                result = subprocess.run([sys.executable, '-I', '-B', str(HERE / 'current_decisions.py'),
                                         'report', '--decisions', str(path)], cwd=temporary,
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stdout, '')
                self.assertTrue(result.stderr.startswith('invalid: '))


if __name__ == '__main__':
    unittest.main(verbosity=2)
