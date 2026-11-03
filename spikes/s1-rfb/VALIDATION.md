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
