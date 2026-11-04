"""Bounded, read-only evidence inspection on POSIX Linux and macOS.

All paths in the report are validated relative names. No input contents, exception
messages, private paths, or hash values are printed. This is not a filesystem
snapshot, an attestation service, or a scientific verdict engine.
"""

from contextlib import ExitStack
from datetime import datetime
import hashlib
import json
import math
import os
import re
import stat
import sys

MAX_RUNS = 16
MAX_ENTRIES = 512                 # Files + directories, shared across selections.
MAX_DEPTH = 8
MAX_FILE_BYTES = 8 * 1024 * 1024
MAX_TOTAL_BYTES = 64 * 1024 * 1024
MAX_JSON_BYTES = 1024 * 1024
MAX_TEXT_BYTES = 1024 * 1024
MAX_JSON_DEPTH = 32
MAX_JSON_NODES = 50000
MAX_REFERENCES = 512
MAX_FINDINGS = 256
MAX_ROOT_DEPTH = 64
MAX_PATH = 1024
MAX_ATTEMPTS = 100
COMPONENT = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,199}\Z")
RUN_ID = re.compile(r"[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9]+(?:-[A-Za-z0-9]+){2,}-[0-9a-fA-F]{8}\Z")
GATE = re.compile(r"s(?:[0-8]|3b)\Z")
SHA = re.compile(r"[0-9a-f]{64}\Z")
REQUIRED = ("environment.md", "inputs.md", "credentials.log", "verdict.md", "manifest.sha256")
UNVERIFIED = [
    "scientific acceptance and F0.8 authorization",
    "historical immutability and preregistration timing (hashes are not authority)",
    "identity/session correctness, oracle calibration, concurrency and statistics",
    "reviewer authority, prose claims and configuration equivalence/contradictions",
    "private originals, source/binary provenance and sanitization fidelity",
    "unselected runs and repository-wide run ID uniqueness",
    "atomic snapshot, hostile privileged writers and changes after inspection",
]


class CheckError(Exception):
    def __init__(self, code, status="failed", path=None):
        self.finding = {"code": code, "status": status}
        if path is not None:
            self.finding["path"] = path
        super().__init__(code)


def add_finding(report, item):
    if len(report["findings"]) < MAX_FINDINGS:
        report["findings"].append(item)
    elif len(report["findings"]) == MAX_FINDINGS:
        report["findings"].append({"code": "finding_limit", "status": "failed"})


def finding(report, code, status="failed", path=None):
    item = {"code": code, "status": status}
    if path is not None:
        item["path"] = path
    add_finding(report, item)


def status_of(findings):
    for status in ("failed", "unknown", "missing"):
        if any(f["status"] == status for f in findings):
            return status
    return "consistent"


def safe_path(value):
    if not isinstance(value, str) or len(value) > MAX_PATH or not value:
        raise CheckError("unsafe_path")
    parts = value.split("/")
    if any(not COMPONENT.fullmatch(p) or p in (".", "..") for p in parts):
        raise CheckError("unsafe_path")
    return parts


def secret_name(path):
    # Only the exact documented run-root credentials.log is probe metadata.
    if path == "credentials.log":
        return False
    for name in path.lower().split("/"):
        if (name.startswith(".") or any(s in name for s in ("secret", "token", "credential", "key", "cert"))
                or name.endswith((".pem", ".p12", ".pfx", ".crt", ".cer", ".der", ".db", ".sqlite", ".sqlite3"))):
            return True
    return False


def canonical_selection(value):
    parts = safe_path(value)
    if len(parts) != 2 or not GATE.fullmatch(parts[0]) or not RUN_ID.fullmatch(parts[1]) or "--" in parts[1]:
        raise CheckError("invalid_run_id")
    try:
        datetime.strptime(parts[1][:16], "%Y%m%dT%H%M%SZ")
    except ValueError:
        raise CheckError("invalid_run_id") from None
    return parts


