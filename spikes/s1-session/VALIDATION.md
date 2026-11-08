# WP1.A2 — ověření přípravné instrumentace

Ověřeno 2026-11-03 implementátorem, nezávislým source reviewerem a koordinátorem (root agent).
Jde o kontrolu instrumentace a krátkou **host diagnostiku**, nikoli běh L1 nebo verdikt S1.
A2/L1 zůstává partial, LAB-v1/P1–P6 návrhem a všech 155 případů i brány beze změny.

## Automatické testy a review

| Kontrola | Výsledek |
|---|---|
| Implementátor, Debug, pouze `S1InstrumentationTests` | 17/17, bez selhání; čisté synthetic/fixture testy bez GPU/GUI |
| Koordinátor, první úplná Release sada před posledním offscreen regression testem | 22/22; původní výsledek zachován |
| Koordinátor, finální úplná Release sada | **23/23**: 6 původních + 17 nových, 0 failed, 0 skipped; log 2026-11-03 19:25:45 CET |
| Nezávislé source review | Bez zbývajících blokujících nálezů po opravách |
| Kontrola vlastnictví změn a coverage | Jen `spikes/s1-session`, vlastní WP1.A2 řádek a F1 agregát 2 hotovo / 1 partial / 27 todo |

Oba úplné Release běhy měly očekávané upozornění na deprecaci `--build-system native`, nikoli chybu
sestavení. Koordinátor uchovává původní `sanjbox-a2-root-release.log` i finální
`sanjbox-a2-root-release-final.log` odděleně. Nový test ověřuje, že nonfinite/nonpositive offscreen
hodnoty zůstanou v `invalidResult` jako raw řetězce s chybou a nezabrání zápisu výsledku.

Po posledním buildu koordinátor znovu lokálně podepsal testovanou CLI binárku ad-hoc přes `-s -`,
`--options runtime`, prázdné entitlements a `--timestamp=none`. Aktivní CLI ověření následovalo bez
dalšího rebuildu; podpis neobsahoval `get-task-allow`. Nebyly hledány signing identity ani čtena Klíčenka.
Nejde o ověření stabilní TCC identity nebo brány S8.

## Nezávislá CLI kontrola

Koordinátor dokončil **25/25 kontrol**, včetně:

- výchozího režimu, help, neznámých argumentů a dry-run bez měření/zápisu;
- malformed JSON, duplicitních i neznámých klíčů a prázdného očekávání;
- nesprávného přesného ASID: `invalidMeasurement` před workloadem;
- prošlého plánu a odmítnutí opakovaného datasetu s nezměněným původním obsahem;
- skutečného krátkého RAM a presentation recorderu v předem ověřené vlastní host identitě,
  následného offline vyhodnocení a odmítnutí reuse;
- nezávisle sestavené Python fixture se 120 snímky při 60 Hz a negativních variant časového envelope,
  raw identity, viditelnosti a duplicit;
- offscreen dry-run, nesprávného ASID, jednoho skutečného host workloadu a odmítnutí reuse.

## Skutečně měřená krátká host diagnostika

| Samostatný pokus | Naměřeno | Rozsah závěru |
|---|---|---|
| RAM, diagnostic, fixed 3 s | 6 skutečných vzorků včetně acquisition endpointů; offline `evidenceComplete: true`, `issues: []` | Funkční krátký systémový collector; žádná W0 baseline ani RAM tří relací |
| Vlastní syntetické presentation okno, diagnostic, 1 s warmup + fixed 3 s | 179 prezentací uvnitř `[start,end)`, 59,6666667 fps; offline `evidenceComplete: true`, `issues: []` | Funkční krátký recorder a fixed-window výpočet v jedné host relaci; žádný souběh tří oblastí ani fyzický photon |
| Jeden host offscreen workload | GPU medián 10,487625 ms, p95 11,418042 ms; 0 neshod z 4096 ověřených pixelů | Samostatná diagnostika původního workloadu přes nový wrapper; žádná párová S1 série nebo poměr proti oblasti |

U diagnostic RAM/presentation zůstává `conditionalTargetsMet: null`. Úplnost instrumentačního záznamu
není splnění LAB prahů ani ověření externích podmínek L1. Koordinátor uchovává všechny nové privátní
runy, skripty, souhrny a původní raw odděleně; tato sanitizovaná poznámka nepublikuje jejich identity,
boot metadata ani obsah datasetů a nenahrazuje neměnný akceptační protokol LAB.

Nebyly spuštěny TCC request/preflight, vytváření uživatelů, PF ani změny systémových nastavení.
Původní úplná testovací sada má své známé live GPU/process/loopback testy; nové fixture testy zůstávají
oddělené. Zbývající mezery L1 a provozní limity recorderu jsou v [runbooku](INSTRUMENTATION.md).

