#!/usr/bin/python3
"""C1 laboratory preparation, not a production boundary. No actual PF calls in dry-run.

Only the CLI constructs System. Tests inject a fake executor and an in-memory journal.
The only mutation is a filter-only load into one predelegated, fixed anchor.
"""
import argparse
import ctypes
import fcntl
import errno
import hashlib
import json
import os
from pathlib import Path
import platform
import pwd
import re
import selectors
import shlex
import stat
import subprocess
import sys
import time

ANCHOR = "sanjbox_c1"
HERE = Path(__file__).absolute().parent
MAX_FILE = 64 * 1024
MAX_OUTPUT = 1024 * 1024
MAX_RECORDS = 32


class Refused(Exception):
    pass


def require(value, message):
    if not value:
        raise Refused(message)


def strict_json(raw):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, "duplicate JSON key")
            result[key] = value
        return result
    require(len(raw) <= MAX_FILE, "JSON too large")
    depth = 0
    quoted = escaped = False
    for char in raw:
        if quoted:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                quoted = False
        elif char == '"':
            quoted = True
        elif char in "[{":
            depth += 1
            require(depth <= 16, "JSON nesting too deep")
        elif char in "]}":
            depth -= 1
    try:
        return json.loads(raw, object_pairs_hook=unique)
    except (ValueError, UnicodeError, RecursionError) as error:
        raise Refused("invalid JSON") from error


def config_checked(c):
    require(type(c) is dict and set(c) == {"schema", "run_id", "zones"}, "config keys")
    require(type(c["schema"]) is int and c["schema"] == 1, "config schema")
    require(type(c["run_id"]) is str and re.fullmatch(r"[a-z0-9]{8,12}", c["run_id"]), "run_id")
    zones = c["zones"]
    require(type(zones) is list and 1 <= len(zones) <= 3, "one to three test zones")
    for z in zones:
        require(type(z) is dict and set(z) == {"uid", "name"}, "zone keys")
        require(type(z["uid"]) is int and 400 <= z["uid"] <= 60000, "UID range")
        require(type(z["name"]) is str and re.fullmatch(r"snjt[123]", z["name"]), "S1 test account name")
    require(len({z["uid"] for z in zones}) == len(zones), "duplicate UID")
    require(len({z["name"] for z in zones}) == len(zones), "duplicate account")
    return c


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def metadata(st, directory, owner, strict, private=False):
    require(stat.S_ISDIR(st.st_mode) if directory else stat.S_ISREG(st.st_mode), "wrong path type")
    require(st.st_uid in ({owner} if strict else {0, owner}), "wrong path owner")
    if strict or not directory:
        require(st.st_mode & 0o022 == 0, "group/world-writable path")
    if not directory:
        require(st.st_nlink == 1, "hard-linked file")
    if private:
        require(stat.S_IMODE(st.st_mode) == (0o700 if directory else 0o600), "private state mode required")


def reject_extended_acl(fd):
    # Darwin public sys/acl.h: an ACE can grant writes despite Unix mode bits.
    # Apply is Darwin-only; do not silently skip an unavailable ACL inspection.
    require(platform.system() == "Darwin", "secure deployment ACL inspection requires macOS")
    libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    libc.acl_get_fd_np.argtypes = (ctypes.c_int, ctypes.c_int)
    libc.acl_get_fd_np.restype = ctypes.c_void_p
    libc.acl_get_entry.argtypes = (ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_void_p))
    libc.acl_free.argtypes = (ctypes.c_void_p,)
    libc.acl_valid.argtypes = (ctypes.c_void_p,)
    ctypes.set_errno(0)
    acl = libc.acl_get_fd_np(fd, 0x100)  # ACL_TYPE_EXTENDED
    if not acl:
        require(ctypes.get_errno() == errno.ENOENT, "cannot inspect extended ACL")
        return
    try:
        entry = ctypes.c_void_p()
        require(libc.acl_valid(acl) == 0, "invalid ACL")
        ctypes.set_errno(0)
        result = libc.acl_get_entry(acl, 0, ctypes.byref(entry))
        require(result == -1 and ctypes.get_errno() == errno.EINVAL, "extended ACL or ACL inspection failure")
    finally:
        libc.acl_free(acl)


