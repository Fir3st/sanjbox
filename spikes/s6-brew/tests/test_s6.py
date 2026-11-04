import copy
from datetime import datetime, timezone, timedelta
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import s6
import prefix


class SelectionTests(unittest.TestCase):
    def analytics(self, rows):
        return {'category': 'formula_install', 'start_date': '2026-01-01', 'end_date': '2026-04-01',
                'items': [{'formula': name, 'count': count} for name, count in rows]}

    def test_options_aggregate_taps_excluded_ties_lexical(self):
        data = self.analytics([('z', '1,000'), ('z --HEAD', '10'), ('a', '1,010'), ('owner/tap/higher', '9,999')])
        result = s6.selection(data, 2)['formulae']
        self.assertEqual([(r['name'], r['install_events']) for r in result], [('a', 1010), ('z', 1010)])

    def test_duplicates_rejected(self):
        with self.assertRaises(ValueError):
            s6.selection(self.analytics([('a', '2'), ('a', '2')]), 1)

    def test_bad_counts_and_insufficient_rows(self):
        for count in ['1,00', '-1', 'nan', True]:
            with self.subTest(count=count), self.assertRaises(ValueError):
                s6.selection(self.analytics([('a', count)]), 1)
        with self.assertRaises(ValueError):
            s6.selection(self.analytics([('a', '1')]), 200)

    def test_no_shell_labels(self):
        with self.assertRaises(ValueError):
            s6.selection(self.analytics([('a ; touch /tmp/x', '1')]), 1)

    def test_duplicate_json_key_refused(self):
        with self.assertRaises(ValueError):
            s6.decode('{"installed":[],"installed":[1]}')

    def test_pinned_dataset_and_sample(self):
        chosen, formulae = s6.pinned_inputs()
        self.assertEqual(len(chosen['formulae']), 200)
        self.assertEqual(len(formulae), 200)
        chosen_sample = s6.sample(chosen)
        self.assertEqual(len(set(chosen_sample)), 20)
        for start in range(0, 200, 50):
            self.assertEqual(len(set(chosen_sample) & {r['name'] for r in chosen['formulae'][start:start + 50]}), 5)
        self.assertEqual(s6.sample(chosen), chosen_sample)


class PlanTests(unittest.TestCase):
    def setUp(self):
        self.chosen, self.formulae = s6.pinned_inputs()
        self.manifest = s6.read(s6.BASE.parent / 's4-state/examples/mvp.state-manifest.json')

    def test_plan_covers_manifest_without_claiming_deployment(self):
        result = s6.plan(self.chosen, self.formulae, self.manifest, 'arm64_golden_gate')
        self.assertFalse(result['executable'])
        self.assertEqual(result['acceptance_status'], 'Neověřeno')
        self.assertEqual(len(result['formula_commands']), 200)
        self.assertEqual(len(result['cask_commands']), 2)
        self.assertTrue(all(c[0] == '/opt/snj/t001/bin/brew' for c in result['test_commands']))
        self.assertEqual(result['environment']['HOMEBREW_NO_SUDO'], '1')
        self.assertNotIn('/opt/homebrew', result['environment']['PATH'])
        self.assertTrue(all(a['decision'] == 'refuse_unknown_publication' for a in result['publication']))

    def test_missing_catalog_and_conflicting_names_refuse(self):
        with self.assertRaises(ValueError):
            s6.plan(self.chosen, self.formulae[:-1], self.manifest, 'arm64_golden_gate')
        with self.assertRaises(ValueError):
            s6.plan(self.chosen, self.formulae + [self.formulae[0]], self.manifest, 'arm64_golden_gate')

    def test_wrong_prefix_refused(self):
        self.manifest['volumes'][1]['mountPoint'] = '/opt/homebrew'
        with self.assertRaises(ValueError):
            s6.topology(self.manifest)

    def test_rollback_omission_refused(self):
        self.manifest['rollback']['volumeIDs'] = ['state']
        with self.assertRaises(ValueError):
            s6.topology(self.manifest)

    def test_unsafe_relative_root_refused(self):
        self.manifest['roots'][0]['relativePath'] = '../host'
        with self.assertRaises(ValueError):
            s6.topology(self.manifest)

    def test_overlapping_roots_refused(self):
        self.manifest['roots'][3]['relativePath'] = 'home/cache'
        with self.assertRaises(ValueError):
            s6.topology(self.manifest)

    def test_unsupported_cask_install_artifact_refused(self):
        cask = s6.read(s6.DATA / 'cask-coteditor.json')
        self.assertFalse(s6.cask_candidate(cask, '/mock/home')['app_only_candidate'])

    def test_no_bottle_is_not_a_source_measurement(self):
        result = s6.plan(self.chosen, self.formulae, self.manifest, 'arm64_unknown')
        self.assertTrue(any(not r['metadata_has_target_bottle'] for r in result['formula_commands']))
        self.assertTrue(all(r['status'].startswith('proposal-only') for r in result['formula_commands']))


