# PyPI, Homebrew a Git — WP1.D5 (částečně)

D5 přidává integrovatelné Swift handlery nad D1 `UpstreamClient`: PyPI Simple JSON s artefaktovým
cooldownem, explicitně uzavřenou Homebrew cestu a Git smart HTTP v0 svázaný s jedním projektem.
**Balík zůstává rozpracovaný:** Homebrew artefaktový cooldown není splněný. Živé integrace, účty a
oprávnění zůstávají nepodporované do F0.7/D7. S5, S6, GW-16…18, HB-04 a R3/R8 jsou **Neověřeno**.
CLI `sanjbox-gateway --mode mock` se tím nemění na produkční bránu.

## Podmnožina a vstupní kontrakt

| Handler / cesta | Povolená operace | Stav |
|---|---|---|
| `/pypi/simple/<normalized-project>/` | GET, JSON Simple API 1.1–1.4 upstream, filtrovaná odpověď 1.1 | Implementováno; lokální pip fixture |
| `/pypi/files/<project>/<filename>` | GET `.whl` / `.tar.gz`, také jako úplně první request | Implementováno; vždy nová autorizace |
| `/brew/api/formula/<formula>.json` | GET jedné core formule pro diagnostiku metadat | Vždy odmítne vydání 403; vrací pouze pevnou chybu |
| `/brew/bottles/…`, katalogy/JWS, casks, zdrojové URL, tapy | Žádná | 403 před upstreamem |
| `/git/project.git/info/refs?service=git-upload-pack` | GET discovery pevného repa | Implementováno |
| `/git/project.git/git-upload-pack` | POST smart HTTP v0 | Implementováno; lokální clone |
| Stejné Git cesty se službou `git-receive-pack` | GET discovery / POST push, pouze při trusted `allowPush: true` | Implementováno; lokální push do jednoho fixture repa |
| SSH, Git v1/v2, LFS, další repo/submodules, dumb HTTP, archive, HTTP redirects | Žádná | Nepodporované, bez fallbacku |

Všechny handlery odmítají klientské credentials, cookies, Range/conditional requesty, komprimované
requesty a `Expect`. Žádná klientská hlavička se neposílá upstreamu. Každý upstream request sestavuje
handler z pevné důvěryhodné konfigurace a ověřeného tvaru operace. Host, proxy, TLS a DNS vlastní D1;
není zde veřejný test seam pro obejití SSRF/TLS. D1 znovu ověřuje DNS i vlastní adresy před každým
spojením. Produkční listener musí být svázaný s oblastí až přes ověřenou hranici D7/S3b; samotný
loopback endpoint takovou autentizaci neposkytuje.

## PyPI: autorizační postup

1. Požadavek obsahuje jen normalizovaný projekt a případně filename. Projekt se normalizuje malými
   ASCII písmeny a sloučením `[-_.]+` na `-`; vstupní cesta musí už být kanonická. Percent-encoding,
   query, fragment, dvojitá lomítka a absolutní URL se nepřijímají. Upstream je vždy
   `/simple/<project>/` na nakonfigurovaném registry hostname.
2. Přijímá se pouze 200 s `application/vnd.pypi.simple.v1+json`; žádné HTML, 304, redirect či
   stale-on-error. JSON odmítá duplicitní klíče (včetně escapovaných ekvivalentů), hloubku nad 32,
   přes 100 000 uzlů a přes 10 000 souborů. Duplicita filename zneplatní celý dokument.
3. Každý vydatelný soubor vyžaduje `upload-time` v UTC s nejvýše šesti desetinnými místy, `size`
   jako kladné celé číslo a SHA-256 v malém hexu. Chybějící/neplatné/budoucí datum, čas kratší než
   cooldown, yanked soubor nebo neaktivní status projektu se nevydá. Rovnost hranice je povolená;
   submilisekundová část se zachovává, aby datum neprošlo o zlomek sekundy dřív.
4. Normativní API 1.4 používá kořenový `project-status.status`; připnutý zdroj má současně starší
   příklad `meta.project-status`. Pokud je přítomna kterákoli forma, vyžaduje se explicitně `active`.
   Konflikt, neznámý status i vadný tvar selžou uzavřeně. Výstup nepropaguje nezkontrolované statusy.
5. Filename váže normalizované jméno distribuce a verzi k projektu: wheel má 5/6 pomlčkou oddělených
   složek a sdist `<name>-<version>.tar.gz`. Verze je úzký ASCII token začínající číslicí, ne úplný
   PEP 440 parser; resolver a shodu vnitřních metadat může dále odmítnout klient. SHA-256 váže celé
   bytes k důvěryhodným metadatům registry. Archiv se neotvírá ani nespouští.
6. URL musí být kanonická absolutní HTTPS URL na explicitně povoleném artifact hostu, bez portu,
   credentials, query, fragmentu, percent-encoding a dot segmentů; basename musí být filename.
   Relativní a podepsané URL jsou nepodporované. **Všechny redirecty se odmítají** — neprovádí se ani
   druhý hop na stejný host. Metadata smí uvést více povolených CDN hostů, každé spojení kontroluje D1.
