#!/bin/bash
# WP1.B4 / P0 — read-only planner and hand-off for the user-owned APFS pilot.
#
# This script never creates a snapshot, never mounts, never unmounts, never
# restores, never erases and never runs anything privileged. It reads APFS
# metadata through documented read-only commands (apfs list, info, mount,
# kern.bootsessionuuid), writes exactly one JSON plan file into --out-dir, and
# prints the argv the operator must run by hand. `--apply` only performs the
# hand-off; it prints the same argv and still executes none of it.
set -euo pipefail
umask 077
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

PROG=apfs-pilot
PYTHON=/usr/bin/python3
diskutil_bin=/usr/sbin/diskutil
sysctl_bin=/usr/sbin/sysctl
mount_bin=/sbin/mount

usage() {
  cat <<'USAGE'
Usage:
  apfs-pilot.sh --plan FILE --out-dir DIR [--fixture-dir DIR]
  apfs-pilot.sh --apply --i-understand --plan FILE --out-dir DIR --backup-receipt FILE

  --dry-run            Default. Reads metadata only, writes <out-dir>/apfs-pilot-plan.json.
  --apply              Hand-off mode: validates preconditions and prints the operator argv.
                       Executes nothing. Requires --i-understand and --backup-receipt.
  --i-understand       Explicit acknowledgement that every printed command is run by hand.
  --plan FILE          Own sanjbox.apfs-pilot.plan.v1 JSON, max 64 KiB.
  --out-dir DIR        Own private directory; the only place this script writes.
  --fixture-dir DIR    Dry-run only: read captured plist/text fixtures instead of the host.
                       The output then marks the probe as "fixture-mock".
  --backup-receipt F   Own sanjbox.apfs-pilot.backup-receipt.v1 JSON, max 16 KiB.

Exit codes:
  0  dry-run plan written, or apply hand-off printed; no disk mutation either way
  2  usage, input schema, or I/O error; no plan file is produced
  4  apply/backup refusal (missing --i-understand, missing/invalid receipt, fixture apply)
  5  pre-state gate failed (identity mismatch, forbidden volume, busy target)
  6  read-only probe failed (metadata could not be read)

This script never runs sudo, asr, snapshot create/delete, mounting or unmounting.
USAGE
}

die() {
  local code=$1
  shift
  printf '%s: %s\n' "$PROG" "$*" >&2
  exit "$code"
}

mode=dry-run
plan=
out_dir=
fixture_dir=
receipt=
understand=0
saw_dry=0
saw_apply=0

