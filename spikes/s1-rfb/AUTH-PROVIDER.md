# WP1.A3 — synthetic type-30 provider

This is an explicit **offline-only** implementation of S4's credential response,
using the user-approved OpenSSL **3.5.9 `libcrypto`** dependency. It is not a live
Apple client, server authentication, transport confidentiality or session identity.
A3 remains in progress. Every grant still fails with `unverifiedSessionIdentity`,
without an Apple framebuffer or a console fallback. Historical SDK findings remain
in [AUTH-BACKEND](AUTH-BACKEND.md); approval scope is in [HANDOFF-PROVIDER](HANDOFF-PROVIDER.md).

## Dependency and public API boundary

[openssl-provenance.json](openssl-provenance.json) pins archive, digest, source commit,
recipe and license. No Swift package dependency or installed OpenSSL is searched for.
The repository owns only a thin C adapter, process boundary, fixtures and orchestration;
all production cryptography is provided by the public OpenSSL API. Downloaded source,
archives, binaries and caches stay in an owned `/private/tmp` tree, outside Git.

`CArdCrypto` imports unsigned big-endian wire values with `BN_bin2bn`, then builds
public `OSSL_PARAM` values for `EVP_PKEY_fromdata`. It uses the built-in default provider
in a private library context, with automatic OpenSSL configuration loading disabled.
It performs full `EVP_PKEY_param_check`, explicit `EVP_PKEY_public_check`, fresh
`EVP_PKEY_generate` per response, and `EVP_PKEY_derive` with `pad=1`. There is no
private API, custom modular exponentiation or fallback crypto in the runtime.
Headers and the runtime version must both equal the approved 3.5.9 pin.

Local policy is **1024–4096 effective modulus bits, 128–512 wire bytes**, equal-width
peer value and generator greater than one. The Swift provider checks these even for
directly constructed `AppleDHChallenge` values; the worker/C adapter checks again.
The existing raw challenge DTO and parser retain smaller framing mocks, which the
real provider refuses. The 1024-bit floor is synthetic legacy research, not a live
security recommendation. Full checking accepts only safe primes: both `p` and
`(p−1)/2` must be prime. Backend recognition of a known group is allowed, but the
adapter never substitutes a named group or uses the weaker quick check.

Type 30 supplies no `q`. On the non-named path the pinned provider checks
`2 ≤ y ≤ p−2`; it does **not** establish `y^q = 1` or order-`q` membership. For a
safe prime, accepted values may have order `q` or `2q`. The same exclusion of trivial
generator values does not establish a particular subgroup. The backend can infer
parameters for recognized groups; the general guarantee remains the conservative
range guarantee above. Non-safe-prime Apple parameters are intentionally refused.
Live compatibility and SP800-56A full-validation claims do not follow.

The client public value is exported at the original wire width. EVP's shared secret
is first padded to effective modulus width, then left-zero-padded to original wire
width **before MD5**. The 128-byte credential plaintext begins as backend random
bytes; each 64-byte half receives the first 63 UTF-8 bytes plus NUL. This preserves
S4's bytes after embedded NUL and can split a UTF-8 sequence. AES-128-ECB has padding
disabled and emits exactly 128 bytes, followed by the public value. These legacy
algorithms reproduce S4; they do not add server authentication or transport encryption.

C cleans its shared secret, digest, plaintext and temporary cipher buffers and frees
backend objects on every path; a valid-sized output is zeroed on error. Swift
`String`/`Array` creation may leave copies, and stored synthetic input arrays outlive
one call. Best-effort wiping of the final request is **not** a blanket secret-erasure
claim. Only explicitly synthetic fixture inputs are supported; no Keychain, credential
loader, environment credential or credential CLI argument exists.

## One-shot worker and deadline

