# WP1.H4 — lokální revize a validace

## Oprava nálezu nezávislého review P3 — 2026-11-14

Reviewer zjistil, že při validním H1 `responseBytesLimit = 1` lokální odmítnutí
`DELETE /npm/fixture` měnilo `403/handlerForbidden` na
`502/failed/h1ResponseLimit`, protože syntetické chybové tělo překračovalo mez.
Otestovaný opravný commit kódu/testů je
**`71034cefb5cc8220b1bee64307913353f6009394`**. Následný commit mění jen vlastní
H4 dokumentaci a jediný řádek H4 v COVERAGE; prostředí je stejné jako níže.

Nadlimitní router/handler denial nyní zachová status, `deniedByHandler`, původní
důvod a případný `.capacity` marker; vrátí prázdné tělo. Původní response completion
se dokončí jako neúspěch, protože původní tělo se neposlalo. Ostatní nadlimitní
odpovědi zůstávají 502. Upstream parser se nemění a nadále odmítá větší těla včetně
upstream chybových odpovědí; žádné rozšíření cílů, metod ani limitů.

Tři nové regrese ověřují PUT/DELETE přes skutečný transport, handlerové 403/400 a
původní audit bez DNS, souběžnou lokální capacity 503 s typovaným markerem, a přesnou
upstream hranici: jednobajtové tělo projde, dvoubajtové skončí 502 při upstream
statusu 200 i 403. Vše používá pouze syntetická data a in-memory upstream.

| Ověření opravného commitu | Výsledek |
|---|---|
| všechny produkty, `swift build`, Debug / Release | prošlo / prošlo |
| úplná gateway sada, `swift test`, Debug / Release | **117/117 / 117/117**, 0 failures, 0 skips |
| `listener_cli.py`, Debug / Release | **5/5 / 5/5**, 0 skips |
| `/usr/bin/python3 -m unittest discover -s tools/tests` | **94/94**, 0 skips |
| `git diff --check` | prošlo |

Příkazy použily vlastní scratch `/private/tmp/sanjbox-h4-h1-review-build`; po
ověření byl odstraněn, malé textové logy zůstávají. Nedošlo k systémovým změnám,
živým upstreamům, použití skutečných klíčů ani změně H1.

Podmínka offline prototypu H4 z IMPLEMENTATION §0 je splněna: H1 prokazatelně řídí
npm/PyPI/git/model i běžící knihovní listener a nepodporované konfigurace se odmítají.
H4 proto evidujeme jako **✅ hotovo (offline prototyp)**. Opravný head má před merge
ještě nezávisle zkontrolovat reviewer a jeho přesné CI; tento záznam jejich výsledek
nepředjímá. CLI stále přijímá pouze draft, veřejné H1 API je popsáno níže. Brány a
všech 155 akceptací zůstávají Neověřeno; produkční integrace ani autentizace klienta
nejsou součástí tohoto dokončení. Následující záznamy zachovávají dřívější stav.

## Původní H1 adaptér — 2026-11-14

Výslovně zadané pokračování původních autorů janfiedler / Codex + Astra; navazující
Astra, větev `codex/wp1-h4-h1-policy`. Základ čistého main:
`75f3b5da13dfd7fca3acd376e06f1cd4d0fe2786`; publikovaný scoped claim:
`d8a29a0`. **Otestovaný commit kódu a testů:
`cf58222f4ea278064290710771afb23e62f94559`.** Následný commit mění pouze dokumentaci
H4 a jeho řádek COVERAGE. H1 ani jiný sdílený kontrakt se nemění.

Apple Silicon arm64, macOS **27.2.1 (26B131)**, Xcode **27.2 (27B52)**, Swift
**6.4.2** (`swiftlang-6.4.2.1.9`), `/usr/bin/python3` **3.9.6**. Jediné Swift
závislosti jsou lokální `spikes/s5-gateway` a `proto/contracts`; žádný externí balíček.

