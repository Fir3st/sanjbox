# WP0.5 — read-only LAB evidence validator

Inspect explicitly selected **sanitized published runs** using only Python's standard
library (Python 3.9+, POSIX macOS/Linux). The tool emits text or JSON to stdout and
never creates, changes, seals, repairs, or removes evidence. It does not execute
probes, follow network links, change COVERAGE, or close a laboratory gate.

From the repository root, this exact command checks the existing diagnostic M1 run:

```sh
python3 -B -m tools.lab_evidence \
  --root "$PWD/docs/evidence" \
  --run s1/20261103T134131Z-janfiedler-LAB-janfiedler-01-r1-a8a26eeb \
  --index "$PWD/docs/spikes.md" \
  --format json
```

Use `--format text` for a short report. Repeat `--run gate/run-id` for independent
runs under the same explicit evidence root. No default root or recursive discovery
of other runs exists. `--index` is optional and accepts an explicit absolute path
whose basename is `spikes.md`; its parent directory is never enumerated. It does
not have to be the repository's current index, so the report does not authenticate
that document. Do not use `-I -m tools.lab_evidence`: isolated Python mode removes
the repository from the module search path. `-B` prevents Python bytecode caches.

Only select sanitized lab evidence or synthetic fixtures, never a home directory,
a credential store, a live database, or an unreviewed export. The documented
run-root `credentials.log` is **probe identity metadata**, not a login secret. It
is hashed but its contents are never printed or interpreted as proof of identity.
The filename filter below is defense in depth; it cannot recognize secrets hidden
under innocent names and is not a publication/privacy review.

## Report and exit status

`structural_status` is one of:

| Value | Meaning |
|---|---|
| `consistent` | All supported structural checks completed without findings. |
| `missing` | Required evidence, a selected run, or a referenced file is absent/empty. |
| `failed` | A structural contradiction, malformed input, unsafe object, hash mismatch, or resource limit was detected. |
| `unknown` | Access/metadata errors or unsupported syntax/platform prevent a structural conclusion. |

When several findings occur, `failed` takes precedence over `unknown`, then
`missing`; individual findings remain in the report. These are **validator states**,
not measured outcomes. `acceptance` is always `unverified`, including when a run
or its index claims `Prošlo` or `Neprošlo`. Exit **0** means structural consistency
only; **1** means incomplete/failed/unknown validation; **2** is an argparse usage
error. Never use exit 0 as an acceptance or deployment gate.

