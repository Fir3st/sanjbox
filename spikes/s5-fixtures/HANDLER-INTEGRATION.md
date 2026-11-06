# D4 → skutečný D2 npm handler (2026-11-06)

`Tests/SanjboxGatewayFixturesTests/NPMHandlerAdapter.swift` propojuje původní katalog
`ArtifactScenario.standard()` se skutečným `NPMGateway.response(to:)`. Adaptér přijímá jen
`ArtifactInput`, nikdy `expected`. Pozorování vzniká z odpovědi handleru, jeho
`downloadRecords()`, zachycených upstream HTTP request/response bytes a výstupu vlastního
npm procesu. `RegistryMock.refuse` v této integraci není použitý.

**Matice 40 má 28 matched, 12 incomplete, 0 mismatched.** To je výsledek místní syntetické
integrace; 42/42 úspěšných testů neznamená 40/40 plně doložených scénářů ani prošlou S5/L5.
[Validační záznam](VALIDATION-HANDLER.md) odlišuje obě počítadla.

## Přístupové cesty

| Cesta | Počet | Měřené kroky | matched / incomplete / mismatched |
|---|---:|---|---|
| directURL | 8 | Přímé volání skutečného handleru, bez předchozího packument requestu klienta | 4 / 4 / 0 |
| gatewayCache | 8 | Skutečný způsobilý seed download, pak obnovení metadat scénáře a další handler request | 4 / 4 / 0 |
| lockfileCI | 8 | Skutečný `npm ci`, D1 loopback listener, D2 handler, vlastní lockfile v3 a prázdná klientská cache | 4 / 4 / 0 |
| clientCache | 8 | Vlastní `npm cache add <seed.tgz> --offline`, pak `npm ci --offline` a kontrola instalovaného manifestu | 8 / 0 / 0 |
| localImport | 8 | Vlastní `npm install --offline --package-lock=false <import.tgz>` v novém projektu, kontrola manifestu | 8 / 0 / 0 |

Všechny npm příkazy mají `--ignore-scripts --no-audit --no-fund`, vypnuté retries a update
notifier. Spouští se pouze předem zvolené existující Node/npm, žádná instalace nástrojů nebo
cizích balíčků. Každý scénář má samostatný UUID projekt, HOME, cache, prefix, TMP a prázdné
user/global npmrc; environment podprocesu je úplně nahrazený. Runner čte jen dvě explicitní
opt-in proměnné pro cesty k nástrojům. Podproces je mimo MainActor, deadline 15 s, fetch 5 s,
výstup max. 64 KiB; cancellation/timeout ukončí vlastní proces.

Klientská cache/import nemají handler, upstream ani audit aktivitu. Dokládají úspěšnou
lokální instalaci vlastní inertní fixture mimo síťovou kontrolu, nikoli zákaz instalace.
Manifesty obsahují pouze name/version, archivy mají jen package.json a README; žádný
spustitelný kód či lifecycle script.

## Testový seam a hranice měření

Knihovna `SanjboxGatewayFixtures` nadále importuje veřejné API. Jen test target používá
`@testable import SanjboxGatewayCore`: existující interní inicializátory hodin a upstream
dialeru/connection, interní konstruktor `HTTPRequest`. Žádný soubor `s5-gateway` ani `common`
se nemění. SwiftPM `swift test -c release` tento import sestaví bez přidaných unsafe flags.
Neexistuje nové veřejné API pro vypnutí DNS/SSRF/TLS.

Hodiny jsou pevné `2026-01-01T00:00:00Z`, cooldown 604800 s. Mock DNS vrátí policy-povolenou
adresu pouze jako data, reálný `DestinationPolicy` ji ověří; testový dialer nevytváří žádný
upstream socket. `UpstreamClient` skutečně serializuje request a parsuje syntetickou HTTP
odpověď po 257B částech. Přesný hostname, raw target, no-cache metadata headers, pořadí,
metadata/artefaktové bytes a celý download record mají samostatné testové assertions.
Nedokládá se živé DNS/TLS/registry nebo nezávislá protistrana.

Adaptér uchovává seed a následné pozorování odděleně. Seed jde přes normální handler se
způsobilým publish-time za stejných hodin; žádný interní setter cache neexistuje. Pro již
způsobilou verzi zůstává datum stejné, jinak seed metadata použijí přesnou hranici cooldownu.
Potom se vrátí skutečná vstupní metadata, včetně mladého či chybějícího data. Každý seed má
200, shodné skutečné bytes, upstream sled metadata → tarball → metadata a `cached=false`.
Způsobilý opakovaný request má dvě čerstvá metadata čtení, nula tarball fetchů a `cached=true`.
Mladé/neznámé datum vrátí 403 po prvním novém metadata requestu, bez artefaktu/auditu.

Přímá volání handleru a cache seed mají audit `prepared`; adaptér **nevolá** completion
callback a nevydává ho za odeslání. Skutečný GatewayServer pro npm zachová původní callback
a zapisuje `transportAccepted`; adaptér má omezené čekání na tuto změnu. To je potvrzení
lokálního transportu, nikoli obecný důkaz přijetí či instalace klientem. U npm je instalovaný
manifest a exit status doložen zvlášť.

## Nerozlišitelná 403 a negativní kontroly

D2 používá stejné `403 {"error":403}\n` pro cooldown, chybějící datum a další příčiny.
Adaptér proto vrací `.denied(.other)`. Verifier nejdřív kontroluje cestu, počet požadavků,
status 403, přesné povolené tělo a nulový download audit; až potom vrátí
`incomplete("denial reason not observable")`. Skutečné cause nevymýšlí z očekávání ani
z fixture publish-time. Původní explicitní `.cooldown`/`.unknownDate` verifier mocky zůstávají.

