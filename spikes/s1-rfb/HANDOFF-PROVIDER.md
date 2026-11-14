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


## Implementation milestone — 2026-11-14

The approved provider/worker and independent KATs are now implemented; local Debug/Release
pass 81/81 methods and the selected pinned upstream suite passes 188 tests. The clean
CI-script rehearsal provisions only A3 and supplies identical pinned flags to build/test;
its measured per-configuration total fits the unchanged 12-minute budget. Details, failed
attempts, exact target-27.0 rebuild delta and scope limits are in [VALIDATION](VALIDATION.md).
[AUTH-PROVIDER](AUTH-PROVIDER.md) records the same-UID path limitation, strict SIGCHLD/no
competing-reaper caller contract, reserved cleanup fallback and independent identity refusal.
Fresh final review and exact-head hosted CI remain required. No push, PR or merge has been
performed by the implementer; the coordinator owns that next step after review. Own large
temporary build caches are retained until final review, then removed while keeping logs/state.


## Integration review and next owner — 2026-11-14

The preceding no-push instruction describes the original implementation assignment.
The later explicit integration assignment authorizes final review, documentation,
commit/push and PR maintenance for [#84](https://github.com/Fir3st/sanjbox/pull/84),
while the coordinator retains merge control. #83 is now merged in main as `b183737`;
A3 integrated it normally in `6ff8f2a`, preserving every A6 file and its coverage row.
The fresh independent [integration review](VALIDATION.md#independent-integration-review-of-pr-84-after-pr-83--2026-11-14)
found no source defect and reproduced 81/81 Debug/Release, 188 upstream tests, 150
independent oracle checks, 28 CLI scenarios and 98 repository tests. Failed attempts
remain separately recorded. Final hosted checks must match the final pushed head;
old `c324217` CI cannot substitute for that requirement. No merge or automerge is
performed by this review.

The delivered milestone is the approved offline provider, not completion of A3.
The next assigned owner remains janfiedler / Codex + Astra and must define trusted
server identity, the independently obtained expected non-console UID/audit session,
their connection binding and positive/negative oracles before a concrete live-use
proposal under LAB-NEXT. Preserve fail-closed grants until identity is proved; no
server/session label or successful crypto response is authority. Do not reopen backend
selection or add another general mock in place of that missing identity work. Any new
dependency version or real authentication remains outside this exact offline approval.
Screen Sharing.app/L1-D and all 10/155 unverified gate/case states remain unchanged.
