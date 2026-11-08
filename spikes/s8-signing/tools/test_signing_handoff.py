#!/usr/bin/env python3
"""Synthetic app bytes and codesign stubs only: never a Personal Team success claim."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import select
import shutil
import stat
import struct
import subprocess
import unittest
from unittest.mock import patch
import uuid

spec = importlib.util.spec_from_file_location('handoff', Path(__file__).with_name('signing-handoff.py'))
h = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h)
f = h.f


def macho(signature=b'S' * 16):
    header = struct.pack('<8I', 0xfeedfacf, 0x100000c, 0, 2, 2, 88, 0, 0)
    segment = struct.pack('<II16sQQQQIIII', 0x19, 72, b'__LINKEDIT', 0x1000, 16384,
                          128, 16 + len(signature), 1, 1, 0, 0)
    command = struct.pack('<4I', 0x1d, 16, 144, len(signature))
    return header + segment + command + bytes(8) + b'PAYLOAD-ORIGINAL' + signature


# Each contender is a separate OS process. Only the codesign observations are stubbed;
# planner, inventory, locks, manifests, refusal paths and unlink operations are real.
PROCESS_DRIVER = r"""
import importlib.util, json, os, sys
spec = importlib.util.spec_from_file_location('handoff', sys.argv[1])
h = importlib.util.module_from_spec(spec); spec.loader.exec_module(h)
root, source, operation, mode, pause = sys.argv[2:]
os.umask(0o077)
h.adhoc_verify = lambda root: None
h.signature_check = lambda root, name: dict(target=name, strictAllArchitectures=True,
    hardenedRuntime=True, adHoc=False, getTaskAllow='absent', entitlements='empty')
inventory_calls = 0
original_entries = h.entries
original_linked = h.linked_root
original_write = h.write_record
linked_calls = 0
def gate():
    print(json.dumps({'paused': operation, 'pid': os.getpid()}), flush=True)
    if sys.stdin.readline() != 'continue\n': raise RuntimeError('test controller did not resume')
def entries(fd):
    global inventory_calls
    inventory_calls += 1
    return original_entries(fd)
def linked(root, fd):
    global linked_calls
    linked_calls += 1
    if pause == 'linked-' + str(linked_calls): gate()
    return original_linked(root, fd)
def write(root, fd, name, value):
    if pause == 'write-' + name: gate()
    return original_write(root, fd, name, value)
h.entries = entries
h.linked_root = linked
h.write_record = write
try:
    if operation == 'prepare':
        result = h.prepare(source, root, 'personal-team', apply=mode == 'apply')
    else:
        result = {'handoff': h.handoff, 'cleanup': h.cleanup, 'record-signed': h.record_signed}[operation](
            root, mode == 'apply')
    print(json.dumps({'result': result, 'inventoryCalls': inventory_calls}), flush=True)
except Exception as error:
    print(json.dumps({'error': str(error), 'kind': type(error).__name__,
                      'inventoryCalls': inventory_calls}), flush=True)
    sys.exit(2)
