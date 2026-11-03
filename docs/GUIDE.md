# Ohrádka — průvodce pro implementaci

Jak pracovat na Ohrádce tak, aby výsledky byly důkazem podle [PLAN.md](../PLAN.md) a aby více lidí
nebo agentů mohlo pracovat paralelně bez kolizí. Co dělat a v jakém pořadí: [IMPLEMENTATION.md](IMPLEMENTATION.md).

## 1. Co číst a v jakém pořadí

1. [PLAN.md](../PLAN.md): požadavky R1–R8, threat model, akceptační kontrakt, brány S0–S8. **Autoritativní.**
2. [DECISIONS.md](DECISIONS.md): rozhodnutí F0 a změny kontraktu.
3. [IMPLEMENTATION.md](IMPLEMENTATION.md): fáze, pracovní balíky, laboratorní sloty.
4. [COVERAGE.md](COVERAGE.md): co je hotovo, co prošlo, co ne.
5. Tento průvodce: pravidla, postupy, šablony.

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
  evidence/<brána>/<YYYY-MM-DD>-<běh>/   protokoly běhů                 (§7)
spikes/
  common/               sdílené sondy a protistrana                      (WP0.3, WP0.4)
  s0-boundary/ s1-session/ s2-coherence/ s3-pf/ s4-host/
  s5-gateway/ s6-brew/ s7-docker/ s8-signing/
Contracts/              XPC schémata, stavový automat, formát politiky   (F2, WP2.0)
Helper/ Broker/ SessionAgent/ Gateway/ Docker/ Ohradka/                 (F2–F4)
Tests/Escape/           únikový test suite                               (WP2.8)
```

## 5. Paralelní práce

- **Jeden balík = jedna větev** `wp/<id>-<slug>`, např. `wp/1.D2-npm-typed`. Pro souběh na jednom stroji
  použij git worktree: `git worktree add ../ohradka-wp-1.D2 -b wp/1.D2-npm-typed`.
- **Vlastnictví adresářů:** balík mění jen svůj adresář, svůj řádek v COVERAGE.md a případně vlastní protokoly.
  Změny `spikes/common/`, `Contracts/` a PLAN.md jsou samostatné balíky/commity s review.
- **Převzetí balíku:** v COVERAGE.md §4 nastav stav `🟨 rozpracováno` a vlastníka; commitni to jako první
  commit větve. Tím je vidět, kdo na čem dělá.
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
| sondy (Swift) | První akce každé sondy: `ohr-whoami` kontrola credentials a session proti očekávání; nesoulad = sonda skončí s „neplatné měření“ |

Pravidla pro skripty:

1. `#!/bin/bash` + `set -euo pipefail`; žádné `eval` s externím vstupem.
2. **Výchozí režim je dry-run**: skript vypíše přesně, co by změnil. Změny provede jen s `--apply`.
3. Před změnou zapíše původní stav (práva, ACL, nastavení) do `state/` u protokolu běhu.
4. Každý měnící skript má protějšek pro úklid, který je **idempotentní** a vrací jen vlastní změny.
   Konflikt s pozdější změnou uživatele hlásí, nepřepisuje.
5. Žádné mazání podle neověřené cesty. Cesty se ověřují (existence, vlastník, typ, ne-symlink) před operací.
6. Skripty nečtou obsah souborů v chráněných kořenech; pracují s metadaty a vlastními kanárky.

## 7. Důkazy a verdikty

Každý běh brány vytvoří `docs/evidence/<brána>/<YYYY-MM-DD>-<běh>/`:

| Položka | Obsah |
|---|---|
| `environment.md` | ID stroje z registru LAB.md, model Macu, čip, RAM, macOS + build, displeje, Xcode, souběžně běžící aplikace, verze kódu (commit) |
| `inputs.md` | Testované případy (ID z COVERAGE), vstupy, očekávaný výsledek a oracle stanovené **před** během |
| `credentials.log` | Výstup `ohr-whoami` pro každou sondu |
| `raw/` | Nezpracované výstupy sond a protistrany (bez tajemství, jen kanárky) |
| `verdict.md` | Prošlo / Neprošlo / Nejasné pro každý případ, s odkazem na raw a mapováním na R1–R8 |

Pravidla:

- Rozlišuj **měřeno**, **odvozeno**, **mock** a **hypotéza**. Mock nikdy nedokazuje reálnou integraci.
- Prahy a statistiky se nemění po měření. Pokud se metodika ukáže chybná, nový běh s novou metodikou.
- Chybné credentials sondy = neplatné měření, ne důkaz izolace.
- Verdikt brány zapiš do [spikes.md](spikes.md) a aktualizuj [COVERAGE.md](COVERAGE.md). Bránu uzavírá review.

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