class CooldownTests(unittest.TestCase):
    def setUp(self):
        self.artifact = {'kind': 'bottle', 'name': 'synthetic', 'version': '1.0', 'revision': 0,
                         'rebuild': 1, 'tag': 'arm64_golden_gate', 'url': 'https://example.invalid/blob',
                         'sha256': 'a' * 64}
        self.now = datetime(2026, 11, 4, tzinfo=timezone.utc)
        self.evidence = {'kind': 'synthetic-artifact-publication', 'artifact': self.artifact.copy(),
                         'published_at': '2026-11-03T00:00:00Z'}

    def check(self):
        return s6.synthetic_cooldown(self.artifact, self.evidence, self.now, 1)

    def test_exact_boundary_synthetic_only(self):
        self.assertEqual(self.check(), 'eligible_synthetic_only')

    def test_young_and_future_refused(self):
        self.evidence['published_at'] = '2026-11-03T00:00:01Z'
        self.assertEqual(self.check(), 'refuse_too_young')
        self.evidence['published_at'] = '2026-11-05T00:00:00Z'
        self.assertEqual(self.check(), 'refuse_future_publication')

    def test_rebuild_digest_url_tag_and_version_mismatch(self):
        for key in ('rebuild', 'sha256', 'url', 'tag', 'version'):
            evidence = copy.deepcopy(self.evidence)
            evidence['artifact'][key] = 'different'
            self.assertEqual(s6.synthetic_cooldown(self.artifact, evidence, self.now, 1), 'refuse_identity_mismatch')

    def test_unknown_and_nonpublication_dates_refused(self):
        for evidence in (None, {'generated_date': '2020-01-01'}, {'time': 1}, {'tap_git_head': 'a' * 40},
                         {'kind': 'registry-created', 'published_at': '2020-01-01T00:00:00Z'}):
            self.assertEqual(s6.synthetic_cooldown(self.artifact, evidence, self.now, 1), 'refuse_unknown_publication')

    def test_missing_or_naive_timestamp_refused(self):
        for value in (None, '', '2020-01-01', 'invalid'):
            self.evidence['published_at'] = value
            self.assertEqual(self.check(), 'refuse_unknown_publication')


