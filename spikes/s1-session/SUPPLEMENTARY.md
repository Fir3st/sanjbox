# WP1.A2 — doplňující instrumentace (2026-11-04)

**A2/L1 je stále partial, S1 a GUI-01…13 Neověřeno.** Tento doplněk nemění LAB-v1 ani F0.8.
Původní [presentation/system RAM recorder](INSTRUMENTATION.md) a jeho schema v1 zůstávají samostatné.
Nové zprávy výslovně odlišují skutečný marker, vlastní recorder a externě dodaná syntetická tvrzení.

| Mezera | Implementováno | Zbývá |
|---|---|---|
| Login čas | Monotónní `login-marker`, přesná identita/podpis, boot/UTC kotva; offline kontrola start/ready/timeout, rolí, nejistoty a provenance | Automatické zachycení posledního potvrzení credentials a prvního interaktivního frame; kalibrace event-to-marker, skutečné first-run/cold/warm/resume série, agregace požadovaných 10/30 opakování |
| Procesní RAM | `process-memory`: **jen vlastní běžící recorder fixture**, registrace PID/UID/čas vzniku před alokací, `proc_pid_rusage(RUSAGE_INFO_V4)` pro footprint a resident bytes; rozpad jednotlivých záznamů bez součtu | Všechny procesy UID, WindowServery, klienti/keeper, skutečné aplikace a jejich úplná atribuce; korelace se systémovým ΔM a skutečný W0 stav |
| Aplikace | Přísný offline intake pro externě dodaná syntetická WX/WA/WE/WS/WM data; tři cykly, identity, procesní role, časová okna, výstup/vstup/backend, WebGL začátek/konec, uchování selhání | Automatické adaptéry Xcode/Simulator/Android/Electron/Safari, skutečné výstupy a kalibrace, ověření hashovaných artefaktů, souběh tří relací, host akce, WM rotace |

Žádný příkaz nevytváří uživatele/relaci, neprovádí login ani nespouští reálné aplikace. Žádná inventura
PID, cesty/jména procesů, argumenty nebo environment; žádné TCC/capture, Klíčenka, credential store,
databáze, sudo, systémová instalace nebo změna nastavení. Nový živý paměťový collector má záměrně
jediný cíl `getpid()`. Nelze mu předat jiný PID ani „shared WindowServer“ roli.

## Společná pravidla

```text
sanjbox-s1-instrument login-marker --marker-json JSON --expect-json JSON [--apply]
sanjbox-s1-instrument process-memory --memory-json JSON --expect-json JSON [--apply]
sanjbox-s1-instrument evaluate-supplement --fixture NAME --run-id ID [--apply]
```

Dry-run validuje inline vstup, nečte fixture/identitu/podpis, neměří a nezapisuje. `--apply` živých příkazů
nejprve zachytí očekávaný kontext a ověří vlastní běžící signature přes Security (no-network validity,
hardened runtime, nepřítomnost **obou** `get-task-allow` klíčů i s hodnotou false). Tato podpisová brána
nyní platí i pro původní `record` a `offscreen`. Chybějící/nerozparsované entitlementy fail-closed; žádná
signing identity se nehledá. Ad-hoc runtime podpis není stabilita TCC identity ani důkaz S8.
Po posledním buildu je stále nutné binárku ověřit před aktivními testy.

`--expect-json` má beze změny přesný kontrakt z INSTRUMENTATION.md. Očekávání musí být předregistrované;
nikdy se nedoplňuje automatickým schválením právě zjištěného kontextu. Chybějící window session není
omluvena tím, že nástroj běží pod správným UID. Neshoda zůstane v raw a vrací 3 bez workloadu.
Nedostupný/nebezpečný podpis vrací 2 před vytvořením datasetu nebo paměťovou sondou.

Dataset a staged fixture mají stejná pravidla `0700`/`0600`, create-exclusive, O_NOFOLLOW, owner/type/link/
size kontrol jako původní writer. Nové role datasetu jsou `login-marker` a `process-memory`.
Výstup se nikdy nepřepisuje ani neappenduje. Nepovinná JSON pole se **vynechávají**, neposílá se `null`.
Nové schemas odmítají neznámá pole rekurzivně, duplicitní klíče včetně escapovaných, neplatné enumy,
nefinite hodnoty, přebytečné argumenty a překročení mezí. Inline limit 16 KiB, fixture 32 MiB, hloubka 24.

## Login marker a jeho skutečný význam

Příklad je syntetický, `targetUID` ani `--expect-json` se nesmí převzít jako lokální očekávání:

```json
{"runID":"example-marker-20261104-a1b2c3d4","attemptID":"example-attempt-a1b2c3d4","configurationSHA256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","mode":"warm","event":"start","targetUID":4501,"order":1,"activeOtherZones":2}
```

