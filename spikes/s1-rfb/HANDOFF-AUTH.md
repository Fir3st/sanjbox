# WP1.A3 scoped continuation — 2026-11-14

Existing authorship/ownership: janfiedler / Codex + Astra. The user explicitly delegated
this continuation to a fresh Astra implementation agent on `codex/wp1-a3-apple-auth`,
from clean main `75f3b5da13dfd7fca3acd376e06f1cd4d0fe2786`.

Scope: only `spikes/s1-rfb/`, this package’s COVERAGE row and its own validation.
Completion target: a real type-30 Apple credential provider exercised only with synthetic
inputs, plus S5 length-framed session selection and strict refusal of console fallback.
Pinned primary client byte contracts must be distinguished from policy and hypotheses.
Any unsupported portion remains explicitly incomplete; no live interoperability is claimed.

No live RFB connection, real credential reads, accounts, system settings or TCC changes.
All acceptance cases and gates remain unverified. Independent review precedes PR readiness;
this agent does not merge or enable auto-merge.

## Bounded delivered scope

Public SDK inspection did not establish an approved finite-field DH backend. The locally cached,
hash-verified S5 files establish record layouts but forward the allowed mask to unavailable
`ard/session-select.js`. Per the coordinating agent's explicit follow-up, this change delivers exact
S5 record codecs and integrated metadata/SessionInfo parsing with terminal policy refusal. It does
not implement speculative cryptography or mask semantics. A3 stays in progress; both concrete gaps
are documented in README/SOURCES/LAB-NEXT. No claim of a complete Apple selection handshake is made.

## Independent integration review — 2026-11-14

The fresh reviewer now fetched and hashed the previously unavailable pinned `ard/session-select.js`;
[SOURCES](SOURCES.md) records its exact provenance. It describes per-command bits and tests the console
bit, but virtual command 2 bypasses that test. The historical availability gap above is resolved;
a reviewed virtual-authorization policy, integrated result lifecycle and Apple DH provider are still
missing. This review preserves the delegated bounded scope and terminal refusal; it does not claim
A3 completion or authorize a live connection.

## Next scoped continuation — 2026-11-14

The user explicitly delegated the owned A3 continuation to a fresh Astra implementer on
`codex/wp1-a3-auth-followup`, starting from clean main
`7b8294e4fd28a3e62f4998baf39d3da1fd904ccb` after #78/#77. Original authorship remains
janfiedler / Codex + Astra; the earlier review and evidence above are preserved.

This follow-up owns only `spikes/s1-rfb/` and the A3 COVERAGE row. Its bounded target is
a source-backed, explicitly local virtual-command authorization policy and the integrated S5
command/result lifecycle (pending/denial, deadline, shared message budget and no console fallback),
plus investigation of a supported public type-30 finite-field DH/MD5/AES backend. Implement crypto
only if defensible without new unsourced dependencies, private API or hand-rolled cryptography;
otherwise document the precise remaining blocker and deliver independently useful selection work.

Validation uses this Mac, synthetic bytes and offline fixtures only. No live RFB/credentials,
accounts, system settings or TCC; no laboratory acceptance changes. Completion requires source
provenance, Debug/Release tests, updated package documentation and an independently reviewed draft
PR. This follow-up does not claim full A3 completion if crypto or identity binding remains absent,
and does not merge or enable auto-merge.

### Delivered continuation and remaining condition

Source/test commit `2c33df1` integrates explicit local virtual-only policy, the exact S5 command,
pending/denial/grant parsing, a shared message budget and a fixed monotonic result deadline. Default
selection remains refusal; even an opted-in grant stops before the missing independent identity,
with no Apple framebuffer. [Validation](VALIDATION.md#local-virtual-selection-lifecycle-continuation--2026-11-14)
records 54/54 Debug and Release tests, 28/28 CLI checks and 98/98 repository-tool tests.

This is a concrete advance toward the original A3 completion condition, but the real type-30
provider remains absent. [AUTH-BACKEND](AUTH-BACKEND.md) identifies the exact unblocking decision:
a permitted, supported, independently reviewed arbitrary-modulus DH backend plus synthetic KATs.
Another generic mock/docs continuation would not resolve it. Independent review of this local policy
and lifecycle is pending; leave the PR draft. No live use, acceptance change, merge or auto-merge.