## Navazující validace A2 — 2026-11-04

Samostatné implementační evidence ID **A2-followup-20261104-7e51c8a2**; dokončeno nejpozději
2026-11-04T22:38:45Z. Není to rezervovaný LAB/L1 běh ani nový verdikt S1. Historie 2026-11-03 výše
zůstává beze změny. Výchozí main `afae1ca7dfe78f03d5006c42b6b01093772eba0c`, claim
`9f734d7`; testované zdroje mají soukromý `source-manifest.json` s SHA-256
`b1ec88d4294e56492795ce56099c286c30cf528ca8aa2ab7495f80f41d997302`.

| Kontrola | Výsledek a hranice |
|---|---|
| Finální native Release build | Úspěšný; bez externích balíčků, lokální common beze změny; `build-reviewed.log` |
| Podpis po posledním buildu | Ad-hoc `--options runtime --timestamp=none`, prázdné entitlements; `codesign --verify --strict` a metadata všech 3 CLI + test bundle; bez obou `get-task-allow` klíčů. `signature-reviewed.txt` |
| Kompletní finální Release sada | **43/43**, 0 failed, 0 skipped: 6 původních + 17 původních instrumentačních + 20 nových fixture testů. `tests-release-final.log` |
| Finální CLI sada | **30/30**; `Tests/cli_validation.py`, `cli-final/results.json` a samostatné nové raw/report datasety |
| Pozitivní živý nový memory/login workload | **Neproveden**; není aktuální předregistrované host očekávání. Žádná automatická substituce z právě zachycené identity |
| Negativní živá kontrola | Záměrně nesprávná syntetická očekávání → exit 3; paměťový raw má prázdné samples, žádnou registration/window, zachovanou chybu. Bez `proc_pid_rusage` workloadu/alokace. Marker má neplatnou identitu, není login měřením |
| Diff a rozsah | `git diff --check` bez nálezu; jen `spikes/s1-session` + vlastní WP1.A2 coverage řádek. F0, LAB prahy, Contracts/common, brány a 155 případů beze změny |

Nové testy jsou čisté fixture/policy testy: známá časová řada a fractional duration rounding,
missing/zero/unreadable paměť, mezery a hrany, sample mimo okno, PID/start reuse a dvojí instance,
neshodné clock domains/UTC/pořadí, přesná identita, runtime a obě varianty zakázaných entitlementů,
unknown/duplicate/null JSON, timeout ≥60 s, neznámá event-to-marker nejistota, meze 10 ms,
směs login konfigurací/rolí, chybějící skutečný aplikační výstup, CoreSimulator/emulátor vazby,
fail/unknown outcomes a zákaz přeznačit dodaná data na `measured`.

Původních šest testů zahrnuje GPU/offscreen, display metadata, own-UID procesní metadata a loopback
forwarder; byly spuštěny v dříve autorizovaném rozsahu původní sady. Jejich úspěch není nový S1 důkaz.
Nové živé rozhraní žádnou inventuru procesů nemá. Žádná skutečná aplikace, login, TCC/capture,
systémové změny, credential store, Klíčenka nebo databáze nebyly spuštěny/čteny.

### Reprodukovatelné příkazy

Příkazy byly spuštěny z kořene worktree; `TASK_SCRATCH` je nové, implementátorem vlastněné místo.
Při opakování vytvořit jiné jméno a nové CLI output adresáře; nepoužívat původní datasety.

```bash
TASK_SCRATCH=/private/tmp/sanjbox-a2-followup-20261104-7e51c8a2
CLANG_MODULE_CACHE_PATH="$TASK_SCRATCH/clang" \
SWIFTPM_MODULECACHE_OVERRIDE="$TASK_SCRATCH/module" \
swift build --package-path spikes/s1-session --scratch-path "$TASK_SCRATCH/build" \
  --configuration release --build-system native --disable-sandbox --build-tests -Xswiftc -enable-testing
```

Před testem byly všechny výstupy **po buildu** resealovány a kontrolovány:

```bash
RELEASE_OUTPUT="$TASK_SCRATCH/build/arm64-apple-macosx/release"
for artifact in sanjbox-s1-instrument sanjbox-s1-probe sanjbox-s1-forward SanjboxS1PackageTests.xctest; do
  codesign --force --sign - --options runtime --entitlements "$TASK_SCRATCH/empty-entitlements.plist" \
    --timestamp=none "$RELEASE_OUTPUT/$artifact"
  codesign --verify --strict "$RELEASE_OUTPUT/$artifact"
  codesign -dvvv "$RELEASE_OUTPUT/$artifact"
  codesign -d --entitlements :- "$RELEASE_OUTPUT/$artifact"
done
```

