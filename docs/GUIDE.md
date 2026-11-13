# Sanďbox — průvodce pro implementaci

Jak pracovat na Sanďboxu tak, aby výsledky byly důkazem podle [PLAN.md](../PLAN.md) a aby více lidí
nebo agentů mohlo pracovat paralelně bez kolizí. Co dělat a v jakém pořadí: [IMPLEMENTATION.md](IMPLEMENTATION.md).

## 1. Co číst a v jakém pořadí

1. [PLAN.md](../PLAN.md): požadavky R1–R8, threat model, akceptační kontrakt, brány S0–S8. **Autoritativní.**
2. [DECISIONS.md](DECISIONS.md): rozhodnutí F0 a změny kontraktu.
3. [IMPLEMENTATION.md](IMPLEMENTATION.md): fáze, pracovní balíky, laboratorní sloty.
4. [COVERAGE.md](COVERAGE.md): co je hotovo, co prošlo, co ne.
5. Tento průvodce: pravidla, postupy, šablony.
6. [LAB.md](LAB.md): registr strojů, rezervace, předregistrace a metodika (LAB-v1, přijato v F0.8).

## 2. Prerekvizity

| Položka | Požadavek |
|---|---|
| Hardware | Obecný Mac s Apple Silicon (F0.8). Minimální podporovanou konfiguraci určuje DECISIONS.md; každý testovací stroj je zapsaný v registru `docs/LAB.md`. |
| macOS | 27.x. Každý verdikt brány uvádí přesnou verzi a build; brána platí jen pro konfigurace, na kterých prošla. |
| Xcode | 27.x (Swift 6.x). Žádné externí Swift balíčky ve spikech bez schválení (PLAN: brána bez závislostí). |
| Podpis | Bezplatný Personal Team. **Nikdy `get-task-allow`** v podepsaných binárkách sond, agenta ani helperu; hardened runtime. |
| Laboratoř | Testovací Mac s čerstvou zálohou před každým slotem. Bez skutečných projektů, účtů a tajemství v testovacích oblastech. |

## 3. Bezpečnostní pravidla práce (nepřekročitelná)

Platí pro lidi i AI agenty, kteří na projektu pracují.

1. **Žádná skutečná tajemství.** Nečíst, nekopírovat, nevypisovat ani neměnit `.env*`, klíče, certifikáty,
   Klíčenky, credential stores, tokeny ani soubory s `secret`/`token`/`credential` v názvu.
   Testy používají **syntetické kanárky** a **mocky**.
2. **Žádné živé databáze** ani credential stores v automatických testech. Skutečná integrace (účet, scopes,
   revokace) je zvlášť evidovaný uživatelský důkaz.
3. **Privilegované kroky spouští uživatel.** Implementátor nespouští `sudo`, nemění systémová nastavení
   a nevytváří uživatele. Připraví skript podle §6 a předá ho.
4. **Žádné spouštění cizích balíčků bez schválení konkrétního příkazu** (`npx`, `npm exec`, `brew install`
   v testech apod.). Výchozí testy brány používají `npm view`/`npm pack` a fixtures, ne instalační skripty.
5. **Testovací oblasti před prošlými branami** obsahují jen kontrolované sondy, požadované testovací aplikace
   s prázdnými profily a syntetická data.
6. **Root operace z oblasti neexistují.** Žádný kód nesmí oblasti nabídnout cestu k privilegované akci.
7. **Neprošlo zůstává neprošlo.** Selhání se nepřejmenovává na reziduum. Změna požadavku jen přes DECISIONS.md
   s výslovným rozhodnutím uživatele.

## 4. Struktura repozitáře

Adresáře vznikají až s prvním balíkem, který je potřebuje.

```
PLAN.md                 autoritativní kontrakt
docs/
  IMPLEMENTATION.md     fáze a pracovní balíky
  GUIDE.md              tento průvodce
  COVERAGE.md           stav požadavků, bran, testů a balíků
  DECISIONS.md          rozhodnutí F0 a změny kontraktu
  spikes.md             verdikty bran F1
  LAB.md                baseline laboratoře, metodika, rezervace slotů   (WP0.5)
  templates/lab/        šablony stroje/slotu a protokolu běhu           (WP0.5)
  evidence/<brána>/<run-id>/  neměnné protokoly jednotlivých běhů       (§7)
spikes/
  common/               sdílené sondy a protistrana                      (WP0.3, WP0.4)
  s0-boundary/ s1-session/ s2-coherence/ s3-pf/ s4-host/
  s5-gateway/ s6-brew/ s7-docker/ s8-signing/
proto/                  izolované prototypy jádra proti mockům (proud H, IMPLEMENTATION §3)
Contracts/              XPC schémata, stavový automat, formát politiky   (F2, WP2.0)
Helper/ Broker/ SessionAgent/ Gateway/ Docker/ Sanjbox/                 (F2–F4)
Tests/Escape/           únikový test suite                               (WP2.8)
```

## 5. Paralelní práce

