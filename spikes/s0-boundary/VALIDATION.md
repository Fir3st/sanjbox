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

## XPC follow-up — implementátor, 2026-11-04 (samostatná větev)

Základ `main` je `afae1ca7dfe78f03d5006c42b6b01093772eba0c`, claim commit
`511ac5e`; větev `codex/wp1.a4-xpc-fixtures`. Žádné závislosti na otevřených PR nebo nové balíčky.
Stejný arm64 stroj, macOS 27.2 `26B123`, Swift 6.4 `swiftlang-6.4.0.34.1` / clang
`2100.3.34.1`. Tento oddíl nepřepisuje předchozí vývojové výsledky ani žádné `docs/evidence`.

Finální native Release XCTest skončily **2026-11-04 23:42:11 CET: 42 testů, 0 failures, 0 skips**
(23 BoundaryTests, 12 FixtureTests, 7 XPCFixtureTests). Dvě staré XPC mock/in-process testy byly
nahrazeny skutečným podepsaným cross-process runnerem; přibyly přísné XPC preregistration/policy,
claim/run/operation rejection, terminal cancellation, deadline a queued-late-reply regrese.
Původní XCTest/CLI počty výše platí pro jejich zaznamenané starší zdroje.

Přesný vrchní příkaz (self metadata bylo předem samostatně zkontrolováno, není schválená oblast):

```bash
python3 spikes/s0-boundary/validate-xpc.py --apply --expect-json '{"schemaVersion":1,"scope":"synthetic-self-fixture","realUID":501,"effectiveUID":501,"realGID":20,"effectiveGID":20,"kernelGroups":[20,12,61,79,80,81,98,701,33,100,204,250,395,398,399,400],"forbiddenGroups":[],"auditSessionID":100002,"auditUID":501,"launchdManagerName":"Aqua","launchdManagerUID":501,"window":{"userID":501,"auditSessionID":100002,"onConsole":true,"loginDone":true}}'
```

Runner použil `/private/tmp/sanjbox-a4-xpc-validation-7llvvsdo` a uvnitř přesně:

```text
/usr/bin/swift test --build-system native --configuration release \
  --package-path <repo>/spikes/s0-boundary \
  --scratch-path <root>/build --cache-path <root>/cache --disable-sandbox \
  -Xswiftc -module-cache-path -Xswiftc <root>/modules
```

`CLANG_MODULE_CACHE_PATH=<root>/clang`, `SWIFTPM_MODULECACHE_OVERRIDE=<root>/modules`.
Poslední build předcházel každému ad-hoc runtime seal (empty entitlements), strict verify a živému běhu.
Žádný Debug nebo get-task-allow executable se jako aktivní sonda nepoužil. Jediné build upozornění
byla deprecation native SwiftPM backendu. Python `-O` se výslovně odmítá ještě před přípravou fixture.

**Skutečná živá matice: 6/6 očekávaných výsledků, 0 skips.**

| Případ | Skutečné zjištění serveru | Klient / úklid |
|---|---|---|
| positive-denials-positive | 2 canary operace; `hello` + 4 zakázané requesty odmítnuty | kód 0, NOTE_EXIT, reap, bundle odstraněný |
| wrong-signature | OS nepustil žádnou metodu po přesné cdhash podmínce; 0 authenticated messages, 0 operací | kód 3, NOTE_EXIT, reap, bundle odstraněný |
| wrong-peer-session | Skutečný connection ASID neshodný s přesnou sealed policy; connection odmítnuta, 0 authenticated messages/operací | kód 3, NOTE_EXIT, reap, bundle odstraněný |
| cross-run | Podepsaný správný peer, cizí run ID; 0 operací | kód 3, NOTE_EXIT, reap, bundle odstraněný |
| deadline | Autorizovaná fixed wait fixture bez odpovědi; absolutní 2s deadline, 0 operací | kód 3, watchdog exit pozorován, reap, bundle odstraněný |
| cancel-client | Vlastní Popen klient ukončen TERM až po server `replyWithheld`; 0 operací | exit -15, služba ukončená launchd, NOTE_EXIT, reap, bundle odstraněný |

