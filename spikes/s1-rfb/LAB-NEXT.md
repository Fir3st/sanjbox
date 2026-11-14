# WP1.A3 — next research and user laboratory work

**Not executed.** These instructions extend the existing [S1 preparation](../s1-session/README.md)
and [LAB](../../docs/LAB.md); they neither reserve a slot nor authorize the implementer to enable
services, create users, change pf/TCC, read credentials, inspect the live screen or connect a client.
All existing measurements and sealed evidence directories remain untouched.

## What the offline prototype now covers, and what it still does not

**[implementátor]** The package parses S5 extended ServerInit and length-framed SessionInfo and,
under explicit `.syntheticVirtualOnly`, emits command 2 and consumes bounded pending/denial/granted
results. Default selection still rejects all masks. The local opt-in policy requires virtual bit 2
and no unknown command bits; it does not assert a server permission contract. S4 authentication is
still a mock seam; [AUTH-BACKEND](AUTH-BACKEND.md) records the exact remaining crypto blocker.

Every grant fails with `unverifiedSessionIdentity` before `.initialized`, pixel-format/encoding
output or framebuffer. Neither the request nor the reported grant proves non-console identity.
A3 stays in progress; these fixtures advance command/result integration but do not authorize a
live client or close the original Apple-auth requirement. See [README](README.md).

## Before a custom client can connect

**[implementátor]** The current binary has no live mode. A later separately reviewed change must:

1. **[částečně hotovo]** S4 framing and S5 selection records/lifecycle are source-backed and bounded
   offline. [Independent review](VALIDATION.md#integration-review-and-plan-handoff-for-pr-81--2026-11-14)
   confirms the local opt-in mask rule and pending/denial/budget/deadline/no-fallback flow only;
   it does not establish server authorization. The policy does not adopt the upstream unchecked virtual branch.
   Choose and review a supported type-30 backend, then implement the provider with independent
   synthetic known-answer vectors; do not guess cryptography or use private API. The precise
   blocker/criteria are in [AUTH-BACKEND](AUTH-BACKEND.md). Live command/capability interoperability
   remains unverified; a grant must not relax the identity boundary below.
2. Establish authenticated server identity and confidentiality appropriate to the chosen local path before
   any credentials. Loopback, a port number, a server name or DH exchange alone is not an identity proof.
   Investigate local port substitution and the trust boundary around a forwarder. Do not adopt the
   prototype's None mode, use a generic password fallback, or infer encryption of the whole session from
   an encrypted credential exchange.
3. Design explicit host-side credential consent/storage separately. Implementers use only synthetic
   fixtures; no Keychain reads, saved-login extraction, terminal/environment passwords or packet capture
   of real authentication data. The reviewed research does not approve a crypto implementation.
4. Keep clipboard/file transfer disabled and control messages absent until their own design/review.
   Add transport partial-write/backpressure and failure tests, scheduled monotonic idle/total deadlines,
   cancellation, bounded queues and no automatic reconnect. No real endpoint should be accepted by a
   synthetic test harness.
5. Bind the returned surface to an independently checked expected identity. Do not infer it from the
   desktop name, login username, server status, requested virtual mode or framebuffer content.
   **[neimplementováno]** The current Apple parser never publishes `.initialized` or any pixel format:
   even an opted-in synthetic grant stops at `unverifiedSessionIdentity`. A future surface must still
   be tied to independent identity; SessionResult cannot replace the exact audit-session comparison below.

## Identity first, before real measurement

**[implementátor]** A future real probe's first operation must capture/check `spikes/common` identity
against **pre-registered** real/effective UID and GID, required/forbidden groups, Aqua bootstrap manager
and its UID, window-session UID, and non-console status. Supplement common's `ProbeExpectation` with a
mandatory **exact expected positive audit session ID** comparison. Common currently only supports a
forbidden-session list; “different from the host” is insufficient because it could be another area's
session. Missing, zero/nonpositive, unreadable or mismatched identity makes the measurement invalid and
must stop all subsequent measurement. Never fill in expectations from the same sample being validated.

Obtain expected area identities in the controlled user setup and record them before each measurement;
the host reference has its own expectations. A restart or reconnect that changes audit identity needs
an explicit new setup/expectation, not automatic acceptance. Preserve context logs with each phase.
This package does not modify common or claim that existing S1 launchers already enforce this addition.

## Screen Sharing.app bootstrap / fallback

**[uživatel]** Use the existing S1 L1 procedure only in a registered, exclusive slot on a backed-up test
Mac, with empty test profiles and synthetic content. F0.8 and the missing instrumentation listed in LAB §8
must be resolved before a complete gate run. The steps here do not bypass that limitation.

1. Follow the existing S1 dry-runs, user-created accounts and port protection procedure. Verify protection
   from the independent LAN peer **before enabling/using the service**; restrict access to test users.
   Do not enable legacy “VNC password” access to make this prototype work. Do not broaden Remote
   Management or Remote Login permissions as a convenience fallback.
2. Use the existing user-operated loopback forwarder / Screen Sharing.app route. Its ability to connect
   to this Mac is still an L1 hypothesis, not evidence supplied by A3. Use **Standard** mode for the
   three-user-session experiment; High Performance is a separate one-session limitation.
3. Explicitly choose the test account's own virtual login, if offered. Do not select share-console or
   request permission to observe the host. If that choice is absent/denied, stop and record the result.
   Do not assume a login with the expected username guarantees the resulting surface.
4. Keep Screen Sharing's shared clipboard disabled in its UI; do not invoke clipboard fetch/send,
   paste, drag/drop or file transfer. Verify the actual settings for the tested OS version before using
   any shared content; if disabled behavior cannot be established, do not use host clipboard data in the
   run. The RFB mock's clipboard rejection says nothing about Screen Sharing.app settings.
5. After the user establishes the test session, run the identity-first probe with the exact expectations
   above inside that session. If it is the host console or another session, disconnect and record an
   invalid setup; do not continue the measurement. Authentication alone is not the oracle.
6. Measure GUI-01…13 according to LAB: three distinct users/audit sessions beside the responsive host,
   actual application presentation and GPU workloads, disconnect continuity, and separate keeper trials
   if needed. A retained Screen Sharing connection is a different measured construction from no client.
   An A3 offline frame neither closes GUI-13 nor measures connection RAM/latency.
7. For TCC bootstrap use only the existing user-confirmed S1 steps in the verified test relace. The
   implementer does not click prompts, capture the host, grant permissions or automate screen control.
8. Follow S1 cleanup in its documented order, restore only owned changes, inspect residual processes and
   listeners, record conflicts, and close the slot only after review. Keep failed/invalid runs and each
   developer's independent measurements; use a new run ID rather than overwriting earlier evidence.

**[uživatel + reviewer]** Compare outcomes to PLAN and pre-registered LAB thresholds. Screen Sharing.app
is the documented bootstrap/fallback route, but its existence does not prove isolation, three accelerated
sessions or persistence. F0.6 permits a retained-client desktop fallback; it does not resolve inability
to run parallel accelerated users. New findings must preserve that boundary and all gate statuses until
the required evidence is complete.
