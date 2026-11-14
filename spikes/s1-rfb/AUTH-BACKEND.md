# WP1.A3 — type-30 backend decision, 2026-11-14

> Historical SDK-only decision before the explicit dependency exception. The subsequent
> approved OpenSSL 3.5.9 implementation, independent KATs and remaining limits are in
> [AUTH-PROVIDER](AUTH-PROVIDER.md). The original finding below is preserved.

**No provider was added.** The missing piece is a selected, reviewed public backend for the
peer-supplied finite-field DH parameters in [S4](SOURCES.md#s4--primary-implementation-of-ard-authentication).
MD5 and AES alone cannot close that gap. This is a scoped finding on this Mac's SDK, not proof
that no suitable backend exists. A3 remains in progress; no cryptographic known-answer test is
claimed for the constant provider mock.

This continuation used local SDK headers/interfaces and the previous review's cached primary
sources. It made no source fetch, dependency installation, network connection to an RFB server,
credential access, private API call, account or system change. No upstream code was copied or run.

## Required operation and evidence

The five S4/S5 cached source hashes were reproduced against [SOURCES](SOURCES.md). In pinned
`rfb.js:1822–1860`, S4 accepts a u16 generator plus modulus and peer public value of the stated
byte width. It performs finite-field DH, exports a width-padded public value, hashes the equally
padded shared value with MD5, and AES-ECB encrypts exactly 128 bytes without adding a padding block.
Two NUL-terminated, at-most-63-byte UTF-8 fields occupy the random-filled 64-byte halves. In pinned
`dh.js:36–47` and `:50–55`, the public/shared values are padded to the modulus width. This is a
client implementation claim, not server authentication, transport encryption or Apple endorsement.

The current parser validates only framing and provider response width (`128 + keyLength`). It
does **not** establish DH group validity, primality, subgroup order, peer-key validity, constant-time
operations, RNG behavior or secret erasure. Those must belong to the backend design and its review;
feeding an arbitrary modulus to a generic big-integer primitive is not a defensible substitute.

## Local public API inspection

Environment: arm64, macOS 27.2.1 (26B131), Xcode 27.2 (27B52), Swift 6.4.2.
SDK root returned by `xcrun --show-sdk-path`:
`/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk`.
Paths below are relative to that SDK. Headers were read only; none were copied into the package.

| Candidate | Observed API and scope | Decision |
|---|---|---|
| `usr/include/CommonCrypto/` | Public umbrella/modules expose symmetric ciphers, digests, MAC, KDF and key wrapping. `CommonCryptor.h:154,620` supplies ECB and `CCCrypt`; `CommonDigest.h:142` declares deprecated `CC_MD5`. No public `CCDH`/`CCBigNum` header/API was found in this directory. | Symmetric/digest pieces are available, but no established arbitrary-modulus DH path. Do not use private CommonCrypto declarations. |
| `Security.framework/Headers/SecKey.h` | `SecKeyCopyKeyExchangeResult` at line 1570 is generic by algorithm; the inspected DH algorithms at 1240–1340 are ECDH. Lines 1255–1257 explicitly limit the raw standard exchange to ECSECPrimeRandom keys and accept no parameters. | EC agreement cannot replace S4's supplied finite-field generator/modulus. No compatible modern SecKey path was established. |
| `CryptoKit.framework/Modules/CryptoKit.swiftmodule/arm64e-apple-macos.swiftinterface` | `DiffieHellmanKeyAgreement` is a protocol (line 532); concrete public agreement families are Curve25519 and P256/P384/P521. `Insecure.MD5` exists (line 572). No supplied-prime finite-field agreement implementation was identified. | A protocol named Diffie-Hellman is not evidence of the required operation. No compatible backend established. |
| `Security.framework/Headers/cssmtype.h`, `cssmapi.h` | `CSSM_ALGID_DH` exists (`cssmtype.h:824`). Both headers explicitly deprecate CDSA from macOS 10.7 and advise developers not to use it, while saying APIs continue to work. | This research does not claim DH is absent from all public headers. These legacy declarations were not exercised or selected as a supported new backend. |
| External backend | `Package.swift` has no external dependency or approved finite-field DH binding. | An installed executable or an available library would not alone establish an approved, reviewed product dependency. No package, subprocess-crypto adapter or vendor source was introduced. |

SHA-256 of the exact inspected API files:

| File | SHA-256 |
|---|---|
| `usr/include/CommonCrypto/CommonCrypto.h` | `48bea992addd7bbb6e628b4acabe9d6575283893c83191b8f88172854e7e8db3` |
| `usr/include/CommonCrypto/CommonCryptor.h` | `2574c3a96ad3619f723823a24056678d2a7785cd30c7992481cbca0d134066a9` |
| `usr/include/CommonCrypto/CommonDigest.h` | `83a9705bbc8d44f27ee61801064ee99288496a038d623f152aa30db6819e9ca6` |
| `System/Library/Frameworks/Security.framework/Headers/SecKey.h` | `2cba3b0d904c00560c1f7d4d7efb163d75a1aa941bb40b7ef851723806f6d3a0` |
| `System/Library/Frameworks/Security.framework/Headers/cssmtype.h` | `647032d694ed3fd7aa394106ae1054f9ab384beb634f1f69efa2e4e094be4f56` |
| `System/Library/Frameworks/Security.framework/Headers/cssmapi.h` | `a34f84feaa56376657d0ff436756464a4d58962b7679dbcbb7b2c123e2b4fc3f` |
| `System/Library/Frameworks/CryptoKit.framework/Modules/CryptoKit.swiftmodule/arm64e-apple-macos.swiftinterface` | `fd6795bbc2ba434a0a3b23acb665173b011a34decb3b5eee078ab94ba4574d36` |

## Exact unblocking condition

A continuation must select and independently review a maintained, permitted backend with documented
arbitrary-group DH support, parameter/public-key validation, bounded work and safe randomness/secret
handling. If it requires a dependency exception, approve that concrete dependency first under GUIDE.
Pin its provenance/version/license and API contract, then use independent synthetic known-answer
vectors for DH public/shared width (including leading zeros), MD5, AES-ECB/no-padding, credential
field boundaries/random-padding injection, malformed group/public values and backend failures.
All values must remain synthetic; fixture-only deterministic randomness must not become a live default.

A3's current follow-up advances its original completion condition by integrating the actual S5
command/result flow. It still cannot satisfy Apple auth with synthetic credentials while the backend
is absent. Another documentation-only or generic-mock follow-up would not resolve this blocker.
Server identity/confidentiality and exact UID/audit-session binding remain separate requirements in
[LAB-NEXT](LAB-NEXT.md); even working crypto would not authorize live use or Apple framebuffer exposure.