`wrong-peer-session` je **neshodná politika stejné živé session**, nikoli reálné cross-session měření.
`wrong-signature` používá přesnou neodpovídající code-hash requirement; žádná binárka s oslabeným
runtime/get-task-allow nevzniká. Neznámý plný peer audit token/auditUID zůstává unsupported. Všechna
JSON hlášení mají `acceptanceEvidence: false`; chybové kódy jsou invalid measurement, samy nedokazují izolaci.

Po finálním běhu se Swift runtime nezměnil. Python receipt dostal kontrolu file flags a guard proti
`-O`: ověřen dry-run, očekávané odmítnutí `python3 -O`, a dodatečný podepsaný positive/denial live případ
v `/private/tmp/sanjbox-a4-xpc-final-receipt-tmdvafcl` (2 operace, všechny cleanup oracles passed).
[Neměnné server records/preregistrace, test log, výsledky a manifest](validation/20261104T224211Z-local-xpc/README.md)
obsahují hlavní i tento dodatečný běh. Příjemce nezávisle zapisuje journal; nevěří výsledku klienta.

### Zachované vývojové neúspěchy a mezivýsledky

- První kompilace opravila skutečné SDK názvy ASID/Security flagů a `Never` návrat service entry pointu.
  Žádný živý service při compile failure neběžel.
- První tři bundle pokusy dostaly klientské NSCocoaErrorDomain 4097. Třetí doplněný vlastní diagnostic
  doložil `serviceIdentityRejected` pro ASID/auditUID/window: `JoinExistingSession` má dle macOS man
  výchozí false. Nebyl to denial oracle hranice. Čtvrtý pokus s explicitním true skutečně provedl
  2 operace a 4 denials, ale nebyl finálním plně sealed app měřením.
- Scratch `9yoio6kl`: **41/41 Release**; runner skončil před živým testem na codesign kvůli ještě
  nekompletnímu nested service bundle. Oprava pořadí: seal služby, seal celé app, poté exact hash policy
  v soukromém sibling Control. Klient nyní validuje také celý nested app seal.
- Scratch `k0uf19y7`: **41/41 Release**, pozitivní live case prošel. U wrong-signature skutečný
  NOTE_EXIT přišel bez self `serviceExit`: launchd při zániku klienta může službu ukončit dříve než
  watchdog. Původní oracle vyžadující poslední textový záznam byl příliš silný; nešlo o únik operace.
- Scratch `72_5m8q_`: **41/41 Release**, pozitivní i signature case prošly. Wrong-session služba skončila
  dřív než externí watch registrace (ESRCH); neplatný cleanup observer, nikoli pass. Opraveno bounded
  readiness handoff před activate listeneru, žádný race se neřeší holým PID kill/podpisovou kontrolou.
- Scratch `5hcng33p`: **41/41 Release + 6/6 live**, bez skips. Následně zpevněna atomická publikace
  readiness markeru a přidán malformed preregistration XCTest. Finální nový běh výše má 42/42 + 6/6.

Staré raw lokální soubory zůstaly zachované při odstranění vlastních build/cache a spotřebovaných
fixture kopií; nikdy se nepřeklasifikují jako finální pass. Všech šest finálních živých service exits
bylo nezávisle pozorováno, klienti reaped a fixture objekty po kontrole odstraněné. Žádný globální
service scan, TCC/capture/Keychain/database přístup, systémová registrace, privilegovaný krok ani změna
jiného balíku neproběhla. Zůstává to vývojová příprava, ne gate evidence.

## Nezávislé review HEAD 0c084afe — opravy klasifikace a diagnostiky (2026-11-04)

Fresh Astra review přesného `0c084afe24fab03b537106b17a2255883116f969` našlo dvě platné P2:
(1) non-denial odpověď na zakázaný XPC request po fungující pozitivní kontrole končila jako
invalid measurement a následná exit-observer chyba mohla původní nález přepsat;
(2) runner při chybě před `communicate` neuložil skutečné stdout/stderr/context ani dostupný raw journal.
Staré `validation/20261104T224211Z-local-xpc` a všechny předchozí výsledky zůstaly beze změny.

