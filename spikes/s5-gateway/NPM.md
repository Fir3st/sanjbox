# npm typed — WP1.D2

`NPMGateway` je integrovatelný read-only handler nad D1 `UpstreamClient`. Filtruje packumenty a před
každým vydáním tarballu ověřuje aktuální metadata, cooldown, identitu, původ a kryptografický hash.
**Jde o prototyp s níže vymezenou podmnožinou; S5, GW i R zůstávají Neověřeno.** CLI
`sanjbox-gateway --mode mock` zůstává mockem bez přístupu do veřejného registru.

## Podporované operace

| Operace | Chování |
|---|---|
| `GET /npm/name` nebo `/npm/@scope%2fname` | Čerstvý full packument z pevného registry; pouze způsobilé verze, jejich časy a dist-tags. Scoped separator přijímá i `%2F` nebo doslovné `/`; výstup používá `%2f`. |
| `GET /npm/name/-/name-1.2.3.tgz` | Funguje i jako první požadavek, například `resolved` z lockfile. Identita se určí z cesty a ověří proti full packumentu, nikoli proti návštěvní historii. |
| `GET /npm/@scope%2fname/-/name-1.2.3.tgz` | Stejná artefaktová kontrola pro scoped balíček; také doslovné `/npm/@scope/name/-/…`. |
| PUT, DELETE, POST, CONNECT, tělo GET, Range, klientské credentials | Odmítnutí před upstreamem; žádný raw fallback. Router navíc blokuje neregistrované mounty a ostatní metody. |
| Query, fragment, absolutní klientská URL, dvojité/alternativní percent-encoding | Odmítnutí. Cesta není obecný URL fetcher. |

Jména jsou malá ASCII písmena/čísla s `-._`, nezačínají `.`/`_`, maximálně 214 bajtů včetně scope.
Verze mají podobu `major.minor.patch` s volitelným prerelease/build suffixem. Specifický endpoint
`/package/version`, search, ping, audit, publish, private registry auth a HEAD nejsou implementované.
Klient má používat metadata a přepsané tarball URL pod mountem. Starý lockfile odkazující přímo
mimo tuto bránu není touto knihovnou zachycen; v produktu to musí vynutit síťová hranice S3/S5.

Nezpůsobilý dist-tag se odstraní a **nepřesměruje** na jinou verzi. Pokud `latest` míří do cooldownu,
použij explicitní způsobilou verzi nebo zachovaný tag. `npm pack package` bez pinu nemusí uspět;
praktický fixture test používá `npm pack fixture@1.0.0` právě s odstraněným `latest`.

## Autorizační postup

1. Pevný registry hostname se nastaví při konstrukci handleru. Klient vybírá jen ověřené jméno/verzi,
   nikoli host. Upstream požadavek je GET s `Accept: application/json` a `Cache-Control: no-cache`.
   Žádné klientské hlavičky se nepřenášejí. Jen 200 s JSON; metadata redirect, 304 a abbreviated
   `application/vnd.npm.install-v1+json` nejsou podkladem k vydání.
2. Full packument musí mít odpovídající jméno a mapy `versions`, `time`, `dist-tags`. Duplicitní JSON
   klíče, nadměrné vnoření a překročení rozpočtů se odmítnou i v později vynechaných polích.
   Každý použitý manifest musí mít přesně očekávané name/version a `time[version]` v UTC ISO formátu
   `YYYY-MM-DDTHH:mm:ss[.fraction]Z`. Chybějící, nemožné nebo budoucí datum není způsobilé.
   Přesná hranice `now − published >= cooldown` je povolená; cooldown je povinná důvěryhodná konfigurace.
3. `dist.tarball` musí být kanonická absolutní HTTPS URL bez credentials, explicitního portu, query,
   fragmentu, percent-encoding a dot segmentů, s hostname v pevné sadě registry/CDN. Povolené znaky
   cesty jsou ASCII písmena/čísla a `/@-._~+`. Prototyp nepodporuje podepsané query URL ani relativní redirecty.
4. `dist.integrity` je povinné. CryptoKit ověří SHA-512, SHA-384 nebo SHA-256; při více algoritmech
   se použije nejsilnější, při více hashech stejné síly musí odpovídat alespoň jeden. Kanonické base64,
   nejvýše 8 tokenů, žádné option suffixy. Samotné SHA-1/`shasum` nestačí; vadný silný hash nemá fallback.
5. Na každý explicitní 301/302/303/307/308 se ověří nový origin, znovu získá full packument a vyžaduje
   **stejný descriptor** (jméno, verze, datum, původní URL, vybraný integrity hash). Další hop volá znovu
   D1 klienta: nové DNS, host-interface snapshot, SSRF policy a připnuté TLS. Smyčka a limit hopů selžou zavřeně.
