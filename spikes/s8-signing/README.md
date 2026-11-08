# S8 — částečná příprava signing a brokeru (WP1.A6)

**WP1.A6 zůstává rozpracované. S8 a SG-01…11 zůstávají Neověřeno.** Balíček dodává
spustitelnou statickou sondu vlastních syntetických artefaktů, čisté policy testy, omezený mock
fuzzer a plán šesti odlišných uživatelských experimentů. Nedodává produkční broker, XPC transport,
produkční autorizační cestu daemonu ani platný same-UID attach oracle. Nové [disposable service fixtures](SERVICES.md) dodávají sestavitelný SMAppService host, tři samostatné helper targets a úzké uživatelské UI. Nový [copy/signing handoff](HANDOFF.md) předá uživateli čtyři konkrétní podpisové příkazy bez změny původního ad-hoc manifestu; po handoffu automatický cleanup záměrně odmítá neznámý registration state. Konkrétní mezery jsou níže.
Historický `SOURCES.sha256` patří výhradně revizi a výsledkům 2026-11-03; nepřepisuje se pro dnešní HEAD. `SERVICE-SOURCES-20261104.sha256` je rovněž historický snapshot; aktuální handoff se dokládá testy a krátkou poznámkou ve VALIDATION podle GUIDE §11.
Autoritativní jsou [PLAN](../../PLAN.md), [GUIDE](../../docs/GUIDE.md) a [LAB](../../docs/LAB.md).

## Rozsah a oracle

| Případ | Spustitelná příprava | Co stále chybí |
|---|---|---|
| SG-01, SG-02 / R2 | `inspect`: Security API, validita všech architektur, runtime flag, explicitní absence obou názvů `get-task-allow`, známý formát entitlements | Agent/helper/sondy v L2; zde původní čtyři thin arm64 fixtures a čtyři staticky ověřené service targets |
| SG-03 / R6 | Identifikátor a hash ve statickém reportu | Stabilita identity/TCC přes rebuild; žádné granty ani TCC databáze se nečtou |
| SG-04 / R2 | `experiments`: Personal Team × tři služby; [sestavitelný disposable app](SERVICES.md), typované UI a startup observations | Uživatelský podpis/registrace, bezpečná host-only cesta daemonu, login/reboot a lifecycle oracle |
| SG-05 / R2 | Tři oddělené podmíněné self-signed scénáře | Žádné certifikáty/identity nebyly čteny ani použity; ad-hoc není self-signed ani Personal Team |
| SG-06 / R2 | Negativní signing policy testy pouze na hodnotách v paměti | Same-UID attach runner a srovnatelná pozitivní kontrola; viz samostatný postup níže |
| SG-07 / R2 | Změna jednoho syntetického markeru po podpisu → statická validace musí selhat | Nepřevzetí skutečných TCC grantů, bundle/rebuild scénáře |
| SG-08, SG-09 / R2 | `mock`: pevná syntetická zpráva, oddělená mock identita, replay/capacity a fuzzer | F2 Contracts/Broker chybějí. Žádná autentizace skutečného XPC audit tokenu nebyla ověřena |
| SG-10 / R2 | Mock odmítá globální ID, cizí/chybějící/zastaralou simulovanou capability | Přenos, vlastnictví, zánik a vyčerpání skutečných Mach práv / IOSurface |
| SG-11 / R2 | Path-like zprávy se nevejdou do mock schématu; vlastní soubory mají scope/type/hash/ACL kontroly | Helper path resolver, symlink/hardlink races a produkční TOCTOU mechanismus |

Žádná sonda nepřijímá PID, procesní jméno, libovolný podpisový cíl, příkaz, službu ani certifikát.
Původní `s8-probe` nevolá `register` ani `unregister`. Nové disposable UI má tyto dvě operace pouze pro LoginItem/LaunchAgent, po explicitní uživatelské akci a mimo ad-hoc profil; v implementátorské validaci se nevolají. Daemon mutace nejsou dostupné. Neexistuje `bootstrap`, `task_for_pid`, `ptrace`, TCC request ani zachytávání obrazu/vstupu. `prepare` nikdy nespustí vytvořenou binárku. Automatické testy nepotřebují
síť, účet, Keychain, databázi, root, nové uživatele ani změnu nastavení systému.

## Build a vlastní signing preflight [implementátor]

Apple Silicon, macOS 15+ pro kompilaci; akceptační cíl je macOS 27.x podle GUIDE. Swift 6,
jediná závislost je lokální `../common`. Spouštěj z kořene repozitáře. Následující cesty jsou
samostatné vlastní scratch/cache; použij nové jméno, pokud už patří jinému běhu.

