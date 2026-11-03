"""SYNTHETIC transaction/PF tests. No /dev/pf, real pfctl, sockets or UID changes.
Only the ACL test changes permissions on its own temporary file, without root.
"""
import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import platform
import pwd
import subprocess
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("pf_lab", HERE / "pf_lab.py")
pf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pf)
spec = importlib.util.spec_from_file_location("renderer", HERE / "renderer.py")
renderer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renderer)
CONFIG = json.loads((HERE / "fixtures/config.json").read_text())
TEMPLATE = (HERE / "templates/deny.pf.in").read_text()


class MemoryJournal:
    def __init__(self):
        self.records = []
        self.fail_next = False

    def latest(self):
        return copy.deepcopy(self.records[-1]) if self.records else None

    def ensure_capacity(self, count):
        pf.require(len(self.records) + count <= pf.MAX_RECORDS, "MOCK capacity")

    def append(self, record):
        if self.fail_next:
            raise OSError("MOCK fsync failure")
        self.records.append(copy.deepcopy(record))


class FakeSystem:
    def __init__(self, journal):
        self.journal = journal
        self.rules = ""
        self.info = "Status: Enabled for 0 days\n"
        self.root = 'anchor "sanjbox_c1" all\nanchor "com.apple/*" all\n'
        self.nat = self.children = self.tables = ""
        self.accounts = {z["name"]: z["uid"] for z in CONFIG["zones"]}
        self.processes = "0 0\n501 501\n"
        self.writes = []
        self.calls = []
        self.failure = None

    def account_uid(self, name):
        return self.accounts[name]

    def run(self, argv, data=None):
        self.calls.append((argv, data))
        if argv == ["/bin/ps", "-axo", "ruid=,uid="]:
            return self.processes
        if argv == ["/sbin/pfctl", "-s", "info"]:
            return self.info
        if argv == ["/sbin/pfctl", "-sr"]:
            return self.root
        prefix = ["/sbin/pfctl", "-a", "sanjbox_c1"]
        if argv == prefix + ["-sr"]: return self.rules
        if argv == prefix + ["-sn"]: return self.nat
        if argv == prefix + ["-s", "Anchors"]: return self.children
        if argv == prefix + ["-s", "Tables"]: return self.tables
        if argv == prefix + ["-n", "-R", "-o", "none", "-f", "-"]:
            return ""  # MOCK parser only; this proves no Darwin syntax/semantics.
        if argv == prefix + ["-R", "-o", "none", "-f", "-"]:
            assert self.journal.latest()["phase"] == ("prepared_load" if data else "prepared_unload")
            if self.failure == "before":
                raise pf.Refused("MOCK failure before write")
            self.writes.append(data)
            self.rules = data.replace("from any to any", "all")
            for zone in CONFIG["zones"]:
                self.rules = self.rules.replace(f'user {zone["uid"]} ', f'user = {zone["name"]} ')
            if self.failure == "after":
                raise pf.Refused("MOCK process death after kernel accepted load")
            return ""
        raise AssertionError(f"forbidden/unexpected command: {argv}")