Plist obsahoval prázdný dict (vytvořen Python `plistlib.dumps({})`), nevyhledávaly se identity.
Metadata měla flags `0x10002(adhoc,runtime)`; entitlement výstup byl prázdný u test bundle nebo prázdný
XML dict u CLI. To není grant ani stabilní signing identity. Následoval test bez rebuildu:

```bash
CLANG_MODULE_CACHE_PATH="$TASK_SCRATCH/clang" \
SWIFTPM_MODULECACHE_OVERRIDE="$TASK_SCRATCH/module" \
swift test --package-path spikes/s1-session --scratch-path "$TASK_SCRATCH/build" \
  --configuration release --build-system native --disable-sandbox --skip-build
python3 spikes/s1-session/Tests/cli_validation.py \
  --binary "$RELEASE_OUTPUT/sanjbox-s1-instrument" --output "$TASK_SCRATCH/cli-final" --apply
```

CLI sada kontroluje dry-run bez fixture read/výstupu, přesné argumenty, nepovolený PID, oversize,
recursive unknown/duplicate fields, invalid identity před samplováním, konflikt bez přepsání raw,
platný syntetický memory/login/app report a neúplné/selhané varianty. Raw zdrojové JSON skládá nezávisle
Python, ne Swift encoder. `cli-final` má vlastní náhodný namespace odlišný od prvního CLI běhu.

### Zachovaná validační historie a úklid

Původní `build-initial.log` neprošel, protože Release `--build-tests` potřebovalo `-enable-testing`;
`build-second.log` odhalil nepřístupný memberwise initializer společné fixture struktury. Oprava byla
jen v lokálních testech, common se nezměnilo. Následující buildy prošly.

`tests-release-first.log` má 42/42 před posledním regresním testem. Tento první pokus se spustil
kvůli chybě validačního wrapperu i po neúspěšném parsování chybějících entitlementů test bundle,
před dokončením kontroly všech podpisů; **nepoužívá se jako validace podepsané sestavy**. Wrapper byl
opraven na fail-fast, absence entitlementů odlišena od malformed plist a všechny výstupy ověřeny.
`tests-release-verified.log` následně uchovává 42/42 po podpisové kontrole; finální doplnění testu a
kontroly hranic má vlastní `tests-release-final.log` 43/43. `cli-first` uchovává dřívějších 30/30,
`cli-final` samostatných 30/30 po poslední změně. Nic z těchto záznamů nebylo přepsáno novými výsledky.
Očekávané deprecation warning pro native build system a codesign `:-` nejsou selhání testu.

Privátní logy, source manifest, syntetické input kopie a nové raw/report datasety zůstávají zachované
v task namespace / přesných cestách `cli-*/datasets.json`. CLI staged fixture soubory byly odstraněny
jen podle vlastní evidované owner/inode identity. Po validaci jsou odstraněny pouze vlastní `build`,
`clang`, `module` cache a prázdný signing plist; žádné sealed raw, předchozí evidence ani cizí scratch.
Původní storage test záměrně zachovává svůj create-exclusive syntetický dataset.

Zbývající funkční a důkazní mezery jsou v [SUPPLEMENTARY.md](SUPPLEMENTARY.md). A2/L1 zůstává
rozpracované; nikdy nebyl proveden ani odvozen reálný třírelační výsledek.

## Registrované procesní řady — 2026-11-06

Nové implementační evidence ID **A2-process-series-20261106-345cbff8fc5c**; finální validace dokončena
2026-11-06T07:28:09Z. Jde o **host diagnostiku na vlastních kontrolovaných dětech**, nikoli L1,
testovací oblast, P4 nebo verdikt S1. Historické výsledky výše se nemění. Přesný malý
[receipt s hashi](validation/process-series-20261106-345cbff8fc5c/receipt.json) nepublikuje raw identity.

Výchozí main `2a15fc2608a04b3cf06ba676810ffe69edae3982`, claim `b857c99`, implementace `684b59b`,
oprava zachování rozpracovaných bodů `76d01f2d6846d246395a5213c197af9c08406857`. Finální source manifest
SHA-256 `77cc4df1edcec3ccb63de1a0597e956debef79fcecc308e88c43d0c6dc81a39a` zahrnuje místní common
závislost, která se nezměnila. Konfigurace je macOS **27.2 (26B123), arm64, Xcode 27.2 (27B52),
Swift 6.4.2** (`swiftlang-6.4.2.1.9 clang-2100.4.1.1`). Xcode se liší od historického LAB/r1;
stará konfigurace ani závěr brány se nepřenášejí.

