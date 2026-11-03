# CI a podmínky sloučení pull requestu

## Návrh

[GitHub Actions workflow](../.github/workflows/ci.yml) sestaví a otestuje všechny Swift balíky
v repozitáři. [Ruleset pro `main`](../.github/rulesets/main.json) vyžaduje úspěšnou kontrolu
`CI required`, aktuálnost větve vůči `main` a sloučení přes pull request.
Samotný workflow merge neblokuje: správce musí ruleset jednorázově aktivovat na GitHubu.

## Co se spouští

| Kontrola | Rozsah |
|---|---|
| Discover Swift packages | Najde všechny verzované `Package.swift`; prázdný seznam je chyba |
| Swift (`balík`, `debug`) | `swift build` všech produktů a `swift test` všech testů balíku |
| Swift (`balík`, `release`) | Stejné sestavení a testy s optimalizacemi |
| CI required | Projde pouze při úspěšném nalezení balíků a všech bězích matice |

Aktuálně jde o šest běhů: `spikes/common`, `spikes/s1-session` a `spikes/s5-gateway`,
všechny v debug a release.
Samostatný běh `common` je nutný: `swift test` v gateway nespouští testy jeho závislostí.
Nový verzovaný Swift balík se přidá automaticky a musí obsahovat testy.

Workflow běží pro každý pull request včetně změn dokumentace, po pushi do `main`, při `merge_group`
a při ručním spuštění. Nemá filtry cest. Pull request testuje slučovací commit vytvořený GitHubem.
Nový commit zruší starší běh stejného PR. Selhání jedné položky matice nezastaví ostatní běhy.
Povinná kontrola přes `always()` vyhodnotí i selhání, zrušení nebo přeskočení závislých jobů;
přijímá pouze výsledek `success`. Při zrušení celého workflow nemůže vzniknout nová úspěšná kontrola.

Testy běží na GitHub-hosted Apple Silicon runneru `xcode-27` s macOS 27 a Xcode 27,
v souladu s [GUIDE §2](GUIDE.md#2-prerekvizity). Tento obraz je k 2026-11-03 v public preview;
jeho dostupnost a label je nutné sledovat v [oficiálním seznamu runnerů](https://github.com/actions/runner-images#available-images).
Job ověřuje verzi systému a Xcode i architekturu. Verze prostředí, výstup sestavení, testů a xUnit XML
se ukládají jako artefakty na 14 dnů, i když test selže.

Testy `s1-session` navíc potřebují Metal GPU a aktivní displej. Dostupnost těchto prostředků
na hostovaném runneru musí potvrdit první běh PR. Nedostupný hardware není důvod k přeskočení
testů: kontrola zůstane neúspěšná. Pokud hostovaný obraz jejich požadavky nesplní, pro plné
CI bude potřeba vyhrazený testovací Mac; jeho připojení a bezpečné spouštění kódu PR je samostatný krok.

Oficiální Actions jsou připnuté ke konkrétním commitům. Workflow potřebuje jen `contents: read`,
checkout neuchovává přihlašovací údaje a testy nepotřebují secrets. Používá `pull_request`,
bez privilegovaného `pull_request_target`. Fork PR může podle nastavení GitHubu nejprve čekat
na povolení běhu správcem. Žádné systémové změny ani laboratorní sloty se automaticky nespouštějí.

## Aktivace na GitHubu

1. Dostat workflow do `main` přes PR a ověřit první úspěšný běh. Před prvním sloučením nového
   workflow zkontrolovat i záložku Checks v jeho PR.
2. **Správce repozitáře** otevře Settings → Rules → Rulesets → New ruleset → Import a nahraje
   [main.json](../.github/rulesets/main.json). Zkontroluje cílovou větev `main`, stav Active,
   prázdný seznam bypass a povinnou kontrolu `CI required` se zdrojem GitHub Actions.
3. Alternativně správce z kořene repozitáře vytvoří stejný ruleset přes CLI:

   ```bash
   gh api --method POST repos/Fir3st/sanjbox/rulesets \
     --input .github/rulesets/main.json
   ```

   Příkaz stačí spustit jednou. Při pozdější úpravě se aktualizuje existující ruleset;
   nevytváří se další kopie. JSON v repozitáři je návrh konfigurace, GitHub ho sám neaplikuje.

4. Ověřit pravidla a zkusit PR s úmyslně padajícím testem: `CI required` musí být červená
   a merge zablokovaný. Po opravě musí projít všech šest běhů. Další push do PR musí
   vyvolat nové kontroly; po změně `main` musí GitHub vyžadovat aktualizaci větve a nový běh.

   ```bash
   gh api repos/Fir3st/sanjbox/rules/branches/main
   ```

Ruleset zakazuje přímé pushování do `main`, force push i smazání větve. Nemá výjimky pro
administrátory či aplikace; správce ovšem může samotnou konfiguraci pravidel později změnit.
Počet povinných lidských schválení je záměrně 0, takže lze pracovat i v jednom člověku.
Pro povinné review druhým člověkem lze nastavit `required_approving_review_count` na 1.
Schválení review a sloučení PR jsou různé operace: testy blokují **sloučení**.

Stav zjištěný 2026-11-03: veřejný repozitář `Fir3st/sanjbox`, výchozí větev `main`, žádná aktivní
pravidla pro `main`. Použitý účet má `WRITE`, ale nemá administrátorské oprávnění.
Aktivace ochrany proto vyžaduje správce; lokální soubory zatím nastavení GitHubu nemění.

## Lokální ověření

Na Apple Silicon Macu s macOS 27 a Xcode 27 spusť z kořene repozitáře:

```bash
for package in spikes/common spikes/s1-session spikes/s5-gateway; do
  for configuration in debug release; do
    swift build --package-path "$package" --configuration "$configuration" || exit
    swift test --package-path "$package" --configuration "$configuration" || exit
  done
done
```

Ověření návrhu 2026-11-03: všechny tři balíky se lokálně sestavily a jejich testy prošly
v debug i release (`common`: 25 testů, `s1-session`: 6 testů, `s5-gateway`: 45 testů v každé konfiguraci).
xUnit XML obsahuje odpovídající
výsledky; Swift Testing používá příponu `-swift-testing.xml`, která se spolu s ostatními logy
zahrne do artefaktu. Ověřena byla také syntaxe YAML/JSON a shellových kroků, nalezení Swift balíků
a všech 16 kombinací výsledků vstupních jobů: povinná kontrola přijímá pouze dva úspěchy.
Samotný běh v GitHub Actions a vynucení ochrany se ověří až po nasazení podle postupu výše.

## Rozsah důkazu a rozšiřování

Zelené CI potvrzuje sestavení a existující automatické testy. Nenahrazuje laboratorní důkazy
bran S0–S8 ani neoznačuje 155 případů v [COVERAGE.md](COVERAGE.md) za prošlé. GUI relace, APFS,
pf, TCC, signing a další scénáře vyžadující skutečný testovací Mac zůstávají v laboratorních
slotech podle [GUIDE](GUIDE.md). Jejich výsledky a review se nadále evidují v `docs/evidence`.

Při přidání jiného testovacího systému než SwiftPM doplň nový job a jeho ID do `needs` kontroly
`CI required` i podmínku úspěchu. Bez toho by nový testovací systém nebyl povinný.
Při přejmenování `CI required` současně uprav ruleset na GitHubu i jeho uložený JSON.
Změny workflow a testovací konfigurace vyžadují pečlivé review: autor PR může měnit i samotné testy.