| Ověření | Výsledek |
|---|---|
| `swift build --package-path proto/gateway -c debug` | prošlo, všechny produkty |
| tentýž build s `-c release` | prošlo, všechny produkty |
| `swift test --package-path proto/gateway -c debug` | **114/114**, 0 failures, 0 skips |
| tentýž test s `-c release` | **114/114**, 0 failures, 0 skips |
| `python3 proto/gateway/Tests/listener_cli.py <Debug binary>` | **5/5**, 0 skips |
| tentýž subprocess suite proti Release binary | **5/5**, 0 skips |
| `PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -m unittest discover -s tools/tests` | **94/94**, 0 skips |
| `git diff --check` | prošlo |

Swift příkazy použily vlastní `--scratch-path /private/tmp/sanjbox-h4-h1-build`;
CLI binárky byly v jeho `out/Products/Debug` a `out/Products/Release`.
Nových **22 testů** (21 H1 adapter + 1 skutečný listener) pokrývá:

- skutečné H1 strict decode, opětovnou validaci změněného DTO, deny-all a saturaci;
  chybějící/přebývající bindingy, duplicity typů, zakázané/nesprávné konfigurace;
- npm/PyPI artefakty s hashem, cooldownem a dokončeným auditem přes skutečné handlery;
  cizí artifact host se odmítne po metadata requestu bez dialu na cizí host;
- git přesné request/response byte hranice, odmítnutí limit+1 před upstreamem či
  před vydáním, explicitní push a odmítnutí jiného repozitáře;
- modelový POST na jediný pevný host/endpoint, pouze mock klíč, skutečné úspěšné SSE,
  canonical JSON request, malformed těla, raw upstream ceiling včetně zahazovaných
  pingů, klientský output ceiling, chyby před i po prvním eventu a finální audit;
- minimum/maximum H1 mezí, odmítnutí větších handler mezí, společné zpřísnění upstream
  parseru; odmítnutí rozšíření hostů/metod a Homebrew;
- **H1 wire → adaptér → GatewayService → skutečný 127.0.0.1 listener → npm handler**:
  syntetický download 200, request limit 413, neznámý původní mount 404, žádné další
  upstream volání, artifact audit `transportAccepted`, cancellation a opětovný bind.

Offline upstream factory je pouze interní testovací seam a dostává skutečné H1
`UpstreamLimits`. Veřejné `GatewayService(adapting:)` vytvoří omezeného klienta samo;
veřejný resolver test odmítá po ověření přesného hostu, bez socketu. Žádné živé DNS,
upstreamy, uživatelské klíče/účty, billing, instalace balíčků ani systémové změny.
Dev běh opravil chybějící `try` ve fixture a nesprávný předpoklad o Foundation Unicode
escapování; uvedené finální Debug/Release běhy prošly na výsledném commitu.

### Stav a hranice tohoto pokračování

H1 skutečně řídí běžící knihovní cestu, ne jen validační objekt.
[H1-ADAPTER.md](H1-ADAPTER.md) dokumentuje explicitní caller-supplied konfiguraci,
jednotky mezí, přesné odmítané podmnožiny a společný upstream cap. Samostatný CLI
`--policy` nadále přijímá starý draft; pro H1 je veřejná cesta
`H1GatewayAdapter.decode` → `GatewayService(adapting:)` →
`dispatch` / `LoopbackListener.run(serving:)`. CLI není důkazem H1 autorizace.

Lokální podmínka implementace z IMPLEMENTATION §0 je pokryta touto dosažitelnou cestou
s pozitivními i negativními testy. **Řádek H4 zatím zůstává 🟨 rozpracováno: čeká na
samostatné nezávislé review a integraci**, které spravuje hlavní vlastník úkolu.
Žádná brána ani akceptační případ nemění stav Neověřeno.