def signature(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_nlink, info.st_uid,
            info.st_gid, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def identity(info):
    return info.st_dev, info.st_ino, info.st_mode


def supported():
    return (sys.platform in ("darwin", "linux")
            and all(hasattr(os, flag) for flag in ("O_NOFOLLOW", "O_DIRECTORY", "O_NONBLOCK"))
            and os.open in os.supports_dir_fd and os.stat in os.supports_dir_fd
            and os.stat in os.supports_follow_symlinks and os.scandir in os.supports_fd)


class Reader:
    """Pin explicitly named ancestors and inspect only selected subtrees."""
    def __init__(self):
        self.stack = ExitStack()
        self.anchors = []
        self.entries = 0
        self.bytes = 0

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return self.stack.__exit__(*args)

    def keep(self, fd):
        self.stack.callback(os.close, fd)
        return fd

    def directory(self, parent, name, boundary=None):
        before = os.stat(name, dir_fd=parent, follow_symlinks=False)
        if not stat.S_ISDIR(before.st_mode):
            raise CheckError("unsafe_directory")
        if boundary is not None and before.st_dev != boundary:
            raise CheckError("filesystem_boundary")
        fd = self.keep(os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent))
        if signature(before) != signature(os.fstat(fd)):
            raise CheckError("concurrent_change")
        self.anchors.append((parent, name, fd, identity(before)))
        return fd

    def absolute_directory(self, path):
        # Do not realpath() a symlink into authorization. A root is a named boundary.
        if not isinstance(path, str) or not path.startswith("/") or path == "/" or len(path) > 4096:
            raise CheckError("absolute_root_required")
        parts = path[1:].split("/")
        if len(parts) > MAX_ROOT_DEPTH:
            raise CheckError("root_depth_limit")
        if any(p in ("", ".", "..") or "\x00" in p for p in parts):
            raise CheckError("ambiguous_root")
        fd = self.keep(os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW))
        for part in parts:
            fd = self.directory(fd, part)
        return fd

    def check_anchors(self):
        for parent, name, fd, original in self.anchors:
            if (identity(os.stat(name, dir_fd=parent, follow_symlinks=False)) != original
                    or identity(os.fstat(fd)) != original):
                raise CheckError("concurrent_change")

    def read_file(self, parent, name, before, path):
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise CheckError("unsafe_file_type_or_hardlink", path=path)
        if before.st_size > MAX_FILE_BYTES:
            raise CheckError("file_size_limit", path=path)
        if self.bytes + before.st_size > MAX_TOTAL_BYTES:
            raise CheckError("total_size_limit")
        # NONBLOCK prevents a replacement FIFO from hanging before fstat rejects it.
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
        try:
            if signature(before) != signature(os.fstat(fd)):
                raise CheckError("concurrent_change", path=path)
            chunks = []
            remaining = before.st_size
            while remaining:
                chunk = os.read(fd, min(65536, remaining))
                if not chunk:
                    raise CheckError("incomplete_read", path=path)
                chunks.append(chunk)
                remaining -= len(chunk)
            if os.read(fd, 1) or signature(before) != signature(os.fstat(fd)):
                raise CheckError("concurrent_change", path=path)
            if signature(before) != signature(os.stat(name, dir_fd=parent, follow_symlinks=False)):
                raise CheckError("concurrent_change", path=path)
            self.bytes += before.st_size
            return b"".join(chunks)
        finally:
            os.close(fd)

    def snapshot(self, root, read=True):
        files, metadata = {}, {}
        boundary = os.fstat(root).st_dev
        # Metadata-only verification is bounded independently; it cannot discover
        # and read newly introduced contents after the initial snapshot.
        visited = 0

        def walk(fd, prefix, depth):
            nonlocal visited
            if depth > MAX_DEPTH:
                raise CheckError("depth_limit")
            initial = os.fstat(fd)
            metadata[prefix] = signature(initial)
            names = []
            with os.scandir(fd) as directory:
                for entry in directory:
                    visited += 1
                    if visited > MAX_ENTRIES or (read and self.entries >= MAX_ENTRIES):
                        raise CheckError("entry_count_limit")
                    if read:
                        self.entries += 1
                    name = entry.name
                    path = prefix + "/" + name if prefix else name
                    safe_path(path)
                    if secret_name(path):
                        raise CheckError("prohibited_name")
                    names.append(name)
            # Reject case aliases on both case-sensitive and case-insensitive hosts.
            if len({n.casefold() for n in names}) != len(names):
                raise CheckError("ambiguous_case_names")
            for name in sorted(names):
                path = prefix + "/" + name if prefix else name
                before = os.stat(name, dir_fd=fd, follow_symlinks=False)
                if before.st_dev != boundary:
                    raise CheckError("filesystem_boundary", path=path)
                if stat.S_ISDIR(before.st_mode):
                    child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                    try:
                        if signature(before) != signature(os.fstat(child)):
                            raise CheckError("concurrent_change", path=path)
                        walk(child, path, depth + 1)
                        if signature(before) != signature(os.stat(name, dir_fd=fd, follow_symlinks=False)):
                            raise CheckError("concurrent_change", path=path)
                    finally:
                        os.close(child)
                else:
                    if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
                        raise CheckError("unsafe_file_type_or_hardlink", path=path)
                    metadata[path] = signature(before)
                    if read:
                        files[path] = self.read_file(fd, name, before, path)
            if signature(initial) != signature(os.fstat(fd)):
                raise CheckError("concurrent_change")

        walk(root, "", 0)
        return files, metadata


