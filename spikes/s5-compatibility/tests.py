#!/usr/bin/python3
"""Native stdlib-only negative fixtures and CLI checks. No clients/network."""
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('compatibility_matrix', HERE / 'matrix.py')
matrix = importlib.util.module_from_spec(spec)
spec.loader.exec_module(matrix)

def select(value, component):
    if isinstance(component, dict):
        return next(x for x in value if x['id'] == component['id'])
    return value[component]

def mutate(document, case):
    path = case['path']
    parent = document
    for component in path[:-1]:
        parent = select(parent, component)
    key = path[-1]
    action = case['action']
    if action == 'set':
        parent[key] = copy.deepcopy(case['value'])
    elif action == 'delete':
        del parent[key]
    elif action in ('remove-id', 'duplicate-id'):
        target = select(parent, key)
        item = next(x for x in target if x['id'] == case['value'])
        if action == 'remove-id':
            target.remove(item)
        else:
            target.append(copy.deepcopy(item))
    else:
        raise AssertionError('Unknown fixture action')

class MatrixTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.good = matrix.load_json(HERE / 'matrix.json')
        cls.sources = matrix.load_json(HERE / 'sources.json')

    def test_complete_matrix_and_exact_baseline_counts(self):
        matrix.validate(self.good, self.sources)
        self.assertEqual(len(self.good['rows']), 50)
        observed = {r['profile'] for r in self.good['rows'] if r['baseline']['status'] == 'fixture_only'}
        self.assertEqual(observed, {'npm', 'sse'})
        self.assertEqual({r['profile'] for r in self.good['rows'] if r['proposed_d5'] and r['proposed_d5']['status'] == 'fixture_only'}, {'pip', 'git-http'})

    def test_all_negative_fixtures_reject_for_the_intended_reason(self):
        cases = matrix.load_json(HERE / 'fixtures' / 'invalid-cases.json')
        self.assertEqual(len(cases), 28)
        self.assertEqual(len({c['id'] for c in cases}), len(cases))
        for case in cases:
            with self.subTest(case=case['id']):
                good, sources = copy.deepcopy(self.good), copy.deepcopy(self.sources)
                mutate(good if case['target'] == 'matrix' else sources, case)
                with self.assertRaisesRegex(matrix.Invalid, case['error']):
                    matrix.validate(good, sources)

    def test_generated_report_matches_committed_artifact(self):
        self.assertEqual(matrix.markdown_report(self.good, self.sources), (HERE / 'REPORT.md').read_text())

    def test_report_contains_every_client_and_keeps_proposal_visible(self):
        report = matrix.markdown_report(self.good, self.sources)
        for pid, (tool, protocol) in matrix.CATALOG.items():
            self.assertIn('### ' + tool + ' — ' + protocol, report)
        self.assertIn(matrix.BASELINE, report)
        self.assertIn(matrix.PROPOSED, report)
        self.assertIn('not rerun by D6', report)
        self.assertIn('passthrough', report.lower())

    def test_cli_runs_from_empty_directory_without_adjacent_packages(self):
        with tempfile.TemporaryDirectory(prefix='sanjbox-d6-test-') as temporary:
            result = subprocess.run([sys.executable, '-I', '-B', str(HERE / 'matrix.py'), 'validate'], cwd=temporary, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)['rows'], 50)
            report = subprocess.run([sys.executable, '-I', '-B', str(HERE / 'matrix.py'), 'report', '--format', 'json'], cwd=temporary, capture_output=True, text=True, timeout=10)
            self.assertEqual(report.returncode, 0, report.stderr)
            self.assertEqual(json.loads(report.stdout), self.good)
            self.assertEqual(list(Path(temporary).iterdir()), [])

    def test_cli_invalid_input_nonzero_and_no_report(self):
        with tempfile.TemporaryDirectory(prefix='sanjbox-d6-test-') as temporary:
            path = Path(temporary) / 'invalid.json'
            path.write_text('{"schema_version":1,"schema_version":1}')
            result = subprocess.run([sys.executable, '-I', '-B', str(HERE / 'matrix.py'), 'report', '--matrix', str(path)], cwd=temporary, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(result.stdout, '')
            self.assertIn('duplicate object key', result.stderr)

    def test_duplicate_keys_unicode_alias_nan_and_invalid_encoding(self):
        with tempfile.TemporaryDirectory(prefix='sanjbox-d6-test-') as temporary:
            path = Path(temporary) / 'input.json'
            for payload in (b'{"a":1,"a":2}', b'{"a":1,"\\u0061":2}', b'{"x":NaN}', b'{"x":Infinity}', b'\xff', b'{oops'):
                with self.subTest(payload=repr(payload)):
                    path.write_bytes(payload)
                    with self.assertRaises(matrix.Invalid):
                        matrix.load_json(path)

    def test_size_nesting_and_node_budgets(self):
        with tempfile.TemporaryDirectory(prefix='sanjbox-d6-test-') as temporary:
            path = Path(temporary) / 'input.json'
            for payload in (b' ' * (matrix.MAX_BYTES + 1), ('[' * 40 + '0' + ']' * 40).encode(), json.dumps([0] * 50_001).encode()):
                path.write_bytes(payload)
                with self.assertRaises(matrix.Invalid):
                    matrix.load_json(path)

    def test_nonregular_and_symlink_inputs_fail_without_reading(self):
        with tempfile.TemporaryDirectory(prefix='sanjbox-d6-test-') as temporary:
            root = Path(temporary)
            link = root / 'input.json'
            link.symlink_to(HERE / 'matrix.json')
            with self.assertRaises(OSError):
                matrix.load_json(link)
            with self.assertRaises(matrix.Invalid):
                matrix.load_json(root)

if __name__ == '__main__':
    unittest.main(verbosity=2)
