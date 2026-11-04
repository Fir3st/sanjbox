# WP1.A4 validation (vývojové testy, nikoli S0 evidence)

Vývoj ověřen 2026-11-03 na arm64, macOS 27.2 build `26B123`, Swift 6.4
(`swiftlang-6.4.0.34.1`, clang `2100.3.34.1`), Xcode 27.0 build `27A266a`.
Základ větve je `main` commit `547f3c1e630cdd95662b9a9f339a22f7a1c47026`; jediná závislost je
jeho `spikes/common`. Žádné implementace otevřených PR, externí balíčky nebo instalace se nepoužily.

## Příkazy

Z kořene repozitáře, nový scratch/cache/module-cache mimo tracked strom pro každého autora/běh:

```bash
a4_build=$(mktemp -d /private/tmp/sanjbox-a4-build.XXXXXXXX)
export CLANG_MODULE_CACHE_PATH="$a4_build/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$a4_build/modules"
swift test --build-system native --configuration release \
  --package-path spikes/s0-boundary --scratch-path "$a4_build/scratch" \
  --cache-path "$a4_build/cache" --disable-sandbox \
  -Xswiftc -module-cache-path -Xswiftc "$a4_build/modules"
```

`--disable-sandbox` zde vypíná SwiftPM build sandbox, nikoli vnější Codex sandbox. Test skutečných
vlastních loopback socketů vyžaduje prostředí, které bind/connect na `127.0.0.1` umožní; v omezeném
prostředí má test selhat. Selhání se neskipuje a netvrdí síťovou izolaci. Není potřeba root, pf, změna
systémových oprávnění ani přístup do sítě mimo tento vlastní loopback. Swift 6.4 upozorňuje na budoucí
odstranění `--build-system native`; aktuální použitá verze jej podporuje. Testy lze provozovat i v Debug,
ale takto vytvořená CLI se nepoužívají jako aktivní sondy bez finálního přepodepsání.

Přesný finální debug příkaz použitý implementátorem (2026-11-03 18:45:11–13 CET):

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/sanjbox-a4-clang-6bc17c98 \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/sanjbox-a4-modules-6bc17c98 \
swift test --build-system native --package-path spikes/s0-boundary \
  --scratch-path /private/tmp/sanjbox-a4-native-6bc17c98 \
  --cache-path /private/tmp/sanjbox-a4-cache-6bc17c98 --disable-sandbox \
  -Xswiftc -module-cache-path -Xswiftc /private/tmp/sanjbox-a4-modules-6bc17c98
