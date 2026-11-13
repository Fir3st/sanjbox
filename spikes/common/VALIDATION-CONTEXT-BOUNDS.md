# WP0.3 — bounded launchctl collection (2026-11-08)

Source tested: `826b07812c3e1e70bf3d72f5fcb90ee6a243b9c2`.
Configuration: macOS 27.2 (26B123), arm64, Apple Swift 6.4.2
(`swiftlang-6.4.2.1.9`, clang `2100.4.1.1`). Offline preparation; no gate verdict.

- `swift test --package-path spikes/common --scratch-path <own-temporary-build>`: **53 passed**.
- Same command with `-c release`: **53 passed**.
- Each configuration: 39 ProbeKit tests (21 new), 7 Counterpart tests and 7 Provenance XCTest cases;
  zero failures. Normal suite includes existing controlled loopback tests.
- New deterministic I/O tests exercise the actual collector state machine: EOF before exit,
  exit before inherited-writer EOF, exact output cap/overflow, nonzero/signalled exit, read failure,
  repeated EINTR/retry, loss of wait ownership, TERM/KILL escalation and exhausted cleanup windows.
  Reads/reaps observed exactly at or after the deadline cannot return success.
- Actual fixed `/bin/cat` fixture returns its synthetic input and is reaped; holding its input open
  reaches the 2 s timeout and reaps in approximately 2.21 s in both builds. Exact-child
  `waitpid(..., WNOHANG)` then returns `ECHILD`; tests never signal a previously reaped PID.
- Both built `sanjbox-whoami` binaries reported manager name/UID equal to independently invoked
  fixed `/bin/launchctl managername` and `manageruid` in the calling context. Both returned unknown
  manager when a newly owned subprocess inherited `SIGCHLD=SIG_IGN` (no host signal changes).
- Parsing tests preserve open-ended manager names and reject malformed UTF-8, embedded controls,
  empty replies, nondecimal/overflowing UIDs and failed queries. Public Codable models, expectations,
  and the Darwin `getgroups` implementation are unchanged; no extended-group oracle was substituted.

Limits and embedding contract:

- Each fixed query admits at most 8192 B stdout and uses a 2 s monotonic budget after spawn, followed
  on failure by at most 200 ms TERM and 200 ms KILL polling windows. Stderr/stdin use `/dev/null`;
  children receive a fixed minimal environment and only their intended descriptors. No public
  executable, arguments, environment or PID inputs exist; the fixed echo fixture is internal only.
- Default `SIGCHLD` without `SA_NOCLDWAIT` is required and checked before spawn and before signals.
  Custom/ignored dispositions fail closed. Embedding callers must not change that disposition or
  run a competing reaper during capture. Successful exact-child reap or lost ownership forbids any
  later signal. A still-unreaped child pins its PID under this exclusive-reaper contract.
- Cleanup deadline/ownership failure returns unknown, never success. If the OS cannot complete reap
  after SIGKILL within the cleanup window, eventual reap is **not guaranteed**; there is no blocking
  wait or detached retry worker. Only the direct child is owned; descendants are never targeted.
- Setup/spawn, OS scheduling/suspension, `getpwuid`, membership and CoreGraphics calls are not given
  hard wall-clock limits. `capture()` remains synchronous and does not cooperate with Swift Task
  cancellation. This change makes no hard deadline claim for total context capture or any lab gate.


## Independent native review (2026-11-13)

Original production source reviewed and tested: `a77802876f50fee0477054f115355aa5b8b63736`.
Configuration: macOS 27.2.1 (26B131), arm64, Xcode 27.2 (27B52), Apple Swift 6.4.2.
No actionable production defect was found in exact-child ownership, nonblocking I/O,
output/deadline bounds, spawn setup, or the documented SIGCHLD preconditions.

- Common suite: **53 tests passed in Debug and Release**; tools: **63 tests passed**.
- Added [isolated native audit](Tests/context_child_native_audit.swift): **18 scenarios passed**
  with both unoptimized and `-O` builds. Each mode runs in its own disposable process, so closing
  descriptors, setting an fd limit or changing signal disposition never affects the test runner.
- The audit covers 32 repeated captures without fd drift; exact child fd inventory `[0, 1, 2]`
  despite a borrowed non-CLOEXEC fd; all seven combinations of closed standard descriptors;
  ignored/custom SIGCHLD and `SA_NOCLDWAIT` refusal before spawn; blocked SIGCHLD; blocked/ignored
  SIGTERM requiring escalation; preservation of a separate direct child's wait status; and ten
  descriptor-exhaustion setup points, including failed low-fd relocation. Exact-child `ECHILD`
  checks follow every successful or timed-out echo; parent descriptor inventories remain unchanged.

To repeat from `spikes/common`, compile the three files named in the audit header, then run
its binary separately with each mode: `repeat`, `child-descriptors`, `closed-1` through `closed-7`,
`ignored-chld`, `custom-chld`, `no-cldwait`, `blocked-chld`, `blocked-term`, `ignored-term`,
`unrelated-child`, `exhaustion`, `exhaustion-closed`. Repeat compilation with `-O` for optimized code.
These are local implementation checks, not lab or gate evidence.


## Integrated review after PR #66 (2026-11-13)

Tested source: `cf8ed23de58eb627d0b686aade50e0eb4646dbd7`, integrating main
`b5e6bf1bba259ea34b8620cb06747b64aa626c4b`. Same native configuration as above.
The integration preserves the whoami outcome/schema changes and both validation histories;
`ContextChild.swift` and `ProbeContext.swift` match the originally reviewed production source.

- `swift test --package-path spikes/common --scratch-path <isolated-build> --configuration debug`
  and the corresponding `release` command each passed **95/95 tests**: 39 ProbeKit tests,
  4 whoami CLI XCTest cases, 7 Provenance XCTest cases, and 45 Counterpart tests.
- The isolated native audit passed **18/18 scenarios in each build mode**, including all ten
  descriptor-exhaustion points. Each invocation had an external 10 s harness deadline.
- Both newly built whoami binaries matched independently invoked fixed launchctl name/UID queries;
  under inherited `SIGCHLD=SIG_IGN`, both reported an unknown manager without errors. Diagnostic
  `valid` remained absent and `mismatches` empty in all four CLI checks.
- `python3 -m unittest discover -s tools/tests -v`: **63/63 passed**.
- `git diff --check` passed. Only the WP0.3 row differs in COVERAGE from integrated main; all
  requirement, gate, acceptance and other package states are unchanged. No historical evidence
  or source from the preceding whoami review was altered; no additional production finding.

The following validation-note commit changes only this document and the WP0.3 coverage summary.