6. Celé bounded tělo se ověří **před** předáním klientovi. Po stažení, stejně jako při cache hitu,
   následuje další čerstvá autorizace z full packumentu a shoda descriptoru; znovu se ověří hash,
   aktuální čas/cooldown, absence zpětného skoku hodin a cancellation. Změna během operace nic nevydá.
   Již cachované bajty se při odlišném aktuálním descriptoru zahodí; nová operace může získat pouze
   nově autorizovaný artefakt. Metadata/rozhodnutí se necachují a neexistuje režim stale-on-error.

**Důvěra:** identita, datum i hash pocházejí z nakonfigurovaného registry ověřeného D1 TLS cestou.
Hash váže bajty k jeho metadatům; sám nedokazuje autora, nezávadnost ani pravdivost data publikace.
Podpisy/provenance registru zde nejsou implementované. Mezi dvěma odečty vzdálených metadat nelze
udělat distribuovanou atomickou transakci; vydání se opírá o poslední úspěšnou kontrolu a pinned descriptor.

## Výstupní metadata a hranice cooldownu

Handler rekonstruuje výstup z allowlistu: name/version, dist s **lokální** URL a silným integrity,
registry-only dependencies/optionalDependencies/peerDependencies, peer optional flag, node/npm engines,
os/cpu/libc. Nepřeposílá readme, repository, homepage, scripts, `_resolved`, arbitrary dist pole ani
jiná vložená URL. Dependency spec musí mít omezenou abecedu pro registry verzi/range/tag; URL, git,
file, relativní cesta (včetně `.local`), samotný soubor `*.tgz`/`*.tar.gz`/`*.tar` a `npm:` alias jsou
nepodporované a zneplatní verzi. Bundled dependencies jsou
nepodporované. Neplatný semver/range může dále odmítnout npm klient — brána neimplementuje jeho resolver.

Tarball se nerozbaluje, nespouští a nepřepisuje. Síťová kontrola neověřuje obsah jeho package.json,
shrinkwrapu, skriptů či dalších souborů; nebrání instalaci dříve staženého/importovaného kódu ani
přímému spojení mimo bránu bez S3. Odmítnutí alternativních zdrojů ve vydaných metadatech není globální
zákaz jejich použití klientem. Prototyp nemůže tvrdit, že sleduje nebo bezpečně povoluje instalace.

## Cache, limity a audit

| D2 limit | Výchozí hodnota |
|---|---|
| Full metadata / jeden tarball | 4 MiB / 4 MiB; odpovídá default D1 upstreamu a listeneru |
| Verze / JSON hloubka / JSON uzly | 10 000 / 32 / 100 000 |
| Cache | 32 položek, celkem 16 MiB, FIFO; pouze ověřené tarball bytes |
| Aktivní operace / deadline celé operace | 4 / 90 s, včetně všech metadata kontrol a redirectů |
| Redirecty | nejvýše 3; konfigurovatelné 0–5 |
| Audit | nejvýše 1 024 záznamů; při plném auditu další download vrací 503 |

Jde o záměrnou kompatibilitní hranici: některé skutečné full packumenty přesahují 10 MiB a velké
balíčky 4 MiB. Limit se neobchází abbreviated dokumentem bez publish-time. Integrátor musí při zvýšení
rozpočtu sladit D2, `UpstreamLimits.responseBytes` i `GatewayLimits.responseBytes` a počítat s pamětí
všech souběžných odpovědí. Žádná neomezená čekací fronta, persistentní cache ani neověřený streaming.

`downloadRecords()` vrací metadata vydání a stavy:

- `prepared`: ověřené bytes připravené pro transport, **ještě ne potvrzené odeslání**;
- `transportAccepted`: GatewayServer úspěšně předal celou odpověď lokálnímu transportu;
- `sendFailed`: limit/kódování/odesílání odpovědi selhalo; část bajtů přesto mohla být přenesena.

Záznam má ID, package/version, integrity, registry-deklarovaný původní source, velikost, čas a cache flag.
Transport acknowledgement není důkaz kompletního příjmu klientem ani instalace. Bounded audit nedělá
síťový endpoint; čte ho důvěryhodný vlastník handleru. `takeCompletedDownloadRecords()` odebere jen
ukončené záznamy k exportu; vlastník odpovídá za jejich trvalé uložení. Pending záznamy zůstávají a při
vyčerpání kapacity brána odmítá další vydání. Přímé volání `response(to:)` bez GatewayServeru nevyhodnotí
transport completion a zachová `prepared`; pro tento spike používej `route()` s GatewayServerem.
Zápis `prepared` nastává až po úspěšném návratu časově omezené přípravy; pozdní výsledek zahozený
timeoutem/zrušením neobsadí audit. Regression test ověřuje i následný download s kapacitou auditu 1.

## Integrace rozhraní

Kód je určen pro důvěryhodného vlastníka procesu, po ověření credentials WP0.3 jako v existujícím CLI.
Následující příklad ukazuje API, **není příkaz k živému integračnímu testu**. Cooldown 7 dnů je pouze
příklad explicitní konfigurace; schválení reálného provozu a síťové cesty patří do D7.