Oprava (1) přidává úzký `XPCObservedFailure`: CLI vždy vrací `fixtureFailed`/exit **1**, zachová
primární nález a samostatný `cleanupError`/`serviceExitObserved`. Není to gate verdikt a
`acceptanceEvidence` zůstává false. Nadlimitní přijatá odpověď se uchová jen jako bounded prefix pro
rozpoznání non-denial; nepromění se v nejasnou transportní chybu. Čtyři nové Swift regrese používají
injektovanou syntetickou protistranu: fungující canary control → neoprávněná odpověď, zdravý i selhávající
exit observer, oversized odpověď a chybějící pozitivní control. Kontrolují CLI status/exit, okamžité
zastavení dalších operací a zachování sekundární chyby. Nejde o nově povolenou wire/CLI fault operaci.

Oprava (2) průběžně drainuje oba pipes, v povinné finalizaci reaps vlastní child a před hlášením chyby
uloží bounded stdout/stderr, dostupný journal a outcome s primary/secondary chybami a skutečným
exit/reap/cleanup stavem. Dvanáct deterministických Python testů ověřilo self-gate/no-service případ,
failed NOTE_EXIT registraci, malformed/oversized journal, chybějící exit, cleanup conflict, sekundární
reap/drain chyby, limity streamů, nezávislost zápisu jednotlivých raw souborů i zdravou cestu. Používají
výhradně fake child/capture a nové syntetické soubory, žádný skutečný PID nebo XPC.

### Nový kompletní běh

Root `/private/tmp/sanjbox-a4-xpc-validation-jltgeiar`; stejný výše uvedený explicitní self expectation
(UID 501, ASID 100002, Aqua, stejné groups/window), stejný top-level příkaz `python3 .../validate-xpc.py
--apply --expect-json '<JSON výše>'`. Systém macOS 27.2 `26B123`, arm64, Swift 6.4. Žádná externí
závislost. Native Release test/build/cache příkazy jsou stejné jako v předchozím oddílu s tímto novým
rootem. Každý živý bundle je po buildu znovu runtime podepsaný, empty entitlements a strict verify.

- **46 Release XCTest, 0 failures, 0 skips**, konec 2026-11-04 23:58:36 CET (27 BoundaryTests +
  12 FixtureTests + 7 XPCFixtureTests). Původních 42 testů zůstalo funkčních, 4 nové výše.
- **12 Python runner testů, 0 failures/skips**, přesný příkaz:
  `python3 -m unittest discover -s spikes/s0-boundary/Tests/RunnerTests -v`.
- **Původní 6/6 signed cross-process XPC případů prošlo**: 2 skutečné operace pouze v pozitivním
  případě, nula operací v signature/session/cross-run/deadline/cancellation případech. Všech 6 service
  exits skutečně pozorováno, všichni klienti reaped, všechny fixture bundles odstraněny.
- **1 nový signed identity-mismatch případ prošel jako negativní control**: klient dostal ASID 100003,
  zachovaný report obsahuje skutečné ASID 100002 a přesnou neshodu, kód 3, žádná aktivovaná služba,
  journal ani marker; klient reaped a neaktivovaná fixture po kontrole odstraněná.

### Přesná reprodukce původní ztráty diagnostiky

V odděleném `/private/tmp/sanjbox-a4-xpc-rejection-repro-u21kbspf` byl normální pozitivní runner case
spuštěn se záměrně nesprávným očekávaným ASID 100003. Stejné finální Release binárky byly znovu
podepsány. **Očekávaný RunnerFailure nastal**, ale před ním už existovaly client JSON se skutečnou
identitou a mismatch, stderr, prázdný raw journal s `journalPresent: false` a outcome: primární
`client exited before service activation`, exit 3, `clientReaped: true`, `cleanupState: retained`.
Fixture byla v okamžiku chyby prokazatelně zachovaná. Po samostatné kontrole této očekávané self-gate
chyby (žádná aktivace služby) byla vlastní nezměněná fixture odstraněna; záznam tohoto následného
úklidu je samostatný a původní failure outcome se nepřepsal. Reprodukce není pass XPC hranice.

