# WP1.H2 — syntetický životní cyklus UID

Swift 6 prototyp nad **skutečným automatem, manifestem, reportem a auditem H1** z
[`../contracts`](../contracts/README.md). Jediná SwiftPM závislost je tento lokální balík;
žádný externí balíček. Výstup splňuje offline rozsah H2 z IMPLEMENTATION §0/§3.
**Není to helper, bezpečné MVP ani důkaz izolace. LC-06, LC-11, R2, S0 a S4 zůstávají Neověřeno.**

Veškeré operace uživatele, svazku, bootstrapu, ochrany, procesů a úklidu mění jen inertní JSON
ve vlastní privátní fixture. Manifestové cesty se nikdy neotevřou. Kód nemá implementaci pro
skutečné UID, APFS, launchd, síť, signály ani TCC. `realStartAllowed` je vždy `false`.

## Použití a ověření

Z kořene repozitáře, **[implementátor]**, pouze syntetické testy:

```sh
swift build --package-path proto/lifecycle --scratch-path /private/tmp/sanjbox-h2-build -c debug
swift test --package-path proto/lifecycle --scratch-path /private/tmp/sanjbox-h2-build -c debug
swift build --package-path proto/lifecycle --scratch-path /private/tmp/sanjbox-h2-build -c release
swift test --package-path proto/lifecycle --scratch-path /private/tmp/sanjbox-h2-build -c release
```

Existující CI balíček automaticky objeví a spouští v Debug/Release; lokální dependency edge zajistí
H2 testy také při změně H1. Balík nepřidává službu ani integrační spouštěč. Jediný executable
`lifecycle-crash-driver FIXTURE ZONE OPERATION HOOK` je testovací worker: otevře existující vlastní
fixture, provede mock operaci a v přesně vyjmenovaném bodě skončí `_exit(77)`. Nepřijímá systémové
příkazy ani libovolný výstupní adresář. Testy používají syntetická UID 750/751; B3 příklad s UID 450
je platný návrh B3, ale nesplňuje minimum H1 lifecycle `501`, proto jej H2 jako oblast odmítne.

Knihovna: `LifecycleStore.create()` → `LifecycleCoordinator(store:)` →
`register(manifest:)` → `execute(_:zone:)`. `manifestReport(zone:)` vrací úplný H1/B3 report,
`audit(zone:)` H1 `AuditLog` a `inspect(zone:)` stav, rezervaci UID a konzervativní mock rozhodnutí.
Registrace stejného nezměněného manifestu je idempotentní; změna existujícího manifestu je konflikt.
Žádný manifestový warning se nepřeklasifikuje na ověřenou topologii.

## Automat, admission a rezervace UID

H2 neduplikuje povolené přechody: replay volá `ZoneStateMachine.assignIdentity/apply` z H1.
Vstupy a persistované manifesty validuje `StateManifestSchema`; report stále říká
`deploymentReady: false`. Audit má jeden H1 log na oblast, souvislé pořadí od 1 a akce host control
plane (`actorUID: 0`). Audit je součástí stejného potvrzení jako dokončená operace; úspěch nevznikne
před koncem. Známé selhání bez efektu přidá `failed`; odmítnutí vstupu vrací chybu bez změny deníku.
Výchozí timestamp je pevný syntetický čas; volající může dodat validovaný clock closure.

| Operace | Mock kroky v přesném pořadí | Přechod H1 |
|---|---|---|
| start | vytvořit uživatele; všechny manifestové svazky; ochrany; bootstrap; ověřit running | created → starting při begin; running až při finish |
| pause | blokovat admission; odvolat síť/IPC; zmrazit celé UID; ověřit pause | running → paused až při finish |
| resume | ochrany; obnovit celé UID; ověřit running | paused → running až při finish |
| stop | blokovat admission; odvolat síť/IPC; bootout GUI i user domény; odstranit joby; ukončit celé UID; ověřit nulu; ověřit zákaz restartu | starting/running/paused → stopping při begin; stopped až při finish |
| cleanup | znovu ověřit nulu; zákaz restartu; odstranit svazky; uživatele; ověřit úplný úklid | stopped → cleaning při begin; cleaned a uvolnění UID současně při finish |

