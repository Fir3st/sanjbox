# Přípravná instrumentace WP1.A2

A2/L1 zůstává **partial**. Tento přídavek dodává recorder a deterministický offline výpočet chybějící
v LAB §6–8. LAB-v1/P1–P6 jsou návrh, F0.8 není uzavřené. Výstup není verdikt S1 ani důkaz izolace.
Původní sondy a jejich formát se nemění. Nový `sanjbox-s1-instrument` nevolá Screen Recording preflight,
TCC request, SCK, AX, inventuru oken, procesů, procesních prostředí ani Klíčenku.

## Rozsah a stav ověření

- **Implementováno:** lehká Metal prezentace s každým `presentedTime`, časem submit/callback, výpadky
  drawable, skutečnými časy sběru a sekundovou viditelností vlastního okna; samostatný systémový RAM
  recorder po 1 s; pevný harmonogram pro předem spuštěné sondy; offline fixed-window výpočet a společné
  okno host + tří UID; create-new per-run/per-UID výstupy; strict identity před prací a na hranicích fází.
- **Mock/fixture:** automatické testy známých 60Hz řad, mezer, hranic, pozdních callbacks, identity,
  hodin, baseline, driftu, malformed vstupů a konfliktů souborů. Fixture nikdy není reálný souběh.
- **Dosud neověřeno v L1:** tři UID/ASID, host interaktivita, přežití relací, aplikace, klient/keeper,
  display profil, prompt/granty, cold/warm login a procesní footprint atribuce. Systémový RAM recorder
  sám nedokazuje, že operátor skutečně provedl login/odhlášení/změnu workloadu v plánované fázi.
- **Nespouštěno implementátorem:** živé GUI/TCC, administrátorské instalace, uživatelé, PF nebo systémová
  nastavení. Samostatné root/reviewer smoke výsledky se uvádějí odděleně; žádný smoke není L1.

Nezávislá finální kontrola 2026-11-03: **23/23 úplných Release testů a 25/25 CLI kontrol**.
Krátká skutečná host diagnostika ověřila RAM recorder (6 vzorků/3 s), vlastní presentation okno
(179 prezentací/fixed 3 s) a jeden offscreen workload; všechny výsledky a omezení přesně rozlišuje
[sanitizovaný validační záznam](VALIDATION.md). Žádný z těchto pokusů není L1/S1 nebo potvrzení F0.8.

## Sestavení a bezpečné ověření

**[implementátor]** Bez externích závislostí (jen existující lokální common a S1Probe):

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/sanjbox-a2-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/sanjbox-a2-swift-cache \
swift test --package-path spikes/s1-session --scratch-path /private/tmp/sanjbox-a2-build \
  --disable-sandbox --filter S1InstrumentationTests