def decode(data, path, limit=MAX_TEXT_BYTES):
    if len(data) > limit:
        raise CheckError("text_size_limit", path=path)
    try:
        result = data.decode("utf-8")
    except UnicodeDecodeError:
        raise CheckError("invalid_utf8", path=path) from None
    if "\x00" in result or "\r" in result:
        raise CheckError("ambiguous_text_encoding", path=path)
    return result


def strict_json(data, path):
    source = decode(data, path, MAX_JSON_BYTES)
    # Bound nesting before invoking the recursive stdlib decoder.
    depth, in_string, escape = 0, False, False
    for char in source:
        if in_string:
            if escape:
                escape = False
            elif char == "\\":
                escape = True
            elif char == '"':
                in_string = False
        elif char == '"':
            in_string = True
        elif char in "[{":
            depth += 1
            if depth > MAX_JSON_DEPTH:
                raise CheckError("json_depth_limit", path=path)
        elif char in "]}":
            depth -= 1

    def pairs(items):
        value = {}
        for key, item in items:
            if key in value:
                raise CheckError("duplicate_json_key", path=path)
            value[key] = item
        return value

    def constant(_):
        raise CheckError("nonfinite_json", path=path)

    try:
        result = json.loads(source, object_pairs_hook=pairs, parse_constant=constant)
    except (ValueError, RecursionError):
        raise CheckError("malformed_json", path=path) from None
    pending, count = [result], 0
    while pending:
        item = pending.pop()
        count += 1
        if count > MAX_JSON_NODES:
            raise CheckError("json_node_limit", path=path)
        if isinstance(item, float) and not math.isfinite(item):
            raise CheckError("nonfinite_json", path=path)
        if isinstance(item, dict):
            pending.extend(item.values())
        elif isinstance(item, list):
            pending.extend(item)
    return result


def target_path(source, reference):
    """Resolve minimal leading ../ inside a run, without ever following a link."""
    if not isinstance(reference, str) or len(reference) > MAX_PATH:
        raise CheckError("unsafe_reference", path=source)
    path, separator, fragment = reference.partition("#")
    if separator and (not fragment or not re.fullmatch(r"[A-Za-z0-9_-]+", fragment)):
        raise CheckError("unsupported_fragment", "unknown", source)
    if not path:
        if separator:
            return source
        raise CheckError("unsafe_reference", path=source)
    base = source.split("/")[:-1]
    parts = path.split("/")
    while parts and parts[0] == "..":
        if not base:
            raise CheckError("reference_outside_run", path=source)
        base.pop()
        parts.pop(0)
    safe_path("/".join(parts))
    result = "/".join(base + parts)
    if secret_name(result):
        raise CheckError("prohibited_reference", path=source)
    return result


