# WP1.A3 — approved synthetic provider continuation

2026-11-14, explicit user delegation to Codex / Astra xhigh, continuing original
janfiedler / Codex + Astra ownership on `codex/wp1-a3-dh-provider-next` from
`98a80af368bdc941a072a9496ef50f1666dc3211` after PR #81.

The user explicitly approved the exact revised dependency proposal at
`/private/tmp/sanjbox-a3-openssl-approval-proposal.md` ("Schvaluji přesný rozsah návrhu").
Scope: pinned OpenSSL 3.5.9 libcrypto, local source build and selected upstream tests,
public-API C shim and bounded one-shot native worker, synthetic type-30 provider and
independent KATs. Only 1024–4096 effective modulus bits, at most 512 wire bytes,
backend-validated safe primes and peer range checking, without an order-q membership
claim. A3-scoped CI provisioning/link flags are included. No installation, live RFB,
real credentials, accounts, TCC/system/backup changes, push/PR or merge is authorized
by this implementation handoff.

Completion of this continuation requires the actual provider, independent literal
DH/MD5/AES/whole-response vectors, malformed-group/failure/cancellation/worker lifetime
checks, Debug/Release validation, dependency provenance/license, scoped CI and fresh
independent code review. Claims remain local at the coordinator's explicit instruction
not to push or open a PR before review. All previous evidence remains intact.

A3 as a whole remains in progress: working crypto cannot establish server identity,
confidentiality or the expected non-console UID/audit session. Parser grants must still
fail at `unverifiedSessionIdentity`, with no Apple framebuffer or console fallback.
Every gate and acceptance case remains unverified. Screen Sharing.app/L1-D is unchanged.