Dvanáct incomplete výsledků je šest mladých a šest bez data, přes tři síťové cesty a oba
názvy. Všechny skutečně odmítly vydání; nedoložená část je konkrétní diagnostická příčina.
Varianty s uniklým celým/částečným artefaktem, chybným statusem či auditem vracejí mismatch,
nikoli incomplete. Další kontroly ověřují:

- Posun pevných hodin o sekundu skutečně povolí dříve mladou verzi; nezměněný oracle to
  označí jako mismatch, takže adaptér nemůže jen opsat očekávání.
- Poškozené upstream archive bytes neprojdou skutečnou SRI kontrolou; metadata změněná po
  fetchi nevedou k vydání ani auditu. Očekávaná delivery v obou případech zůstane mismatch.
- Chyba transportu a upstream HTTP 503 vyústí ve skutečnou 502 a mismatch i pro scénář
  očekávající refusal; zrušení handleru zůstane vyhozené `CancellationError`.
- Filter packumentu pro oba názvy vydá jen 1.0.0 a přesnou hranici 1.1.0, odstraní neplatný
  latest tag a přepíše tarball URL; nesprávný lokální exit/manifest zneplatní receipt.

## Doplněk: původní redirect korpus přes D2

`RedirectHandlerAdapter.swift` a `RedirectHandlerIntegrationTests.swift` v témže test targetu
přidávají **12 nových testových metod**. Přímo spotřebují `response` všech šesti existujících
`RedirectFixture.standard`; předchozí D2 testy z `s5-gateway` se nepřesouvají ani nezapočítávají
jako nové. Adaptér přijímá pouze finite HTTP/DNS/interface skripty a request, nikdy očekávání.
Hodiny, inertní archivy a existující interní clock/dialer API zůstávají stejné.

| Původní fixture | Pozorovaná odpověď | DNS / dial | Nový audit |
|---|---|---|---|
| cdn | 200, přesné archive bytes a SHA-512 | 5 / 5 | 1 `prepared` |
| same-host-rebinding | 502, přesné generické chybové tělo | 4 / 3 | 0 |
| loopback | 403, přesné generické chybové tělo | 2 / 2 | 0 |
| downgrade | 403, přesné generické chybové tělo | 2 / 2 | 0 |
| userinfo | 403, přesné generické chybové tělo | 2 / 2 | 0 |
| unapproved-origin | 403, přesné generické chybové tělo | 2 / 2 | 0 |

Rebinding fixture vrátí při čtvrtém lookupu loopback adresu. V záznamu je její nové DNS
vyhodnocení a nový snapshot, ale žádný čtvrtý dial. `DestinationFailure` handler mapuje na
502; měření ji nepřejmenovává na 403 ani na diagnostický důvod odmítnutí. Čtyři nepovolené
URL se odmítnou ještě před další metadata/DNS operací. Pozitivní kontrola stejného hostname
se scoped balíčkem a střídajícími se povolenými DNS adresami vrátí 200.

Journal pořadí zapisuje DNS pokus a odpověď, snapshot, skutečně předaný `ApprovedDestination`,
start, serializované request bytes, vrácené response chunks a cancel. Každý DNS a interface
skript musí být úplně spotřebován; každé spojení musí přečíst všechny odpovědní bytes a být
zavřeno. Přebytečné nebo chybné pokusy se zapisují před kontrolou a zneplatní spotřebu skriptu,
i když je handler převede na generickou chybu. Assertions porovnají **celý** observed sled,
přesné host/port/adresy, request headers/target i fragmenty skutečné HTTP odpovědi.
Log navíc zachová request bytes v base64 a SHA-256 každého přijatého fragmentu, počítaný z
pozorovaných bytes. Testový dialer nevytváří socket; veřejné DNS adresy jsou pouze data.

Další kontroly pokrývají šest druhů zakázaných DNS odpovědí a adresu, která se stala lokální,
čerstvá metadata před cílovým hopem a po jeho fetchi (mladé/chybějící/změněné datum, změněný
původ a digest), poškozený CDN archiv, redirect seed a cache hit se dvěma reautorizacemi,
nový cooldown/unknown-date zákaz v obou cache autorizačních bodech a změněný cache digest,
který vynutí nový fetch a nevydá staré bytes. Audit při odmítnutí nepřibude; dřívější audit
seedu zůstává nezměněný. Přesné chybové tělo vylučuje i částečné vydání archivu.

Smyčka je ukončena před opakovaným dialem; limity 0, 1 a 3 mají odmítací i úspěšnou kontrolu
přesně na hranici. Výsledek určuje počet spotřebovaných přechodů, nikoli timeout nebo retries.
Cizí auth/cookie/range hlavičky skončí před prvním DNS; ostatní klientské hlavičky nejsou
přeneseny na registry ani CDN. Negativní kontroly seamů odmítnou nevyužitý/chybný skript a
změna vstupních odpovědních bytes skutečně změní výsledek handleru.

Přímé nové requesty dokládají jen `prepared`; adaptér completion callback nevolá. Původní npm
loopback regresní testy nadále samostatně dokládají `transportAccepted`. Generická 403/502
neprozrazuje důvod; pozorování používá `.denied(.other)`. **Původní matice 40 zůstává
28 matched / 12 incomplete / 0 mismatched**, bez nového tvrzení o plné akceptaci.
Nový zdrojový commit, běhy, přesné počty a hashe: [VALIDATION-REDIRECT.md](VALIDATION-REDIRECT.md).

D3/OAuth zůstává mock. S5/D7/L5, pf cesta/identity, F0.7, skutečné registry a výkon ≤1,1×
jsou nadále neověřené. Ani nové lokální redirect testy nejsou verdiktem brány.