def markdown_targets(source, path):
    # A deliberately small dialect: inline Markdown links only. Other link forms
    # are surfaced as unsupported rather than silently claimed as validated.
    fenced = False
    lines = []
    for line in source.splitlines():
        if line.lstrip().startswith(("```", "~~~")):
            fenced = not fenced
            continue
        if not fenced:
            lines.append(re.sub(r"`[^`]*`", "", line))
    if fenced:
        raise CheckError("unclosed_markdown_fence", path=path)
    body = "\n".join(lines)
    if re.search(r"\]\[|^[ \t]*\[[^\]\n]+\]:|<(?:a\b|img\b|https?:)", body, re.M | re.I):
        raise CheckError("unsupported_markdown_links", "unknown", path)
    pattern = re.compile(r"\[[^\[\]\n]*\]\(([^()\n]*)\)")
    targets = pattern.findall(body)
    if len(targets) > MAX_REFERENCES:
        raise CheckError("reference_count_limit", path=path)
    if "](" in pattern.sub("", body):
        raise CheckError("malformed_markdown_link", path=path)
    return targets


def check_manifest(files, report):
    if "manifest.sha256" not in files:
        return
    source = decode(files["manifest.sha256"], "manifest.sha256")
    manifest = {}
    if not source.endswith("\n"):
        raise CheckError("incomplete_manifest", path="manifest.sha256")
    for line in source.splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
        if not match:
            raise CheckError("malformed_manifest", path="manifest.sha256")
        digest, path = match.groups()
        safe_path(path)
        if path == "manifest.sha256" or path in manifest:
            raise CheckError("duplicate_or_self_manifest_entry", path="manifest.sha256")
        if secret_name(path):
            raise CheckError("prohibited_manifest_reference", path="manifest.sha256")
        manifest[path] = digest
    actual = set(files) - {"manifest.sha256"}
    for path in sorted(actual - set(manifest)):
        finding(report, "unmanifested_file", path=path)
    for path in sorted(set(manifest) - actual):
        finding(report, "manifest_file_missing", "missing", path)
    for path in sorted(actual & set(manifest)):
        if hashlib.sha256(files[path]).hexdigest() != manifest[path]:
            finding(report, "hash_mismatch", path=path)


def check_links(files, report):
    for path, data in files.items():
        if not path.endswith(".md"):
            continue
        try:
            for reference in markdown_targets(decode(data, path), path):
                target = target_path(path, reference)
                if target not in files:
                    finding(report, "linked_file_missing", "missing", path)
                elif "#" in reference:
                    finding(report, "fragment_not_verified", "unknown", path)
        except CheckError as error:
            add_finding(report, error.finding)


