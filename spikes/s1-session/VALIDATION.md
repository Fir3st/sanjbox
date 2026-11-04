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