- Globální deník rezervuje UID atomicky s `begin(start)`, před první mock operací. Registrace
  manifestu ještě UID nevlastní. Jiná oblast smí UID skutečně získat až po platném `finish(cleanup)`.
  Kontroluje se také replay; správný hash zfalšovaného přechodu nestačí. `uidReusable` zohlední také
  nové přidělení UID jiné oblasti. Jedna fixture je jeden celý syntetický control-plane namespace;
  nezávislé fixtures nekoordinují skutečná UID. GID není alokátor UID.
- `mockAdmissionAllowed` čte celý deník a ověří celý mock svět při každém požadavku. Povolení platí
  pouze pro `running` bez rozpracované operace. Není to přenositelná capability ani launch API.
  Během stop a po něm jsou start/resume zakázané; vyčištěná oblast je terminální, nová musí mít nové ID.
- Backend modeluje GUI, user-job, CLI, detached i stopped procesy. Bootout ponechá CLI/detached/stopped;
  teprve whole-UID termination je odstraní. Stopped vyžaduje nulu, zablokované admission/síť/IPC,
  chybějící domény a joby. Pause zmrazí všechny třídy a zablokuje nové přijetí.
- Nedokončený start lze z dokončeného checkpointu výslovně zastavit přechodem H1 starting → stopping.
  Nejasný pending intent nepovolí ani tento automatický zásah. Pause/stop/cleanup jsou po úspěchu
  idempotentní; opakovaný start/resume nepřekryje zakázaný přechod H1.
- Jakýkoliv pending intent nebo drift blokuje celý společný alokátor; problémy jiné oblasti se
  neignorují. Jde o úmyslně konzervativní dostupnost malého prototypu.

## Trvalý deník a obnova

Model vychází z [B4 recovery](../../spikes/s4-state/RECOVERY.md): záměr bez potvrzení je nejasný,
shoda nynějších bytes neprokazuje vlastnictví efektu. Není zde force, odhad výsledku, automatické
mazání orphanů ani rollback host policy. H2 neimplementuje snapshot/restore ani B4 witness adapter.

Každá fixture vznikne exkluzivním `mkdtemp` pod `/private/tmp/sanjbox-h2-*`, mode 0700. Má `lock`,
`head.json`, `world.json` a `000000.json`… události. `flock(LOCK_EX | LOCK_NB)` na descriptoru adresáře i lock souboru drží výlučnost po dobu
života store; výměna jména lock nevytvoří druhou doménu zámku. Každé I/O znovu kontroluje named lock
proti drženému fd (`fstatat` bez následování symlinků), jeho owner/mode a single-link identitu. Jeden koordinátor provádí synchronní operace; Swift 6 jej nedeklaruje `Sendable`.

```text
register(manifest + audit)
begin(operation)                         # rezervace / přechod stopping/cleaning
  intent(step) → durable mock world → done(step)
  intent(step) → prokázaný no-effect → retry(step + failed audit)
finish(operation + success audit)        # release UID pouze zde při cleanup
```

Události tvoří append-only SHA-256 řetěz od `genesis`; oddělený head váže počet a poslední hash.
Chybějící konec, mezera, orphan event/replacement, neznámé jméno, pořadí, schéma, duplicitní/unknown
JSON field a nekánonické bytes se odmítnou. Replay kontroluje celý stavový automat, přesné kroky,
manifest a audit. Limity jsou 64 registrovaných oblastí, 2048 událostí a 1 MiB na soubor; vyčerpání
kapacity neautorizuje dokončení ani uvolnění identity.

