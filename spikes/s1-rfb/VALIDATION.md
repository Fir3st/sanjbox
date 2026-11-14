# WP1.A3 — offline developer validation

**Mock/unit validation only, 2026-11-03.** No S1 laboratory slot or gate measurement was performed.
No connection, screen capture, TCC prompt, credentials, Keychain access, services, users or system
settings were involved. Existing evidence and other developers' results were not edited.

## Reproducible result

- Developer: janfiedler / Codex + Astra; isolated branch `codex/wp1.a3-rfb-research` from
  `547f3c1e630cdd95662b9a9f339a22f7a1c47026`; ownership commit `2c16e80`.
- Toolchain reported by `swift --version`: Apple Swift 6.4, `swiftlang-6.4.0.34.1`, clang
  `2100.3.34.1`; target `arm64-apple-macosx27.2.0`. This records the developer compiler target,
  not Apple Screen Sharing compatibility or a newly registered lab configuration.
- Final developer Debug run: **21 XCTest methods, 0 failures**. Test framework wall duration
  approximately 0.047 s; timing is diagnostic, not a performance result or acceptance threshold.
- The separately printed Swift Testing “0 tests” line is a second framework's empty suite; the
  21 methods above execute under XCTest.
- Demo: **all 16 expected pixel bytes matched**; 52 protocol bytes generated in memory,
  **0 network bytes sent**.
- No arguments / `--help` / `--demo`: exit 0. `--host 127.0.0.1` and `--demo extra`: exit 2.
  There is no live endpoint, file or credential input mode.
- `git diff --check`: passed. Swift package has no package dependencies.

Independent coordinator review on the same unchanged source hashes: **Release 21/21 passed, 0 failures,
no compiler warnings**; Release `--demo` matched the same 16 bytes / 52 generated protocol bytes / zero
network bytes, and `--help` passed. The coordinator also independently fetched the three pinned raw
source files in SOURCES.md and confirmed all SHA-256 values. Its first Release build hit a sandbox
`Operation not permitted` in Xcode `dsymutil`; the same build/test was rerun with tool escalation and
passed. That build-environment retry is not a live RFB probe or gate result. Release reproduction uses
the command below with `-c release` and a separate scratch directory.

Command from `spikes/s1-rfb` (all scratch/cache paths belong solely to A3):

```bash
env CLANG_MODULE_CACHE_PATH=/private/tmp/sanjbox-a3-module-cache \
    SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/sanjbox-a3-module-cache \
  swift test --disable-sandbox \
    --scratch-path /private/tmp/sanjbox-a3-debug-build \
    --cache-path /private/tmp/sanjbox-a3-swift-cache \
    --config-path /private/tmp/sanjbox-a3-swift-config \
    --security-path /private/tmp/sanjbox-a3-swift-security \
    -Xswiftc -module-cache-path -Xswiftc /private/tmp/sanjbox-a3-module-cache
/private/tmp/sanjbox-a3-debug-build/debug/sanjbox-rfb-fixture --demo
```

Two initial build attempts stopped before tests: first the manifest compiler tried its default module
cache outside the writable roots; then nested `sandbox-exec` was disallowed. The final command uses
isolated module caches and disables the **SwiftPM manifest sandbox** while remaining inside the tool's
filesystem sandbox. It executes only this local dependency-free package. These setup failures were not
protocol test failures or live-system findings.

## What the tests establish

| Area | Oracle |
|---|---|
| Version/auth | Exact 3.8 response; wrong/Apple banners rejected; default refuses authentication; synthetic policy refuses unsupported, duplicate and mixed lists; required 3.8 SecurityResult. |
| Initialization | Exact setup output; bounded dimensions/format/name; nonzero padding accepted; no peer-controlled text surfaced. |
| Fragmentation | Every two-chunk boundary and bytewise delivery for handshake and Raw update; every boundary of multi-rectangle/bell stream. Outputs and pixels match unsplit fixtures. |
| Pixel updates | Known byte arrays, row placement, overlap order and unchanged pixels after an incremental update; partial update inaccessible and erased on later error. |
| Malformed inputs | Invalid coordinates/dimensions/encodings, oversized names/reasons before payload allocation, clipboard and unknown message types rejected. |
| Lifecycle | No unsolicited update, one request outstanding, explicit polling, EOF at every incomplete handshake/update prefix, clean idle EOF, terminal cancel/deadline/failure. |
| Resource budgets | Maximum 4 MiB frame accepted; oversized chunk, rectangle count, cumulative pixels, message/request count and lifetime wire bytes rejected. |
| Regression corpus | 1,000 deterministic single-byte handshake mutations, seed `0xa3_2026_1103`, bounded terminal outcome. This is not a coverage-guided fuzzing or security-audit claim. |

The source hash table identifies the exact developer-tested code; documents may change independently.
Hashes use SHA-256 over the UTF-8 file bytes, paths relative to this directory.

| File | SHA-256 |
|---|---|
| `Package.swift` | `d026d1d90c2dee4f97aadb14399db6eeb63a0ca6cdb6a0a482299e43fbf8de0d` |
| `Sources/RFBProtocol/RFBClient.swift` | `a6504d5590255679f9434fb39775886461ec97425162810e40ce84239c756f2d` |
| `Sources/sanjbox-rfb-fixture/main.swift` | `7d68bab0dcdaad9601baddd9567f520d36847c16276109136975caa078de3c7f` |
| `Tests/RFBProtocolTests/RFBClientTests.swift` | `01e34a824449400cef29cce337fc319ce62c5972481cc58ef65cb38684893ce3` |

## What remains unverified

Apple authentication, server identity, encrypted transport, proprietary virtual-session selection,
macOS server interoperability, screen presentation, full initial-frame coverage, latency/RAM, GPU,
disconnect persistence, three concurrent areas, UI/control and TCC are unimplemented or unmeasured.
No R1–R8 requirement, GUI test, POS-08 or gate changes status. A standard Raw frame cannot prove the
selected desktop belongs to the intended user. The future exact audit-session check and Screen Sharing
bootstrap path are preparation instructions in [LAB-NEXT.md](LAB-NEXT.md), not executed evidence.

The branch's F1 aggregate is `2 hotovo / 1 rozpracováno / 27 nezahájeno / 0 blokováno`, reflecting only
this branch's change from clean main. Integration with other package branches must recalculate the
aggregate from all rows rather than overwriting concurrent progress.

## Apple fixture subset run — 2026-11-07

**Mock/unit validation only.** No connection, socket, TLS, credential, Keychain entry, TCC prompt,
service, user or system setting was involved, and no packet capture or live Apple exchange exists.
The Apple bytes in this package are synthetic fixtures; the selection layout is package-local and
documented as such in `Sources/RFBProtocol/AppleSubset.swift`. The 2026-11-03 section above is left
intact as the historical record of the earlier revision; its hash table describes the pre-change files.

