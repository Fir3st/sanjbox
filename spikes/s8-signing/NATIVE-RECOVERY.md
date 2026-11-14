# WP1.A6 — native registration recovery continuation

Base `main` `7b8294e4fd28a3e62f4998baf39d3da1fd904ccb`, branch
`codex/wp1-a6-native-recovery`, 2026-11-14; published claim `53bb52a`.
Original authors/owners **janfiedler / Codex + Astra** are preserved. The continuing
Astra implementer has an explicit user handoff; prior #77 evidence is unchanged.

**Concrete advance:** the actual `S8ServiceHost` mutation path now commits a persistent
intent/result journal and binds the complete signed app inventory. The previous native
host retained registration provenance only in memory and wrote observations under `/private/tmp`.
This is native filesystem code used before/after the real ServiceManagement call sites,
not another simulated workflow. **It does not establish registration continuity across
restart, restore unregister authority, authorize artifact deletion, or close A6/S8.**

## Native application binding and persistent records

After the existing independently supplied identity expectation and user action, the host:

1. Checks its sealed run UUID, bundle identity, non-root real/effective UID/GID, non-ad-hoc
   signature, hardened runtime and empty entitlements. It validates all four nested signing
   targets with strict/all-architectures/no-network Security checks. Bare helper executable
   signing identifiers need not equal their launchd labels; the two bundle IDs are fixed.
2. Inventories the actual app twice around the signature checks. Each relative entry binds
   device/inode, UID/GID, mode/flags and file SHA-256/size. Every component uses directory fds
   and `O_NOFOLLOW`; extended ACL, symlink, hardlink, special file, writable/privileged mode,
   changed inode/content or unknown metadata refuses. Reads are bounded to 256 entries,
   12 directory levels, 64 MiB per file and 256 MiB total. This new native signed-app inventory
   is independent of the Python `signed-inventory.json`; neither is registration authority.
3. Opens the fixed current account location, derived from `getpwuid(geteuid())`:

   ```text
   ~/Library/Application Support/org.sanjbox.s8.fixture-registration/<SEALED_RUN_UUID>/
   ```

   The application-support parent must already exist, be owned by this UID, have no group/world
   write, flags or extended ACL, and have a path without symlinks. Only the application-specific
   container and run directory can be created (`0700`), after the user mutation dialog.
   Read-only recovery creates nothing. There is no alternate state-path argument, home override,
   automatic reset, migration, baseline adoption or recursive cleanup.
4. Holds a nonblocking `flock` on the run directory inode for the lifetime of the native host's
   journal object. All descriptors, including enumeration duplicates, are atomically close-on-exec
   so a concurrent child spawn cannot prolong that lock. A second cooperating process refuses busy. The root identity and linked
   path are checked again on operations. A new `header.json` pins run/app/inventory/owner/root;
   an existing header must match byte for byte, including canonical JSON encoding.
5. Before the service API, creates a new immutable-name intent with `O_EXCL|O_NOFOLLOW` (`0600`),
   then requests `fsync(file)`, `fsync(directory)`, then the final `F_FULLFSYNC(file)` barrier and rereads the record.
   Creation ancestry and record must share the same device, so all preceding parent-directory fsyncs are included in that final barrier.
   The result is a separate record with the same operation UUID and actual API outcome/status.
   Every record binds sequence, previous-record SHA-256, service/action, PID and process start,
   boot time, audit UID/session and the independent expectation's SHA-256. NSError data is
   limited to domain/code; no messages or arbitrary user data are persisted.

Each append revalidates the full sequence, schema, canonical bytes and transition pairing.
The file count is bounded to 64 records; an individual record to 16 KiB and header to 256 KiB.
The first register for a service requires `notRegistered` and no previous operation for that
service in this run. Successful registration may enable unregister **only in the same live
journal instance/process**, with unchanged status and freshly matching app/identity.
The two services are independent, but any interrupted/conflicting operation blocks new run
mutations. Successful unregister remains `process/relaunch oracle still required`, and a new
register cycle requires a new signed run; there is no reuse of a completed service transcript.

The existing temporary observations remain supplementary evidence. If any post-API validation
or write fails, the durable intent remains and the host revokes its in-memory authority. There
is no automatic retry, completion synthesis, rollback, global reset or registration adoption.

## Recovery behavior and cleanup boundary

```text
OWN_APP/Contents/MacOS/S8ServiceHost recovery --expect OWN_EXPECTATION
```

