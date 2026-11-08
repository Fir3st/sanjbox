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
