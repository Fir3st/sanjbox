# WP1.D6 — compatibility inventory

D6 delivers an offline, machine-readable inventory of **25 client/protocol subsets × 2 policies =
50 rows**, with a deterministic Markdown/JSON report and negative validation fixtures. It covers
all clients named by [PLAN S5](../../PLAN.md#s5--typované-brány-bez-rootu-testovatelné-hned), splitting
Gradle/Maven, Python/TypeScript SDKs, Git HTTP/SSH and WebSocket/SSE where their contracts differ.

Start with [REPORT.md](REPORT.md). [matrix.json](matrix.json) is authoritative for this package;
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

## Scope and evidence

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

## Run (implementer)

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

## Validator contract and limits

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

## Next evidence

D7 must use preregistered area identity and independent counterpart evidence after the network
boundary is ready. Future client fixtures should include exact protocol traces, strict custom-CA
success plus wrong-CA/wrong-host rejection, same-host typed/passthrough denial, cancellation and
size limits, and alternate endpoint/cache behavior. Live identities additionally require user
scope/revocation evidence under F0.7. This package does not run those experiments or authorize
client installations, external accounts, real keys, or a compatibility bypass.
