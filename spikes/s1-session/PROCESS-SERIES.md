# WP1.A2 — registrované procesní časové řady

Přípravná instrumentace **bez verdiktu S1/P4**. Nový `process-series` měří reálné předem
registrované instance testovacích aplikací pod stejným UID jako collector. Samostatný
`owned-process-series` ověřuje stejný sampler na dvou vlastních dětech. Původní `process-memory`,
`SupplementaryBundle`, systémový RAM recorder a jejich historické důkazy se nemění.

## Registr a původ cíle

```text
sanjbox-s1-instrument process-series --series-json JSON --expect-json JSON [--apply]
sanjbox-s1-instrument evaluate-process-series --fixture NAME --run-id ID [--apply]
sanjbox-s1-instrument owned-process-series --run-id ID --expect-json JSON [--apply]
```

Příklad **syntetického** registru, nikoli lokální očekávání:

```json
{"runID":"example-registered-series-20261106","seconds":10,"registrations":[{"slot":1,"identity":{"pid":42001,"uid":4501,"realUID":4501,"startSeconds":1800000000,"startMicroseconds":12345},"role":"application","provenanceSHA256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}
```

Operátor v testovací relaci předem připraví 1–32 záznamů ze svého kontrolovaného spuštění aplikací.
Každý obsahuje jedinečný slot 1–32, PID, skutečný i efektivní UID, BSD start v sekundách a mikrosekundách,
omezenou roli a SHA-256 samostatně uchovaného podkladu registrace. Role jsou `application`, `renderer`,
`simulator`, `emulator`, `keeper`, `ownedAllocationFixture`, `ownedTransientFixture`. Záměrné role
nepotvrzují skutečný typ programu; důkaz původu musí reviewer zkontrolovat. Collector hashovaný podklad
neotevírá (`provenanceArtifactsVerified:false`). Explicitní registr **není** oprávnění inventarizovat
osobní aplikace; v L1 patří pouze kontrolovaným testovacím procesům.

Není zde libovolný `--pid`, command, executable path, shell ani výčet UID. Každý cíl musí mít shodné
real/effective UID s předregistrovaným očekáváním collectoru; jiné UID se odmítne ještě před datasetem
nebo čtením cíle. Proces aplikace se musí narodit a jeho číselná instance být zaregistrovaná před
spuštěním běžného registru. Nové externí děti aplikace vzniklé po uzavření registru tento režim
**neobjeví**. Další registrace vyžaduje nový běh; nerebinduje se starý PID ani nepřepisuje původní raw.

WindowServer a klienti pod jiným UID zůstávají nepokrytí. I bezchybný registr je jen pokrytí jeho
explicitních instancí, nikoli úplná atribuce UID, tří relací, sdílených služeb nebo systému.
`fullSessionAttributionComplete`, `unregisteredProcessesCovered`, `windowServerAttributionComplete`
a `crossUIDClientAttributionComplete` jsou vždy `false`.

## Kontroly, čas a výstupy

Dry-run validuje pouze inline JSON; nečte metadata procesů, identitu, podpis ani fixture a nic
nezapisuje/nespouští. `--apply` nejprve ověří přesný vlastní UID/GID, kernel groups, autoritativní členství,
process/window ASID, audit UID, Aqua manager a konzolovou roli podle [INSTRUMENTATION](INSTRUMENTATION.md).
Očekávání je samostatně zkontrolované a zapsané **před** během, nikdy automaticky nahrazené detekovaným
kontextem. Neshoda vytvoří raw s chybou, bez bindings, okna a samples; exit 3. Aktuálně běžící collector
musí mít ověřený podpis, hardened runtime a nepřítomné **oba** `get-task-allow` klíče, i kdyby byly false.
Neplatný podpis skončí exit 2 před datasetem/čtením cíle. Pouhý ad-hoc podpis není S8/TCC identita.