```

Výsledek: **36 XCTest, 0 failures, 0 skips** (24 `BoundaryTests` + 12 `FixtureTests`). Paralelní
Swift Testing hlášení „0 tests“ není počet XCTest a není použito jako důkaz. Unit testy injektují
syntetický identity/signature context do interních funkcí; produkční CLI tuto možnost nemá. Skutečné
file/XPC/TCP/child testy pracují pouze se svými objekty. Bez L1/L2 neověřují oddělení relací/UID.

## Co testy kontrolují

| Oblast | Kontroly |
|---|---|
| Identity a pořadí | Úplná pozitivní identita; každé real/effective UID/GID, ASID/auditUID, manager/window pole; extra/missing/duplicate/unresolved groups; missing session; explicitní null window; každá sonda bez interakce při neshodě. |
| Vstupy | Každé chybějící top-level pole, unknown keys, duplicate/escaped/nested keys, root/invalid ASID/scope, conflicting groups, limit velikosti/hloubky/čísel/Unicode, trailing JSON; odmítnuté path/PID/service/duplicitní CLI flags. |
| Vykonávání | Všech sedm dry-runů bez capture/interakce; malformed expectation před capture; pozitivní kontrola přesně jedné operace; signature prerequisite blokuje všechny čtyři aktivní fixture backendy; TCC/capture vracejí 5. |
| Podpis | Čistý metadata evaluator: runtime, oba spellings get-task-allow včetně `false`, raw entitlements bez decoded dictionary a malformed dictionary. Jde o unit mock signing metadat, ne TCC persistence. |
| XPC | Skutečný vlastní anonymní round trip pozitivní/negativní/pozitivní; zvlášť bounded mock authorization a nulový únik canary při odmítnutí. |
| TCP | Skutečný vlastní loopback round trip, přesný canary a ACK. Žádný cross-UID negativní síťový test. |
| Child | Skutečný fixed child, přesný stdin/stdout, úspěšný waitpid; příliš velký vstup odmítnut. DFL/IGN/SA_NOCLDWAIT/custom-handler matrix; interní held-stdin fault skutečně vyvolá 2s timeout, TERM a reap (následné ECHILD). Nejde o celý UID nebo crash/fork lifecycle gate. |
| File fixture | Skutečné permission denial s před/po pozitivním fresh-open control; idempotentní cleanup; mode/content/GID/immutable flag/ACL změny detekované před unlink; hardlink/symlink/FIFO; directory mode change; rename-out odmítnut a již unlinked soubor přijat. |

GID test může na jiném účtu bez druhé doplňkové skupiny hlásit explicitní `XCTSkip`; při tomto běhu
nebyl skip. Takový odlišný běh musí uvést skutečný počet, nesmí převzít „0 skips“ z tohoto stroje.
Teardown ACL/GID/flags nyní assertuje obnovu a cleanup, nepoužívá tiché `try?`.

## Zachované neúspěchy a opravy

1. První sestavení narazilo na nepřístupný implicitní user module cache; opraveno explicitními
   `CLANG_MODULE_CACHE_PATH` a `SWIFTPM_MODULECACHE_OVERRIDE`. Následně opraveny compile chyby C/Swift
   interop (ACL raw pointer/enum, přejmenované Security OptionSet členy, `strdup` type inference).
2. První dokončený XCTest běh v omezeném sandboxu (18:34:27 CET): **34 tests, 13 failures**. TCP bind
   nebyl povolený. Všech 12 file testů odmítlo init, protože Darwin při absenci extended ACL vrací
   `ENOENT`, nikoli prázdný ACL objekt. Ověřeno na zvláštní vlastní UUID diagnostické fixture; getter
   přijímá `ENOENT` jen při práci s již otevřeným vlastním fd, ostatní chyby zůstávají konfliktem.
   Tento běh zanechal 12 prázdných UUID adresářů. Nešlo o důkaz ochrany dat ani úspěšný cleanup.
3. Po opravě getteru a povolení vlastního loopbacku testy hlásily **34/34**, ale samostatná kontrola
   residuí odhalila chybu GID test teardown. Darwin zdědil group `wheel` z `/private/tmp`; testující
   uživatel směl group změnit na svou supplementary group, ale ne zpět na `wheel`. Tiché cleanup
   chyby byly odstraněné. Nový vlastní fixture adresář nyní dostává effectiveGID před baseline;
   test assertuje návrat i cleanup. Tento druhý běh ponechal jednu přesně určenou dvousouborovou fixture.
4. Nezávislý root reviewer ověřil původ těchto **13 konkrétních UUID** podle jediného test produceru,
   počtu/inodů/časového okna a známého obsahu. Uklidil je pouze přes pinned fd, vlastnictví, mode/GID,
   flags, no-ACL a empty/content kontroly; dva známé soubory se ověřily na přesné syntetické bajty.
   Neproběhlo prefixové nebo rekurzivní mazání, žádné jiné objekty se nezměnily. Absence všech 13 byla
   nezávisle ověřena. Jde o jednorázový opravený vývojový incident, ne podporovaný crash-cleanup nástroj.
5. Běh po opravě teardown: **34 tests, 0 failures, 0 skips**. Starší výsledky výše se nevymazávají
   ani nepřeklasifikují jako pass. Review také opravilo předdelete kontrolu GID/flags/ACL, odlišení
   přesunu od smazání a raw-PID race: fixed child nyní vlastní `posix_spawn` + výhradní `waitpid`.
6. Finální review navíc vyžadovalo před spawn odmítnout inherited `SIGCHLD=SIG_IGN`, custom handler
   nebo `SA_NOCLDWAIT`, protože auto-reaping by zrušilo vlastnictví PID. Přidána fail-closed kontrola
   bez změny globálního stavu, čistý evaluátor a skutečná vlastní fault fixture držící stdin otevřený.
   Nový Debug běh: **36 tests, 0 failures, 0 skips**; timeout/TERM/reap test trval 2.016 s. **KILL fallback
   tím není otestovaný** (cat ukončí TERM). Žádný CLI fault/bypass parametr nebyl přidán.

## Finální binárky a CLI smoke [implementátor]

Release test/build sám nemusí vložit runtime flag. Následující lokální sealing smí cílit **jen na
sedm vlastních binárek v právě vytvořeném scratch adresáři**, po posledním buildu. Ad-hoc identita `-`
nevyžaduje Keychain; nevytváří dlouhodobou TCC identitu. Rebuild tento profil může zrušit.

```bash
a4_bin=$(swift build --build-system native --configuration release \
  --package-path spikes/s0-boundary --scratch-path "$a4_build/scratch" \
  --cache-path "$a4_build/cache" --disable-sandbox --show-bin-path)