| Kontrola | Výsledek a omezení |
|---|---|
| Finální native Release build `build-07.log` | Úspěšný, bez externích balíčků; před aktivní validací znovu podpis všech 3 CLI a test bundle |
| Signatures po posledním buildu | Ad-hoc, runtime, prázdné entitlements; `codesign --verify --strict`, skutečné CodeDirectory flags a nepřítomné oba get-task-allow klíče. Hash binárek po testech nezměněn |
| Kompletní Release sada | **63/63**, 0 failed, 0 skipped: původních 43 + 20 nových testů. Zděděný test own-UID inventory spuštěn jednou jako autorizovaná regrese; jeho seznam/jména se nepublikují. Nové live kolektory žádnou inventuru nedělají |
| Původní CLI sada | **30/30**, vlastní fixture/negativní vstupy, původní schémata kompatibilní |
| Nová signed CLI sada | **17/17**, skutečné registrace/čtení vlastních dětí, životní cyklus, identity/start mismatch, foreign UID, strict schema, immutable output a journal interruption |
| Běžný `process-series`, živý pozitivní běh | 4 s, **5 platných bodů**, známá dotčená 16MiB alokace, růst footprint **16 793 600 B**; PID/UID/start shodné před/po každém readu; `acquisitionComplete:true`, `fullSessionAttributionComplete:false` |
| Pevný owned-child birth/exit běh | 6 s, 14 bodů; první dítě 7 bodů, druhé `notRegistered → sampled → unreadableBefore`; arrival a zánik uchované jako neúplnost, **exit 3**, nikoli performance fail/pass. Obě děti prokazatelně skončily, cleanup true |
| Přerušení vlastního collectoru SIGTERM / SIGALRM | Oba pokusy po 2 zapsaných bodech: journal uchoval 2 plné řádky; záměrně zkrácený prefix uchoval první řádek; žádný final recording/report. Exit −15 / −14, vždy neúplné. SIGALRM testuje dispatch stejného handleru jako watchdog, nikoli skutečnou expiraci deadline |
| Pořadí kontrol | Neshodný ASID → exit 3 a žádná target metadata/paměť/children; cizí registry UID → exit 2 před datasetem; chybný start stále živého dítěte → `identityChangedBefore` bez metrik |

Před pozitivní akvizicí se samostatně zkontroloval sanitizovaný vlastní host kontext, explicitně zvolila
přesná očekávání a uložily `expected-reviewed.json` a `preregistration.json`; koordinátor tento rozsah
ověřil. Collector nikdy neodvozuje schválená očekávání z právě zjištěné identity. První úmyslný mismatch
zůstává v `initial-identity-rejection.json` a jeho samostatném create-exclusive datasetu.

### Oprava potvrzeného review nálezu a uchovaná historie

Nezávislý reviewer na `684b59b` potvrdil P2: SIGTERM **2,2067 s** po uzavření registru zachoval jen
intent/registry, protože vzorky čekaly v RAM na konec série. Původní repro je ponecháno v jeho vlastním
scratch a nebylo přepsáno. `76d01f2` přidává čerstvý bounded `samples.jsonl`, zápis a fsync **po každém
readu před dalším readem/wait**, včetně chyb a `notRegistered`. Nezmění částečný prefix na úplný report,
neimplementuje automatickou recovery a netvrdí power-loss odolnost. Protokol a limity jsou v
[PROCESS-SERIES.md](PROCESS-SERIES.md).

`build-05` má zachovaných **59/59 + CLI 15/15 + původní CLI 30/30**, `build-06` **62/62 + 15/15 + 30/30**.
Tyto dřívější úspěchy nepokrývaly přerušení a nezastupují finální opravu. `build-01` zachoval odmítnutou
static non-Sendable reader hodnotu, `build-02` a `build-03` compiler type-check timeout ve fixture
výrazu; po lokální opravě proběhl úspěšný build-04. Žádný z chybových logů není odstraněn nebo přejmenován
na úspěšný test.

Samostatné doplňující signature pokusy na kopiích build-06: skutečný CLI bez runtime i s
`com.apple.security.get-task-allow:false` skončil exit 2 před datasetem/child launch. Kopii s
`get-task-allow:false` macOS zabil při startu SIGKILL; **není** to doložené odmítnutí aplikačním gate.
Deterministické testy ověřují oba klíče včetně false. Přípravu těchto kopií dvakrát zastavila chyba
validačního wrapperu: substring `runtime` nesprávně našel ve filename `no-runtime`. První interpretace
příčiny zůstala uchovaná a má samostatný amendment s opravou; finální kontrola parsovala CodeDirectory
flags. Skutečná finální runtime binárka zůstala beze změny. Žádná osobní signing identity/Keychain se
nevyhledávala a žádné nastavení systému se nezměnilo.

### Reprodukce a evidence