class ReportTests(unittest.TestCase):
    def setUp(self):
        self.chosen, self.formulae = s6.pinned_inputs()
        self.names = [r['name'] for r in self.chosen['formulae']]
        self.before = {'formulae': []}
        self.after = {'formulae': []}
        self.attempts = []
        self.tests = []

    def add(self, rank, poured=True, exit_code=0):
        name = self.names[rank]
        f = next(f for f in self.formulae if f['name'] == name)
        version = f['versions']['stable'] + ('_' + str(f['revision']) if f['revision'] else '')
        self.after['formulae'].append({'name': name, 'full_name': name, 'tap': 'homebrew/core',
                                      'installed': [{'version': version, 'used_options': [],
                                                     'poured_from_bottle': poured, 'built_as_bottle': True}]})
        self.attempts.append({'name': name, 'exit_code': exit_code})

    def result(self):
        return s6.report(self.chosen, self.formulae, self.before, self.after, self.attempts, self.tests)

    def test_denominator_keeps_missing_and_failures(self):
        self.add(0, True)
        self.add(1, False)
        self.add(2, True, 1)
        result = self.result()
        self.assertEqual(result['counts'], {'bottle': 1, 'source': 1, 'failed': 1, 'unattempted': 197})
        self.assertEqual(result['bottle_fraction_of_classified'], 0.5)
        self.assertEqual(result['bottle_fraction_of_all_200'], 0.005)
        self.assertFalse(result['cohort_complete'])
        self.assertFalse(result['test_sample_all_passed'])
        self.assertEqual(result['acceptance_status'], 'Neověřeno')

    def test_missing_flag_is_not_source(self):
        self.add(0)
        del self.after['formulae'][0]['installed'][0]['poured_from_bottle']
        self.assertEqual(self.result()['counts'], {'unknown': 1, 'unattempted': 199})

    def test_string_false_is_not_boolean(self):
        self.add(0, 'false')
        self.assertEqual(self.result()['counts']['unknown'], 1)

    def test_preexisting_not_counted(self):
        self.add(0)
        self.before = copy.deepcopy(self.after)
        self.assertEqual(self.result()['counts']['preexisting'], 1)

    def test_drift_and_multiple_kegs_not_counted(self):
        self.add(0)
        self.add(1)
        self.after['formulae'][0]['installed'][0]['version'] = 'other'
        self.after['formulae'][1]['installed'] *= 2
        self.assertEqual(self.result()['counts']['version_drift'], 1)
        self.assertEqual(self.result()['counts']['ambiguous_receipt'], 1)

    def test_origin_mismatch_refused(self):
        self.add(0)
        self.after['formulae'][0]['tap'] = 'other/tap'
        self.assertEqual(self.result()['counts']['origin_mismatch'], 1)

    def test_duplicate_outcome_and_receipt_refused(self):
        self.add(0)
        self.attempts *= 2
        with self.assertRaises(ValueError):
            self.result()
        self.attempts.pop()
        self.after['formulae'] *= 2
        with self.assertRaises(ValueError):
            self.result()

    def test_sample_failure_and_missing_cannot_pass(self):
        sampled = s6.sample(self.chosen)
        self.tests = [{'name': n, 'exit_code': 0} for n in sampled[:-1]]
        self.assertFalse(self.result()['test_sample_all_passed'])
        self.tests.append({'name': sampled[-1], 'exit_code': 1})
        self.assertFalse(self.result()['test_sample_all_passed'])
        self.tests[-1]['exit_code'] = 0
        self.assertTrue(self.result()['test_sample_all_passed'])
        self.assertEqual(self.result()['acceptance_status'], 'Neověřeno')

    def test_unplanned_test_and_noninteger_exit_refused(self):
        self.tests = [{'name': 'not-selected', 'exit_code': 0}]
        with self.assertRaises(ValueError):
            self.result()
        self.tests = []
        self.add(0, exit_code=True)
        with self.assertRaises(ValueError):
            self.result()

    def test_no_classified_has_null_ratio(self):
        self.assertIsNone(self.result()['bottle_fraction_of_classified'])


class PrefixTests(unittest.TestCase):
    def test_dry_run_never_opens_files(self):
        with patch.object(prefix, 'trusted_directory', side_effect=AssertionError('must not open')):
            result = prefix.operation('prepare', Path('/mock/run/state'), 450, 701)
            self.assertTrue(result['dry_run'])

    def test_apply_refuses_nonroot_before_open(self):
        with patch.object(prefix.os, 'getuid', return_value=501), patch.object(prefix, 'trusted_directory',
                                                                                   side_effect=AssertionError()):
            with self.assertRaises(ValueError):
                prefix.operation('prepare', Path('/mock/run/state'), 450, 701, True)

    def test_state_and_identity_validation(self):
        for path, uid in [('/opt/snj/state', 450), ('/mock/../state', 450), ('/mock/state', 0)]:
            with self.subTest(path=path), self.assertRaises(ValueError):
                prefix.operation('prepare', Path(path), uid, 701)

    def test_empty_cleanup_and_conflicts_in_synthetic_temp_only(self):
        with tempfile.TemporaryDirectory(prefix='s6-synthetic-') as tmp:
            root = Path(tmp)
            fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
            try:
                recorded = prefix.create_empty(fd, 'zone', os.getuid(), os.getgid())
                with self.assertRaises(FileExistsError):
                    prefix.create_empty(fd, 'zone', os.getuid(), os.getgid())
                child = root / 'zone' / 'synthetic.txt'
                child.write_text('synthetic')
                with self.assertRaises(ValueError):
                    prefix.remove_empty(fd, 'zone', recorded)
                child.unlink()
                (root / 'zone').chmod(0o755)
                with self.assertRaises(ValueError):
                    prefix.remove_empty(fd, 'zone', recorded)
                (root / 'zone').chmod(0o700)
                prefix.remove_empty(fd, 'zone', recorded)
                self.assertFalse((root / 'zone').exists())
                (root / 'zone').symlink_to(root, target_is_directory=True)
                with self.assertRaises(OSError):
                    prefix.remove_empty(fd, 'zone', recorded)
                (root / 'zone').unlink()
            finally:
                os.close(fd)

    def test_replaced_directory_refused(self):
        with tempfile.TemporaryDirectory(prefix='s6-synthetic-') as tmp:
            root = Path(tmp)
            fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
            try:
                expected = prefix.create_empty(fd, 'zone', os.getuid(), os.getgid())
                (root / 'zone').rename(root / 'old')
                (root / 'zone').mkdir(mode=0o700)
                with self.assertRaises(ValueError):
                    prefix.remove_empty(fd, 'zone', expected)
            finally:
                os.close(fd)