7. Před přímým file requestem se načtou čerstvá metadata; pak se stáhne bounded celé tělo a ověří
   délka i hash. Potom se metadata znovu načtou a musí odpovídat celý descriptor včetně filename,
   verze, upload-time, URL, hashe, velikosti a `requires-python`. Změna nebo chyba nic nevydá.
   Kontroluje se cancellation, deadline a návrat hodin pod počáteční čas operace i při vydání.
8. Výstupní index obsahuje jen `meta`, `name`, přijaté `files` a přepsané lokální file URL,
   `hashes`, `size`, `upload-time`, případně `requires-python`. Sidecar metadata, provenance,
   `_links`, seznam neověřených verzí a další vložené URL se neposílají. Prázdný seznam je platná
   odpověď; přímý request na nezpůsobilý soubor stále selže.

Upstream `upload-time` označuje jednotlivý upload, nikoli první vydání verze. Novější wheel stejné
verze proto zůstává v cooldownu i při starším sdistu. **Důvěra je v nakonfigurovaný registry a jeho
TLS metadata**, nikoli v samostatně ověřenou identitu autora či pravdivost registry času. Dvě čtení
vzdálených metadat netvoří atomickou transakci; poslední úspěšná kontrola je hranicí rozhodnutí.

Brána nemá PyPI byte ani metadata cache. HTTP odpovědi D1 mají `Cache-Control: no-store`; vlastní
klientská cache nebo importovaný archiv zůstávají mimo síťovou kontrolu. Starý lockfile/direct URL
mimo gateway musí zablokovat S3, nikoli tato knihovna. Neověřuje se obsah závislostí, sdist build
hooks ani vnitřní package metadata; jejich další síťové operace také potřebují S3.

Nepodporované: HTML-only klienti (např. lokální systémový pip 21.2.4), uv dosud neměřeno, root
project listing, `.zip`, epoch verze s `!`, sidecar metadata, publish/private auth, přímé URL mimo
mount, HEAD a ranges. Soubor s nepodporovaným tvarem filename v upstream seznamu zneplatní celý
index; nejde o univerzální náhradu veřejného PyPI. Skutečný veřejný registry nebyl volán testy.

## Homebrew: doložená mezera, nikoli vypuštění cooldownu

**Fakt z připnutého zdroje:** `Formula#bottle_hash` vytváří pro bottle `cellar`, `url` a `sha256`;
na této cestě není čas publikace artefaktu. Dokumentovaný formula API ukazuje stejné údaje.
`HOMEBREW_API_DOMAIN` i `HOMEBREW_BOTTLE_DOMAIN` mohou při nedostupnosti mirroru použít veřejný
fallback. `HOMEBREW_ARTIFACT_DOMAIN_NO_FALLBACK` se týká artifact mirror konfigurace a samo není
síťovou hranicí ani důkazem pokrytí všech operací. [Připnuté zdroje](research/wp1-d5/README.md).

**Odvození:** hash a digest URL dokazují identitu bytes vůči metadatům, ale ne jejich stáří.
`generated_date`, datum upstream releasu, git commit formule nebo OCI `created` nejsou bez dalšího
kontraktu důkazem času prvního publikování právě této bottle. D5 nepřijímá ani uměle přidaný
`upload-time` v neznámém Homebrew rozšíření. Není zaveden nový schválený autoritativní zdroj času.

`HomebrewMetadataAssessment.inspect` vrátí `missingArtifactPublicationTime`, má-li core formule
známou digest identitu na stock GHCR doméně; jiné identity dostanou `unsupportedBottleIdentity`.
`artifactCooldownSupported` je v obou případech false. `HomebrewGateway` nikdy nevydá instalovatelná
metadata ani bottle. Diagnostický formula request může načíst jeden bounded dokument, ostatní
API/bottle/manifests/cask/tap cesty odmítne před upstreamem. Testy prokazují i případ se starým
`generated_date`, správným hashem a syntetickými dodatečnými daty: stále 403.

Pouhé nastavení `HOMEBREW_API_DOMAIN=http://127.0.0.1:<port>/brew/api` a
`HOMEBREW_BOTTLE_DOMAIN=http://127.0.0.1:<port>/brew/bottles` by **nezabránilo klientskému fallbacku**.
Jde o dokumentované mapování mountů, ne návod na bezpečnou živou instalaci. Pro kompletní D5/E1
zbývá najít a ověřit autoritativní per-artifact publish-time, integritu katalogů/JWS a všechny
stahovací cesty. Bez toho je brew cooldown nesplněný; změnu požadavku může provést pouze uživatel.

## Git: rozhodnutí pro smart HTTP v0 v tomto prototypu