"""


class HandoffTests(unittest.TestCase):
    def setUp(self):
        self.old_umask = os.umask(0o077)
        self.source = Path(f.PREFIX + str(uuid.uuid4()).upper())
        self.root = Path(h.PREFIX + str(uuid.uuid4()).upper())
        self.source.mkdir(mode=0o700)
        self.source_inode = self.source.stat().st_ino
        self.run_id = self.source.name[len('sanjbox-s8-services-'):]
        for folder in ('Contents/MacOS', 'Contents/Library/LoginItems/S8LoginItem.app/Contents/MacOS',
                       'Contents/Library/LaunchAgents', 'Contents/Library/LaunchDaemons',
                       'Contents/_CodeSignature', 'Contents/Library/LoginItems/S8LoginItem.app/Contents/_CodeSignature'):
            (self.source/f.APP/folder).mkdir(parents=True, mode=0o700, exist_ok=True)
        for name in h.BINARIES:
            f.write_new(self.source/name, macho(), 0o700)
        f.plist(self.source/f.APP/'Contents/Info.plist', dict(S8FixtureRunID=self.run_id,
                CFBundleIdentifier=f.HOST_ID, CFBundleExecutable='S8ServiceHost'))
        f.plist(self.source/h.LOGIN/'Contents/Info.plist', dict(S8FixtureRunID=self.run_id,
                CFBundleIdentifier='org.sanjbox.s8.fixture.loginItem'))
        for kind, product, folder in [('agent', 'S8LaunchAgent', 'LaunchAgents'), ('daemon', 'S8LaunchDaemon', 'LaunchDaemons')]:
            label = 'org.sanjbox.s8.fixture.' + kind
            f.plist(self.source/f.APP/'Contents/Library'/folder/(label + '.plist'),
                    dict(Label=label, BundleProgram='Contents/MacOS/' + product, RunAtLoad=True, ProcessType='Background'))
        for name in h.RESOURCES:
            f.write_new(self.source/name, b'synthetic sealed resources')
        f.write_new(self.source/'build.log', b'synthetic build cache is deliberately not copied')
        f.seal_artifact(self.source)
        self.source_manifest = (self.source/'artifact-manifest.json').read_bytes()
        self.real_signed = False
        self.flags = b'0x10000(runtime)'
        self.entitlements = plistlib.dumps({})
        self.returncode = 0
        self.extra_metadata = b''
        self.calls = []
        def tool(args, **kwargs):
            self.calls.append(args)
            self.assertEqual(args[0], '/usr/bin/codesign')
            self.assertNotIn('--sign', args)
            self.assertTrue('--verify' in args or '-dvv' in args)
            signed = self.real_signed and args[-1].startswith(str(self.root) + '/')
            flags = self.flags if signed else b'0x10002(adhoc,runtime)'
            return subprocess.CompletedProcess(args, self.returncode,
                self.entitlements if signed else plistlib.dumps({}),
                b'CodeDirectory v=20500 size=123 flags=' + flags + b' hashes=1+1\n' + self.extra_metadata)
        self.stub = patch.object(h.subprocess, 'run', side_effect=tool)
        self.stub.start()

    def tearDown(self):
        # Stop any failed/paused child before removing its exact synthetic test roots.
        self.doCleanups()
        self.stub.stop()
        # Exact roots generated by this test; no borrowed paths or globs.
        if self.root.is_symlink():
            self.root.unlink()
        elif self.root.exists():
            shutil.rmtree(self.root)
        self.assertEqual(self.source.stat().st_ino, self.source_inode)
        shutil.rmtree(self.source)
        os.umask(self.old_umask)

    def prepare(self, apply=True, profile='personal-team', fallback=False):
        with contextlib.redirect_stderr(io.StringIO()):
            return h.prepare(str(self.source), str(self.root), profile, fallback, apply)

    def issued(self):
        self.prepare()
        return h.handoff(str(self.root), True)

    def signed(self):
        self.issued()
        for name in h.BINARIES:
            (self.root/name).write_bytes(macho(b'new signature, synthetic fixture!' * 2))
        for name in h.RESOURCES:
            (self.root/name).write_bytes(b'changed sealed resource bytes')
        self.real_signed = True

    def assert_preserved(self, operation):
        before = {str(p.relative_to(self.root)): p.read_bytes() for p in self.root.rglob('*') if p.is_file() and not p.is_symlink()}
        with self.assertRaises((f.Refused, ValueError, OSError, subprocess.SubprocessError)):
            operation()
        after = {str(p.relative_to(self.root)): p.read_bytes() for p in self.root.rglob('*') if p.is_file() and not p.is_symlink()}
        self.assertEqual(before, after)

    def process(self, operation, mode='apply', pause='none'):
        child = subprocess.Popen([h.sys.executable, '-I', '-B', '-c', PROCESS_DRIVER,
                                  h.__file__, str(self.root), str(self.source), operation, mode, pause],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 text=True)
        def close():
            if child.poll() is None: child.kill()
            child.communicate(timeout=10)
        self.addCleanup(close)
        return child

    def wait_paused(self, child, operation):
        ready, _, _ = select.select([child.stdout], [], [], 10)
        self.assertTrue(ready, 'child did not reach the requested operation barrier')
        line = child.stdout.readline()
        self.assertTrue(line, 'child exited before operation barrier')
        value = json.loads(line)
        self.assertEqual(value['paused'], operation)
        self.assertNotEqual(value['pid'], os.getpid())

    def finish_process(self, child, resume=False, expected=0):
        out, err = child.communicate(input='continue\n' if resume else None, timeout=10)
        self.assertEqual(child.returncode, expected, out + err)
        return json.loads(out)

    def assert_busy_process(self, operation, mode='apply'):
        result = self.finish_process(self.process(operation, mode), expected=2)
        self.assertEqual(result['kind'], 'Refused')
        self.assertIn('signing root busy', result['error'])
        self.assertEqual(result['inventoryCalls'], 0, 'contender inventoried before acquiring the lock')
        self.assertNotIn('result', result)

    def snapshot_root(self):
        fd = f.scoped_root(str(self.root), h.PREFIX)
        try: return h.entries(fd)
        finally: os.close(fd)

    def test_review_counterexample_handoff_during_cleanup_second_root_check(self):
        self.prepare()
        original = h.linked_root
        calls = [0]
        issued = []
        refusals = []
        def interleave(root, fd):
            calls[0] += 1
            if calls[0] == 2:
                try: issued.append(h.handoff(str(self.root), True))
                except f.Refused as error: refusals.append(str(error))
            return original(root, fd)
        with patch.object(h, 'linked_root', side_effect=interleave):
            result = h.cleanup(str(self.root), True)
        self.assertTrue(result['removed'])
        self.assertEqual(issued, [])
        self.assertEqual(len(refusals), 1)
        self.assertIn('signing root busy', refusals[0])
        self.assertFalse(self.root.exists())

    def test_process_cleanup_before_unlink_excludes_handoff(self):
        self.prepare()
        child = self.process('cleanup', pause='linked-2')
        self.wait_paused(child, 'cleanup')
        before = self.snapshot_root()
        self.assert_busy_process('handoff')
        self.assertEqual(self.snapshot_root(), before)
        self.assertFalse((self.root/h.HANDOFF).exists())
        result = self.finish_process(child, resume=True)
        self.assertTrue(result['result']['removed'])
        self.assertFalse(self.root.exists())
        refused = self.finish_process(self.process('handoff'), expected=2)
        self.assertNotIn('result', refused)

    def test_process_handoff_before_marker_excludes_cleanup_and_second_handoff(self):
        self.prepare()
        child = self.process('handoff', pause='write-' + h.HANDOFF)
        self.wait_paused(child, 'handoff')
        before = self.snapshot_root()
        self.assert_busy_process('cleanup')
        self.assert_busy_process('handoff')
        self.assertEqual(self.snapshot_root(), before)
        result = self.finish_process(child, resume=True)
        self.assertEqual(result['result']['userOnlyCommands'].count('/usr/bin/codesign --force --sign'), 4)
        self.assertTrue((self.root/h.HANDOFF).exists())
        self.assertTrue(all((self.root/name).exists() for name in h.BINARIES))
        for mode in ('dry', 'apply'):
            refused = self.finish_process(self.process('cleanup', mode), expected=2)
            self.assertIn('registration state unknown', refused['error'])

    def test_process_signed_inventory_write_excludes_all_other_operations(self):
        self.signed()
        child = self.process('record-signed', pause='write-' + h.SIGNED)
        self.wait_paused(child, 'record-signed')
        before = self.snapshot_root()
        for operation in ('handoff', 'cleanup', 'record-signed'):
            for mode in ('dry', 'apply'):
                self.assert_busy_process(operation, mode)
        self.assertEqual(self.snapshot_root(), before)
        self.finish_process(child, resume=True)
        original = (self.root/h.SIGNED).read_bytes()
        self.assertTrue(h.record_signed(str(self.root), True)['alreadyRecorded'])
        self.assertEqual((self.root/h.SIGNED).read_bytes(), original)

    def test_process_prepare_excludes_operations_until_complete_inventory(self):
        child = self.process('prepare', pause='write-' + h.PREPARED)
        self.wait_paused(child, 'prepare')
        before = self.snapshot_root()
        self.assertFalse((self.root/h.PREPARED).exists())
        for operation in ('handoff', 'cleanup', 'record-signed'):
            self.assert_busy_process(operation)
        competing = self.finish_process(self.process('prepare'), expected=2)
        self.assertIn('destination already exists', competing['error'])
        self.assertEqual(self.snapshot_root(), before)
        self.finish_process(child, resume=True)
        self.assertTrue(h.handoff(str(self.root))['dryRun'])
        h.cleanup(str(self.root), True)

    def test_process_exit_releases_lock_but_never_adopts_partial_preparation(self):
        child = self.process('prepare', pause='write-' + h.PREPARED)
        self.wait_paused(child, 'prepare')
        before = self.snapshot_root()
        child.kill()
        child.communicate(timeout=10)
        for operation in ('handoff', 'cleanup', 'record-signed'):
            refused = self.finish_process(self.process(operation), expected=2)
            self.assertNotIn('busy', refused['error'])
            self.assertEqual(refused['inventoryCalls'], 1)
            self.assertEqual(self.snapshot_root(), before)
        self.assertFalse((self.root/h.PREPARED).exists())

    def test_process_dry_run_locks_without_files_and_releases_for_apply(self):
        self.prepare()
        before = self.snapshot_root()
        child = self.process('handoff', mode='dry', pause='linked-1')
        self.wait_paused(child, 'handoff')
        self.assert_busy_process('cleanup')
        self.assertEqual(self.snapshot_root(), before)
        result = self.finish_process(child, resume=True)
        self.assertTrue(result['result']['dryRun'])
        self.assertEqual(self.snapshot_root(), before)
        self.assertEqual(set(os.listdir(self.root)), {f.APP, 'provenance.json', 'empty-entitlements.plist', h.PREPARED})
        h.cleanup(str(self.root), True)

    def test_refusal_releases_lock_for_a_later_operation(self):
        self.prepare()
        path = self.root/'empty-entitlements.plist'
        original = path.read_bytes()
        path.write_bytes(b'changed')
        with self.assertRaises(f.Refused): h.handoff(str(self.root), True)
        path.write_bytes(original)
        self.assertTrue(h.handoff(str(self.root))['dryRun'])
        h.cleanup(str(self.root), True)

    def test_dry_plan_concrete_targets_no_writes(self):
        plan = self.prepare(False)
        self.assertTrue(plan['dryRun'])
        self.assertEqual(plan['insideOutTargets'], [str(self.root/n) for n in h.TARGETS])
        self.assertFalse(self.root.exists())
        self.assertEqual((self.source/'artifact-manifest.json').read_bytes(), self.source_manifest)

    def test_copy_preserves_source_and_has_independent_inventory(self):
        self.prepare()
        self.assertEqual((self.source/'artifact-manifest.json').read_bytes(), self.source_manifest)
        fd, _ = f.validated_artifact(str(self.source)); os.close(fd)
        self.assertFalse((self.root/'build.log').exists())
        record = json.loads((self.root/h.PREPARED).read_bytes())
        provenance = json.loads((self.root/'provenance.json').read_bytes())
        self.assertEqual(provenance['sourceManifest']['sha256'], h.hashlib.sha256(self.source_manifest).hexdigest())
        for name in h.BINARIES:
            self.assertEqual((self.source/name).read_bytes(), (self.root/name).read_bytes())
            self.assertNotEqual((self.source/name).stat().st_ino, record['entries'][name]['inode'])

    def test_self_signed_requires_explicit_failure_acknowledgement(self):
        with self.assertRaises(f.Refused): self.prepare(False, 'self-signed')
        self.assertFalse(self.root.exists())
        self.assertEqual(self.prepare(False, 'self-signed', True)['requestedProfile'], 'self-signed')
        with self.assertRaises(f.Refused): self.prepare(False, 'personal-team', True)

    def test_existing_destination_never_adopted(self):
        self.root.mkdir(mode=0o700)
        f.write_new(self.root/'unrelated', b'keep')
        self.assert_preserved(lambda: self.prepare())

    def test_invalid_destination_and_symlink_rejected(self):
        for value in ('/private/tmp', str(self.root).lower(), str(self.root) + '/child', str(self.root) + '/../other'):
            with self.assertRaises((f.Refused, ValueError)):
                h.prepare(str(self.source), value, 'personal-team')
        self.root.symlink_to(self.source, target_is_directory=True)
        with self.assertRaises(f.Refused): self.prepare()

    def test_source_content_change_refused(self):
        (self.source/h.BINARIES[0]).write_bytes(macho() + b'drift')
        with self.assertRaises(f.Refused): self.prepare()
        self.assertFalse(self.root.exists())

    def test_source_symlink_refused_without_following(self):
        (self.source/'artifact-manifest.json').unlink()
        (self.source/f.APP/'Contents/external').symlink_to('/unopened-outside-fixture')
        f.seal_artifact(self.source)
        self.calls.clear()
        with self.assertRaises(f.Refused): self.prepare()
        self.assertFalse(self.root.exists())
        self.assertEqual(self.calls, [])

    def test_source_hardlink_refused(self):
        os.link(self.source/h.BINARIES[0], self.source/f.APP/'Contents/hardlink')
        with self.assertRaises(f.Refused): self.prepare()
        self.assertFalse(self.root.exists())

    def test_source_drift_during_copy_leaves_partial_without_manifest(self):
        original = h.read_bytes
        count = [0]
        def drift(fd, name):
            data = original(fd, name)
            count[0] += 1
            if count[0] == 5:
                (self.source/'build.log').write_bytes(b'changed concurrently')
            return data
        with patch.object(h, 'read_bytes', side_effect=drift):
            with self.assertRaises(f.Refused): self.prepare()
        self.assertTrue(self.root.exists())
        self.assertFalse((self.root/h.PREPARED).exists())
        self.assert_preserved(lambda: h.cleanup(str(self.root), True))

    def test_pre_handoff_cleanup_dry_apply_repeat(self):
        self.prepare()
        self.assertTrue(h.cleanup(str(self.root))['dryRun'])
        self.assertTrue(self.root.exists())
        self.assertTrue(h.cleanup(str(self.root), True)['removed'])
        self.assertTrue(h.cleanup(str(self.root), True)['alreadyAbsent'])

    def test_cleanup_changed_content_mode_extra_file_refuses_before_unlink(self):
        self.prepare()
        path = self.root/'empty-entitlements.plist'
        original = path.read_bytes()
        path.write_bytes(b'changed')
        self.assert_preserved(lambda: h.cleanup(str(self.root), True))
        path.write_bytes(original)
        path.chmod(0o644)
        self.assert_preserved(lambda: h.cleanup(str(self.root), True))
        path.chmod(0o600)
        f.write_new(self.root/'artifact-manifest.json', b'ignored by old helper, forbidden here')
        self.assert_preserved(lambda: h.cleanup(str(self.root), True))

    def test_missing_prepared_record_never_adopted(self):
        self.prepare()
        (self.root/h.PREPARED).unlink()
        self.assert_preserved(lambda: h.cleanup(str(self.root), True))

    def test_root_identity_and_duplicate_json_refused(self):
        self.prepare()
        path = self.root/h.PREPARED
        value = json.loads(path.read_bytes()); value['rootIdentity']['inode'] += 1
        path.write_text(json.dumps(value))
        self.assert_preserved(lambda: h.handoff(str(self.root), True))
        path.write_bytes(path.read_bytes()[:-1] + b',"schema":1}')
        self.assert_preserved(lambda: h.cleanup(str(self.root), True))

    def test_handoff_preview_keeps_cleanup_available(self):
        self.prepare()
        plan = h.handoff(str(self.root))
        self.assertTrue(plan['dryRun'])
        self.assertNotIn('userOnlyCommands', plan)
        self.assertFalse((self.root/h.HANDOFF).exists())
        h.cleanup(str(self.root), True)

    def test_explicit_handoff_order_flags_no_signing_execution(self):
        result = self.issued()
        lines = result['userOnlyCommands'].splitlines()[3:]
        self.assertEqual(len(lines), 4)
        for line, name in zip(lines, h.TARGETS):
            self.assertTrue(line.endswith(str(self.root/name)))
            self.assertIn('--options runtime', line)
            self.assertIn('--timestamp=none', line)
            self.assertIn('"$S8_USER_SIGNING_IDENTITY"', line)
            self.assertNotIn('--deep', line)
        self.assertFalse(result['signingExecuted'])
        self.assertTrue((self.root/h.HANDOFF).exists())
        self.assert_preserved(lambda: h.handoff(str(self.root), True))

    def test_issued_handoff_blocks_cleanup_even_if_no_signing_occurred(self):
        self.issued()
        for apply in (False, True):
            self.assert_preserved(lambda: h.cleanup(str(self.root), apply))

    def test_handoff_marker_is_durable_before_commands_are_emitted(self):
        self.prepare()
        class CheckedOutput(io.StringIO):
            def write(inner, text):
                self.assertTrue((self.root/h.HANDOFF).exists())
                return super().write(text)
        output = CheckedOutput()
        with patch.object(h.sys, 'argv', ['signing-handoff.py', 'handoff', '--root', str(self.root), '--apply']):
            with contextlib.redirect_stdout(output): h.main()
        self.assertEqual(output.getvalue().count('/usr/bin/codesign --force --sign'), 4)

    def test_partial_handoff_write_never_emits_commands_or_allows_cleanup(self):
        self.prepare()
        original = f.write_new
        def partial(path, data, mode=0o600):
            original(path, data[:10], mode)
            raise OSError('synthetic write failure')
        output = io.StringIO()
        with patch.object(f, 'write_new', side_effect=partial):
            with contextlib.redirect_stdout(output):
                with self.assertRaises(OSError): h.handoff(str(self.root), True)
        self.assertEqual(output.getvalue(), '')
        self.assert_preserved(lambda: h.cleanup(str(self.root), True))

    def test_later_flags_and_symlink_substitution_refuse_handoff(self):
        self.prepare()
        path = self.root/h.BINARIES[0]
        os.chflags(path, stat.UF_IMMUTABLE)
        try:
            self.assert_preserved(lambda: h.handoff(str(self.root), True))
        finally: os.chflags(path, 0)
        path.unlink()
        path.symlink_to('/unopened-outside-fixture')
        self.assert_preserved(lambda: h.handoff(str(self.root), True))
        self.assertFalse((self.root/h.HANDOFF).exists())

    def test_changed_handoff_preflight_refused(self):
        self.prepare()
        (self.root/h.BINARIES[0]).chmod(0o600)
        self.assert_preserved(lambda: h.handoff(str(self.root), True))
        self.assertFalse((self.root/h.HANDOFF).exists())

    def test_signed_record_dry_apply_repeat_and_no_identity_claim(self):
        self.signed()
        result = h.record_signed(str(self.root))
        self.assertFalse((self.root/h.SIGNED).exists())
        self.assertFalse(result['profileVerified'])
        self.assertEqual(len(result['observations']), 4)
        h.record_signed(str(self.root), True)
        original = (self.root/h.SIGNED).read_bytes()
        self.assertTrue(h.record_signed(str(self.root), True)['alreadyRecorded'])
        self.assertEqual(original, (self.root/h.SIGNED).read_bytes())
        self.assertEqual((self.source/'artifact-manifest.json').read_bytes(), self.source_manifest)
        self.assert_preserved(lambda: h.cleanup(str(self.root), True))

    def test_ad_hoc_never_counts_as_real_signing(self):
        self.issued()
        self.assert_preserved(lambda: h.record_signed(str(self.root), True))
        self.assertFalse((self.root/h.SIGNED).exists())

    def test_signed_payload_modification_refused(self):
        self.signed()
        path = self.root/h.BINARIES[0]
        path.write_bytes(path.read_bytes().replace(b'PAYLOAD-ORIGINAL', b'PAYLOAD-CHANGED!'))
        self.assert_preserved(lambda: h.record_signed(str(self.root), True))

    def test_signed_non_signature_resource_change_refused(self):
        self.signed()
        path = self.root/f.APP/'Contents/Info.plist'
        path.write_bytes(path.read_bytes() + b'\n')
        self.assert_preserved(lambda: h.record_signed(str(self.root), True))

    def test_missing_extra_symlink_and_hardlink_signed_entries_refused(self):
        self.signed()
        extra = self.root/f.APP/'Contents/extra'
        extra.symlink_to('/unopened-outside-fixture')
        self.assert_preserved(lambda: h.record_signed(str(self.root), True))
        extra.unlink()
        os.link(self.root/h.BINARIES[0], extra)
        self.assert_preserved(lambda: h.record_signed(str(self.root), True))
        extra.unlink()
        (self.root/h.BINARIES[0]).unlink()
        self.assert_preserved(lambda: h.record_signed(str(self.root), True))

    def test_handoff_record_cannot_claim_unregistered(self):
        self.signed()
        path = self.root/h.HANDOFF
        record = json.loads(path.read_bytes()); record['registrationState'] = 'notRegistered'
        path.write_text(json.dumps(record))
        self.assert_preserved(lambda: h.record_signed(str(self.root), True))
        self.assert_preserved(lambda: h.cleanup(str(self.root), True))

    def test_both_get_task_allow_spellings_even_false_are_refused(self):
        self.signed()
        for key in ('get-task-allow', 'com.apple.security.get-task-allow', 'other'):
            for value in (True, False):
                self.entitlements = plistlib.dumps({key: value})
                self.assert_preserved(lambda: h.record_signed(str(self.root), True))

    def test_missing_malformed_entitlements_refused(self):
        self.signed()
        for data in (b'', b'not a plist', plistlib.dumps([])):
            self.entitlements = data
            self.assert_preserved(lambda: h.record_signed(str(self.root), True))

    def test_flags_are_numeric_not_runtime_substring(self):
        self.signed()
        for flags in (b'0x0(runtime)', b'0x10002(adhoc,runtime)', b'unknown(runtime)', b'0x2(adhoc)'):
            self.flags = flags
            self.assert_preserved(lambda: h.record_signed(str(self.root), True))

    def test_failed_tool_and_duplicate_flags_refused(self):
        self.signed()
        self.returncode = 1
        self.assert_preserved(lambda: h.record_signed(str(self.root), True))
        self.returncode = 0
        self.extra_metadata = b'CodeDirectory v=20500 flags=0x10000(runtime)\n'
        self.assert_preserved(lambda: h.record_signed(str(self.root), True))

    def test_timeout_preserves_copy_and_no_signed_manifest(self):
        self.signed()
        with patch.object(h.subprocess, 'run', side_effect=subprocess.TimeoutExpired('codesign', 15)):
            self.assert_preserved(lambda: h.record_signed(str(self.root), True))
        self.assertFalse((self.root/h.SIGNED).exists())

    def test_signed_inventory_drift_never_resealed(self):
        self.signed()
        h.record_signed(str(self.root), True)
        path = self.root/next(iter(h.RESOURCES))
        path.write_bytes(b'different signature resource')
        self.assert_preserved(lambda: h.record_signed(str(self.root), True))

    def test_change_during_verification_refused(self):
        self.signed()
        original = h.signature_check
        def changed(root, name):
            result = original(root, name)
            (self.root/'provenance.json').write_bytes(b'drift')
            return result
        with patch.object(h, 'signature_check', side_effect=changed):
            with self.assertRaises(f.Refused): h.record_signed(str(self.root), True)
        self.assertFalse((self.root/h.SIGNED).exists())


class PayloadTests(unittest.TestCase):
    def test_signature_resize_preserves_payload_hash(self):
        self.assertEqual(h.payload_hash(macho()), h.payload_hash(macho(b'longer synthetic signature' * 4)))

    def test_payload_and_command_changes_are_detected(self):
        expected = h.payload_hash(macho())
        for offset in (12, 28, 56, 120, 128):
            data = bytearray(macho()); data[offset] ^= 1
            self.assertNotEqual(h.payload_hash(data), expected)

    def test_malformed_macho_bounds_rejected(self):
        for data in (b'', macho()[:-1], macho() + b'extra', b'bad!' + macho()[4:]):
            with self.assertRaises(f.Refused): h.payload_hash(data)
        for offset, value in ((64, 0xffffffff), (16, 4097), (20, 0xffffffff), (36, 8), (104, 0x19), (108, 8), (112, 0), (116, 0)):
            data = bytearray(macho()); struct.pack_into('<I', data, offset, value)
            with self.assertRaises(f.Refused): h.payload_hash(data)


if __name__ == '__main__':
    unittest.main()
