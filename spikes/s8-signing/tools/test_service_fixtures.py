#!/usr/bin/env python3
"""Synthetic filesystem boundaries; never runs a service, app, compiler or signing tool."""
import importlib.util
import json
import os
from pathlib import Path
import stat
import unittest
import uuid

spec = importlib.util.spec_from_file_location('fixtures', Path(__file__).with_name('service-fixtures.py'))
f = importlib.util.module_from_spec(spec); spec.loader.exec_module(f)

class ProvenanceTests(unittest.TestCase):
    def test_h1_dependency_is_in_source_inventory(self):
        hashes = f.source_hashes()
        contract_root = f.PACKAGE.parent.parent/'proto'/'contracts'
        expected = [contract_root/'Package.swift'] + list((contract_root/'Sources').rglob('*.swift'))
        self.assertGreater(len(expected), 1)
        for path in expected:
            key = os.path.relpath(path, f.PACKAGE)
            self.assertEqual(hashes[key], f.hashlib.sha256(path.read_bytes()).hexdigest())

class ArtifactTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(f.PREFIX + str(uuid.uuid4()).upper())
        self.root.mkdir(mode=0o700)
        f.write_new(self.root/'fixture', b'synthetic')
        f.seal_artifact(self.root)
    def tearDown(self):
        # Only test-owned files at the exact just-created root, no recursive external cleanup.
        if self.root.exists():
            for name in os.listdir(self.root):
                path = self.root/name
                if path.is_dir() and not path.is_symlink(): path.rmdir()
                else: path.unlink()
            self.root.rmdir()
    def test_dry_run_and_repeat_cleanup(self):
        f.cleanup(str(self.root), False)
        self.assertTrue((self.root/'fixture').exists())
        f.cleanup(str(self.root), True)
        self.assertFalse(self.root.exists())
        f.cleanup(str(self.root), True)
    def test_content_conflict_changes_nothing(self):
        (self.root/'fixture').write_bytes(b'changed')
        with self.assertRaises(f.Refused): f.cleanup(str(self.root), True)
        self.assertTrue((self.root/'artifact-manifest.json').exists())
    def test_mode_conflict_changes_nothing(self):
        (self.root/'fixture').chmod(0o644)
        with self.assertRaises(f.Refused): f.cleanup(str(self.root), True)
        self.assertTrue((self.root/'fixture').exists())
    def test_symlink_substitution_is_not_followed(self):
        (self.root/'fixture').unlink()
        (self.root/'fixture').symlink_to('/unopened-outside-fixture')
        with self.assertRaises(f.Refused): f.cleanup(str(self.root), True)
        self.assertTrue((self.root/'fixture').is_symlink())
    def test_hardlink_is_refused(self):
        os.link(self.root/'fixture', self.root/'second')
        with self.assertRaises(f.Refused): f.cleanup(str(self.root), True)
    def test_extra_file_is_refused_before_any_unlink(self):
        f.write_new(self.root/'extra', b'extra')
        with self.assertRaises(f.Refused): f.cleanup(str(self.root), True)
        self.assertEqual((self.root/'fixture').read_bytes(), b'synthetic')
    def test_root_inode_mismatch_is_refused(self):
        manifest = self.root/'artifact-manifest.json'
        value = json.loads(manifest.read_bytes()); value['inode'] += 1
        manifest.write_text(json.dumps(value))
        with self.assertRaises(f.Refused): f.cleanup(str(self.root), True)
    def test_flags_conflict_is_refused(self):
        path = self.root/'fixture'
        os.chflags(path, stat.UF_IMMUTABLE)
        try:
            with self.assertRaises(f.Refused): f.cleanup(str(self.root), True)
        finally: os.chflags(path, 0)
    def test_unscoped_paths_and_invalid_uuid_are_rejected(self):
        for root in ['/private/tmp', f.PREFIX+'../elsewhere', f.PREFIX+str(uuid.uuid4())]:
            with self.assertRaises((f.Refused, ValueError)): f.cleanup(root, True)
    def test_duplicate_manifest_keys_are_refused(self):
        path = self.root/'artifact-manifest.json'
        path.write_bytes(path.read_bytes()[:-1] + b',"schema":1}')
        with self.assertRaises(f.Refused): f.cleanup(str(self.root), True)
    def test_internal_build_symlinks_removed_without_traversal(self):
        (self.root/'artifact-manifest.json').unlink()
        (self.root/'release').symlink_to('fixture')
        f.seal_artifact(self.root)
        f.cleanup(str(self.root), True)
        self.assertFalse(self.root.exists())

class EventTests(unittest.TestCase):
    def setUp(self):
        self.run = str(uuid.uuid4()).upper(); self.session = 77
        self.root = Path(f.EVENT_PREFIX + str(uuid.uuid4()).upper())
        self.root.mkdir(mode=0o700)
        value = {'runID':self.run, 'context':{'effectiveUID':os.geteuid(), 'audit':{'sessionID':self.session}}}
        f.write_new(self.root/'event.json', json.dumps(value).encode())
        rs = self.root.stat(); es = (self.root/'event.json').stat()
        m = {'schema':1,'kind':'s8-event-cleanup','runID':self.run,'session':self.session,
             'ownerUID':rs.st_uid,'ownerGID':rs.st_gid,'rootDevice':rs.st_dev,'rootInode':rs.st_ino,
             'eventInode':es.st_ino,'eventSHA256':f.hashlib.sha256((self.root/'event.json').read_bytes()).hexdigest()}
        f.write_new(self.root/'manifest.json', json.dumps(m).encode())
    def tearDown(self):
        if self.root.exists():
            for p in self.root.iterdir(): p.unlink()
            self.root.rmdir()
    def test_exact_event_dry_apply_repeat(self):
        f.cleanup_event(str(self.root), self.run, self.session, False)
        self.assertTrue(self.root.exists())
        f.cleanup_event(str(self.root), self.run, self.session, True)
        f.cleanup_event(str(self.root), self.run, self.session, True)
    def test_wrong_run_or_session_never_unlinks(self):
        for run, session in [(str(uuid.uuid4()).upper(), self.session), (self.run, 78)]:
            with self.assertRaises(f.Refused): f.cleanup_event(str(self.root), run, session, True)
        self.assertTrue((self.root/'event.json').exists())
    def test_event_content_change_is_conflict(self):
        (self.root/'event.json').write_bytes(b'{}')
        with self.assertRaises(f.Refused): f.cleanup_event(str(self.root), self.run, self.session, True)
    def test_replaced_event_inode_is_conflict(self):
        value = (self.root/'event.json').read_bytes()
        (self.root/'event.json').rename(self.root/'old')
        f.write_new(self.root/'event.json', value)
        (self.root/'old').unlink()
        with self.assertRaises(f.Refused): f.cleanup_event(str(self.root), self.run, self.session, True)

if __name__ == '__main__': unittest.main()