`SyntheticAppleCredentialProvider` has an ordinary constructor accepting an explicit
local worker URL and named synthetic username/password strings. It cannot accept
deterministic randomness, private exponents or padding. Each operation launches
`sanjbox-ard-worker --synthetic-stdio-v1`; all input is a bounded binary stdin frame.
The deterministic branch is compiled only into `CArdCryptoTestSupport`, never into
the production worker. The internal short-deadline constructor is test-only.

| Frame | Exact layout (big-endian u16) |
|---|---|
| Request | `A3D1, generator, width, usernameLength, passwordLength, p, y, username, password`, then EOF; ≤1162 bytes |
| Response | `A3R1, status, length, payload`, then EOF and exit 0; ≤648 bytes |
| Success | status 0, payload exactly `128 + wireWidth` |
| Failure | status 1…4, length 0, no payload; other codes/lengths fail closed |

The parent uses a local `AF_UNIX` socketpair as a bidirectional pipe; it creates no
network listener or network transport. Writes/reads are nonblocking, stderr is
`/dev/null`, and inherited descriptors are closed by spawn policy. Output is accepted
only after exact framing, EOF and successful child exit. Output overflow, early exit,
partial output, malformed status/length and cancellation return no response.

A monotonic **10-second total operation deadline** is checked around launch and
through writes, computation, reads and exit. Expiry/cancellation signals only the
owned child/process group, then allows at most one second for synchronous reap.
The cleanup state and a standby reaper thread are reserved **before spawn**; failure
to reserve refuses before creating a child. If the one-second reap cannot finish,
the operation returns `cleanupFailed` and hands its still-owned child to that already
created thread. It does not silently discard ownership. Reap completion after that
exceptional handoff depends on kernel progress and continued caller process lifetime.
This is a bounded user-space boundary, not a guarantee that the kernel schedules
filesystem/spawn syscalls within a fixed time under failure or system suspension.

**Caller contract:** throughout the operation, keep `SIGCHLD=SIG_DFL`, no
`SA_NOCLDWAIT`, and no competing `wait`/child reaper. The initial disposition check
cannot stop a later caller change. `waitid(...WNOWAIT)` retains the PID until cleanup
under this contract; `ECHILD` loses ownership and must never cause a signal to a
possibly reused PID/group. A later disposition change fails closed without signalling;
the standby waiter cannot guarantee termination when the caller violates this contract.
This provider is a synchronous offline fixture component, not a generic process library.

Worker paths use POSIX `realpath` followed by descriptor-based ancestry checks.
Every checked ancestor/leaf rejects extended ACL entries/flags, symlinks, unexpected
owners and group/other-write permissions; root-owned sticky temporary directories
are the sole writable-ancestor exception. FIFO/device leaves are refused by metadata
before nonblocking open, and the open leaf's device/inode must match. The parent
directory stays pinned for `posix_spawn`'s `fchdir`/relative executable lookup.
The worker must be in the user's trusted local build tree. These checks constrain
other UIDs; they do **not** attest content or protect against same-UID replacement
between check and exec. Do not point this interface at untrusted build products.

## Independent fixtures and failures

Five literal vectors in `Tests/RFBProtocolTests/Fixtures/type30-vectors.json` cover
1024/2048/4096 bits, 129-byte redundant wire padding, generator 257, leading-zero
public/shared values, empty/63/64/long/UTF-8/NUL fields and exact response order.
`tools/generate-auth-vectors.py` uses published RFC primes and Python integer `pow`
only as a fixture oracle. Public system CommonCrypto independently computes MD5/AES;
the generator never loads OpenSSL and is not imported by runtime code. Tests read
the checked-in literal bytes, not expectations generated by the implementation.

RFC 2409's 1024-bit second Oakley group is deliberately **not** an OpenSSL named DH
group: tests query the imported backend key to prove the non-named path. RFC 3526's
2048/4096-bit groups also exercise recognized paths. Separate RFC 1321 MD5 and NIST
SP800-38A AES-ECB known answers check the primitives. This demonstrates supplied safe
prime support; it is not coverage of every prime or a side-channel/RNG-quality audit.