```sh
env CLANG_MODULE_CACHE_PATH=/private/tmp/s8-own-clang-cache \
  SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/s8-own-swift-module-cache \
  swift test --build-system native --package-path spikes/s8-signing \
  --scratch-path /private/tmp/s8-own-build --cache-path /private/tmp/s8-own-package-cache
```

V sandboxu, kde vnořený SwiftPM sandbox nelze spustit, lze pro **tento vlastní lokální balíček**
přidat `--disable-sandbox`. Žádné balíčky se nestahují. `native` je v Swift 6.4 označené deprecated;
výchozí `swiftbuild` v Debug na ověřené konfiguraci **vkládá get-task-allow**. Testy jsou čisté
unit/mock testy; každá následně spuštěná CLI sonda vyžaduje samostatný signing preflight.

Po **každém rebuildu** připrav vlastní binárku (cestu vrátí `swift build` se stejným scratch a
`--show-bin-path`; u native typicky `/private/tmp/s8-own-build/arm64-apple-macosx/debug/s8-probe`).
Do vlastního souboru `/private/tmp/s8-own-empty-entitlements.plist` vlož
`<?xml version="1.0"?><plist version="1.0"><dict/></plist>`. Pak pouze pro tuto vlastní binárku:

```sh
/usr/bin/codesign --force --sign - --timestamp=none --options runtime \
  --entitlements /private/tmp/s8-own-empty-entitlements.plist \
  /private/tmp/s8-own-build/arm64-apple-macosx/debug/s8-probe
/usr/bin/codesign -dvv --entitlements - /private/tmp/s8-own-build/arm64-apple-macosx/debug/s8-probe
```

Oracle preflight: `runtime`, ad-hoc, žádný `get-task-allow` ani jiný entitlement. Nepřidávej signing
identity. `-` znamená ad-hoc bez Keychain; není to důkaz Personal Team. CLI navíc ověřuje podpis
**vlastního běžícího procesu** přes Security a při neznámých/nesprávných metadatech skončí s 3.

## Identita před každou sondou [implementátor / uživatel v L2]

1. Spusť podepsané `s8-probe context`. Je to diagnostika s `valid: null`, nikoli platné měření.
2. Před dalším během nezávisle zkontroluj očekávání: real/effective UID a GID, přesnou množinu kernel
   skupin, potřebné/zakázané skupiny, **přesné auditSessionID i auditUID**, manager name/UID a úplnou
   window session, případně výslovnou absenci. Host reference má vlastní očekávání; testovací UID
   nesmí sdílet host audit session. Prázdný seznam membership kontrol neověřuje další skupiny.
3. Vytvoř vlastní adresář `/private/tmp/sanjbox-s8-inputs-<UUID>` s módem `0700` a bez rozšířené ACL.
   Do jeho `s8-expectation.json` (`0600`, obyčejný soubor, jediný hardlink) ulož **zkontrolovaný**
   `candidateExpectation`. Nepřítomná window session se zapisuje jako explicitní `"windowSession": null`.
   Kandidát z diagnostiky se nesmí automaticky pokládat za schválený vstup L2.
4. Všechny příkazy kromě `context` vyžadují `--expect` s touto přesnou absolutní cestou. Sonda
   vypíše nejprve skutečnou identitu a shodu. Neshoda/unknown = exit 3, žádná fixture operace.

Parser odmítá duplicitní dekódované klíče (i Unicode alias), neznámá pole, float/exponent/boolean
namísto UID, neúplnou session, více než 16 KiB a hluboké objekty. Neotevírá obecné `*.json` mimo
vlastní pojmenovaný input root. Identita se sbírá stejnými veřejnými API do common `ProbeContext`;
lokální sběrač má omezené `launchctl managername/manageruid`, protože common sběrač timeout nemá.

## Statický cyklus [implementátor]

V příkladech `s8-probe` označuje přesnou vlastní podepsanou binárku a `EXPECT` výše připravený
soubor. `ROOT` je cesta vrácená **konkrétním** `prepare --apply yes`; žádná vlastní cesta cíle se nepřijímá.

```text
s8-probe prepare --expect EXPECT
s8-probe prepare --expect EXPECT --apply yes
s8-probe inspect --expect EXPECT --root ROOT --fixture hardened
s8-probe inspect --expect EXPECT --root ROOT --fixture plain
s8-probe inspect --expect EXPECT --root ROOT --fixture unsigned
s8-probe inspect --expect EXPECT --root ROOT --fixture tampered
s8-probe cleanup --expect EXPECT --root ROOT
s8-probe cleanup --expect EXPECT --root ROOT --apply yes
```

