import copy
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

BASE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BASE))
import s7
import fixture_files as ff


def design():
    return s7.read(BASE / 'examples/design.json')


def sample_row(sid='DK-05/container-direct', zone='t001', m=None):
    m = m or design()
    return {'scenario': sid, 'zone': zone, 'attempted': True, 'controls_before': True,
            'controls_after': True, 'complete': True, 'result': s7.expected_result(s7.INDEX[sid], zone, m)}


def evidence(rows, m=None):
    return {'schema': 'sanjbox.s7-observations.v1', 'kind': 'synthetic-only',
            'manifest_sha256': s7.digest(m or design()), 'observations': rows}


def proposed_budget():
    m = design()
    m['budget'] = {'kind': 'synthetic-example', 'cold_ms': 100, 'warm_ms': 10, 'stop_ms': 50,
                   'samples': 3, 'statistic': 'maximum'}
    return m


class InputTests(unittest.TestCase):
    def test_duplicate_unknown_and_nonfinite(self):
        for raw in ('{"a":1,"a":2}', '{"a":NaN}', '{"a":Infinity}', '{"a":1.25}'):
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                s7.decode(raw)

    def test_complexity_limits(self):
        for raw in ('[' * 18 + '0' + ']' * 18, json.dumps(['a'] * 513), json.dumps('a' * 2049),
                    ' ' * (s7.MAX_INPUT + 1), json.dumps('\u0000')):
            with self.subTest(size=len(raw)), self.assertRaises(ValueError):
                s7.decode(raw)

    def test_deep_parser_recursion_is_refusal(self):
        with self.assertRaises(ValueError):
            s7.decode('[' * 2000 + '0' + ']' * 2000)

    def test_node_limit(self):
        with self.assertRaises(ValueError):
            s7.decode(json.dumps([[0] * 250 for _ in range(100)]))

    def test_file_refuses_symlink_fifo_oversize(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'data').write_text('{}')
            (root / 'link').symlink_to(root / 'data')
            os.mkfifo(root / 'pipe')
            (root / 'large').write_bytes(b' ' * (s7.MAX_INPUT + 1))
            for file in ('link', 'pipe', 'large'):
                with self.subTest(file=file), self.assertRaises((OSError, ValueError)):
                    s7.read(root / file)
            self.assertEqual(s7.read(root / 'data'), {})

    def test_path_canonicalization(self):
        for value in ('/', '/a/../b', '/a//b', '/a/./b', '/a/', '/a\\b', '/a\nb', 'relative', '/a;echo'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                s7.path(value)


class ManifestTests(unittest.TestCase):
    def test_valid_proposal_still_unverified(self):
        m = s7.manifest(design())
        self.assertEqual(len(m['zones']), 3)
        result = s7.plan(m)
        self.assertFalse(result['executable'])
        self.assertEqual(result['acceptance_status'], 'Neověřeno')
        self.assertTrue(any('F0.8' in x for x in result['blockers']))

    def test_stored_negative_manifests(self):
        rows = s7.read(BASE / 'fixtures/negative-manifests.json')
        self.assertGreaterEqual(len(rows), 20)
        for row in rows:
            m = design()
            dest = m
            for part in row['path'][:-1]:
                dest = dest[part]
            dest[row['path'][-1]] = row['value']
            with self.subTest(case=row['case']), self.assertRaises(ValueError):
                s7.manifest(m)

    def test_no_real_evidence_or_approved_budget_schema(self):
        for key, value in [('kind', 'runtime-measured'), ('budget', dict(proposed_budget()['budget'], kind='approved'))]:
            m = design(); m[key] = value
            with self.assertRaises(ValueError):
                s7.manifest(m)

    def test_unknown_fields_refused(self):
        m = design(); m['shell'] = 'docker run'
        with self.assertRaises(ValueError):
            s7.manifest(m)

    def test_artifact_pins_are_explicit(self):
        m = design(); m['artifacts']['engine'] = 'latest'
        with self.assertRaises(ValueError):
            s7.manifest(m)
        m['artifacts']['engine'] = 'a' * 64
        self.assertFalse(s7.plan(m)['executable'])

    def test_control_bool_cannot_be_root_uid(self):
        m = design(); m['control']['owner_uid'] = False
        with self.assertRaises(ValueError):
            s7.manifest(m)

    def test_share_integer_cannot_be_boolean(self):
        m = design(); m['zones'][0]['shares'][0]['read_only'] = 0
        with self.assertRaises(ValueError):
            s7.manifest(m)

    def test_command_argv_has_exact_socket_and_no_execution(self):
        result = s7.plan(design())
        self.assertEqual(len(result['commands']), 15)
        for command in result['commands']:
            args = command['argv']; z = command['zone']
            self.assertFalse(command['execute'])
            self.assertEqual(args[:5], ['/S7-LAB-ONLY/bin/docker', '--config',
                                        '/S7-LAB-ONLY/zones/' + z + '/docker-config', '--host',
                                        'unix:///S7-LAB-ONLY/zones/' + z + '/run/docker.sock'])
            self.assertNotIn('/bin/sh', args)
            self.assertNotIn('/bin/bash', args)
        mount = next(c for c in result['commands'] if c['scenario'] == 'mac-root')
        self.assertIn('/:/host', mount['argv'])
        self.assertTrue(any('UNRESOLVED' in arg for arg in mount['argv']))

    def test_apple_native_is_not_a_docker_substitute(self):
        m = design(); m['candidate'] = 'apple-native'
        self.assertEqual(s7.plan(m)['commands'], [])

    def test_inventory_covers_all_dk_and_failure_modes(self):
        result = s7.inventory()
        self.assertEqual({r['dk'] for r in result['scenarios']}, {'DK-%02d' % i for i in range(1, 11)})
        ids = {r['id'] for r in result['scenarios']}
        for name in ('flush-anchor', 'flush-all', 'disable-pf', 'helper-crash', 'gateway-crash',
                     'manager-crash', 'forwarder-crash', 'sleep-wake', 'vpn-network-change',
                     'stale-state-revocation', 'restart-recovery'):
            self.assertIn('DK-09/' + name, ids)
        self.assertEqual(len(ids), len(result['scenarios']))
        self.assertEqual(result['observation_count'], 3 * len(ids))


class OracleTests(unittest.TestCase):
    def report(self, rows, m=None):
        return s7.oracle(m or design(), evidence(rows, m))

    def test_empty_is_missing_never_success(self):
        r = self.report([])
        self.assertFalse(r['complete'])
        self.assertFalse(r['all_synthetic_match'])
        self.assertEqual(len(r['missing']), len(s7.SCENARIOS) * 3)

    def test_manifest_binding_and_real_kind_refused(self):
        for key, value in [('manifest_sha256', '0' * 64), ('kind', 'live')]:
            obs = evidence([]); obs[key] = value
            with self.assertRaises(ValueError):
                s7.oracle(design(), obs)

    def test_duplicate_unknown_and_foreign_zone_refused(self):
        row = sample_row()
        for rows in ([row, row], [dict(row, scenario='DK-99/unknown')], [dict(row, zone='t999')]):
            with self.assertRaises(ValueError):
                self.report(rows)

    def test_missing_controls_attempt_and_window_are_insufficient(self):
        for key in ('attempted', 'controls_before', 'controls_after', 'complete'):
            row = sample_row(); row[key] = False
            self.assertEqual(self.report([row])['rows'][0]['result'], 'insufficient')

    def test_bool_counts_and_nonbool_flags_refused(self):
        row = sample_row(); row['result']['forbidden_bytes'] = False
        with self.assertRaises(ValueError):
            self.report([row])
        row = sample_row(); row['attempted'] = 1
        with self.assertRaises(ValueError):
            self.report([row])

    def test_one_forbidden_byte_or_packet_fails_model(self):
        for field in ('forbidden_bytes', 'forbidden_packets'):
            row = sample_row(); row['result'][field] = 1
            self.assertEqual(self.report([row])['rows'][0]['result'], 'synthetic-mismatch')

    def test_known_leak_is_not_hidden_by_incomplete_evidence(self):
        row = sample_row(); row['controls_after'] = False; row['result']['forbidden_bytes'] = 1
        self.assertEqual(self.report([row])['rows'][0]['result'], 'synthetic-mismatch')
        row = sample_row('DK-10/full-stop'); row['result']['remaining_processes'] = 1
        self.assertEqual(self.report([row])['rows'][0]['result'], 'synthetic-mismatch')

    def test_negative_measurement_counts_refused(self):
        row = sample_row(); row['result']['forbidden_bytes'] = -1
        with self.assertRaises(ValueError):
            self.report([row])

    def test_capture_gap_and_missing_channel_never_match(self):
        for field, value in [('capture_complete', False), ('channels', ['ipv4-tcp'])]:
            row = sample_row(); row['result'][field] = value
            self.assertEqual(self.report([row])['rows'][0]['result'], 'synthetic-mismatch')

    def test_file_leak_write_and_topology_gap(self):
        for field, value in [('protected_bytes', 1), ('protected_writes', 1), ('topology_complete', False)]:
            row = sample_row('DK-02/mac-root'); row['result'][field] = value
            self.assertEqual(self.report([row])['rows'][0]['result'], 'synthetic-mismatch')

    def test_control_plane_and_socket_bypasses(self):
        for sid, field in [('DK-03/alternate-launcher', 'expanded_shares'),
                           ('DK-03/add-nic', 'added_nics'), ('DK-04/foreign-socket', 'unauthorized_operations'),
                           ('DK-10/post-stop-restart', 'unauthorized_operations')]:
            row = sample_row(sid); row['result'][field] = 1
            self.assertEqual(self.report([row])['rows'][0]['result'], 'synthetic-mismatch')

    def test_workload_hash_and_daemon_are_bound(self):
        row = sample_row('DK-01/build-copy')
        self.assertEqual(row['result']['output_sha256'], hashlib.sha256(ff.payloads('t001')['canary.txt']).hexdigest())
        for field, value in [('exit_code', 1), ('output_sha256', '0' * 64), ('daemon_id', 'mock-daemon-t002')]:
            changed = copy.deepcopy(row); changed['result'][field] = value
            self.assertEqual(self.report([changed])['rows'][0]['result'], 'synthetic-mismatch')

    def test_gateway_misattribution_or_direct_path(self):
        for field, value in [('gateway_zone', 't002'), ('upstream_zone', 't002'), ('direct_bytes', 1), ('delivered_bytes', 0)]:
            row = sample_row('DK-05/typed-container'); row['result'][field] = value
            self.assertEqual(self.report([row])['rows'][0]['result'], 'synthetic-mismatch')

    def test_result_fields_cannot_replace_expectations(self):
        row = sample_row(); row['result']['expected_bytes'] = 0
        with self.assertRaises(ValueError):
            self.report([row])

    def test_unresolved_budget_is_insufficient(self):
        self.assertEqual(self.report([sample_row('DK-10/cold-start')])['rows'][0]['result'], 'insufficient')

    def test_budget_exact_boundary_samples_and_lifecycle(self):
        m = proposed_budget()
        for sid, limit in [('DK-10/cold-start', 100), ('DK-10/warm-start', 10), ('DK-10/full-stop', 50)]:
            row = sample_row(sid, m=m); row['result']['samples_ms'] = [limit] * 3
            self.assertEqual(self.report([row], m)['rows'][0]['result'], 'synthetic-match')
            row['result']['samples_ms'][-1] += 1
            self.assertEqual(self.report([row], m)['rows'][0]['result'], 'synthetic-mismatch')
        row = sample_row('DK-10/full-stop', m=m); row['result']['samples_ms'] = [1]
        self.assertEqual(self.report([row], m)['rows'][0]['result'], 'insufficient')
        for field, value in [('policy_ready', False), ('remaining_processes', 1), ('remaining_channels', 1)]:
            row = sample_row('DK-10/full-stop', m=m); row['result'][field] = value
            self.assertEqual(self.report([row], m)['rows'][0]['result'], 'synthetic-mismatch')

    def test_complete_synthetic_matrix_never_passes_gate(self):
        m = proposed_budget()
        rows = [sample_row(s['id'], zone, m) for s in s7.SCENARIOS for zone in s7.ZONES]
        result = self.report(rows, m)
        self.assertTrue(result['all_synthetic_match'])
        self.assertEqual(result['acceptance_status'], 'Neověřeno')
        self.assertEqual(set(result['all_dk_status'].values()), {'Neověřeno'})

    def test_all_zones_default_budget_has_nine_insufficient(self):
        rows = [sample_row(s['id'], zone) for s in s7.SCENARIOS for zone in s7.ZONES]
        result = self.report(rows)
        self.assertTrue(result['complete'])
        self.assertFalse(result['all_synthetic_match'])
        self.assertEqual(result['counts']['insufficient'], 9)

    def test_stored_negative_observations(self):
        obs = s7.read(BASE / 'examples/observations.json')
        result = s7.oracle(design(), obs)
        self.assertEqual(result['counts'], {'synthetic-match': 1, 'synthetic-mismatch': 2, 'insufficient': 2})
        self.assertFalse(result['complete'])


class ModelTests(unittest.TestCase):
    def test_stored_registry_requests(self):
        rows = s7.read(BASE / 'fixtures/registry-cases.json')
        for row in rows:
            result = s7.registry_mock(row['request'], row['bound_zone'])
            self.assertEqual(result['decision'], row['expected'])
            self.assertFalse(result['exposes_auth_material'])

    def test_registry_cross_zone_same_request_denied(self):
        request = s7.registry_request('scoped-pull', 't001')
        self.assertEqual(s7.registry_mock(request, 't001')['decision'], 'synthetic-allow')
        self.assertEqual(s7.registry_mock(request, 't002')['decision'], 'synthetic-deny')
        request['client_auth'] = 1
        with self.assertRaises(ValueError):
            s7.registry_mock(request, 't001')

    def test_toy_frame_positive_not_transport(self):
        result = s7.MockVsockSession('t001').exchange(s7.frame())
        self.assertEqual(result['kind'], 'toy-frame-mock')
        self.assertEqual(result['acceptance_status'], 'Neověřeno')

    def test_toy_frame_bounds_truncation_trailing_and_duplicate_json(self):
        raw = b'{"version":1,"version":1}'
        for frame in (b'', b'\0\0\0\0', struct.pack('!I', 4097) + b'a' * 4097,
                      s7.frame()[:-1], s7.frame() + b'X', struct.pack('!I', len(raw)) + raw):
            with self.subTest(size=len(frame)), self.assertRaises(ValueError):
                s7.MockVsockSession('t001').exchange(frame)

    def test_toy_frame_peer_generation_operation_path_refused(self):
        for change in ({'zone': 't002'}, {'generation': 2}, {'generation': True}, {'version': True},
                       {'operation': 'connect'}, {'operation': 'dns'}, {'resource': '../host'}, {'host': '127.0.0.1'}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                s7.MockVsockSession('t001').exchange(s7.frame(**change))

    def test_toy_replay_revocation_and_bound(self):
        session = s7.MockVsockSession('t001')
        session.exchange(s7.frame())
        with self.assertRaises(ValueError):
            session.exchange(s7.frame())
        session.revoked = True
        with self.assertRaises(ValueError):
            session.exchange(s7.frame(request_id='req-002'))
        session = s7.MockVsockSession('t001')
        for i in range(64):
            session.exchange(s7.frame(request_id='req-%03d' % i))
        with self.assertRaises(ValueError):
            session.exchange(s7.frame(request_id='req-064'))


class FixtureTests(unittest.TestCase):
    def prepare(self, tmp):
        return Path(ff.prepare(Path(tmp).resolve(), apply=True)['root'])

    def test_default_dry_run_never_opens_parent(self):
        with patch.object(ff, 'directory', side_effect=AssertionError('opened path')):
            self.assertTrue(ff.prepare(Path('/synthetic-not-created'), apply=False)['dry_run'])
            self.assertTrue(ff.cleanup(Path('/synthetic-not-created/sanjbox-s7-fixtures-' + 'a' * 32))['dry_run'])

    def test_prepare_cleanup_and_idempotence(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = self.prepare(tmp)
            self.assertEqual(set(p.name for p in root.iterdir()), {'Dockerfile', 'canary.txt', 'config.json', ff.STATE})
            self.assertEqual((root / 'config.json').read_bytes(), b'{}\n')
            self.assertEqual(ff.cleanup(root, True)['result'], 'removed')
            self.assertEqual(ff.cleanup(root, True)['result'], 'already-absent')

    def test_changed_content_refuses_all_deletion(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = self.prepare(tmp)
            (root / 'canary.txt').write_text('later user change')
            with self.assertRaises(ValueError):
                ff.cleanup(root, True)
            self.assertEqual(len(list(root.iterdir())), 4)

    def test_symlink_and_hardlink_refused(self):
        for mode in ('symlink', 'hardlink'):
            with tempfile.TemporaryDirectory() as tmp:
                root = self.prepare(tmp)
                target = root / 'canary.txt'
                if mode == 'symlink':
                    target.unlink(); target.symlink_to(root / 'Dockerfile')
                else:
                    os.link(target, Path(tmp) / 'extra-link')
                with self.assertRaises((ValueError, OSError)):
                    ff.cleanup(root, True)
                self.assertTrue((root / 'Dockerfile').exists())

    def test_foreign_entry_and_changed_mode_refused(self):
        for mode in ('extra', 'mode'):
            with tempfile.TemporaryDirectory() as tmp:
                root = self.prepare(tmp)
                if mode == 'extra':
                    (root / 'not-ours').write_text('preserve')
                else:
                    (root / 'canary.txt').chmod(0o644)
                with self.assertRaises(ValueError):
                    ff.cleanup(root, True)
                self.assertTrue((root / 'Dockerfile').exists())

    def test_replaced_inode_and_journal_conflict(self):
        for mode in ('inode', 'phase'):
            with tempfile.TemporaryDirectory() as tmp:
                root = self.prepare(tmp)
                if mode == 'inode':
                    (root / 'canary.txt').rename(Path(tmp) / 'old')
                    (root / 'canary.txt').write_bytes(ff.payloads('t001')['canary.txt'])
                    (root / 'canary.txt').chmod(0o600)
                else:
                    value = json.loads((root / ff.STATE).read_text()); value['phase'] = 'planned'
                    (root / ff.STATE).write_text(json.dumps(value))
                with self.assertRaises(ValueError):
                    ff.cleanup(root, True)

    def test_missing_known_file_can_resume_cleanup(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = self.prepare(tmp)
            (root / 'Dockerfile').unlink()
            self.assertEqual(ff.cleanup(root, True)['result'], 'removed')

    def test_nonfixture_path_and_parent_symlink_refused(self):
        with self.assertRaises(ValueError):
            ff.cleanup(Path('/private/tmp/arbitrary'), True)
        with tempfile.TemporaryDirectory() as tmp:
            parent = Path(tmp).resolve()
            (parent / 'link').symlink_to(parent, target_is_directory=True)
            with self.assertRaises(OSError):
                ff.prepare(parent / 'link', apply=True)

    def test_short_read_and_eintr(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = self.prepare(tmp)
            fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
            original, calls = os.read, [0]
            def short(fd, size):
                calls[0] += 1
                if calls[0] == 1:
                    raise InterruptedError()
                return original(fd, min(size, 2))
            try:
                with patch.object(ff.os, 'read', side_effect=short):
                    raw, _ = ff.checked_file(fd, 'canary.txt')
                self.assertEqual(raw, ff.payloads('t001')['canary.txt'])
                self.assertGreater(calls[0], 5)
            finally:
                os.close(fd)
            ff.cleanup(root, True)

    def test_root_or_parent_rename_drift_before_delete(self):
        for which in ('root', 'parent'):
            with tempfile.TemporaryDirectory() as tmp:
                parent = Path(tmp).resolve() / 'parent'
                parent.mkdir(mode=0o700)
                root = self.prepare(parent)
                original = ff.checked_file
                changed = [False]
                moved = root.with_name('moved') if which == 'root' else parent.with_name('moved')
                def drift(fd, name, expected=None):
                    result = original(fd, name, expected)
                    if name == 'config.json' and not changed[0]:
                        changed[0] = True
                        target = root if which == 'root' else parent
                        target.rename(moved)
                        target.mkdir(mode=0o700)
                    return result
                with patch.object(ff, 'checked_file', side_effect=drift), self.assertRaises(ValueError):
                    ff.cleanup(root, True)
                preserved = moved if which == 'root' else moved / root.name
                self.assertEqual(len(list(preserved.iterdir())), 4)

    def test_writable_nonsticky_ancestor_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            ancestor = Path(tmp).resolve() / 'untrusted'
            ancestor.mkdir(mode=0o777)
            ancestor.chmod(0o777)
            child = ancestor / 'private'
            child.mkdir(mode=0o700)
            with self.assertRaises(ValueError):
                ff.prepare(child, apply=True)

    def test_journal_hardlink_and_forged_inventory_refused(self):
        for mode in ('hardlink', 'inventory'):
            with tempfile.TemporaryDirectory() as tmp:
                root = self.prepare(tmp)
                if mode == 'hardlink':
                    os.link(root / ff.STATE, Path(tmp) / 'state-link')
                else:
                    value = json.loads((root / ff.STATE).read_text())
                    value['files']['../../elsewhere'] = value['files']['Dockerfile']
                    (root / ff.STATE).write_text(json.dumps(value))
                with self.assertRaises(ValueError):
                    ff.cleanup(root, True)
                self.assertTrue((root / 'Dockerfile').exists())

    def test_privileged_fixture_apply_refused_before_access(self):
        with patch.object(ff.os, 'geteuid', return_value=0), patch.object(ff, 'directory', side_effect=AssertionError('opened')):
            with self.assertRaises(ValueError):
                ff.prepare(Path('/synthetic-not-created'), apply=True)
            with self.assertRaises(ValueError):
                ff.cleanup(Path('/synthetic-not-created/sanjbox-s7-fixtures-' + 'a' * 32), True)

    def test_short_write_and_eintr(self):
        with tempfile.TemporaryFile() as stream:
            original, calls = os.write, [0]
            def short(fd, data):
                calls[0] += 1
                if calls[0] == 1:
                    raise InterruptedError()
                return original(fd, data[:3])
            with patch.object(ff.os, 'write', side_effect=short):
                ff.write_all(stream.fileno(), b'12345678')
            stream.seek(0)
            self.assertEqual(stream.read(), b'12345678')


class CLITests(unittest.TestCase):
    def cli(self, script, *args, expected=0):
        proc = subprocess.run(['/usr/bin/python3', '-I', '-B', str(BASE / script), *args],
                              capture_output=True, text=True, timeout=10)
        self.assertEqual(proc.returncode, expected, proc.stderr)
        if expected == 0:
            return json.loads(proc.stdout)
        self.assertEqual(proc.stdout, '')
        self.assertNotIn('Traceback', proc.stderr)
        return proc.stderr

    def test_validate_plan_inventory_entrypoints(self):
        self.assertTrue(self.cli('s7.py', 'validate')['valid_design'])
        self.assertFalse(self.cli('s7.py', 'plan')['executable'])
        self.assertEqual(self.cli('s7.py', 'inventory')['observation_count'], len(s7.SCENARIOS) * 3)

    def test_oracle_entrypoint(self):
        report = self.cli('s7.py', 'oracle', '--observations', str(BASE / 'examples/observations.json'))
        self.assertEqual(report['counts']['synthetic-mismatch'], 2)
        self.assertEqual(report['acceptance_status'], 'Neověřeno')

    def test_cli_invalid_and_oversize_json(self):
        with tempfile.TemporaryDirectory() as tmp:
            file = Path(tmp) / 'bad.json'
            for raw in ('{"kind":1,"kind":2}', '[]', ' ' * (s7.MAX_INPUT + 1)):
                file.write_text(raw)
                self.cli('s7.py', 'validate', '--manifest', str(file), expected=2)

    def test_no_runtime_execute_or_apply_command(self):
        self.cli('s7.py', 'plan', '--apply', expected=2)
        self.cli('s7.py', 'execute', expected=2)

    def test_fixture_dryrun_and_apply_entrypoints(self):
        self.assertTrue(self.cli('fixture_files.py', 'prepare', '--parent', '/synthetic-not-created')['dry_run'])
        with tempfile.TemporaryDirectory() as tmp:
            result = self.cli('fixture_files.py', 'prepare', '--parent', str(Path(tmp).resolve()), '--zone', 't003', '--apply')
            root = Path(result['root'])
            self.assertIn('t003', (root / 'canary.txt').read_text())
            self.assertTrue(self.cli('fixture_files.py', 'cleanup', '--root', str(root))['dry_run'])
            self.assertTrue(root.exists())
            self.assertEqual(self.cli('fixture_files.py', 'cleanup', '--root', str(root), '--apply')['result'], 'removed')
            self.assertEqual(self.cli('fixture_files.py', 'cleanup', '--root', str(root), '--apply')['result'], 'already-absent')


if __name__ == '__main__':
    unittest.main()
