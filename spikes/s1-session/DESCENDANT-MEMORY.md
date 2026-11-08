# WP1.A2 — bounded descendant memory acquisition

`descendant-memory` adds actual dynamic discovery for GUI-12 diagnostic attribution. It samples
one explicitly registered same-UID test root and discovers later children/grandchildren itself.
The fixed registry in [PROCESS-SERIES.md](PROCESS-SERIES.md), its journal inspector and historical
results retain their original semantics. This mode cannot establish full UID/session attribution
or a GUI-12/P4/S1 pass. System RAM delta remains a separate measurement.

```text
sanjbox-s1-instrument descendant-memory --descendant-json JSON --expect-json JSON [--apply]
```

Synthetic plan example (not a registration for this host):

```json
{"runID":"example-descendant-memory","seconds":600,"root":{"identity":{"pid":42001,"uid":4501,"realUID":4501,"startSeconds":1800000000,"startMicroseconds":12345},"parentPID":42000},"provenanceSHA256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","maxProcesses":16,"maxDepth":4}
```

Register only a controlled test application's root, using the numeric identity and parent PID from
its owned launch. The provenance hash refers to a separately retained operator registration; the
collector does not open or authenticate that artifact. This is not authorization to inventory personal
applications. Expected collector credentials/session are preregistered separately using the existing
[identity schema](INSTRUMENTATION.md). There is no arbitrary command, executable, file path or UID scan.

Dry-run validates inline JSON only. With `--apply`, exact collector credentials/session and own valid
hardened-runtime signature without either get-task-allow entitlement are checked before any target
read. A mismatch records no target observations. Cross-UID root plans are rejected before acquisition.
Root registration is sealed in the create-new `intent.json` before metadata acquisition.

Discovery uses only `proc_listchildpids(knownParentPID)` from the installed macOS SDK. Its return value
is a PID **count**, as in [Apple's libproc implementation](https://github.com/apple-oss-distributions/xnu/blob/main/libsyscall/wrappers/libproc/libproc.c).
The collector checks PID, real/effective UID, BSD start seconds/microseconds and direct parent relation
for the whole recorded ancestry before memory, immediately after memory, and after enumeration.
A candidate is admitted only after checking its direct relation, UID and instance twice, with ancestor
checks around discovery. Failed ancestor checks stop traversal before descendant reads. A reused PID
is never rebound to its old entry. Zombies are unreadable/exited observations, not zero memory.

`proc_pid_rusage(RUSAGE_INFO_V4)` supplies physical footprint and resident bytes as separate diagnostics.
A failed or ambiguous combined observation contains neither metric. No process names, argv, environment,
file contents, process task ports or WindowServer inventory are read. No signals are sent to targets.

Bounds and evidence:

- 1–600 seconds, nominal 1-second ticks, 1–16 total registered/discovered instances including root,
  depth 1–4 below root. Historical instances retain their slots after exit.
- Each child list has `maxProcesses + 1` numeric slots; a filled buffer is explicitly saturated.
  At most `maxProcesses` new candidate identity attempts occur per tick. At the depth/count bound,
  child PID observations remain explicit but no candidate metadata/memory is read.
- A tick has a one-second work budget; the acquisition endpoint has at most one second allowance.
  Actual operation/tick times are retained. Missed ticks are skipped, never fabricated; gaps over
  two seconds and operations over one second are issues. A CLI self-watchdog is duration + 30 seconds.
- Create-new `/private/tmp/sanjbox-a2-<runID>-uid<uid>-descendant-memory/` contains `intent.json`,
  durable `descendants.jsonl` (fsync before the next observation), compact `recording.json` and `report.json`.
  Journal bounds are 180,000 rows, 8 KiB per row and 32 MiB total. Exhaustion/write failure leaves the
  durable prefix and an incomplete recording where final writes succeed. Interruption may leave only
  intent/journal; that is never a complete result. The fixed-registry inspector rejects this format.

Unknown/unreadable, failed memory/enumeration, identity/reparenting changes, capacity/depth/process/
candidate/time limits are separate states. The report contains per-instance distributions of successful
samples and state counts; there is no aggregate footprint sum. `pollingWindowCompleted` states only
that endpoint acquisition finished, with other failures listed separately. Exit 0 requires no observed
issues, exit 3 retains incomplete/failed observations, exit 2 is invalid input/operational failure.
Even exit 0 always has `fullTreeAttributionComplete:false` and `quickProcessesMayBeMissed:true`.

Polling cannot detect every process born and exited between ticks, detached/reparented children lost
before discovery, or transient changes between sequential kernel calls. Before/after checks are not an
atomic kernel snapshot or a security boundary against a hostile fork/reparent race. No whole-UID,
cross-UID, WindowServer/shared-service or full-session claim is made. Do not add footprint, resident,
RSS or their sums to the independently recorded system delta M.

## Reproducible owned native validation

Build with existing local Swift packages only, using a unique scratch directory and explicit native
SwiftPM backend. Run `S1InstrumentationTests` in Debug and Release. After each final build, ad-hoc reseal
the own CLI with hardened runtime and empty entitlements; verify the exact executable before launch.
This uses no signing identity, certificate, Keychain or TCC prompt and proves no S8 identity stability.

```text
python3 spikes/s1-session/Tests/descendant_memory_validation.py \
  --binary /absolute/path/to/signed/sanjbox-s1-instrument \
  --expect-file /absolute/path/to/independently-reviewed-expectation.json \
  --output /private/tmp/unique-new-validation-output --apply
```

The test launches only this same signed binary as an owned root fixture. It registers **only the root**,
starts the normal `descendant-memory` CLI, waits for the first durable poll, then arms the fixture.
The root launches a late child, which launches a grandchild. Each allocates/touches 4/8/12 MiB after
0.6 seconds; child/grandchild exit during the 10-second acquisition. Descendant PIDs are never passed
to the collector. The harness reads the recursive truth protocol only **after collector exit**, then
compares identities, parent relations, allocation/lifetime times, samples and explicit exit states.
It also exercises native wrong-start, exited-root, invalid collector identity and process-count limits;
`--unsafe-binary` optionally tests a separately prepared own non-hardened binary's rejection.

The internal `owned-descendant-fixture` protocol cannot launch caller-selected code. It checks own
credentials/signature, requires parent pipes and current parent PID, has fixed depth/allocation/lifetime,
and a 20-second self-watchdog. Cleanup closes owned pipes and waits boundedly; EOF/parent exit cascades
through the fixture tree. No kill-by-PID can affect a reused or foreign process. Successful fixture truth
includes recursive cleanup completion. This is an acquisition test on the current Mac, not an L1 run.
