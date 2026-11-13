# WP1.H2 — validace offline prototypu

Datum: **2026-11-13**. Základ `main`: `6c80c8f378c8658b4d80abde061dcb32a744cb8d` (H1 po PR #73).
Implementace: `1d9917f`; finální zdroj a testy: **`ba306985cae3e41d3deae0fe9117f7e3fd0fd562`**.
Původní dokumentační commit `98736fe` přidal tento záznam a změnil pouze H2 řádek COVERAGE;
navazující review a předání plánu jsou zaznamenané níže.

**Výsledek je mock/offline příprava H2.** Žádný skutečný uživatel, svazek, launchd job, proces oblasti,
síť, systémové nastavení ani TCC nebyly vytvořeny či změněny. Jediné procesy jsou build/test runner
a vlastní crash worker ukončující se `_exit(77)`. LC-06/LC-11, S0/S4, R2 a ostatní brány zůstávají
**Neověřeno**; process-crash test není OS admission ani reboot/power-loss důkaz.

## Prostředí a příkazy

- macOS 27.2.1, build `26B131`, arm64.
- Xcode 27.2, build `27B52`.
- Apple Swift 6.4.2 (`swiftlang-6.4.2.1.9`, clang `2100.4.1.1`), Swift 6 language mode.
- Žádné externí SwiftPM dependencies. Lokální H1 se kompiluje přímo z checkoutu.

```sh
swift build --package-path proto/lifecycle --scratch-path /private/tmp/sanjbox-h2-fast --configuration debug
swift test --package-path proto/lifecycle --scratch-path /private/tmp/sanjbox-h2-fast --configuration debug
swift build --package-path proto/lifecycle --scratch-path /private/tmp/sanjbox-h2-release --configuration release
swift test --package-path proto/lifecycle --scratch-path /private/tmp/sanjbox-h2-release --configuration release
git diff --check
```

## Pokrytí a výsledky

| Kontrola | Rozsah | Výsledek |
|---|---|---|
| Build všech produktů | library + testovací crash driver, Debug/Release | Prošlo |
| XCTest Debug | 37 testových metod, včetně tabulkových scénářů níže | Prošlo, 0 failures, 55,7 s |
| XCTest Release | Stejných 37 metod | Prošlo, 0 failures, 44,8 s |
| H1 životní cyklus | manifest/report/audit, všechny dosažitelné H1 stavy a zakázané operace, starting → stopping | Prošlo v mocku |
| Process crash matrix | 5 operací, 24 kroků, **116** bodů: před/po begin, před/po intent, po efektu, po done, před/po finish | V každém bodě skutečný `_exit(77)`, nový store/koordinátor, očekávaný recovery/deny |
| H1 crash oracle | Doslovná tabulka **9** `ZoneCrashPoint` → očekávaná `ZoneRecoveryAction` | Žádný chybějící bod; review/cleanup pravidla zachována |
| Retry/error matrix | **24** známých no-effect selhání + **24** nejistých post-effect selhání | No-effect ověřen a retry bez duplicitního success auditu; nejistý intent zůstane deny i po restartu |
| LC-06 | Každá hranice stop/cleanup, start/resume po vypnutí a po cleaned | Odmítnuto; celá cesta mock admission uzavřena |
| LC-11 | Druhá oblast se stejným UID, třetí s jiným; všechny stavy a **24** cleanup hranic po restartu | Reuse až po finish(cleanup); nové přidělení zneplatní také starší `uidReusable` inspection |
| Whole UID | GUI, user-job, CLI, detached, stopped; joby a obě domény | Bootout ponechá ne-GUI procesy, whole-UID stop dosáhne nuly a modelovaného restart-denial |
| Striktní persistence | Unknown/duplicate/truncated/oversized/noncanonical JSON, mezera/orphan/head hash, forged transitions a UID collision | Deny, žádné uvolnění identity |
| Konflikty a metadata | Backend drift; lživý no-effect; změna po intent; lock replacement, druhý writer, root replacement, symlink/hardlink/FIFO/mode | Deny bez přepsání pozorované pozdější změny |
| Durability error | 5 file-write/flush/head hranic a chyba finálního cleanup commitu | Aktuální instance poisoned; fresh reopen přijme jen kompletní znovu flushnutý checkpoint |
| Úklid | Validované cleaned fixtures versus pending/unknown stav | Pouze explicitní flat úklid dokončené fixture; testy odstraňují vlastní syntetická data |

## Vývojové nálezy a opravy

První test fixture převzala B3 návrhové UID 450. H1 lifecycle vyžaduje nejméně 501 a správně je
odmítlo; fixtures nyní používají 750/751. První crash-driver lookup přes `CommandLine.arguments[0]`
na tomto SwiftPM ukazoval na systémový `xctest`, takže pět crash metod nemohlo spustit worker.
Lookup nyní vychází z bundle testů; následný běh skutečně prošel všech 116 ukončení a obnov.

Původní Debug ověřování opakovaně alokovalo 1 MiB a flushovalo/parsovalo nezměněné záznamy.
Čtení nyní alokuje ověřenou délku + 1, ověřuje bytes/metadata a cache uznává jen přesný receipt již
flushnutý v aktuální instanci. Regrese pro pozdější změnu dat a root identity zůstaly zelené.
Následná self-review zpřísnila `uidReusable` tak, aby stará cleaned oblast nemohla inzerovat UID,
které mezitím vlastní jiná oblast; samotný alokátor už tento konflikt odmítal.

Mezilehlý kompletní běh na `1d9917f`: 35/35 Debug (54,6 s) a 35/35 Release (43,8 s).
Na `f82fb11` prošlo 36/36 Debug (53,6 s) a 36/36 Release (48,3 s), včetně regrese inspection
proti aktuálnímu globálnímu bindingu UID. Nezávislé review následně reprodukovalo P2: stará instance
nekontrolovala vazbu named lock proti fd, takže výměna souboru mohla otevřít druhého writera.
Oprava `ba30698` přidává kontrolu identity/metadat lock při každém I/O a samostatný flock inode
adresáře. Cílených 17 StoreTests prošlo, včetně replacement/missing/symlink/hardlink/mode,
odmítnutí druhého writera a nového otevření po zániku staré instance. Finálních 37 metod zahrnuje
tuto regresi a úplné fresh-process testy znovu ověřují uvolnění/acquisition zámku po `_exit(77)`.
Malé lokální build/test logy zůstaly v `/private/tmp/sanjbox-h2-*.log`; velké vlastní scratch
adresáře `sanjbox-h2-build`, `sanjbox-h2-fast`, `sanjbox-h2-release` byly po validaci odstraněny.

Závěrečné potvrzení nezávislého review a CI jsou samostatné kontroly PR; tato poznámka jejich výsledek nepředjímá.
Provozní hranice a neimplementované nativní adaptéry jsou výslovně popsány v [README](README.md).

## Nezávislé review PR #74 — 2026-11-13

Na žádost vlastníka proběhla další nezávislá kontrola celého diffu
`6c80c8f378c8658b4d80abde061dcb32a744cb8d…98736fed0cd340e5cf8adaf5fbfd4ae2a2912048`:
zdroje, testové oracle, vazba na H1 a rozsah PLAN/IMPLEMENTATION. Po opravě named-lock bindingu
z `ba30698` nebyl nalezen další problém P0–P2; zdroje ani testy se při tomto review neměnily.
Ověřena byla rezervace před efektem, replay přechodů a auditu, fail-closed pending intent/drift,
uvolnění UID až při potvrzeném cleanup, vazba locku i meze syntetického backendu.

Na stejném macOS/Swift prostředí jako výše byly nezávisle znovu spuštěny:

| Kontrola | Výsledek |
|---|---|
| Všechny produkty Debug/Release | Sestaveny bez varování |
| XCTest Debug | **37/37**, 0 failures, 63,49 s |
| XCTest Release | **37/37**, 0 failures, 45,42 s |
| Matice obnovy v každém sestavení | **116** skutečných ukončení workeru přes **24** kroků a fresh-store recovery; všech **9** H1 bodů a cross-zone LC-06/LC-11 scénáře |
| Repo `tools/tests` | **94/94**, 38,74 s; včetně CI selection, status generátoru, evidence a watchdogu |
| Generátor stavu nad upravenou dokumentací | **24/63** hotových balíků, **0/155** prošlých akceptací; F1 **19/6/11** |
| Kontrola dokumentace | Lokální odkazy existují; vlastníci a všechny ostatní řádky balíků, požadavky, brány a akceptační případy beze změny; `git diff --check` prošel |

```sh
swift build --package-path proto/lifecycle --scratch-path /private/tmp/sanjbox-pr74-review-build -c debug
swift test --package-path proto/lifecycle --scratch-path /private/tmp/sanjbox-pr74-review-build -c debug
swift build --package-path proto/lifecycle --scratch-path /private/tmp/sanjbox-pr74-review-build -c release
swift test --package-path proto/lifecycle --scratch-path /private/tmp/sanjbox-pr74-review-build -c release
python3 -B -m unittest discover -s tools/tests -v
python3 -I -B tools/progress.py --out /private/tmp/sanjbox-pr74-review-progress --history-ref origin/main --repository Fir3st/sanjbox
git diff --check
```

První lokální sandboxové pokusy nebyly platným výsledkem těchto sad: Swift nemohl zapsat module
cache, Python `-I` vyloučil repo import `tools` a sandbox zakázal watchdogu `/bin/ps`. Výsledky v tabulce
pocházejí z následného úplného běhu se správným importem a běžnými oprávněními, bez změny zdrojů.

Dokumentační follow-up opravuje souhrn COVERAGE a [IMPLEMENTATION §0](../../docs/IMPLEMENTATION.md#0-co-dál):
H2 je dokončený offline balík, H3 první volná práce a H6 paralelní možnost; H4/A2/A3/A6 zachovávají
vlastníky. H3 dostává konkrétní H1 wire/reply kontroly, H6 úplný katalog 155 případů. Provozní důkazy
admission, whole-UID a crash/reboot zůstávají v S0/S4/labu, produkční integrace ve WP2.2 po vstupu F2.
Toto review ani zelené testy neuzavírají žádnou bránu; konečný CI a merge ověřuje vlastník PR.