class JournalAndCleanupTests(unittest.TestCase):
    def test_short_and_interrupted_write(self):
        with tempfile.TemporaryFile() as stream:
            original = os.write
            calls = [0]
            def partial(fd, data):
                calls[0] += 1
                if calls[0] == 1:
                    raise InterruptedError()
                return original(fd, data[:7])
            with patch.object(prefix.os, 'write', side_effect=partial):
                prefix.journal_write(stream.fileno(), {'before': None, 'phase': 'planned'})
            stream.seek(0)
            self.assertEqual(s6.decode(stream.read()), {'before': None, 'phase': 'planned'})
            self.assertGreater(calls[0], 2)

    def test_partial_invalid_journal_refused(self):
        with self.assertRaises(ValueError):
            s6.decode('{"phase":"creat')

    def test_acl_is_conflict(self):
        result = subprocess.CompletedProcess([], 0, 'drwx------  user group /mock\n 0: user:test allow write\n', '')
        with patch.object(prefix.subprocess, 'run', return_value=result), self.assertRaises(ValueError):
            prefix.no_acl(Path('/mock'))

    def test_idempotent_cleanup_and_recreation_refusal(self):
        with tempfile.TemporaryDirectory(prefix='s6-synthetic-') as tmp:
            path = Path(tmp) / 'zone'
            fd = os.open(tmp, os.O_RDONLY | os.O_DIRECTORY)
            try:
                expected = prefix.create_empty(fd, 'zone', os.getuid(), os.getgid())
                record = {'phase': 'created', 'created': expected}
                with patch.object(prefix, 'no_acl', side_effect=ValueError('ACL conflict')):
                    with self.assertRaises(ValueError):
                        prefix.cleanup_record(fd, 'zone', record, path)
                self.assertTrue(path.exists())
                with patch.object(prefix, 'no_acl'):
                    prefix.cleanup_record(fd, 'zone', record, path)
                    prefix.cleanup_record(fd, 'zone', record, path)
                    self.assertEqual(record['phase'], 'removed')
                    path.mkdir(mode=0o700)
                    with self.assertRaises(ValueError):
                        prefix.cleanup_record(fd, 'zone', record, path)
                    self.assertTrue(path.exists())
            finally:
                os.close(fd)

    def test_interrupted_preparation_never_cleans(self):
        with tempfile.TemporaryDirectory(prefix='s6-synthetic-') as tmp:
            fd = os.open(tmp, os.O_RDONLY | os.O_DIRECTORY)
            try:
                with self.assertRaises(ValueError):
                    prefix.cleanup_record(fd, 'zone', {'phase': 'planned'}, Path(tmp) / 'zone')
            finally:
                os.close(fd)