Nový create-exclusive dataset role `process-series` má `intent.json` (plán a očekávání), `registry.json`
(před čtením cílové paměti), `samples.jsonl`, `recording.json` a `report.json`. Writer používá držené directory FD,
O_NOFOLLOW, owner/mode kontroly, `0700`/`0600`, O_EXCL a fsync; původní výsledky nikdy nepřepisuje.
Journal vzniká jednou přes O_EXCL a drží vlastní FD; do **tohoto nového** souboru se během acquisition
připisuje compact JSONL `schemaVersion/runID/sequence/window/point` a provede fsync bezprostředně po
každém readu (včetně nečitelnosti/notRegistered), před dalším readem nebo wait. Má nejvýše 32×602 bodů,
4 KiB na řádek a 32 MiB celkem. Po uzavření se už neotevírá k zápisu. To není claim odolnosti proti
power loss. Normální registry zůstává po dobu celého běhu neměnný. Chybějící/zániklá instance se nevyřadí z registru.

Časové okno je 1–600 s, kadence 1 s a skutečný koncový vzorek; zmeškané termíny se přeskakují. Každý
read uloží čas začátku/konce a porovná PID, real/effective UID a start před i po
`proc_pid_rusage(RUSAGE_INFO_V4)`. `PROC_PIDTBSDINFO` vrací širší kernel strukturu; kód z ní vybírá pouze
číselnou identitu, nikdy nekopíruje jméno/comm. Nečte cesty, argumenty, environment ani obsah paměti,
nepoužívá task port. After-check proběhne i při chybě rusage. Neshoda instance před čtením zabrání rusage;
neshoda po čtení zahodí získaná čísla. Jde o dvě metadatové kontroly kolem readu, ne atomický kernel
snapshot ani bezpečnostní handle. Rychlý transient UID drift mezi oběma kontrolami nelze vyloučit.

Raw uchová `notRegistered`, `unreadableBefore`, `identityChangedBefore`, `readFailed`, `unreadableAfter`
a `identityChangedAfter`, před/po identity a číselný errno podle dostupnosti. Exit se konzervativně
projeví jako nečitelná registrovaná instance: samotné errno nedokazuje příčinu. Failed sample nemá
paměťové metriky; **není nulou**. Skutečná číselná nula je platná. Časová mezera >2 s, read >1 s,
chybějící/opožděné endpointy, arrival uvnitř okna, změna identity či chyba vedou k neúplnosti. Tolerance
začátku ≤100 ms a konce ≤1 s jsou diagnostické kontroly acquisition, **ne změna LAB/F0.8 prahů**.

CLI má self-only watchdog `ceil(seconds)+30 s`, fixture runner 30 s; ukončený/zaseknutý běh může
zanechat intent/registry, dosavadní journal a případný částečný poslední řádek. Úplné již zapsané
řádky zůstávají i při SIGTERM/SIGALRM. [Offline inspektor](JOURNAL-INSPECTOR.md) nyní kontroluje
explicitně staged kopii prefixu včetně byte hashů, framingu, schématu a konzistence; vždy vrací
neúplné/neověřené tvrzení, nikdy kompletní acquisition nebo verdikt;
bez řádného final recording/report je běh neúplný. Při přerušení uprostřed posledního write může být
poslední řádek částečný; dřívější řádky se nevyhazují. Automatická recovery ani verdikt z prefixu nejsou
implementované; inspekce původní journal neotevírá k zápisu ani neopravuje. Dřívější review repro ztráty bodů před touto opravou zůstává zachované. Žádný kód
neopravuje ani nemaže starý raw. Knihovní API bez CLI watchdogu vyžaduje vnější supervision, protože
zděděné identity helpery a kernel API nemají vlastní deadline.

Report počítá count/min/nearest-rank median/p95/max **samostatně pro každý proces a zvlášť** footprint
versus resident. Nikdy nesčítá procesy, RSS s footprint ani cokoli se `systemDeltaM`. `acquisitionComplete`
je jen struktura/časové pokrytí registrované řady, ne výkonový pass. `fullWindowComplete` jednotlivého
procesu nezastupuje globální collector identity/clock issues; celková platnost je `acquisitionComplete`.

Offline `evaluate-process-series` čte výhradně vlastní ručně staged regular JSON
`/private/tmp/sanjbox-a2-fixture-<uid>-<NAME>.json` přes stávající bounded reader (32 MiB, žádné symlinky/
hardlinky). Rekurzivně odmítá neznámé/duplicitní klíče a null optional fields. Report v novém datasetu
nikdy neověřuje pravdivost dodaného `source`/hash/identity tvrzení; vyžaduje původní evidence/provenance.
Exit 0 = úplná acquisition, 3 = neúplná/nesprávná identita, 2 = malformed/I/O/signature.

