# Sanďbox — projektový web na GitHub Pages

Projektový web inspirovaný [AnyPS5](https://boykopovar.github.io/AnyPS5/), jeho
[progresem](https://boykopovar.github.io/AnyPS5/progress.html) a
[historií](https://boykopovar.github.io/AnyPS5/history.html). Vlastní implementace bez cizího
kódu, frameworku, CDN, analytiky, tokenů nebo Python/JS balíčků. Stačí Python 3.11+ a Git.

## Veřejný web a struktura

Hlavní výstup je trvale dostupný web na **GitHub Pages** pod
`https://fir3st.github.io/sanjbox/`, který se aktualizuje po změnách na `main`.
`index.html` je úvodní stránka projektu: vysvětluje, proč Sanďbox vzniká, co má dělat,
jaká je navržená architektura, co už existuje a kam vývoj směřuje. Stav čerpá ze stejných
dat jako detailní podstránky `progress.html` a `history.html`.

Web v této branchi ještě není publikovaný. Zapnutí Pages a první nasazení popisuje sekce níže.
Artefakt v CI slouží jen k náhledu změn při review. Návštěvník publikovaného webu nic nestahuje,
nesestavuje ani lokálně nespouští; stránky otevírá přímo v prohlížeči.

## Lokální náhled pro vývojáře

Z kořene repozitáře:

```sh
python3 tools/progress.py
python3 -m http.server 8765 --bind 127.0.0.1 --directory build/progress
```

Otevři [lokální přehled](http://127.0.0.1:8765/). Server ukončíš Ctrl-C.
Prosté otevření `build/progress/index.html` funguje také: stránka nenačítá data přes fetch.
Po změně dokumentace generátor spusť znovu a obnov stránku.

## Co se generuje

| Soubor v `build/progress/` | Účel |
|---|---|
| `index.html` | Hlavní stránka projektu: cíle, architektura, aktuální stav, hotové části a roadmapa |
| `progress.html` | Podrobné metriky, mapa balíků a případů, filtrovatelné tabulky, brány, požadavky a blokátory |
| `history.html` | Grafy hotových položek vůči celkovému rozsahu, denní tabulka a odkazy na commity |
| `progress.json` | Aktuální záznamy, souhrny, provenance a verze schématu |
| `history.json` | Denní metriky a úplné SHA zdrojových commitů |
| `progress.svg` | Samostatná mapa progresu pro README nebo sdílení |
| `style.css`, `app.js`, `.nojekyll` | Lokální styl, hledání, filtry, světlé/tmavé téma a podpora Pages |

Obsah, SVG grafy a tabulky jsou v HTML už při sestavení. Bez JavaScriptu zůstávají čitelné;
JavaScript přidává hledání bez diakritiky, kombinaci filtrů a uloženou volbu tématu.
Výstupy jsou ignorované Gitem, generují se znovu při CI a nemusí se commitovat.

## Jediný zdroj pravdy

- [COVERAGE.md](COVERAGE.md) §1–5: požadavky, brány, akceptační případy, stavy a vlastníci balíků, blokátory.
- [IMPLEMENTATION.md](IMPLEMENTATION.md) §3: výstupy a závislosti balíků.
- [PLAN.md](../PLAN.md) zůstává autoritativním kontraktem. Rozhodnutí a rozsah MVP se vedou v
  [DECISIONS.md](DECISIONS.md); přehled na ně odkazuje.

Generátor počítá **detailní řádky**, nikoli ruční souhrn v COVERAGE §0, počet commitů, řádků kódu nebo
testovacích funkcí. Ruční souhrn tedy nemůže přepsat skutečný výsledek. Každý záznam odkazuje na
zdrojový řádek v konkrétním commitu; výstup z nečistého checkoutu je označený jako lokální náhled
a jeho necommitované změny ještě nebudou na GitHubu pod tímto SHA dostupné.

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
testů z poznámek balíku se nepřičítají k akceptačním případům. Balíky mají různou pracnost;
například 4/57 hotových balíků není odhad, že produkt je ze 7 % hotový.

Neznámý stav, rozbitá tabulka, chybějící sekce, duplicitní ID a nesoulad seznamů balíků zastaví build.
`Prošlo` u případu či brány vyžaduje Markdown odkaz na důkaz; splněný požadavek vyžaduje prošlé
rozhodující brány. Odkaz sám není review důkazu: měření, platnost protokolu a uzavírání bran se nadále
řídí [GUIDE §7–8](GUIDE.md#7-důkazy-a-verdikty). Generátor žádný test izolace nespouští a verdikt sám nemění.

### Historie

Historie se rekonstruuje offline z úplného Git checkoutu, bez stahování metrik nebo samostatné
datové větve. Pro každý **UTC den s commitem** vybere poslední commit na `--first-parent` historii
zvoleného refu a přepočítá tehdejší COVERAGE + IMPLEMENTATION současnými pravidly. Aktivita vedlejší
větve se započte až v jejím merge na sledovanou větev. Dny před existencí obou dokumentů se vynechají.
Neplatná historická dokumentace build zastaví; nevyrobí tichou díru v grafu.

Výchozí ref je `HEAD`; v CI na `main` tak graf ukazuje historii `main`, v PR historii testovaného
merge. Pro lokální porovnání lze použít `--history-ref main`. Aktuální přehled vždy čte pracovní
strom; lokální necommitované změny **nejsou** historické body. Dny bez commitů se nepřidávají a
mezery v grafu odpovídají skutečně uplynulému času. Jednodenní projekt má jeden bod, bez vymyšleného trendu.

Graf ukazuje dokončený i celkový počet položek. Změna rozsahu může snížit procento dokončení;
nejde automaticky o regresi. Změna metodiky přepočítá všechny body. Shallow checkout se odmítne:
v Actions je nutné `fetch-depth: 0`, lokálně případně `git fetch --unshallow`.

```sh
python3 tools/progress.py --out /tmp/sanjbox-progress --history-ref main --repository Fir3st/sanjbox
python3 -m unittest discover -s tools/tests -v
```

## Aktualizace při vývoji

1. Uprav vlastní řádek balíku v COVERAGE §4 a případně jeho definici v IMPLEMENTATION §3.
2. Pro stav případu přidej protokol a odkaz do §3; bránu uzavři až po review podle GUIDE.
3. Aktualizuj odpovídající souhrny COVERAGE §0 podle stávajícího postupu.
4. Spusť generátor nebo si v pull requestu stáhni CI artefakt `progress-preview`.

Pro změnu webu uprav `tools/progress.py` nebo `tools/progress-site/` a spusť testy.
Redakční obsah úvodní stránky je v `tools/progress-site/home.html`; počty a seznam hotových balíků
se do něj doplní automaticky. Tvrzení o schopnostech a rozsahu musí odpovídat PLAN a DECISIONS.
Při přidání/změně významu metrik uprav tuto metodiku i regresní testy. Pro kopii repozitáře předej
`--repository owner/name`; CI použije automaticky `${{ github.repository }}`.

## GitHub Actions a Pages

[Workflow](../.github/workflows/progress.yml) při pull requestu a pushi do `main` či větve
`codex/development-status` ověří generátor, sestaví web, přiloží souhrn a uloží náhled na 14 dní.
PR a vývojová větev nic nepublikují. Na `main` se po úspěšném buildu nasadí stejný výstup na Pages.
Workflow lze ručně spustit pomocí `workflow_dispatch` (nasazení je povolené pouze z `main`).

Jednorázové zapnutí po review větve:

1. **Správce repozitáře** v **Settings → Pages → Build and deployment → Source** vybere **GitHub Actions**.
   Připojený účet má podle kontroly 2026-11-03 právo `push`, ale nemá `admin` ani `maintain`;
   tímto účtem nelze jednorázové zapnutí Pages dokončit.
2. Slouč větev do `main`; workflow nasadí projektový web včetně hlavní stránky a podstránek.
   Pokud už merge proběhl, spusť workflow na `main` ručně.
3. URL vrátí deploy job. Při standardním nastavení tohoto repozitáře bude
   [fir3st.github.io/sanjbox](https://fir3st.github.io/sanjbox/), progres pod `progress.html`
   a historie pod `history.html`. V nastavení About repozitáře lze tuto URL uvést jako Website.

Workflow nemění nastavení ani viditelnost repozitáře a nevyžaduje PAT nebo push do `gh-pages`.
Práva `pages: write` a `id-token: write` dostává pouze deploy job na `main`. Preview job má pouze
`contents: read`; checkout neuchovává credentials. Nastavení environmentu `github-pages` může
podle politiky repozitáře vyžadovat schválení. Publikování připravujeme v branchi; před mergem není web živý.

Po prvním úspěšném nasazení lze do README vložit automaticky aktuální obrázek:

```markdown
[![Sanďbox — stav vývoje](https://fir3st.github.io/sanjbox/progress.svg)](https://fir3st.github.io/sanjbox/)
```

Konfigurace nasazení vychází z [oficiální dokumentace GitHub Pages](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages).