Použít nový vlastní scratch, stejný native Release postup jako ve validačním záznamu 2026-11-04,
`--build-tests -Xswiftc -enable-testing`, a po **posledním** buildu re-sign/verify všech artefaktů.
Potom bez rebuildu:

```bash
CLANG_MODULE_CACHE_PATH="$TASK_SCRATCH/clang" \
SWIFTPM_MODULECACHE_OVERRIDE="$TASK_SCRATCH/module" \
swift test --package-path spikes/s1-session --scratch-path "$TASK_SCRATCH/build" \
  --configuration release --build-system native --disable-sandbox --skip-build
python3 spikes/s1-session/Tests/cli_validation.py \
  --binary "$RELEASE_OUTPUT/sanjbox-s1-instrument" --output "$TASK_SCRATCH/cli-legacy-new" --apply
python3 spikes/s1-session/Tests/process_series_validation.py \
  --binary "$RELEASE_OUTPUT/sanjbox-s1-instrument" --expect-file "$TASK_SCRATCH/expected-reviewed.json" \
  --output "$TASK_SCRATCH/cli-series-new" --apply
```

`expected-reviewed.json` se připravuje samostatně před během podle konkrétního kontrolovaného hosta/
relace; nekopírovat zdejší numeric expectation na jinou konfiguraci. Fixture script výchozím dry-runem
nic nečte ani nespouští. Nový běh vytvoří nové namespace a output adresáře, uchová i neúspěšné kroky.

Malé privátní evidence jsou v `/private/tmp/sanjbox-a2-series-345cbff8fc5c`: `preregistration.json`,
`source-manifest-07.json`, `signatures-07.json`, `tests-07.log`, `final-run-07.json`, `cli-series-07`
a `cli-legacy-07`; přesné nové raw cesty jsou v `cli-*/datasets.json`. Raw/report/journals zůstanou,
stejně jako staré build/test/CLI logy a review repro. Mazatelné jsou pouze přesně vlastní build/cache,
pomocné podpisové kopie a prázdný plist; žádný cizí scratch nebo uzavřená evidence. Staged fixture JSON
script odstraňuje po kontrole vlastní inode/owner identity. Nový storage regression záměrně zachovává
vlastní create-exclusive journal fixture. Receipt obsahuje hashe vybraných malých záznamů a raw.

**Zůstává neověřeno:** skutečné L1 aplikace/tři souběžné relace, úplnost registru jejich procesů a nových
dětí, WindowServer/klienti mimo UID, W0/pressure/swap a ostatní LAB důkazy. Žádný součet procesní paměti
se nepřičítá k systémovému ΔM; F0.8/P4 prahy, původní schémata, brány a 155 případů se nemění.

## 2026-11-06 — offline inspektor zachovaného journalu

Zdrojový commit **`f77875f01a2692910518e2e664e5f77edb309571`** (implementace `82eef94`, následné zpřesnění
`notRegistered`); základ `dd058d3f4e758ed7fdef7dc64eba1c9a34a66967`. Finální nativní SwiftPM Release
(`--build-system native`, 2 jobs, vlastní scratch/cache) na macOS **27.2 / 26B123**, arm64, Apple Swift
**6.4.2**: **77/77 testů**, 0 failures/skips, z toho 14 nových inspektorových testů a 63 původních.
Nativní backend vypisuje deprecation warning; log jej zachovává. Následně vlastní CLI ad-hoc podpis
s hardened runtime a bez entitlements, `codesign --verify --strict`, bez certifikátů/Keychain.
Na této přesné binárce: **nový offline CLI 38/38 + původní syntetický/negativní CLI 30/30**.
[Receipt, hashe zdrojů/binárky a logy](validation/journal-inspector-publication-derivative-20261106/receipt.json),
[manifest publikovaných bytů](validation/journal-inspector-publication-derivative-20261106/manifest.json).

Nový [runbook](JOURNAL-INSPECTOR.md) popisuje jediný staged vstup, volitelný explicitní plán, readonly
FD kontroly, 30s watchdog, přesnou JSONL hranici a exit 3/2. Žádný report inspektoru nemá acquisition
nebo acceptance pass; i zdánlivě perfektní vstup vrací `incomplete-unverified`.

Testy používají skutečný `ProcessSeriesJournal` encoder/writer a **12 byte-identických historických
journalů / 54 řádků**: dvě nezávislé předchozí sady autora implementace a review, každá positive,
wrong-start, SIGTERM, SIGALRM, exited a lifecycle. Neproběhl nový aktivní `process-series` ani nový
memory workload. Přesný [původ kopií](validation/journal-inspector-publication-derivative-20261106/native-journals/provenance.json)
a [kontrola nezměněných originálů po testech](validation/journal-inspector-publication-derivative-20261106/originals-rechecked.json)
zůstávají oddělené per autor/run; šest originálů implementace navíc souhlasilo s již zachovaným
historickým dataset manifestem. Ostatní kopie mají současný byte hash a vazbu na původní dataset index,
ne tvrzení o nezávisle autentizovaném původu. Dva dodané plány jsou přesné UTF-8 argumenty z předchozích
CLI výsledků, nikoli automaticky načtené intent/registry sidecary.