`prepare` a `cleanup` jsou výchozí dry-run. Příprava vytvoří nový soukromý UUID adresář v
`/private/tmp`, zapíše vložený C zdroj, kompiluje `clang -arch arm64 -O0` a podepíše pouze vlastní
fixtures `codesign --sign - --timestamp=none`. Původní stav: adresář neexistoval. Manifest obsahuje
vlastníka, původní skupinu a SHA-256 zdroje i čtyř výstupů; ostatní soubory/modifikace jsou odmítnuty.
Nikdy se nevytváří binárka s `get-task-allow`; tyto negativní případy existují jen v paměťových testech.

Oracle: `hardened` má exit 0, validitu 0, runtime true, adHoc true, entitlement absent a prázdné
`issues`; `plain` má exit 1 kvůli chybějícímu runtime; `unsigned` a `tampered` mají exit 1 kvůli
neplatné/neznámé signatuře. Odmítnutí vstupu nebo selhání nástroje není negativní signing kontrola.
Uchovej statusy a stderr všech čtyř; nulový exit samotný není verdikt S8.

`inspect` používá `SecStaticCodeCheckValidity` se strict/all-architectures/no-network, nepřeskakuje
executable ani resources. Přijímá jen thin arm64; policy metadat jedné architektury nelze zobecnit
na všechny slices. Nečte certifikáty a neprovádí trust/notarization check. Chybějící entitlements
dictionary při přítomném raw blobu znamená unknown. Požadovaný fixture profil nemá žádné entitlementy.

Cesty musí být kanonické podle POSIX `realpath`; finální soubor je otevřen `O_NOFOLLOW`, kontrolují
se fd/path inode, dev, UID/GID, hardlinks, mode, file flags, size, mtime/ctime a ACL před/po čtení. Při inspection
se porovnává hash a metadata před/po Security. Cleanup kontroluje i očekávané původní módy/skupinu;
pozdější změnu práv nepřepíše a nic nesmaže. **To není ochrana proti souběžnému útočníkovi se stejným
UID:** path-based Security API a oddělené kontroly nemají atomickou vazbu. Pouze vlastní quiescent fixtures.

Cleanup neprochází strom rekurzivně: unlink šesti ověřených názvů a rmdir prázdného vlastního rootu.
Opakované `cleanup --apply yes` po úspěchu je no-op. Při přerušení úklidu lze pokračovat, pokud
zůstal původní manifest a zbývající soubory stále odpovídají; inspect neúplný set odmítá.
Pád po posledním unlink před rmdir lze dokončit pouze pro prázdný ověřený vlastní UUID root.
Immutable/append flags a pozdější změny módu/ACL jsou odmítnuty před prvním unlink.
Při neúplné přípravě zůstane přesná cesta
v chybě; ručně zkontroluj jen vlastní uvedené názvy a jejich metadata, odstraň jednotlivě vlastní
nezměněné soubory a pak prázdný adresář. Nevyřešený konflikt uchovej. Žádné `rm -rf` s externí cestou.
Input, scratch a logy patří tomuto vývojovému běhu; nemaž sdílené cache ani jiné běhy.

## Mock broker a služby [implementátor]

```text
s8-probe mock --expect EXPECT --iterations 10000 --seed 21304
s8-probe experiments --expect EXPECT
```

Mock wire `S8M1` má přesně 32 B (frame) nebo 40 B (input), max 64 přijatých operací, monotónní
sequence, pevné zone/window, role/UID/session a generation. Identity a simulovaná rights jsou
oddělené oracle hodnoty v paměti; žádné audit tokeny/porty se nedekódují z wire. Fuzzer deterministicky
prochází 16 tříd odmítnutí, nejvýše 10 000 iterací; seed/corpus hash jsou v reportu. Oracle je
4 úspěšné pozitivní kontroly (před/po), n odmítnutých negativů, 0 unexpectedAccepts a prázdné failures.
Nejde o coverage-guided fuzzing, reálný XPC parser, paměťovou bezpečnost transportu ani race test.