Each selected run retains its own result and every selected index record's line
number and declared verdict. There is no latest-wins rule, averaged outcome, or
cross-machine success. Index claims are not verified scientific results. The tool
cannot infer configuration equivalence from prose; contradictory configurations
require human review under [LAB §3](../../docs/LAB.md#3-předregistrace-a-platnost-důkazu).
The existing M1 example must remain **partial host diagnostics / S1 Neověřeno**.

## Checks implemented

- Run-root `environment.md`, `inputs.md`, `credentials.log`, `verdict.md`, and
  `manifest.sha256` must be nonempty; at least one file under `raw/` and one Markdown
  record under `reviews/` must exist. Presence does not validate their claims.
  `state/` is not required in a sanitized publication: it may contain private data.
- Manifest lines are exactly `lowercase-sha256`, two spaces, canonical relative
  path, LF. No comments, escaping, CRLF, duplicates, self-entry or missing final LF.
  Every regular file except the manifest itself must appear exactly once and match
  its current SHA-256. Extra files and missing entries are errors, including new
  reviews/amendments. **Do not rewrite a closed run's manifest to satisfy this tool.**
  An append-only amendment outside the original manifest remains an explicit
  coverage gap; this tool introduces no amendment/sealing protocol or backfill.
- Selection is exactly a lowercase documented gate (`s0`–`s8`, `s3b`) plus a run ID.
  The ID has a real UTC calendar timestamp `YYYYMMDDTHHMMSSZ`, at least three
  nonempty ASCII alphanumeric segments for alias/machine/revision, optional further
  hyphen-separated segments, and eight final hexadecimal characters. Revisions
  are not restricted to `rN`; original case and IDs are preserved. Case-insensitive
  duplicate IDs across selected runs/gates are rejected for filesystem portability.
  Hyphenated labels cannot be unambiguously split into identities; no author or
  machine binding is inferred. Uniqueness is only checked in the selected set.
- Markdown inline links `[label](relative-file)` must name files inside the same
  selected run. Minimal leading `../` from nested review/amendment documents is
  supported only while staying within that run. Absolute paths, URLs, encoded
  paths, interior `..`, `./`, backslashes, whitespace, query strings, and ambiguous
  paths are rejected. Reference-style/HTML links and heading fragments are
  unsupported/unknown, never fetched. Fenced code and inline code are excluded.
  This is a limited dialect, not a full Markdown semantic validator; shortcut links
  and prose/code path mentions are not attested.
- Every `.json` file is parsed with duplicate-key, finite-number, depth, size and
  node bounds. A present top-level `run_id` must match its directory. Arbitrary JSON
  schemas receive syntax checks only. `.jsonl`/logs are hashed, not interpreted.
- Limited existing M1 JSON conventions are checked when present: preregistration
  `run_id`, `planned_attempts` (1–100), source-reference/hash syntax; the corresponding
  `attempt-NN.json`, `.envelope.json`, `.stderr.txt` membership and envelope numbers;
  `raw/seal.json`'s run-relative `reviews/` target; `raw/publication.json`'s unique
  attempt numbers and **published** expectation/attempt hashes. Null or malformed
  known objects fail. This does not attest measurements or private-original hashes.
  Source paths are syntax-checked, never opened outside the evidence root.
- Optional index checks inspect selected six-column rows under the matching gate,
  require one primary `běh` row per selected run, retain subsequent reviews, reject
  duplicate primary declarations and malformed/absent local targets, and surface
  ambiguous/contradictory declared verdicts. References to unselected runs are only
  syntax-checked; their existence/content/uniqueness is not verified. A new run's
  link to an older run does not assign the newer verdict to the older run.

Current hash equality cannot establish historical immutability, before-measurement
preregistration, provenance authority, authentic review, calibration, valid probe
identity, complete oracle coverage, concurrency, or acceptance statistics. These
limitations are listed explicitly in every report. F0.8, thresholds, methodology,
old reviews, and previous authors' outcomes remain unchanged.

## Read boundary and fixed limits

The absolute root and optional index parent are opened component by component
with `O_DIRECTORY | O_NOFOLLOW`; symlink components are rejected, never resolved.
On macOS use the real explicit `/private/tmp/...` path for your own scratch rather
than the `/tmp` symlink. `.`/`..`, empty path components and root `/` are rejected.
Only the named gate/run subtrees are enumerated. Reads use pinned directory file
descriptors, `stat(..., follow_symlinks=False)`, and `O_NOFOLLOW | O_NONBLOCK`.
Regular-file type, single link count, device, inode, mode, UID/GID, size, mtime and
ctime are checked before/after reads. A bounded second metadata walk and ancestor
identity checks detect observed concurrent replacement/change. Reads can update
filesystem access times; the validator makes no explicit metadata writes.

Symlinks, hardlinked files, FIFO/socket/device objects, device crossings below
the root, and case-alias filenames fail. Files/directories have ASCII alphanumeric
names with dots/underscores/hyphens; hidden names, names containing `secret`, `token`,
`credential`, `key`, or `cert`, and common certificate/database extensions are
rejected before content reads (except exact run-root `credentials.log`). These
conservative exclusions intentionally report unsupported evidence rather than read
possibly private material. Reports omit file contents, hash values, absolute
paths, OS error messages and rejected unsafe filenames.

| Bound | Maximum |
|---|---:|
| Selected runs | 16 |
| Entries (files and directories, all selected runs together) | 512 |
| Subdirectory depth below a run | 8 |
| File bytes | 8 MiB |
| Total bytes, including optional index | 64 MiB |
| JSON / Markdown / manifest / index text | 1 MiB each |
| JSON nesting / nodes | 32 / 50,000 |
| Inline references per document / selected index records | 512 / 512 |
| Findings per report/run | 256 + explicit limit finding |
| Absolute root/parent components | 64 |

A missing required POSIX capability or unsupported OS produces `unknown`; no
Darwin-only flag is silently treated as a Linux guarantee. There is no atomic
filesystem snapshot or defense against a privileged actor restoring invisible
state; same-device bind mounts are not distinguished by `st_dev`. Changes after the final check are outside the observation window. Use
quiescent sanitized evidence, and retain independent version history/review for
historical claims. No current-hash result is an authority signature.

## Validation

Run from the repository root:

```sh
python3 -B -m unittest discover -s tools/tests -v
```

The synthetic tests cover manifest coverage/tampering, safe relative references,
duplicate/malformed/deep JSON, multi-author/machine histories, unsupported states,
symlink/hardlink/FIFO rejection, resource limits, permission failures, deterministic
file/directory/index replacement, unchanged bytes, CLI output and exit codes.
They use unique temporary directories and remove only their own fixtures. Linux
Python 3.11 CI already discovers `tools/tests`; no dependency or CI change is needed.

## Validation history

- Initial implementation `3f94c0966fc73fbfce5b5f5230bb3b08e107f685`: **56/56** tool
  tests passed on macOS Python 3.9.6, no skips. The documented M1 CLI reported
  21 files / 29,230 bytes / 12 JSON files, structural consistency, declared S1
  `Neověřeno` and acceptance `unverified`.
- 2026-11-05, review fixes: manifests split only on literal LF and reject control
  or Unicode line separators, including otherwise correct manifests that retain
  their final LF. Gate context ends at unrelated H1/H2 headings; nested H3–H6
  headings retain the current section. Only recognized level-two ATX gate headings
  establish/reopen it. Setext H1/H2 headings end it without establishing a gate;
  standalone thematic breaks and fenced heading examples do not end it. Primary
  rows outside their gate remain reported but cannot satisfy index membership.
  Added five regression tests, including CLI failure and preserved original bytes.
  The full suite passed **61/61** on macOS Python 3.9.6, no skips; the exact
  documented M1 JSON command still reported 21 files / 29,230 bytes / 12 JSON,
  `Neověřeno` and `unverified`. Prior evidence, manifests, reviews and the index
  were unchanged. Unique temporary fixtures were cleaned; no bytecode/build
  artifacts were created. The limited Markdown dialect and scientific/provenance
  limitations above remain unchanged; Linux verification belongs to existing CI.