- **Výběr práce:** začni aktuálním [IMPLEMENTATION §0](IMPLEMENTATION.md#0-co-dál), potom ověř
  COVERAGE §4 na aktuálním `main` a otevřené PR daného balíku. Pořadí v plánu neznamená, že balík je
  volný; zkontroluj vlastníka, závislosti i přesnou podmínku dokončení. Sloučené částečné PR neznamená
  hotový balík a hotová příprava neznamená prošlou bránu.
- **Jeden vymezený balík nebo follow-up = jedna větev**, pro agenty `codex/<id>-<slug>`, např.
  `codex/wp1-h1-broker-manifest`. Existující přidělenou větev lze dokončit pod původním názvem.
  Pro souběh na jednom stroji použij samostatný worktree; sdílený checkout nesmí přepínat dvě práce současně.
- **Vlastnictví adresářů:** balík mění jen svůj adresář, svůj řádek v COVERAGE.md a případně vlastní protokoly.
  Změny `spikes/common/`, `Contracts/` a PLAN.md jsou samostatné balíky/commity s review.
- **Převzetí volného balíku:** jen při splněných závislostech nastav v COVERAGE.md §4 stav
  `🟨 rozpracováno` a vlastníka; první commit větve uvede rozsah a podmínku dokončení. Claim zveřejni
  ve větvi/PR, aby ho ostatní viděli. Samotný lokální commit ani dva souběžné claimy nejsou zámek;
  před implementací vyřeš kolizi.
- **Obsazený balík:** pokračuje jeho vlastník. Jiný agent potřebuje výslovné zadání/předání od uživatele
  nebo dohodu s vlastníkem o konkrétní části, větvi a hranicích změn; existující zadání stačí.
  V COVERAGE zachovej původní autorství a zaznamenej navazujícího vlastníka/rozsah, nepřebírej cizí
  rozpracovanou větev tiše. Změnu rozhraní H1 koordinuj s H2/H4/A6 a budoucími H3/H6; zachovej kompatibilitu
  dokončeného H2 a znovu spusť jeho testy.
- **Čekání:** pokud je balík hotový, čeká na lab/rozhodnutí nebo nemá splněné závislosti, není automaticky
  k převzetí. Uveď konkrétní blokátor a pokračuj jiným dostupným zadáním; pokud žádné není, ohlas stav
  podle §11. Nevytvářej další přípravný follow-up bez nálezu a konečné podmínky dokončení.
- **Laboratoř:** každý vývojář testuje na svém stroji zapsaném v registru `docs/LAB.md`. Před během zapiš
  rezervaci slotu (stroj, slot, kdo, kdy). Na jednom stroji dva sloty nikdy neběží současně; různé stroje
  mohou běžet paralelně. Slot končí ověřeným úklidem. Neměř na stroji se skutečnými tajemstvími v cestách,
  které test zpevňuje, dokud nemáš zálohu a neprošel dry-run.
- **Integrace:** větev se slučuje do `main` až s aktualizovanou COVERAGE.md. Konflikty v COVERAGE.md řeš
  ručně po řádcích; nikdy nepřepisuj cizí stav.

## 6. Jak psát spike

Každý `spikes/<brána>/` obsahuje:

| Soubor | Obsah |
|---|---|
| `README.md` | Cíl, mapování na R a testy z COVERAGE, prerekvizity, kroky (označené **[uživatel]** / **[implementátor]**), oracle, očekávaný výsledek, úklid |
| skripty `*.sh` | Viz pravidla níže |
| sondy (Swift) | První akce každé sondy: `sanjbox-whoami` kontrola credentials a session proti očekávání; nesoulad = sonda skončí s „neplatné měření“ |

Pravidla pro skripty:

1. `#!/bin/bash` + `set -euo pipefail`; žádné `eval` s externím vstupem.
2. **Výchozí režim je dry-run**: skript vypíše přesně, co by změnil. Změny provede jen s `--apply`.
3. Před změnou zapíše původní stav (práva, ACL, nastavení) do `state/` u protokolu běhu.
4. Každý měnící skript má protějšek pro úklid, který je **idempotentní** a vrací jen vlastní změny.
   Konflikt s pozdější změnou uživatele hlásí, nepřepisuje.
5. Žádné mazání podle neověřené cesty. Cesty se ověřují (existence, vlastník, typ, ne-symlink) před operací.
6. Skripty nečtou obsah souborů v chráněných kořenech; pracují s metadaty a vlastními kanárky.

## 7. Důkazy a verdikty

Každý běh brány vytvoří nový `docs/evidence/<brána>/<run-id>/`; formát jedinečného ID je
`<UTC-YYYYMMDDTHHMMSSZ>-<veřejný-alias>-<stroj>-<revize>-<náhodných-8-hex>` podle [LAB §3](LAB.md#3-předregistrace-a-platnost-důkazu).
Předregistrace a šablony jsou v [LAB.md](LAB.md). Žádný adresář běhu se nepoužije podruhé.

| Položka | Obsah |
|---|---|
| `environment.md` | ID stroje z registru LAB.md, model Macu, čip, RAM, macOS + build, displeje, Xcode, souběžně běžící aplikace, verze kódu (commit) |
| `inputs.md` | Testované případy (ID z COVERAGE), vstupy, očekávaný výsledek a oracle stanovené **před** během |
| `credentials.log` | Výstup `sanjbox-whoami` pro každou sondu |
| `raw/` | Nezpracované výstupy sond a protistrany (bez tajemství, jen kanárky) |
| `verdict.md` | Prošlo / Neprošlo / Nejasné pro každý případ, s odkazem na raw a mapováním na R1–R8 |
| `manifest.sha256` | Hashe publikovaných souborů při uzavření (bez hashe manifestu samotného); následné opravy jsou nové záznamy |
| `amendments/`, `reviews/` | Nové datované opravy interpretace/metadat a následná review s autorem, důvodem a odkazem na původní soubor; původní důkaz zůstává |

Pravidla:

- Rozlišuj **měřeno**, **odvozeno**, **mock** a **hypotéza**. Mock nikdy nedokazuje reálnou integraci.
- Prahy a statistiky se nemění po měření. Pokud se metodika ukáže chybná, nový běh s novou metodikou.
- Chybné credentials sondy = neplatné měření, ne důkaz izolace.
- Uzavřené běhy jsou neměnné. Zachovej všechny výsledky různých vývojářů/strojů i neplatné a neúspěšné
  běhy; nové měření má nové ID. Oprava kódu nikdy nepřepíše staré raw ani verdict.
- Přidej běh do indexu konkrétní brány v [spikes.md](spikes.md); při merge zachovej oba souběžné záznamy.
  Verdikty platí pro konkrétní konfigurace, rozdíly a rozpory zůstávají viditelné. [COVERAGE.md](COVERAGE.md)
  pouze odvozuje souhrn z indexu, nikdy nepřebírá automaticky poslední výsledek. Bránu uzavírá review.

## 8. Definice hotového

**Pracovní balík je hotový**, když:
- výstup z IMPLEMENTATION.md existuje v repozitáři a je zdokumentovaný (README);
- skripty mají dry-run a úklid; sondy kontrolují credentials;
- automatické testy (pokud jsou) prochází a mocky jsou jako mocky označené;
- COVERAGE.md §4 je aktualizovaná.

**Brána prošla**, když:
- všechny její případy v COVERAGE.md §3 mají stav Prošlo s odkazem na protokol;
- měření proběhlo v souběhu a na verzi macOS, které brána vyžaduje;
- review potvrdilo verdikt proti PLAN.md;
- žádný blokátor PLAN §Otevřené blokátory v rozsahu brány nezůstal otevřený.

## 9. Commity

- Krátký předmět v rozkazovacím způsobu, s ID balíku: `WP1.D2: enforce cooldown on tarball requests`.
- Jeden commit = jedna logická změna; COVERAGE.md se mění ve stejném commitu jako výstup, který stav mění.
- Do repozitáře nikdy necommituj tajemství, osobní data ani surové výstupy obsahující cokoli mimo kanárky.

## 10. Jak aktualizovat coverage

1. Stav balíku: COVERAGE.md §4 (`⬜ nezahájeno` → `🟨 rozpracováno` → `✅ hotovo`, případně `⛔ blokováno` s důvodem).
2. Stav testu: COVERAGE.md §3 (`Neověřeno` → `Prošlo` / `Neprošlo` / `Nejasné`) vždy s odkazem na protokol.
3. Stav brány: COVERAGE.md §2 se mění až po verdiktu v spikes.md a review.
4. Stav požadavku: COVERAGE.md §1 se odvozuje z bran; nikdy se nemění přímo.
5. Poznámka balíku v COVERAGE.md §4 má nejvýš dvě věty a odkaz. Podrobnosti patří do dokumentace balíku.

## 11. Kdy přípravu ukončit

1. **Přípravný balík končí podmínkou dokončení** z [IMPLEMENTATION §0](IMPLEMENTATION.md#0-co-dál)
   nebo ze svého výstupu v §3. Po jejím splnění je balík ✅. Další práce je nový balík s důvodem
   z laboratorního běhu nebo review, ne pokračování přípravy.
2. **Neměnné záznamy podle §7 patří k laboratorním během** (L1-D až L8) a k host diagnostice, ze které se
   odvozuje brána. Patří k nim i publikační kopie, sanitizované odvozeniny a nezávislé review. Offline
   příprava (kód, fixtures, mocky, prototypy) se dokládá testy v CI a krátkou poznámkou ve VALIDATION:
   co bylo ověřeno, kolik testů a na jakém commitu.
3. **Čekání se nevyplňuje náhražkou.** Když další krok potřebuje laboratoř nebo rozhodnutí uživatele,
   zapiš to do COVERAGE (`⛔` s důvodem, nebo „čeká na L…/U…“) a vezmi jiný balík z IMPLEMENTATION §0.
   Offline důkaz nenahrazuje měření, které chybí.
4. **Dva PR bez posunu k podmínce dokončení = stop.** Napiš do COVERAGE, co balík blokuje, a nepokračuj.
