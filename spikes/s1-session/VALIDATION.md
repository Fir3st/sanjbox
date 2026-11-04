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