Odvozené truncation/missing-LF a malformed middle/final vstupy jsou označené `derived-*` a nemění
originály. Pokryto: zachování validního prefixu i failure diagnostik, omitted metric versus zero,
oddělení footprint/resident, foreign/root/real-UID drift při failure, expected-instance a PID binding,
chronologie, cross-run/window/sequence, duplicitní/escaped klíče, unknown/null/bool/čísla, depth/byte/row
limity včetně celého 32×602 prefixu, explicitní plan mismatch, dry-run bez čtení a odmítnutí symlink,
hardlink, FIFO, directory a cizího mode. Každý dokončený CLI výsledek kontroluje přesný input hash,
byte count, neúplný stav a nezměněné staged byty/inode/mode/mtime/ctime. Stage cleanup odstraňuje jen
vlastní jmenované inode, původní journals ani vytvořené legacy report datasety nemaže.

### Reprodukce poslední ověřené sady

V novém vlastním scratch (žádné opětovné použití output adresářů), z kořene repozitáře:

```bash
CLANG_MODULE_CACHE_PATH="$TASK_SCRATCH/modules" \
SWIFTPM_MODULECACHE_OVERRIDE="$TASK_SCRATCH/modules" \
swift test --package-path spikes/s1-session --build-system native -c release --jobs 2 \
  --scratch-path "$TASK_SCRATCH/native-build" --cache-path "$TASK_SCRATCH/cache" \
  --disable-sandbox -Xswiftc -enable-testing \
  -Xswiftc -module-cache-path -Xswiftc "$TASK_SCRATCH/modules"
```

Poslední ověřená binárka je `native-build/arm64-apple-macosx/release/sanjbox-s1-instrument`.
Po posledním buildu vlastní ad-hoc hardened podpis bez entitlements a strict verify; potom:

```bash
python3 spikes/s1-session/Tests/journal_inspector_validation.py \
  --binary "$RELEASE_OUTPUT/sanjbox-s1-instrument" --output "$TASK_SCRATCH/cli-offline-new"
python3 spikes/s1-session/Tests/cli_validation.py \
  --binary "$RELEASE_OUTPUT/sanjbox-s1-instrument" --output "$TASK_SCRATCH/cli-legacy-new" --apply
```

Nový validační Python script je explicitní test runner: vytváří pouze vlastní staged kopie a
nový zadaný output adresář, spouští pouze offline CLI; nemá režim měření. Originální zdroje již
nepotřebuje: používá původní malé byte-identické kopie ze zdrojového commitu v `validation/journal-inspector-20261106/native-journals`.
Publikovaná finální evidence obsahuje raw vstupy/výstupy a cleanup, nikoli jen souhrn.

Předchozí pokusy zůstávají v `/private/tmp/sanjbox-a2-journal-inspector-20261106` a jsou hashované
v [retained-attempts.json](validation/journal-inspector-publication-derivative-20261106/retained-attempts.json). `build-01`
selhal před kompilací kvůli sandboxem odmítnuté implicitní module cache; opravené cache byly vlastní.
`build-02/03/04` použily výchozí **XCBuild**, postupně 75/77/77 úspěšných testů. `cli-offline-01`
selhal před spuštěním CLI: wrapper předpokládal jiný output layout. `cli-offline-02/03` pak prošly
38/38 a `cli-legacy-01` 30/30 na XCBuild artefaktu. Poslední `build-native-05`,
`cli-offline-native-04`, `cli-legacy-native-02` jsou samostatné finální nativní výsledky výše;
předchozí selhání ani backend nebyly přepsány na úspěch.

**Hranice důkazu:** test parseru a compatibility původních bytů není obnovená acquisition, autentizace
historické identity/provenance ani S1/P4 verdikt. A2/L1, skutečné aplikace/tři relace, úplná procesní
atribuce, LAB/F0.8 a všechny dřívější otevřené body zůstávají beze změny. Velké vlastní build/cache
může implementátor odstranit až po předání review; malé důkazy a všechny historické originály zůstávají.

## 2026-11-06 — opravy nezávislého review offline inspektoru

