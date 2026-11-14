# WP1.A6 — native message-bound code identity

Continuation of merged #82 on `main` `98a80af368bdc941a072a9496ef50f1666dc3211`,
2026-11-14. Owners **janfiedler / Codex + Astra**, with the explicit user handoff to
the continuing Astra implementer, are preserved. Previous evidence is unchanged.

**Delivered slice:** a real, read-only XPC message identity adapter and an owned
anonymous-XPC executable that exercises it through macOS. This replaces no service
policy and enables no operation. It advances the missing OS transport provenance
step toward host authorization. **It does not deliver trusted admin approval.**

## Boundary and code pin

`NativeXPCMessageVerifier` accepts only an actual received XPC dictionary with a
remote connection. `SecCodeCreateWithXPCMessage` selects live code using that
message's OS audit token. `SecCodeCheckValidity` checks a verifier-owned exact
CDHash requirement, with network access disabled. The adapter then checks the
matching code hash, hardened runtime and empty entitlements, including refusal of
either `get-task-allow` spelling even when false, and rechecks live validity.
No PID lookup, private audit-token symbol, payload identity, bundle-path lookup,
UUID, service status, journal, or static signature alone substitutes for this path.

`NativeXPCPeerPolicy` requires an explicit 20-byte code hash and non-root expected
UID/GID/audit session. It is not Codable, has no wire/config loader and cannot
discover or adopt a hash from self, the sender, a path or a journal. The only
requirement it builds is `cdhash H"…"`; callers cannot provide a permissive
requirement expression. **A future production caller still needs an independently
trusted way to provision this policy.** The library does not establish that trust
merely because a caller constructs a policy object.

UID/GID/session checks use public OS connection metadata. The SDK describes these
as values at connection establishment. They are **not** asserted to be fresh
per-message credentials after Mach-right transfer or credential changes. The
code identity itself is bound to each message. This distinction, trusted policy
provisioning, host session classification and independent approval remain required
before any privileged operation can use such an adapter.

The returned observation explicitly has `mutationAuthorized=false`; it is not an
approval capability. Ad-hoc code can satisfy an exact code pin and is reported as
ad-hoc. That proves neither a Personal Team/self-signed identity nor trusted host
authorization. Nothing in `S8ServiceHost`, the daemon, the registration journal,
post-handoff cleanup or the H1 contracts calls this adapter or changes authority.
Daemon mutation remains compiled out, and reopened registration remains unowned.

## Owned native control

`s8-xpc-identity-fixture` is a separate non-service executable, never embedded in
the service app. With no arguments or `plan`, it exits after a dry-run description.
The explicit `--apply-fixture CDHASH UID GID ASID` path first compares its own
real/effective credentials and audit identity to the supplied synthetic test
expectation and requires ad-hoc hardened signing with empty entitlements.

The **external test driver** takes the CDHash from the exact freshly copied and
ad-hoc-sealed fixture before starting it. The fixture does not discover its own
pin. This is an explicitly synthetic verifier policy, not a host trust anchor.
The fixture CLI is not a production policy/approval endpoint.

The fixture creates anonymous listener/client pairs in **one owned process**.
There is no named Mach service, bootstrap registration, launchd plist, socket path,
ServiceManagement call, UI, daemon, child process or persistent endpoint. Each
pair has a three-second wait; a 20-second whole-process alarm bounds a stalled
Security call or queue. Connections/listeners are canceled and their queue drained;
the external driver has a 25-second deadline and reaps this exact process.

The controls use the same real OS message path:

1. Correct pin and connection identity succeed despite contradictory wire claims.
2. Correct native transport requirements on accepted messages and replies succeed.
3. A wrong native reply requirement yields the exact
   `XPC_ERROR_PEER_CODE_SIGNING_REQUIREMENT` object after a verified request.
4. A wrong verifier pin refuses in live `SecCodeCheckValidity`.
5. Wrong expected UID, GID and audit session each refuse, despite matching wire claims.
6. A locally constructed dictionary with fake audit-token data has no OS provenance.

The reply-rejection control sends only synthetic data. Setting a requirement on
received replies is not proof that an outgoing request was withheld from an
untrusted peer; an authorizer must validate the request before acting.

**Limits:** this is genuine XPC/Security execution, not injected mock identity.
It is nevertheless a same-process test: no separate executable, cross-UID/session,
process exit/reuse, credential change, Mach-right transfer or replacement-binary
race is calibrated here. The four Swift unit tests cover malformed policy and
locally constructed XPC objects; they are distinct from the eight native controls.
Neither kind is an SG-08 or S8 acceptance result.

## Repeating the bounded fixture [implementer]

Build this package with the repository's current Swift toolchain and isolated
scratch/cache paths; select `--product s8-xpc-identity-fixture`. Work only with your
own build and a new private temporary root, and preserve any failure output.
Copy that executable into the fresh root before signing it. On that exact copy:

```sh
/usr/bin/plutil -create xml1 "$OWN_XPC_ROOT/empty-entitlements.plist"
/usr/bin/codesign --force --sign - --timestamp=none --options runtime \
  --entitlements "$OWN_XPC_ROOT/empty-entitlements.plist" "$OWN_XPC_ROOT/fixture"
/usr/bin/codesign --verify --strict --all-architectures "$OWN_XPC_ROOT/fixture"
/usr/bin/codesign -dvvv "$OWN_XPC_ROOT/fixture"
```

Take only the reported `CDHash` as the external synthetic verifier pin. Use the
expected current test UID/GID/audit-session values established by the test driver
or own diagnostic expectation, not values from an incoming XPC payload:

```sh
"$OWN_XPC_ROOT/fixture" --apply-fixture "$OWN_FIXTURE_CDHASH" \
  "$EXPECTED_UID" "$EXPECTED_GID" "$EXPECTED_ASID"
```

Do not execute unsealed SwiftPM Debug output: it may contain `get-task-allow`.
No actual signing identity, certificate or Keychain access is needed: `--sign -`
is only ad-hoc sealing of this owned synthetic copy. Sandboxed XPC or own-process
inspection restrictions can invalidate the measurement; a timeout is a failure,
never evidence that code was safely rejected. This fixture requests no prompt
or system-setting change. Remove only your exact owned copies after their process
has exited; it creates no registration state to unregister or recover.

## Public API basis and remaining work

The current Apple SDK declares `SecCodeCreateWithXPCMessage` in `Security/SecCode.h`
with the message audit-token contract; [Apple DTS identifies it as the public
macOS 11 path](https://developer.apple.com/forums/thread/681053).
`xpc/connection.h` declares `xpc_connection_set_peer_code_signing_requirement`
as available from macOS 12 and documents per-message checking. The current
27.2 SDK also imports its exact rejection error into Swift. The package minimum
is macOS 15. No private symbol or custom declaration is used.
[Apple TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements/)
describes exact code-hash requirements; [Applying Code Requirements](https://developer.apple.com/documentation/security/applying-code-requirements)
distinguishes the verifier's policy from signature validity. Header hashes and
the measured environment are recorded in [VALIDATION](VALIDATION.md).

**A6 remains partial.** Next work must supply independently trusted host/admin
policy and approval, real cross-process/session controls, independent registration
continuity and cleanup through UI/login/reboot, and the calibrated SG-06 attach
positive control. Actual signatures and A7/L2 remain the user's work after S1 and
reviewed cleanup. This adapter provides no authority to start those experiments.
