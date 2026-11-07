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

PROG=apfs-pilot
PYTHON=/usr/bin/python3
STAT=/usr/bin/stat

diskutil_bin="${APFS_PILOT_DISKUTIL:-/usr/sbin/diskutil}"
sysctl_bin="${APFS_PILOT_SYSCTL:-/usr/sbin/sysctl}"
mount_bin="${APFS_PILOT_MOUNT:-/sbin/mount}"

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

This script never runs sudo, asr, snapshot create/delete, mount or unmount.
USAGE
}

die() {
  local code=$1
  shift
  printf '%s: %s\n' "$PROG" "$*" >&2
  exit "$code"
}

# Own regular file: exists, not a symlink, owned by the caller, not group/world writable.
require_own_file() {
  local path=$1 label=$2
  [[ -e $path ]] || die 2 "$label: no such file: $path"
  [[ ! -L $path ]] || die 2 "$label: symlink refused: $path"
  [[ -f $path ]] || die 2 "$label: not a regular file: $path"
  [[ $("$STAT" -f '%u' -- "$path") == "${EUID:?}" ]] || die 2 "$label: not owned by the caller: $path"
  local mode
  mode=$("$STAT" -f '%Lp' -- "$path")
  (( (8#$mode & 8#022) == 0 )) || die 2 "$label: group/world writable refused: $path"
}

require_own_dir() {
  local path=$1 label=$2
  [[ -e $path ]] || die 2 "$label: no such directory: $path"
  [[ ! -L $path ]] || die 2 "$label: symlink refused: $path"
  [[ -d $path ]] || die 2 "$label: not a directory: $path"
  [[ $("$STAT" -f '%u' -- "$path") == "${EUID:?}" ]] || die 2 "$label: not owned by the caller: $path"
  local mode
  mode=$("$STAT" -f '%Lp' -- "$path")
  (( (8#$mode & 8#022) == 0 )) || die 2 "$label: group/world writable refused: $path"
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

require_own_file "$plan" 'plan'
plan_bytes=$(wc -c <"$plan")
((plan_bytes > 0 && plan_bytes <= 65536)) || die 2 "plan: size must be 1..65536 bytes, got $plan_bytes"

if [[ -n $receipt ]]; then
  require_own_file "$receipt" 'backup receipt'
  receipt_bytes=$(wc -c <"$receipt")
  ((receipt_bytes > 0 && receipt_bytes <= 16384)) ||
    die 4 "refused: backup receipt: size must be 1..16384 bytes, got $receipt_bytes"
fi

require_own_dir "$out_dir" 'out-dir'
if [[ -n $fixture_dir ]]; then
  require_own_dir "$fixture_dir" 'fixture-dir'
fi

if [[ -z $fixture_dir ]]; then
  for tool in "$diskutil_bin" "$sysctl_bin" "$mount_bin"; do
    [[ $tool == /* ]] || die 2 "tool override must be an absolute path: $tool"
    [[ -f $tool && ! -L $tool && -x $tool ]] || die 2 "tool is not an executable regular file: $tool"
  done
fi

# --- read-only planning; all JSON work happens in one bounded stdlib-only helper ---
"$PYTHON" -I -B - \
  "$mode" "$plan" "$out_dir" "${fixture_dir:--}" "${receipt:--}" \
  "$diskutil_bin" "$sysctl_bin" "$mount_bin" <<'PYTHON'
import hashlib
import json
import os
import plistlib
import re
import subprocess
import sys

PLAN_SCHEMA = "sanjbox.apfs-pilot.plan.v1"
OUT_SCHEMA = "sanjbox.apfs-pilot.dry-run.v1"
RECEIPT_SCHEMA = "sanjbox.apfs-pilot.backup-receipt.v1"
OUT_NAME = "apfs-pilot-plan.json"
MAX_PLAN_BYTES = 64 * 1024
MAX_RECEIPT_BYTES = 16 * 1024

UUID_RE = re.compile(r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")
DEVICE_RE = re.compile(r"^disk[0-9]+(s[0-9]+){1,3}$")
LABEL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
SNAPSHOT_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$")
CREATED_AT_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
MOUNT_PREFIXES = ("/Volumes/", "/private/tmp/")
FORBIDDEN_ROLES = frozenset(
    ["System", "Data", "Preboot", "Recovery", "VM", "Update", "xART", "Hardware", "Baseband"]
)
FORBIDDEN_MOUNTS = ("/", "/System/Volumes/")

mode, plan_path, out_dir, fixture_dir, receipt_path, diskutil, sysctl, mount = sys.argv[1:9]


def fail(code, message):
    sys.stderr.write("apfs-pilot: " + message + "\n")
    raise SystemExit(code)


def load_json(raw, label, limit):
    if not raw:
        fail(2, label + ": empty input")
    if len(raw) > limit:
        fail(2, label + ": exceeds " + str(limit) + " bytes")

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
        return json.loads(
            raw.decode("utf-8"), object_pairs_hook=no_duplicates, parse_constant=no_constants
        )
    except (UnicodeDecodeError, ValueError) as exc:
        fail(2, label + ": invalid JSON: " + str(exc))


def read_bytes(path, limit):
    try:
        with open(path, "rb") as handle:
            data = handle.read(limit + 1)
    except OSError as exc:
        fail(2, "cannot read " + path + ": " + str(exc))
    if len(data) > limit:
        fail(2, path + ": exceeds " + str(limit) + " bytes")
    return data


def require_object(obj, label, required, optional=()):
    if not isinstance(obj, dict):
        fail(2, label + ": must be a JSON object")
    missing = sorted(set(required) - set(obj))
    unknown = sorted(set(obj) - set(required) - set(optional))
    if missing:
        fail(2, label + ": missing key(s) " + ", ".join(missing))
    if unknown:
        fail(2, label + ": unknown key(s) " + ", ".join(unknown))


def require_string(obj, key, label, limit=1024):
    value = obj.get(key)
    if not isinstance(value, str) or not value:
        fail(2, label + "." + key + ": must be a non-empty string")
    if len(value.encode("utf-8")) > limit:
        fail(2, label + "." + key + ": exceeds " + str(limit) + " bytes")
    if any(ch in value for ch in ("\x00", "\n", "\r")):
        fail(2, label + "." + key + ": control characters refused")
    return value


def optional_uuid(obj, key, label):
    value = obj.get(key)
    if value is None:
        return None
    if not isinstance(value, str) or not UUID_RE.match(value):
        fail(2, label + "." + key + ": must be a UUID like 00000000-0000-0000-0000-000000000000")
    return value


def require_absolute_under(value, label, prefixes):
    if not value.startswith("/") or value.startswith("//") or value.endswith("/") or "/./" in value \
            or "/../" in value or value == "/..":
        fail(2, label + ": must be a normalized absolute path, got " + value)
    if not any(value.startswith(prefix) and len(value) > len(prefix) for prefix in prefixes):
        fail(2, label + ": must live under one of " + ", ".join(prefixes) + ", got " + value)
    return value


def check_volume(side, label):
    require_object(side, label, ["device"], ["expectedVolumeUUID", "expectedContainerUUID"])
    device = require_string(side, "device", label, 64)
    if not DEVICE_RE.match(device):
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
        if not LABEL_RE.match(value):
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
        if not LABEL_RE.match(pair_id) or pair_id in ids:
            fail(2, label + ".id: unique [A-Za-z0-9._-] label required")
        ids.add(pair_id)
        name = require_string(pair, "snapshotName", label, 63)
        if not SNAPSHOT_RE.match(name) or name in names:
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


def check_receipt(doc, plan):
    require_object(
        doc,
        "backup receipt",
        ["schema", "pilotId", "transactionLabel", "createdAt", "backupLocation", "coversDevices"],
    )
    if doc["schema"] != RECEIPT_SCHEMA:
        fail(4, "refused: backup receipt: expected schema " + RECEIPT_SCHEMA)
    if doc["pilotId"] != plan["pilotId"]:
        fail(4, "refused: backup receipt: pilotId does not match the plan")
    if doc["transactionLabel"] != plan["transactionLabel"]:
        fail(4, "refused: backup receipt: transactionLabel does not match the plan")
    created = require_string(doc, "createdAt", "backup receipt", 32)
    if not CREATED_AT_RE.match(created):
        fail(4, "refused: backup receipt: createdAt must be UTC YYYY-MM-DDTHH:MM:SSZ")
    location = require_string(doc, "backupLocation", "backup receipt", 1024)
    if location.strip() != location:
        fail(4, "refused: backup receipt: backupLocation has surrounding whitespace")
    covers = doc["coversDevices"]
    if not isinstance(covers, list) or not covers:
        fail(4, "refused: backup receipt: coversDevices must be a non-empty array")
    if len(set(covers)) != len(covers):
        fail(4, "refused: backup receipt: coversDevices contains duplicates")
    for device in covers:
        if not isinstance(device, str) or not DEVICE_RE.match(device):
            fail(4, "refused: backup receipt: coversDevices entry is not a volume device")
    missing = sorted(set(plan["devices"]) - set(covers))
    if missing:
        fail(4, "refused: backup receipt: does not cover " + ", ".join(missing))
    return {
        "createdAt": created,
        "backupLocation": location,
        "coversDevices": sorted(covers),
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
            result = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        except OSError as exc:
            fail(6, "probe command could not start: " + " ".join(argv) + ": " + str(exc))
        if result.returncode != 0:
            fail(6, "probe command failed with " + str(result.returncode) + ": " + " ".join(argv))
        return result.stdout

    def _fixture(self, name):
        path = os.path.join(self.directory, name)
        if not os.path.isfile(path) or os.path.islink(path):
            fail(6, "fixture-mock: missing regular fixture " + name)
        return read_bytes(path, 4 * 1024 * 1024)

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
    try:
        doc = plistlib.loads(data)
    except Exception as exc:  # plistlib raises several unrelated types
        fail(6, label + ": cannot parse property list: " + str(exc))
    if not isinstance(doc, dict):
        fail(6, label + ": property list root must be a dictionary")
    return doc


def parse_mounts(text):
    entries = []
    for line in text.decode("utf-8", "replace").splitlines():
        match = re.match(r"^(\S+) on (.+) \(([^)]*)\)$", line)
        if not match:
            continue
        options = [item.strip() for item in match.group(3).split(",") if item.strip()]
        entries.append(
            {"device": match.group(1), "mountpoint": match.group(2), "mountFields": options}
        )
    entries.sort(key=lambda item: (item["mountpoint"], item["device"]))
    return entries


def main():
    plan_doc = load_json(read_bytes(plan_path, MAX_PLAN_BYTES + 1), "plan", MAX_PLAN_BYTES)
    plan = check_plan(plan_doc)
    plan_digest = hashlib.sha256(
        json.dumps(plan_doc, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()

    receipt = None
    if receipt_path != "-":
        receipt_doc = load_json(
            read_bytes(receipt_path, MAX_RECEIPT_BYTES + 1), "backup receipt", MAX_RECEIPT_BYTES
        )
        receipt = check_receipt(receipt_doc, plan)

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
    if not UUID_RE.match(boot_uuid):
        fail(6, "kern.bootsessionuuid did not return a UUID")

    apfs_doc = parse_plist(probe.apfs_list(), "apfs list")
    containers_doc = apfs_doc.get("Containers")
    if not isinstance(containers_doc, list) or not containers_doc:
        fail(6, "apfs list: Containers array is missing or empty")
    mounts = parse_mounts(probe.mount_table())

    volumes = {}
    containers = {}
    for container in containers_doc:
        if not isinstance(container, dict):
            fail(6, "apfs list: container entry is not a dictionary")
        container_uuid = container.get("APFSContainerUUID")
        if not isinstance(container_uuid, str) or not UUID_RE.match(container_uuid):
            fail(6, "apfs list: container without a valid UUID")
        if container_uuid in containers:
            fail(6, "apfs list: duplicate container UUID " + container_uuid)
        container_volumes = container.get("Volumes")
        if not isinstance(container_volumes, list):
            fail(6, "apfs list: container without a Volumes array")
        record = {
            "uuid": container_uuid,
            "designatedPhysicalStore": container.get("DesignatedPhysicalStore", ""),
            "capacityCeilingBytes": int(container.get("CapacityCeiling", 0) or 0),
            "capacityFreeBytes": int(container.get("CapacityFree", 0) or 0),
            "volumes": [],
        }
        for volume in container_volumes:
            if not isinstance(volume, dict):
                fail(6, "apfs list: volume entry is not a dictionary")
            device = volume.get("DeviceIdentifier")
            volume_uuid = volume.get("APFSVolumeUUID")
            if not isinstance(device, str) or not DEVICE_RE.match(device):
                fail(6, "apfs list: volume without a valid device identifier")
            if not isinstance(volume_uuid, str) or not UUID_RE.match(volume_uuid):
                fail(6, "apfs list: volume " + device + " without a valid UUID")
            roles = volume.get("Roles") or []
            if not isinstance(roles, list) or any(not isinstance(role, str) for role in roles):
                fail(6, "apfs list: volume " + device + " has malformed Roles")
            entry = {
                "device": device,
                "volumeUUID": volume_uuid,
                "name": volume.get("Name", ""),
                "roles": sorted(roles),
                "capacityQuotaBytes": int(volume.get("CapacityQuota", 0) or 0),
                "capacityReserveBytes": int(volume.get("CapacityReserve", 0) or 0),
                "capacityInUseBytes": int(volume.get("CapacityInUse", 0) or 0),
                "containerUUID": container_uuid,
            }
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
        infos[device] = parse_plist(probe.volume_info(device), "volume info " + device)

    relevant_mounts = []
    for entry in mounts:
        device = entry["device"]
        bare = device[5:] if device.startswith("/dev/") else device
        if bare == "disk" or bare in gated_devices or entry["mountpoint"] == "/":
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
    if mismatched:
        gate("identity-match", "fail", "declared UUID does not match observation: " + ", ".join(mismatched))
    else:
        gate("identity-match", "pass", "every declared UUID that was checked matches the observation")

    forbidden = []
    for item in pilot_volumes:
        observed = item["observed"]
        if observed is None:
            continue
        hits = sorted(FORBIDDEN_ROLES.intersection(observed["roles"]))
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
            if mountpoint == "/" or mountpoint.startswith(FORBIDDEN_MOUNTS[1]):
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

    busy_targets = []
    for item in pilot_volumes:
        if item["side"] != "target" or not item["mountpoint"]:
            continue
        if not (item["mountpoint"] == plan["pilotRoot"]
                or item["mountpoint"].startswith(plan["pilotRoot"] + "/")):
            busy_targets.append(item["device"] + " is mounted at " + item["mountpoint"])
    if busy_targets:
        gate("target-not-active", "fail", "; ".join(busy_targets))
    else:
        gate("target-not-active", "pass", "no target is mounted outside the declared pilot root")

    quotas = [item for item in pilot_volumes if item["observed"] and item["observed"]["capacityQuotaBytes"] == 0]
    if len(quotas) == len([item for item in pilot_volumes if item["observed"]]):
        gate(
            "quota-declared",
            "warn",
            "no pilot volume has an APFS quota; quota 0 means unbounded, not reserved space",
        )
    else:
        gate("quota-declared", "pass", "at least one pilot volume declares an APFS quota")

    if receipt is not None:
        gate("backup-receipt", "pass", "receipt covers every plan device and matches pilot/transaction")
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
        }
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
                "reason": "Only the operator's own snapshot mount, after an identity check.",
            }
        )
        cleanup_steps.append(
            {
                "id": "delete-snapshot-" + pair["id"],
                "argv": [
                    "diskutil",
                    "apfs",
                    "deleteSnapshot",
                    pair["source"]["device"],
                    "-name",
                    pair["snapshotName"],
                    "-wait",
                ],
                "argvTemplate": False,
                "readOnly": False,
                "rootRequired": False,
                "executed": False,
                "reason": "Only after P2/P3 are closed and the snapshot is provably unused; -wait "
                "because deletion can continue after the command returns.",
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
            "reason": "Read-only: close the run only after no pilot snapshot, mount or target remains.",
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
            "gatesPassed": all(item["status"] != "fail" for item in gates),
            "manualGates": sorted(
                item["id"] for item in gates if item["status"] == "manual"
            ),
            "realStartAllowed": False,
        },
    }
    if receipt is not None:
        doc["backupReceipt"] = {
            "createdAt": receipt["createdAt"],
            "sha256": hashlib.sha256(
                read_bytes(receipt_path, MAX_RECEIPT_BYTES + 1)
            ).hexdigest(),
            "coversDevices": receipt["coversDevices"],
        }

    data = (json.dumps(doc, sort_keys=True, indent=2, ensure_ascii=True) + "\n").encode("utf-8")
    failed = not doc["verdict"]["gatesPassed"]

    if mode == "dry-run":
        path = os.path.join(out_dir, OUT_NAME)
        if os.path.lexists(path):
            if os.path.islink(path) or not os.path.isfile(path):
                fail(2, "output exists and is not a regular file: " + path)
            current = read_bytes(path, 8 * 1024 * 1024)
            if current == data:
                sys.stderr.write("apfs-pilot: dry-run output already identical; not rewritten\n")
                data = None
            else:
                if os.stat(path, follow_symlinks=False).st_uid != os.geteuid():
                    fail(2, "output is not owned by the caller: " + path)
        if data is not None:
            temp = os.path.join(out_dir, "." + OUT_NAME + ".tmp." + str(os.getpid()))
            flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
            descriptor = os.open(temp, flags, 0o600)
            try:
                with os.fdopen(descriptor, "wb") as handle:
                    handle.write(data)
                    handle.flush()
                    os.fsync(handle.fileno())
                os.replace(temp, path)
            except BaseException:
                try:
                    os.unlink(temp)
                except OSError:
                    pass
                raise

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


main()
PYTHON
