# WP1.A6 — native registration recovery continuation

Base `main` `7b8294e4fd28a3e62f4998baf39d3da1fd904ccb`, branch
`codex/wp1-a6-native-recovery`, 2026-11-14. Original authors/owners
**janfiedler / Codex + Astra** are preserved. The continuing Astra implementer has
an explicit user handoff; prior #77 evidence is unchanged.

Concrete gap: the native `S8ServiceHost` retains registration provenance only in
memory. Its intent/result observations live under temporary roots and do not
bind the complete signed application inventory. A crash loses the state needed
to distinguish pending, completed, drifted and unknown operations.

This continuation ends with a real persistent, inode-bound operation journal
wired into the native user-service adapter, exact run/app/service/UID/signed
inventory binding, interrupted/drift/unknown recovery refusals, and native
filesystem/process tests in Debug and Release. A receipt or unchanged service
status must never authorize adoption after restart or artifact deletion.

Native daemon authorization and SG-06 positive-control feasibility will be
assessed against the SDK and primary sources. No speculative mutation endpoint
or incomparable attach runner will be added. Live registration, signing identity,
accounts, TCC, reboot and system changes are outside the authorized work.
A6 stays partial; no S8/SG verdict changes.