`mode`: `firstRun`, `cold`, `warm`, `resume`, `reconnect` se nikdy neslévají. `event`: `start`,
`clientConnected`, `desktop`, `firstFrame`, `ready`, `timeout`. Každý marker má nové `runID`; všechny
markery jednoho pokusu sdílejí `attemptID`, konfiguraci, mód, cílový UID, pořadí 1…3 a počet ostatních
aktivních oblastí 0…2. `start`/`timeout` patří host konzoli s jiným UID; `ready` patří cílové nekonzolové
relaci. Pouhý název události **neznamená**, že ji collector pozoroval.

CLI uloží `LoginMarker` do `recording.json` s `source: measured-marker`, skutečným časem až po kontrolách,
identitou a podpisem. Je to čas spuštění obsluhy markeru, **nikoli** automaticky čas login/ready události.
Nezná zpoždění ručního spuštění ani latenci kontrol, neposkytuje kalibraci. Zákaznické credentials vůbec
nevidí. Jeho použití umožní korelaci, nikoli potvrzení cíle <2 s; evaluator takový pokus označí neúplný.

Operátor sestaví kopii `{"schemaVersion":1,"login":[{"markers":[START,READY]}]}`. Každý prvek je celý
nezměněný `LoginMarker`; původní raw/hashes zůstanou. U externího syntetického časového recorderu se
použije `source: external-synthetic` (v testu `fixture`) a u start/terminal markerů:

- `eventDelayBoundSeconds`: doložená horní mez vazby událost→timestamp (0…60 s), ne jen rozlišení hodin;
- `calibrationSHA256` a `observationSHA256`: SHA-256 externě uchovaného syntetického podkladu;
- skutečné hodiny stejného bootu, očekávání, identita a informace o podpisu. Intake je sám neměří.

Tyto hashe se zde **neotevírají ani neověřují**. Reviewer musí zkontrolovat podklad a kalibraci mimo
intake. Nelze přeznačit `measured-marker` a přidat mu nulovou nejistotu; takový vstup je odmítnutý.
Offline korektnost hash řetězce není důkaz pravdivosti dodaných tvrzení.

Výstup zachová zdroje, konfiguraci, UID, mód, pořadí, počty aktivních oblastí a jednotlivé výsledky.
`markerIntervalSeconds = terminal.monotonic − start.monotonic`. Horní event délka přičítá obě kalibrační
meze a obě nejistoty clock stamps. Bez nich je vynechaná. Warm/resume vyžaduje nejistotu ≤10 ms dle LAB;
warm navíc dvě ostatní aktivní oblasti. Timeout před 60 s je neúplný; zaznamenaný timeout ≥60 s zůstane
`timeout`, pozdější ready `ready-after-timeout`, nikdy vyřazený úspěch. Nezaměňuje se timeout s chybou
parseru. Report nepočítá přijímací medián/p95 celé série a nedává performance pass.

Až 300 pokusů, každý 1…6 unikátních událostí. Start musí být první, ready/timeout poslední a vzájemně
výlučné. Neshodné boot/UTC, obrácený čas, směs konfigurací, duplicitní pokusy/run IDs nebo role jsou
neplatné/neúplné. Reportované `timingEvidenceComplete` popisuje pouze dodaný časový záznam.

## Vlastní procesní paměť

```json
{"runID":"example-memory-20261104-a1b2c3d4","seconds":3,"fixtureMiB":4}
```

`seconds`: 1…600 s, `fixtureMiB`: 0…64 celých MiB. Po úspěšných kontrolách se v `intent.json` uloží vlastní
PID, UID, BSD čas vzniku (s/µs) a pevná role `owned-recorder-fixture`. Teprve potom se vytvoří a dotkne
syntetická alokace a měří vlastní proces. Footprint **zahrnuje collector a jeho knihovny**, není to čistá
velikost syntetické alokace ani reálné aplikace. Záměrně není jiný PID argument, čtení přes task port ani
mapování celého UID. Registry pro privilegované externí procesy by byl jiný, dosud chybějící mechanismus.

Každý skutečný vzorek ověří PID/UID/start před i po `proc_pid_rusage`; změna/reuse nebo nečitelnost uloží
chybu s vynechanými metrikami, nikdy nulovou paměť. Nula je naopak explicitní platná číselná hodnota.
Vzorkování po 1 s přeskakuje zmeškané termíny, konečný vzorek je až po plánovaném konci. Dataset uchová
skutečné měřicí okno, počáteční/konečný kontext a chyby. Výpadek >2 s, chybějící konce nebo mimočasový
vzorek vede k neúplnosti. Povolená odchylka prvního vzorku ≤100 ms a koncového ≤1 s jsou diagnostické
kontroly tohoto collector acquisition, **ne nové akceptační cíle P4**. API mají stejné omezení vnějšího
watchdogu jako původní recorder; kill může ponechat jen intent. Alokace je uvolněna při návratu.