```swift
let port: UInt16 = 8765
let upstream = UpstreamClient() // sdílet také s ostatními typed handlery
let npm = NPMGateway(
    configuration: try NPMConfiguration(
        registryHostname: "registry.npmjs.org",
        artifactHostnames: [], // další CDN jen po výslovné konfiguraci
        publicOrigin: "http://127.0.0.1:\(port)",
        cooldown: 7 * 24 * 60 * 60),
    upstream: upstream)
let server = GatewayServer(router: try TypedRouter(routes: [npm.route()]))
_ = try await server.start(port: port)
// Důvěryhodný vlastník průběžně uloží await npm.takeCompletedDownloadRecords().
```

`publicOrigin` musí přesně odpovídat listeneru; přijímá jen `http://127.0.0.1:<port>` bez cesty.
Mount je explicitní jeden segment. Neodvozuje se z klientského Host. NPM konfigurace nedává klientovi
přístup k nastavení DNS, trust anchors nebo upstream URL. API záměrně neposkytuje vypnutí SSRF/TLS.

## Testy a hranice důkazů

```bash
swift test --package-path spikes/s5-gateway
```

NPM testy používají syntetické packumenty a tarball bytes; UpstreamClient prochází skutečnou
DestinationPolicy s mock DNS a interním scripted transportem. Nejde o živý veřejný registry/TLS důkaz.
D1 suite samostatně testuje skutečný TLS na loopbacku. Nový CLI test, pokud již existuje
`/opt/homebrew/bin/npm`, vytvoří vlastní `.tgz` systémovým tar, otevře skutečný GatewayServer na
loopbacku a provede `npm pack fixture@1.0.0 --ignore-scripts --json`. Neinstaluje npm ani žádnou cizí
závislost. Má vlastní prázdné user/global config, cwd/cache/temp a minimální prostředí bez ambient
proxy/auth. Stažený soubor musí bajtově odpovídat lokálnímu fixture a audit skončit `transportAccepted`.
Bez již dostupného npm je tento **jeden** test explicitně skipped, ostatní npm testy běží.

Případy pokrývají hranici cooldownu, neznámé/budoucí datum, scoped names, přímý lockfile target,
credentials a metody, bezpečné přepsání metadat, unsupported dependency sources, cache hit/mutaci/
eviction, změnu descriptoru po stažení a v redirectu, CDN origin/hash odmítnutí, rebinding při hopu,
SRI strongest-algorithm pravidlo, duplicitní JSON klíče, limity, souběh, cancellation, deadline a audit.
Žádný automatický test nespouští `npm install`, skripty balíčků, sudo ani změny systému.

Ověřeno 2026-11-03 na arm64 macOS: **63 debug testů prošlo, 0 skips**, z toho 18 nových D2.
Skutečný fixture `npm pack` proběhl s Node v26.12.1 / npm 11.20.0; oba review nálezy
(bare-file dependency specs a orphan audit při timeout/cancel) mají regresní testy.
Použitý příkaz z kořene repozitáře s oddělenými build/cache adresáři:

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/sanjbox-d2-module-cache \
  swift test --package-path spikes/s5-gateway \
  --scratch-path /private/tmp/sanjbox-d2-build \
  --cache-path /private/tmp/sanjbox-d2-cache --disable-sandbox
```

Hostitelský sandbox musel povolit lokální listenery; nejde o privilegovanou konfiguraci systému.
Release sestava a nezávislé review jsou samostatná kontrola finálního commitu.

Mapování: příprava pro **GW-01…09, GW-15**, části R3/R7/R8. Neprokazuje F0.7 účty, D3 modelová API,
D6 matici klientů, D7 pf cestu z oblasti, úplný lockfile/npm-ci flow ani režii ≤1,1×. Brány/testové
případy v COVERAGE se tím neuzavírají.

## Primární protokolové podklady

- [npm registry: package metadata](https://github.com/npm/registry/blob/main/docs/responses/package-metadata.md):
  full vs abbreviated odpovědi, `time[version]`, registry-generated `dist`, metadata mohou přesáhnout 10 MiB.
- [npm: package-lock.json](https://docs.npmjs.com/cli/v11/configuring-npm/package-lock-json/):
  `resolved` tarball URL a `integrity`; lockfile není povinnost navštívit filtrovaný packument.
- [npm: package.json dependency sources](https://docs.npmjs.com/cli/v11/configuring-npm/package-json/#urls-as-dependencies):
  URL/git/file/alias jsou další zdroje, nikoli běžná registry verze; zde výslovně nepodporované.
- [npm-package-arg: klasifikace zdrojů](https://github.com/npm/npm-package-arg/blob/main/lib/npa.js):
  také leading-dot a samotné tarball názvy mohou označovat lokální soubor/adresář bez `file:` nebo `/`.
- [RFC 9112: HTTP/1.1](https://www.rfc-editor.org/rfc/rfc9112.html): rámování vlastní D1; D2 nenásleduje redirect automaticky.
