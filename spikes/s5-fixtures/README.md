# S5 — fixtures a mocky (WP1.D4)

Samostatný Swift 6 balík nad `../s5-gateway`. Knihovna používá veřejné D1 API; testy navíc
volají skutečný D2 npm handler přes [testový adaptér](HANDLER-INTEGRATION.md). Bez externích
balíčků a bez kopie D2/D3 implementace. **Hotové D4 není prošlá brána S5.**
Všech 155 případů COVERAGE i všechny brány zůstávají Neověřeno.

## Co se skutečně ověřuje

| Vrstva | Výstup a oracle | Co tím není doložené |
|---|---|---|
| D1 veřejné API | `DestinationPolicy`, `UpstreamClient` na odmítnutých cílech, parsery HTTP a `TypedRouter`; konkrétní chyby a úplná spotřeba skriptu DNS/interface odpovědí | Živé DNS, TLS/dial po úspěšném schválení, automatické následování redirectu nebo pf cesta |
| Vlastní fixtures | 8 reprodukovatelných `.tgz`, metadata, lockfile v3, 40 očekávání vydání artefaktu, 6 redirect odpovědí | Implementace cooldownu, filtr packumentu, důvěryhodný původ metadat |
| Vlastní OAuth model | 15 scénářů explicitně mockované identity, scopes, účtu, zdroje, expirace/revokace a oblasti | Skutečné OAuth, ověření tokenu, transportní autentizace oblasti, uživatelský důkaz scopes |
| Volitelný skutečný npm | Čtení vlastního lockfilu a tarballu přes D1 loopback listener, reakce na mock 403, neplatný lockfile, offline klientská cache | D2 handler, zákaz instalací, provoz v izolované oblasti, npm/pnpm/yarn kompatibilita obecně |
| Skutečný D2 handler | Testový adaptér: metadata, přímé URL, cache reautorizace, skutečný npm lockfile/cache/import; 40 scénářů: **28 matched, 12 incomplete, 0 mismatched** | Důvod generické 403 nepozorovatelný; synthetic upstream, žádný živý registry/TLS ani verdikt S5/L5 |

Mapování přípravy: R3/R8 a **GW-01…09, GW-12…13, GW-15** (jen relevantní části).
Číslování v [COVERAGE](../../docs/COVERAGE.md) zůstává autoritativní. Nenahrazuje D7/L5,
scopes uživatele ani nezávislou protistranu WP0.4. Není výkonovým měřením GW-20/PERF-01.

## Deterministický katalog

Hodiny jsou pevně `2026-01-01T00:00:00Z`; fixture cooldown = **604800 s**. Jde o testovací
parametr, nikoli změnu produktové politiky. Katalog obsahuje `fixture-bead` a `@fixture/bead`:

| Verze | Publish time (UTC) | Očekávání síťového vydání |
|---|---|---|
| 1.0.0 | 2025-12-24 23:59:59 | vydat — o sekundu starší než hranice |
| 1.1.0 | 2025-12-25 00:00:00 | vydat — přesně na hranici |
| 1.2.0 | 2025-12-25 00:00:01 | odmítnout — o sekundu mladší |
| 1.3.0 | chybí `time[version]` | odmítnout — neznámé datum |

Inkluzivní hraniční očekávání je explicitní fixture kontrakt `age >= cooldown`. Obsah JSON
vzniká z typovaných Swift struktur přes encoder se seřazenými klíči. Neexistuje loader externího
scenario JSON s neznámými či duplicitními klíči. Konstruktor katalogu odmítá duplicitní package/version;
grant odmítá duplicitní scopes/resources. Testovací gramatika názvů/verzí je úmyslně užší než npm.

`SyntheticArtifact` vytvoří pouze `package/package.json` (name/version) a `package/README.txt`.
Žádné skripty, spustitelný kód, závislosti, binárky, symlinky nebo host soubory. Ustar má pevné
UID/GID/mtime = 0, mode 0644, gzip pevnou hlavičku a uložený DEFLATE blok. Každý standardní
tarball má 3095 B; SHA-512 SRI je nad skutečnými bajty. Nezávislý Python stdlib vektor pro
`fixture-bead@1.0.0` má SHA-256
`dce3d65c3651022ed0e18156a097796099d5b5b88eeecb86f60271b21e2e1621`.
Postup reprodukce a zdroje: [SOURCES.md](SOURCES.md).

Upstream cesta a gateway cesta jsou oddělené:

```text
upstreamPackumentTarget: /@fixture%2fbead
upstreamTarballTarget:   /@fixture/bead/-/bead-1.2.0.tgz
packumentTarget:         /npm/@fixture%2fbead
tarballTarget:           /npm/@fixture/bead/-/bead-1.2.0.tgz
```