Raw je `SupplementaryBundle` s jediným polem `memory: [ProcessMemoryRecording]`. Offline report vrací
počet/minimum/nearest-rank medián/p95/max odděleně pro footprint a resident bytes jednotlivých procesů.
Nesčítá je mezi sebou ani se systémovým ΔM; žádná souhrnná per-session hodnota se nepočítá. Duplicitní
instance `(boot,pid,start)` se odmítá i při změně UID/role/runID. `fullSessionAttributionComplete` je vždy
`false`. Nečitelné/missing vzorky zůstanou v raw a ve stavu neúplnosti, ze statistik se nestanou nuly.
V této implementační validaci nebyl žádný úspěšný živý běh tohoto collector; ověřen byl překlad,
fixture analýza a strict identity rejection bez registrace/vzorků.

## Externí syntetické aplikace

Vstup: `{"schemaVersion":1,"workloads":[ApplicationWorkload,...]}`; nejvýše 128 záznamů s unikátními
run IDs. Typy a přesná pole jsou v [ApplicationEvidence.swift](Sources/S1Instrumentation/ApplicationEvidence.swift).
Spustitelné syntetické příklady skládá [CLI validation](Tests/cli_validation.py); nejsou naměřená data.

Každý záznam obsahuje `source` pouze `fixture` nebo `external-synthetic`, `profile`, `workload` a
`application`, verze appky/runtime, fixture/preregistration SHA-256, rozměry/scale, očekávání a skutečné
identity, boot/UTC začátek/konec a pevné `window`. `lab-v1-draft` má 600 s; `diagnostic` 1…30 s.
Mapování je WX→xcodeSimulator, WA→androidEmulator, WE→electron, WS→safari; WM dovoluje jednotlivé role,
ale tento intake **neověřuje rotaci ani kompletní smíšený blok**.

- `cycles`: přesně 3 sekvenční start/run cykly před hlavním oknem; Xcode navíc build. Každý má index,
  skutečný start/end, `success/failure/unknown` a hash výstupu. Chybějící cyklus/build je neúplnost.
- `processes`: nejvýše 32 dodaných vazeb PID/UID/start/role/hash. `application` je povinná; WX vyžaduje
  `coreSimulatorService`, WA `emulator`; další možná role `renderer`. Duplicita PID a cizí UID nesmí
  vytvořit zdání správné atribuce. Žádný z těchto procesů se živě nečte.
- `observations`: nejvýše 6000 časovaných tvrzení `kind/time/outcome/artifactSHA256`. Povinné druhy:
  `changingOutput`, `inputResponse`, `presentedOutput`, `acceleratedBackend`, `processContinuity`,
  pro Electron/Safari také `webglCheck`. Každý má začátek/konec okna s tolerancí 1 s. Kontinuita má
  nejvýše 2s mezeru. Jde o kontrolu pokrytí externího schema, nikoli nový benchmark ani důkaz,
  že periodické sighting nemohlo minout zánik procesu. Reviewer musí ověřit identitu instance v raw.

`recordComplete` znamená vyplněné, konzistentní schema. `reportedFailures` uchová každé dodané selhání,
i když je záznam jinak úplný. `unknown` dává neúplnost. `artifactsVerified` je vždy `false`; samotné
hash řetězce, deklarace backendu, PID nebo rAF nejsou důkaz prezentace/akcelerace. Žádná dodaná data se
nepřeznačují na námi `measured`. Externí screenshot/obraz/video se zde neotevírá a nesmí obsahovat osobní data.

## Vyhodnocení a návratové kódy

`evaluate-supplement` čte jen ručně připravenou vlastní regular fixture bez symlinků/hardlinků v
`/private/tmp/sanjbox-a2-fixture-<effectiveUID>-<NAME>.json`. Má právě jeden payload `login`, `memory`
nebo `workloads`; ostatní pole se vynechají. Writer vytvoří nové `report` data. Exit 0 znamená dokončený
příkaz/strukturálně úplný záznam, **nikoli úspěšný login/aplikaci, P3/P4 nebo S1**. Exit 3 je neplatná
identita či neúplnost, 2 malformed vstup/I/O/signature. `--apply` je třeba i pro offline zápis.

Raw a neúspěšné pokusy uchovat s novým ID. Built/cache scratch lze po kontrole odstranit, nikdy sealed
raw ani cizí běhy. Obecný collector cleanup nevznikl; CLI validační skript odstraňuje pouze vlastní
přesně evidované staged fixture regular files po owner/inode kontrole, výstupy a výsledky zachovává.