def open_directory(path, strict=False, owner=None):
    """Walk with openat/O_NOFOLLOW. Apply admits only root-owned non-writable parents.

    /private/... is intentional: symlink aliases such as /tmp and /var are refused.
    The returned descriptor pins the directory even if a trusted parent is renamed.
    """
    owner = os.geteuid() if owner is None else owner
    raw = os.fspath(path)
    require(raw.startswith("/") and "\x00" not in raw, "absolute path required")
    require(all(p not in ("", ".", "..") for p in raw.split("/")[1:]), "noncanonical path")
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in raw.split("/")[1:]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = child
            # Dry-run may live in a private user's checkout beneath /private/tmp.
            if strict:
                metadata(os.fstat(fd), True, owner, True)
                reject_extended_acl(fd)
        return fd
    except BaseException:
        os.close(fd)
        raise


def read_at(fd, name, strict=False, owner=None, private=False):
    owner = os.geteuid() if owner is None else owner
    handle = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
    try:
        st = os.fstat(handle)
        metadata(st, False, owner, strict, private)
        if strict:
            reject_extended_acl(handle)
        require(st.st_size <= MAX_FILE, "file too large")
        data = b""
        while len(data) <= MAX_FILE:
            part = os.read(handle, min(8192, MAX_FILE + 1 - len(data)))
            if not part:
                break
            data += part
        require(len(data) <= MAX_FILE, "file grew too large")
        after = os.fstat(handle)
        named = os.stat(name, dir_fd=fd, follow_symlinks=False)
        fingerprint = lambda value: (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns, value.st_mode, value.st_uid, value.st_gid, value.st_nlink)
        require(fingerprint(st) == fingerprint(after) == fingerprint(named), "file changed during read")
        require(len(data) == st.st_size, "short input read")
        return data.decode("utf-8")
    finally:
        os.close(handle)


def read_file(path, strict=False):
    path = Path(os.path.abspath(path))
    fd = open_directory(path.parent, strict)
    try:
        return read_at(fd, path.name, strict)
    finally:
        os.close(fd)


def config_path_checked(path):
    require(all(ord(char) >= 32 and ord(char) != 127 for char in os.fspath(path)), "control character in config path")
    parts = os.fspath(path).split("/")
    require(re.fullmatch(r"config(?:-[a-zA-Z0-9_-]{1,40})?\.json", parts[-1]), "config schema filename required")
    for part in parts:
        require(not part.startswith(".") and not any(word in part.lower() for word in ("secret", "credential", "token", "keychain")), "restricted config path")
    return path


def expected_rules(config):
    result = []
    for z in config["zones"]:
        for family in ("inet", "inet6"):
            for direction in ("in", "out"):
                for proto in ("tcp", "udp"):
                    label = f'c1_{config["run_id"]}_{z["uid"]}_{family}_{direction}_{proto}'
                    result.append((direction, family, proto, z["uid"], label))
    return result


def render(config, template):
    # Prevent an edited template from introducing pass/global statements under root.
    fixed = 'block drop @DIRECTION@ quick @FAMILY@ proto @PROTO@ from any to any user @UID@ label "@LABEL@"'
    lines = [line for line in template.splitlines() if line and not line.startswith("#")]
    require(lines == [fixed], "unsupported template; review required")
    result = []
    for direction, family, proto, uid, label in expected_rules(config):
        line = fixed
        for key, value in (("DIRECTION", direction), ("FAMILY", family), ("PROTO", proto), ("UID", str(uid)), ("LABEL", label)):
            line = line.replace(f"@{key}@", value)
        result.append(line)
    return "\n".join(result) + "\n"


