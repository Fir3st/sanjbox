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