This new command and **Inspect durable recovery** UI button validate identity/signing/current
inventory and inspect only the fixed journal for the sealed run. They do not call even the
ServiceManagement status API. The command accepts no service, PID, state path, `--apply` or
approval switch. A missing journal reports unknown ownership and creates nothing.

| Durable observation | Recovery behavior |
|---|---|
| Complete register intent/result | Reports recorded registration; unregister remains unavailable after reopening |
| Intent without result | Reports interrupted/unknown API outcome; retry and other-service mutations refuse |
| API error, unknown status, or status drift during live cleanup | Conflict; no continuing mutation authority |
| Complete unregister result with status absent | Reports API result only; process exit and no relaunch remain unproved |
| Changed run, app path/inventory, UID/GID, root, ACL/mode/flags, malformed/partial/extra/linked record or broken pairing/hash chain | Refuses and preserves the existing files |

The report always has `mutationAuthorityRestored=false` and `artifactCleanupAllowed=false`.
All post-handoff Python artifact cleanup refusals remain intact. The native journal deliberately
has **no cleanup/delete command**: its evidence may be needed after a crash or failed unregister.
A completed unregister result does not remove the app or its evidence. A future reviewed oracle
must establish ownership continuity, helper exit and no relaunch before providing that cleanup.
Do not start login/reboot/daemon registration experiments on the strength of this journal.

## Limits and exact remaining work

- **Registration generation is absent from the public SMAppService status API.** The identical
  status can follow somebody else's unregister/re-register. This implementation refuses restored
  mutation authority rather than treating matching bytes, UUID, status or a review checkbox as
  proof. Same-live-instance user experiments still require the existing serialized LAB slot;
  same-status external intervention is not detected there either.
- `fsync`/`F_FULLFSYNC` and process-crash tests exercise actual local persistence requests. They
  are not a measured reboot, power-loss or storage-hardware guarantee. A complete-prefix rollback
  cannot be distinguished from an earlier transcript without an independent trusted anchor.
  The user owns these files; a hostile same-UID writer can rewrite or remove an entire journal.
  Hash chaining detects ordinary corruption, not forgery by that UID. There is no claim of
  hostile same-UID TOCTOU protection around path-based Security or ServiceManagement calls.
- The journal lives outside temporary storage, but the existing builder's app still lives in
  `/private/tmp`. Loss/move/re-signing of that app refuses recovery; this continuation does not
  install or migrate it. Real user signatures, account type, persistent app location and native
  signature-check compatibility still require the user. Native tests use explicitly unsigned
  synthetic app bytes and synthetic service outcomes with real filesystem/process APIs.
- **Daemon authorization is not safely completed here.** The fixture is a bounded one-shot
  observer without IPC; there is no OS-supplied connection audit token or independently trusted
  host/admin approval issuer. SDK `SecCode.h` exposes `kSecGuestAttributeAudit` for a future live
  guest check, but a token copied from wire or the UI's own identity would not supply that trust.
  A new privileged endpoint without those pieces would weaken the boundary. The current SDK
  also documents notarization for apps containing LaunchDaemons and separate admin approval
  in System Settings. Compatibility with the project's no-paid-account policy needs explicit
  evidence; it is not inferred from LoginItem/Agent or ad-hoc builds. Daemon mutation stays absent.
- **SG-06 remains blocked by an uncalibrated positive control.** Apple's debugger entitlement
  documentation describes target entitlement restrictions and an admin authorization dialog for
  a non-root debugger. Under the present ban on `get-task-allow`, authorization and system changes,
  that path is not a demonstrated positive control. Self task ports or cooperating `PT_TRACE_ME`
  children use different mechanisms. No attach call, prompt, new runner or blanket impossibility
  claim is made. A future runner needs the same mechanism/caller signing/UID/session for both
  targets plus PID/start binding, deadline and verified termination/reaping.

This continuation satisfies its scoped claim by delivering native durable provenance and
fail-closed recovery inspection. **A6 remains partial**: independent registration continuity and
cleanup through UI/login/reboot, the trusted host/admin path, calibrated SG-06, real signatures
and A7/L2 remain open. The next step is review of this native seam and a concrete ownership/
authorization/control design under user-approved conditions, not a further generic mock PR.
Source observations and hashes: [RESEARCH](RESEARCH.md#native-recovery-feasibility-2026-11-14).
Exact test scope, failures encountered and cleanup: [VALIDATION](VALIDATION.md).