class Transactions(unittest.TestCase):
    def setUp(self):
        self.journal = MemoryJournal()
        self.system = FakeSystem(self.journal)

    def run_action(self, action):
        return pf.transact(action, CONFIG, TEMPLATE, self.journal, self.system)

    def test_load_repeat_unload_repeat(self):
        self.run_action("load")
        self.run_action("load")
        self.run_action("unload")
        self.run_action("unload")
        self.assertEqual(len(self.system.writes), 2)
        self.assertEqual([r["phase"] for r in self.journal.records], ["prepared_load", "loaded", "prepared_unload", "unloaded"])
        self.assertEqual(self.system.writes[-1], "")

    def test_crash_after_load_before_confirmation_is_recoverable(self):
        self.system.failure = "after"
        with self.assertRaises(pf.Refused): self.run_action("load")
        self.assertEqual(self.journal.latest()["phase"], "prepared_load")
        self.system.failure = None
        self.run_action("unload")
        self.assertEqual(len(self.system.writes), 2)

    def test_crash_after_unload_before_confirmation_is_idempotent(self):
        self.run_action("load")
        self.system.failure = "after"
        with self.assertRaises(pf.Refused): self.run_action("unload")
        self.system.failure = None
        self.run_action("unload")
        self.assertEqual(len(self.system.writes), 2)

    def test_crash_before_load_does_not_claim_other_rules(self):
        self.system.failure = "before"
        with self.assertRaises(pf.Refused): self.run_action("load")
        self.system.failure = None
        self.system.rules = "pass out all\n"
        with self.assertRaises(pf.Refused): self.run_action("unload")
        self.assertEqual(self.system.writes, [])

    def test_journal_failure_prevents_write(self):
        self.journal.fail_next = True
        with self.assertRaises(OSError): self.run_action("load")
        self.assertEqual(self.system.writes, [])

    def test_refuse_missing_or_conditional_parent(self):
        for root in ("", 'pass quick all\nanchor "sanjbox_c1" all\n', 'anchor "sanjbox_c1" out all\n', 'anchor "sanjbox_c1/*" all\n'):
            self.system.root = root
            with self.assertRaises(pf.Refused): self.run_action("load")
        self.assertEqual(self.system.writes, [])

    def test_refuse_disabled_foreign_descendants_nat_tables_and_uid_conflict(self):
        for field, value in (("info", "Status: Disabled\n"), ("children", "foreign\n"), ("nat", "rdr all\n"), ("tables", "foreign\n"), ("processes", "4501 4501\n"), ("processes", "4501 0\n")):
            old = getattr(self.system, field)
            setattr(self.system, field, value)
            with self.assertRaises(pf.Refused): self.run_action("load")
            setattr(self.system, field, old)
        self.system.accounts["snjt1"] = 501
        with self.assertRaises(pf.Refused): self.run_action("load")
        self.assertEqual(self.system.writes, [])

    def test_unload_refuses_live_zone(self):
        self.run_action("load")
        self.system.processes += "4501 4501\n"
        with self.assertRaises(pf.Refused): self.run_action("unload")
        self.assertEqual(len(self.system.writes), 1)

    def test_modified_parent_or_own_rules_never_overwritten(self):
        self.run_action("load")
        root = self.system.root
        self.system.root += "block in all\n"
        with self.assertRaises(pf.Refused): self.run_action("unload")
        self.system.root = root
        self.system.rules += "pass out all\n"
        with self.assertRaises(pf.Refused): self.run_action("unload")
        self.assertEqual(len(self.system.writes), 1)

    def test_rules_reappearing_after_cleanup_refused(self):
        self.run_action("load")
        rules = self.system.rules
        self.run_action("unload")
        self.system.rules = rules
        with self.assertRaises(pf.Refused): self.run_action("unload")
        self.assertEqual(len(self.system.writes), 2)

    def test_loaded_rules_lost_no_silent_reload(self):
        self.run_action("load")
        self.system.rules = ""
        with self.assertRaises(pf.Refused): self.run_action("load")
        self.run_action("unload")
        self.assertEqual(len(self.system.writes), 1)

    def test_unload_without_ownership_never_writes(self):
        with self.assertRaises(pf.Refused): self.run_action("unload")
        self.assertEqual(self.system.writes, [])

    def test_change_between_journal_and_mutation_refused(self):
        append = self.journal.append
        def drift(record):
            append(record)
            self.system.rules = "pass out all\n"
        self.journal.append = drift
        with self.assertRaises(pf.Refused): self.run_action("load")
        self.assertEqual(self.system.writes, [])

    def test_last_journal_slot_cannot_start_mutation(self):
        self.run_action("load")
        self.journal.records += [copy.deepcopy(self.journal.records[-1]) for _ in range(29)]
        self.assertEqual(len(self.journal.records), 31)
        with self.assertRaises(pf.Refused): self.run_action("unload")
        self.assertEqual(len(self.system.writes), 1)

    def test_different_run_cannot_reuse_journal(self):
        self.run_action("load")
        config = copy.deepcopy(CONFIG)
        config["run_id"] = "other001"
        with self.assertRaises(pf.Refused): pf.transact("unload", config, TEMPLATE, self.journal, self.system)
        self.assertEqual(len(self.system.writes), 1)


class Validation(unittest.TestCase):
    def test_rule_normalization_variants_and_strictness(self):
        text = pf.render(CONFIG, TEMPLATE)
        expected = pf.expected_rules(CONFIG)
        self.assertEqual(len(expected), 24)
        self.assertEqual(pf.semantic_rules(text, CONFIG), expected)
        for variant in (text.replace("from any to any", "all"), text.replace("user ", "user = ")):
            self.assertEqual(pf.semantic_rules(variant, CONFIG), expected)
        for changed in (text.replace("drop", "return"), text.replace("quick ", ""), text + "pass all\n", text.replace("from any", "from 127.0.0.1")):
            with self.assertRaises(pf.Refused): pf.semantic_rules(changed, CONFIG)

    def test_injections_types_unknown_keys_and_bounds(self):
        for uid in (0, 399, 60001, True, "4501\npass all", 4501.0):
            c = copy.deepcopy(CONFIG); c["zones"][0]["uid"] = uid
            with self.assertRaises(pf.Refused): pf.config_checked(c)
        for run in ("../../tmp", "a;echo x", "a" * 13, "c1a00001\npass all"):
            c = copy.deepcopy(CONFIG); c["run_id"] = run
            with self.assertRaises(pf.Refused): pf.config_checked(c)
        c = copy.deepcopy(CONFIG); c["pfctl"] = "/tmp/evil"
        with self.assertRaises(pf.Refused): pf.config_checked(c)
        c = copy.deepcopy(CONFIG); c["zones"][0]["name"] = "root"
        with self.assertRaises(pf.Refused): pf.config_checked(c)
        with self.assertRaises(pf.Refused): pf.render(CONFIG, TEMPLATE + "pass out all\n")
        with self.assertRaises(pf.Refused): pf.strict_json('{"x":1,"x":2}')
        with self.assertRaises(pf.Refused): pf.strict_json("[" * 20000 + "]" * 20000)

    def test_transparent_templates_are_only_bounded_output(self):
        for family, address in ((4, "192.0.2.10"), (6, "2001:db8::10")):
            text = renderer.render(family, 4501, address, 18080, 18081, "c1a00001")
            self.assertIn("route-to", text)
            self.assertIn("tagged C1_c1a00001_4501", text)
            self.assertNotIn("@", text)
        for bad in ("127.0.0.1", "example.com", "192.0.2.10\npass all", "192.0.2.0/24", "::1"):
            with self.assertRaises(ValueError): renderer.render(4, 4501, bad, 18080, 18081, "c1a00001")

    def test_config_filename_restricts_sensitive_paths_before_read(self):
        for path in ("/tmp/.env", "/tmp/.ssh/config.json", "/tmp/credentials/config.json", "/tmp/Library/Keychains/config.json", "/tmp/config.txt", "../config.json"):
            with self.assertRaises(pf.Refused): pf.config_path_checked(path)

    def test_cli_dry_run_never_constructs_system_or_writes(self):
        with tempfile.TemporaryDirectory(prefix="c1-dry-") as directory:
            missing = Path(directory) / "state"
            with patch.object(pf, "System", side_effect=AssertionError("actual executor forbidden")), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(pf.main(["load", "--config", str(HERE / "fixtures/config.json"), "--state", str(missing)]), 0)
            self.assertFalse(missing.exists())