## Pevně omezená vlastní child validace

`owned-process-series` předem zapisuje sloty/plán a spustí výhradně aktuální vlastní CLI, bez volby
příkazu, shellu nebo cizího programu. Děti mají prázdný environment, privátní pipes, stejná předem
zadaná očekávání a samostatný runtime/signature gate. Jejich protokol akceptuje jen slot 1 nebo 2 a
číselný rodičovský PID; samostatné spuštění vyžaduje `--apply`, obě pipes a shodu rodiče. Není to obecný
launcher. Worker má vlastní 15s alarm i při selhání common identity helperu.

- Slot 1: vznikne před oknem, po armování čeká 1,2 s, alokuje a dotkne 16 MiB, lifetime nejvýše 10 s.
- Slot 2: vznikne při ticku kolem +2 s šestisekundového okna, alokuje 8 MiB, skončí po 1,5 s.
- Před armováním rodič ověří handshake, vlastní child PID/start/UID, identitu/podpis a zapíše
  `registry-1.json` / `registry-2.json`. Teprve jediný byte `G` povolí alokaci. Unregistered slot před
  narozením zůstává v raw; po zániku se dál zaznamenávají nečitelné reads. Registry2 uvnitř okna a zánik
  záměrně dávají **exit 3 / acquisitionComplete:false**, i když pozitivní validace mechanismu prošla.
- Úklid zavře pouze vlastní vstupní pipe; dítě skončí na EOF nebo deadline. Nesignalizuje cizí/numerický
  PID. `ownedCleanupComplete` vyžaduje potvrzený exit obou `Process` objektů. Výsledky mají skutečné časy
  alokace a konce, konečnou identitu a důvod ukončení; žádný byte alokovaného obsahu se neloguje.

Reprodukovatelný [CLI validační script](Tests/process_series_validation.py) navíc spustí jednoho
vlastního workera a použije jeho zapečetěnou registraci v **běžném** `process-series` CLI. Předem určený
oracle: 4 s, ≥5 bodů, růst footprint ≥8 MiB při známé 16MiB alokaci. To je kontrola nástroje, nikoli P4.
Ověří dry-run, unknown fields, duplicitní registry, foreign UID, špatný collector ASID, živý pozitivní
sběr, konfliktní reuse output, offline report, zánik, nativní birth/exit, SIGTERM/SIGALRM po dvou zapsaných bodech a uchování prefixu. SIGALRM test ověřuje stejný signal handler jako watchdog, nikoli skutečné uplynutí deadline. Výchozí režim scriptu je dry-run.
Při selhání uchová dosavadní výsledky. Maže pouze přesně evidované vlastní staged JSON po inode/owner
kontrole; všechny datasety a logy zůstávají. Samostatný source/build scratch se uklízí až po validaci.

## Ověřené zdroje API a zbývající mezery

Překlad/typy ověřeny v aktivním macOS SDK (`libproc.h`, `sys/proc_info.h`, `sys/resource.h`). Apple
[libproc implementation](https://github.com/apple-oss-distributions/xnu/blob/main/libsyscall/wrappers/libproc/libproc.c)
a [rusage_info_v4](https://developer.apple.com/documentation/kernel/rusage_info_v4) popisují použitá API.
Na konkrétním systému funkčnost dokládá vlastní nativní Release validace, nikoli samotná existence API.

Zbývají skutečné L1 aplikace/tři relace, úplný registr procesů a jejich nových dětí, doložené WindowServer/
klient/keeper vazby, W0 systémové baselines, workloady a ostatní LAB/P4 důkazy. Výstup se nesmí označit
za úplnou procesní atribuci, reálný třírelační výkon ani za uzavřený A2/S1. Současný stav a historické
počty testů jsou beze změny zachované ve [VALIDATION](VALIDATION.md).

## Samostatné dynamické potomky (2026-11-08)

[DESCENDANT-MEMORY.md](DESCENDANT-MEMORY.md) přidává oddělený skutečný sběrač potomků
registrovaného same-UID test rootu. Pevný registr, jeho journal/analyzer a výše uvedené historické
výsledky se nemění; polling neposkytuje úplnou atribuci UID/relace.
