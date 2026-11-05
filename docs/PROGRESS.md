# Sanďbox — status page na GitHub Pages

Jednostránkový status projektu na [fir3st.github.io/sanjbox](https://fir3st.github.io/sanjbox/).
Aktualizuje se po každé změně na `main`. Bez frameworku, CDN, analytiky, tokenů a Python/JS balíčků;
stačí Python 3.9+ a Git.

## Co stránka ukazuje

| Část | Zdroj |
|---|---|
| Celkový stav | Počet prošlých bran S0–S8 (COVERAGE §2). Dokud žádná neprošla, stránka hlásí neověřenou izolaci. |
| Ověřovací brány | Verdikt každé brány a pod ním pruh jejích přípravných a laboratorních balíků (COVERAGE §4) |
| Fáze | Hotové balíky F0–F4 vůči všem balíkům fáze; aktuální je poslední fáze s rozpracovaným nebo hotovým balíkem |
| Poslední změny | Pull requesty sloučené do first-parent historie (název PR z merge commitu), seskupené po dnech |

Přiřazení balíků k branám je v `GATE_PACKAGES` v [tools/progress.py](../tools/progress.py). Při přidání
nebo přejmenování brány či balíku ho uprav; nesoulad s COVERAGE build zastaví.

## Lokální náhled

Z kořene repozitáře:

```sh
python3 tools/progress.py
python3 -m http.server 8765 --bind 127.0.0.1 --directory build/progress
```

Otevři [lokální náhled](http://127.0.0.1:8765/). Výstup z checkoutu s necommitovanými změnami je
na stránce označený jako lokální náhled.

## Co se generuje

| Soubor v `build/progress/` | Účel |
|---|---|
| `index.html` | Status page |
| `progress.json` | Aktuální záznamy, souhrny, provenance a verze schématu |
| `history.json` | Denní souhrny a úplné SHA zdrojových commitů |
| `progress.html`, `history.html` | Přesměrování starých adres na `index.html` |
| `style.css`, `app.js`, `.nojekyll` | Styl, volitelné přepnutí světlého/tmavého režimu a podpora Pages |

Veškerý obsah je v HTML už při sestavení; bez JavaScriptu stránka sleduje systémový režim.
Výstupy jsou ignorované Gitem a generují se v CI.

## Jediný zdroj pravdy

- [COVERAGE.md](COVERAGE.md) §1–5: požadavky, brány, akceptační případy, stavy balíků, blokátory.
- [IMPLEMENTATION.md](IMPLEMENTATION.md) §3: výstupy a závislosti balíků.
- [PLAN.md](../PLAN.md) zůstává autoritativním kontraktem, rozsah MVP vedou [DECISIONS.md](DECISIONS.md).

Generátor počítá **detailní řádky**, nikoli ruční souhrn v COVERAGE §0. Každý balík a brána na stránce
odkazují na svůj zdrojový řádek v konkrétním commitu.

### Pravidla počítání

| Metrika | Čitatel / jmenovatel |
|---|---|
| Implementace | Balíky `✅` / všechny balíky v §4; `🟨` nedává částečný kredit |
| Fáze F0–F4 | Totéž podle prefixu ID `WP0`–`WP4` |
| Brány F1 | `Prošlo` / brány S0–S8 včetně S3b (10 bran); F0 a F2–F4 do této metriky nevstupují |
| Akceptace | Případy `Prošlo` / všechny jednotlivé případy v §3 |
| Požadavky | R1–R8 se stavem `Prošlo` / všechny požadavky v §1 |
| Blokátory | Zvlášť počet otevřených a uzavřených řádků v §5 |

**Hotový pracovní balík neznamená prošlou bránu ani prokázanou izolaci.** Počty unit/mock/lokálních
testů z poznámek balíku se nepřičítají k akceptačním případům. Balíky mají různou pracnost.

Neznámý stav, rozbitá tabulka, chybějící sekce, duplicitní ID a nesoulad seznamů balíků zastaví build.
`Prošlo` u případu či brány vyžaduje Markdown odkaz na důkaz; splněný požadavek vyžaduje prošlé
rozhodující brány. Odkaz sám není review důkazu: měření a uzavírání bran se řídí
[GUIDE §7–8](GUIDE.md#7-důkazy-a-verdikty). Generátor žádný test izolace nespouští a verdikt sám nemění.

### Historie

`history.json` se rekonstruuje offline z úplného Git checkoutu. Pro každý **UTC den s commitem** vybere
poslední commit na `--first-parent` historii zvoleného refu a přepočítá tehdejší COVERAGE + IMPLEMENTATION
současnými pravidly. Aktivita vedlejší větve se započte až v jejím merge. Neplatná historická dokumentace
build zastaví. Shallow checkout se odmítne: v Actions je nutné `fetch-depth: 0`.

```sh
python3 tools/progress.py --out /tmp/sanjbox-progress --history-ref main --repository Fir3st/sanjbox
python3 -m unittest discover -s tools/tests -v
```

## Aktualizace při vývoji

1. Uprav řádek balíku v COVERAGE §4 a případně jeho definici v IMPLEMENTATION §3.
2. Pro stav případu přidej protokol a odkaz do §3; bránu uzavři až po review podle GUIDE.
3. Aktualizuj souhrny COVERAGE §0 podle stávajícího postupu.
4. Spusť generátor nebo si v pull requestu stáhni CI artefakt `progress-preview`.

Vzhled a texty stránky jsou v `tools/progress-site/`, logika v `tools/progress.py`. Tvrzení o projektu
musí odpovídat PLAN a DECISIONS. Pro kopii repozitáře předej `--repository owner/name`;
CI použije automaticky `${{ github.repository }}`.

## GitHub Actions a Pages

[Workflow](../.github/workflows/progress.yml) při pull requestu a pushi do `main` (a vývojové větve `codex/development-status`) ověří generátor,
sestaví web a uloží náhled `progress-preview` na 14 dní. PR nic nepublikují. Na `main` se po
úspěšném buildu nasadí stejný výstup na Pages (zdroj Pages: **GitHub Actions**). Workflow lze spustit
ručně přes `workflow_dispatch`; nasazení je povolené jen z `main`.

Workflow nemění nastavení repozitáře a nevyžaduje PAT ani push do `gh-pages`. Práva `pages: write`
a `id-token: write` má pouze deploy job na `main`; build job má jen `contents: read` a checkout
neuchovává credentials. Konfigurace vychází z
[dokumentace GitHub Pages](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages).