Nezávislé review zdroje `f77875f` / předání `a609d3c` našlo tři P2, které dřívější úspěšná sada
77/38/30 nepokrývala: buffered `print` dokončoval stdout až po zrušení alarmu; nedokončený string
s nemožným UTF-8 či low surrogate se chybně označil jako přípustné přerušení; dva publikované
compiler/wrapper logy obsahovaly lokální home cesty. [Původní review repro](validation/journal-inspector-reviewfix-20261106/review-baseline/provenance.json)
zůstává oddělené od nových výsledků. Na původním zdroji 94 validních řádků dávalo 65 757 bytů stdout;
při přirozeně zablokované prázdné pipe proces přežil 33 s a reviewer jej musel ukončit SIGTERM.

Opravy `bdd5a17` a **`db6622ef2f0abeacd62e71a622579c0550e30253`** používají synchronní `Darwin.write`
s partial-write/EINTR smyčkou; 30s alarm jednorázového inspektoru zůstává aktivní až do skutečného
ukončení procesu, včetně top-level chybového stderr. Větve ostatních příkazů se nemění. Syntax scanner
ověřuje každý dostupný UTF-8 continuation byte, hranice overlong/surrogate/max scalar a `\u` surrogate
páry již před closing quote; možné neúplné vícebytové prefixy uchová jako přerušení, nemožné prefixy
jako strukturální chybu. Předchozí validní řádky, jejich byte pozice/hash i failure diagnostika zůstávají.

Nové samostatné [finální evidence](validation/journal-inspector-reviewfix-20261106/receipt.json),
[manifest](validation/journal-inspector-reviewfix-20261106/manifest.json) a
[34 source/test hashů](validation/journal-inspector-reviewfix-20261106/source-manifest.json): explicitní
native SwiftPM Release, 2 jobs, vlastní cache, macOS 27.2 / 26B123, arm64, Apple Swift 6.4.2:
**79/79 testů**, 0 failures/skips (přibyly 2 Unicode-prefix testy); po vlastním ad-hoc hardened podpisu
bez entitlements a strict verify **offline CLI 41/41** (přibyly 3 cílené případy) a **legacy CLI 30/30**.
Nativní backend nadále vypisuje zachované deprecation warning. Neproběhl nový aktivní procesní sběr.

Skutečný [natural blocking-pipe test](Tests/journal_watchdog_validation.py) používá vlastní `Popen`,
94 syntetických řádků a nejprve ověří kompletní referenční stdout s exit 3. Druhý proces píše do
**zpočátku prázdné, nečtené vlastní pipe**, bez jejího předplnění a bez ručního SIGALRM:
**65 757 bytů reference, 65 536 bytů částečného výstupu, vlastní SIGALRM / exit −14 za 30,0223 s**.
[Raw výsledek](validation/journal-inspector-reviewfix-20261106/watchdog-natural-01/result.json), reference,
syntetický vstup, partial stdout a cleanup jsou uchované. Partial stdout není dokončený inspekční JSON.
Po nativním buildu/podpisu se k předchozím dvěma CLI příkazům přidá:

```bash
python3 spikes/s1-session/Tests/journal_watchdog_validation.py \
  --binary "$RELEASE_OUTPUT/sanjbox-s1-instrument" --output "$TASK_SCRATCH/watchdog-natural-new"
```

Úplná původní publikace **72 souborů = 71 manifest entries + manifest** byla uchována byte-identicky
v `/private/tmp/sanjbox-a2-journal-inspector-20261106/private-original-publication-a609d3c`;
SHA-256 původního manifestu `0fab333ff910797223aa6149be9981ecf4ea31e97865d6244c25991ac4352d05`.
Původní uzavřený record ani manifest se nepřepisují. Veřejná
[oddělená publikační odvozenina](validation/journal-inspector-publication-derivative-20261106/derivation-manifest.json)
má vlastní manifest a výslovně označené kopie pouze dvou diagnostických logů s home-prefixem
nahrazeným `<HOME>/`. Jejich původní/publikované hashe, počty náhrad, přidané označení a generická
replacement map jsou zveřejněné; přesná privátní mapa je mimo neměnný archiv. Dřívější raw/test výstupy,
validace zdroje `f77875f` a všech 12 původních nativních journalů zůstávají zachované, nikoli přepsané
na nové úspěšné běhy. [Nová kontrola originálů](validation/journal-inspector-reviewfix-20261106/originals-rechecked.json)
ověřila stejné hashe všech 12 skutečných historických journalů.

Samostatný private scratch nových výsledků je `/private/tmp/sanjbox-a2-journal-inspector-reviewfix-20261106`;
velké vlastní native-build/cache z předchozího scratch byly pro build znovu použity. Receipt uvádí přesný
validovaný zdrojový commit a hash finální podepsané binárky. Při zabalení publikace do jiné větve rozhoduje
shoda uvedených source/test bytů; nový veřejný commit není vydáván za revizi původního měření. Kód i data
stále neposkytují autentizaci historické identity/provenance, úplnou acquisition ani S1/P4 verdict.

