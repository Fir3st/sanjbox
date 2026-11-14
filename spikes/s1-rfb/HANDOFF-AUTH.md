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
