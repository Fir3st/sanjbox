"""WP1.B4 — synthetic tests for spikes/s4-state/apfs-pilot.sh.

The pilot script is a read-only planner. These tests never run a mutating path:
they exercise `bash -n`, dry-run, apply refusals and accepted hand-off with a
hermetic "live" probe whose commands are replaced by recording shims. Every
fixture is synthetic and lives under its own /private/tmp tree.
"""

import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

BASE = Path(__file__).resolve().parents[1]
SCRIPT = BASE / "apfs-pilot.sh"
PYTHON = "/usr/bin/python3"


def uuid(index):
    return "00000000-0000-4000-8000-%012d" % index


PLAN_SCHEMA = "sanjbox.apfs-pilot.plan.v1"
OUT_SCHEMA = "sanjbox.apfs-pilot.dry-run.v1"
RECEIPT_SCHEMA = "sanjbox.apfs-pilot.backup-receipt.v1"
BACKUP_DIGEST = "sha256:" + "a" * 64


def valid_plan():
    return {
        "schema": PLAN_SCHEMA,
        "pilotId": "wp1-b4-p0",
        "transactionLabel": "T-20261107-01",
        "pilotRoot": "/Volumes/SanjboxPilot",
        "pairs": [
            {
                "id": "A",
                "snapshotName": "sanjbox-b4-T-20261107-01-A",
                "source": {
                    "device": "disk9s1",
                    "expectedVolumeUUID": uuid(11),
                    "expectedContainerUUID": uuid(1),
                },
                "target": {
                    "device": "disk9s2",
                    "expectedVolumeUUID": uuid(12),
                    "expectedContainerUUID": uuid(1),
                },
            }
        ],
    }


def valid_receipt(backup_digest=None):
    document = {
        "schema": RECEIPT_SCHEMA,
        "pilotId": "wp1-b4-p0",
        "transactionLabel": "T-20261107-01",
        "createdAt": "2026-11-07T12:00:00Z",
        "backupLocation": "/Volumes/Backup/synthetic-pilot-receipt",
        "coversDevices": ["disk9s1", "disk9s2"],
    }
    if backup_digest is not None:
        document["backupDigest"] = backup_digest
    return document


def volume_entry(device, volume_uuid, name, quota=0, reserve=0, roles=None):
    entry = {
        "DeviceIdentifier": device,
        "APFSVolumeUUID": volume_uuid,
        "Name": name,
        "CapacityQuota": quota,
        "CapacityReserve": reserve,
        "CapacityInUse": 4096,
        "Locked": False,
    }
    if roles:
        entry["Roles"] = roles
    return entry


def apfs_list(volumes_by_container):
    containers = []
    for index, (container_uuid, store, volumes) in enumerate(volumes_by_container, start=1):
        containers.append(
            {
                "APFSContainerUUID": container_uuid,
                "DesignatedPhysicalStore": store,
                "CapacityCeiling": 1024 * 1024,
                "CapacityFree": 512 * 1024,
                "Volumes": volumes,
            }
        )
    return {"Containers": containers}


def volume_info(device, volume_uuid, mountpoint="", sealed="No", bootable=False, writable=True):
    return {
        "DeviceIdentifier": device,
        "VolumeUUID": volume_uuid,
        "VolumeName": "Pilot" + device,
        "MountPoint": mountpoint,
        "Writable": writable,
        "Sealed": sealed,
        "Bootable": bootable,
        "FilesystemType": "apfs",
        "APFSSnapshot": False,
        "APFSContainerReference": "disk9",
    }


class PilotTree(object):
    """Synthetic plan + captured probe fixtures + a private output directory."""

    def __init__(self, system_source=False, mounted_target=True, quota=0, source_quota=None,
                 target_quota=None):
        source_quota = quota if source_quota is None else source_quota
        target_quota = quota if target_quota is None else target_quota
        self.root = Path(tempfile.mkdtemp(prefix="sanjbox-b4-apfs-tests.", dir="/private/tmp"))
        os.chmod(str(self.root), 0o700)
        self.fixtures = self.root / "fixtures"
        self.out = self.root / "out"
        self.fixtures.mkdir(mode=0o700)
        self.out.mkdir(mode=0o700)
        source_roles = ["System"] if system_source else None
        self.write_plist(
            "apfs-list.plist",
            apfs_list(
                [
                    (
                        uuid(1),
                        "disk9s0",
                        [
                            volume_entry(
                                "disk9s1", uuid(11), "PilotSource", quota=source_quota,
                                roles=source_roles
                            ),
                            volume_entry("disk9s2", uuid(12), "PilotTarget", quota=target_quota),
                        ],
                    ),
                    (
                        uuid(2),
                        "disk8s0",
                        [volume_entry("disk8s1", uuid(21), "System", roles=["System"])],
                    ),
                ]
            ),
        )
        target_mount = "/Volumes/SanjboxPilot/target" if mounted_target else ""
        self.write_plist("volume-info-disk9s1.plist", volume_info("disk9s1", uuid(11)))
        self.write_plist(
            "volume-info-disk9s2.plist",
            volume_info("disk9s2", uuid(12), mountpoint=target_mount),
        )
        self.write_plist(
            "volume-info-disk8s1.plist",
            volume_info("disk8s1", uuid(21), mountpoint="/", sealed="Yes", bootable=True),
        )
        mount_lines = ["/dev/disk3s1s1 on / (apfs, sealed, local, read-only, journaled)"]
        if target_mount:
            mount_lines.append("/dev/disk9s2 on %s (apfs, local)" % target_mount)
        (self.fixtures / "mount.txt").write_text("\n".join(mount_lines) + "\n")
        (self.fixtures / "bootsessionuuid.txt").write_text(uuid(99) + "\n")
        self.plan_path = self.root / "plan.json"
        self.write_json(self.plan_path, valid_plan())

    def write_plist(self, name, document):
        with open(str(self.fixtures / name), "wb") as handle:
            plistlib.dump(document, handle, fmt=plistlib.FMT_XML)

    @staticmethod
    def write_json(path, document):
        path.write_text(json.dumps(document, indent=2) + "\n")

    def receipt_path(self, document=None):
        path = self.root / "receipt.json"
        self.write_json(path, valid_receipt() if document is None else document)
        return path

    def plan_file(self, document):
        path = self.root / "plan-custom.json"
        self.write_json(path, document)
        return path

    def tree_hashes(self):
        hashes = {}
        for path in sorted(self.root.rglob("*")):
            relative = str(path.relative_to(self.root))
            if path.is_file():
                hashes[relative] = hashlib.sha256(path.read_bytes()).hexdigest()
            else:
                hashes[relative] = "dir"
        return hashes

    def out_entries(self):
        return sorted(entry.name for entry in self.out.iterdir())

    def cleanup(self):
        root = str(self.root)
        if not root.startswith("/private/tmp/sanjbox-b4-apfs-tests."):
            raise AssertionError("refusing to clean an unexpected path: " + root)
        if os.path.islink(root) or not os.path.isdir(root):
            raise AssertionError("refusing to clean a non-directory root: " + root)
        shutil.rmtree(root)