`FixtureOrigin.upstream` používá `https://registry.fixture.invalid` bez `/npm`;
`.cdn` používá `https://cdn.fixture.invalid`. Jsou to pouze inertní metadata, nikdo na ně
nespojuje. `.loopback(port:)` generuje `http://127.0.0.1:<port>/npm/...` pro vlastní mock server.
Testový adaptér mapuje registry resource → typed gateway mount; žádný upstream socket neotevírá.

## Použití knihovny a kontrakt adaptéru

```swift
let fixtures = try RegistryFixtures.standard()
let key = try PackageKey(name: "@fixture/bead", version: "1.2.0")
let metadata = try fixtures.packument(name: key.name) // nefiltrovaný upstream
let project = try fixtures.project(key: key, origin: .loopback(port: 12345))
let scenarios = try ArtifactScenario.standard()
```

`RegistryMock` lze připojit přes `mock.route` do D1 `TypedRouter`/`GatewayServer`; po otevření
dočasného portu nastav `configure(origin:)`. Mock vydá **všechny** verze včetně nových/neznámých.
`refuse:` je výslovné naprogramování 403 pro test klienta; **není rozhodnutí cooldown policy**.
Mock zaznamenává metodu, přesný raw target, status a počet bajtů. Při overflow odmítne vydat
úplný transcript, aby ztracené požadavky nevypadaly jako nulové kontakty.

D2 testový adaptér předává do `ArtifactHarness.run(scenarios, observe:)` async closure přijímající
jen `ArtifactInput`, nikoli expected výsledek. Musí zavolat skutečný handler, shromáždit odpovědi
a audit z nezávislých testovacích hooků, uzavřít pozorování a vrátit `ArtifactObservation`.
Nesmí vracet expected hodnoty jako pozorování. Konstruktor výsledku používá jeden enum outcome,
nikoli současné booleany allowed/denied. Verifier přijímá **právě jeden terminální požadavek
klient → brána na tarball**, s pořadovým číslem 0 a správným endpointem. Jakýkoli další
exchange nebo packument target odmítne, i s 403 či prázdným tělem; žádné tělo neignoruje.
Pro vydání vyžaduje shodné bajty a jeden download audit; při odmítnutí 403, žádný download
audit a prázdné tělo nebo přesné D1 error tělo.
Neznámé odmítnutí `.other` nenahrazuje cooldown/unknown-date očekávání: po kontrole
statusu/těla/auditu vrátí `incomplete("denial reason not observable")`. Vadný status, únik
bajtů či audit zůstane `mismatched`; nedostupná diagnostika nesmí skrýt counterexample.

Samotný HTTP trace nedokládá přístupovou cestu. `accessEvidence` je ve výchozím stavu
`.unverified` a výsledek pak zůstává incomplete. Adaptér musí dodat odpovídající variantu:
direct URL, lockfile CI, cache brány, klientská cache nebo lokální import. Pro CI se porovná
skutečný manifest i lockfile s přesnými vygenerovanými vstupy, loopback origin a exit status
npm. Pro cache brány jsou potřeba shodné seed bajty a pozorovaných nula upstream fetchů
artefaktu. Přímé stažení proto samo nemůže projít scénářem cache či CI. Údaje mají přijít
z instrumentace skutečného běhu; jejich pravost knihovna neautentizuje. Nové varianty
`clientCacheInstallation` / `localImportInstallation` ověřují také exit 0 a skutečně
nainstalovaný manifest; původní jednodušší varianty zůstávají pro verifier/mock testy.

40 scénářů = 8 artefaktů × direct URL, lockfile CI, cache brány, klientská cache, lokální import.
První tři cesty mají 24 očekávání vydání/odmítnutí; poslední dvě 16 očekávání
`outsideNetworkControl`, s nulovým provozem a auditem brány. **To netvrdí, že se instalace
nestala nebo že je zakázaná.** Cache brány musí znovu projít artefaktovou kontrolou; klientská
cache/import je hranice síťového enforcementu podle PLAN.

Verifier ověřuje omezený kontrakt koncového vydání. Packument nebo upstream trace se do něj
nesmí skrýt ani přimíchat; musí mít samostatný oracle skutečného adaptéru. Neověřuje sám
filtr metadat, správnost metadata provenance, TLS, redirect chain nebo autenticitu pozorovatele.
`complete` je příznak testovací instrumentace, nikoli kryptografický důkaz. Adaptér musí mít
vlastní timeout a spolupracovat na cancellation.