def semantic_rules(raw, config):
    by_name = {z["name"]: z["uid"] for z in config["zones"]}
    result = []
    for line in raw.splitlines():
        if not line.strip():
            continue
        try:
            w = shlex.split(line)
        except ValueError as error:
            raise Refused("unrecognized rule display") from error
        if len(w) >= 8 and w[7] == "all":
            w[7:8] = ["from", "any", "to", "any"]
        if len(w) == 16 and w[12] == "=":
            w.pop(12)
        require(len(w) == 15, "unexpected rule/options")
        require(w[:2] == ["block", "drop"] and w[2] in ("in", "out") and w[3] == "quick", "not our explicit quick drop")
        require(w[4] in ("inet", "inet6") and w[5] == "proto" and w[6] in ("tcp", "udp"), "family/proto")
        require(w[7:12] == ["from", "any", "to", "any", "user"] and w[13] == "label", "rule syntax")
        uid = int(w[12]) if re.fullmatch(r"[0-9]{1,5}", w[12]) else by_name.get(w[12])
        require(uid is not None, "foreign user")
        result.append((w[2], w[4], w[6], uid, w[14]))
    return result


class System:
    """Fixed executables, bounded I/O and deadline; no shell and no env override."""
    def run(self, argv, data=None):
        require(argv[0] in ("/sbin/pfctl", "/bin/ps"), "executable not allowed")
        payload = None if data is None else data.encode()
        require(payload is None or len(payload) <= MAX_FILE, "stdin too large")
        env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "LANG": "C"}
        process = subprocess.Popen(argv, stdin=subprocess.PIPE if payload is not None else subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        # Nonblocking stdin/output share the same five-second deadline.
        selector = selectors.DefaultSelector()
        buffers = {process.stdout: bytearray(), process.stderr: bytearray()}
        try:
            if payload is not None:
                os.set_blocking(process.stdin.fileno(), False)
                selector.register(process.stdin, selectors.EVENT_WRITE)
            for stream in buffers:
                os.set_blocking(stream.fileno(), False)
                selector.register(stream, selectors.EVENT_READ)
            until = time.monotonic() + 5
            offset = 0
            while selector.get_map():
                require(time.monotonic() < until, "command timeout; inspect journal, do not assume rollback")
                for key, _ in selector.select(min(0.1, max(0, until - time.monotonic()))):
                    stream = key.fileobj
                    if stream is process.stdin:
                        offset += os.write(stream.fileno(), payload[offset:]) if offset < len(payload) else 0
                        if offset == len(payload):
                            selector.unregister(stream)
                            stream.close()
                    else:
                        chunk = os.read(stream.fileno(), 8192)
                        if not chunk:
                            selector.unregister(stream)
                        else:
                            buffers[stream].extend(chunk)
                            require(sum(len(b) for b in buffers.values()) <= MAX_OUTPUT, "command output limit")
            process.wait(timeout=max(0.001, until - time.monotonic()))
            require(process.returncode == 0, f"command refused ({process.returncode}); inspect journal")
            return buffers[process.stdout].decode("utf-8", errors="strict")
        finally:
            selector.close()
            if process.poll() is None:
                process.kill()
            process.wait()
            for stream in (process.stdin, process.stdout, process.stderr):
                if stream is not None:
                    stream.close()

    def account_uid(self, name):
        return pwd.getpwnam(name).pw_uid


def snapshot(system):
    # No global state-table/connection dump: only rules and PF status/counters.
    result = {"info": system.run(["/sbin/pfctl", "-s", "info"]),
              "root_rules": system.run(["/sbin/pfctl", "-sr"])}
    for name, flags in (("rules", ["-sr"]), ("nat", ["-sn"]), ("children", ["-s", "Anchors"]), ("tables", ["-s", "Tables"])):
        result[name] = system.run(["/sbin/pfctl", "-a", ANCHOR] + flags)
    return result


def prerequisite(system, config, snap):
    require(re.search(r"(?m)^Status: Enabled\b", snap["info"]), "PF must already be enabled by the lab owner")
    lines = [line.strip() for line in snap["root_rules"].splitlines() if line.strip()]
    call = f'anchor "{ANCHOR}" all'
    require(lines and lines[0] == call and sum(ANCHOR in line for line in lines) == 1,
            "requires exact, unconditional first root filter call: " + call)
    require(not any(snap[key].strip() for key in ("nat", "children", "tables")), "anchor has foreign translation/children/tables")
    for z in config["zones"]:
        require(system.account_uid(z["name"]) == z["uid"], "account/UID mismatch")
    # Only numeric real/effective UID columns, never command lines or process names.
    rows = system.run(["/bin/ps", "-axo", "ruid=,uid="]).splitlines()
    require(rows, "empty process snapshot")
    targets = {z["uid"] for z in config["zones"]}
    for row in rows:
        require(re.fullmatch(r"\s*[0-9]+\s+[0-9]+\s*", row), "unrecognized process UID snapshot")
        require(not targets.intersection(map(int, row.split())), "live test UID; stop sessions/jobs and prevent new starts first")


def mutate(system, text):
    system.run(["/sbin/pfctl", "-a", ANCHOR, "-R", "-o", "none", "-f", "-"], text)


def transact(action, config, template, store, system):
    text = render(config, template)
    expected = expected_rules(config)
    previous = store.latest()
    if previous is not None:
        require(type(previous) is dict and set(previous) == {"schema", "phase", "config", "render_sha256", "before"}, "journal schema")
        require(previous["schema"] == 1 and previous["config"] == config and previous["render_sha256"] == digest(text), "journal belongs to another config/template")
        require(previous["phase"] in ("prepared_load", "loaded", "prepared_unload", "unloaded"), "journal phase")
        require(type(previous["before"]) is dict and set(previous["before"]) == {"info", "root_rules", "rules", "nat", "children", "tables"}, "journal snapshot")
        require(all(type(v) is str for v in previous["before"].values()), "journal snapshot type")
    snap = snapshot(system)
    prerequisite(system, config, snap)
    if previous:
        require(snap["root_rules"] == previous["before"]["root_rules"], "parent filter rules changed; manual review required")
    current = semantic_rules(snap["rules"], config)

    def record(phase, before):
        store.append({"schema": 1, "phase": phase, "config": config, "render_sha256": digest(text), "before": before})

    if action == "load":
        require(previous is None or previous["phase"] in ("prepared_load", "loaded"), "completed/cleaning run; use a new state directory and run_id")
        if current == expected and previous is not None:
            if previous["phase"] == "prepared_load":
                record("loaded", snap)
            return "already loaded; no PF write"
        require(not current and (previous is None or previous["phase"] == "prepared_load"), "anchor conflict or lost loaded rules; no automatic reload")
        system.run(["/sbin/pfctl", "-a", ANCHOR, "-n", "-R", "-o", "none", "-f", "-"], text)
        store.ensure_capacity(2)
        record("prepared_load", snap)  # durable write-ahead, even if pfctl dies after applying
        # Recheck after journal I/O and directly before change. External root writers
        # cannot be atomically excluded by pfctl: a reserved serial L4 slot is required.
        fresh = snapshot(system)
        prerequisite(system, config, fresh)
        require(all(fresh[k] == snap[k] for k in ("root_rules", "rules", "nat", "children", "tables")), "PF changed during preparation")
        mutate(system, text)
        after = snapshot(system)
        prerequisite(system, config, after)
        require(after["root_rules"] == snap["root_rules"] and semantic_rules(after["rules"], config) == expected, "load verification failed; journal retained, no automatic cleanup")
        record("loaded", after)
        return "diagnostic deny rules loaded; NOT an R3 boundary or permission to start a real zone"

    require(previous is not None, "no ownership journal; refuse cleanup")
    require(not current or current == expected, "own anchor was changed; refuse cleanup")
    if previous["phase"] == "unloaded":
        require(not current, "rules reappeared after cleanup; refuse")
        return "already empty; no PF write"
    if not current:
        record("unloaded", snap)
        return "already empty (possibly externally flushed); no PF write, no isolation claim"
    store.ensure_capacity(2)
    record("prepared_unload", snap)  # record before even clearing our one filter ruleset
    fresh = snapshot(system)
    prerequisite(system, config, fresh)
    require(fresh["root_rules"] == snap["root_rules"] and semantic_rules(fresh["rules"], config) == expected, "PF changed during cleanup")
    mutate(system, "")  # never -F, -d, -X, global -f, states, tables or parent edits
    after = snapshot(system)
    prerequisite(system, config, after)
    require(after["root_rules"] == snap["root_rules"] and not after["rules"].strip(), "cleanup verification failed; inspect journal")
    record("unloaded", after)
    return "own filter rules cleared; parent, PF enable state and global states untouched"


class Journal:
    """Append-only, fsynced records and a persistent lock; never deletes a path.

    Requires an existing empty root-owned 0700 state directory. Bounded records mean
    a failure to append cannot silently lose the write-ahead record or overwrite it.
    """
    def __init__(self, fd):
        self.fd = fd
        self.names = sorted(os.listdir(fd))
        require(all(name == "lock" or re.fullmatch(r"[0-9]{4}\.json", name) for name in self.names), "foreign state entry")
        self.names = [name for name in self.names if name != "lock"]
        require(self.names == [f"{i:04}.json" for i in range(1, len(self.names) + 1)], "journal sequence")
        require(len(self.names) <= MAX_RECORDS, "journal too large")
        self.lock = os.open("lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600, dir_fd=fd)
        metadata(os.fstat(self.lock), False, os.geteuid(), True, True)
        reject_extended_acl(self.lock)
        fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        # Enumeration must be repeated *after* acquiring the lock.
        current = sorted(name for name in os.listdir(fd) if name != "lock")
        require(current == self.names, "journal changed while taking lock")
        for name in self.names:
            strict_json(read_at(fd, name, True, private=True))

    def latest(self):
        return strict_json(read_at(self.fd, self.names[-1], True, private=True)) if self.names else None

    def ensure_capacity(self, count):
        require(len(self.names) + count <= MAX_RECORDS, "journal lacks room for before/after records; no PF change")

    def append(self, record):
        require(len(self.names) < MAX_RECORDS, "journal full; inspect, do not delete")
        raw = (canonical(record) + "\n").encode()
        require(len(raw) <= MAX_FILE, "snapshot too large for journal; no PF change")
        name = f"{len(self.names) + 1:04}.json"
        fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=self.fd)
        try:
            offset = 0
            while offset < len(raw):
                offset += os.write(fd, raw[offset:])
            os.fsync(fd)
        finally:
            os.close(fd)
        os.fsync(self.fd)
        self.names.append(name)

    def close(self):
        os.close(self.lock)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("load", "unload"))
    parser.add_argument("--config", required=True)
    parser.add_argument("--state", required=True, help="existing private state directory for --apply; not created in dry-run")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--apply", action="store_true")
    mode.add_argument("--dry-run", action="store_true")
    parser.add_argument("--lab-quiescent", action="store_true", help="USER attests reserved L4, synthetic zones stopped and all start paths disabled; no concurrent PF writers")
    args = parser.parse_args(argv)
    config = config_checked(strict_json(read_file(config_path_checked(args.config), strict=args.apply)))
    template = read_file(HERE / "templates/deny.pf.in", strict=args.apply)
    rules = render(config, template)
    if not args.apply:
        print("DRY-RUN: no system commands, no writes, no PF parser or device access.")
        print(f"Requires already-enabled PF and first root filter call: anchor \"{ANCHOR}\" all")
        print("USER prerequisite: reserved L4, stopped synthetic UIDs, start capability revoked, no concurrent PF writer.")
        print("State:", os.path.abspath(args.state), "(not opened/created)")
        print("Would inspect PF status, root filter and leaf filter/NAT/children/tables; verify account UIDs and no UID processes.")
        print("Would lock state, fsync before/after records, recheck and change only:")
        print(shlex.join(["/sbin/pfctl", "-a", ANCHOR, "-R", "-o", "none", "-f", "-"]))
        print(rules if args.action == "load" else "<empty stdin ONLY if unchanged owned rules and stopped UIDs>")
        return 0
    require(os.geteuid() == 0 and platform.system() == "Darwin", "--apply is user-only root macOS laboratory mode")
    require(args.lab_quiescent, "--lab-quiescent attestation required; see README")
    # Root invocation is permitted only from a reviewed root-owned deployment.
    for relative in ("pf_lab.py", "load.sh", "unload.sh"):
        read_file(HERE / relative, strict=True)
    fd = open_directory(args.state, strict=True)
    try:
        metadata(os.fstat(fd), True, 0, True, True)
        journal = Journal(fd)
        try:
            print(transact(args.action, config, template, journal, System()))
        finally:
            journal.close()
    finally:
        os.close(fd)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (Refused, OSError, KeyError, UnicodeError, subprocess.SubprocessError) as error:
        print("REFUSED:", error, file=sys.stderr)
        sys.exit(4)