## 2026-11-08 — dynamický sběr potomků test rootu (offline příprava)

Zdroj **`e5e1b203239b0ae4f4c7e6bc0b559aab770b0097`** přidává samostatný
[descendant-memory](DESCENDANT-MEMORY.md): skutečné `proc_listchildpids` pouze nad registrovaným
same-UID rootem a ověřenými potomky, kontrolu celé ancestry před/po čtení, footprint/resident a
explicitní chyby, exit/reparent/PID reuse, limity a mezery. Pevný registr/journal i staré výsledky beze změny.

Na aktuálním Macu: explicitní native SwiftPM Debug **91/91**, Release **91/91** (17 nových syntetických
případů); po ad-hoc hardened podpisu bez entitlements skutečné CLI **9/9 v každé konfiguraci** a původní
CLI regrese **30/30**. Normální acquisition CLI v obou bězích samo objevilo root → pozdní dítě → vnuka:
3 instance, 11 ticks, 29 observations; známé dotčené alokace 4/8/12 MiB, raw/report jednotky a exity
ověřeny proti fixture truth čtené až po skončení collectoru. Úklid vlastních potomků ověřen. Exit 3 a
`unreadableBefore` po ukončení dětí jsou očekávané neúplné pozorování, nikoli nulová RAM nebo S1 pass.

První preflight byl správně odmítnut bez target reads: nezávisle připravené očekávání použilo 17 skupin
z Python/Darwin EXT API; samostatná kontrola native `getgroups` potvrdila 16 skupin. Nové předregistrované
V2 očekávání má SHA-256 `3c2abcaf1af3119cb3b37e77cbc8464ec4a5c5dcb6a13ac5af263294d35622c3`;
gate ani společný identity kód se neoslabily. Před finálním zdrojem byla opravena i reportová konverze
UInt64→Double; nové oracles porovnávají report přímo s raw byty. Dřívější pokusy zůstaly zachované.

Malé logy, podepsané binárky, souhrn a původní pokusy:
`/private/tmp/sanjbox-a2-descendants-20261108-5bwaXeVW` (`validation-summary.json`, `bin/`,
`debug-07.log`, `release-03.log`, `native-debug-03/`, `native-release-02/`, `legacy-cli-release-02/`).
Přesné nové datasety jsou v jejich `datasets.json`; vlastní build/cache (~340 MiB) byly po ověření
zdroje a logů odstraněny. Polling nezaručuje zachycení krátkých procesů; žádné whole-UID, cross-UID,
WindowServer, session, L1, P4 ani S1 tvrzení. Systémové ΔM se s footprint/RSS nesčítá.

## 2026-11-08 — review fix: deadline před každým procesním čtením

Nezávislé review zdroje `e5e1b203` našlo P2: metadata mohla spotřebovat celý tick budget a původní
kontrola před celým pollem přesto dovolila další memory/enumeration volání. Zdroj
**`464f1fff0cd9b857f5550b1be62b514e1abf829c`** kontroluje deadline před i po každém jednotlivém
metadata/memory/list volání, včetně každého prvku ancestry a kandidáta. Rovnost s deadline již
nepovolí čtení; overrun ukončí traversal s `timeLimit`, bez metrik nebo nové binding po timeoutu.
Již běžící kernel call tím nelze přerušit: jde o omezení mezi operacemi, nikoli hard per-call timeout.

Nové vlastní ověření na témže Macu, beze změny V2 identity očekávání: native SwiftPM Debug
**95/95**, Release **95/95** (4 nové regresní testy: všech 9 pozic volání, rovnost deadline, ancestry
loop a pomalý journal emit). Po ověřeném ad-hoc hardened podpisu bez entitlements normální signed
native CLI **9/9 v obou konfiguracích**; každá pozitivní acquisition opět 3 instance, 11 ticks,
29 observations, posthoc fixture truth, explicitní exity a ověřený úklid. Žádný S1/P4 ani úplný UID
nebo session závěr. Původní testy, odmítnuté preflighty a reviewer repro zůstávají beze změny.

Nové malé logy, `validation-summary.json`, `cache-cleanup.json` a ověřené kopie `bin/debug-instrument`,
`bin/release-instrument` jsou v `/private/tmp/sanjbox-a2-deadline-fix-20261108-EcrkVmZm`;
finální logy `debug-01.log`, `release-01.log`, `native-debug-01/`, `native-release-01/`.
Přesné acquisition cesty jsou v `datasets.json` obou native sad. Vlastní build/cache byly po
ověření zdroje, logů a kopií binárek odstraněny; žádné starší scratch nebo sdílené cache se neměnily.