`ScriptedResolver` a `ScriptedHostAddresses` mají konečný scénář bez fallbacku na poslední
odpověď. `assertConsumed()` odhalí chybějící, nadbytečné i nesprávné dotazy. Veřejné IP v těchto
scénářích jsou pouze data pro policy; testy k nim nevytvářejí sockety. Redirect corpus dodává
HTTP 302 + Location pro CDN, stejný hostname/rebinding, loopback, downgrade, userinfo a cizí origin.
D1 parser pouze čte metadata; rozhodnutí o přechodu na CDN/nový origin musí ověřit D2.

OAuth model má vlastní vymyšlené názvy scopes `repo:read`, `repo:write`, `account:admin`.
Nejsou smlouvou žádného poskytovatele. Mock identity se předává z testu odděleně; `claimedZone`
je nedůvěryhodné tvrzení a nepřihlašuje volajícího. Chybějící principal je odmítnut i s platně
vypadající zone claim. Stejný provider s jiným účtem, jiná oblast, široký grant/zdroje a passthrough
na stejném hostname se odmítnou. Reálné zdroje identity a granty F0.7 zůstávají nepodporované.

## Limity

| Vstup / operace | Limit |
|---|---|
| Katalog / jednotlivý tar payload | 32 unikátních artefaktů / 65535 B |
| Názvový segment / celkový název / verze | 80 B / 160 B / tři číselné části po max. 4 číslicích |
| DNS/interface skript / adresy v kroku | 32 kroků / 16 adres |
| Registry transcript | výchozí 64, max. 256 požadavků; overflow zneplatní transcript |
| Scénáře adaptéru / exchanges / audit | 128 / 64 / 32 |
| Tělo pozorování / součet response bodies / target | 64 KiB / 1 MiB / 512 B |
| CI manifest/lockfile nebo cache seed v accessEvidence | každý max. 64 KiB |
| Mock scopes/resources | každé max. 16, bez duplicit |
| npm podproces | 15 s, fetch timeout 5 s, retry 0; čtení diagnostiky max. 64 KiB |

Čas/velikost výstupního souboru npm se kontroluje každých 20 ms; není to tvrdá OS disková kvóta.
Při timeout/cancellation se ukončí konkrétní vlastní podproces a dočká se jeho konce.
Žádný fixture skript neinstaluje nástroje ani nemění host služby.

## Sestavení a testy [implementátor]

Apple Silicon + Swift 6.x / Xcode 27.x dle GUIDE. Standardní spuštění:

```bash
swift test --package-path spikes/s5-fixtures
```

**38** testů nepotřebuje npm ani listenery. Další **4** jsou ve výchozím stavu výslovně skipped.
Testový D2 adaptér používá `@testable import SanjboxGatewayCore` pouze pro existující
interní clock/dialer seam; SwiftPM Release sestavení je ověřené. Knihovna nadále používá
veřejný import. Nevzniklo veřejné nastavení pro vypnutí SSRF/TLS; podrobnosti a limity
jsou v [HANDLER-INTEGRATION.md](HANDLER-INTEGRATION.md).

Pro izolované build/cache adresáře v tomto pracovním prostředí byl použit příkaz:

```bash
env CLANG_MODULE_CACHE_PATH=/private/tmp/sanjbox-d4-clang-cache \
  SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/sanjbox-d4-module-cache \
  swift test --disable-sandbox --package-path spikes/s5-fixtures \
  --scratch-path /private/tmp/sanjbox-d4-debug-build \
  --cache-path /private/tmp/sanjbox-d4-swift-cache \
  --config-path /private/tmp/sanjbox-d4-swift-config \
  --security-path /private/tmp/sanjbox-d4-swift-security
```

`--disable-sandbox` zde řeší zákaz vnořeného SwiftPM `sandbox-exec`; nemění systémové sandboxy.
V prostředí, které vnořený SwiftPM sandbox podporuje, jej vynech. Síťově omezený tool sandbox
může zvlášť odmítnout loopback bind; není to výsledek bezpečnostní brány.

Volitelné npm testy vyžadují explicitně zvolené existující binárky. Historický běh
2026-11-03 použil **Node v26.12.1**, **npm 11.20.0**, Swift 6.4, arm64 macOS 27.2.
Nová [validace 2026-11-06](VALIDATION-HANDLER.md) uvádí aktuálně ověřené cesty/verze. K výše uvedenému
`env` lze přidat následující dvě proměnné (nebo spustit přímo):

```bash
env SANJBOX_FIXTURE_NODE=/opt/homebrew/Cellar/node/26.12.1/bin/node \
  SANJBOX_FIXTURE_NPM_CLI=/opt/homebrew/lib/node_modules/npm/bin/npm-cli.js \
  swift test --package-path spikes/s5-fixtures --filter NPMCompatibilityTests
```

