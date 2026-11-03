# Sanďbox — verdikty bran F1

Výstup F1 podle [PLAN.md §Výstup F1](../PLAN.md). Každá brána má **index všech běhů** a závěry pro
konkrétní konfigurace; různí vývojáři i stroje mohou mít rozdílné výsledky. Neměnné protokoly zůstávají
v `docs/evidence/<brána>/<run-id>/`. Postup: [GUIDE.md §7](GUIDE.md#7-důkazy-a-verdikty),
identifikátory a zachování historie: [LAB §3](LAB.md#3-předregistrace-a-platnost-důkazu).
Odvozený souhrnný stav: [COVERAGE.md §2](COVERAGE.md#2-brány).

Verdikt: **Prošlo** · **Neprošlo** · **Nejasné** · **Neověřeno**. „Nevyřešeno“ není pass;
bezpečnostní fail se neopravuje přejmenováním na reziduum. Bez provedeného měření zůstává Neověřeno.

Do tabulek se **přidávají** řádky pro každý běh, pozdější opravu/review a závěr konfigurace. Existující
řádek ani důkaz se nepřepíše novějším výsledkem. Každá oprava má nový odkaz na `amendments/`, review
na `reviews/`; při merge zachovat příspěvky všech autorů. Souhrnné závěry také mají vlastní datovaný
záznam a odkazy na všechny posuzované běhy, včetně rozporů. Nový souhrn odkazuje na předchozí.

Konfigurační klíč = stroj/revize + macOS build + displeje/workload + konstrukce + commit kódu + verze
akceptace. Odlišný stroj může současně mít odlišný verdikt. Rozpor platných běhů stejné konfigurace
se neprůměruje ani neřeší posledním zápisem: bezpečnostní fail znamená Neprošlo, jinak potvrzení
konfigurace zůstává Nejasné do review příčiny. Širší stav v COVERAGE vyjmenuje ověřený i neověřený
rozsah; výzkumný nepodporovaný stroj se nestává povinnou konfigurací bez rozhodnutí.

## Šablona verdiktu jednoho běhu

Úplná předregistrace a vyhodnocení: [šablona běhu](templates/lab/run.md). Tento stručný záznam patří
do jeho `verdict.md`, ne místo staršího výsledku v indexu.

```markdown
## S<n> — <run-id>

- Verdikt: Neověřeno
- Datum, veřejný alias vývojáře a běh: UTC, alias, docs/evidence/s<n>/<run-id>/
- Konfigurace: stroj/revize, model Macu, RAM, macOS + build, displeje/workload, konstrukce, commit, metodika
- Credentials sond: odkaz na credentials.log; soulad s očekáváním ano/ne
- Mapování na požadavky: R…
- Případy: tabulka ID → Prošlo/Neprošlo/Nejasné → odkaz na raw
- Měřeno / odvozeno / mock / hypotéza: rozlišit u každého závěru
- Blokátory v rozsahu brány: …
- Rezidua mimo threat model: …
- Review: kdo, datum, závěr
- Vztah k jiným běhům a rozporům: odkazy, žádné odstranění staršího výsledku
```

## S1 — Neviditelná relace

- Souhrn: **Neověřeno**. Evidována dílčí diagnostika sondy v host konzoli M1; žádný akceptační běh tří relací ani závěr konfigurace S1.

| UTC / ID záznamu | Typ: běh / oprava / review / závěr konfigurace | Autor | Konfigurační klíč | Verdikt a rozsah | Důkaz / vazba na předchozí záznamy |
|---|---|---|---|---|---|
| 2026-11-03T13:41:57Z / 20261103T134131Z-janfiedler-LAB-janfiedler-01-r1-a8a26eeb | běh: dílčí host diagnostika | janfiedler / Codex; review Astra xhigh | LAB-janfiedler-01/r1, M1/16 GiB, 27.2/26B123, externí 3440×1440/100 Hz/1×, host konzole, kód 9462158, vlastní předregistrace 3×5 s | S1 **Neověřeno**; 3/3 platné host sondy, bez rozhodnutí F0.8/P1–P6 | [Výsledek a raw](evidence/s1/20261103T134131Z-janfiedler-LAB-janfiedler-01-r1-a8a26eeb/verdict.md); historický M5 záznam v README A1 zachován samostatně |

## S0 — Hranice a attack surface

- Souhrn: **Neověřeno**. Žádný evidovaný běh ani závěr konfigurace.

| UTC / ID záznamu | Typ: běh / oprava / review / závěr konfigurace | Autor | Konfigurační klíč | Verdikt a rozsah | Důkaz / vazba na předchozí záznamy |
|---|---|---|---|---|---|

## S8 — Signing, TCC a broker

- Souhrn: **Neověřeno**. Žádný evidovaný běh ani závěr konfigurace.

| UTC / ID záznamu | Typ: běh / oprava / review / závěr konfigurace | Autor | Konfigurační klíč | Verdikt a rozsah | Důkaz / vazba na předchozí záznamy |
|---|---|---|---|---|---|

## S4 — Zpevnění hosta

- Souhrn: **Neověřeno**. Žádný evidovaný běh ani závěr konfigurace.

| UTC / ID záznamu | Typ: běh / oprava / review / závěr konfigurace | Autor | Konfigurační klíč | Verdikt a rozsah | Důkaz / vazba na předchozí záznamy |
|---|---|---|---|---|---|

## S3 — pf podle uživatele

- Souhrn: **Neověřeno**. Žádný evidovaný běh ani závěr konfigurace.

| UTC / ID záznamu | Typ: běh / oprava / review / závěr konfigurace | Autor | Konfigurační klíč | Verdikt a rozsah | Důkaz / vazba na předchozí záznamy |
|---|---|---|---|---|---|

## S3b — Ingress a loopback

- Souhrn: **Neověřeno**. Žádný evidovaný běh ani závěr konfigurace.

| UTC / ID záznamu | Typ: běh / oprava / review / závěr konfigurace | Autor | Konfigurační klíč | Verdikt a rozsah | Důkaz / vazba na předchozí záznamy |
|---|---|---|---|---|---|

## S5 — Typované brány

- Souhrn: **Neověřeno**. Žádný evidovaný běh ani závěr konfigurace.

| UTC / ID záznamu | Typ: běh / oprava / review / závěr konfigurace | Autor | Konfigurační klíč | Verdikt a rozsah | Důkaz / vazba na předchozí záznamy |
|---|---|---|---|---|---|

## S6 — Homebrew per oblast

- Souhrn: **Neověřeno**. Žádný evidovaný běh ani závěr konfigurace.

| UTC / ID záznamu | Typ: běh / oprava / review / závěr konfigurace | Autor | Konfigurační klíč | Verdikt a rozsah | Důkaz / vazba na předchozí záznamy |
|---|---|---|---|---|---|

## S2 — Coherence

- Souhrn: **Neověřeno**. Žádný evidovaný běh ani závěr konfigurace.

| UTC / ID záznamu | Typ: běh / oprava / review / závěr konfigurace | Autor | Konfigurační klíč | Verdikt a rozsah | Důkaz / vazba na předchozí záznamy |
|---|---|---|---|---|---|

## S7 — Docker

- Souhrn: **Neověřeno**. Žádný evidovaný běh ani závěr konfigurace.

| UTC / ID záznamu | Typ: běh / oprava / review / závěr konfigurace | Autor | Konfigurační klíč | Verdikt a rozsah | Důkaz / vazba na předchozí záznamy |
|---|---|---|---|---|---|
