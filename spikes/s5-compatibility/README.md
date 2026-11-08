# WP1.D6 — compatibility inventory and current decisions

Start with [CURRENT-DECISIONS.md](CURRENT-DECISIONS.md) for the **November 7 F0.7/C-003
user decision**, reviewed November 8. The earlier [REPORT.md](REPORT.md) is a separate historical
compatibility inventory, pinned to its original revisions; its 50 rows and observations are unchanged.

## Current decision snapshot (2026-11-08)

[current-decisions.json](current-decisions.json) and [current_decisions.py](current_decisions.py)
provide a versioned, closed catalog of six accepted integration scopes and an unsupported default.
User acceptance, integration implementation, live evidence and gate status are independent fields.
All six accepted integrations remain **implementation-blocked / live-unverified** in this inventory.
Existing typed fixture components retain their historical scope below.

C-003 accepts Claude subscription, Codex ChatGPT and OpenCode OAuth only with per-area opt-in and
an integration/provider domain allowlist. Tokens in the area are assumed compromisable; full R3 is
**not met** for that exception. Reviewed domains, actual account scopes, disable/delete revocation
and live evidence are missing or unverified; this package invents none of them. OpenCode API keys
retain typed host-gateway custody; GitHub classic PAT is host-only for project git smart HTTP
fetch/push; Xcode is Simulator-only without signing or Apple ID. Unlisted integrations stay unsupported.

From the repository root, using only the existing Python standard library:

```sh
/usr/bin/python3 -I -B spikes/s5-compatibility/current_decisions.py validate
/usr/bin/python3 -I -B spikes/s5-compatibility/current_decisions.py report
/usr/bin/python3 -I -B spikes/s5-compatibility/current_decisions.py report --format json
/usr/bin/python3 -I -B spikes/s5-compatibility/tests_current.py
```

These commands are read-only; reports go to stdout. The current validator reuses the historical
bounded strict JSON reader, accepts an explicit `--decisions` file, and returns 2 without a report
on invalid input. It makes no network or Git calls, executes no product client, and reads no accounts,
Keychain, trust stores or personal data. Tests create and remove only their own temporary directories.
This JSON is **not runtime policy**: it contains no usable domains, credentials or area configuration.
New scope or evidence needs a reviewed version update. The checker verifies structure/provenance
and contradictions, not cited prose, enforcement or real interoperability.

[tests_current.py](tests_current.py) checks 44 synthetic scope/evidence contradictions, closed
coverage, source pins, separate statuses, exact report regeneration and byte preservation of the six
historical code/data/report/test artifacts. [VALIDATION.md](VALIDATION.md) records source revisions
and measured test counts; no offline-proof archive is created. To regenerate the current report:

```sh
/usr/bin/python3 -I -B spikes/s5-compatibility/current_decisions.py report > spikes/s5-compatibility/CURRENT-DECISIONS.md
```

## Historical inventory (2026-11-04)

The sections below describe the original baseline/proposed-D5 snapshot. Their unresolved-F0.7 and
unsupported-passthrough claims apply to those pinned revisions; use the current report above for
the later accepted decision. The historical `matrix.py report` command is unchanged.

