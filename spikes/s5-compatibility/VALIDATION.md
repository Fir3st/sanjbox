# D6 development validation — 2026-11-04

**9 unittest tests passed**, including **28 negative matrix mutation cases**. Validation accepted
25 profiles / 50 rows / 52 source records. Baseline counts: 2 `fixture_only`, 3 `untested`,
45 `unsupported` (including all 25 passthrough rows). Proposed D5 is separate: pip/Git local fixture
observations, uv untested, Homebrew unsupported. S5/GW-19 and live integrations remain unverified.

## Environment and exact commands

- macOS 27.2 (26B123), arm64.
- Existing native `/usr/bin/python3`: **Python 3.9.6**; standard library only.
- Baseline `afae1ca7dfe78f03d5006c42b6b01093772eba0c`; D6 claim `3ebefd7`.
- Read-only D5 review pinned to `9ddb62e2efde534d7057a1ce01aa9bd942156ee8`, including `ca4e50d`.
- Cwd for validation: the isolated D6 repository root. `-I` ignores Python environment/user site;
  `-B` suppresses bytecode caches.

Commands actually run from the repository root:

```sh
/usr/bin/python3 -I -B spikes/s5-compatibility/matrix.py validate
/usr/bin/python3 -I -B spikes/s5-compatibility/matrix.py report > spikes/s5-compatibility/REPORT.md
/usr/bin/python3 -I -B spikes/s5-compatibility/tests.py
git diff --check
```

The final test run completed **9/9 in 0.510 seconds**, exit 0. Test names and assertions are in
[tests.py](tests.py); all 28 mutations in [invalid-cases.json](fixtures/invalid-cases.json) rejected
for their declared reason. CLI tests additionally run `validate`, `report --format json` and a
failing `report --matrix <own-invalid-fixture>` from a fresh empty directory with the same isolated
Python, with a 10-second subprocess limit. JSON report round-trips exactly; Markdown matches
[REPORT.md](REPORT.md) byte for byte. Invalid input returns 2 and emits no successful report.

The first matrix validation caught duplicate citation IDs in generated claim lists; those were
removed before the first unittest run. No failing assertion was weakened or skipped. The subsequent
report/source review made the RubyGems CA setting explicit and regenerated the report; the final
suite passed as above. Official web pages were read through the browsing tool, not executed or
installed. No web snapshot/archive is retained.

## Independent D5 read-only review

Reviewed D5 versus baseline before implementing D6, without editing or executing D5. No blocking
finding was identified in the inspected code or fixture scope:

- PyPI: per-file time/filename/project/hash/size identity, fresh metadata before and after bytes,
  direct-request authorization, all redirects denied, no gateway cache, bounded audit and
  cancellation/deadline behavior. Its two metadata reads are not an atomic upstream transaction.
- Git: exact project and smart HTTP v0 operations, default-denied push, client headers/auth rejected,
  no redirects/WWW-Authenticate reflection, bounded opaque request/response packs. Real account
  scopes, object policy and Git-to-gateway HTTPS are not proved by the local fixture.
- Homebrew: fixed diagnostic denial and no artifact release; digest or incidental dates cannot
  establish the missing adopted bottle publication-time contract.
- `ca4e50d`: absolute monotonic checks reject a late successful child result even if the timer is
  scheduled late. Structured cancellation still waits for uncooperative children; this is not a
  hard process deadline.
- Test evidence remains scoped to mock policy tests, a generated-wheel pip download and generated
  Git clone/push on loopback. D5's reported 101 Release tests were **not rerun by D6**.

This review is preparation, not a safety-gate verdict. Sources and test locations are full-commit
links in [sources.json](sources.json). D6 has no runtime dependency on the D5 worktree or source.

## Evidence gaps and cleanup

The tests prove inventory completeness, citation/provenance consistency, rejected schema/status
contradictions, bounded parsing and deterministic reporting. They do **not** prove the contents or
freshness of remote sources, SDK/client interoperability, scoped accounts/revocation, cooldown
across every client path, UID/session/network isolation, real trust provisioning, installations,
or performance ≤1.1×. Those require separate preregistered D7/laboratory evidence.

Tests created only their own temporary directories and removed them via `TemporaryDirectory`;
standalone CLI checks verified their cwd stayed empty. No native builds, package downloads,
certificates, trust changes, `.build`, `__pycache__`, `.pyc`, `.pytest_cache` or third-party caches
were produced. The temporary data-authoring script was deleted after the final authored artifacts
were verified. Only the reviewed JSON, Python, Markdown and small mutation fixtures remain.
No archives were made. No secrets, account stores, Keychain, sudo or system configuration were used.

## Current-decision follow-up — 2026-11-08

Reason: F0.7/C-003 accepted on November 7 after the historical inventory. Measured source commit
`f9e7019bcabb15caaf667e73c29004b7895dd521`; decision source
`740593d8d9e66e719c179572354f634c2ed85457`; reviewed repository source
`7b20c41496f9a8d2a8e49604e31c7598a4943adb`.

On this Mac, both `/usr/bin/python3` **3.9.6** and existing `/opt/homebrew/bin/python3` **3.15.2**
passed `-I -B spikes/s5-compatibility/tests.py` (**9 tests / 28 negative mutations**) and
`-I -B spikes/s5-compatibility/tests_current.py` (**10 tests / 44 negative mutations**): **19 tests
per interpreter**. Both validators passed with `/usr/bin/python3 -I -B`: `matrix.py validate`
retains 25 profiles / 50 rows (2 fixture-only, 3 untested, 45 unsupported); `current_decisions.py
validate` reports 7 entries, 6 accepted but implementation-blocked, 1 unsupported, 0 live-verified,
and 3 C-003 entries where full R3 is not met. `git diff --check` passed.

Tests verify exact regeneration of both reports, current-report stability under reordered JSON,
byte preservation of all six historical artifacts, closed scope/provenance and rejection of
acceptance-to-implementation/live/gate promotion. Temporary directories were automatically removed;
no bytecode caches or offline-proof archives were produced. No clients, network, accounts, secrets,
Keychain, certificates, system settings or privileged operations were used. This is offline
inventory validation; reviewed domain lists, scopes, revocation, live compatibility and all gate
results remain missing/unverified as specified in [CURRENT-DECISIONS.md](CURRENT-DECISIONS.md).