- Commit: `31f80c9` (branch head at the time of this run; the hash table at the end of this section is
  that commit's files).
- Toolchain, reported by `swift --version`: `swift-driver version: 1.168.6 Apple Swift version 6.4.2
  (swiftlang-6.4.2.1.9 clang-2100.4.1.1)`, `Target: arm64-apple-macosx27.2.0`. This is the developer
  compiler target, not a registered lab configuration or a Screen Sharing compatibility claim.

Reproduced from the repository root (`spikes/s1-rfb` relative paths):

```bash
swift build -c release --package-path spikes/s1-rfb --scratch-path /private/tmp/a3-build
swift test  -c release --package-path spikes/s1-rfb --scratch-path /private/tmp/a3-test
swift run   --package-path spikes/s1-rfb --scratch-path /private/tmp/a3-run sanjbox-rfb-fixture --demo
/usr/bin/python3 -m unittest discover -s tools/tests
```

Observed output:

- `swift build -c release`: `Build complete! (0,97 secs)`, no compiler warnings.
- `swift test -c release`: `Executed 17 tests, with 0 failures (0 unexpected)` for `AppleSubsetTests`,
  `Executed 21 tests, with 0 failures (0 unexpected)` for the unchanged `RFBClientTests`, total
  `Executed 38 tests, with 0 failures (0 unexpected)`. The separate Swift Testing "0 tests" line is the
  second framework's empty suite.
- `swift run … --demo` (exit 0, deterministic):
  `MOCK ONLY: 2x2 Raw framebuffer matched all 16 expected bytes.` /
  `Generated 52 protocol bytes in memory; network bytes sent: 0.` /
  `MOCK ONLY: Apple fixture selection granted the virtual desktop (command 2).` /
  `Generated 180 protocol bytes in memory; network bytes sent: 0.` /
  `MOCK ONLY: console-only SessionInfo refused (consoleFallbackForbidden); no fallback attempted.` /
  `The Apple selection framing here is package-local, not Apple's wire format.` /
  `Apple authentication/session selection and S1 gates remain unverified.`
- `/usr/bin/python3 -m unittest discover -s tools/tests`: `Ran 63 tests` / `OK` (untouched by this package).

Two temporary local mutations were used to show the new tests can fail, then reverted (not committed,
`cmp` verified the restore): answering ClientInit `0xC1` with `[1]` produced 73 failures; auto-selecting
the console instead of terminating produced 5 failures.

### What the new tests establish

| Area | Oracle |
|---|---|
| Apple banner | Accepted only under `syntheticAppleSubset`; the standard banner is rejected there and the Apple candidate is rejected under both other policies. |
| ARD offer (S4) | Only `[30]` as the single offer; mixed, duplicated and type-33/None/VNC offers terminate before any challenge byte is read. |
| Type-30 framing (S4) | Generator 0/1, key length 0, 1000 and 65535 rejected before payload; 512-byte key length accepted and passed to the seam; provider sees the exact generator/modulus/server-key triple. |
| Credential seam (S4) | No provider, empty response, oversized response and a throwing provider all stop the handshake: `authenticationNotImplemented` / `resourceLimit`, no credential bytes, no `0xC1`, no session choice, `session == .notOffered`. |
| Selection framing | `granted` transcript at every two-chunk split and bytewise; `consoleOnly`, `unavailable`, `denied`, `pending`, empty offer, unknown kinds/commands/states, duplicate offers and a wrong SessionResult outcome all terminate deterministically. |
| Forbidden fallback | A console-only offer and a virtual-desktop-unavailable offer never produce a client choice; the terminal failures are `consoleFallbackForbidden` and `sessionUnavailable`. |
| Ordering | No SetPixelFormat, SetEncodings or `.initialized` before a granted SessionResult; no framebuffer request while selection or pending; a pixel update smuggled into the SessionInfo position is rejected. |
| Lifecycle | Truncated prefix at every byte of the granted transcript; pending waits for a later result, `expire()` is terminal, pending never retries. |
| Regression corpus | 500 deterministic single-byte mutations of the granted transcript, seed `0xa3_2026_1103_a3`, bounded terminal outcome. Not a fuzzing or security-audit claim. |

### Source hashes for this run

| File | SHA-256 |
|---|---|
| `Package.swift` | `d026d1d90c2dee4f97aadb14399db6eeb63a0ca6cdb6a0a482299e43fbf8de0d` |
| `Sources/RFBProtocol/RFBClient.swift` | `47c9a856ff8fc5ddc44551f7c9785eef248e1a11e7028212248cd1d19d55948c` |
| `Sources/RFBProtocol/AppleSubset.swift` | `26096ef6b1c59433e20053abaae3a472cb160abe0b0ae1a47aaf3a828939e9c3` |
| `Sources/sanjbox-rfb-fixture/main.swift` | `9185530c17882e24c9275619d911354a9d1b7cc03e80290c9f13585d44899097` |
| `Tests/RFBProtocolTests/RFBClientTests.swift` | `01e34a824449400cef29cce337fc319ce62c5972481cc58ef65cb38684893ce3` |
| `Tests/RFBProtocolTests/AppleSubsetTests.swift` | `10c5f55046ef247ee23f2cf9852a4d7684122e5ca51477754e148536f644580c` |

### What remains unverified

Real Apple authentication and its cryptography, the actual byte layout of SessionInfo/choice/result and
of the extended ServerInit metadata, server identity, transport confidentiality, macOS server
interoperability, the binding of the returned surface to an exact audit session, screen presentation,
GPU, latency/RAM, disconnect persistence and three concurrent areas. `AppleFixtureFraming.appleBanner`
is an un-re-verified fixture constant. This run changes no R1–R8 requirement, GUI test, POS-08 or gate
status, and it is not a statement that the Apple path works against a real Mac.

## Fix round for PR #57 review — 2026-11-07

**Mock/unit validation only**, same boundaries as the section above: no transport, socket, TLS,
credential, capture, TCC prompt or system change. The sections above stay as the historical record of
the pre-fix revision; this section supersedes only the counts, the corpus oracle and the selection
classification.

- Commit: `4b4d0120c891f236486b6e66e5b51fff3aea6d96` — the tree every command below was run on. This
  record is added by a follow-up commit on the same branch, so the hashes at the end are that commit's
  files; base commit of the round was `31f80c9`.
- Changed sources: `RFBClient.swift` (session classification), `AppleSubsetTests.swift` (two new tests,
  tightened corpus oracle), `SOURCES.md` (implemented / not-implemented boundary), `README.md` (test
  counts and the `consoleOnly` / `unavailable` classification rows).
- Toolchain, `swift --version`: `swift-driver version: 1.168.6 Apple Swift version 6.4.2
  (swiftlang-6.4.2.1.9 clang-2100.4.1.1)`, `Target: arm64-apple-macosx27.2.0`.
- `git diff --check`: passed; no compiler warnings.

Commands, observed output:

- `swift build -c release --package-path spikes/s1-rfb --scratch-path /private/tmp/fix-a3`:
  `Build complete! (1,75 secs)`, no compiler warnings.
- `swift test -c release --package-path spikes/s1-rfb --scratch-path /private/tmp/fix-a3`:
  `Executed 19 tests, with 0 failures (0 unexpected)` for `AppleSubsetTests`, `Executed 21 tests, with
  0 failures (0 unexpected)` for `RFBClientTests`, `Executed 40 tests, with 0 failures (0 unexpected)`
  in total. The separate Swift Testing “0 tests” line is the second framework's empty suite.
- `swift run --package-path spikes/s1-rfb --scratch-path /private/tmp/fix-a3/run
  sanjbox-rfb-fixture --demo` (exit 0): the same six lines as above — 16/16 expected pixel bytes,
  52 generated protocol bytes, granted virtual desktop, 180 generated protocol bytes, console-only
  refusal `consoleFallbackForbidden`, and `network bytes sent: 0` in both scenarios.
- `/usr/bin/python3 -m unittest discover -s tools/tests`: `Ran 63 tests` / `OK`.

### Changes the review asked for

| Finding | Change | Test that fails without it |
|---|---|---|
| `SOURCES.md` claimed no Apple messages are implemented | New “Implementation boundary” section: (a) package-local synthetic framing (message kinds 1/2/3, banner constant, bounds 512/4096/8) versus (b) not implemented (real Apple wire format and extended ServerInit metadata, DH/MD5/AES, type-33, transport, identity) | documentation only |
| Pending `SessionResult` message budget was untested | Charged to the shared `messages` counter and driven to exhaustion | `testPendingSessionResultConsumesTheServerMessageBudget` |
| An unavailable console offer was classified as `consoleOnly` | Only an *available* console counts as a console offer; an offer naming only an unavailable console is `unavailable` / `sessionUnavailable` | `testSessionInfoClassificationIsIndependentOfCommandAndAvailability` (cartesian product of command 1/2 × available/unavailable, single and paired offers in both wire orders) |
| Corpus oracle `phase == .closed \|\| .failed` is always true after `finish()` | Terminal state must agree with `failure` (`failure == nil` iff `closed`), `session == .granted` iff `closed`, `bufferedByteCount == 0`, and no `send([2, 1])` console choice in any emitted event | mutated `testDeterministicAppleCorpusStaysBounded` (see mutations 3 and 4) |

### Mutations used to show these tests can fail

Each mutation was applied to `Sources/RFBProtocol/RFBClient.swift`, the failing test was run alone,
and the file was restored (`cmp` against a saved copy succeeded, nothing was committed):

1. Removed `guard messages < Limits.serverMessages` from the pending branch →
   `XCTAssertThrowsError failed: did not throw an error`, `("sessionPending") is not equal to
   ("failed")`, `("nil") is not equal to ("Optional(…resourceLimit)")`.
2. Restored the pre-fix classification (`availableConsole = consoleState != nil`) →
   `("Optional(…consoleFallbackForbidden)") is not equal to ("Optional(…sessionUnavailable)")` twice and
   `("consoleOnly") is not equal to ("unavailable") - console/unavailable`.
3. Sent the session choice as `[sessionInfoChoiceKind, consoleCommand]` →
   `XCTAssertNotEqual failed: ("send([2, 1])") is equal to ("send([2, 1])")` in the corpus test.
4. Removed `session = .granted` from `grantSession` →
   `XCTAssertEqual failed: ("false") is not equal to ("true")` on the corpus' `granted ⇔ closed`
   invariant.

### Source hashes for this run

| File | SHA-256 |
|---|---|
| `Package.swift` | `d026d1d90c2dee4f97aadb14399db6eeb63a0ca6cdb6a0a482299e43fbf8de0d` |
| `Sources/RFBProtocol/RFBClient.swift` | `2b2241103d47702f0580a6362156aebf1c8b5338831d89f209a5616e54e46555` |
| `Sources/RFBProtocol/AppleSubset.swift` | `26096ef6b1c59433e20053abaae3a472cb160abe0b0ae1a47aaf3a828939e9c3` |
| `Sources/sanjbox-rfb-fixture/main.swift` | `9185530c17882e24c9275619d911354a9d1b7cc03e80290c9f13585d44899097` |
| `Tests/RFBProtocolTests/RFBClientTests.swift` | `01e34a824449400cef29cce337fc319ce62c5972481cc58ef65cb38684893ce3` |
| `Tests/RFBProtocolTests/AppleSubsetTests.swift` | `0f8742b646dfcceb1da05e82fc2a44583fce96f5674540ed4e6168b0c3af27ce` |

### What this round does not prove

It proves neither the Apple wire format, the selection semantics of a real macOS server, the crypto
seam, nor any gate. The classification fix is a package policy statement: a console that a server
marks unavailable is now reported as `unavailable`, which is still not evidence that the offered
virtual desktop belongs to the intended user. All R1–R8, GUI, POS-08 and S1 statuses are unchanged.

## Source-provenance correction after independent PR #57 review — 2026-11-07

This correction supersedes the earlier description of the banner as an un-re-verified local constant
and the claim that pinned sources contain no selection layout. S5 `ard-patch.js` at
`d699293635083c9e0c30c8f9480993865653772a` contains the exact banner at line 214, extended ServerInit
metadata at lines 331–348, SessionInfo at 779–797, SessionResult at 839–867 and SessionCommand at
2510–2523. [SOURCES.md §S5](SOURCES.md#s5--original-author-implementation-lead-for-apple-selection)
now links each record. Its raw SHA-256 was independently rechecked as
`bef0c7b6c88639d555815487e48dcecdcd8362dcee20eb258f70ad397c7164d5`; the S5 constants and S4 raw
hashes also match their existing SOURCES.md entries.

The package-local selection model is a deliberate simplification despite that available client
implementation evidence. No Apple-published specification or live-server interoperability was
established. This correction changes documentation and Swift comments only; runtime statements,
constants and tests are unchanged. Independent review of parent commit
`757b073d887486c7b28447531224a6e2a8650272` passed native Release 40/40 tests and an offline harness
with 131,072 command/availability and kind/result combinations, pending exhaustion and duplicate-grant
rejection. Those runtime checks remain applicable; they were not rerun for this comment-only change.
Validation of this correction: pinned source lines and SHA-256 values checked, Swift non-comment text
compared with the parent, and `git diff --check` passed. All outputs stayed in a unique temporary
directory. No transport, crypto implementation, credentials or laboratory run was added.

## Final local review of PR #57 — 2026-11-13

Reviewed original head `87a274e61bea417f1da5806e8d034966076699f4` after integrating main
`99dc1da162eafe4b89eae8dd331d87182298f2a8` (merge `5df1adf3d39336c09b04d36db217ac192af2e105`).
**Tested fix commit: `2743559e91fd59ede278fb4a22d3c0bfb9d45d34`.** This note is a later documentation-only
commit. Offline parser/unit validation only; no credentials, sockets, live Apple session, system
settings, or S0/S1 laboratory measurement.

Two boundary defects were fixed:

- A nonempty provider response of any size up to 4096 previously advanced the handshake. The seam now
  requires exactly `128 + keyLength` bytes, rejecting a malformed record before credential output or
  ClientInit. The check establishes shape only; cryptographic validation is still unimplemented.
- Only pending SessionResult messages consumed the message budget. A grant after 1024 pending results
  could therefore initialize a surface beyond the limit. Every SessionResult now consumes the shared
  budget; grant/denial cannot bypass exhaustion, and a final permitted grant leaves no extra Bell slot.

Three added regression methods failed against the pre-fix merged implementation with 66 assertions.
After the fixes, the full suite passes; provider lengths cover key widths 1, 8 and 512, short/long
records, valid exact records, and the pre-existing empty/throwing/oversized cases. Existing fragmentation,
EOF, denial, console refusal, malformed selection, bounded corpus and framebuffer tests also pass.

Environment: arm64, macOS 27.2.1 build 26B131, Xcode 27.2 build 27B52, Apple Swift 6.4.2
(`swiftlang-6.4.2.1.9 clang-2100.4.1.1`). Scratch output: `/private/tmp/pr57-review.E3XtuG`.

| Check | Result |
|---|---|
| `swift test --disable-sandbox --package-path spikes/s1-rfb --configuration debug` | 43/43 XCTest tests, 0 failures; all products built, no compiler warnings |
| Same command with `--configuration release` | 43/43 XCTest tests, 0 failures; all products built, no compiler warnings |
| Both built fixture binaries, `--demo` | Exact 16-byte Raw framebuffer, virtual grant, console-only refusal; 52/180 generated bytes and zero network bytes |
| Both binaries: no args, `--help`, `--demo`, unknown flag, `--host 127.0.0.1`, demo plus host, repeated demo | 14/14 CLI checks; malformed/live-address arguments exit 2 before any scenario |
| `/usr/bin/python3 -B -m unittest discover -s tools/tests -v` | 63/63 passed |
| `git diff --check` | Passed |

Swift commands used separate explicit scratch/cache/config/security/module-cache paths under the
scratch directory. The initial sandboxed Release build failed in `dsymutil` with `Operation not
permitted`; the unchanged native rerun passed. An initial Python invocation with `-I` could not import
the repository's `tools` package; the normal repository invocation above passed. These attempts are
tool invocation restrictions, not hidden test passes. Swift Testing's separate empty suite is not an
additional test count.

Source review re-read RFC 6143 and fetched the pinned S4/S5 raw sources over HTTPS: all three original
SHA-256 values match [SOURCES.md](SOURCES.md). Banner `003.889`, type 30, ClientInit `0xC1`, extended
ServerInit and selection-record citations match the source lines. The newly cited pinned `dh.js`
confirms the client public-key width. Apple support pages S2/S3/display settings were fetched directly
after the browser tool returned HTTP 429, confirming user-desktop semantics and the High Performance
limit without a remaining access gap. No downloaded implementation was executed or reused.

**Limits unchanged:** package-local selection messages are not the S5 wire records; DH/MD5/AES,
authenticated server identity, confidentiality, transport, exact audit-session binding and live
interoperability remain absent. The trusted injected provider owns its own allocations and runtime.
A3 stays in progress because its Apple-auth/selection completion condition is not met; the F1 aggregate,
all 155 cases, S0/S1 and other gates remain unchanged. Screen Sharing.app/L1-D remains a user laboratory
path, not a result of this mock validation.

## Source-backed S5 records, policy refusal — 2026-11-14

**Tested implementation: `6bc94e58e7159ff262865f6cc82371dbf7d23b95`.** This note is a later
validation-only commit. Original authors/owners remain janfiedler / Codex + Astra; the explicit
continuation and bounded scope are recorded in [HANDOFF-AUTH.md](HANDOFF-AUTH.md).

The old package-local selection protocol is removed. New offline codecs cover extended ServerInit,
SessionInfo, the exact 74-byte virtual-only SessionCommand and SessionResult from pinned S5.
RFBClient consumes metadata/SessionInfo and then **always fails with `unverifiedSelectionPolicy`**:
locally inspected source files forward `allowedCmds` to `ard/session-select.js`, whose contents were
unavailable for inspection. No bit interpretation, command authorization, console classification or
successful selection is invented. Command/result positives are codec tests, not an integrated
handshake. S4 DH/MD5/AES is still a mock seam; no real credential provider was delivered.

Local cached `rfb.js`, `dh.js`, `ard-patch.js` and `ard-constants.js` were re-read and their four
SHA-256 values matched [SOURCES.md](SOURCES.md). The code was not executed, linked or copied.
Public CommonCrypto/Security SDK inspection did not establish an approved arbitrary-modulus DH API;
this is a scoped limitation, not a claim that no backend exists. No custom cryptography, private API
or external package was introduced. No live RFB endpoint, credential store, account, TCC or system
setting was accessed. All test protocol bytes were synthetic and stayed in memory.

Environment: arm64, macOS 27.2.1 build 26B131; Xcode 27.2 build 27B52; Apple Swift 6.4.2
(`swiftlang-6.4.2.1.9 clang-2100.4.1.1`). Run directory: `/private/tmp/a3-s5-check.Q1XaS5`.

| Check against the tested implementation | Result |
|---|---|
| `swift test --disable-sandbox --package-path spikes/s1-rfb --configuration debug` | 41/41 XCTest tests (20 Apple, 21 standard), no failures or compiler warnings |
| Same command with `--configuration release` | 41/41 XCTest tests, no failures or compiler warnings |
| Both compiled binaries, no args/help/demo/bad flag/host/demo+host/repeated demo | 14/14 CLI checks; valid commands exit 0, invalid commands exit 2 |
| Both `--demo` runs | Exact 16-byte Raw framebuffer; S5 policy refusal; 52/150 generated bytes, zero network bytes, no Apple choice/surface |
| `/usr/bin/python3 -B -m unittest discover -s tools/tests` (native) | 94/94 passed |
| `git diff --check`; COVERAGE comparison with base excluding A3 row | Passed; all other rows, gates and acceptance statuses unchanged |

Swift commands used separate Debug/Release scratch/cache/config/security/module-cache paths below
the run directory, with `CLANG_MODULE_CACHE_PATH` and `SWIFTPM_MODULECACHE_OVERRIDE` set explicitly.
Initial invocations without those environment settings failed because the manifest tried a protected
module cache. A sandboxed Release attempt then failed in `dsymutil`; native builds passed. The first
sandboxed repository-tools run had eight failures caused by blocked `/bin/ps`, including watchdog
cleanup/timing checks; the unchanged native run passed all 94. These failures are not counted as passes.
Swift Testing's separate empty suite is not an additional test count.

The Apple tests verify literal byte offsets, exact command length/padding, Latin-1→UTF-8 conversion
including 63-byte truncation, NUL handling and no-terminator input, both granted/pending status pairs,
denial, variable reserved lengths, nonzero marker byte 1, opaque bitmap/reserved content, minimum and
maximum lengths, short/trailing/version errors, every prefix/fragment boundary, timeout/cancel,
capability refusal, all 32 one-bit masks plus mixed/zero/all-one masks, provider shape/error checks,
and a 1,000-case deterministic mutation corpus that never publishes an Apple surface. The corpus is
not a fuzzing-coverage or security-audit claim. Pending lifecycle/message-budget tests from the removed
local protocol no longer describe this parser; they must return when sourced policy permits integration.

Two temporary mutations were applied and restored byte-for-byte before final exact-commit tests:
command 2→1 failed the literal command test with two assertions; replacing the terminal policy refusal
with `.ready` failed the mask-refusal test with 148 assertions. Neither mutation is committed.

Build binary SHA-256 at validation: Debug
`113cd9f4cd1b81fa6568b7b622efac002d59a1cc8897dc5b0be7566e3143c002`, Release
`2536e1cd11e4f32b8c03c2d973f4d58e9ef0c50ade6983286e65bebfe8d55f42`.
Own large build/cache directories were removed after checks; only small local logs/CLI records remain.

**Limits:** A3 remains in progress on the real provider and source-backed command authorization;
result integration, server identity/confidentiality, transport, 0×0 initialization, live interoperability,
exact audit-session binding and all laboratory work remain absent/unverified. All 155 cases, all F1
gates, the F1 aggregate and the user's Screen Sharing.app/L1-D path are unchanged. Independent review
and PR readiness are coordinated separately; this implementation agent does not merge or auto-merge.


## Nezávislé integrační review po H4 — 2026-11-14

**Fresh Astra review; tested source/test commit `e1f1e5e653d200a29abb2b613d98e656a873973d`.**
The separate documentation commit adds this record and reconciles COVERAGE/IMPLEMENTATION/README.
Review started from PR #78 head `9cfe84da1c68b67694567b2e4985f569a6ba2edc`, in an isolated managed
worktree. Current `main` after H4 #79 (`41d6f658887fe72ea29d903b6015ea7cfbca5744`) was integrated by
normal merge `4191af88ff65331e9bed49d5ccd91bbcd804522c`, without conflicts or history rewriting.
The full resulting A3 diff was reviewed against PLAN/S1, RFC 6143 and pinned S4/S5 primary sources;
this review does not reuse the implementer's earlier independent-review result as its own evidence.

**Source-evidence correction:** all four previously pinned raw-file SHA-256 values were independently
reproduced over HTTPS. The reviewer also fetched the pinned `ard/session-select.js`, recorded its
hash in [SOURCES](SOURCES.md), and inspected lines 13–47. This resolves the historical availability
gap above. The file describes a per-command mask and checks the console bit for an empty console
username, but returns virtual command 2 without testing the mask. That client preference is not proof
of server authorization or a non-console session. Current docs and parser comments now distinguish
that observed behavior from the still-missing reviewed virtual-authorization policy. RFC and Apple
S2/S3 pages were re-read; the Apple pages required direct HTTPS after browser-tool HTTP 429 responses.
No downloaded implementation was executed, copied into Swift, linked or installed.

No actionable runtime/codec defect was found. The record offsets, length/version checks, opaque
fields, username conversion/truncation and result classifications agree with the pinned client within
the documented conservative local bounds. The standard path stays separate. The integrated Apple
path always fails before command output, pixel-format/encoding output or surface initialization;
the source client's unchecked virtual preference and console branches are not adopted.

A targeted regression, `testUpstreamPreferenceBranchesCannotBypassRefusalWithCoalescedGrant`, adds
5,710 transcript splits per build: absent, NUL-only and nonempty console usernames; masks 0, 2, 4, 6
and all bits; and buffered result status 0 or 4. Every split must produce terminal
`unverifiedSelectionPolicy`, erase buffered bytes and expose no framebuffer or selection event.
The pre-existing literal codec, malformed/budget, fragmentation, provider and standard RFB tests
remain intact. Runtime behavior is unchanged; code changes in this review are comments and tests.

Environment: arm64, macOS 27.2.1 build 26B131, Xcode 27.2 build 27B52, Apple Swift 6.4.2
(`swiftlang-6.4.2.1.9 clang-2100.4.1.1`). Separate native Debug/Release scratch/module/cache/config/
security paths are under `/private/tmp/pr78-astra-review`. Commands follow the explicit-path recipe
in [README](README.md#offline-ověření-a-úklid); the package has no external dependencies.

| Independent check | Result |
|---|---|
| Original merged-base source, Debug and Release | 41/41 XCTest methods in each build, zero failures |
| Final source/test commit, Debug and Release | **42/42** XCTest methods in each build (21 Apple, 21 standard), zero failures/warnings |
| Both binaries: no args/help/demo, invalid flag, host/port/file arguments, duplicate/combined/extra arguments | **28/28 CLI scenarios** (14 per build); expected exits 0/2, no stderr, invalid input never starts a demo |
| Both `--demo` runs | Exact 16-byte Raw framebuffer, terminal Apple policy refusal, 52/150 generated bytes, zero network bytes |
| Native `/usr/bin/python3 -B -m unittest discover -s tools/tests` | **94/94 passed** on the merged base; tooling is unchanged by this review |
| `tools.progress.collect` on final documentation, compared with current `main` | F0 5/5; F1 22 done / 5 active / 9 todo; every requirement/gate/case/package status unchanged |
| `git diff --check` | Passed |

Debug CLI binary SHA-256: `b0cb1c954c445f85aa0907f299b25838a56a46fa73416dcadd7b10ee4e2486cf`.
Release CLI binary SHA-256: `0eb75798b6dc36f02f0f6af98b2d2edb1373e29eb6c2f67f38bb8c6f6706b60b`.
Swift Testing's separately printed empty suite is not an additional test count. There were no live
RFB connections, real credential reads, system settings, new accounts or laboratory measurements.

**Handoff:** A3 remains in progress on the type-30 provider, reviewed virtual authorization and
integrated result lifecycle/budgets. Server identity/confidentiality, transport, exact UID/audit
binding and live interoperability remain unverified. H4 is already merged and complete offline;
after #78's final integration, independently review A6 #77 against the new `main` and its original
completion conditions. The 10 F1 gates and all 155 acceptance cases stay Neověřeno. Exact final-head
CI and coordinator review are still required before merge; this reviewer does not merge the PR.

## Local virtual-selection lifecycle continuation — 2026-11-14

**Implementation validation; independent review is recorded below.** Tested source/test commit
`2c33df1d776c2d721ca9241fe9de48b0ecc9291e` on `codex/wp1-a3-auth-followup`, based on clean
main `7b8294e4fd28a3e62f4998baf39d3da1fd904ccb`. The user explicitly delegated the owned A3
continuation; claim `0fd9ed5` was published before implementation. Original janfiedler / Codex +
Astra ownership and every earlier validation record above are preserved.

This follow-up integrates the S5 command/result path under explicit `.syntheticVirtualOnly`:
only known masks 4/5/6/7 generate command 2; default `.rejectAll` still refuses every mask. The
one-bit convention and command numbers come from pinned S5, while requiring the virtual bit and
rejecting unknown bits are stricter **local fixture rules**, not a verified server authorization
contract. Pending/denied/granted statuses are now consumed by the parser. One shared 1024-message
counter includes Info and every result; a fixed monotonic 30s result deadline never resets on
pending/fragmentation. Caller wakeups are still required during silence. A grant always fails at
`unverifiedSessionIdentity`, with no Apple initialization, encodings, pixel format or surface.

All five locally cached S4/S5 source hashes matched SOURCES. No source was fetched during this
continuation. [AUTH-BACKEND](AUTH-BACKEND.md) records the current public SDK inspection and exact
hashes: no suitable reviewed arbitrary-modulus DH backend was established. The deprecated CDSA DH
declarations are explicitly acknowledged; this is not a claim that no backend exists. No crypto,
private API, external dependency or hand-rolled bignum was added; no end-to-end crypto KAT is claimed.

Environment: arm64, macOS 27.2.1 (26B131), Xcode 27.2 (27B52), Swift 6.4.2
(`swiftlang-6.4.2.1.9 clang-2100.4.1.1`). Native commands used the README recipe with separate
Debug/Release scratch/cache/config/security/module paths under
`/private/tmp/a3-auth-followup-check.qMJ8q7`; both module-cache environment overrides were set.

| Check on the committed source/test tree | Result |
|---|---|
| Native `swift test --disable-sandbox --package-path spikes/s1-rfb --configuration debug` with explicit temporary paths | **54/54** XCTest methods, zero failures or compiler warnings |
| Same command with `--configuration release` and separate paths | **54/54**, zero failures or compiler warnings |
| Both binaries: no args/help/demo plus invalid host/port/file/extra/combined/repeated arguments | **28/28 CLI scenarios** (14 each); expected exits 0/2, no stderr, invalid input never starts a fixture |
| Both `--demo` runs | Exact standard 16-byte Raw framebuffer; one virtual command, pending/grant, terminal Apple identity refusal; 52/224 generated bytes, zero network bytes |
| Native `/usr/bin/python3 -B -m unittest discover -s tools/tests` | **98/98 passed** on this base; no repository tooling changed |
| `tools.progress.collect` comparison with base | Every status unchanged: F0 5/5; F1 22 done / 5 active / 9 todo; 10 gates and 155 cases unverified |
| Scope/history checks and `git diff --check` | Only A3 paths and A3 ownership/note changed; every non-A3 COVERAGE row byte-identical, historical VALIDATION/HANDOFF prefixes preserved |

The 12 new lifecycle methods cover every bit alone and unknown bits combined with virtual,
zero/console-only masks, username-independent policy, literal command bytes and exactly-once output,
all transcript splits and bytewise feeds, both pending/granted statuses, denial/unknown status,
minimum/maximum result bodies, malformed lengths/version, duplicate-Info-as-result ambiguity,
every incomplete Info/pending/grant prefix at EOF, exact deadline boundaries, backwards fixture time,
partial-record expiry/cancellation, coalesced grant plus apparent pixels, missing capabilities and
missing provider. Boundary tests prove Info + 1022 pending + grant consumes exactly 1024 messages,
and the next header after Info + 1023 pending fails before waiting for a body. All original 42
methods remain unchanged, including 5,710 default-refusal transcript splits and standard RFB tests.
Swift Testing's empty suite is not another test count. No mutation/fuzz-coverage claim is made.

Debug CLI SHA-256: `c17a0066f2353b3235ef4c401db753ac30c039e2869268acb4037f1f67041f5c`.
Release CLI SHA-256: `8584b548c1212b9212f4563191ff2e2bc9a4b0edf682378530124d1c0ccc9e49`.
Own large temporary build/module/cache trees were removed after validation; small local logs and
CLI records remain. No test opened a live RFB endpoint, used real credentials, created accounts,
changed settings/TCC or performed laboratory measurements.

**Remaining condition:** this second partial follow-up advances A3 by replacing isolated codecs
with integrated bounded selection. It does not complete the original type-30 auth requirement:
a permitted supported backend and synthetic KATs remain absent. Independent review of the local
policy/lifecycle completed without findings; see the addendum below. Server identity/confidentiality, transport/wakeup scheduling, 0×0
initialization and exact UID/audit binding remain unverified. All gate/acceptance verdicts and
Screen Sharing.app/L1-D remain unchanged. The PR stays draft; this implementation agent does not
merge or enable auto-merge.


### Independent review of the continuation — 2026-11-14

A fresh independent Astra reviewer inspected final head
`00db538ee359864b93590c8d21fe5286d8649ff2` against base `7b8294e4fd28a3e62f4998baf39d3da1fd904ccb`
and found **no actionable correctness or scope defect** in this bounded offline follow-up.
The local review record is `/private/tmp/sanjbox-a3-independent-review.aRS8ze/review.json`.

- Independent native Debug and Release: **54/54 XCTest methods each**, no compiler warnings;
  **28/28 CLI scenarios**, 52/224 generated bytes and zero network bytes.
- A standalone reviewer-authored harness, without reusing package fixtures, passed **291,433
  adversarial assertions each at `-Onone` and `-O`**: all 65,536 low masks and unknown high bits,
  all Latin-1 bytes, maximum records, coalesced failure, shared-message boundaries, exact deadline
  ±1 ns, backwards time, every maximum-result split and incomplete prefix at EOF.
- **5/5 primary-source hashes and 7/7 SDK hashes matched**; API excerpts, A3-only scope, preserved
  history, unchanged coverage statuses and `git diff --check` were independently confirmed.
  Repository tooling was not rerun by the reviewer; the implementer's 98/98 result remains separate.

An initial sandbox Release build failed in `dsymutil`; the permitted native rerun passed. An initial
post-build wrapper exited 1 after using zsh's read-only `status` variable; the retained Debug test
log independently confirms the passing suite. Neither is recorded as a passing failed invocation.
The reviewer removed their own large build caches and binaries and made no worktree, live-server,
credential, account, settings or TCC changes. Harness source SHA-256:
`6f953c2f612871552ffe8bfdcfc5eee11aaf3b1ee49240ca8e5f8baf50ff6834`.

This review confirms the local fixture policy/lifecycle only. Coalesced input can update the last
observed selection state while the throwing `receive` returns no output events; this is not proof
of command delivery. Type-30 backend/provider and synthetic crypto KATs remain the actual A3 blocker.
Live transport/causal sequencing, server and UID/audit identity, all 10 gates and 155 acceptance cases
remain unverified. This addendum changes documentation only; unchanged tests were not rerun for it.
The PR remains draft, without merge or auto-merge.


### Integration review and plan handoff for PR #81 — 2026-11-14

A fresh independent Astra ExtraHigh reviewer inspected source/test head
`e702830781052f4163cb36095ab95040977d0b4d` against main
`7b8294e4fd28a3e62f4998baf39d3da1fd904ccb`. **No actionable correctness/security finding** was
found in the bounded offline implementation. Review confirmed default refusal, local masks 4–7,
exact command-2 framing, pending/denial behavior, one shared message budget, fixed total monotonic
deadline, terminal failure and refusal before Apple initialization or pixels. Coalesced failure
still returns no events; the last observed session state is not proof of command delivery or identity.

Fresh Debug and Release runs passed **54/54 XCTest methods each**, with no compiler warnings;
**28/28 CLI scenarios** passed, including both demos' 52/224 generated bytes and zero-network output.
The initial sandbox Release attempt failed at `dsymutil` with Operation not permitted; the permitted
native rerun passed and is recorded separately. All **5/5 cached primary-source hashes and 7/7 SDK
hashes** matched. The reviewer re-read the pinned selection/auth code without fetching or executing
it; no cryptography, dependency, live RFB endpoint, credentials, account, settings or TCC were used.
Logs and CLI records are in `/private/tmp/sanjbox-a3-pr81-review.BNfYNz`.

Post-edit `git diff --check`, local link paths and `tools.progress.collect` comparisons passed:
all non-A3 COVERAGE rows are byte-identical, every state is unchanged (F1 22 done / 5 active / 9 todo),
and historical HANDOFF/VALIDATION prefixes are intact. The full repository-tool suite ran 98 tests:
the sandbox attempt had 8 watchdog failures including denied `/bin/ps`; the native attempt had one
failure in unchanged `test_reap_failure_preserves_only_timeout_status` (hang subcase, missing `.term`
marker, line 237). That fixture uses a 0.3s deadline without a readiness wait; the result is recorded
as a failure, not attributed to this documentation-only change or counted as a pass. No further local
rerun was made; the coordinator must assess exact-head CI before merging.

This review corrects stale A3 implementation-plan/coverage/README summaries and current review-state
wording; no source/test change was needed. It preserves historical validation/handoffs and every
other workstream owner/status. The next owner/action is explicit in IMPLEMENTATION and HANDOFF-AUTH:
a permitted supported independently reviewed arbitrary-modulus type-30 DH backend/provider with
synthetic KATs, plus separate server and exact non-console UID/audit identity validation. A3 remains
active; all **10 F1 gates and 155 acceptance cases remain unverified**. The coordinator must confirm
CI for the exact final documentation head before merge; this reviewer neither merges nor enables auto-merge.


### Approved synthetic OpenSSL provider — 2026-11-14

This continuation follows explicit approval of the exact revised
`/private/tmp/sanjbox-a3-openssl-approval-proposal.md` and the claim in
[HANDOFF-PROVIDER](HANDOFF-PROVIDER.md), base `98a80af368bdc941a072a9496ef50f1666dc3211`.
It implements the provider and native worker, not a documentation-only replacement.
Source/test/script hashes and retained log hashes are in
[validation/provider-2026-11-14.json](validation/provider-2026-11-14.json); the coordinator
will attach the exact reviewed commit/hosted CI result separately. Fresh independent
final code review and hosted exact-head CI are **not claimed by this local record**.

Environment: arm64, macOS **27.2.1 (26B131)**, Xcode **27.2 (27B52)**, Swift **6.4.2**.
Package minimum remains macOS 27.0. No system install, Homebrew, private API, live RFB,
real credential, account, TCC, backup or system-setting operation was performed.
Downloaded source/build/cache trees remain outside Git; small records and the exact
upstream license are in A3. All data are synthetic. Socketpairs are local process IPC,
not live RFB transport or network listeners.

**Measured results:**

- Final native Debug and Release each passed **81/81 XCTest methods**, zero compiler
  warnings: 54 preserved parser/selection methods, 10 crypto methods and 17 provider/
  worker methods. The final added KAT passes explicit C NULL pointers with zero lengths.
- Five literal independent full-response/DH vectors matched at 1024/2048/4096 effective
  bits, including a backend-confirmed non-named RFC 2409 safe prime and redundant 129-byte
  wire padding. Generator 257, leading-zero public/shared values, empty/63/64/long/UTF-8/
  embedded-NUL fields, published RFC 1321 MD5 and NIST AES-ECB vectors passed. Regeneration
  via Python integer pow + public CommonCrypto reproduced fixture SHA-256
  `548a20e6aa5db57340ba27b557e714b20a488e077a10459559cb8c1d32bece94`.
- Real worker output decrypted to the synthetic fields using the independent system
  oracle; fresh calls differed. Composite/even/non-safe primes, invalid generator/peer,
  direct-DTO invalid bounds, staged backend/entropy failure and malformed frames failed
  closed. The normal constructor and worker protocol expose no deterministic key/RNG seam.
- Silent/partial/closed-output deadlines, cancellation before/during work, excess output,
  failed/early child exit, inherited/leaked descriptors, owned process-group cleanup,
  real FIFO rejection, leaf/ancestor ACL rejection, isolated ignored-SIGCHLD and
  SA_NOCLDWAIT rejection all passed. Fragmentation 1/7/127/full with the actual provider
  still ends at `unverifiedSessionIdentity` without initialization or framebuffer.
- **28/28 existing CLI scenarios** passed across Debug/Release: 52/224 generated bytes,
  network bytes 0, constant mock clearly labeled. These CLI scenarios are not crypto KATs.
- Final Release worker `otool -L` lists only system `libSystem`; there is no dynamically
  installed OpenSSL. `nm -g` has `ard_crypto_response` and no `ard_test_*` entry point.
  Static default-provider linkage can retain algorithms beyond the fixed interface;
  this symbol inspection is not a claim that known vulnerable code is absent.
- Script syntax/dry-runs passed. A separate owned tiny cleanup fixture passed dry-run,
  application, second idempotent application, log retention and symlink-root refusal.

Repository CI/progress/watchdog tools passed **98/98** in the CI-compatible native rerun;
the isolated-mode import failure remains recorded separately.

**Dependency recipe and CI measurement:**

The approved official archive hash
`603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a` matched before each extraction.
The first exact recipe in `/private/tmp/sanjbox-a3-openssl-3.5.9.Kq4m3h` passed 188 selected
upstream tests in 3m09.28s total, but defaulted to SDK deployment target 27.2. Its archive
SHA-256 is `3f0a377eea49c109d95a7bb96c2e8ee6ae67de0ccd57de58cc18405fb5b1745b`.
It is **not** evidence for the package's 27.0 minimum. The coordinator explicitly confirmed
adding `MACOSX_DEPLOYMENT_TARGET=27.0` to the sanitized environment; Configure options,
version and selected make/test commands were unchanged.

The fresh target-27.0 build in `/private/tmp/sanjbox-a3-openssl-3.5.9.EfHcSm` completed
in 2m59.75s; libcrypto SHA-256
`cec0408ea5f708f2d7aa5bb2ce31e6780e297f850f8f1118f0b7f151ec91aff7`.
The final clean CI-script rehearsal in `/private/tmp/sanjbox-a3-openssl-3.5.9.V7Ht2w`
completed provisioning in **145.30s**; archive SHA-256
`656762c0cf3d9b2cc9e94b78f007796315a1fec110e4713d60c264d874d2105c`.
Different local archive hashes are recorded; no byte-reproducible-build claim is made.
All three selected upstream runs passed **5 recipes / 188 tests**. The only reported
skip is the expected `00-prep_fipsmodule_cnf.t` prerequisite (not a FIPS build, NOTESTS);
DH/DH parameter/EVP/RAND recipes executed, with no unexpected skip or failure.

The clean rehearsal ran both commands with explicit pinned flags, including `swift build`
before tests: Debug build **7.88s**, test **9.29s**; Release build **7.32s**, test **12.30s**.
These runs had 80 methods; the subsequent explicit-NULL test raised the final count to 81,
which passed both modes. One clean CI matrix leg therefore measured about **162.5–164.9s**
locally before checkout/upload overhead. The existing **12-minute job budget** and 300s
Swift watchdog are retained. A separate exact watchdog/wrapper/`--xunit-output` invocation
passed; this Swift/Xcode XCTest path did not create the requested XML, so retained textual
XCTest logs are the local result evidence. Hosted CI has not run for this branch yet.

**Preserved failed attempts and early-review corrections:**

The first Swift compile failed on anonymous C-enum/Int32 switch typing and also emitted an
unused Swift wipe-result warning, with newer-deployment linker warnings from the original 27.2 archive.
Later provider runs exposed Foundation shortening `/private/tmp` to the `/tmp` symlink;
POSIX realpath now preserves the descriptor-checked canonical ancestry. A new ACL test
initially lacked the public membership declaration. The first Release attempt failed at
sandbox-denied `dsymutil`; its native rerun exposed the same abbreviation in test temporary
paths. Each failed log is retained independently, never counted as a pass. A repository
Python attempt used isolated mode and hid its own `tools` package; that failed log is
also separate from the CI-compatible rerun. No automatic approval rejection occurred.

Early independent review identified and the implementation corrected: (1) blocking FIFO
open before deadline, now metadata preclassification plus O_NONBLOCK/O_NOFOLLOW and a real
FIFO negative; (2) invalid-generator return before clearing a known-valid output extent,
now cleared before input guards; (3) mode bits alone missing extended ACL permissions,
now descriptor ACL entry/flag refusal for every ancestor and leaf; (4) ECHILD/PID reuse,
now no signalling after loss of ownership with explicit caller SIGCHLD/no-competing-reaper
contract; (5) late reaper allocation/thread failure, now standby capability reserved
before spawn. The empty-field memcpy review note is covered by guarded copies and the
explicit NULL KAT. Fresh final review remains separate from these early observations.

The operational limits are part of the result: same-UID worker replacement is not
attested; syscall progress is not a real-time kernel guarantee; exceptional cleanup
hands ownership to a pre-existing waiter and cannot promise kernel reap completion after
the caller exits or violates its reaper contract. Safe-prime/range policy makes no general
order-q claim. Swift String/Array copies prevent blanket erasure claims. The official
2026-11-10 five-Low advisory is outside the fixed intended DH/MD5/AES-ECB interface, not
proof of a vulnerability-free library. Full details are in [AUTH-PROVIDER](AUTH-PROVIDER.md).

A3 remains **in progress**. Server authentication/confidentiality, live compatibility
and expected non-console UID/audit identity remain independent unresolved requirements.
All 10 gates and 155 acceptance cases remain unverified; Screen Sharing.app/L1-D is unchanged.
Only the A3 COVERAGE row and explicitly approved A3 CI provisioning were changed outside
A3-owned implementation/docs. Historical validation entries above remain byte-preserved.


## Independent integration review of PR #84 after PR #83 — 2026-11-14

Fresh independent Astra xhigh review examined the complete #84 change against current
`origin/main` after #83 merged as `b18373730680762963945ff8a6af43a084683e91`.
The existing A3 worktree integrated that base with an ordinary merge,
`6ff8f2a06ce6577016740664394d6a196671026e`; there were no conflicts. The A6 source/docs
tree and its COVERAGE row are byte-identical to #83. Original implementation commits
`ba45e02` / `c324217`, authorship and all validation history above remain intact. The
root checkout was not modified. This review found **no actionable source defect**;
the follow-up commit updates the implementation plan, coverage summary and A3 handoff.

**Scope and approval evidence.** The reviewer read the exact retained
`/private/tmp/sanjbox-a3-openssl-approval-proposal.md`, compared its pin/recipe/limits to
HANDOFF-PROVIDER, provenance and scripts. The coordinator confirmed reproduction within
that recorded approval and the current integration assignment; the reviewer did not
independently recover the original approval conversation. The proposal's original
proposal-only header is historical; the
subsequent explicit approval is recorded in HANDOFF-PROVIDER. The current integration
assignment authorizes branch commits/push and PR maintenance; it does not expand the
approved foreign commands or permit live authentication. The already-confirmed 27.0
deployment-target setting is the only recorded recipe delta. No new dependency,
version, global installation, real credential or system/service operation was added.

**Fresh measured evidence on the integrated source:**

| Check | Result |
|---|---|
| Fresh official archive download/hash and approved Configure/make/test recipe | SHA-256 matched; **5 recipes / 188 upstream tests passed**; 194 seconds provisioning on this Mac |
| A3 `build` followed by watchdog-wrapped `test`, Debug and Release | **81/81 each**, no compiler/link warnings; selected upstream default-provider DH/EVP/RAND tests ran |
| Reviewer-owned Python integer `pow` + system CommonCrypto oracle | **150/150 checks** across all five literal vectors and two fresh production-worker calls per vector/configuration; DH public/shared bytes, original-width hash, AES bytes, truncation/NUL fields and fresh public keys matched |
| Existing fixture CLI, both configurations | **28/28 scenarios**, expected exits and empty stderr; demos remain constant mocks with 52/224 generated bytes and zero network bytes |
| Repository tools/progress/CI-selection/watchdog suite with documented import environment | **98/98 passed** |
| Worker linkage and symbol inspection, both configurations | `otool -L` lists only system `libSystem`; `ard_crypto_response` present, no `ard_test_*`, no OpenSSL/Homebrew dylib |
| Primary provenance and license | 12 recorded archive-source hashes matched; repository license byte-identical; official checksum/tag and pinned noVNC source hashes refreshed and matched |
| Provision/cleanup scripts and integration integrity | Shell syntax and provisioning dry-run passed; own tiny cleanup fixture passed dry-run, cleanup, repeated cleanup and log retention; #83 A6 tree/row and historical A3 validation preserved |

The fresh dependency root is `/private/tmp/sanjbox-a3-openssl-3.5.9.qwMhj7`;
reviewer harnesses, source responses and logs are retained at
`/private/tmp/pr84-final-review`. Environment remains arm64, macOS 27.2.1 (26B131),
Xcode 27.2 (27B52), Swift 6.4.2; all dependency/Swift commands target macOS 27.0.
The only selected-upstream prerequisite skip is the expected non-FIPS configuration;
all five selected recipes executed. Provisioning plus the A3 commands fits the unchanged
12-minute matrix budget. CI still provisions libcrypto **only** for `spikes/s1-rfb`;
unrelated packages retain the original build/test commands. The CI workflow change
selects every package, so hosted CI also rechecks the merged #83 package.

**Retained unsuccessful attempt.** The review first invoked the complete repository
suite with Python `-I`, which is not that suite's documented import environment: it
reported 54 discovered items, a `tools` import error, and a watchdog stopped-root fixture
that exited before writing its ready JSON. That run occurred during the dependency
build; this record does not infer a cause for the readiness failure. Its log remains
`repository-tools.log`. The subsequent normal native command, without `-I`, passed all
98 tests (`repository-tools-native.log`). The failed run is not a pass and has not been
deleted or folded into the successful count. Earlier implementation and review failure
evidence above remains unchanged.

**Review conclusions and limits.** Full EVP parameter checks validate supplied safe
primes; explicit public checks enforce the stated peer range, without a general
order-q membership claim. Original wire-width padding precedes MD5; AES-ECB has no
extra padding block. Deterministic key/padding seams are confined to the test-support
target. The one-shot runner bounds input/output/time, reserves exceptional cleanup
before spawn, owns only its child/group, refuses inherited unsupported SIGCHLD state,
and returns no partial response on failure. Same-UID executable replacement, later
caller reaper-contract violations and kernel scheduling remain documented limits.
The production-provider fragmented parser tests still fail at
`unverifiedSessionIdentity` with no initialized Apple framebuffer.

The official [2026-11-10 advisory](https://openssl-library.org/news/secadv/20261110.txt)
and [release listing](https://openssl-library.org/source/) were refreshed during this
review. The five Low issues still concern QUIC, AES-GCM-SIV and CMS/explicit EC; the
fixed DH/MD5/AES-ECB interface does not expose those operations. This is reachability
assessment, not a claim that static linkage removes every affected algorithm. The
advisory schedules fixed releases for 2026-12-01. The release tag still reports
`unknown_key`; verified signature and vulnerability-free claims remain absent.

**Coordinator handoff.** The previous green hosted checks at `c324217` are historical.
After the dedicated review/docs commit is pushed, the coordinator must inspect the
exact final PR head and its complete required CI before merge; the final head/run URLs
belong in the PR and closing review report, not a self-referential commit hash in this
file. This record itself does not claim that later hosted run or merge has completed.
No automerge was enabled by the reviewer.

A3 remains **partial / in progress**. The next owner remains janfiedler / Codex + Astra:
define trusted server identity and the expected non-console UID/audit-session source,
bind them to the specific connection, and specify independent positive/negative oracles
before proposing concrete live steps. Server trust, transport confidentiality/credential
handling, scheduled handshake wakeups and interoperability are not delivered here.
Keep the terminal identity refusal until those requirements are independently proved;
no crypto success, mask, username or grant may expose Apple pixels. A6 #83's same-process
read-only code identity does not supply that missing RFB/session oracle. All **10 gates
and 155 acceptance cases remain unverified**; Screen Sharing.app/L1-D remains independent.