Subprocess stdout+stderr má limit 64 KiB; `launchctl` 2 s, codesign 5 s, clang 10 s. Interní runner
nemá CLI passthrough. Synchronous membership/Security API nemají prokázaný vlastní hard deadline;
CLI má nouzový 45s process watchdog. Timeout 124 znamená neúplný běh, zachovat výstup/fixtures;
není to úspěšná izolace. OS scheduling, kernel I/O a potomci compileru nemají dokázanou časovou mez.
Ostatní exity: 0 splněný lokální oracle/diagnostika, 1 odmítnutí statické policy nebo mock nález,
2 usage, 3 neplatná identita/podpis sondy, 4 odmítnutý vstup/nástroj/úklid.

## Uživatelské experimenty a skutečné blokátory [uživatel, budoucí L2]

Po S1 a zapsané rezervaci/předregistraci LAB použij pouze disposable app s prázdným profilem.
Kontejnerová aplikace, tři oddělené helper targets, skutečná common identita ve startup observations a UI pro uživatelské služby jsou nyní v [SERVICES.md](SERVICES.md). Příprava byla pouze sestavena a staticky/ad-hoc ověřena. Daemon autorizační cesta a cleanup přes login/reboot zůstávají blokátorem; bez předem zajištěného úplného úklidu se lifecycle scénář nespouští.

Pro **každou** z šesti kombinací `experiments` uchovej exact bundle ID, build hash, signing metadata,
OS/build, uživatele/session, stav před registrací, výsledek registrace, startup marker, opětovný
login/reboot a úklid. Personal Team a self-signed mají vlastní záznamy; self-signed se zkoumá jen
pokud Personal Team neprojde. Ad-hoc není náhradní sedmá úspěšná varianta. Nikdo zde nevyhledává identity,
nečte Keychain ani certifikáty. Případnou budoucí práci s podpisovou identitou provádí uživatel zvlášť.

- **LoginItem:** vlastní helper bundle v `Contents/Library/LoginItems`; zaznamenej okamžité spuštění,
  další login a restart po nenulovém ukončení. Nepředpokládej obecný požadavek admin schválení.
- **LaunchAgent:** vlastní plist v `Contents/Library/LaunchAgents`, `BundleProgram` v containing app;
  registrace jednou pro každého uživatele. Zvlášť bezprostřední bootstrap a následující login.
- **LaunchDaemon:** vlastní plist v `Contents/Library/LaunchDaemons`; registrační požadavek a admin
  schválení jsou různé kroky. Před schválením nesmí běžet. Systémové schválení provádí pouze uživatel;
  nikdy z oblasti. Po schválení zvlášť reboot a cleanup. Úspěch ostatních služeb tento případ nenahrazuje.

Oracle cleanup: stejné `SMAppService` unregister z owning app, každý registrovaný uživatel zvlášť,
žádný vlastní živý helper a žádné opětovné spuštění po příslušném login/reboot. Až potom odstranit
vlastní app. Konflikt nebo chybějící lifecycle oracle blokuje uzavření slotu; neprovádět globální reset.

**SG-06:** chybí srovnatelná pozitivní kontrola attach, bezpečný child lifecycle runner a skutečný
SessionAgent. Budoucí runner smí přijmout jen child, který sám vytvořil z předem schválené vlastní
binárky, s ověřeným PID/start identity/UID/session a deadline. Nikdy uživatelský PID/procesní seznam.
Pouhá chyba attach bez pozitivní kontroly může znamenat chybějící oprávnění debuggeru, a tudíž je Nejasné.
GUIDE zakazuje `get-task-allow`; tento balíček takovou pozitivní fixture nevytváří. Před implementací
je nutné nalézt kontrolu slučitelnou s pravidly a preregistrovat ji. Žádný grant/capture ani paměť cizího
procesu se nečte. Zánik vlastního child musí být ověřen i při timeoutu, před uvolněním slotu.

**SG-03/07:** shodný identifikátor či úspěšná static signature nestačí pro stabilitu TCC. Potřebný
je uživatelský experiment s jedinou syntetickou app/rebuildem/modifikací a předem schváleným oracle;
TCC granty, Keychain a databáze zůstávají mimo automatiku. **SG-08…11:** skutečný fuzzer lze připojit
až k pevnému budoucímu rozhraní a implementaci brokeru. Testovat OS-získanou peer identitu, vazbu
audit token ↔ běžící kód ↔ session, revokaci, Mach rights i konkurentní změny. Mock toto nepokrývá.

Primární opory a jejich omezení: [RESEARCH.md](RESEARCH.md). Lokální vývojové výsledky:
[VALIDATION.md](VALIDATION.md). Žádný soubor zde není uzavřený protokol brány v `docs/evidence`.