Nepodporované zůstávají Homebrew, více gate stejného typu, cizí artifact hosty
(včetně veřejného PyPI CDN), model GET/jiné upstreamy a širší handler limity.
Neexistuje autentizace UID/session, broker, bind policy/pf, durable audit, produkční
lifecycle ani skutečný Keychain/TLS trust/billing. Společný upstream parser může
zpřísnit větší gate na nejmenší H1 response mez v celé službě; je to zveřejněný
limit, nikoli slib dostupnosti pro každou samostatnou mez. Historická validace níže
se týká staršího draftu a její tehdejší mezera H1 je řešena výše.

Vlastní velký scratch build byl po ověření odstraněn; zůstává tento krátký záznam,
zdrojové testy a malé lokální textové logy. Testy uklidily vlastní sockety/procesy;
žádné zálohy, zařízení, účty, TCC ani jiná systémová nastavení se neměnily.

## Historická revize samostatného draftu — 2026-11-13

Datum: 2026-11-13. Jde o offline/prototypovou validaci podle GUIDE §11, nikoli
laboratorní důkaz, potvrzení S5/GW nebo oprávnění sestavit běžící oblast.

## Revize a prostředí

- Původní head PR #54: `ca0a342b27a3606f4642133539642b9be4a275ea`.
- Integrovaný `main`: `e9ce5c75aeb8e20e26b77bdc662756c78982b6ea`, lokální merge
  `3c18ff6ee2d681a967520926a6ffc281bfafdf88`; bez konfliktů a bez přepsání cizích stavů coverage.
- **Otestovaný commit kódu a testů: `ec0e3cc785525ace1dd13d06cc24af9459c76043`.**
  Následný commit mění pouze README, tento záznam a řádek H4 v COVERAGE.
- Apple Silicon arm64; macOS **27.2.1 (26B131)**, Xcode **27.2 (27B52)**,
  Apple Swift **6.4.2** (`swiftlang-6.4.2.1.9`), `/usr/bin/python3` **3.9.6**.
- Bez externích Swift balíčků; závislost je lokální `spikes/s5-gateway`.
  Testy používají syntetické klíče/obsah, mock upstreamy a místní sockety.

## Výsledky na uvedeném commitu

| Ověření | Výsledek |
|---|---|
| `swift build --package-path proto/gateway -c debug` | prošlo, všechny produkty |
| `swift build --package-path proto/gateway -c release` | prošlo, všechny produkty |
| `swift test --package-path proto/gateway -c debug` | **92/92**, 0 failures, 0 skips |
| `swift test --package-path proto/gateway -c release` | **92/92**, 0 failures, 0 skips |
| `python3 proto/gateway/Tests/listener_cli.py proto/gateway/.build/debug/sanjbox-gateway-service` | **5/5**, 0 skips |
| tentýž subprocess suite proti `.build/release/sanjbox-gateway-service` | **5/5**, 0 skips |
| `swift test --package-path spikes/s5-gateway -c debug` | **104/104**, 0 skips |
| `swift test --package-path spikes/s5-gateway -c release` | **104/104**, 0 skips |
| `/usr/bin/python3 -m unittest discover -s tools/tests` | **63/63**, 0 skips |
| `git diff --check` | prošlo |

Oba downstream běhy zahrnuly skutečné lokální fixture cesty `npm pack`, `pip download`,
`git clone/push` a modelové HTTPS/SSE. Žádný test neinstaloval ani nespouštěl stažený
balíček, nepoužíval živý účet, modelový billing nebo skutečnou Klíčenku.

Swift listener suite má devět testů: osm otevírá socket/socketpair, jeden odmítá
nesoulad publicOrigin ještě před bindem. Ověřuje bind pouze na 127.0.0.1, neblokující
fd a close-on-exec, syntetický artifact přes skutečný HTTP transport a handler audit,
limit jednoho aktivního klienta, timeout nečinného klienta a pevný lifetime, zrušení
listeneru bez klientů/i s idle klientem/i s čekajícím modelovým handlerem, znovupoužití
portu, pomalého čtenáře, zavřený peer bez SIGPIPE a idempotentní close.