class PilotTestCase(unittest.TestCase):
    def setUp(self):
        self.tree = PilotTree()
        self.addCleanup(self.tree.cleanup)

    def run_script(self, *args, **kwargs):
        env = dict(os.environ)
        env.update(kwargs.pop("env", {}))
        return subprocess.run(
            ["/bin/bash", str(SCRIPT)] + list(args),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            timeout=120,
            check=False,
        )

    def dry_run(self, tree=None, extra=(), env=None):
        tree = tree or self.tree
        args = [
            "--plan",
            str(tree.plan_path),
            "--out-dir",
            str(tree.out),
            "--fixture-dir",
            str(tree.fixtures),
        ]
        return self.run_script(*(args + list(extra)), env=env or {})

    def shims(self, marker):
        shims = self.tree.root / "shims"
        shims.mkdir(mode=0o700)
        helpers = {
            "diskutil": (
                'case "$1 $2" in\n'
                '  "apfs list") cat "$APFS_PILOT_TEST_FIXTURES/apfs-list.plist" ;;\n'
                '  "info -plist") cat "$APFS_PILOT_TEST_FIXTURES/volume-info-$3.plist" ;;\n'
                '  *) echo "unexpected diskutil argv: $*" >&2; exit 99 ;;\n'
                "esac\n"
            ),
            "sysctl": (
                'case "$1 $2" in\n'
                '  "-n kern.bootsessionuuid") cat "$APFS_PILOT_TEST_FIXTURES/bootsessionuuid.txt" ;;\n'
                '  *) echo "unexpected sysctl argv: $*" >&2; exit 99 ;;\n'
                "esac\n"
            ),
            "mount": (
                '[[ $# -eq 0 ]] || { echo "unexpected mount argv: $*" >&2; exit 99; }\n'
                'cat "$APFS_PILOT_TEST_FIXTURES/mount.txt"\n'
            ),
        }
        for name, body in helpers.items():
            path = shims / name
            path.write_text(
                "#!/bin/bash\nset -euo pipefail\n"
                'printf "%s %s\\n" "$(basename "$0")" "$*" >> "$APFS_PILOT_TEST_LOG"\n' + body
            )
            os.chmod(str(path), 0o700)
        return shims


    def live_env(self, marker=None):
        marker = marker or (self.tree.root / "tool-invoked.log")
        shims = self.shims(marker)
        return {
            "APFS_PILOT_DISKUTIL": str(shims / "diskutil"),
            "APFS_PILOT_SYSCTL": str(shims / "sysctl"),
            "APFS_PILOT_MOUNT": str(shims / "mount"),
            "APFS_PILOT_TEST_LOG": str(marker),
            "APFS_PILOT_TEST_FIXTURES": str(self.tree.fixtures),
        }

    def plan_document(self, result=None):
        result = result or self.dry_run()
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        return json.loads(result.stdout.decode())