Soubory se otevírají relativně k drženému descriptoru s `O_NOFOLLOW`, `O_NONBLOCK`, kontrolou
regular/single-link, owner UID a mode 0600; FIFO neblokuje read. Kontroluje se identita cesty rootu
a stabilita metadat při čtení. Efekt a head používají exclusive `replacement.json` + rename;
není to atomická transakce napříč soubory. Po chybném zápisu/flush je instance otrávená do deny.
Nová instance ověří a znovu `fsync`ne každý použitý soubor a adresář. Cache platí pouze pro přesná
metadata + bytes, které tato instance už úspěšně flushnula; změněné bytes se znovu parsují.
Úplný checkpoint může po úspěšném novém flush pokračovat, částečný zůstává zachován k review.

| H1 crash point | H1 akce | H2 při fresh recovery |
|---|---|---|
| beforeIdentityCommit | refuseAndRollbackToCreated | created, žádná rezervace/efekt; lze znovu startovat |
| afterIdentityCommit | denyStartUntilCleanup | dokončený checkpoint odvodní přes stop; UID zůstane rezervované |
| beforeProtectionsArmed | denyStartUntilCleanup | stejné; pending intent vždy přísnější karanténa |
| afterProtectionsArmed | denyStartAndRequireReview | žádné automatické obnovení startu |
| duringPause | denyStartAndRequireReview | žádné automatické obnovení pause/resume |
| beforeQuiescence | denyStartUntilCleanup | pokračování dokončeného stop checkpointu; nejasný intent deny |
| afterQuiescence | denyStartUntilCleanup | dokončit stop, ponechat UID do cleanup |
| duringCleanup | resumeCleanup | pokračovat pouze z dokončeného checkpointu |
| afterCleanupCommit | identityReusable | cleaned a prázdný backend znovu ověřit, teprve pak reuse |

Tabulka má doslovný testový oracle pro všech devět bodů H1. Přerušený resume je navíc konzervativně
review-only. Nový koordinátor nesmí pravidla obejít přímým `execute(start/pause/resume)`.
Nejednoznačný intent při kterémkoliv kroku vyžaduje review a nikdy se sám neopakuje.
Známé no-effect selhání lze opakovat v živém koordinátoru, ale příslib se nejprve kontroluje proti
celému očekávanému světu; lživý příslib nechá pending intent. Po restartu platí přísnější H1 pravidla.

## Oracle, úklid a hranice důkazu

[Testy](Tests/SanjboxLifecycleTests) ověřují všech 24 kroků pěti operací, 116 hranic přes skutečný
`_exit(77)` testovacího procesu a nový store/koordinátor, všechny H1 crash pointy, no-effect/uncertain
chybu v každém kroku, LC-06/11 včetně druhé oblasti, whole-UID stavy, striktní replay, drift, audit,
metadata a I/O chyby. Další table-driven kontroly nejsou laboratorní akceptační případy.

`destroyCompletedFixture()` je výslovný úklid pouze kompletně vyčištěných, znovu validovaných oblastí.
Odmítá pending, neznámý stav a cizí entries; flat descriptor-relative unlink nepoužívá rekurzi.
Test harness vlastní své známé poškozené fixtures a uklízí je samostatnou flat cestou s kontrolou
identity rootu. Pád celého test runneru může fixture zachovat; prototyp ji neodstraňuje při příštím
startu. Build cache je samostatná a lze odstranit pouze vlastní zvolený scratch adresář.

**Meze:** namespace vlastní vývojářské UID, nikoli root oddělený od oblasti. Hash není podpis;
nechrání proti host vlastníkovi, který vrátí celý namespace do staršího stavu. Zámek chrání
spolupracující store, nikoli škodlivý host proces; kontroly jmen nejsou atomic compare-and-swap.
Není validace ACL všech předků ani produkční ochrana adresáře. `fsync` a process crash nejsou
power-loss/device/reboot důkaz. Identita bootu se nemodeluje. Žádná modelovaná nula procesů,
zmrazení ani odmítnutí restartu nedokazuje OS admission interlock přetrvávající smrt helperu.
Skutečné mechanismy a integrace čekají na WP2.2 a příslušné brány/lab; bezpečná pauza/stop hosta
z tohoto balíku neplyne. Výsledky konkrétního sestavení jsou ve [VALIDATION.md](VALIDATION.md).