Negative tests include composite/even/non-safe/minimum-bound violations, peer
0/1/p−1/p, generator 0/1, staged backend/entropy failures, output clearing, direct
challenge bypass attempts, malformed request/response frames, timeouts, cancellation,
FIFO paths, ACL-bearing leaf/ancestor, ignored SIGCHLD/SA_NOCLDWAIT in isolated children,
descriptor inheritance/leaks and owned descendant cleanup. Fragmented real-provider
parser transcripts still terminate on the unverified-identity grant. The old demo
continues to label its constant provider as a mock.

## Reproduction, CI and cleanup

**[implementátor]** The explicit dependency exception covers this pinned recipe only.
No install is performed. Scripts default to dry-run; to reproduce the approved scope:

```bash
/bin/bash spikes/s1-rfb/scripts/provision-openssl.sh
/bin/bash spikes/s1-rfb/scripts/provision-openssl.sh --apply > /private/tmp/a3-root-record.txt
a3_root=$(cat /private/tmp/a3-root-record.txt)
for a3_mode in debug release; do
  /bin/bash spikes/s1-rfb/scripts/swift-with-openssl.sh --apply "$a3_root" "$a3_mode" build
  /bin/bash spikes/s1-rfb/scripts/swift-with-openssl.sh --apply "$a3_root" "$a3_mode" test
done
```

The provisioning script creates one unique owner-only tree, records its original
state, downloads over HTTPS, verifies the literal SHA-256 before extraction, and runs
the approved out-of-tree Configure/make/test commands in a sanitized environment.
`MACOSX_DEPLOYMENT_TARGET=27.0` matches the unchanged package minimum. Configure enables
neither shared/dynamic provider modules nor legacy provider. Upstream test prerequisites
may build libssl/tools, but A3 links only the exact `libcrypto.a`, with explicit include
and link flags on **both build and test**. There is no Homebrew/system fallback or cache
reuse across provenance roots. The test wrapper verifies the recorded archive hash.

CI provisions only `spikes/s1-rfb` in its existing arm64 macOS 27 Debug/Release matrix
legs. Each leg builds from a clean source download, preserves dependency logs even
on failure, then uses the same wrapper for build/test and the existing test watchdog.
The overall 12-minute job budget remains unchanged; local measurements and hosted CI
status are separate in [VALIDATION](VALIDATION.md). Unrelated package commands are unchanged.

Retain logs and failed attempts for review. After final review, run the cleanup
script without `--apply` first, then with it on **that recorded owned root**. It
validates owner/type/mode and the root marker, removes only named source/build/cache
children, and retains logs/state. It is idempotent and refuses changed ownership or
symlink roots. Temporary file fixtures remove their own files/ACLs. No accounts,
TCC settings, services or system installations need restoration.

## Advisory and distribution limits

The official [2026-11-10 advisory](https://openssl-library.org/news/secadv/20261110.txt)
affects 3.5.9 with five Low issues: two QUIC, two AES-GCM-SIV, and CMS encryption of
malformed explicit EC parameters. The fixed runtime interface accepts only bounded
DH values and MD5/AES-128-ECB; it exposes none of those affected operations. Static
libcrypto/default-provider linkage may retain other algorithms in the binary, so
this is an **interface reachability assessment**, not proof of absent vulnerable
symbols or a vulnerability-free dependency. Upstream synthetic EVP tests have a
broader algorithm surface. The advisory schedules patched releases for 2026-12-01;
no unreleased 3.5.10 version or unapproved patch is substituted. Recheck the advisory
before any new dependency update/live-use proposal; an interface-reachable new issue
requires reassessment. There is no FIPS-validation claim.

OpenSSL 3.5 is maintained LTS through 2030-04-08. Preserve its exact Apache-2.0
[LICENSE.txt](licenses/OpenSSL-LICENSE.txt), copyright and applicable notices when
distributing a linked binary. This spike changes no OpenSSL source. The pin, official
archive and public source paths are documented in [SOURCES](SOURCES.md).
