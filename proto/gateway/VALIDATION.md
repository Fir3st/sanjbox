# WP1.H4 — lokální revize a validace

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