```

Tento filtr nepouští původní live GPU/process/forwarder testy. Kompletní existující sada má jiné
provozní nároky; zejména původní forwarder je dlouho běžící. Nové testy neotvírají GUI, nečtou host
procesy ani neměří GPU. Vlastní nové testovací datasety v `/private/tmp` se zachovávají.

**[uživatel, před aktivním smoke]** Build může změnit podpis. Po **posledním** buildu ověř runtime a
entitlements konkrétní binárky; Swift 6.4 Debug může přidat `get-task-allow`. Aktivně nespouštět takový
podpis. Případný lokální ad-hoc reseal používá hardened runtime a prázdné entitlements, bez vyhledávání
identit/Klíčenky. To není S8 stabilita TCC identity. Po dalším buildu kontrolu opakovat.

## CLI a přísný vstup

```text
sanjbox-s1-instrument plan --plan-json JSON
sanjbox-s1-instrument record --plan-json JSON --expect-json JSON [--apply]
sanjbox-s1-instrument offscreen --run-id ID --expect-json JSON [--apply]
sanjbox-s1-instrument evaluate --fixture NAME --run-id ID [--apply]
```

Výchozí dry-run pouze validuje explicitní argumenty a vypíše záměr. Nečte fixture, nezjišťuje identitu,
nevytváří výstup, nezapíná GPU/okno a neměří RAM. `plan` pouze normalizuje plán na stdout. `--apply`
opt-in je povinné i pro zápis offline reportu. Neznámé/přebývající/duplicitní argumenty a duplicitní JSON
klíče včetně escapovaných ekvivalentů se odmítají. Každý inline argument ≤16 KiB; JSON hloubka ≤24.

Plán (příklad je **syntetický**, čas 1000 není použitelný živý start):

```json
{"runID":"example-20261103-a1b2c3d4","profile":"diagnostic","kind":"presentation","start":1000,"phases":[{"name":"warmup","seconds":1},{"name":"measurement","seconds":3}]}
```

- `runID`: 8–96 ASCII písmen/číslic/pomlček, při každém dalším pokusu nové ID. Předregistrace má nadále
  úplný formát LAB run ID; případné diagnostické kratší ID není publikovaný LAB protokol.
- `start`: společný budoucí `CACurrentMediaTime()` v sekundách na **témže Macu a bootu**. Při armování
  musí být 2–300 s v budoucnosti; doporučeno alespoň 30 s pro ruční spuštění všech relací. Plán nelze
  získat z UTC odečtením libovolné konstanty. Operátor jej připraví z vlastního monotónního recorderu
  před během; nezaměňovat s `mach_continuous_time`/`ContinuousClock` při spánku.
- `profile`: pouze `diagnostic` nebo `lab-v1-draft`. Diagnostic fáze 1–30 s, žádný acceptance boolean.
  LAB presentation přesně `warmup:5, measurement:600`; W0 RAM přesně
  `baselineBefore:300, settle:300, measurement:600, cleanup:1…600, baselineAfter:300`.
  Délka cleanup je určena předem, nikoli dodatečně. Zátěžový RAM profil je jediná `measurement:600`.
  Maximálně 5 fází a 2400 s; libovolná změna LAB profilu vyžaduje další verzi kódu/metodiky.
- `kind`: `presentation` nebo `ram`. RAM nepouští GPU ani nové okno. Založit jej **jednou na hostu**
  pro daný systémový blok, nikoli třikrát s duplicitními systémovými daty.

Očekávání je předregistrované; následující hodnoty jsou pouze fixture:

```json
{"uid":4501,"gid":4500,"kernelGroups":[4500],"requiredGroups":[4500],"forbiddenGroups":[20,80],"auditSessionID":123,"onConsole":false}
```

UID/GID se musí shodovat pro real/effective credentials, explicitní kernelGroups se porovnávají přesně.
Common kontroluje autoritativní required/forbidden membership, `Aqua`, manager UID a vlastní window UID.
Lokální wrapper navíc vyžaduje přesný process i window ASID, audit UID a `loginDone:true`; nespoléhá na
pouhý zákaz ASID hosta. Chybějící window kontext znamená **invalidMeasurement**, i když CLI běží pod
správným UID a managerem Aqua. Kontrola se neoslabuje pro headless/tool kontext. Není zde auto-discovery
ani „přečti současnou identitu a automaticky ji schval“. Raw ukládá skutečné sanitizované identity údaje,
ne uživatelská jména, takže je offline kontrola umí znovu porovnat.

## Koordinace bez instalátoru a launcheru

**[uživatel]** V rezervovaném L1 připrav stejné ověřené binárky a vlastní Terminaly/sondy v již
existujících identitách. Instalaci provést **sériově**, před měřením; nový recorder sám nic neinstaluje,
nespouští cizí UID a nepotřebuje privilegia. Původní `run-probe.sh --apply` nepoužívat souběžně: mění
sdílenou instalační cestu a připisuje do společného logu.

1. Předregistrovat stejný `runID`, profil, boot/stroj a plán pro tři oblasti a host; každá identita má své
   explicitní očekávání. Zaprotokolovat binární hash, konfiguraci displeje, klientů a pracovní zátěže.
2. Spustit dry-run v každé relaci. Teprve schválené příkazy spustit s `--apply`, vždy s týmž plánem.
   Spouštění musí skončit před budoucím startem; pozdní příchod je neplatný pokus, nikoli posun celé série.
3. **W1:** všechny čtyři sondy dělají jen lehkou prezentaci. Systémový RAM collector je samostatná host
   sonda. Nikde současně neběží těžké offscreen benchmarky. Zachovat funkční host kontrolní akce dle LAB.
4. **Offscreen páry:** samostatná série; ostatní relace zůstávají aktivní se stejnou lehkou zátěží.
   Operátor volá `offscreen` **jednou**, počká na dokončení a ověří raw, teprve potom spustí další:
   host před → daná oblast → host po. Každý krok má nové run ID s UID/párem/rolí, nikdy sdílený soubor.
   Pro 10 párových bloků na UID rotuje pořadí 1-2-3, 2-3-1, 3-1-2. Wrapper používá původní pevné
   `OffscreenWorkload` 2048²/512 iterací/60 frames/4096 ověřených pixelů; nespouští prezentaci ani TCC.
   Neobsahuje cross-UID lock: sériovost dokládá operátor a timestamps, nesmí se tvrdit z pouhého run ID.
   Poměry, >10% host drift, GPU finite/positive hodnoty a výsledky pixelů se posuzují dle LAB §7 samostatně;
   `evaluate` tento jiný formát nepřijímá a nedává GPU párový verdikt. Neplatné/nonfinite timingy wrapper
   ukládá jako `invalidResult` s raw číselnými řetězci a chybou, aby se neztratil výsledek při JSON encodingu.
5. W0 RAM vyžaduje skutečné host-only baseline, tři relace, ustálení a úklid v předem určených intervalech.
   Harmonogram pouze časuje recorder; sám nevytváří, neodhlašuje ani neověřuje stav relací. Zpožděný login,
   cleanup nebo změna workloadu vyžaduje záznam skutečných přechodů a neúplný/nový běh, ne posun hranic.

Žádný automatický multi-UID launcher, IPC barrier, systémová instalace nebo cleanup se tímto nevydává
za ověřený. Čtyři nezávislé procesy s plánem pouze připravují souběh; až raw a kontrola společného okna
mohou doložit časový překryv. Stejný boot hash je nezbytná korelace, nenahrazuje důvěryhodnou provenienci.

## Čas, skutečné pokrytí a raw

`recording.json` je `EvidenceBundle` s verzí 1 a polem `recordings`. `intent.json` vzniká před workloadem.
UTC se zaznamenává pro korelaci; intervaly používají jednotně Mach absolute/CACurrentMediaTime včetně
Metal `presentedTime`. SHA-256 `kern.bootsessionuuid` odlišuje boot/clock domain bez HW UUID/hostname.
Každá kotva obsahuje rozptyl dvou monotónních čtení okolo UTC. Rozdíl UTC/monotónní délky >100 ms plus
nejistota znamená neúplný záznam (spánek nebo změna hodin), nikoli tichý přesun snímků.

- `boundaries` obsahuje skutečné okamžiky pozorování logických plánovaných hranic a identitu v každé
  hranici. Identita se nepřepisuje zpětně. Pozdní hranice >1 s, chybná identita či chybějící hranice znamená
  neúplný záznam. Tyto hranice neprokazují externí změny aplikací/loginu.
- `recorderStart/end` jsou skutečné hranice render thread/sběru. **Presentation acquisition** má navíc
  skutečný `measurementAcquisition`: thread jej otevře přibližně 1 s před pevným analysis oknem a běží
  přibližně 0,25 s za jeho konec. Hodnoty jsou naměřené, ne odvozené odečtením od plánu. LAB vyžaduje
  alespoň 5 s skutečného warmupu ještě před tímto acquisition. Shader compilation se do warmupu nepočítá.
  Pevná analysis okna zůstávají předregistrovaných 10×60 s, přebytečné snímky se do nich nepočítají.
- Callback drain trvá nejvýše plánované 2 s po measurement konci. Nil `presented/callback` znamená
  „nepotvrzeno do konce drain“, ne prokázanou fyzickou prezentaci. Uveden je submitted i unpresented count.
  Pozdní callback s `presentedTime` uvnitř okna se počítá, timestamp mimo `[start,end)` se nikdy nepočítá.
- Viditelnost vlastního okna se čte přibližně každou sekundu; evaluator vyžaduje pokrytí a žádnou mezeru
  >5 s, stálou drawable velikost/scale. `.visible` není nezávislý důkaz úplného nezakrytí všech pixelů.
- RAM čte `hw.memsize`, `host_page_size`, `HOST_VM_INFO64.free_count`, `vm.swapusage` a
  `kern.memorystatus_vm_pressure_level` (1/2/4). Neznámá/chybějící hodnota zůstává neznámá. Skutečný
  předvzorek ~0,1 s před první fází a konečný vzorek po konci obepínají swap endpointy. Zpožděné sekundy
  se nepřidávají umělými náhradními vzorky.
- Recorder limity: 200 000 frames, 3000 timeout/visibility záznamů, 2500 RAM vzorků. Chyby a limit se
  zachovají. Nový writer drží raw v paměti a zapisuje jej jednou na konci; crash/kill může zachovat pouze
  intent, což je neúplný běh. Neexistuje slib crash-resilientního průběžného logu.
- **Důležitý provozní limit:** common identity capture spouští pevné `launchctl managername/manageruid`
  bez child timeoutu; Metal inicializace, `nextDrawable` a existující offscreen GPU command completion
  také závisejí na návratu systémových API. Délky a velikosti vstupu jsou
  bounded, ale celkové wall-clock dokončení procesu není garantované při zablokování těchto systémových
  operací. Operátor používá vnější watchdog; přerušený pokus a jeho intent se zachová jako neúplný.

## Offline vyhodnocení a uchování dat

Nové výstupy jsou výhradně `/private/tmp/sanjbox-a2-<runID>-uid<effectiveUID>-<kind>/`, adresář 0700,
soubory 0600. Adresář i soubory musí vzniknout nově (`mkdirat`, `O_EXCL`, `O_NOFOLLOW`, držený dir FD).
Kolize/částečný výstup se zachovává. Neappenduje se, nerecykluje existující dataset a žádné sealed evidence
se neotevírá k zápisu. Odstranění zde **není implementováno**: zachovat raw a odstranit jen ručně ověřené
vlastní scratch objekty až po kontrole/exportu. Neexistuje rekurzivní automatické mazání podle cesty.

**[uživatel]** Pro report explicitně připrav vlastní kontrolovanou kopii `EvidenceBundle` v jediném
allowlist tvaru `/private/tmp/sanjbox-a2-fixture-<vlastní-UID>-<NAME>.json`, např. NAME
`review-20261103-a1b2c3d4`. Je-li to skutečný dataset, zachovat původní raw a jeho hash, kopii neměnit
ani neoznačovat fixture jako `measured`. Pro souběh obsahuje bundle čtyři nezměněné presentation záznamy
(a volitelně RAM); předávání mezi UID je ruční uživatelská operace. Fixture musí být vlastní regular file,
bez symlinku/hardlinků, ≤32 MiB, během čtení se nesmí změnit. Jinou cestu CLI nepřijme.

```text
sanjbox-s1-instrument evaluate --fixture review-20261103-a1b2c3d4 --run-id report-20261103-a1b2c3d4
sanjbox-s1-instrument evaluate --fixture review-20261103-a1b2c3d4 --run-id report-20261103-a1b2c3d4 --apply
```

Výpočet je deterministický:

- fixed `[start,end)` počet / 60 s; obě krajní mezery jsou zahrnuté, i když žádný frame nepřišel;
  nearest-rank medián/p95; `floor(gap/(1000/60)+0.5)-1` se sčítá jen nad nulou. Pro nepříznivou mez
  přidává dvě možné hraniční ztráty, vykazuje obě hodnoty i `D/(N+D)`. Počet sekund bez snímku, timeouts,
  submitted a neprezentované v daném okně jsou zvlášť. Nejistota hodin se přičítá k horním gap limitům.
- RAM `M = physical − page × free`; speculative se neodečítá znovu. W0 `B=min(median before, median after)`,
  záporná delta se zachová a označí k vyšetření. Drift >512 MiB, >2s gap včetně konců nebo neznámý
  pressure/swap dává neúplný záznam. Swap endpointy musí obepínat celé fixed window; růst se ořízne zdola
  nulou. Žádný RSS/footprint se k této metrice nepřičítá.
- `evidenceComplete` popisuje **úplnost tohoto instrumentačního záznamu**. `conditionalTargetsMet` je
  pouze výpočet navržených LAB prahů, nikdy schválená akceptace; u diagnostic nebo neúplných dat je null.
  Výstup vždy uvádí `unverifiedPrerequisites` (externí workload, host akce, kontinuita, konfigurace/F0.8).
  Z toho se nesmí odvodit complete W0/S1. Platný nulový počet snímků zůstává změřené selhání cíle.
- Společné okno vyžaduje přesně tři různé zone UID/ASID a jeden host, stejný plán/boot a celé skutečné
  acquisition pokrytí s nejistotou. `fixture` zdroj nikdy nedokazuje živý souběh. Chybějící participant,
  reboot, jiná série nebo nedostatečný overlap je explicitní issue; výsledky různých UID se neprůměrují.

Kódy: 0 dokončený příkaz/úplný instrumentační report (není pass cíle), 2 neplatný vstup/I/O, 3
invalidMeasurement nebo neúplný report. Runbook LAB nadále vyžaduje publikovat raw/error/stderr, nezávislé
review a neměnnou historii. Chybějící instrumentace login času, atribuce footprintu a externích aplikací
zůstává otevřená; nebyly změněny statusy žádných testů nebo bran.
