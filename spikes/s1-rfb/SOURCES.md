# WP1.A3 — primary sources and evidence boundaries

Initial access date for the original source set: **2026-11-03**; the added S4 DH support file is dated
separately below. The three original pinned S4/S5 raw files and
their SHA-256 values were independently rechecked on **2026-11-07**, **2026-11-13** and
**2026-11-14**. The latest independent review also fetched and hashed `session-select.js` (see S5).
S1–S3 were re-read on 2026-11-14 (Apple pages via direct HTTPS after the browser tool returned HTTP 429).
This is source research, not a
capture of a macOS server or a measurement. Exact source commits were resolved through the public
GitHub commits API and their raw files inspected over HTTPS. Moving branches/search excerpts are not the pinned evidence.
No downloaded code was executed, copied into Swift, linked, vendored, or installed.

## S1 — published RFB protocol

[RFC 6143, March 2011](https://www.rfc-editor.org/rfc/rfc6143.html), especially §§7.1–7.7 and Appendix A.
It is an **Informational RFC**, not an Apple extension specification. It defines version negotiation,
security negotiation, initialization, pixel format, update requests and Raw rectangles.
In 3.8, None authentication still receives SecurityResult; 3.3 and 3.7 differ. ClientInit's shared flag
governs coexistence of clients, not selection of a macOS user. Raw rectangles carry scanline pixels.

Decision for the standard policies: support only exact 3.8 and a bounded pixel-format/encoding subset;
reject 3.3/3.7 and unknown/Apple banners. The separate Apple fixture policy below accepts S5's banner
without claiming interoperability. The byte vectors and Swift parser were authored for this package;
no RFC code component was copied.

## S2 — Apple user-session semantics

[Apple: Choose how to control and observe in Remote Desktop](https://support.apple.com/da-dk/guide/remote-desktop/apd4f46319e/mac).
Apple distinguishes the visible user's desktop from the authenticated account's virtual desktop.
The documented virtual option lets another logged-in user continue working. If nobody is logged in,
or the authenticated account already owns the visible session, the documented behavior can share that
screen instead. This describes **Remote Desktop application behavior**, not the packets a custom client
should send, and not a universal guarantee for Screen Sharing.app, standard-user accounts, or macOS 27.x.

Consequence: “virtual requested” cannot be treated as proof of non-console identity. The required
positive UID/audit/bootstrap check is independent of RFB names, flags, success status or pixels.
This source does not prove three simultaneous accelerated sessions or persistence after disconnect.

## S3 — High Performance is a separate constraint

[Apple: Screen sharing type options, macOS 27](https://support.apple.com/en-ie/guide/mac-help/mchl1883115d/27/mac/27)
documents at most **one High Performance session per Mac**. It also describes Standard and High
Performance modes. This is not proof that three standard user sessions work, nor proof they cannot work.

[Apple: Share the screen of another Mac](https://support.apple.com/en-gb/guide/mac-help/mh14066/mac)
describes one/two configurable virtual **displays** for High Performance, including display layout and
resolution. Do not conflate those virtual monitors with the **authenticated user desktop** in S2.
The latter is the session-isolation hypothesis in PLAN; neither page is evidence that S1 passed.

## S4 — primary implementation of ARD authentication

Upstream **noVNC v1.6.0**, commit `a8dfd6a3ea3c74244f5ebdaa5a7f1023007a7820`:

- [core/rfb.js](https://github.com/novnc/noVNC/blob/a8dfd6a3ea3c74244f5ebdaa5a7f1023007a7820/core/rfb.js),
  `_negotiateARDAuth` and `_negotiateARDAuthAsync` (lines 1798–1866 in the inspected raw file).
- [core/crypto/dh.js](https://github.com/novnc/noVNC/blob/a8dfd6a3ea3c74244f5ebdaa5a7f1023007a7820/core/crypto/dh.js#L36-L47),
  inspected on 2026-11-13: `_generateKey` exports a public key padded to the modulus byte width.
- [License](https://github.com/novnc/noVNC/blob/a8dfd6a3ea3c74244f5ebdaa5a7f1023007a7820/LICENSE.txt):
  core library MPL-2.0; consulted only, no implementation reuse.

This client reads a two-byte DH generator, two-byte key length, then modulus and server public key of
that length. It derives a DH shared value, hashes it with MD5 and encrypts a 128-byte credential block
with AES-ECB. The block has two 64-byte fields with UTF-8 data truncated to 63 bytes plus NUL and random
padding. It sends encrypted bytes and the client public key, then awaits SecurityResult. The provider
seam therefore requires exactly `128 + keyLength` response bytes; this checks framing, not crypto.

That is evidence of **noVNC's implementation**, not an Apple specification, endorsement of this crypto,
authenticated server identity, or proof of full-session encryption. It does not establish user-session
selection. A production implementation needs a separate security review and interoperability evidence;
hand-rolled crypto or silently using legacy VNC/None is not an acceptable substitute here.

Raw `core/rfb.js` SHA-256: `563a8c8469dfb55d1deee05262a311637d0e6fe8f65ae34c8222ee22e34e8a93`.
Raw `core/crypto/dh.js` SHA-256: `9102454282ba646ee4a4ce34c5db5d2a9979179f9d4606737fc6bb7a669e5ebe`.

## S5 — original-author implementation lead for Apple selection

**peetinc/noVNC-ARD**, commit `d699293635083c9e0c30c8f9480993865653772a`:

- [ard/ard-patch.js](https://github.com/peetinc/noVNC-ARD/blob/d699293635083c9e0c30c8f9480993865653772a/ard/ard-patch.js):
  `_initMsg`, `_negotiateServerInit`, `_ardSessionSelect` (selection at lines 776–875).
- [ard/ard-constants.js](https://github.com/peetinc/noVNC-ARD/blob/d699293635083c9e0c30c8f9480993865653772a/ard/ard-constants.js)
  and [ard/session-select.js](https://github.com/peetinc/noVNC-ARD/blob/d699293635083c9e0c30c8f9480993865653772a/ard/session-select.js).
- [License](https://github.com/peetinc/noVNC-ARD/blob/d699293635083c9e0c30c8f9480993865653772a/LICENSE): MPL-2.0;
  no implementation or cryptography reused.

The original author's code provides a concrete research lead: Apple banner handling, ClientInit `0xC1`,
extended ServerInit metadata, then SessionInfo / a client choice / SessionResult. Its constants assign
command 1 to console and 2 to virtual desktop, with pending and granted states. It also contains a type-33
RSA tunnel path; type 30 is not necessarily the whole Apple authentication surface.

The pinned implementation also contains concrete byte layouts, not just session semantics:

| Element | Pinned evidence in S5 |
|---|---|
| Banner `RFB 003.889\n` | [Detection at line 131](https://github.com/peetinc/noVNC-ARD/blob/d699293635083c9e0c30c8f9480993865653772a/ard/ard-patch.js#L124-L131) and [exact response at line 214](https://github.com/peetinc/noVNC-ARD/blob/d699293635083c9e0c30c8f9480993865653772a/ard/ard-patch.js#L207-L218) |
| ClientInit `0xC1`, commands console `1` / virtual `2`, result codes | [ard-constants.js lines 75–97](https://github.com/peetinc/noVNC-ARD/blob/d699293635083c9e0c30c8f9480993865653772a/ard/ard-constants.js#L75-L97): granted `0`/`4`, pending `2`/`3` |
| Extended ServerInit | [ard-patch.js lines 331–348](https://github.com/peetinc/noVNC-ARD/blob/d699293635083c9e0c30c8f9480993865653772a/ard/ard-patch.js#L331-L348): marker, flags and capability bitmap inside the name field |
| SessionInfo | [ard-patch.js lines 779–797](https://github.com/peetinc/noVNC-ARD/blob/d699293635083c9e0c30c8f9480993865653772a/ard/ard-patch.js#L779-L797): u16 body length, u16 version, u32 allowed-command mask, u32 reserved, username bytes |
| SessionCommand (client choice) | [ard-patch.js lines 2510–2523](https://github.com/peetinc/noVNC-ARD/blob/d699293635083c9e0c30c8f9480993865653772a/ard/ard-patch.js#L2510-L2523): 74-byte record with length, version, padding, command and 64-byte username |
| SessionResult | [ard-patch.js lines 839–867](https://github.com/peetinc/noVNC-ARD/blob/d699293635083c9e0c30c8f9480993865653772a/ard/ard-patch.js#L839-L867): u16 body length, u16 version, u32 status and remaining reserved bytes |

These are **client-side implementation claims**, not a verified server contract. The package implements
their records and now integrates command/result only under an explicit synthetic local policy. The
pinned [`ard/session-select.js` lines 13–47](https://github.com/peetinc/noVNC-ARD/blob/d699293635083c9e0c30c8f9480993865653772a/ard/session-select.js#L13-L47)
was fetched by the prior independent review on 2026-11-14. Its comment describes one bit per command,
and its console branch tests `1 << sessionCmdConnectToConsole` when the console username is empty.
Its virtual branch returns command 2 **without testing the mask**. The follow-up does not copy that
bypass: the explicit local policy requires bit `1 << 2` and rejects bits outside commands 0/1/2.
This uses the documented bit convention as a conservative condition for **fixture output**, not proof
that a server will honor it or return a non-console session. Default policy still refuses every mask.
Grant handling always stops at the independent identity boundary; no Apple pixels are exposed.

Raw SHA-256 values:

| File | SHA-256 |
|---|---|
| `ard/ard-patch.js` | `bef0c7b6c88639d555815487e48dcecdcd8362dcee20eb258f70ad397c7164d5` |
| `ard/ard-constants.js` | `8c107d8939f74867c84d5708a9706c2226654cf0ceb59c5633bf4f87a03f9474` |
| `ard/session-select.js` | `f1cd6c49be4cfa28849d52f7646424251e76b5d4c4cf342afcc31e43e934dcf4` |

## Implementation boundary — 2026-11-14

The implementation used four hash-verified raw files from the prior review's local cache. The fresh
integration review fetched those four files directly over HTTPS and confirmed their hashes, then
fetched, inspected and hashed the fifth file, `ard/session-select.js`. This supersedes the earlier
local availability gap recorded in HANDOFF-AUTH/VALIDATION; it does not supply server authorization
or identity evidence. This follow-up re-read all five local cached files and reproduced every hash
above without an outbound fetch. No upstream code was executed, copied, linked, vendored or installed. The Swift
codecs are independently authored from the record descriptions.

### Source-backed records

- Banner and ClientInit remain exactly as S5. S4 challenge framing/response-width check is unchanged;
  at this selection-only milestone cryptography was absent behind the mock provider seam.
  The later approved offline provider in S6/[AUTH-PROVIDER](AUTH-PROVIDER.md) supplies that implementation.
- Extended ServerInit: at least 22 name bytes, byte 0 is NUL (byte 1 unrestricted), flags at 2…5,
  16-byte capability bitmap at 6…21. S5 `ard-constants.js` names flags observe 1, may-control 2,
  session-select 4 and no-virtual-display 8. The bitmap and name are not identity evidence.
- SessionInfo: u16 body length excludes itself; u16 version, u32 allowed commands, four opaque
  reserved bytes, remaining console username bytes. First NUL terminates the username; an absent
  terminator means all remaining bytes, as in S5. Empty username payload is accepted by S5.
- SessionCommand: exactly 74 bytes: u16 body length 72, u16 version 1, four zero padding bytes,
  u8 command, one zero padding byte, 64-byte NUL-padded username. The internal encoder only writes
  command 2. S5 first maps incoming username bytes to Latin-1 code units, then UTF-8 encodes the
  resulting string and truncates to 63 bytes, potentially splitting a multibyte sequence. The codec
  matches that behavior; it does not substitute the credential username or assert session identity.
- SessionResult: u16 body length, u16 version, u32 status, then opaque reserved remainder. The source
  comment says 74 reserved bytes, but its parser uses `bodySize - 6`. Our decoder accepts bounded
  variable reserved length, not an invented fixed-size requirement. Status 0/4 = granted, 2/3 =
  pending, everything else = denied (S5 constants and the status branch).

### Local conservative policy, not Apple claims

- Incoming records must use version 1. S5's writer fixes version 1, while its input parser reads but
  does not validate version; this prototype deliberately refuses other versions.
- Body length must exactly match the supplied record, with no trailing bytes; SessionInfo >=10,
  SessionResult >=6; maximum 4096 for either. ServerInit name also has the existing 4096-byte budget.
- Unknown ServerInit flag bits fail. Missing session-select or set no-virtual-display means
  unavailable. Capability bitmap and reserved bytes remain opaque and are not required to be zero.
- The default `.rejectAll` policy still raises `unverifiedSelectionPolicy` for every mask.
  Explicit `.syntheticVirtualOnly` requires virtual bit 2 and rejects all bits outside `0x07`;
  therefore only masks 4/5/6/7 authorize **local synthetic command generation**. This requirement,
  rejection of unknown bits and no-console fallback are local rules, not claims about Apple servers.
- An accepted Info emits exactly one command 2; result 2/3 waits without resend, 0/4 records
  `.grantedUnverified` and fails with `unverifiedSessionIdentity`; all other statuses deny terminally.
  No mask, username, capability, result or apparent pixels substitute for independently checked
  expected UID/audit session. S2's visible-screen sharing behavior remains an explicit blocker.
- One shared 1024-message budget counts Info, every result and standard server messages. Pending
  cannot reset it. The fixed 30s total result deadline starts at command creation, uses monotonic
  `ContinuousClock`, rejects backwards fixture times, and never resets on partial/pending input.
  Silence requires caller wakeups (`receive([])`/`expire()`); there is no autonomous timer.
- Removed package-local kinds/count/availability/outcome bytes are no longer a supported wire path.

### Still unimplemented

Type-33 RSA tunnel, server authentication, transport confidentiality/wakeup scheduling,
live interoperability and independent UID/audit session binding. The scoped public SDK
investigation remains in [AUTH-BACKEND](AUTH-BACKEND.md). The subsequent user-approved
OpenSSL provider is described in [AUTH-PROVIDER](AUTH-PROVIDER.md); no custom runtime
bignum or private API was introduced. The integrated selection work retains its
[review #81](VALIDATION.md#integration-review-and-plan-handoff-for-pr-81--2026-11-14).
A3 remains in progress: working synthetic crypto never substitutes for independently
validated server and exact non-console UID/audit identity before any Apple surface.

## Research outcome

The inspected Apple pages establish application-level choices and the High Performance limit. The
pinned clients establish concrete candidate byte contracts, now partly implemented offline. We did
not locate an Apple-published byte-level specification in those sources. No live interoperability,
server identity or exact user-session binding follows from these records. [README](README.md) lists
the bounded remaining work; [LAB-NEXT](LAB-NEXT.md) preserves the independent laboratory requirements.


## S6 — approved OpenSSL 3.5.9 public backend and independent fixtures

The official [release archive](https://github.com/openssl/openssl/releases/download/openssl-3.5.9/openssl-3.5.9.tar.gz)
was downloaded only after explicit approval and checked against SHA-256
`603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a` before extraction.
[Provenance](openssl-provenance.json) records tag `d0ca66a1abe52545f14eca635c648932fcde5615`,
commit `45e844fa2a14ec92d146bd8f5778ac130b6625fb`, recipe and exact license hash. The official
API reported tag signature `unknown_key`; no verified-signature claim is made.

Primary source paths below are pinned to that commit. Read-only source hashes are retained
with local validation records; only the upstream license, not implementation source, is copied here.

| Primary source | Supported claim |
|---|---|
| [EVP_PKEY_fromdata](https://github.com/openssl/openssl/blob/45e844fa2a14ec92d146bd8f5778ac130b6625fb/doc/man3/EVP_PKEY_fromdata.pod) | Public parameter/key import using OSSL_PARAM; the shim avoids native-endian BN ambiguity via BN_bin2bn and OSSL_PARAM_BLD |
| [DH API/checks](https://github.com/openssl/openssl/blob/45e844fa2a14ec92d146bd8f5778ac130b6625fb/doc/man7/EVP_PKEY-DH.pod), [dh_check.c](https://github.com/openssl/openssl/blob/45e844fa2a14ec92d146bd8f5778ac130b6625fb/crypto/dh/dh_check.c) | Full parameter check; absent q validates p and (p−1)/2; quick check is insufficient |
| [ffc_key_validate.c](https://github.com/openssl/openssl/blob/45e844fa2a14ec92d146bd8f5778ac130b6625fb/crypto/ffc/ffc_key_validate.c) | Absent-q peer range check; no general y^q=1 guarantee |
| [DH exchange](https://github.com/openssl/openssl/blob/45e844fa2a14ec92d146bd8f5778ac130b6625fb/doc/man7/EVP_KEYEXCH-DH.pod), [dh_exch.c](https://github.com/openssl/openssl/blob/45e844fa2a14ec92d146bd8f5778ac130b6625fb/providers/implementations/exchange/dh_exch.c) | pad=1 pads to effective modulus width; the shim separately restores original S4 wire width |
| [RFC 2409 §6.2](https://www.rfc-editor.org/rfc/rfc2409.html#section-6.2) | Published 1024-bit safe-prime fixture, not recognized as a named group by this backend |
| [RFC 3526 §§3,5](https://www.rfc-editor.org/rfc/rfc3526.html) | Published 2048/4096-bit fixtures; no invented primality claim from a custom generator |
| [RFC 1321 test suite](https://www.rfc-editor.org/rfc/rfc1321.html#appendix-A.5), [NIST SP800-38A](https://csrc.nist.gov/pubs/sp/800/38/a/final) | Independent literal MD5 and AES-128-ECB primitive vectors |
| [2026-11-10 advisory](https://openssl-library.org/news/secadv/20261110.txt), [release lifecycle](https://openssl-library.org/source/) | Known Low issues and scheduled fixes; 3.5 LTS support, not a vulnerability-free claim |

Five full-response literals use Python integer pow as a fixture-only DH oracle and a
repository-authored helper calling system public CommonCrypto for MD5/AES. Neither loads
OpenSSL. The checked-in fixture hash and recipe results are in [VALIDATION](VALIDATION.md).
S4's UTF-8 prefix is 63 bytes, followed by NUL, preserving bytes after embedded NUL in
that prefix; credentials are not interpreted as C strings before encrypting the block.
Darwin ACL semantics (`acl_get_entry`: entry=0, empty=-1/EINVAL) and spawn/wait/descriptor
interfaces are from the current public macOS SDK, with own-file/child negative tests.