cat > "$a4_build/empty-entitlements.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict/></plist>
PLIST
for a4_probe in xpc tcc capture host-read ingress signing lifecycle; do
  /usr/bin/codesign --force --sign - --options runtime --timestamp=none \
    --entitlements "$a4_build/empty-entitlements.plist" "$a4_bin/$a4_probe-probe"
  /usr/bin/codesign --verify --strict "$a4_bin/$a4_probe-probe"
  "$a4_bin/$a4_probe-probe" --dry-run
done
```

Nechat metadata expectation ručně nezávisle zkontrolovat podle README. Teprve poté explicitní
`--apply --expect-json '<úplný JSON>'` pro jednotlivé self fixtures. Čeká se fixture výsledek
(u signing vlastní profil), případně kód 5 u TCC/capture. `acceptanceEvidence` musí zůstat `false`.
Neshoda identity nebo nevyhovující signature profil je kód 3 před fixture interakcí. Malformed `{}`
je rovněž kód 3; dry-run všech sedmi je 0. Nikdy nedoplňovat automatický capture-and-approve wrapper.

Před posledním SIGCHLD doplněním nezávislý root reviewer sestavil zdroj s `--configuration release` v odděleném
`/private/tmp/sanjbox-a4-root-release-*` scratch/cache a ověřil **34 XCTest, 0 failures, 0 skips**.
Příkaz odpovídal výše uvedenému native Release postupu; zaznamenané upozornění bylo deprecation
native backendu. Následný ad-hoc runtime seal všech sedmi vlastních CLI a první smoke měl **28/28**
očekávaných výsledků (pět aktivních fixture pass, dvě unavailable; všech sedm dry-run/malformed/wrong-ASID).
Tyto starší vývojové výsledky zůstávají zachované; nejsou L2 evidence. Žádné metody TCC/capture, osobní
clipboard, globální XPC
lookup, host data, živé DB, login item, cron, launchctl bootstrap nebo root změny se v těchto testech
nevolají. Žádná brána ani akceptační řádek COVERAGE se nemění.


## Finální nezávislé review po SIGCHLD opravě

Root reviewer na finálním runtime zdroji zopakoval native Release v odděleném scratch/cache:
**36 XCTest, 0 failures, 0 skips**. Skutečný timeout test trval 2.020 s a doložil TERM/reap + ECHILD;
**KILL fallback zůstává nevyvolaný a neověřený testem**. Poslední sestavení následovalo nové ad-hoc
runtime zapečetění všech sedmi vlastních CLI s prázdnými entitlements. Pak už žádný rebuild těchto
binárek neproběhl. Jediné build upozornění bylo deprecation native backendu.

Explicitní vlastní metadata expectation byla zkontrolována pro `synthetic-self-fixture` (nikoli
schválená host oblast). Finální CLI smoke měl **37/37 očekávaných výsledků**:

| Kontrola | Počet | Výsledek |
|---|---|---|
| Každá sonda dry-run | 7 | `dryRun`, kód 0 |
| Malformed expectation | 7 | `invalidMeasurement`, kód 3 |
| Přesný jiný auditSessionID | 7 | `invalidMeasurement`, kód 3 |
| Aktivní file/XPC/TCP/child a self-signing profil | 5 | `fixturePassed`, kód 0; vždy `acceptanceEvidence: false` |
| Aktivní TCC/capture | 2 | `notImplemented`, kód 5 |
| Inherited `SIGCHLD=SIG_IGN` v oddělených CLI procesech | 7 | `invalidMeasurement`, kód 3; disposition rodiče beze změny |
| Vlastní kopie signing CLI s ad-hoc podpisem bez runtime a s prázdnými entitlements | 1 | `fixtureFailed`, kód 1 |
| Vlastní kopie host-read CLI se stejným nevyhovujícím profilem | 1 | `invalidMeasurement`, kód 3 před file fixture |

V tomto smoke se nikdy nevytvořila binárka s get-task-allow; nevyhovující profil byl pouze absence
runtime na vlastní ad-hoc kopii. Stav vlastních A4 fixture adresářů byl před i po finálním běhu
prázdný. Starší root Release/28-case smoke výše zůstaly oddělené a nepřepsané. Do `docs/evidence`
nebyl přidán laboratorní důkaz. Fresh review uzavřelo nalezené P2; zbývající lab mezery v README
jsou záměrně zachované, WP1.A4 je stále partial a S0/S8 zůstávají Neověřeno.
