# WP1.A3 — primary sources and evidence boundaries

Initial access date for the original source set: **2026-11-03**; the added S4 DH support file is dated
separately below. The three original pinned S4/S5 raw files and
their SHA-256 values were independently rechecked on **2026-11-07** and **2026-11-13**. S1–S3 were
also re-read on 2026-11-13 (Apple pages via direct HTTPS after the browser tool returned HTTP 429).
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

These are **client-side implementation claims**, not a verified server contract. Validation of framing,
capability bits, allowed commands, encryption, cancel/retry semantics, failure behavior and version
compatibility remains open. Do not copy this client's automatic choice policy into Sanďbox: an unavailable
virtual choice must fail, not choose the console. This prototype deliberately does **not implement S5's
selection records or extended ServerInit parsing**. Its selection bytes use the simplified package-local
fixture framing below. That is a scope choice despite the available client implementation evidence;
no real endpoint may ever receive these fixture messages.
The lead narrows future investigation; it does not establish a working or safe Apple client.

Raw SHA-256 values:

| File | SHA-256 |
|---|---|
| `ard/ard-patch.js` | `bef0c7b6c88639d555815487e48dcecdcd8362dcee20eb258f70ad397c7164d5` |
| `ard/ard-constants.js` | `8c107d8939f74867c84d5708a9706c2226654cf0ceb59c5633bf4f87a03f9474` |

## Implementation boundary

The package separates two layers so that no fixture byte is read as an Apple claim. The code side of this
boundary is `Sources/RFBProtocol/AppleSubset.swift`; the behaviour side is `RFBClient` under
`AuthenticationPolicy.syntheticAppleSubset`, which is a fixture policy and not an authentication mode.

### (a) Implemented fixture subset

Everything below is reachable only under the fixture policy. S4 supplies the challenge framing; S5
supplies the banner and selected constants/semantics. The selection message layout and local budgets
are deliberately authored for this package, separate from S5's records above.

| Element | Constant / state | Basis |
|---|---|---|
| Message kinds `1` SessionInfo, `2` SessionInfoChoice, `3` SessionResult | `sessionInfoKind`, `sessionInfoChoiceKind`, `sessionResultKind` | package-local kinds; deliberately different from S5's length-prefixed records |
| Availability flag `0` unavailable, `1` available | `unavailableState`, `availableState` | package-local availability byte; S5 instead parses an allowed-command mask |
| SessionResult outcomes `0` granted, `1` denied, `2` pending | `outcomeGranted`, `outcomeDenied`, `outcomePending` | package-local one-byte outcomes; S5 uses u32 statuses including additional granted/pending values |
| Candidate Apple banner `RFB 003.889\n` | `appleBanner` | exact literal in S5 `ard-patch.js` line 214; source-verified, not server-verified; default policy rejects it |
| Bounds 512-byte key length, 4096-byte credential response, 8 SessionInfo entries | `Limits.appleKeyBytes`, `appleCredentialBytes`, `appleSessionChoices` | package-local research budgets, NOT values from S4/S5 |
| Console command `1`, virtual-desktop command `2`; ClientInit `0xC1` | `consoleCommand`, `virtualDesktopCommand`, `appleClientInit` | exact constants in S5 `ard-constants.js` lines 78, 90–91; the surrounding selection record remains package-local |
| Type-30 challenge framing: u16 generator, u16 key length, modulus, server public key; the provider answer must have exactly `128 + keyLength` bytes | parser states `appleChallengeHeader` / `appleModulus` / `appleServerKey` | S4 framing only; no key agreement, hash or cipher exists |
| The rule that only an *available* virtual desktop may be chosen, that a pending result never retries, and that no message ever selects the console | client state machine | package policy derived from S5's failure leads, not an Apple guarantee |

### (b) Not implemented and not claimed

- S5's byte layouts for SessionInfo / SessionCommand / SessionResult and extended ServerInit metadata.
  The pinned client implements them, but this package deliberately models only simplified selection
  messages. Neither these fixtures nor the source inspection verifies a live Apple server contract.
- The S4 DH / MD5 / AES credential exchange, the 128-byte encrypted block and the client public key. Only
  the empty `AppleCredentialProvider` seam exists: with no provider the handshake stops before a
  credential response or ClientInit is sent (banner/type negotiation can precede it), and the provider
  used by the tests and the demo is a labelled mock with constant bytes.
- The type-33 RSA tunnel, type-30 key agreement, server identity, transport confidentiality, any socket,
  TLS, network I/O, live macOS-server interoperability and the binding of a surface to an exact audit
  session.

## Research outcome

The reviewed Apple pages establish application-level choices and the HP limit. The pinned open-source
clients establish candidate authentication and selection implementations worth studying. **We did not
locate an Apple-published byte-level contract for these extensions in the reviewed sources.** This is a
scoped finding, not a claim that none exists anywhere. There is enough evidence to avoid guessing that
standard shared=1 or successful auth selects the right user. There is not enough local evidence to
enable Apple credentials, the proprietary selection path or a live viewer in this package.

Implementation work is restricted to the standard RFB fixture parser and the Apple fixture subset in
(a). S5's selection records are not implemented, and no live Apple wire compatibility is claimed.
Follow-up requires the separate identity, crypto/transport, capability/failure and laboratory work in
[LAB-NEXT.md](LAB-NEXT.md).