[Nové neměnné raw/outcome/preregistration/test logy, source hashe a manifest](validation/20261104T225836Z-review-fixes/README.md)
zachovávají hlavní běh i tuto očekávanou chybu. Starý manifest byl znovu ověřen beze změn. V tomto
opravném běhu nenastal další build/test fail; žádný test nebyl skipnutý. Vlastní build/cache byly po
zaznamenání validace odstraněny, lokální raw zůstaly. S0/S8 a WP1.A4 coverage stav se nemění: partial,
bez full peer auditUID/token, bez cross-session důkazu, bez systémových/privilegovaných změn.


## Příprava všech 31 případů (2026-11-08)

Dokumentační změna podle IMPLEMENTATION §0 / GUIDE §11; kód testován na
`b3bb8f8b21fcba3e85702f5d2eaf4fa2b6ec76a2` (claim nad `7b20c414`, beze změny zdrojů).
[LAB-PLAN](LAB-PLAN.md) a karty FS/ID/LC v tomto commitu mají 31 unikátních ID a 31 indexových
řádků shodných s přesným rozsahem COVERAGE; u každého je kontrola, oracle, blokátor a úklid.
Ověřeno 60 lokálních odkazů včetně fragmentů a všech 68 starých sealed souborů byte-for-byte
proti základnímu commitu; historické záznamy výše zůstávají beze změn.

- `python3 -B -m unittest discover -s spikes/s0-boundary/Tests/RunnerTests -v`: **12/12**, bez skips.
- `/usr/bin/python3 -I -B -m unittest discover -s spikes/s0-boundary/Tests/RunnerTests -v`:
  **12/12** i na systémovém Pythonu 3.9.6 používaném macOS CI.
- `python3 -B -m unittest discover -s tools/tests -v`: **63/63**, bez skips (Python 3.15.2).
- `python3 -B spikes/s0-boundary/validate-xpc.py`: výchozí dry-run, žádná aktivace XPC.
- CLI syntax ověřena proti parserům a instalovaným man stránkám (`open`, `launchctl`, `ps`,
  `mdfind`, `log`, `dscl`, cron/at); 21 jmen API proti hlavičkám aktivního macOS SDK, nikoli
  živým voláním. `log help show` sandbox odmítl; syntax ověřena z `log(1)`, žádné logy se nečetly.
  `git diff --check` prošel; žádný nový Swift build, protože se kód nezměnil.

macOS 27.2 / 26B123, arm64. Žádný L2, TCC/capture/attach, změna účtů, podpisových identit,
Keychain, systémových nastavení, mountů nebo registrací. Příprava scénářů nedokazuje jejich
spustitelnost ani izolaci; chybějící komponenty zůstávají stop podmínky, FS-04/08/LC-11 patří
k S4/S8/F2. Žádný nový offline evidence balík; stávající CI pokrývá použité testové sady.


## Review oprava FS-09 / ID-07 (2026-11-08)

Dvě P2 nad `dcd8282e57a85ace64de4b1521c7ec10edf6c70f`: neurčené metadata fixtures a prázdná
service inventura. FS-09 nyní fixuje všech sedm zdrojů/selektorů/polí, včetně inertního app bundle
a vlastní USB descriptor fixture; široké system_profiler/netstat CLI zůstávají STOP. ID-07 má
konkrétní MDQuery a NSWorkspace lookup, rozlišuje system/per-user scope i neprokázanou runtime trasu.
LS registrace čeká na konkrétní cleanup disposable lab baseline; smazání app není unregister.