class CLITests(unittest.TestCase):
    def run_cli(self, *args):
        result = subprocess.run(['/usr/bin/python3', '-I', '-B', str(s6.BASE / 's6.py'), *args],
                                check=True, capture_output=True, text=True)
        return json.loads(result.stdout)

    def test_real_select_and_plan_entrypoints(self):
        self.assertEqual(self.run_cli('select'), s6.read(s6.DATA / 'top-200.json'))
        result = subprocess.run(['/bin/bash', str(s6.BASE / 'plan.sh')], check=True, capture_output=True, text=True)
        plan = json.loads(result.stdout)
        self.assertEqual(len(plan['formula_commands']), 200)
        self.assertEqual(len(plan['bootstrap_commands']), 3)
        self.assertEqual(plan['bootstrap_commands'][0][-1], plan['bootstrap']['url'])
        self.assertFalse(plan['executable'])

    def test_real_report_with_synthetic_fixtures(self):
        args = ['report']
        for flag in ('before', 'after', 'attempts', 'tests'):
            args.extend(['--' + flag, str(s6.BASE / 'examples' / ('synthetic-' + flag + '.json'))])
        result = self.run_cli(*args)
        self.assertEqual(result['counts'], {'bottle': 1, 'source': 1, 'failed': 1, 'unknown': 1,
                                           'version_drift': 1, 'unattempted': 195})
        self.assertFalse(result['test_sample_all_passed'])
        self.assertEqual(result['test_sample'][-1]['outcome'], 'missing')
        self.assertEqual(result['acceptance_status'], 'Neověřeno')

    def test_real_cooldown_entrypoint(self):
        result = self.run_cli('cooldown')
        self.assertTrue(result['records'])
        self.assertTrue(all(r['decision'] == 'refuse_unknown_publication' for r in result['records']))

    def test_prefix_shells_are_dry_run_without_host_access(self):
        for script in ('prepare-prefix.sh', 'cleanup-prefix.sh'):
            result = subprocess.run(['/bin/bash', str(s6.BASE / script), '--uid', '450', '--gid', '701',
                                     '--state-dir', '/synthetic-not-created/s6/state'],
                                    check=True, capture_output=True, text=True)
            self.assertTrue(json.loads(result.stdout)['dry_run'])
            self.assertFalse(Path('/synthetic-not-created').exists())


class AdditionalContractTests(unittest.TestCase):
    def test_cask_destination_override_and_disabled_refused(self):
        original = s6.read(s6.DATA / 'cask-rectangle.json')
        for mode in ('target', 'path', 'override', 'disabled'):
            cask = copy.deepcopy(original)
            app = next(a for a in cask['artifacts'] if 'app' in a)
            if mode == 'target':
                app['target'] = '/Library/Other.app'
            elif mode == 'path':
                app['app'] = ['../Other.app']
            elif mode == 'override':
                app['app'].append({'target': '/Library/Other.app'})
            else:
                cask['disabled'] = True
            self.assertFalse(s6.cask_candidate(cask, '/mock/home')['app_only_candidate'])

    def test_missing_synthetic_identity_fields_refused(self):
        artifact = {'sha256': 'a' * 64}
        evidence = {'kind': 'synthetic-artifact-publication', 'artifact': artifact.copy(),
                    'published_at': '2020-01-01T00:00:00Z'}
        self.assertEqual(s6.synthetic_cooldown(artifact, evidence,
                                             datetime(2026, 1, 1, tzinfo=timezone.utc), 1),
                         'refuse_identity_mismatch')

    def test_complete_synthetic_cohort_still_never_passes_gate(self):
        chosen, formulae = s6.pinned_inputs()
        after = {'formulae': []}
        attempts = []
        for f in formulae:
            version = f['versions']['stable'] + ('_' + str(f['revision']) if f['revision'] else '')
            after['formulae'].append({'name': f['name'], 'full_name': f['name'], 'tap': 'homebrew/core',
                                      'installed': [{'version': version, 'used_options': [],
                                                     'poured_from_bottle': True}]})
            attempts.append({'name': f['name'], 'exit_code': 0})
        tests = [{'name': n, 'exit_code': 0} for n in s6.sample(chosen)]
        result = s6.report(chosen, formulae, {'formulae': []}, after, attempts, tests)
        self.assertTrue(result['cohort_complete'])
        self.assertTrue(result['test_sample_all_passed'])
        self.assertEqual(result['acceptance_status'], 'Neověřeno')


if __name__ == '__main__':
    unittest.main()
