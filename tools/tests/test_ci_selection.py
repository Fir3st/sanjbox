"""Execute the actual CI package selector against controlled Git output and manifest fixtures."""

import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / '.github/workflows/ci.yml'


def discovery_source():
    lines = WORKFLOW.read_text(encoding='utf-8').splitlines()
    start = lines.index("          python3 - <<'PY'") + 1
    end = lines.index('          PY', start)
    return textwrap.dedent('\n'.join(lines[start:end]))


class CISelectionTests(unittest.TestCase):
    manifests = {
        'spikes/common/Package.swift': 'let package = Package(name: "common")',
        'spikes/s4-state/Package.swift': '.package(path: "../common")',
        # Deliberately NO runtime edge from H1 to B3.
        'proto/contracts/Package.swift': 'let package = Package(name: "SanjboxContracts")',
        # Synthetic downstream package checks ordinary dependency traversal after parity selection.
        'proto/consumer/Package.swift': '.package(path: "../contracts")',
        'spikes/unrelated/Package.swift': 'let package = Package(name: "unrelated")',
    }

    def select(self, changed, event='pull_request', parents=3, manifests=None):
        manifests = self.manifests if manifests is None else manifests
        source = discovery_source()
        calls = []
        real_open = open

        def fixture_git(command, **kwargs):
            calls.append(command)
            if command == ['git', 'ls-files', '-z']:
                output = '\0'.join(manifests) + '\0'
            elif command == ['git', 'rev-list', '--parents', '-n', '1', 'HEAD']:
                output = ' '.join(['merge', 'base', 'topic'][:parents]) + '\n'
            elif command == ['git', 'diff', '--no-renames', '--name-only', 'HEAD^1', 'HEAD']:
                output = '\n'.join(changed) + '\n'
            else:
                self.fail('Unexpected Git query: ' + repr(command))
            return subprocess.CompletedProcess(command, 0, output, '')

        def fixture_open(path, *args, **kwargs):
            if str(path) in manifests:
                return io.StringIO(manifests[str(path)])
            return real_open(path, *args, **kwargs)

        with tempfile.TemporaryDirectory(prefix='sanjbox-ci-selection-') as directory:
            result_path = Path(directory) / 'outputs'
            with mock.patch.dict(os.environ, EVENT=event, GITHUB_OUTPUT=str(result_path)), \
                 mock.patch('subprocess.run', side_effect=fixture_git), \
                 mock.patch('builtins.open', side_effect=fixture_open), \
                 contextlib.redirect_stdout(io.StringIO()):
                exec(compile(source, str(WORKFLOW) + ':discover', 'exec'), {'__name__': '__main__'})
            outputs = dict(line.split('=', 1) for line in result_path.read_text().splitlines())
        packages = json.loads(outputs['matrix'])['package']
        self.assertEqual(outputs['run'], 'true' if packages else 'false')
        self.assertEqual(packages, sorted(set(packages)))
        return set(packages), calls

    def test_b3_only_sources_examples_and_schema_select_h1_and_dependents(self):
        for path in [
            'spikes/s4-state/Sources/StateManifest/Manifest.swift',
            'spikes/s4-state/Sources/StateManifest/Paths.swift',
            'spikes/s4-state/Sources/StateManifest/Validation.swift',
            'spikes/s4-state/Sources/StateManifest/Schema.swift',
            'spikes/s4-state/Sources/StateManifest/NewRule.swift',
            'spikes/s4-state/examples/mvp.state-manifest.json',
            'spikes/s4-state/examples/f4.state-manifest.json',
            'spikes/s4-state/SCHEMA.md',
        ]:
            with self.subTest(path=path):
                packages, _ = self.select([path])
                self.assertEqual(packages, {'spikes/s4-state', 'proto/contracts', 'proto/consumer'})

    def test_deletion_or_move_out_of_b3_still_selects_h1(self):
        # --no-renames supplies the old deleted path even when the destination has another owner.
        old = 'spikes/s4-state/Sources/StateManifest/Validation.swift'
        for changed in [[old], [old, 'spikes/unrelated/Validation.swift']]:
            with self.subTest(changed=changed):
                packages, calls = self.select(changed)
                self.assertIn('proto/contracts', packages)
                self.assertIn('spikes/s4-state', packages)
                self.assertIn(['git', 'diff', '--no-renames', '--name-only', 'HEAD^1', 'HEAD'], calls)

    def test_unrelated_changes_do_not_select_parity_consumer(self):
        for changed, expected in [
            (['spikes/s4-state/README.md'], {'spikes/s4-state'}),
            (['spikes/s4-state/Tests/StateManifestTests/RecoveryTests.swift'], {'spikes/s4-state'}),
            (['spikes/unrelated/Probe.swift'], {'spikes/unrelated'}),
            (['docs/GUIDE.md'], set()),
        ]:
            with self.subTest(changed=changed):
                packages, _ = self.select(changed)
                self.assertEqual(packages, expected)

    def test_runtime_dependency_selection_is_preserved(self):
        packages, _ = self.select(['spikes/common/Sources/Fixture.swift'])
        self.assertEqual(packages, {'spikes/common', 'spikes/s4-state'})
        packages, _ = self.select(['proto/contracts/Sources/Example.swift'])
        self.assertEqual(packages, {'proto/contracts', 'proto/consumer'})

    def test_ci_changes_and_non_pr_events_select_every_package(self):
        all_packages = {str(Path(path).parent) for path in self.manifests}
        packages, _ = self.select(['.github/workflows/ci.yml'])
        self.assertEqual(packages, all_packages)
        for event in ['push', 'merge_group', 'workflow_dispatch']:
            with self.subTest(event=event):
                packages, calls = self.select(['docs/GUIDE.md'], event=event)
                self.assertEqual(packages, all_packages)
                self.assertFalse(any(command[1] == 'diff' for command in calls))
        packages, _ = self.select(['docs/GUIDE.md'], parents=2)
        self.assertEqual(packages, all_packages)

    def test_missing_parity_package_fails_discovery(self):
        manifests = {key: value for key, value in self.manifests.items() if not key.startswith('proto/')}
        with self.assertRaisesRegex(SystemExit, 'require the proto/contracts parity test package'):
            self.select(['spikes/s4-state/Sources/StateManifest/Validation.swift'], manifests=manifests)

    def test_missing_or_invalid_package_graph_still_fails(self):
        with self.assertRaisesRegex(SystemExit, 'No Swift packages found'):
            self.select([], manifests={})
        with self.assertRaisesRegex(SystemExit, 'depends on unknown package'):
            self.select([], manifests={'proto/broken/Package.swift': '.package(path: "../absent")'})


if __name__ == '__main__':
    unittest.main()
