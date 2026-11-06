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

D3/OAuth zůstává mock. D4 redirect corpus není tímto adaptérem integrován do D2; existující
D2 redirect testy zůstávají vlastním důkazem gateway balíku. S5/D7/L5, pf cesta/identity,
F0.7, skutečné registry a výkon ≤1,1× jsou nadále neověřené.
