# WP1.C1 network provenance — validace 2026-11-06

Měřený a nezávisle reviewovaný source commit:
`ba339392df85f0798ba66b9f4842735558467646`, čistý výchozí main
`2a15fc2608a04b3cf06ba676810ffe69edae3982`. Následný dokumentační commit odstranil
jen nadbytečný prázdný řádek na konci `Identity.swift`; nemění měřený runtime.
Historické C1/common/C3 důkazy zůstávají zachované.

[Nový uzavřený záznam](provenance-validation/20261106-host-arm64-ba33939/environment.json)
je **host diagnostika**, nikoli S1 testarea či L4 slot. Vývojářský alias
`janfiedler-Codex-Astra`, strojový alias `host-arm64-20261106`, macOS 27.2 (26B123),
arm64, Xcode 27.2 (27B52), Swift 6.4.2. Neobsahuje username/hostname/serial ani
skutečná tajemství. Host UID/GID/audit/window metadata jsou výslovná číselná očekávání,
nikoli přepsaná identita testovací oblasti. `preparedUTC: 2026-11-06T08:11:26Z`.

| Kontrola | Výsledek a rozsah |
|---|---|
| common native Release | 32/32 = 7 nových XCTest + 25 stávajících Swift Testing. |
| C1 native Release | 11/11 = 5 partial/error sender XCTest + 6 stávajících testů. |
| C3 native Release | 50/50; původní strict parser beze změny. |
| C3 offline CLI | 25/25, 0 skips, bez identity/network/smoke. |
| Vlastní signed host runner | [11/11](provenance-validation/20261106-host-arm64-ba33939/loopback/results.json), přesná preregistrace a independent raw. |
| Doplňkové offline CLI | [4/4](provenance-validation/20261106-host-arm64-ba33939/offline-cli/results.json): actual ne-hardened executable odmítnut před target, duplicate/unknown target odmítnut, default dry-run bez output journalu. |
| Čerstvé nezávislé Astra review | [Bez P0–P2](provenance-validation/20261106-host-arm64-ba33939/review/review.json); vlastní 32/11/50 unit testy, vlastní signed 11/11 a 11 dalších nezávislých kontrol, 21 raw references. |

Nové testy skutečně měří podepsané ad-hoc hardened kopie obou native binárek,
`codesign --verify --strict` a self Security preflight prošly. Signing nebyl Personal
Team/self-signed certifikátový test a nedává S8 verdikt. Signer žádné entitlementy
nepřidával. Ne-hardened negativ použil vlastní původní build, bez tvorby GTA fixture.

Čtyři pozitivní případy mají každý **169 B** v sender `sent.bin` i nezávislém
receiver `received-1.bin`, shodný SHA-256, run/flow/challenge a navzájem obrácené
skutečné `local`/`remote` endpointy:

| Transport | Sender local | Receiver local |
|---|---|---|
| TCP IPv4 | 127.0.0.1:53421 | 127.0.0.1:53420 |
| UDP IPv4 | 127.0.0.1:52823 | 127.0.0.1:49170 |
| TCP IPv6 | [::1]:53425 | [::1]:53424 |
| UDP IPv6 | [::1]:64561 | [::1]:58474 |

Tyto shody jsou odvozené z obou raw, nikoli z úspěšného sendu. Receiver je samostatný
native proces. Adversarial Python injekce jsou ve vstupu označené `pythonFixture`:
zero/wrong nonce/replay/foreign run/malformed/truncated UDP, split a zero TCP,
500ms stalled TCP, contact limit, SIGTERM během otevřeného TCP a odmítnutý connect
na vlastním bound-but-not-listening socketu. SIGTERM ponechal 35B raw prefix a žádný
`receiverStopped`. Refused connect zachoval 0 accepted bytes a žádný observed remote.
Chybné/truncated/limitované operace mají očekávanou neúplnost, nepřejmenovávají se na
úspěšné přenosy ani důkaz izolace. Samotné testové kontroly této neúplnosti prošly.

Implementátor použil čerstvý vlastní build root
`/private/tmp/sanjbox-network-build-l4rXZ9`, izolované `TMPDIR`, module/cache paths
se scratch `common`, `c1`, `c3`; `swift test -c release --build-system native
--disable-sandbox`. Plné legacy common regression testy používají vlastní ephemeral
`::` dual-stack listenery se syntetickými klienty pouze `127.0.0.1`; legacy self-capture
test čte vlastní identitu. Jejich zavřené fixtures nejsou novým exact-bind měřením.
Nový host runner používá výhradně exact `127.0.0.1` a `::1` a nic nemění v pf/settings.

Nezávislému reviewerovi první sandboxovaný common pokus odmítl čtyři staré bind testy
a self-membership dotaz (EPERM). Následný autorizovaný běh celé stejné sady prošel;
původní failure nebyl smazán ani vydáván za produktové selhání. [Review record](provenance-validation/20261106-host-arm64-ba33939/review/review.json)
rozlišuje tuto historii. Publikované derivative logy anonymizují pouze absolutní
worktree/home prefix; exact původní hashe a mapování jsou uložené vedle nich.

Všechny vlastní runner subprocessy byly reaped a sockety uzavřené. Malé raw původně
zůstaly v `/private/tmp/sanjbox-network-validation-2ce6cf77-1630-4d7b-a3b0-34bd0d22beee`
a v jednotlivých exclusive producer outputech; kopie v tomto záznamu mají ověřené
původní manifesty. Reviewer má samostatný běh `3c634a9d-7fa7-40cb-bc15-c7fc5ea95d38`.
Úklid se týká jen našich velkých build/cache podadresářů; [cleanup receipt](provenance-validation/20261106-host-arm64-ba33939/cleanup.json)
uvádí přesný seznam. Raw a logy zůstávají, nic se nemaže podle globálního prefixu.

**Beze změny: 0/10 bran a 0/155 akceptačních případů ověřeno.** TestArea relace,
controlled external/LAN protistrana, peer autentizace, packet/capture completeness,
clock calibration, ochranný mechanismus, S3/S3b/L4 a nový C3 adapter nejsou tímto
host během ověřené. Obsahové hashe a review JSON nejsou kryptografickou atestací původu.