Na jiném stroji nejdřív zvol/verifikuj své instalované cesty; testy neprovádějí autodetekci,
instalaci ani `npx`/`npm exec`. Podproces spouští přímo Node s npm CLI, žádný shell.
Pro každý test vzniká nový soukromý UUID adresář s prázdným HOME, user/global npmrc,
cache, prefixem, TMP a projektem. Environment je úplně nahrazený; žádné ambientní
auth, proxy, `NODE_OPTIONS`, scoped registry ani uživatelská npm nastavení. Registry a
lockfile resolved URL míří jen na vlastní D1 `127.0.0.1` listener s dočasným portem.
Každý příkaz má `--ignore-scripts --no-audit --no-fund --update-notifier=false`.

Tři původní mock kompatibilitní testy provádějí:

1. `npm ci` se scoped lockfilem nové verze: právě jeden tarball GET, žádný packument GET,
   stejné nainstalované package.json a nezměněný lockfile. Poté explicitně
   `npm cache add <vlastní seed.tgz> --offline --ignore-scripts` a `npm ci --offline`:
   úspěšná instalace stejné nové verze, žádný další kontakt brány i po nastavení mock 403.
2. `npm ci` proti explicitně nastavenému 403: nenulový exit, pouze požadavky na správný
   tarball s 403, žádný nainstalovaný manifest, nezměněný lockfile.
3. Nesoulad manifest/lockfile mezi dvěma existujícími verzemi 1.0.0 a 1.1.0: nenulový exit,
   výslovná npm diagnostika nesouladu lockfilu a žádné vydání tarballu. npm může číst metadata,
   proto se netvrdí nulový počet HTTP požadavků. Chybějící verze ani chyba transportu tento oracle nenahradí.

První vývojový pokus o offline opakování bez explicitního seedování neprošel (npm exit 1).
D1 odpovědi mají `Cache-Control: no-store`; tento pokus se nevydává za úspěšnou warm-cache
instalaci. Finální test výslovně modeluje **importovanou/předexistující klientskou cache**.
Před seedováním jsou příslušné čerstvé npm operace úspěšné; výsledky 403 a metadata nejsou
zaměněné za nefunkční transport.

Čtvrtý opt-in test `NPMHandlerIntegrationTests.testOptionalAllFortyScenariosWithActualNpmLockfileCacheAndImport`
provádí všech 40 vstupů přes skutečný adaptér. Jeho npm operace a oddělení od původních
mock testů popisuje [HANDLER-INTEGRATION.md](HANDLER-INTEGRATION.md).

**Úklid:** testy zavírají listener a podprocesy v `defer`; smažou pouze vlastní vytvořený
UUID adresář a ověří jeho nepřítomnost. Vlastní build/cache po validačním běhu odstraň implementátorem ověřenými přesnými cestami;
malé receipts uchovej podle [nové validace](VALIDATION-HANDLER.md).
Nevzniká účet, certifikát, Keychain položka, TCC grant, pf pravidlo ani systémová služba.
**[uživatel]** Žádný privilegovaný krok ani laboratorní slot tento balík nepotřebuje.

Toto jsou unit/mock a lokální kompatibilitní testy, nikoli aktivní měření izolace. Nemají
laboratorní verdict ani credentials protokol. Budoucí D7 sonda musí začít WP0.3 kontrolou
přesně očekávaného UID/GID, audit session a bootstrap kontextu; nesoulad zneplatní měření.

## Závěrečné ověření 2026-11-03

Debug běh: **30 passed + 3 volitelné npm testy skipped**, 0 failures. Nezávislý finální Release
běh s explicitním npm: **33/33 passed, 0 failures, 0 skipped, 0 compiler warnings**. Tento běh
obsahoval i konečný oracle nesouladu lockfilu mezi dvěma existujícími verzemi 1.0.0 a 1.1.0.

Review vedlo k odmítnutí všech dodatečných/nepodporovaných exchanges včetně packument odpovědi
s artefaktovými bajty, k povinné explicitní evidenci přístupové cesty a k číselnému řazení
verzí pro `latest`. Regresní testy těchto oprav jsou součástí uvedeného finálního výsledku.
Nezávislá kontrola přes Python stdlib znovu potvrdila 3095 B a SHA-256
`dce3d65c3651022ed0e18156a097796099d5b5b88eeecb86f60271b21e2e1621`;
reprodukce je v [SOURCES.md](SOURCES.md).

Výsledky platí pro popsané unit/mock a lokální kompatibilitní testy. D2/D3 adaptéry zůstávají
neověřené, OAuth identita je mock a žádná brána ani jeden ze 155 akceptačních případů tím neprošel.