D5 volí úzký smart HTTP transport, aby bylo možné otestovat povolení přesné operace na přesném repu
bez skutečných deploy keys a bez změny F0.7. `GitConfiguration` nese pevný TLS hostname a jednu
kanonickou cestu `/owner/repository.git`. Oblast zná jen lokální `/git/project.git`. Jediný parametr
query je přesně `service=git-upload-pack` či `service=git-receive-pack`. Upstream cesta vzniká
z pevného repositoryPath a konstantního suffixu služby. `allowPush` je výchozí false.

Pro fixture klient používá `-c protocol.version=0`. `Git-Protocol` se odmítá, včetně v1/v2; žádné
packfile-URI, SSH, LFS, archive, dumb fallback ani další repo/submodules nejsou implementované.
POST vyžaduje odpovídající přesný media type, neprázdné tělo a nejvýše 1 MiB. Upstream smí vrátit
jen 200 s odpovídajícím smart media type a bounded neprázdným tělem. Redirect/auth challenge se
nepřeposílají. Knihovna nevkládá credentials a nemá SSH agent ani deploy key přístup.

Pack/protocol těla jsou opaque bytes pro **důvěryhodný Git server**, který musí validovat refs,
capabilities a objekty. Brána nevynucuje branch policy, hook policy ani autorství commitů. Push
smí přenést data do nakonfigurovaného projektového repa; oprávnění této operace musí být svázané
s oblastí/uživatelem v budoucí integraci. Tento prototyp neposkytuje trvalý audit git operací.
Timeout nebo přerušená odpověď může nastat až po přijetí push serverem; výsledek změny pak není
známý. Brána neprovádí automatický retry ani rollback vzdálené operace.
Žádný test nepoužívá skutečný účet, GitHub repo nebo autentizaci, takže veřejný GitHub push je
nepodporovaný do F0.7. Per-repo deploy key zůstává alternativou plánu, v D5 se negeneruje.

**Měřeno lokálně:** skutečný `/usr/bin/git` klonuje a pushuje přes skutečný loopback GatewayServer.
Interní test seam D1 mění upstream transport na lokální `git http-backend` nad jediným vytvořeným
bare repem. Test porovná obsah i commit ID v cílovém repu a ověří, že jiné repo nedojde k backendu.
To není veřejný Git TLS/auth ani izolovaná oblast; D1 má vlastní samostatné TLS fixture testy.

## Limity, audit a použití knihovny

`RegistryLimits`: metadata a odpověď 4 MiB (lze snížit), 10 000 souborů, 4 aktivní operace,
1 024 PyPI audit záznamů, 90 s deadline. Konfigurace nepovolí více než 4 MiB, 16 operací,
10 000 audit záznamů či 120 s. D1 limiter se sdílí mezi handlery; také listener a request body
mají vlastní bounded rozpočty. Aktor neudržuje neomezenou frontu požadavků.

PyPI audit je bounded a čte jej jen důvěryhodný vlastník přes `downloadRecords()` a
`takeCompletedDownloadRecords()`. `prepared` znamená připravené bytes, `transportAccepted` lokální
send callback a `sendFailed` selhání odesílání, při němž část bytes mohla odejít. Záznam obsahuje
projekt/verzi/filename, zdrojovou URL, registry upload-time, hash, velikost a čas přípravy. Není to důkaz
kompletního přijetí ani instalace. Dokud vlastník nedokončený záznam neuzavře a dokončené neexportuje,
plná kapacita odmítá další vydání. Přímé knihovní volání neprovede transport callback automaticky.

Integrátor po credentials kontrole WP0.3 sestaví `PyPIGateway`, `HomebrewGateway` a `GitGateway`
s jednou sdílenou instancí `UpstreamClient` a jejich `route()` vloží do `TypedRouter`. PyPI
`publicOrigin` musí být přesně `http://127.0.0.1:<port>` skutečného listeneru; nepřebírá se z Host.
Tato dokumentace neposkytuje živou spouštěcí konfiguraci před D7/F0.7.

## Ověření a zbývající práce

[VALIDATION-D5.md](VALIDATION-D5.md) obsahuje přesné příkazy, verze, počty, raw logy a cleanup.
Mocky testují nepřijatelné datum/hash/URL, mutation, DNS rebinding, limity, cancellation a timeout.
Lokální pip používá vytvořený metadata-only wheel a `pip download --no-deps --only-binary=:all:`;
neinstaluje nic a nepouští package kód. Git používá jen vytvořené repo, prázdné profily, vypnuté
hooks/signing/credentials a pevné HTTP endpointy. Žádná systémová konfigurace se nemění.

**Zbývá:** brew publication-time/JWS/OCI plná cesta, uv a širší pip/Git kompatibilita D6, F0.7
reálné omezení scopes/revokace, D7 pf cesta a autorizace oblasti, user-level bypassy, per-area
konkurence a výkonové cíle. Tyto mezery neuzavírá ani úspěšný lokální test.
