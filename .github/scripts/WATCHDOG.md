# CI watchdog

`run-with-watchdog.sh SECONDS LOG_DIR COMMAND [ARGS...]` uses `/usr/bin/python3`
(Python 3.9 or newer, stdlib only) and works with macOS Bash 3.2. It runs a CI
command in a new session and process group. A separate anchor stays in that
group after the command root exits. The supervisor keeps the anchor unreaped
until **after its last group signal and snapshot**, so its PID/PGID cannot be
reused by an unrelated process during cleanup. No descendant PID is signalled.

A clean command preserves its exit status (including `128 + signal`); exec
failure returns 126/127. If a command exits with live processes still in its
group, the watchdog reports failure and cleans the group. Exit 0 becomes 125;
an already failing command retains its nonzero status if cleanup is verified.
Timeout returns 124. INT, TERM and HUP return `128 + signal`. Internal or
unverified-cleanup failures return 125, except that timeout/cancellation retain
their explicit statuses. None of these failure paths can return 0.

Cleanup sends TERM and CONT, allows one second for exit, then sends KILL to the
whole owned group. This also covers a stopped root and TERM-ignoring children.
The anchor ignores cancellation while the command retains normal signal
handling. If the supervisor dies, EOF on its private control socket makes the
anchor perform the same TERM/CONT/KILL fallback. If the anchor dies first, the
supervisor still holds its unreaped PID and cleans the group. The command
cannot inherit that control socket or start before the ownership handshake.

All failure diagnostics and cleanup verification share one four-second budget;
reaping the anchor has a further half-second budget. A command-exit check takes
at most 0.55 seconds. The operational upper bound is the requested command limit
plus about six seconds, subject to OS scheduling. A kernel-stuck process cannot
be forced to exit by user-space code; failed verification is reported explicitly.

`hung-processes.txt` contains only numeric PID, PGID and state metadata from the
owned scope. Each snapshot is capped at 64 KiB and at most 0.5 seconds of
collection, reserving time to reap its own `ps` helper. Darwin `ps -g` selects the
owned process group; Linux `ps -s` selects the owned session. No global process
listing, recursive traversal or sequential per-process stack sampling is used.
A numeric descendant PID is insufficient to safely sample a process that could
exit and have its PID reused. Zombies count as terminated, not running children.

This is CI lifecycle hygiene, **not a security boundary**. Supported commands
and descendants must retain the inherited process group and session. A process
that deliberately uses `setsid` or `setpgid`, double failure of both supervisor
and anchor, or an uninterruptible kernel task is outside the cleanup guarantee.
Linux detects a different group still in the owned session and fails verification;
Darwin's group-only query cannot identify an escaped group. Neither platform
claims success as proof that deliberately detached descendants do not exist.

## Validation

The regression fixtures create only their own temporary files and processes,
use independent 12-second alarms, and require EOF on a pipe inherited by the
child as proof it stopped. Tests cover clean exit 0/nonzero/signal, exec errors,
a root exiting with a pipe-blocked child, timeout and KILL escalation, INT/TERM/
HUP, root-exit cancellation races, anchor death, supervisor death, unrelated
process survival, invalid limits, failed verification and diagnostic size/time
budgets. CI runs them in `tools/tests` on Ubuntu/Python 3.11 and separately with
`/usr/bin/python3` on `xcode-27`.

Local commands (offline fixtures, not a laboratory gate):

```sh
/bin/bash -n .github/scripts/run-with-watchdog.sh
/usr/bin/python3 -B -W error::ResourceWarning -m unittest discover -s tools/tests -v
python3 -B -W error::ResourceWarning -m unittest discover -s tools/tests -v
```

On 2026-11-08, executable source/tests at commit
`0358eebee80379fc2905fb46652c5b51a66272b4` passed Bash syntax validation and
**77/77 tools tests**, including all **14 watchdog tests**, on both system Python
3.9.6 and Python 3.15.2 (macOS 27.2 / build 26B123, arm64, Bash 3.2.57).
No resource warnings were emitted. An initial full-suite invocation with `-I`
failed to import the preexisting evidence-tool tests; the commands above match
CI's repository import mode. The dedicated watchdog-only CI step uses `-I`.
Linux/Python 3.11 and the hosted `xcode-27` image remain CI validation, not a local
measurement. This document and the workflow's diagnostic comment were then
updated without changing the tested executable code.