class SourceTests(unittest.TestCase):
    def test_bash_syntax_is_clean(self):
        result = subprocess.run(
            ["/bin/bash", "-n", str(SCRIPT)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False
        )
        self.assertEqual(result.returncode, 0, result.stderr.decode())

    def test_source_has_no_shell_eval_or_force_flags(self):
        text = SCRIPT.read_text()
        self.assertIn("set -euo pipefail", text)
        self.assertNotIn(" eval ", text)
        self.assertNotIn("--noprompt", text)
        self.assertNotIn("--fromSnapshot", text)
        self.assertNotIn("restoreexact", text)
        # The only generated asr form is the replication restore template.
        self.assertIn('"asr",\n                    "restore"', text)

    def test_forbidden_mount_prefix_has_no_dead_root_entry(self):
        text = SCRIPT.read_text()
        self.assertNotIn("FORBIDDEN_MOUNTS", text)
        self.assertIn('FORBIDDEN_MOUNT_PREFIXES = ("/System/Volumes/",)', text)
        self.assertEqual(text.count("FORBIDDEN_MOUNT_PREFIXES"), 2)


class DryRunTests(PilotTestCase):
    def test_dry_run_writes_only_its_declared_output(self):
        before = self.tree.tree_hashes()
        result = self.dry_run()
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        after = self.tree.tree_hashes()
        added = sorted(set(after) - set(before))
        self.assertEqual(added, ["out/apfs-pilot-plan.json"])
        changed = sorted(name for name in before if name in after and before[name] != after[name])
        self.assertEqual(changed, [])
        self.assertEqual(self.tree.out_entries(), ["apfs-pilot-plan.json"])

    def test_dry_run_json_matches_fixture_schema(self):
        doc = self.plan_document()
        self.assertEqual(
            set(doc),
            {
                "schema",
                "mode",
                "pilot",
                "probe",
                "preState",
                "gates",
                "steps",
                "cleanup",
                "userActions",
                "verdict",
            },
        )
        self.assertEqual(doc["schema"], OUT_SCHEMA)
        self.assertEqual(doc["mode"], "dry-run")
        self.assertEqual(
            set(doc["pilot"]),
            {"planSchema", "pilotId", "transactionLabel", "pilotRoot", "planSha256", "pairs"},
        )
        self.assertEqual(doc["pilot"]["planSchema"], PLAN_SCHEMA)
        self.assertEqual(len(doc["pilot"]["planSha256"]), 64)
        self.assertEqual(set(doc["probe"]), {"source", "bootSessionUUID", "commands", "limitations"})
        self.assertEqual(doc["probe"]["source"], "fixture-mock")
        self.assertEqual(doc["probe"]["commands"], [])
        self.assertEqual(doc["preState"]["bootSessionUUID"], uuid(99))
        self.assertEqual(
            [item["device"] for item in doc["preState"]["volumes"]], ["disk9s1", "disk9s2"]
        )
        source, target = doc["preState"]["volumes"]
        self.assertEqual(source["observed"]["volumeUUID"], uuid(11))
        self.assertEqual(source["observed"]["roles"], [])
        self.assertTrue(source["matchesExpectedVolumeUUID"])
        self.assertTrue(source["matchesExpectedContainerUUID"])
        self.assertTrue(target["observed"]["writable"])
        self.assertEqual(target["mountpoint"], "/Volumes/SanjboxPilot/target")
        self.assertEqual(doc["preState"]["containers"][0]["uuid"], uuid(1))
        self.assertEqual(doc["preState"]["mounts"][0]["mountpoint"], "/")
        for step in doc["steps"]:
            self.assertEqual(
                set(step),
                {
                    "phase",
                    "id",
                    "argv",
                    "argvTemplate",
                    "readOnly",
                    "rootRequired",
                    "executed",
                    "decision",
                    "reason",
                },
            )
            self.assertFalse(step["executed"])
        restore = [step for step in doc["steps"] if step["id"] == "asr-restore-A"][0]
        self.assertEqual(
            restore["argv"],
            [
                "asr",
                "restore",
                "--source",
                "/dev/disk9s1",
                "--target",
                "/dev/disk9s2",
                "--toSnapshot",
                "<snapshot-uuid-from-P1>",
                "--useReplication",
                "--erase",
            ],
        )
        self.assertTrue(restore["argvTemplate"])
        self.assertTrue(restore["rootRequired"])
        self.assertIsNone(
            [step for step in doc["steps"] if step["id"] == "snapshot-create-A"][0]["argv"]
        )
        self.assertEqual(
            [step for step in doc["steps"] if step["id"] == "switch-writable-state"][0]["decision"],
            "not-implemented",
        )
        delete = [step for step in doc["cleanup"]["steps"] if step["id"] == "delete-snapshot-A"][0]
        self.assertTrue(delete["rootRequired"])
        self.assertEqual(
            delete["argv"],
            [
                "diskutil",
                "apfs",
                "deleteSnapshot",
                "disk9s1",
                "-name",
                "sanjbox-b4-T-20261107-01-A",
                "-wait",
            ],
        )
        self.assertTrue(doc["cleanup"]["preconditions"])
        gate_ids = {gate["id"] for gate in doc["gates"]}
        self.assertLessEqual(
            {
                "plan-schema",
                "volume-observed",
                "identity-match",
                "non-system-volume",
                "distinct-volumes",
                "target-not-active",
                "whole-uid-interlock",
            },
            gate_ids,
        )
        interlock = [gate for gate in doc["gates"] if gate["id"] == "whole-uid-interlock"][0]
        self.assertEqual(interlock["status"], "manual")
        self.assertTrue(doc["verdict"]["gatesPassed"])
        self.assertFalse(doc["verdict"]["diskMutated"])
        self.assertFalse(doc["verdict"]["privilegedCommandExecuted"])
        self.assertFalse(doc["verdict"]["operatorCommandExecuted"])
        self.assertFalse(doc["verdict"]["realStartAllowed"])
        self.assertTrue(doc["verdict"]["identityChecked"])
        self.assertEqual(doc["verdict"]["inconclusiveGates"], [])
        self.assertEqual(doc["verdict"]["manualGates"], ["whole-uid-interlock"])
        support = [step for step in doc["steps"] if step["id"] == "asr-switch-support"][0]
        self.assertEqual(support["phase"], "P0")
        self.assertIsNone(support["argv"])
        for switch in ("--toSnapshot", "--useReplication", "--erase"):
            self.assertIn(switch, support["reason"])
        self.assertIn("asr help", support["reason"])

    def test_second_dry_run_is_byte_identical(self):
        first = self.dry_run()
        self.assertEqual(first.returncode, 0, first.stderr.decode())
        path = self.tree.out / "apfs-pilot-plan.json"
        first_bytes = path.read_bytes()
        first_stat = path.stat()
        second = self.dry_run()
        self.assertEqual(second.returncode, 0, second.stderr.decode())
        self.assertEqual(path.read_bytes(), first_bytes)
        self.assertEqual(second.stdout, first.stdout)
        self.assertEqual(path.stat().st_mtime_ns, first_stat.st_mtime_ns)
        self.assertIn(b"already identical", second.stderr)
        self.assertEqual(self.tree.out_entries(), ["apfs-pilot-plan.json"])

    def test_dry_run_never_shells_out_in_fixture_mode(self):
        marker = self.tree.root / "tool-invoked.log"
        shims = self.shims(marker)
        env = {
            "APFS_PILOT_DISKUTIL": str(shims / "diskutil"),
            "APFS_PILOT_SYSCTL": str(shims / "sysctl"),
            "APFS_PILOT_MOUNT": str(shims / "mount"),
        }
        result = self.dry_run(env=env)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertFalse(marker.exists(), marker.read_text() if marker.exists() else "")

    def test_live_probe_uses_only_documented_read_only_commands(self):
        marker = self.tree.root / "tool-invoked.log"
        result = self.run_script(
            "--plan",
            str(self.tree.plan_path),
            "--out-dir",
            str(self.tree.out),
            env=self.live_env(marker),
        )
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        doc = json.loads(result.stdout.decode())
        self.assertEqual(doc["probe"]["source"], "live-readonly")
        invoked = sorted(marker.read_text().splitlines())
        self.assertEqual(
            invoked,
            [
                "diskutil apfs list -plist",
                "diskutil info -plist disk9s1",
                "diskutil info -plist disk9s2",
                "mount ",
                "sysctl -n kern.bootsessionuuid",
            ],
        )
        # The recorded argv are exactly the documented read-only forms; the
        # shims reject anything else with exit 99, which would fail this run.
        tails = [command[1:] for command in doc["probe"]["commands"]]
        self.assertEqual(
            tails,
            [
                ["-n", "kern.bootsessionuuid"],
                ["apfs", "list", "-plist"],
                [],
                ["info", "-plist", "disk9s1"],
                ["info", "-plist", "disk9s2"],
            ],
        )
        shim_root = str(self.tree.root / "shims")
        self.assertTrue(
            all(command[0].startswith(shim_root + "/") for command in doc["probe"]["commands"])
        )

class GateTests(PilotTestCase):
    def test_system_role_volume_is_refused(self):
        tree = PilotTree(system_source=True)
        self.addCleanup(tree.cleanup)
        result = self.dry_run(tree=tree)
        self.assertEqual(result.returncode, 5, result.stderr.decode())
        doc = json.loads(result.stdout.decode())
        gate = [item for item in doc["gates"] if item["id"] == "non-system-volume"][0]
        self.assertEqual(gate["status"], "fail")
        self.assertIn("System", gate["detail"])
        self.assertFalse(doc["verdict"]["gatesPassed"])
        self.assertEqual(tree.out_entries(), ["apfs-pilot-plan.json"])

    def test_identity_mismatch_is_refused(self):
        plan = valid_plan()
        plan["pairs"][0]["source"]["expectedVolumeUUID"] = uuid(77)
        self.tree.plan_path = self.tree.plan_file(plan)
        result = self.dry_run()
        self.assertEqual(result.returncode, 5, result.stderr.decode())
        doc = json.loads(result.stdout.decode())
        gate = [item for item in doc["gates"] if item["id"] == "identity-match"][0]
        self.assertEqual(gate["status"], "fail")
        self.assertIn("A.source", gate["detail"])

    def test_mounted_target_outside_pilot_root_is_refused(self):
        tree = PilotTree(mounted_target=False)
        self.addCleanup(tree.cleanup)
        tree.write_plist(
            "volume-info-disk9s2.plist",
            volume_info("disk9s2", uuid(12), mountpoint="/Users/synthetic/state"),
        )
        (tree.fixtures / "mount.txt").write_text(
            "/dev/disk3s1s1 on / (apfs, sealed, local, read-only, journaled)\n"
            "/dev/disk9s2 on /Users/synthetic/state (apfs, local)\n"
        )
        result = self.dry_run(tree=tree)
        self.assertEqual(result.returncode, 5, result.stderr.decode())
        doc = json.loads(result.stdout.decode())
        gate = [item for item in doc["gates"] if item["id"] == "target-not-active"][0]
        self.assertEqual(gate["status"], "fail")


class ApplyRefusalTests(PilotTestCase):
    def apply(self, *extra, **kwargs):
        args = [
            "--apply",
            "--plan",
            str(self.tree.plan_path),
            "--out-dir",
            str(self.tree.out),
        ]
        return self.run_script(*(args + list(extra)), env=kwargs.get("env", {}))

    def test_apply_without_i_understand_is_refused(self):
        result = self.apply()
        self.assertEqual(result.returncode, 4)
        self.assertIn(b"--i-understand", result.stderr)
        self.assertEqual(self.tree.out_entries(), [])

    def test_apply_with_acknowledgement_but_no_receipt_is_refused(self):
        result = self.apply("--i-understand")
        self.assertEqual(result.returncode, 4)
        self.assertIn(b"--backup-receipt", result.stderr)
        self.assertEqual(self.tree.out_entries(), [])

    def test_apply_refuses_a_fixture_probe(self):
        result = self.apply(
            "--i-understand",
            "--fixture-dir",
            str(self.tree.fixtures),
            "--backup-receipt",
            str(self.tree.receipt_path()),
        )
        self.assertEqual(result.returncode, 4)
        self.assertIn(b"dry-run-only", result.stderr)
        self.assertEqual(self.tree.out_entries(), [])

    def test_receipt_without_full_coverage_is_refused(self):
        receipt = valid_receipt()
        receipt["coversDevices"] = ["disk9s1"]
        result = self.apply(
            "--i-understand",
            "--backup-receipt",
            str(self.tree.receipt_path(receipt)),
            env=self.live_env(),
        )
        self.assertEqual(result.returncode, 4, result.stderr.decode())
        self.assertIn(b"does not cover", result.stderr)
        self.assertEqual(self.tree.out_entries(), [])

    def test_receipt_for_a_different_transaction_is_refused(self):
        receipt = valid_receipt()
        receipt["transactionLabel"] = "T-other"
        result = self.apply(
            "--i-understand",
            "--backup-receipt",
            str(self.tree.receipt_path(receipt)),
            env=self.live_env(),
        )
        self.assertEqual(result.returncode, 4, result.stderr.decode())
        self.assertIn(b"transactionLabel", result.stderr)

    def test_apply_with_valid_receipt_is_handoff_only(self):
        marker = self.tree.root / "tool-invoked.log"
        receipt = self.tree.receipt_path(valid_receipt(BACKUP_DIGEST))
        result = self.run_script(
            "--apply",
            "--i-understand",
            "--plan",
            str(self.tree.plan_path),
            "--out-dir",
            str(self.tree.out),
            "--backup-receipt",
            str(receipt),
            env=self.live_env(marker),
        )
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        doc = json.loads(result.stdout.decode())
        self.assertEqual(doc["mode"], "apply-handoff")
        self.assertTrue(doc["verdict"]["handoffOnly"])
        self.assertFalse(doc["verdict"]["dryRunOnly"])
        self.assertFalse(doc["verdict"]["operatorCommandExecuted"])
        self.assertFalse(doc["verdict"]["diskMutated"])
        self.assertEqual(doc["backupReceipt"]["coversDevices"], ["disk9s1", "disk9s2"])
        self.assertEqual(doc["backupReceipt"]["backupDigest"], BACKUP_DIGEST)
        self.assertEqual(len(doc["backupReceipt"]["sha256"]), 64)
        self.assertEqual(self.tree.out_entries(), [])
        invoked = sorted(marker.read_text().splitlines())
        self.assertEqual(
            [line for line in invoked if line.startswith("asr") or "restore" in line], []
        )


class ReceiptDigestTests(PilotTestCase):
    def test_receipt_with_sha256_digest_is_accepted(self):
        receipt = valid_receipt(BACKUP_DIGEST)
        result = self.dry_run(
            extra=["--backup-receipt", str(self.tree.receipt_path(receipt))]
        )
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        doc = json.loads(result.stdout.decode())
        self.assertEqual(doc["backupReceipt"]["backupDigest"], BACKUP_DIGEST)

    def test_receipt_with_malformed_digest_is_refused(self):
        for digest in (
            "sha256:" + "A" * 64,
            "sha256:" + "a" * 63,
            "md5:" + "a" * 64,
            "sha256:xyz",
            "",
        ):
            with self.subTest(digest=digest):
                receipt = valid_receipt(digest)
                result = self.dry_run(
                    extra=["--backup-receipt", str(self.tree.receipt_path(receipt))]
                )
                self.assertEqual(result.returncode, 4, result.stderr.decode())
                self.assertIn(b"backupDigest", result.stderr)
                self.assertEqual(self.tree.out_entries(), [])


class ExitCodeContractTests(PilotTestCase):
    """The TOOLING exit-code table is executable: one case per documented class."""

    def dry_run_with_receipt(self, receipt):
        return self.dry_run(
            extra=["--backup-receipt", str(self.tree.receipt_path(receipt))]
        )

    def test_missing_receipt_key_is_a_receipt_refusal(self):
        receipt = valid_receipt()
        del receipt["backupLocation"]
        result = self.dry_run_with_receipt(receipt)
        self.assertEqual(result.returncode, 4, result.stderr.decode())
        self.assertIn(b"missing key(s)", result.stderr)
        self.assertIn(b"backupLocation", result.stderr)
        self.assertEqual(self.tree.out_entries(), [])

    def test_unknown_receipt_key_is_a_receipt_refusal(self):
        receipt = valid_receipt()
        receipt["force"] = True
        result = self.dry_run_with_receipt(receipt)
        self.assertEqual(result.returncode, 4, result.stderr.decode())
        self.assertIn(b"unknown key(s)", result.stderr)
        self.assertIn(b"force", result.stderr)
        self.assertEqual(self.tree.out_entries(), [])

    def test_wrong_receipt_type_is_a_receipt_refusal(self):
        receipt = valid_receipt()
        receipt["createdAt"] = 5
        result = self.dry_run_with_receipt(receipt)
        self.assertEqual(result.returncode, 4, result.stderr.decode())
        self.assertIn(b"createdAt", result.stderr)
        self.assertIn(b"non-empty string", result.stderr)
        self.assertEqual(self.tree.out_entries(), [])

    def test_nonexistent_receipt_file_is_an_input_error(self):
        result = self.dry_run(
            extra=["--backup-receipt", str(self.tree.root / "does-not-exist.json")]
        )
        self.assertEqual(result.returncode, 2, result.stderr.decode())
        self.assertIn(b"no such file", result.stderr)
        self.assertEqual(self.tree.out_entries(), [])

    def test_symlink_receipt_is_an_input_error(self):
        real = self.tree.receipt_path()
        link = self.tree.root / "receipt-link.json"
        os.symlink(str(real), str(link))
        result = self.dry_run(extra=["--backup-receipt", str(link)])
        self.assertEqual(result.returncode, 2, result.stderr.decode())
        self.assertIn(b"symlink refused", result.stderr)
        self.assertEqual(self.tree.out_entries(), [])

    def test_world_writable_receipt_is_an_input_error(self):
        receipt = self.tree.receipt_path()
        os.chmod(str(receipt), 0o666)
        result = self.dry_run(extra=["--backup-receipt", str(receipt)])
        self.assertEqual(result.returncode, 2, result.stderr.decode())
        self.assertIn(b"group/world writable refused", result.stderr)
        self.assertEqual(self.tree.out_entries(), [])


class IdentityTests(PilotTestCase):
    def apply(self, *extra, **kwargs):
        args = [
            "--apply",
            "--plan",
            str(self.tree.plan_path),
            "--out-dir",
            str(self.tree.out),
        ]
        return self.run_script(*(args + list(extra)), env=kwargs.get("env", {}))

    def plan_without_uuids(self):
        plan = valid_plan()
        for pair in plan["pairs"]:
            for side in ("source", "target"):
                pair[side].pop("expectedVolumeUUID", None)
                pair[side].pop("expectedContainerUUID", None)
        return plan

    def test_apply_without_declared_uuids_is_refused(self):
        self.tree.plan_path = self.tree.plan_file(self.plan_without_uuids())
        result = self.apply(
            "--i-understand",
            "--backup-receipt",
            str(self.tree.receipt_path()),
            env=self.live_env(),
        )
        self.assertEqual(result.returncode, 4, result.stderr.decode())
        self.assertIn(b"expectedVolumeUUID", result.stderr)
        self.assertEqual(self.tree.out_entries(), [])

    def test_apply_with_partial_container_identity_is_refused(self):
        plan = valid_plan()
        del plan["pairs"][0]["target"]["expectedContainerUUID"]
        self.tree.plan_path = self.tree.plan_file(plan)
        result = self.apply(
            "--i-understand",
            "--backup-receipt",
            str(self.tree.receipt_path()),
            env=self.live_env(),
        )
        self.assertEqual(result.returncode, 4, result.stderr.decode())
        self.assertIn(b"expectedContainerUUID", result.stderr)
        self.assertEqual(self.tree.out_entries(), [])

    def test_dry_run_without_declared_uuids_is_inconclusive(self):
        self.tree.plan_path = self.tree.plan_file(self.plan_without_uuids())
        result = self.dry_run()
        self.assertEqual(result.returncode, 5, result.stderr.decode())
        doc = json.loads(result.stdout.decode())
        gate = [item for item in doc["gates"] if item["id"] == "identity-match"][0]
        self.assertEqual(gate["status"], "inconclusive")
        self.assertIn("nothing was compared", gate["detail"])
        self.assertFalse(doc["verdict"]["identityChecked"])
        self.assertFalse(doc["verdict"]["gatesPassed"])
        self.assertEqual(doc["verdict"]["inconclusiveGates"], ["identity-match"])
        # The plan is still written so the operator can see the refusal reason.
        self.assertEqual(self.tree.out_entries(), ["apfs-pilot-plan.json"])


class QuotaTests(PilotTestCase):
    def test_single_zero_quota_volume_warns(self):
        tree = PilotTree(source_quota=4096, target_quota=0)
        self.addCleanup(tree.cleanup)
        result = self.dry_run(tree=tree)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        doc = json.loads(result.stdout.decode())
        gate = [item for item in doc["gates"] if item["id"] == "quota-declared"][0]
        self.assertEqual(gate["status"], "warn")
        self.assertIn("disk9s2", gate["detail"])

    def test_all_nonzero_quotas_pass(self):
        tree = PilotTree(source_quota=4096, target_quota=8192)
        self.addCleanup(tree.cleanup)
        result = self.dry_run(tree=tree)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        doc = json.loads(result.stdout.decode())
        gate = [item for item in doc["gates"] if item["id"] == "quota-declared"][0]
        self.assertEqual(gate["status"], "pass")


class PathSecurityTests(PilotTestCase):
    def test_out_dir_not_mode_0700_is_refused(self):
        os.chmod(str(self.tree.out), 0o755)
        result = self.dry_run()
        self.assertEqual(result.returncode, 2, result.stderr.decode())
        self.assertIn(b"mode must be 0700", result.stderr)
        self.assertEqual(self.tree.out_entries(), [])

    def test_plan_in_world_writable_parent_is_refused(self):
        shared = self.tree.root / "shared"
        shared.mkdir(mode=0o700)
        os.chmod(str(shared), 0o777)
        plan_path = shared / "plan.json"
        self.tree.write_json(plan_path, valid_plan())
        result = self.run_script(
            "--plan",
            str(plan_path),
            "--out-dir",
            str(self.tree.out),
            "--fixture-dir",
            str(self.tree.fixtures),
        )
        self.assertEqual(result.returncode, 2, result.stderr.decode())
        self.assertIn(b"parent directory is group/world writable", result.stderr)
        self.assertEqual(self.tree.out_entries(), [])


class ReviewRegressionTests(PilotTestCase):
    """PR 56 review regressions; apply uses only the rejecting recording shims."""

    def both_modes(self, receipt=None):
        receipt_path = self.tree.receipt_path(receipt)
        dry = self.dry_run(extra=["--backup-receipt", str(receipt_path)])
        if not hasattr(self, "review_env"):
            self.review_env = self.live_env()
        before_apply = self.tree.out_entries()
        apply = self.run_script(
            "--apply", "--i-understand", "--plan", str(self.tree.plan_path),
            "--out-dir", str(self.tree.out), "--backup-receipt", str(receipt_path),
            env=self.review_env,
        )
        self.assertEqual(self.tree.out_entries(), before_apply)
        return [("dry-run", dry), ("apply-handoff", apply)]

    def test_info_identity_mismatch_refuses_both_modes(self):
        for key, value in (("VolumeUUID", uuid(999)), ("DeviceIdentifier", "disk8s1")):
            info = volume_info("disk9s2", uuid(12), "/Volumes/SanjboxPilot/target")
            info[key] = value
            self.tree.write_plist("volume-info-disk9s2.plist", info)
            for mode, result in self.both_modes():
                with self.subTest(key=key, mode=mode):
                    self.assertEqual(result.returncode, 5, result.stderr.decode())
                    self.assertIn(b"identity mismatch", result.stderr)
                    self.assertEqual(result.stdout, b"")
                    self.assertEqual(self.tree.out_entries(), [])

    def test_missing_or_malformed_info_identity_refuses_both_modes(self):
        cases = [{}]
        for key in ("DeviceIdentifier", "VolumeUUID", "FilesystemType"):
            info = volume_info("disk9s2", uuid(12), "/Volumes/SanjboxPilot/target")
            del info[key]
            cases.append(info)
        info = volume_info("disk9s2", "not-a-uuid", "/Volumes/SanjboxPilot/target")
        cases.append(info)
        for index, info in enumerate(cases):
            self.tree.write_plist("volume-info-disk9s2.plist", info)
            for mode, result in self.both_modes():
                with self.subTest(case=index, mode=mode):
                    self.assertEqual(result.returncode, 6, result.stderr.decode())
                    self.assertIn(b"APFS identity metadata", result.stderr)
                    self.assertEqual(result.stdout, b"")
                    self.assertEqual(self.tree.out_entries(), [])

    def assert_mount_refusal(self, expected_busy=True):
        for mode, result in self.both_modes():
            with self.subTest(mode=mode):
                self.assertEqual(result.returncode, 5, result.stderr.decode())
                doc = json.loads(result.stdout)
                gates = {item["id"]: item for item in doc["gates"]}
                self.assertEqual(gates["mount-consistency"]["status"], "fail")
                self.assertEqual(gates["target-not-active"]["status"],
                                 "fail" if expected_busy else "pass")
                self.assertFalse(doc["verdict"]["gatesPassed"])

    def test_target_mount_outside_root_in_table_refuses_both_modes(self):
        (self.tree.fixtures / "mount.txt").write_text(
            "/dev/disk9s2 on /Users/synthetic/active (apfs, local)\n"
        )
        self.assert_mount_refusal()

    def test_target_info_unmounted_cannot_hide_table_mount(self):
        self.tree.write_plist("volume-info-disk9s2.plist", volume_info("disk9s2", uuid(12)))
        (self.tree.fixtures / "mount.txt").write_text(
            "/dev/disk9s2 on /Users/synthetic/active (apfs, local)\n"
        )
        self.assert_mount_refusal()

    def test_mount_disagreement_inside_pilot_root_is_still_refused(self):
        (self.tree.fixtures / "mount.txt").write_text(
            "/dev/disk9s2 on /Volumes/SanjboxPilot/other (apfs, local)\n"
        )
        self.assert_mount_refusal(expected_busy=False)

    def test_missing_mount_table_entry_is_not_unmounted_evidence(self):
        (self.tree.fixtures / "mount.txt").write_text("")
        self.assert_mount_refusal(expected_busy=False)

    def test_target_snapshot_mount_outside_root_refuses_both_modes(self):
        with (self.tree.fixtures / "mount.txt").open("a") as handle:
            handle.write("/dev/disk9s2s1 on /Users/synthetic/snapshot (apfs, read-only)\n")
        for mode, result in self.both_modes():
            with self.subTest(mode=mode):
                self.assertEqual(result.returncode, 5, result.stderr.decode())
                doc = json.loads(result.stdout)
                gates = {item["id"]: item for item in doc["gates"]}
                self.assertEqual(gates["mount-consistency"]["status"], "pass")
                self.assertEqual(gates["target-not-active"]["status"], "fail")
                self.assertIn("/Users/synthetic/snapshot", gates["target-not-active"]["detail"])
                self.assertIn("/dev/disk9s2s1", [item["device"] for item in doc["preState"]["mounts"]])

    def test_output_cannot_replace_plan_input(self):
        self.tree.plan_path = self.tree.out / "apfs-pilot-plan.json"
        self.tree.write_json(self.tree.plan_path, valid_plan())
        before = self.tree.plan_path.read_bytes()
        for attempt in range(2):
            result = self.dry_run()
            self.assertEqual(result.returncode, 2, result.stderr.decode())
            self.assertIn(b"output collides with an input", result.stderr)
            self.assertEqual(self.tree.plan_path.read_bytes(), before)

    def test_output_cannot_replace_receipt_input(self):
        path = self.tree.out / "apfs-pilot-plan.json"
        self.tree.write_json(path, valid_receipt())
        before = path.read_bytes()
        result = self.dry_run(extra=["--backup-receipt", str(path)])
        self.assertEqual(result.returncode, 2, result.stderr.decode())
        self.assertIn(b"output collides with an input", result.stderr)
        self.assertEqual(path.read_bytes(), before)

    def test_output_hardlinks_to_plan_or_receipt_are_refused(self):
        output = self.tree.out / "apfs-pilot-plan.json"
        receipt = self.tree.receipt_path()
        for path in (self.tree.plan_path, receipt):
            with self.subTest(input=path.name):
                os.link(str(path), str(output))
                before = path.read_bytes()
                inode = output.stat().st_ino
                result = self.dry_run(extra=["--backup-receipt", str(receipt)])
                self.assertEqual(result.returncode, 2, result.stderr.decode())
                self.assertIn(b"output collides with an input", result.stderr)
                self.assertEqual(path.read_bytes(), before)
                self.assertEqual(output.stat().st_ino, inode)
                output.unlink()

    def test_output_cannot_alias_any_captured_metadata_input(self):
        output = self.tree.out / "apfs-pilot-plan.json"
        for name in ("apfs-list.plist", "bootsessionuuid.txt", "mount.txt",
                     "volume-info-disk9s1.plist", "volume-info-disk9s2.plist"):
            with self.subTest(input=name):
                path = self.tree.fixtures / name
                os.link(str(path), str(output))
                before = path.read_bytes()
                inode = output.stat().st_ino
                result = self.dry_run()
                self.assertEqual(result.returncode, 2, result.stderr.decode())
                self.assertIn(b"output collides with an input", result.stderr)
                self.assertEqual(path.read_bytes(), before)
                self.assertEqual(output.stat().st_ino, inode)
                output.unlink()

    def test_identical_output_with_unsafe_mode_is_refused_without_rewrite(self):
        first = self.dry_run()
        self.assertEqual(first.returncode, 0, first.stderr.decode())
        path = self.tree.out / "apfs-pilot-plan.json"
        self.assertEqual(path.stat().st_mode & 0o7777, 0o600)
        before = path.read_bytes()
        inode = path.stat().st_ino
        for mode in (0o644, 0o666):
            with self.subTest(mode=oct(mode)):
                os.chmod(str(path), mode)
                result = self.dry_run()
                self.assertEqual(result.returncode, 2, result.stderr.decode())
                self.assertIn(b"output mode must be 0600", result.stderr)
                self.assertEqual(path.read_bytes(), before)
                self.assertEqual(path.stat().st_ino, inode)
                self.assertEqual(path.stat().st_mode & 0o7777, mode)

    def test_receipt_cover_types_refuse_without_traceback_in_both_modes(self):
        for covers in ([{}], [[]], [None], [True], [7], ["disk9s1", {}]):
            receipt = valid_receipt()
            receipt["coversDevices"] = covers
            for mode, result in self.both_modes(receipt):
                with self.subTest(covers=covers, mode=mode):
                    self.assertEqual(result.returncode, 4, result.stderr.decode())
                    self.assertIn(b"coversDevices entry", result.stderr)
                    self.assertNotIn(b"Traceback", result.stderr)
                    self.assertEqual(result.stdout, b"")
                    self.assertEqual(self.tree.out_entries(), [])

    def test_invalid_calendar_timestamp_refuses_both_modes(self):
        for created in ("2026-99-99T99:99:99Z", "2026-02-29T12:00:00Z",
                        "0000-01-01T00:00:00Z", "2026-11-07T24:00:00Z"):
            receipt = valid_receipt()
            receipt["createdAt"] = created
            for mode, result in self.both_modes(receipt):
                with self.subTest(created=created, mode=mode):
                    self.assertEqual(result.returncode, 4, result.stderr.decode())
                    self.assertIn(b"valid UTC calendar timestamp", result.stderr)
                    self.assertNotIn(b"Traceback", result.stderr)
                    self.assertEqual(result.stdout, b"")
                    self.assertEqual(self.tree.out_entries(), [])

    def test_valid_leap_day_timestamp_is_accepted_in_both_modes(self):
        receipt = valid_receipt()
        receipt["createdAt"] = "2024-02-29T23:59:59Z"
        for mode, result in self.both_modes(receipt):
            with self.subTest(mode=mode):
                self.assertEqual(result.returncode, 0, result.stderr.decode())
                doc = json.loads(result.stdout)
                self.assertEqual(doc["backupReceipt"]["createdAt"], receipt["createdAt"])
                self.assertFalse(doc["verdict"]["diskMutated"])


class ToolingDocumentationTests(unittest.TestCase):
    def test_test_hooks_and_exit_codes_are_documented(self):
        text = (BASE / "TOOLING.md").read_text()
        for hook in ("APFS_PILOT_DISKUTIL", "APFS_PILOT_SYSCTL", "APFS_PILOT_MOUNT"):
            self.assertIn(hook, text)
        for code in ("| 0 |", "| 2 |", "| 4 |", "| 5 |", "| 6 |"):
            self.assertIn(code, text)


class UsageTests(PilotTestCase):
    def test_unknown_argument_is_a_usage_error(self):
        result = self.dry_run(extra=["--noprompt"])
        self.assertEqual(result.returncode, 2)
        self.assertIn(b"unknown argument", result.stderr)

    def test_dry_run_and_apply_are_mutually_exclusive(self):
        result = self.run_script(
            "--dry-run",
            "--apply",
            "--plan",
            str(self.tree.plan_path),
            "--out-dir",
            str(self.tree.out),
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn(b"mutually exclusive", result.stderr)

    def test_plan_with_unknown_key_is_rejected(self):
        plan = valid_plan()
        plan["force"] = True
        self.tree.plan_path = self.tree.plan_file(plan)
        result = self.dry_run()
        self.assertEqual(result.returncode, 2)
        self.assertIn(b"unknown key", result.stderr)
        self.assertEqual(self.tree.out_entries(), [])

    def test_plan_outside_the_pilot_budget_is_rejected(self):
        plan = valid_plan()
        plan["pairs"] = plan["pairs"] * 3
        for index, pair in enumerate(plan["pairs"]):
            pair["id"] = "P%d" % index
            pair["snapshotName"] = "snap-%d" % index
        self.tree.plan_path = self.tree.plan_file(plan)
        result = self.dry_run()
        self.assertEqual(result.returncode, 2)
        self.assertIn(b"1..2 pairs", result.stderr)


if __name__ == "__main__":
    unittest.main()