D6 delivers an offline, machine-readable inventory of **25 client/protocol subsets × 2 policies =
50 rows**, with a deterministic Markdown/JSON report and negative validation fixtures. It covers
all clients named by [PLAN S5](../../PLAN.md#s5--typované-brány-bez-rootu-testovatelné-hned), splitting
Gradle/Maven, Python/TypeScript SDKs, Git HTTP/SSH and WebSocket/SSE where their contracts differ.

For this historical snapshot, use [REPORT.md](REPORT.md). [matrix.json](matrix.json) is authoritative;
[sources.json](sources.json) contains 52 reviewed primary-source or repository-evidence references.
Every descriptive claim has source IDs. The matrix distinguishes a documented configuration option,
a candidate protocol subset, an inherited local client observation, and unsupported behavior.
**D6 does not establish compatibility by running any package manager, SDK or agent.**

The baseline is immutable `afae1ca7dfe78f03d5006c42b6b01093772eba0c`. Proposed D5
`9ddb62e2efde534d7057a1ce01aa9bd942156ee8` is a separate column, with no code/import/build dependency
on that branch. Full-commit GitHub URLs identify its observations even when its worktree is absent.
A future merge does not silently change this historical matrix; updating the baseline requires review.

| Status | Meaning |
|---|---|
| `fixture_only` | Exact inherited local fixture observation, pinned client/revision and scripted upstream; no broader support |
| `untested` | A matching gateway wire subset is a candidate; this exact client/version/request pattern has not run |
| `unsupported` | No adapter, a known incompatible client requirement, or an explicit denial; never a deferred positive |

Baseline observations are only npm's generated tarball `pack` and raw HTTP/SSE transport. Provisional
D5 adds generated-wheel pip `download` and generated-repository Git clone/push. No inherited test is
represented as rerun by D6. pnpm/Yarn/Bun are untested candidates; uv is an untested candidate only
under proposed D5. Homebrew, private auth, stock agents/SDK integration and every passthrough row
remain unsupported. The model endpoint is narrower than a normal Anthropic SDK, and it is not an
OpenAI Responses/Chat Completions implementation.

### Scope and evidence

Mapping: preparation for **R8 / GW-19**, with explicit **GW-12…15** collision, identity, trust and
cache boundaries. S5/S6, GW-19, POS-01…03, R3/R8 and performance remain **Neověřeno / unverified**.
F0.7 scopes/revocation and F0.8 performance budgets are not settled by documentation research.

The shared policies and every profile state:

- Supported operation subset and excluded protocols, endpoint shapes and workflows.
- Exact observed version, or dated rolling-document scope with **no executable version tested**.
- Separate HTTP and HTTPS configuration/trust surfaces; per-zone CA is not client authentication.
  D2 and proposed PyPI rewrite only HTTP publicOrigin, even though D1 offers a TLS listener.
- Credentials, same-host typed/passthrough collisions, alternate URLs/accounts/protocols and fallback.
- Bounded request/response/concurrency/deadline behavior, cooperative cancellation, SSE completion,
  download-versus-install audit and local-cache/import limits. Provisional absolute-deadline repair
  `ca4e50d` is not silently attributed to baseline code.

Official documentation was browsed on **2026-11-04**. Sources record the reviewed page, sections and
version scope. Rolling pages and upstream `main` are explicitly not immutable snapshots. No web
archive or downloaded SDK/package is retained. Repository evidence uses full commit pins. Before a
future client fixture, pin the executable version and reread the relevant protocol/configuration
sources; documentation alone cannot upgrade a row to `fixture_only`.

### Run (implementer)

Only the existing native Python standard library is required (validated with Python 3.9.6 on
arm64 macOS 27.2). From the repository root:

```sh
/usr/bin/python3 -I -B spikes/s5-compatibility/matrix.py validate
/usr/bin/python3 -I -B spikes/s5-compatibility/matrix.py report
/usr/bin/python3 -I -B spikes/s5-compatibility/matrix.py report --format json
/usr/bin/python3 -I -B spikes/s5-compatibility/tests.py
```

These are read-only/default dry-run operations. `report` writes only stdout. Tests use new,
automatically removed `sanjbox-d6-test-*` temporary directories and only run this repository's
validator through the same native Python. They do not install or invoke clients, access networks,
read ambient configuration/secrets, use Keychain, change trust stores, create accounts or use sudo.
No laboratory slot or privileged **[user]** action is needed for this offline package.

Regenerate the reviewed report only after editing and validating the matrix:

```sh
/usr/bin/python3 -I -B spikes/s5-compatibility/matrix.py report > spikes/s5-compatibility/REPORT.md
```

The validator exits **0** on success and **2** on invalid input. `--matrix` and `--sources` accept
explicit regular JSON files (no symlink/FIFO/device input). Limits are 1 MiB per input, 32 nesting
levels and 50,000 JSON nodes; ambiguous duplicate keys and nonfinite values are rejected. It makes
no network or Git calls and does not read baseline/D5 files, so it works from an empty cwd.

### Validator contract and limits

`matrix.py` contains the independent required profile/tuple inventory. Removing rows or profiles
from the JSON cannot reduce the required coverage. It rejects missing/duplicate rows and sources,
unknown or absent citations, missing version/HTTP/HTTPS/credential/collision/limit fields, unknown
statuses, passthrough positives, unsupported adapters relabelled as untested, unobserved positives,
wrong-client fixture citations, D5-to-baseline evidence promotion and any gate/live positive.

The four inherited observation identities/layers/revisions are explicit in the validator. A new
positive observation requires a reviewed code/data change, exact version and real evidence; merely
adding a documentation URL or setting `supported` fails. The schema intentionally has no blanket
“supported” value. `null` proposed assessment means no change, not automatic promotion.

The checker validates **structure, coverage and provenance consistency**, not the truth of prose,
remote-source freshness, completeness of a source's support, or actual network isolation. A
structurally valid citation can still be misleading and needs human review. This is an inventory,
not an enforcement proxy or a security proof.

[Test fixtures](fixtures/invalid-cases.json) contain 28 declarative invalid mutations with expected
rejection reasons. [tests.py](tests.py) also verifies strict JSON/bounds, standalone CLI behavior,
no report on error, exact observation separation and reproducibility of the committed report.
[VALIDATION.md](VALIDATION.md) records commands, results, gaps and cleanup.

### Next evidence

D7 must use preregistered area identity and independent counterpart evidence after the network
boundary is ready. Future client fixtures should include exact protocol traces, strict custom-CA
success plus wrong-CA/wrong-host rejection, same-host typed/passthrough denial, cancellation and
size limits, and alternate endpoint/cache behavior. Live identities additionally require user
scope/revocation evidence under F0.7. This package does not run those experiments or authorize
client installations, external accounts, real keys, or a compatibility bypass.