def check_structured(files, report, run_id):
    documents = {}
    for path, data in files.items():
        if path.endswith(".json"):
            try:
                documents[path] = strict_json(data, path)
            except CheckError as error:
                add_finding(report, error.finding)
    report["json_files"] = len(documents)
    for path, obj in documents.items():
        if isinstance(obj, dict) and "run_id" in obj and obj["run_id"] != run_id:
            finding(report, "run_id_mismatch", path=path)
    prereg = documents.get("inputs/preregistration.json")
    planned = None
    if "inputs/preregistration.json" in documents:
        if not isinstance(prereg, dict) or prereg.get("run_id") != run_id:
            finding(report, "malformed_preregistration", path="inputs/preregistration.json")
        else:
            if "planned_attempts" in prereg:
                planned = prereg["planned_attempts"]
                if type(planned) is not int or not 1 <= planned <= MAX_ATTEMPTS:
                    finding(report, "invalid_planned_attempts", path="inputs/preregistration.json")
                    planned = None
            if "source_sha256" in prereg:
                mapping = prereg["source_sha256"]
                if not isinstance(mapping, dict):
                    finding(report, "malformed_source_references", path="inputs/preregistration.json")
                else:
                    try:
                        for path, digest in mapping.items():
                            safe_path(path)  # Syntax only; never read source/private originals.
                            if secret_name(path) or not isinstance(digest, str) or not SHA.fullmatch(digest):
                                raise CheckError("malformed_source_references", path="inputs/preregistration.json")
                    except CheckError as error:
                        add_finding(report, error.finding)
    if planned is not None:
        expected = {"raw/attempt-{:02d}{}".format(n, suffix)
                    for n in range(1, planned + 1)
                    for suffix in (".json", ".envelope.json", ".stderr.txt")}
        actual = {p for p in files if re.fullmatch(r"raw/attempt-[0-9]+(?:\.json|\.envelope\.json|\.stderr\.txt)", p)}
        for path in sorted(expected - actual):
            finding(report, "planned_attempt_file_missing", "missing", path)
        for path in sorted(actual - expected):
            finding(report, "unplanned_attempt_file", path=path)
        for n in range(1, planned + 1):
            path = "raw/attempt-{:02d}.envelope.json".format(n)
            if path in documents:
                envelope = documents[path]
                if not isinstance(envelope, dict) or type(envelope.get("attempt")) is not int or envelope["attempt"] != n:
                    finding(report, "attempt_reference_mismatch", path=path)
    seal = documents.get("raw/seal.json")
    if "raw/seal.json" in documents:
        try:
            if not isinstance(seal, dict) or "review" not in seal:
                raise CheckError("malformed_review_reference", path="raw/seal.json")
            # This legacy field is run-relative, unlike Markdown links.
            safe_path(seal["review"])
            if not seal["review"].startswith("reviews/") or secret_name(seal["review"]):
                raise CheckError("malformed_review_reference", path="raw/seal.json")
            if seal["review"] not in files:
                finding(report, "review_file_missing", "missing", "raw/seal.json")
        except CheckError as error:
            add_finding(report, error.finding)
    publication = documents.get("raw/publication.json")
    if "raw/publication.json" in documents:
        try:
            if not isinstance(publication, dict):
                raise CheckError("malformed_publication", path="raw/publication.json")
            references = [("inputs/expect-host.json", publication.get("expectation_published_sha256"))]
            attempts = publication.get("attempts")
            if not isinstance(attempts, list) or not 1 <= len(attempts) <= MAX_ATTEMPTS:
                raise CheckError("malformed_publication", path="raw/publication.json")
            seen = set()
            for attempt in attempts:
                number = attempt.get("attempt") if isinstance(attempt, dict) else None
                if type(number) is not int or not 1 <= number <= MAX_ATTEMPTS or number in seen:
                    raise CheckError("duplicate_or_invalid_publication_attempt", path="raw/publication.json")
                seen.add(number)
                references.append(("raw/attempt-{:02d}.json".format(number), attempt.get("published_sanitized_sha256")))
            if planned is not None and seen != set(range(1, planned + 1)):
                finding(report, "publication_attempt_coverage", path="raw/publication.json")
            for target, digest in references:
                if not isinstance(digest, str) or not SHA.fullmatch(digest):
                    raise CheckError("malformed_publication_hash", path="raw/publication.json")
                if target not in files:
                    finding(report, "published_file_missing", "missing", target)
                elif hashlib.sha256(files[target]).hexdigest() != digest:
                    finding(report, "publication_hash_mismatch", path=target)
        except CheckError as error:
            add_finding(report, error.finding)