class Filesystem(unittest.TestCase):
    def test_symlink_hardlink_fifo_oversize_and_writable_input_refused(self):
        with tempfile.TemporaryDirectory(prefix="c1-path-") as directory:
            root = Path(directory).resolve()
            normal = root / "config.json"; normal.write_text("{}")
            link = root / "link"; link.symlink_to(normal)
            with self.assertRaises(OSError): pf.read_file(link)
            linked = root / "linked"; os.link(normal, linked)
            with self.assertRaises(pf.Refused): pf.read_file(normal)
            linked.unlink()
            normal.chmod(0o666)
            with self.assertRaises(pf.Refused): pf.read_file(normal)
            normal.chmod(0o600); normal.write_bytes(b"x" * (pf.MAX_FILE + 1))
            with self.assertRaises(pf.Refused): pf.read_file(normal)
            fifo = root / "fifo"; os.mkfifo(fifo)
            with self.assertRaises(pf.Refused): pf.read_file(fifo)
            directory_link = root / "alias"; directory_link.symlink_to(root, target_is_directory=True)
            with self.assertRaises(OSError): pf.read_file(directory_link / "config.json")

    def test_file_replacement_during_read_refused(self):
        with tempfile.TemporaryDirectory(prefix="c1-race-") as directory:
            path = Path(directory).resolve() / "fixture"
            path.write_text("{}")
            real_read = os.read
            def replaced(fd, size):
                result = real_read(fd, size)
                if result:
                    path.unlink(); path.write_text("{}")
                return result
            with patch.object(pf.os, "read", side_effect=replaced):
                with self.assertRaises(pf.Refused): pf.read_file(path)

    @unittest.skipUnless(platform.system() == "Darwin", "native Darwin ACL semantics")
    def test_native_acl_absent_allowed_extended_write_denied(self):
        # Only our new temporary file. No protected roots/system settings touched.
        with tempfile.TemporaryDirectory(prefix="c1-acl-") as directory:
            path = Path(directory).resolve() / "fixture"
            path.write_text("synthetic fixture")
            fd = os.open(path, os.O_RDONLY)
            try:
                pf.reject_extended_acl(fd)
                user = pwd.getpwuid(os.getuid()).pw_name
                subprocess.run(["/bin/chmod", "+a", f"user:{user} allow write", str(path)], check=True, capture_output=True)
                with self.assertRaises(pf.Refused): pf.reject_extended_acl(fd)
            finally:
                os.close(fd)

    @unittest.skipUnless(platform.system() == "Darwin", "native Darwin journal ACL check")
    def test_disk_journal_private_append_lock_and_corruption(self):
        with tempfile.TemporaryDirectory(prefix="c1-journal-") as directory:
            fd = os.open(Path(directory).resolve(), os.O_RDONLY | os.O_DIRECTORY)
            journal = pf.Journal(fd)
            try:
                journal.append({"synthetic": 1})
                self.assertEqual(journal.latest(), {"synthetic": 1})
                with self.assertRaises(BlockingIOError): pf.Journal(fd)
                record = Path(directory) / "0001.json"
                self.assertEqual(record.stat().st_mode & 0o777, 0o600)
                record.write_text("{")
                with self.assertRaises(pf.Refused): journal.latest()
            finally:
                journal.close(); os.close(fd)


if __name__ == "__main__":
    unittest.main()