Targeted audit opravných dokumentů: **31/31** ID + index, **62** lokálních odkazů/anchorů,
Markdown tabulky, **33** SDK deklarací/konstant a **4** statické Apple plisty. Primární opory:
aktivní SDK `MDQuery.h`, `MDItem.h`, `NSWorkspace.h`, `LSInfo.h`, `IOKitLib.h`, `IOKitKeys.h`,
`IOUSBHostFamilyDefinitions.h`, `DirServicesConst.h`, `os/log.h`; instalované man stránky
system_profiler/ioreg/mds/lsd/netstat/log/dscl/ps/mdfind a připojené Apple API odkazy v kartách.
Kontrolována jen dokumentace/hlavičky a statické deklarace, žádné cílové API, systémový report,
registrace nebo příprava fixture se nespouštěly. Všech 68 sealed souborů, starý text VALIDATION
a root COVERAGE zůstaly beze změn; `git diff --check` prošel. Kód se nezměnil, 12 + 63 testů
z předchozí poznámky se bez nového důvodu neopakovalo; žádný nový build či evidence balík.


## Nezávislé review PR #62 (2026-11-13)

Review nad `b1b89ff` porovnalo všechny karty s PLAN, COVERAGE a podmínkou IMPLEMENTATION §0.
Opraveny dvě věcné mezery: FS-03 nově zahrnuje `/private/var/tmp` a společně s FS-06 samostatné
unlink/rename-replace pokusy (FS-03 i rmdir), protože zákaz přímého zápisu nevylučuje mutaci přes
rodičovské `delete_child`; společný preflight a ID-06 nyní vyžadují `sanjbox-whoami --expect`
s konkrétními required/forbidden groups, protože samotný výpis bez argumentů členství nezjišťuje.
Ruční porovnání přesných kernel groups, pozitivního ASID/auditUID a session profilu zůstává povinné.

Všech 31 případů má konkrétní operaci a oracle včetně předpokladů, controls, výstupu a úklidu;
chybějící nástroj či mechanismus je výslovný stop. Tím je splněna **přípravná** podmínka A4:
COVERAGE označuje A4 ✅ podle GUIDE §11, s odpovídajícím součtem F1. Nejde o splnění mechanismů,
provedení případů nebo verdikt S0; všechny testové a gate stavy zůstávají beze změny.

- Runner regresní sada: **12/12** na Pythonu 3.11.4 a znovu **12/12** na systémovém Pythonu 3.9.6,
  bez skips; stejné příkazy jako v předchozí přípravě.
- `python3 -B -m unittest discover -s tools/tests -v`: **63/63**, bez skips.
- `python3 -B spikes/s0-boundary/validate-xpc.py`: výchozí dry-run, žádné `--apply`.
- Dokumentační audit: **31/31** karet i indexových řádků, **108** lokálních odkazů/anchorů ve všech
  osmi souborech PR; všech **155** akceptačních stavů nezměněno. Součet F1 odpovídá detailním řádkům
  načteným stávajícím `tools/progress.py`; A4 poznámka má dvě věty a odkazy.
- Všech **68** sealed souborů byte-for-byte shodných se základem `7b20c414`; původní prefix
  VALIDATION, `docs/evidence`, PLAN, GUIDE, IMPLEMENTATION, gate index a zdrojový kód beze změn.
  Ověřeny zdroje common identity collector/parseru, lokální `ioreg(8)` a `MDQuery.h`; všech sedm
  odkazovaných Apple dokumentačních URL je dostupných (část webových API stránek vyžaduje JS).
  `git diff --check` prošel; Swift build se u této dokumentační změny neopakoval.

Prostředí: macOS **27.2.1 / 26B131**, arm64. Testovaný zdrojový kód zůstává shodný s `b1b89ff`.
Žádná uvedená souborová mutace, globální dotaz, capture/TCC/attach, registrace nebo privilegovaný
krok nebyl při review spuštěn. Navazující L2 po S1 a závislosti FS-04/08/LC-11 na S4/S8/F2 trvají;
review nepřepisuje historické výsledky ani nevytváří laboratorní důkaz.
