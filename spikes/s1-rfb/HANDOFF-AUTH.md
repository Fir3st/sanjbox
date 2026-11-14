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