def check_run(files, report, run_id):
    report["files"] = len(files)
    report["bytes"] = sum(len(value) for value in files.values())
    for path in REQUIRED:
        if path not in files:
            finding(report, "required_file_missing", "missing", path)
        elif not files[path]:
            finding(report, "required_file_empty", "missing", path)
    if not any(p.startswith("raw/") for p in files):
        finding(report, "raw_evidence_missing", "missing")
    if not any(p.startswith("reviews/") and p.endswith(".md") for p in files):
        # GUIDE requires review at closure. Presence alone never proves authority.
        finding(report, "review_evidence_missing", "missing")
    for operation in (check_manifest, check_links):
        try:
            operation(files, report)
        except CheckError as error:
            add_finding(report, error.finding)
    check_structured(files, report, run_id)


def check_index(data, runs, available):
    source = decode(data, "spikes.md")
    heading = None
    fenced = False
    counts = {selection: 0 for selection in runs}
    record_count = 0
    reference_count = 0
    for number, line in enumerate(source.splitlines(), 1):
        if line.lstrip().startswith(("```", "~~~")):
            fenced = not fenced
            continue
        if fenced:
            continue
        match = re.match(r"## (S(?:[0-8]|3b))\b", line)
        if match:
            heading = match.group(1).lower()
        if not line.startswith("|"):
            continue
        # Only selected rows are in scope. Other runs are neither opened nor ranked.
        selected = [key for key in runs if key.split("/")[1] in line]
        if not selected:
            continue
        record_count += len(selected)
        if record_count > MAX_REFERENCES:
            raise CheckError("index_record_limit", path="spikes.md")
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        for selection in selected:
            report = runs[selection]
            gate, run_id = selection.split("/")
            if len(cells) != 6:
                finding(report, "malformed_index_row", path="spikes.md")
                continue
            # A new run may link an older run. That does not create another
            # primary declaration for the old run or assign it the new verdict.
            declared_id = cells[0].split(" / ")[-1]
            record_type = cells[1].split(":", 1)[0].strip()
            if record_type not in ("běh", "review", "oprava", "závěr konfigurace"):
                finding(report, "unknown_index_record_type", "unknown", "spikes.md")
            is_run_row = record_type == "běh"
            primary = is_run_row and declared_id == run_id
            if is_run_row and not primary:
                continue
            if heading != gate:
                finding(report, "index_gate_mismatch", path="spikes.md")
            if primary:
                counts[selection] += 1
            verdicts = re.findall(r"(?<!\w)(?:Prošlo|Neprošlo|Nejasné|Neověřeno)(?!\w)", cells[4])
            if len(verdicts) != 1:
                finding(report, "unknown_or_ambiguous_index_verdict", "unknown", "spikes.md")
            report["index_records"].append({"line": number, "primary_run": primary,
                                            "declared_verdict": verdicts[0] if len(verdicts) == 1 else "unknown"})
            try:
                targets = markdown_targets(cells[5], "spikes.md")
                reference_count += len(targets)
                if reference_count > MAX_REFERENCES:
                    raise CheckError("index_reference_limit", path="spikes.md")
                expected_prefix = "evidence/" + selection + "/"
                linked = False
                for target in targets:
                    safe_path(target)
                    if not target.startswith("evidence/"):
                        raise CheckError("unsupported_index_reference", "unknown", "spikes.md")
                    parts = target.split("/")
                    if len(parts) < 4:
                        raise CheckError("malformed_index_reference", path="spikes.md")
                    canonical_selection("/".join(parts[1:3]))
                    if target.startswith(expected_prefix):
                        linked = True
                        local = target[len(expected_prefix):]
                        if local not in available.get(selection, set()):
                            finding(report, "index_target_missing", "missing", "spikes.md")
                if not linked:
                    finding(report, "index_run_reference_missing", "missing", "spikes.md")
            except CheckError as error:
                add_finding(report, error.finding)
    for selection, report in runs.items():
        if counts[selection] == 0:
            finding(report, "index_run_missing", "missing", "spikes.md")
        elif counts[selection] > 1:
            finding(report, "duplicate_index_run", path="spikes.md")
        if len({r["declared_verdict"] for r in report["index_records"]}) > 1:
            finding(report, "conflicting_index_claims_require_review", "unknown", "spikes.md")