while (($#)); do
  case $1 in
    --dry-run) saw_dry=1; mode=dry-run ;;
    --apply) saw_apply=1; mode=apply ;;
    --i-understand) understand=1 ;;
    --plan) shift; [[ $# -gt 0 ]] || die 2 'usage: --plan requires a value'; plan=$1 ;;
    --plan=*) plan=${1#*=} ;;
    --out-dir) shift; [[ $# -gt 0 ]] || die 2 'usage: --out-dir requires a value'; out_dir=$1 ;;
    --out-dir=*) out_dir=${1#*=} ;;
    --fixture-dir) shift; [[ $# -gt 0 ]] || die 2 'usage: --fixture-dir requires a value'; fixture_dir=$1 ;;
    --fixture-dir=*) fixture_dir=${1#*=} ;;
    --backup-receipt) shift; [[ $# -gt 0 ]] || die 2 'usage: --backup-receipt requires a value'; receipt=$1 ;;
    --backup-receipt=*) receipt=${1#*=} ;;
    --help | -h) usage; exit 0 ;;
    *) die 2 "usage: unknown argument: $1" ;;
  esac
  shift
done

((saw_dry == 0 || saw_apply == 0)) || die 2 'usage: --dry-run and --apply are mutually exclusive'
[[ -n $plan ]] || die 2 'usage: --plan is required'
[[ -n $out_dir ]] || die 2 'usage: --out-dir is required'

# --- apply gates: resolved before any input is opened or any output is created ---
if [[ $mode == apply ]]; then
  ((understand == 1)) ||
    die 4 'refused: --apply requires --i-understand; this script prints the operator argv and never runs it'
  [[ -n $receipt ]] ||
    die 4 'refused: --apply requires --backup-receipt pointing at an existing sanjbox.apfs-pilot.backup-receipt.v1 file'
  [[ -z $fixture_dir ]] ||
    die 4 'refused: --apply requires live read-only probing; --fixture-dir is a dry-run-only mock'
fi

# There are no executable test hooks in the distributed script. A program is
# not made read-only by passing it a read-only-looking argv.
[[ -z ${APFS_PILOT_DISKUTIL+x}${APFS_PILOT_SYSCTL+x}${APFS_PILOT_MOUNT+x} ]] ||
  die 2 'executable overrides are refused; live probes use pinned system binaries'

# --- read-only planning; all JSON work happens in one bounded stdlib-only helper ---
"$PYTHON" -I -B - \
  "$mode" "$plan" "$out_dir" "${fixture_dir:--}" "${receipt:--}" \
  "$diskutil_bin" "$sysctl_bin" "$mount_bin" <<'PYTHON'
from datetime import datetime
import hashlib
import json
import os
import plistlib
import re
import stat
import subprocess
import sys
import secrets

PLAN_SCHEMA = "sanjbox.apfs-pilot.plan.v1"
OUT_SCHEMA = "sanjbox.apfs-pilot.dry-run.v1"
RECEIPT_SCHEMA = "sanjbox.apfs-pilot.backup-receipt.v1"
OUT_NAME = "apfs-pilot-plan.json"
BACKUP_DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
MAX_PLAN_BYTES = 64 * 1024
MAX_RECEIPT_BYTES = 16 * 1024

UUID_RE = re.compile(r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")
DEVICE_RE = re.compile(r"^disk[0-9]+(s[0-9]+){1,3}$")
LABEL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
SNAPSHOT_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$")
CREATED_AT_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
MOUNT_PREFIXES = ("/Volumes/", "/private/tmp/")
FORBIDDEN_MOUNT_PREFIXES = ("/System/Volumes/",)

mode, plan_path, out_dir, fixture_dir, receipt_path, diskutil, sysctl, mount = sys.argv[1:9]
input_identities = set()
out_fd = None


def fail(code, message):
    sys.stderr.write("apfs-pilot: " + message + "\n")
    raise SystemExit(code)


def load_json(raw, label, limit, code=2):
    if not raw:
        fail(code, label + ": empty input")
    if len(raw) > limit:
        fail(code, label + ": exceeds " + str(limit) + " bytes")

    def no_duplicates(pairs):
        seen = set()
        for key, value in pairs:
            if key in seen:
                raise ValueError("duplicate key " + repr(key))
            seen.add(key)
        return dict(pairs)

    def no_constants(text):
        raise ValueError("non-finite number " + text)

    try:
        document = json.loads(
            raw.decode("utf-8"), object_pairs_hook=no_duplicates, parse_constant=no_constants
        )
        def validate(value, depth=0):
            if depth > 32:
                raise ValueError("JSON nesting exceeds 32 levels")
            if isinstance(value, str):
                value.encode("utf-8")
            elif isinstance(value, dict):
                for key, child in value.items():
                    validate(key, depth + 1)
                    validate(child, depth + 1)
            elif isinstance(value, list):
                for child in value:
                    validate(child, depth + 1)
        validate(document)
        return document
    except (UnicodeError, ValueError, RecursionError) as exc:
        fail(code, label + ": invalid JSON: " + str(exc))


def open_directory(path, private=False):
    """Walk directory descriptors, never following a symlink in any component."""
    if ".." in path.split("/"):
        fail(2, "parent traversal refused: " + path)
    descriptor = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in os.path.abspath(path).split("/")[1:]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                            dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
            info = os.fstat(descriptor)
            if info.st_uid not in (0, os.geteuid()):
                fail(2, "ancestor directory not owned by caller/root: " + path)
            # Root-owned sticky /private/tmp is permitted; its own child must
            # still be private. No writable non-sticky ancestor is accepted.
            if info.st_mode & 0o022 and not (info.st_uid == 0 and info.st_mode & stat.S_ISVTX):
                fail(2, "parent directory is group/world writable: " + path)
        info = os.fstat(descriptor)
        if info.st_uid != os.geteuid():
            fail(2, "directory not owned by the caller: " + path)
        if info.st_mode & 0o022:
            fail(2, "parent directory is group/world writable: " + path)
        if private and stat.S_IMODE(info.st_mode) != 0o700:
            fail(2, "directory mode must be 0700: " + path)
        result, descriptor = descriptor, None
        return result
    except OSError as exc:
        fail(2, "cannot open directory (symlink refused): " + path + ": " + str(exc))
    finally:
        if descriptor is not None:
            os.close(descriptor)


def check_output_collision(info):
    if mode != "dry-run":
        return
    try:
        output = os.stat(OUT_NAME, dir_fd=out_fd, follow_symlinks=False)
    except FileNotFoundError:
        return
    if (info.st_dev, info.st_ino) == (output.st_dev, output.st_ino):
        fail(2, "output collides with an input file")


def read_input_bytes(path, limit, size_code=2):
    if ".." in path.split("/"):
        fail(2, "parent traversal refused: " + path)
    parent = open_directory(os.path.dirname(os.path.abspath(path)))
    try:
        try:
            descriptor = os.open(os.path.basename(path), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                                 dir_fd=parent)
        except FileNotFoundError:
            fail(2, "no such file: " + path)
        except OSError as exc:
            fail(2, "cannot open input (symlink refused): " + path + ": " + str(exc))
        with os.fdopen(descriptor, "rb") as handle:
            info = os.fstat(handle.fileno())
            check_output_collision(info)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_nlink != 1:
                fail(2, "input must be a caller-owned regular file with one link: " + path)
            if info.st_mode & 0o022:
                fail(2, "input group/world writable refused: " + path)
            data = handle.read(limit + 1)
            after = os.fstat(handle.fileno())
            if (info.st_size, info.st_mtime_ns, info.st_ctime_ns) != \
                    (after.st_size, after.st_mtime_ns, after.st_ctime_ns):
                fail(2, "input changed while being read: " + path)
            input_identities.add((info.st_dev, info.st_ino))
    finally:
        os.close(parent)
    if len(data) > limit:
        fail(size_code, path + ": exceeds " + str(limit) + " bytes")
    return data


def require_object(obj, label, required, optional=(), code=2):
    if not isinstance(obj, dict):
        fail(code, label + ": must be a JSON object")
    missing = sorted(set(required) - set(obj))
    unknown = sorted(set(obj) - set(required) - set(optional))
    if missing:
        fail(code, label + ": missing key(s) " + ", ".join(missing))
    if unknown:
        fail(code, label + ": unknown key(s) " + ", ".join(unknown))


def require_string(obj, key, label, limit=1024, code=2):
    value = obj.get(key)
    if not isinstance(value, str) or not value:
        fail(code, label + "." + key + ": must be a non-empty string")
    if len(value.encode("utf-8")) > limit:
        fail(code, label + "." + key + ": exceeds " + str(limit) + " bytes")
    if any(ch in value for ch in ("\x00", "\n", "\r")):
        fail(code, label + "." + key + ": control characters refused")
    return value


def optional_uuid(obj, key, label):
    value = obj.get(key)
    if key not in obj:
        return None
    if not isinstance(value, str) or not UUID_RE.fullmatch(value):
        fail(2, label + "." + key + ": must be a UUID like 00000000-0000-0000-0000-000000000000")
    return value


def require_absolute_under(value, label, prefixes):
    if not value.startswith("/") or any(part in ("", ".", "..") for part in value.split("/")[1:]):
        fail(2, label + ": must be a normalized absolute path, got " + value)
    if not any(value.startswith(prefix) and len(value) > len(prefix) for prefix in prefixes):
        fail(2, label + ": must live under one of " + ", ".join(prefixes) + ", got " + value)
    return value


def check_volume(side, label):
    require_object(side, label, ["device"], ["expectedVolumeUUID", "expectedContainerUUID"])
    device = require_string(side, "device", label, 64)
    if not DEVICE_RE.fullmatch(device):
        fail(2, label + ".device: must look like disk9s1, got " + device)
    return {
        "device": device,
        "expectedVolumeUUID": optional_uuid(side, "expectedVolumeUUID", label),
        "expectedContainerUUID": optional_uuid(side, "expectedContainerUUID", label),
    }


def check_plan(doc):
    require_object(doc, "plan", ["schema", "pilotId", "transactionLabel", "pilotRoot", "pairs"])
    if doc["schema"] != PLAN_SCHEMA:
        fail(2, "plan.schema: expected " + PLAN_SCHEMA)
    pilot_id = require_string(doc, "pilotId", "plan", 64)
    transaction = require_string(doc, "transactionLabel", "plan", 64)
    for label, value in (("plan.pilotId", pilot_id), ("plan.transactionLabel", transaction)):
        if not LABEL_RE.fullmatch(value):
            fail(2, label + ": only [A-Za-z0-9._-] up to 64 characters")
    root = require_string(doc, "pilotRoot", "plan")
    require_absolute_under(root, "plan.pilotRoot", MOUNT_PREFIXES)

    pairs = doc["pairs"]
    if not isinstance(pairs, list) or not 1 <= len(pairs) <= 2:
        fail(2, "plan.pairs: must be an array of 1..2 pairs (pilot budget)")
    checked = []
    ids = set()
    devices = []
    names = set()
    for index, pair in enumerate(pairs):
        label = "plan.pairs[" + str(index) + "]"
        require_object(pair, label, ["id", "snapshotName", "source", "target"])
        pair_id = require_string(pair, "id", label, 32)
        if not LABEL_RE.fullmatch(pair_id) or pair_id in ids:
            fail(2, label + ".id: unique [A-Za-z0-9._-] label required")
        ids.add(pair_id)
        name = require_string(pair, "snapshotName", label, 63)
        if not SNAPSHOT_RE.fullmatch(name) or name in names:
            fail(2, label + ".snapshotName: unique [A-Za-z0-9._-] name up to 63 characters")
        names.add(name)
        source = check_volume(pair["source"], label + ".source")
        target = check_volume(pair["target"], label + ".target")
        if source["device"] == target["device"]:
            fail(2, label + ": source and target must be different volumes")
        devices.extend([source["device"], target["device"]])
        checked.append({"id": pair_id, "snapshotName": name, "source": source, "target": target})
    if len(set(devices)) != len(devices):
        fail(2, "plan.pairs: a device is used more than once")
    return {
        "pilotId": pilot_id,
        "transactionLabel": transaction,
        "pilotRoot": root,
        "pairs": checked,
        "devices": devices,
    }


def check_receipt(doc, plan, plan_digest):
    require_object(
        doc,
        "backup receipt",
        ["schema", "pilotId", "transactionLabel", "planSha256", "createdAt", "backupLocation", "coversDevices"],
        ["backupDigest"],
        code=4,
    )
    if doc["schema"] != RECEIPT_SCHEMA:
        fail(4, "refused: backup receipt: expected schema " + RECEIPT_SCHEMA)
    if doc["pilotId"] != plan["pilotId"]:
        fail(4, "refused: backup receipt: pilotId does not match the plan")
    if doc["transactionLabel"] != plan["transactionLabel"]:
        fail(4, "refused: backup receipt: transactionLabel does not match the plan")
    if doc["planSha256"] != plan_digest:
        fail(4, "refused: backup receipt: planSha256 does not match the exact plan/identities")
    created = require_string(doc, "createdAt", "backup receipt", 32, code=4)
    if not CREATED_AT_RE.fullmatch(created):
        fail(4, "refused: backup receipt: createdAt must be UTC YYYY-MM-DDTHH:MM:SSZ")
    try:
        created_time = datetime.strptime(created, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        fail(4, "refused: backup receipt: createdAt is not a valid UTC calendar timestamp")
    if created_time > datetime.utcnow():
        fail(4, "refused: backup receipt: createdAt is in the future")
    location = require_string(doc, "backupLocation", "backup receipt", 1024, code=4)
    if location.strip() != location:
        fail(4, "refused: backup receipt: backupLocation has surrounding whitespace")
    covers = doc["coversDevices"]
    if not isinstance(covers, list) or not covers:
        fail(4, "refused: backup receipt: coversDevices must be a non-empty array")
    for device in covers:
        if not isinstance(device, str) or not DEVICE_RE.fullmatch(device):
            fail(4, "refused: backup receipt: coversDevices entry is not a volume device")
    if len(set(covers)) != len(covers):
        fail(4, "refused: backup receipt: coversDevices contains duplicates")
    missing = sorted(set(plan["devices"]) - set(covers))
    if missing:
        fail(4, "refused: backup receipt: does not cover " + ", ".join(missing))
    digest = doc.get("backupDigest")
    if "backupDigest" in doc:
        if not isinstance(digest, str) or not BACKUP_DIGEST_RE.fullmatch(digest):
            fail(
                4,
                "refused: backup receipt: backupDigest must be sha256:<64 lowercase hex characters>",
            )
    return {
        "planSha256": plan_digest,
        "createdAt": created,
        "backupLocation": location,
        "coversDevices": sorted(covers),
        "backupDigest": digest,
    }


class Probe(object):
    """Read-only metadata source: live documented commands or captured fixtures."""

    def __init__(self, kind, directory, tools):
        self.kind = kind
        self.directory = directory
        self.tools = tools
        self.commands = []

    def _run(self, argv):
        self.commands.append(list(argv))
        try:
            result = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
        except (OSError, subprocess.TimeoutExpired) as exc:
            fail(6, "probe command could not start: " + " ".join(argv) + ": " + str(exc))
        if result.returncode != 0:
            fail(6, "probe command failed with " + str(result.returncode) + ": " + " ".join(argv))
        if len(result.stdout) > 4 * 1024 * 1024:
            fail(6, "probe output exceeds 4 MiB")
        return result.stdout

    def _fixture(self, name):
        path = os.path.join(self.directory, name)
        if not os.path.isfile(path) or os.path.islink(path):
            fail(6, "fixture-mock: missing regular fixture " + name)
        return read_input_bytes(path, 4 * 1024 * 1024)

    def apfs_list(self):
        if self.kind == "fixture-mock":
            return self._fixture("apfs-list.plist")
        return self._run([self.tools[0], "apfs", "list", "-plist"])

    def volume_info(self, device):
        if self.kind == "fixture-mock":
            return self._fixture("volume-info-" + device + ".plist")
        return self._run([self.tools[0], "info", "-plist", device])

    def mount_table(self):
        if self.kind == "fixture-mock":
            return self._fixture("mount.txt")
        return self._run([self.tools[2]])

    def boot_session_uuid(self):
        if self.kind == "fixture-mock":
            return self._fixture("bootsessionuuid.txt")
        return self._run([self.tools[1], "-n", "kern.bootsessionuuid"])


def parse_plist(data, label):
    class UniqueDictionary(dict):
        def __setitem__(self, key, value):
            if key in self:
                raise ValueError("duplicate plist key " + repr(key))
            super().__setitem__(key, value)

    try:
        doc = plistlib.loads(data, dict_type=UniqueDictionary)
    except Exception as exc:  # plistlib raises several unrelated types
        fail(6, label + ": cannot parse property list: " + str(exc))
    if not isinstance(doc, dict):
        fail(6, label + ": property list root must be a dictionary")
    return doc


def parse_mounts(text):
    entries = []
    try:
        lines = text.decode("utf-8").splitlines()
    except UnicodeDecodeError:
        fail(6, "mount table is not UTF-8")
    for line in lines:
        if not line.strip():
            continue
        match = re.match(r"^(\S+) on (.+) \(([^)]*)\)$", line)
        if not match:
            fail(6, "mount table contains an unrecognized line")
        options = [item.strip() for item in match.group(3).split(",") if item.strip()]
        point = match.group(2)
        if not point.startswith("/") or (point != "/" and any(
                part in ("", ".", "..") for part in point.split("/")[1:])):
            fail(6, "mount table contains a non-normalized mountpoint")
        entries.append(
            {"device": match.group(1), "mountpoint": match.group(2), "mountFields": options}
        )
    if not entries or sum(entry["mountpoint"] == "/" for entry in entries) != 1:
        fail(6, "mount table must contain exactly one root mount")
    if len({entry["mountpoint"] for entry in entries}) != len(entries):
        fail(6, "mount table contains duplicate mountpoints")
    entries.sort(key=lambda item: (item["mountpoint"], item["device"]))
    return entries


def main():
    global out_fd
    out_fd = open_directory(out_dir, private=True)
    if fixture_dir != "-":
        os.close(open_directory(fixture_dir, private=True))
    plan_doc = load_json(read_input_bytes(plan_path, MAX_PLAN_BYTES), "plan", MAX_PLAN_BYTES)
    plan = check_plan(plan_doc)
    if mode == "apply":
        declared_containers = any(
            pair[side]["expectedContainerUUID"] is not None
            for pair in plan["pairs"]
            for side in ("source", "target")
        )
        missing_identity = []
        for pair in plan["pairs"]:
            for side in ("source", "target"):
                item = pair[side]
                if item["expectedVolumeUUID"] is None:
                    missing_identity.append(pair["id"] + "." + side + ".expectedVolumeUUID")
                if declared_containers and item["expectedContainerUUID"] is None:
                    missing_identity.append(pair["id"] + "." + side + ".expectedContainerUUID")
        if missing_identity:
            fail(
                4,
                "refused: --apply requires declared identity; missing "
                + ", ".join(missing_identity)
                + " (expectedVolumeUUID always, expectedContainerUUID when the plan declares any)",
            )
    plan_digest = hashlib.sha256(
        json.dumps(plan_doc, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()

    receipt = None
    receipt_raw = None
    if receipt_path != "-":
        receipt_raw = read_input_bytes(receipt_path, MAX_RECEIPT_BYTES, size_code=4)
        receipt_doc = load_json(
            receipt_raw, "backup receipt", MAX_RECEIPT_BYTES, code=4
        )
        receipt = check_receipt(receipt_doc, plan, plan_digest)

    if mode == "apply" and receipt is None:
        fail(4, "refused: --apply requires a backup receipt")

    fixture = "" if fixture_dir == "-" else fixture_dir
    kind = "fixture-mock" if fixture else "live-readonly"
    probe = Probe(kind, fixture, (diskutil, sysctl, mount))

    boot_raw = probe.boot_session_uuid()
    try:
        boot_uuid = boot_raw.decode("utf-8").strip()
    except UnicodeDecodeError:
        fail(6, "cannot decode kern.bootsessionuuid output")
    if not UUID_RE.fullmatch(boot_uuid):
        fail(6, "kern.bootsessionuuid did not return a UUID")

    apfs_doc = parse_plist(probe.apfs_list(), "apfs list")
    containers_doc = apfs_doc.get("Containers")
    if not isinstance(containers_doc, list) or not containers_doc:
        fail(6, "apfs list: Containers array is missing or empty")
    mounts = parse_mounts(probe.mount_table())

    volumes = {}
    containers = {}
    container_uuids = set()
    volume_uuids = set()

    def capacity(obj, key):
        value = obj.get(key, 0)
        if type(value) is not int or not 0 <= value <= 2 ** 64 - 1:
            fail(6, "apfs list: " + key + " must be an unsigned integer")
        return value

    for container in containers_doc:
        if not isinstance(container, dict):
            fail(6, "apfs list: container entry is not a dictionary")
        container_uuid = container.get("APFSContainerUUID")
        if not isinstance(container_uuid, str) or not UUID_RE.fullmatch(container_uuid):
            fail(6, "apfs list: container without a valid UUID")
        if container_uuid.upper() in container_uuids:
            fail(6, "apfs list: duplicate container UUID " + container_uuid)
        container_uuids.add(container_uuid.upper())
        container_volumes = container.get("Volumes")
        if not isinstance(container_volumes, list):
            fail(6, "apfs list: container without a Volumes array")
        record = {
            "uuid": container_uuid,
            "designatedPhysicalStore": container.get("DesignatedPhysicalStore", ""),
            "capacityCeilingBytes": capacity(container, "CapacityCeiling"),
            "capacityFreeBytes": capacity(container, "CapacityFree"),
            "volumes": [],
        }
        if not isinstance(record["designatedPhysicalStore"], str):
            fail(6, "apfs list: malformed DesignatedPhysicalStore")
        for volume in container_volumes:
            if not isinstance(volume, dict):
                fail(6, "apfs list: volume entry is not a dictionary")
            device = volume.get("DeviceIdentifier")
            volume_uuid = volume.get("APFSVolumeUUID")
            if not isinstance(device, str) or not DEVICE_RE.fullmatch(device):
                fail(6, "apfs list: volume without a valid device identifier")
            if not isinstance(volume_uuid, str) or not UUID_RE.fullmatch(volume_uuid):
                fail(6, "apfs list: volume " + device + " without a valid UUID")
            if device in volumes or volume_uuid.upper() in volume_uuids:
                fail(6, "apfs list: duplicate volume device or UUID")
            volume_uuids.add(volume_uuid.upper())
            roles = volume.get("Roles", [])
            if not isinstance(roles, list) or any(not isinstance(role, str) for role in roles):
                fail(6, "apfs list: volume " + device + " has malformed Roles")
            entry = {
                "device": device,
                "volumeUUID": volume_uuid,
                "name": volume.get("Name", ""),
                "roles": sorted(roles),
                "capacityQuotaBytes": capacity(volume, "CapacityQuota"),
                "capacityReserveBytes": capacity(volume, "CapacityReserve"),
                "capacityInUseBytes": capacity(volume, "CapacityInUse"),
                "containerUUID": container_uuid,
            }
            if not isinstance(entry["name"], str):
                fail(6, "apfs list: malformed volume Name")
            record["volumes"].append(entry)
            volumes[device] = entry
        record["volumes"].sort(key=lambda item: item["device"])
        containers[container_uuid] = record

    gated_devices = []
    for pair in plan["pairs"]:
        gated_devices.extend([pair["source"]["device"], pair["target"]["device"]])

    infos = {}
    for device in gated_devices:
        if device not in volumes:
            continue
        info = parse_plist(probe.volume_info(device), "volume info " + device)
        info_device = info.get("DeviceIdentifier")
        info_uuid = info.get("VolumeUUID")
        if not isinstance(info_device, str) or not DEVICE_RE.fullmatch(info_device) \
                or not isinstance(info_uuid, str) or not UUID_RE.fullmatch(info_uuid) \
                or info.get("FilesystemType") != "apfs":
            fail(6, "volume info " + device + ": missing or malformed APFS identity metadata")
        if info_device != device or info_uuid != volumes[device]["volumeUUID"]:
            fail(5, "volume info " + device + ": identity mismatch with apfs list")
        for key in ("Bootable", "Writable", "APFSSnapshot"):
            if type(info.get(key)) is not bool:
                fail(6, "volume info " + device + ": malformed " + key)
        if info.get("Sealed") not in ("Yes", "No"):
            fail(6, "volume info " + device + ": malformed Sealed")
        infos[device] = info

    def mount_device(entry):
        device = entry["device"]
        return device[5:] if device.startswith("/dev/") else device

    def device_mounts(device, include_snapshots=False):
        return [
            entry for entry in mounts
            if mount_device(entry) == device
            or include_snapshots and mount_device(entry).startswith(device + "s")
        ]

    relevant_mounts = []
    for entry in mounts:
        device = entry["device"]
        bare = device[5:] if device.startswith("/dev/") else device
        if bare == "disk" or any(
            bare == device or bare.startswith(device + "s") for device in gated_devices
        ) or entry["mountpoint"] == "/":
            relevant_mounts.append(entry)

    gates = []

    def gate(gate_id, status, detail):
        gates.append({"id": gate_id, "status": status, "detail": detail})

    gate("plan-schema", "pass", "own plan validates as " + PLAN_SCHEMA)
    gate("boot-session", "pass", "boot session UUID read read-only; it is recorded, not trusted")

    missing = sorted(set(gated_devices) - set(volumes))
    if missing:
        gate("volume-observed", "fail", "not found in apfs list: " + ", ".join(missing))
    else:
        gate("volume-observed", "pass", "all " + str(len(gated_devices)) + " plan devices observed")

    pilot_volumes = []
    for pair in plan["pairs"]:
        for side in ("source", "target"):
            declared = pair[side]
            device = declared["device"]
            observed = volumes.get(device)
            info = infos.get(device, {})
            mountpoint = info.get("MountPoint", "") if isinstance(info, dict) else ""
            if not isinstance(mountpoint, str):
                fail(6, "volume info " + device + ": MountPoint is not a string")
            mount_fields = sorted(
                {
                    option
                    for entry in mounts
                    if entry["device"] == "/dev/" + device
                    or entry["mountpoint"] == mountpoint and mountpoint
                    for option in entry["mountFields"]
                }
            )
            entry = {
                "pairId": pair["id"],
                "side": side,
                "device": device,
                "expectedVolumeUUID": declared["expectedVolumeUUID"],
                "expectedContainerUUID": declared["expectedContainerUUID"],
                "observed": None,
                "matchesExpectedVolumeUUID": None,
                "matchesExpectedContainerUUID": None,
                "mountpoint": mountpoint,
                "mountFields": mount_fields,
            }
            if observed is not None:
                observed_public = {
                    key: observed[key]
                    for key in (
                        "volumeUUID",
                        "containerUUID",
                        "name",
                        "roles",
                        "capacityQuotaBytes",
                        "capacityReserveBytes",
                        "capacityInUseBytes",
                    )
                }
                observed_public.update(
                    {
                        "writable": info.get("Writable") is True,
                        "sealed": info.get("Sealed") == "Yes",
                        "bootable": info.get("Bootable") is True,
                        "filesystemType": info.get("FilesystemType", ""),
                        "apfsSnapshot": info.get("APFSSnapshot") is True,
                    }
                )
                entry["observed"] = observed_public
                if declared["expectedVolumeUUID"] is not None:
                    entry["matchesExpectedVolumeUUID"] = (
                        observed["volumeUUID"] == declared["expectedVolumeUUID"]
                    )
                if declared["expectedContainerUUID"] is not None:
                    entry["matchesExpectedContainerUUID"] = (
                        observed["containerUUID"] == declared["expectedContainerUUID"]
                    )
            pilot_volumes.append(entry)

    mismatched = [
        item["pairId"] + "." + item["side"]
        for item in pilot_volumes
        if item["matchesExpectedVolumeUUID"] is False
        or item["matchesExpectedContainerUUID"] is False
    ]
    compared = sum(
        1
        for item in pilot_volumes
        for key in ("matchesExpectedVolumeUUID", "matchesExpectedContainerUUID")
        if item[key] is not None
    )
    containers_declared = any(item["expectedContainerUUID"] is not None for item in pilot_volumes)
    unidentified = [item["pairId"] + "." + item["side"] for item in pilot_volumes
                    if item["matchesExpectedVolumeUUID"] is not True
                    or containers_declared and item["matchesExpectedContainerUUID"] is not True]
    if mismatched:
        gate("identity-match", "fail", "declared UUID does not match observation: " + ", ".join(mismatched))
    elif compared == 0:
        gate(
            "identity-match",
            "inconclusive",
            "no expectedVolumeUUID/expectedContainerUUID was declared; nothing was compared, "
            "so identity is not verified",
        )
    elif unidentified:
        gate("identity-match", "inconclusive", "incomplete declared/observed identity: "
             + ", ".join(unidentified))
    else:
        gate(
            "identity-match",
            "pass",
            str(compared) + " declared UUID(s) compared and all match the observation",
        )

    forbidden = []
    for item in pilot_volumes:
        observed = item["observed"]
        if observed is None:
            continue
        hits = observed["roles"]
        if hits:
            forbidden.append(item["device"] + " roles " + ",".join(hits))
        if observed["sealed"] or observed["bootable"]:
            forbidden.append(item["device"] + " is sealed/bootable")
        if observed["apfsSnapshot"]:
            forbidden.append(item["device"] + " is a snapshot device")
        for entry in relevant_mounts:
            bare = entry["device"][5:] if entry["device"].startswith("/dev/") else entry["device"]
            if bare != item["device"] and not bare.startswith(item["device"] + "s"):
                continue
            mountpoint = entry["mountpoint"]
            if mountpoint == "/" or mountpoint.startswith(FORBIDDEN_MOUNT_PREFIXES):
                forbidden.append(item["device"] + " is mounted at " + mountpoint)
    if forbidden:
        gate("non-system-volume", "fail", "; ".join(sorted(set(forbidden))))
    else:
        gate("non-system-volume", "pass", "no plan volume is a boot/system/role volume or a snapshot")

    uuids = [item["observed"]["volumeUUID"] for item in pilot_volumes if item["observed"]]
    if len(set(uuids)) != len(uuids):
        gate("distinct-volumes", "fail", "a volume UUID appears more than once in the plan")
    else:
        gate("distinct-volumes", "pass", "every plan device resolves to a distinct volume UUID")

    inconsistent_mounts = []
    busy_targets = []
    for item in pilot_volumes:
        if item["observed"] is None:
            continue
        info_mounts = {item["mountpoint"]} if item["mountpoint"] else set()
        table_mounts = {entry["mountpoint"] for entry in device_mounts(item["device"])}
        if info_mounts != table_mounts:
            inconsistent_mounts.append(item["device"])
        if item["side"] != "target":
            continue
        all_mounts = info_mounts | {
            entry["mountpoint"] for entry in device_mounts(item["device"], include_snapshots=True)
        }
        for mountpoint in sorted(all_mounts):
            if not (mountpoint == plan["pilotRoot"]
                    or mountpoint.startswith(plan["pilotRoot"] + "/")):
                busy_targets.append(item["device"] + " is mounted at " + mountpoint)
    if inconsistent_mounts:
        gate("mount-consistency", "fail", "diskutil info and mount table disagree: "
             + ", ".join(inconsistent_mounts))
    else:
        gate("mount-consistency", "pass", "diskutil info and mount table agree for every pilot volume")
    if busy_targets:
        gate("target-not-active", "fail", "; ".join(busy_targets))
    else:
        gate("target-not-active", "pass", "no target is mounted outside the declared pilot root")

    observed_volumes = [item for item in pilot_volumes if item["observed"]]
    zero_quota = [item for item in observed_volumes if item["observed"]["capacityQuotaBytes"] == 0]
    if zero_quota:
        detail = "quota 0 means unbounded, not reserved space: " + ", ".join(
            item["device"] for item in zero_quota
        )
        if len(zero_quota) == len(observed_volumes):
            detail = "no pilot volume has an APFS quota; " + detail
        gate("quota-declared", "warn", detail)
    else:
        gate("quota-declared", "pass", "every observed pilot volume declares a non-zero APFS quota")

    if receipt is not None:
        gate("backup-receipt", "pass", "receipt covers every plan device and matches the exact plan hash")
    elif mode == "apply":
        gate("backup-receipt", "fail", "missing receipt")  # unreachable: refused earlier
    else:
        gate("backup-receipt", "warn", "dry-run without --backup-receipt; --apply will require it")

    gate(
        "whole-uid-interlock",
        "manual",
        "G2 is unsolved: this script cannot prove whole-UID quiescence, admission deny or closed "
        "fd/mappings. The operator must evidence it in the reserved L3 slot before any P1/P2 step; "
        "this planner neither gates on it nor pretends it passed",
    )

    # --- operator runbook; nothing below is executed by this script ---
    steps = [
        {
            "phase": "P0",
            "id": "snapshot-create-path",
            "argv": None,
            "argvTemplate": False,
            "readOnly": False,
            "rootRequired": False,
            "executed": False,
            "decision": "P0-G1",
            "reason": "No documented general snapshot-create CLI path is assumed. Decide and record "
            "the permitted signed/entitled path for this build before P1; no argv is guessed here.",
        },
        {
            "phase": "P0",
            "id": "asr-switch-support",
            "argv": None,
            "argvTemplate": False,
            "readOnly": False,
            "rootRequired": False,
            "executed": False,
            "decision": "P0-G3",
            "reason": "Before the P2 template is used, verify that this build's asr accepts "
            "--toSnapshot, --useReplication and --erase. `asr help` does not list them, so compare "
            "the shipped binary/version with a non-destructive check the operator records. If any "
            "switch is unsupported, do not use this template and record the gap.",
        },
    ]
    for pair in plan["pairs"]:
        source = pair["source"]["device"]
        target = pair["target"]["device"]
        steps.append(
            {
                "phase": "P1",
                "id": "snapshot-create-" + pair["id"],
                "argv": None,
                "argvTemplate": False,
                "readOnly": False,
                "rootRequired": True,
                "executed": False,
                "decision": "P0-G1",
                "reason": "Depends on the P0 decision; the snapshot name is "
                + pair["snapshotName"]
                + ".",
            }
        )
        steps.append(
            {
                "phase": "P1",
                "id": "snapshot-list-" + pair["id"],
                "argv": ["diskutil", "apfs", "listSnapshots", "-plist", source],
                "argvTemplate": False,
                "readOnly": True,
                "rootRequired": False,
                "executed": False,
                "decision": None,
                "reason": "Read-only: capture snapshot UUID/name/XID for the parent volume receipt.",
            }
        )
        steps.append(
            {
                "phase": "P1",
                "id": "snapshot-mount-" + pair["id"],
                "argv": None,
                "argvTemplate": False,
                "readOnly": False,
                "rootRequired": True,
                "executed": False,
                "decision": "P0-mount-path",
                "reason": "A read-only snapshot mount uses the operator path approved in P0; this "
                "planner does not generate a mount command. Mountpoint must stay under "
                + plan["pilotRoot"]
                + ".",
            }
        )
        steps.append(
            {
                "phase": "P2",
                "id": "asr-restore-" + pair["id"],
                "argv": [
                    "asr",
                    "restore",
                    "--source",
                    "/dev/" + source,
                    "--target",
                    "/dev/" + target,
                    "--toSnapshot",
                    "<snapshot-uuid-from-P1>",
                    "--useReplication",
                    "--erase",
                ],
                "argvTemplate": True,
                "readOnly": False,
                "rootRequired": True,
                "executed": False,
                "decision": None,
                "reason": "Template only: replace <snapshot-uuid-from-P1> with the tuple captured in "
                "P1 and re-verify the target device before confirming the erase prompt.",
            }
        )
        steps.append(
            {
                "phase": "P2",
                "id": "verify-target-" + pair["id"],
                "argv": ["diskutil", "info", "-plist", target],
                "argvTemplate": False,
                "readOnly": True,
                "rootRequired": False,
                "executed": False,
                "decision": None,
                "reason": "Read-only: record the post-restore target identity; writability and metadata "
                "corpus checks still use the operator's own canaries.",
            }
        )
    steps.append(
        {
            "phase": "P3",
            "id": "switch-writable-state",
            "argv": None,
            "argvTemplate": False,
            "readOnly": False,
            "rootRequired": True,
            "executed": False,
            "decision": "not-implemented",
            "reason": "The native switch/lifecycle adapter does not exist; P3 must be recorded as not "
            "performed and no mount switch may be improvised.",
        }
    )

    cleanup_steps = []
    for pair in plan["pairs"]:
        cleanup_steps.append(
            {
                "id": "unmount-snapshot-" + pair["id"],
                "argv": ["diskutil", "unmount", "<approved-snapshot-mount-from-P0>"],
                "argvTemplate": True,
                "readOnly": False,
                "rootRequired": False,
                "executed": False,
                "reason": "Only the operator's own snapshot mount, after a fresh receipt/identity "
                "check. Already absent means skip; a different mount means stop and preserve it.",
            }
        )
        cleanup_steps.append(
            {
                "id": "delete-snapshot-" + pair["id"],
                "argv": [
                    "diskutil",
                    "apfs",
                    "deleteSnapshot",
                    "<revalidated-parent-device-from-P1>",
                    "-uuid",
                    "<snapshot-uuid-from-P1>",
                    "-wait",
                ],
                "argvTemplate": True,
                "readOnly": False,
                "rootRequired": True,
                "executed": False,
                "reason": "Only after P2/P3 are closed and the snapshot is provably unused; -wait "
                "because deletion can continue after the command returns. Revalidate the full "
                "container/parent/snapshot UUID/XID/name receipt immediately before acting; never "
                "substitute a name match or stale device locator. Already absent means skip; "
                "conflict or unresolved intent means preserve the object and stop.",
            }
        )
        cleanup_steps.append(
            {
                "id": "quarantine-target-" + pair["id"],
                "argv": None,
                "argvTemplate": False,
                "readOnly": False,
                "rootRequired": False,
                "executed": False,
                "reason": "A target without documented completion stays quarantined; do not erase, "
                "reuse or re-point it automatically.",
            }
        )
    cleanup_steps.append(
        {
            "id": "verify-final-topology",
            "argv": ["diskutil", "apfs", "list", "-plist"],
            "argvTemplate": False,
            "readOnly": True,
            "rootRequired": False,
            "executed": False,
            "reason": "Read-only: record remaining snapshots, mounts and targets. Quarantined "
            "targets keep the slot blocked; this plan does not delete targets or prove cleanup.",
        }
    )

    doc = {
        "schema": OUT_SCHEMA,
        "mode": "dry-run" if mode == "dry-run" else "apply-handoff",
        "pilot": {
            "planSchema": PLAN_SCHEMA,
            "pilotId": plan["pilotId"],
            "transactionLabel": plan["transactionLabel"],
            "pilotRoot": plan["pilotRoot"],
            "planSha256": plan_digest,
            "pairs": [
                {
                    "id": pair["id"],
                    "snapshotName": pair["snapshotName"],
                    "sourceDevice": pair["source"]["device"],
                    "targetDevice": pair["target"]["device"],
                }
                for pair in plan["pairs"]
            ],
        },
        "probe": {
            "source": kind,
            "bootSessionUUID": boot_uuid,
            "commands": [list(command) for command in probe.commands],
            "limitations": "Metadata only. No snapshot, mount, restore, erase or writability probe ran.",
        },
        "preState": {
            "bootSessionUUID": boot_uuid,
            "containers": sorted(
                [
                    containers[uuid]
                    for uuid in set(
                        item["observed"]["containerUUID"]
                        for item in pilot_volumes
                        if item["observed"] is not None
                    )
                ],
                key=lambda item: item["uuid"],
            ),
            "volumes": pilot_volumes,
            "mounts": relevant_mounts,
        },
        "gates": gates,
        "steps": steps,
        "cleanup": {
            "preconditions": [
                "No asr or diskutil operation of this pilot is still running; check before acting.",
                "Every object still matches the private allocation/identity receipt, in the "
                "disposable test container only.",
                "The pilot area is fully off, snapshots are unmounted and no target is a needed "
                "binding or the only recovery source.",
                "The host recovery journal, raw evidence and this plan stay outside the restore "
                "unit and are never deleted as part of it.",
            ],
            "steps": cleanup_steps,
        },
        "userActions": [
            "Reserve an L3 slot in docs/LAB.md and freeze inputs/oracle before any mutation; this "
            "script does not reserve or validate a lab slot.",
            "Run every printed argv yourself, one at a time, after re-reading the concrete device; "
            "this script never executes them and never runs privileged commands.",
            "The backup receipt binds the exact plan, not backup contents or freshness. Verify the "
            "backup is still current before each operation; this hand-off grants no authorization.",
            "Replace <snapshot-uuid-from-P1> with the tuple you captured in P1, and the approved "
            "snapshot mount path from P0 in the cleanup template.",
            "Publish the run under docs/evidence per GUIDE §7 and keep closed runs immutable.",
        ],
        "verdict": {
            "dryRunOnly": mode == "dry-run",
            "handoffOnly": mode == "apply",
            "diskMutated": False,
            "privilegedCommandExecuted": False,
            "operatorCommandExecuted": False,
            "gatesPassed": all(
                item["status"] in ("pass", "warn", "manual") for item in gates
            ),
            "identityChecked": not unidentified and not mismatched,
            "manualGates": sorted(
                item["id"] for item in gates if item["status"] == "manual"
            ),
            "inconclusiveGates": sorted(
                item["id"] for item in gates if item["status"] == "inconclusive"
            ),
            "realStartAllowed": False,
        },
    }
    if receipt is not None:
        doc["backupReceipt"] = {
            "createdAt": receipt["createdAt"],
            "planSha256": receipt["planSha256"],
            "sha256": hashlib.sha256(receipt_raw).hexdigest(),
            "coversDevices": receipt["coversDevices"],
            "backupDigest": receipt["backupDigest"],
        }

    data = (json.dumps(doc, sort_keys=True, indent=2, ensure_ascii=True) + "\n").encode("utf-8")
    failed = not doc["verdict"]["gatesPassed"]

    if mode == "dry-run":
        try:
            descriptor = os.open(OUT_NAME, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=out_fd)
        except FileNotFoundError:
            descriptor = None
        if descriptor is not None:
            with os.fdopen(descriptor, "rb") as handle:
                existing = os.fstat(handle.fileno())
                if (existing.st_dev, existing.st_ino) in input_identities:
                    fail(2, "output collides with an input file")
                if not stat.S_ISREG(existing.st_mode) or existing.st_uid != os.geteuid() \
                        or existing.st_nlink != 1:
                    fail(2, "output must be an own regular file with one link")
                if stat.S_IMODE(existing.st_mode) != 0o600:
                    fail(2, "output mode must be 0600")
                if handle.read(len(data) + 1) != data:
                    fail(2, "output differs from this plan; use a fresh out-dir")
                after = os.stat(OUT_NAME, dir_fd=out_fd, follow_symlinks=False)
                fields = ("st_dev", "st_ino", "st_uid", "st_mode", "st_nlink",
                          "st_size", "st_mtime_ns", "st_ctime_ns")
                if any(getattr(existing, key) != getattr(after, key) for key in fields):
                    fail(2, "output changed during validation")
            sys.stderr.write("apfs-pilot: dry-run output already identical; not rewritten\n")
            data = None
        if data is not None:
            temp = "." + OUT_NAME + ".tmp." + secrets.token_hex(16)
            flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
            descriptor = os.open(temp, flags, 0o600, dir_fd=out_fd)
            try:
                with os.fdopen(descriptor, "wb") as handle:
                    handle.write(data)
                    handle.flush()
                    os.fsync(handle.fileno())
                # link() publishes complete bytes exclusively: never overwrite a
                # file, symlink or concurrent writer inserted after our check.
                os.link(temp, OUT_NAME, src_dir_fd=out_fd, dst_dir_fd=out_fd, follow_symlinks=False)
            finally:
                os.unlink(temp, dir_fd=out_fd)

    sys.stdout.write(json.dumps(doc, sort_keys=True, indent=2, ensure_ascii=True) + "\n")
    sys.stdout.flush()
    if failed:
        sys.stderr.write(
            "apfs-pilot: refused: at least one pre-state gate failed; do not continue with the pilot\n"
        )
        raise SystemExit(5)
    if kind == "fixture-mock":
        sys.stderr.write("apfs-pilot: probe is fixture-mock; this is not host evidence\n")
    raise SystemExit(0)


try:
    main()
except OSError as exc:
    fail(2, "I/O error; no successful plan verdict: " + str(exc))
finally:
    if out_fd is not None:
        os.close(out_fd)
PYTHON