Subprocess suite ověřuje skutečnou binárku: výchozí režim bez socketu, kolizi portu
bez falešného `ready`, chybnou politiku/adresu, nesoulad originu, malformed HTTP,
403 vypnutého mountu a uvolnění socketu/portu po SIGTERM. CLI child procesy mají
5sekundový timeout pro ukončující příkazy/readiness; socket klient 2 sekundy, cleanup
3 sekundy do SIGKILL fallbacku. Swift testy používají krátké 50/70/250ms fixture
limity, přijetí zrušení do jedné sekundy a socket timeout 2 sekundy. Jde o regresní
meze testů, nikoli produkční výkonový nebo dostupnostní slib.

## Opravené nálezy

1. `JSONDecoder` tiše vybíral hodnotu duplicitního klíče a připouštěl zaokrouhlení
   numerického lexému do integer pole. Bounded preflight nyní kontroluje původní
   bajty včetně Unicode aliasů klíčů; veřejný wire vstup vede jen přes `decode`.
2. Listener blokoval Swift executor v `accept/read/write`, vytvářel neomezené tasky
   a bez dalšího klienta nereagoval na cancellation. Nyní používá neblokující fd,
   omezenou strukturovanou skupinu, I/O deadlines a čeká na úklid obsluh. Lock
   chrání jednotlivé syscally i close před opětovným použitím čísla descriptoru.
3. `listener ready` byl vypsán před úspěšným bindem, jeho chyba dvakrát. `starting`
   a skutečné `ready` jsou oddělené a chyba se vrací/vypíše jednou; aktivní výstup
   není zadržován stdio bufferingem v pipe. Zapnuté registry vyžadují shodný origin.
4. `npm.limits.files` se ignoroval při skládání. Nyní se předává jako
   `maximumVersions`; regrese s dvěma verzemi potvrzuje odmítnutí při limitu jedna.
5. Audit SSE hlásil `routed` už před odesláním terminálního chunku. Transportní
   finalizace nyní patří do auditovaného producenta; selhání posledního sendu je
   `failed/streamFailed/502`, stejně jako ostatní chyby streamu.
6. Parser auditu přijímal nekanonické nebo neúplné escape zápisy; nyní kontroluje
   přesný canonical round-trip. Duplicitní CLI přepínače se již tiše nepřepisují.

Dosavadní regrese navíc chrání saturaci auditu před spuštěním handleru, jednorázové
completion přes kopie/souběh, artifact audity npm/PyPI, modelový budget/rate/kapacity,
unused/pending/replayed stream, klientské credentials a chyby před/po prvním eventu.

## Zbývající rozsah

**H4 zůstává 🟨 rozpracováno.** H1 `NetworkPolicy/TypedGate` je na main, ale neexistuje
ověřené mapování jeho gate ID, `type`, upstreamu, metod a request/response limitů na
zdejší mounty, enabled stav, cooldown/artifact hosts, Git repo/push, audit/lifetime a
modelový budget/rate. Liší se i zoneID a množina operací (H1 `brew`/`model-api`). H1
wire se odmítá; neexistují implicitní oprávnění ani automatická migrace.

Loopback port **neautentizuje UID, session ani oblast**. `zoneID` je štítek statické
politiky, cizí lokální proces smí socket kontaktovat a Host hlavička není identita.
Chybí skutečný broker/auth, bind policy/pf, TLS/trust, perzistentní audit a produkční
service lifecycle. SIGTERM test dokazuje OS cleanup, nikoli graceful audit flush.
Deadline 120 sekund se kontroluje při socketovém I/O; upstream a resolver musejí
respektovat vlastní kontrakt cancellation/timeout. Pětimiliskundové polling čekání
není škálovací benchmark. Audit se po saturaci neobnovuje v rámci téže instance.

CLI opt-in může přes výchozí síťový upstream oslovit povolený hostname; tyto běhy
nebyly živou integrací a používaly jen fixtures. Model má pouze syntetický klíč.
Homebrew, skutečná Klíčenka/scopes/revokace, autentizace a živé API/billing zůstávají
mimo ověření. **Žádná brána ani R2/R3 tímto záznamem neprošla.**