def validate(root, selections, index=None):
    """Return a bounded JSON-compatible report; no writes and no content output."""
    report = {"schema": "lab-evidence-report-v1", "structural_status": "unknown",
              "acceptance": "unverified", "findings": [], "runs": [],
              "unverified_checks": list(UNVERIFIED),
              "limits": {"runs": MAX_RUNS, "entries": MAX_ENTRIES, "depth": MAX_DEPTH,
                         "file_bytes": MAX_FILE_BYTES, "total_bytes": MAX_TOTAL_BYTES},
              "read_safety": "POSIX no-follow, pinned descriptors, metadata recheck; no atomic snapshot"}
    if index is None:
        report["unverified_checks"].append("index membership (no explicit --index)")
    if not supported():
        finding(report, "unsupported_read_safety_platform", "unknown")
        return report
    try:
        if not selections or len(selections) > MAX_RUNS:
            raise CheckError("selection_count_limit")
        ids = set()
        for selection in selections:
            _, run_id = canonical_selection(selection)
            if run_id.casefold() in ids:
                raise CheckError("duplicate_selected_run_id")
            ids.add(run_id.casefold())
        with Reader() as reader:
            root_fd = reader.absolute_directory(root)
            boundary = os.fstat(root_fd).st_dev
            snapshots, available = [], {}
            index_snapshot = None
            for selection in selections:
                run = {"selection": selection, "structural_status": "unknown", "acceptance": "unverified",
                       "files": 0, "bytes": 0, "json_files": 0, "index_records": [], "findings": []}
                report["runs"].append(run)
                try:
                    gate, run_id = selection.split("/")
                    gate_fd = reader.directory(root_fd, gate, boundary)
                    run_fd = reader.directory(gate_fd, run_id, boundary)
                    files, metadata = reader.snapshot(run_fd)
                    snapshots.append((run_fd, metadata, run))
                    available[selection] = set(files)
                    check_run(files, run, run_id)
                except CheckError as error:
                    add_finding(run, error.finding)
                except FileNotFoundError:
                    finding(run, "selected_path_missing", "missing")
                except OSError:
                    finding(run, "read_or_metadata_error", "unknown")
                run["structural_status"] = status_of(run["findings"])
            if index is not None:
                # A single explicit file is the sole exception to the evidence root;
                # its parent is pinned, never scanned, and links never open targets.
                parent, separator, name = index.rpartition("/")
                if not separator or name != "spikes.md":
                    raise CheckError("explicit_spikes_index_required")
                parent_fd = reader.absolute_directory(parent)
                initial = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
                data = reader.read_file(parent_fd, name, initial, "spikes.md")
                check_index(data, {r["selection"]: r for r in report["runs"]}, available)
                index_snapshot = parent_fd, name, signature(initial)
            for fd, metadata, run in snapshots:
                try:
                    _, final = reader.snapshot(fd, read=False)
                    if metadata != final:
                        raise CheckError("concurrent_change")
                except CheckError as error:
                    add_finding(run, error.finding)
                except OSError:
                    finding(run, "read_or_metadata_error", "unknown")
            if index_snapshot is not None:
                parent_fd, name, initial = index_snapshot
                if initial != signature(os.stat(name, dir_fd=parent_fd, follow_symlinks=False)):
                    raise CheckError("concurrent_index_change")
            reader.check_anchors()
    except CheckError as error:
        add_finding(report, error.finding)
    except FileNotFoundError:
        finding(report, "selected_path_missing", "missing")
    except OSError:
        finding(report, "read_or_metadata_error", "unknown")
    for run in report["runs"]:
        run["structural_status"] = status_of(run["findings"])
    report["structural_status"] = status_of(report["findings"] + [f for r in report["runs"] for f in r["findings"]])
    return report
