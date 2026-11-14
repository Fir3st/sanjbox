# WP1.A6 — vývojová validace, 2026-11-03

Toto je přezkoumatelná poznámka o přípravě, **nikoli uzavřený protokol S8/L2**. Všechny brány a
155 případů v COVERAGE zůstávají Neověřeno. A6 zůstává částečné; chybějící výstupy uvádí README.
Žádné původní `docs/evidence` nebyly změněny. Raw identity se nepublikují; lokální výstupy jsou
vlastní syntetické logy v `/private/tmp/s8-a6-*`, žádné skutečné účty/služby/TCC nebyly testovány.

## Přesný zdroj a prostředí

- Východisko `main`: `547f3c1e630cdd95662b9a9f339a22f7a1c47026`.
- Převzetí A6: `0f7ce02`; pracovní větev `codex/wp1.a6-signing-preparation`.
- [SOURCES.sha256](SOURCES.sha256) pinne Package.swift, všech sedm Swift source souborů a testy.
  Hash samotného seznamu: `5a31c2b56c4a64f7ff175fe6a5acaca0250abfdd0c419e0078ff7e1c1a86929d`.
  Tento seznam se týká právě této vývojové revize; budoucí změna vyžaduje nový záznam výsledků.
- Lokálně: arm64, macOS 27.2 build `26B123`, Swift 6.4 (`swiftlang-6.4.0.34.1`).
- Native SwiftPM Debug, izolované scratch/cache, žádné externí dependencies. Synchronous API
  deadline a same-UID souběžné změny zůstávají omezením podle README.

## Testy

```sh
env CLANG_MODULE_CACHE_PATH=/private/tmp/s8-a6-clang-cache \
  SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/s8-a6-swift-module-cache \
  swift test --build-system native --package-path spikes/s8-signing \
  --scratch-path /private/tmp/s8-a6-native-debug-build \
  --cache-path /private/tmp/s8-a6-swift-cache --disable-sandbox
```

**28 Swift Testing testů, 0 selhání.** XCTest wrapper hlásí 0 testů; rozhodující je následující
Swift Testing výsledek 28. Pokryté jsou úplnost/exaktnost identity a audit session, unknown group
membership, chybějící/přítomná window session včetně null round-trip, strict JSON duplicity/typy,
signature policy a malformed entitlements, role/session/capability/replay/kapacita mock brokeru,
deterministický fuzzer, šest plánů, statický plist validator, omezení souborů, hardlinks/symlinks,
změna módu/immutable flagu před úklidem, pokračování částečného úklidu a prázdný-root crash window.

Nezávislá kontrola koordinátora nad stejným zmrazeným zdrojem: **native Release 28 testů, 0 selhání**;
lokální log `/private/tmp/sanjbox-a6-root-release.log`. Native backend vypisuje deprecation warning;
nejde o warning-free build. Testy samy nepokoušejí attach, TCC, XPC ani systémovou službu.

## Podepsaná CLI smoke kontrola

Před každou CLI sérií byla vlastní scratch binárka znovu ad-hoc podepsána `--options runtime`,
`--timestamp=none` a prázdným entitlement plist. Ověřen výstup `codesign -dvv --entitlements -`:
flags `0x10002 (adhoc,runtime)`, prázdný dictionary; běhová Security self-check bez issues.
Očekávání bylo explicitně zafixováno v soukromém UUID input rootu před sérií. Jde o host diagnostiku,
nikoli o S1 testovací UID či předregistraci L2.

| Kontrola | Pozorování | Rozsah závěru |
|---|---|---|
| `mock --iterations 10000 --seed 21304` | 4 pozitivní kontroly, 10 000 negativů, 0 unexpectedAccepts, prázdné failures | Pouze toy wire/policy |
| Corpus SHA-256 | `a9d18dbb0f51df4edbbec2df5228d5907b88543e498fa147b0e0544bff4b6ef3` | Deterministická reprodukce této série |
| `experiments` | 6 plánů, exit 0 | Plány se nevykonaly |
| `prepare` dry-run | Exit 0, popis vlastních změn | Bez vytvoření fixtures |
| `prepare --apply yes` | Čtyři vlastní thin arm64 fixtures a manifest | Pouze vlastní nový temp root, žádná binárka nebyla spuštěna |
| `inspect hardened` | Exit 0, Security validity 0, flags 65538, issues prázdné | Statický fixture oracle |
| `inspect plain` | Exit 1, validity 0, flags 2, chybí runtime | Očekávaný negativní oracle |
| `inspect unsigned` | Exit 1, validity -67062, flags neznámé | Očekávaný negativní oracle |
| `inspect tampered` | Exit 1, validity -67061, flags 65538 | Očekávaný negativní oracle |
| Cleanup dry-run, apply, apply znovu | Vše exit 0; dry-run zachoval root, apply odstranil vlastní root, opakování no-op | Žádné zbylé fixtures této série |
| Úmyslně jiná očekávaná audit session | Exit 3, jediný identity report s valid false; mock se nespustil | Mismatch není důkaz izolace |

Reporty ukládají SHA-256 jednotlivých fixture bytes. Byte hashe kompilovaných Mach-O se mohou mezi
buildy lišit; jejich expected výsledky se nepřizpůsobovaly pozorování. Čtyři signing výsledky byly
zafixované před spuštěním v README. Neověřují stabilní identitu TCC, Personal Team ani self-signed.

**Nezávislý Release CLI smoke koordinátora:** stejný zdroj, vlastní ad-hoc runtime/empty-entitlement
binárka a nová fixture sada. Potvrdil všechny čtyři výše uvedené validity/flags/exity, 10 000 negativů
a čtyři kontroly se stejným corpus hashem, šest service plánů, identity-only exit 3 při chybné přesné
audit session (ještě před použitím úmyslně neplatného rootu) a cleanup dry/apply/repeat.
Lokální souhrn: `/private/tmp/sanjbox-a6-root-smoke-_wdz53hc/summary.json`. Ani tato nezávislá kontrola
není uživatelský S8/L2 experiment.

## Zachované vývojové problémy a omezení

První build selhal kvůli výchozí module cache mimo writable scratch. Následující sestavení odhalilo
chybějící public inicializátory common vnořených typů a Swift názvy Security enumů; opraveno pouze
v A6. První souborový test selhal na Foundation převodu `/private/tmp` → `/tmp`; přešlo se na POSIX
`realpath`. Pak se doplnilo zacházení s Darwin ENOENT u ACL na otevřeném vlastním fd. Všechny tyto
neúspěchy byly vývojové testy, nikoli negativní výsledky bezpečnostní brány.

**Důležité:** původní Debug build výchozím Swift 6.4 `swiftbuild` backendem vložil `get-task-allow`.
První diagnostický context a odmítnutý mock pokus s tímto buildem nejsou platná signing měření;
neproběhla TCC/attach/grant operace. Metadata to odhalila před finální smoke sérií. README nyní
požaduje preflight po každém rebuildu a CLI se sama odmítne při nesplněném signing profilu.
Finální uvedené výsledky používají výslovně znovu podepsaný native build.

První host smoke také odmítl soukromý input adresář, protože macOS dědí skupinu parentu `/private/tmp`.
Kód nyní vyžaduje vlastní UID/0700/no-ACL/no-flags a pro fixture cleanup porovnává skutečnou původní
skupinu z manifestu; nezaměňuje ji s effective GID procesu, které se nadále kontroluje přesně.

Review doplnilo explicitní null pro non-GUI expectation a ochranu před později nastavenými file
flags, plus pokračování úklidu po vlastním partial unlink a po posledním unlink před rmdir.
Tyto případy mají regresní testy; nejde o obecnou crash-atomicity či hostile TOCTOU garanci.

# WP1.A6 service-fixture follow-up — vývojová validace, 2026-11-04

Samostatné pokračování od `main` `afae1ca7dfe78f03d5006c42b6b01093772eba0c`, větev
`codex/wp1.a6-service-fixtures`, první claim commit `b3c1328`. **Původní výše uvedená historie,
SOURCES.sha256 a docs/evidence nejsou přepsány.** Starý seznam hashů je historický snapshot
2026-11-03, nikoli kontrola aktuálního HEAD. Dnešní zdrojový snapshot pinne
[SERVICE-SOURCES-20261104.sha256](SERVICE-SOURCES-20261104.sha256), SHA-256 seznamu
`72510ae7349115076b99a7499d6874a6c3f5e977289c76fff9849abebc83892b` (17 souborů: package, Swift a tools/tests).

Prostředí: arm64, macOS 27.2 `26B123`, Apple Swift 6.4 `swiftlang-6.4.0.34.1`, clang `2100.3.34.1`.
Native Release; jediná závislost lokální common. Stejné source bytes použity pro finální test a app build;
builder ukládá vlastní `source-manifest.json` včetně lokální common závislosti a odmítne změnu zdrojů
během buildu. Žádný kód common ani Contracts se nemění. Před následným user L2 znovu sestavit a připnout
nové run ID / binární hashe; ad-hoc byte hashe se mezi různými buildy mohou lišit.

## Testy a skutečně sestavený artefakt

```sh
env CLANG_MODULE_CACHE_PATH=OWN_SCRATCH/clang \
  SWIFTPM_MODULECACHE_OVERRIDE=OWN_SCRATCH/modules \
  swift test --configuration release --build-system native \
  --package-path spikes/s8-signing --scratch-path OWN_SCRATCH/build \
  --cache-path OWN_SCRATCH/cache --disable-sandbox
PYTHONDONTWRITEBYTECODE=1 python3 spikes/s8-signing/tools/test_service_fixtures.py
python3 spikes/s8-signing/tools/service-fixtures.py prepare
python3 spikes/s8-signing/tools/service-fixtures.py prepare --apply
```

- **42 Swift Testing testů, 0 failures, 0 skips** (původních 28 + 14 nových). Kontroluje oddělení
  targets/labelů, daemon/ad-hoc mutation refusal, identity/session mismatch, unknown/previous-session
  unregister, vlastní úspěšnou register→unregister policy cestu, drift statusu, pending/failed/unpaired
  completion a injektovaný počítač mutací bez ServiceManagement. Marker round-trip obsahuje common
  context a nikdy sám nevyhlásí lifecycle cause/pass. Pozitivní file writer test vytvořil dvě vlastní
  unikátní private fixtures; negativy odmítly root/cizí UID/chybějící či chybnou audit session a změněné
  run ID před zápisem. Tyto synthetic record testy nejsou spuštěním helperu ani služby.
- **15 Python unittest, 0 failures, 0 skips**: dry/apply/repeat cleanup, změna obsahu/módu/inode,
  symlink/hardlink, immutable flag, extra file, invalid prefix/UUID, duplicate manifest keys,
  unlink interního cache symlinku bez následování a event run/session/hash/inode refusal.
- **5/5 signed host CLI kontrol**: bez argumentů a `plan` exit 0; `register daemon --apply`,
  `ui --apply yes`, `status --expect /private/tmp/unscoped.json` exit 2 ještě před service API.
  Neotevřelo se UI, nečetl se service status a žádný helper neběžel.
- Všechny čtyři executable targets se skutečně zkompilovaly a byly vloženy do úplného app bundle.
  `verify` opakovaně prošel: thin arm64 Mach-O, přesné oddělené plisty/BundleProgram, shodné sealed run ID,
  `codesign --verify --strict --all-architectures`, flags `0x10002 (adhoc,runtime)` a prázdné entitlements
  pro app, nested LoginItem, agent a daemon. Žádný `get-task-allow`.
- Nezávislý koordinátor nad stejným artefaktem znovu ověřil všechny čtyři podpisy/flags/entitlements
  a přesné agent/daemon plist key sets, labels a BundleProgram. Ani tento krok nespustil kód/službu/SM API.

Finální vlastní run ID: `A5154F1B-8F56-48F7-A36A-678C21D00D2F`.

| Executable | SHA-256 finálního ad-hoc artefaktu |
|---|---|
| S8ServiceHost | `c02ce46e3855900f9d4a76099cfa0eb926a9f596eb430b71604e27d4b3bfed70` |
| S8LoginItem | `b169cc7e8334cfc6160b2d866438d5e00424a43d95a46fa2be34043f912d6ae5` |
| S8LaunchAgent | `9fefff9579f653d07e64a1ad685d5d1146ae54b1b5c7e64fc650a5ccb183b751` |
| S8LaunchDaemon | `77c5e8bd6c8126823e4d7d9a5f06a3ecd4ce78725602ce4696ee3e96c62de30a` |

## Vývojové neúspěchy, úklid a limity

První compile odhalil kolizi názvu tlačítka `preview` s metodou, opraveno explicitním `self.preview()`.
Přidaná enclosing-bundle kontrola pak odhalila odlišné Swift názvy Security flags v SDK; použity
lokální SDK konstanty stejně jako původní S8 validator. Tyto neúspěšné buildy nebyly experimenty
brány. Native backend stále vypisuje deprecation warning; raný sandbox build rovněž uvedl
nedostupnost user-level SwiftPM cache (používal vlastní izolované cesty). Není to warning-free build.
Jedna dodatečná verify invokace použila omylem repo-relative script path z podadresáře a nic nespustila;
opakovaná správná verify i cleanup dry-run prošly.

Vlastní scratch/cache `/private/tmp/s8-a6-service-dev-98A72F31` a všechny mezilehlé
`/private/tmp/sanjbox-s8-services-{749F2E81…,7F3EB47D…,3B57FDBC…}` byly odstraněny po ověření vlastní
inventury. Finální build cache se odstranily až po úplné kontrole původního manifestu; zachované app
bytes byly znovu porovnány s původní inventurou, manifest pro zbylé vlastní artefakty znovu zapsán a
všechny čtyři podpisy/hashe opět ověřeny. Finální app (3,4 MiB) a malé lokální review logy byly po
nezávislém review rovněž odstraněny přes manifest cleanup. Testovací event roots byly odstraněny
jejich vlastními testy. Žádné sdílené cache ani cizí run roots nebyly mazány; žádná služba nebyla
registrovaná, takže systémový unregister se neprováděl. Cleanup dry/apply/repeat se ověřil na vlastních
syntetických artefaktech, nikoli na instalované aplikaci nebo registrované službě.

**Neprovedeno:** registration/unregister, bootstrap, LoginItems/daemon běh, UI interakce, reboot/login,
admin approval, instalace, sudo, osobní signing identity, certifikáty/Keychain, TCC/grant/capture,
attach a XPC transport/broker. Hardened runtime/signature static pass není důkaz ochrany TCC.
Daemon autorizační cesta je záměrně neimplementovaná; současné UI umí cleanup jen vlastní úspěšné
registrace ve stejné živé session. Napříč restartem UI/login/reboot není ownership oracle a tyto L2
scénáře se nesmějí zahájit bez doplnění přezkoumaného úklidu. Same-status cizí změna není detekovatelná;
serial LAB slot je předpoklad, nikoli enforcement. **A6 zůstává partial, A7/L2 neprovedené, S8/SG-01…11
Neověřeno; F1 aggregate se nemění.** Úplný postup a další omezení: [SERVICES.md](SERVICES.md).

## WP1.A6 signing handoff — 2026-11-08

Omezená příprava z `main` `7b20c41`, claim `b237e37`; měřený code commit
`5adefab06813d92c8674df5aa1fd88f280e2f22c`. Původní záznamy a hash snapshoty výše se nemění.
Postup: [HANDOFF.md](HANDOFF.md). Celé A6 zůstává partial (H1 fuzzer čeká na H1); A7/L2 a S8/SG-01…11
zůstávají Neověřeno. Tato poznámka je offline validace podle GUIDE §11, nikoli nový laboratorní běh.

- macOS 27.2 `26B123`, arm64, Swift 6.4.2 `swiftlang-6.4.2.1.9`, systémový Python 3.9.6.
- `/usr/bin/python3 -I -B -m unittest discover -s spikes/s8-signing/tools -v`: **51 testů, 0 failures,
  0 skips** (15 původních + 36 nových). Skutečný nový planner/copy/inventory/preflight/cleanup;
  pozitivní non-ad-hoc metadata jsou výslovně **tool stubs**, nikoli Personal Team či self-signed.
  Negativy zahrnují obsah/load-command změny, cesty, linky, flags/módy/inodes, duplicate JSON,
  source drift, částečný handoff zápis, write-before-output, ad-hoc/runtime/entitlement chyby,
  timeout a odmítnutí přepsat signed inventory. Malformovaný testovací Mach-O a počáteční syntax
  testu byly opraveny během vývoje; nejde o výsledky brány.
- Native Release `swift test` s izolovaným scratch/cache: **42 existujících Swift testů, 0 failures**.
  Native backend nadále vydává deprecation warning. Nový Python modul automaticky patří do
  stávajícího macOS spike discovery v CI; GitHub kontrola se ověří až po pushi PR.
- Skutečný vlastní ad-hoc Release app (čtyři targets) prošel původním strict/runtime/empty-entitlement
  verifierem. Jeho Swift zdroje jsou beze změny proti měřenému commitu; build si zapsal tehdejší
  source manifest. **12 smoke kontrol na měřeném commitu**: konkrétní dry-run/new-copy apply,
  nezměněný původní manifest, handoff preview, pre-handoff cleanup dry/apply/repeat, u druhé kopie
  persisted handoff + `bash -n` snippet a očekávané odmítnutí ad-hoc jako reálného podpisu i obou
  post-handoff cleanup režimů. Žádný signing snippet ani fixture executable se nespustil.
- Zdrojový build/cache root `/private/tmp/sanjbox-s8-services-49530FC7-97BF-4BFB-B642-336F080ED806`
  odstraněn původním manifest cleanup dry/apply/repeat; původní manifest zůstal až do cleanup beze
  změny. První copy `…signing-0FC5B2F9-C2A7-489F-A346-6E7F030C4A77` odstraněna novým pre-handoff
  cleanup. Vlastní Swift scratch `/private/tmp/s8-a6-handoff-swift-20261108-4D79F2C1` odstraněn
  po validaci (147 731 258 bytes). Zachována malá ad-hoc kopie pro review:
  `/private/tmp/sanjbox-s8-signing-9C012AF0-5A3B-4B13-A03D-F6A960FBA787`; její handoff marker záměrně
  blokuje produktový cleanup. Je to vlastní testovací fixture bez vykonaného podpisu či služby.
  Krátké lokální diagnostiky: `/private/tmp/s8-a6-handoff-{python-final.log,swift-final.log,real-smoke.json,cache-cleanup.json}`.

**Neověřeno a neprovedeno:** skutečný Personal Team/self-signed podpis a jeho kompatibilita s úzkým
Mach-O delta pravidlem, certifikáty/Keychain/identity lookup, registrace/unregister, status API,
spuštění UI/helperů, service ownership, login/reboot/daemon, TCC/attach a H1 XPC fuzzer.
`record-signed` ověřuje statické properties a inventuru, nikoli druh účtu (`profileVerified=false`).
Po vydání handoffu zůstává registration state unknown a automatický artifact cleanup **odmítá**;
podepsaná inventura neodblokovává L2 ani odstraňování potenciálně registrované aplikace.

### Oprava souběhu po nezávislém review — 2026-11-08

Review prokázalo P2: handoff vložený při druhé kontrole rootu v cleanup mohl vydat příkazy a zapsat
marker, zatímco cleanup pokračoval se starou inventurou, odstranil app a selhal až na novém markeru.
Měřená oprava `1af8925d41c9a3ea61c8cbafb833056d1aa55cad` drží inode-bound directory-fd `flock`
před inventurou až do konce každé operace (včetně dry-run); nový prepare root je zamčen před kopírováním
po zápis inventury. Souběžná operace odmítne `busy` bez inventury nebo změn, další pokus znovu ověří
aktuální stav. Zámek je advisory mezi spolupracujícími příkazy, ne ochrana před ručním codesign či nespolupracujícími změnami téhož UID.

`/usr/bin/python3 -I -B -m unittest discover -s spikes/s8-signing/tools -v`: **59 testů, 0 failures,
0 skips**, 4,369 s na stejném macOS/Python prostředí; log `/private/tmp/s8-a6-handoff-lock-final.log`.
Osm regresí navíc: přesný review counterexample, šest testů se skutečnými samostatnými procesy
(obě pořadí handoff/cleanup, souběžné handoff a signed-inventory zápisy, prepare/partial-state/exit,
dry-run bez lockfile) a uvolnění po refusal. Codesign v těchto syntetických procesových testech
zůstává stub; žádné fixture executable ani služby neběžely. Všechny nové vlastní test roots uklidil
teardown včetně ukončení child procesů; původní nativní review fixture zůstala beze změny.
Swift zdroje se nemění: předchozích **42 Release testů** platí pro stejný Swift kód, znovu zde neběžely.
GitHub CI/re-review následují po předání koordinátorovi; signing/L2/cleanup limity výše zůstávají.

## Review PR #61 po integraci main — 2026-11-13

Původní PR head `d8c01c217a8d7e21d74dbf2afcb15f58e8794ac1` byl lokálně sloučen s
`main` `f301bf398720d8cae78e6e124d4b2a7225aec0e2`. Testovaná revize:
`c0612a48186b580471622ed2e976eaae9bfc4025`; následující změna pouze zapisuje výsledky.
Review nenašlo nový implementační defekt v copy/provenance, čtyřech inside-out příkazech,
statickém preflightu, oddělených inventurách ani konfliktovém úklidu. Existující oprava souběhu
byla znovu ověřena skutečnými oddělenými procesy. Aktuální README/SERVICES/COVERAGE už neoznačují
H1 za nepřítomné: `proto/contracts` je sloučený částečný prototyp, broker v0 odmítá všechny
zprávy a A6 fuzzer na H1 dosud není napojený. Historické záznamy výše zůstávají původní.

Prostředí: arm64, macOS **27.2.1 `26B131`**, Swift **6.4.2 `swiftlang-6.4.2.1.9`**,
systémový Python **3.9.6**. Žádné externí závislosti, síťové testy ani systémové změny.

- `/usr/bin/python3 -I -B -m unittest discover -s spikes/s8-signing/tools -v`:
  **59 testů, 0 failures, 0 skips**, včetně skutečných process/lock regresí; codesign metadata
  v unit testech zůstávají stub, nejde o skutečný Personal Team/self-signed podpis.
- `swift test --configuration debug` a `release`, oba s `--build-system native`, vlastními
  scratch/cache/module-cache cestami a `--disable-sandbox`: **42 + 42 testů, 0 failures**.
  Zůstávají warnings pro nepřístupné user-level SwiftPM cache a deprecated native backend;
  výsledek není warning-free. Buildy zahrnují všechny čtyři service targets.
- `/usr/bin/python3 -B -m unittest discover -s tools/tests -v`: **63 testů, 0 failures**.
  První pokus s `-I` selhal na importu `tools.lab_evidence`, protože izolovaný režim odstraní
  repo root z import path; správný režim podle CI výše prošel. Není to selhání S8.
  `tools/progress.py --history-ref HEAD` vytvořil výstup (**22/63 balíků, 0/155 případů**);
  `git diff --check origin/main...HEAD` prošel.
- Čerstvý vlastní ad-hoc Release app se čtyřmi targets prošel builderem a následnou opakovanou
  `verify`: strict/all-architectures, runtime, ad-hoc a prázdné entitlements. **22 CLI/syntax
  kontrol** nad tímto skutečným artefaktem ověřilo dry-run/new-copy apply, byteově nezměněný
  původní manifest, handoff preview, cleanup dry/apply/repeat, odmítnutí existujícího cíle,
  nekonzistentních profile/fallback voleb, obecné cesty a identity argumentu. Skutečné ACL na
  vlastním rootu a vnořené binárce odmítly handoff i cleanup před změnami; po odstranění pouze
  právě přidané testovací ACL šel původní cleanup dokončit.
- Druhá vlastní kopie ověřila uložení handoff markeru před vydáním čtyř příkazů a `bash -n`
  jejich syntaxe, odmítnutí opakovaného handoffu, ad-hoc `record-signed` a obou režimů úklidu
  po handoffu. **Žádný signing snippet ani fixture executable nebyl spuštěn.** Neproběhl
  identity lookup, práce s certifikáty/Keychain, service/status API, UI, register/unregister,
  login/reboot, attach ani TCC.

Nový source root `…services-1FE1E14B-3AC8-49C1-AA0D-62CCD0FA9301` byl ověřen a odstraněn
původním manifest cleanup dry/apply/repeat; první kopie `…signing-3467F551-9869-4E9E-84D2-1F00EDD87652`
novým pre-handoff cleanup. Druhou kopii `…signing-01813F65-ABE8-4661-93A8-63F1B772AE90` odstranil
výhradně testovací teardown po opětovné kontrole přesné inventury, nezměněného prepared baseline,
markeru a ad-hoc podpisů. Proces ji právě vytvořil a nespustil žádný snippet, executable ani službu;
nejde o podporovanou výjimku pro předané uživatelské artefakty a produktový cleanup nadále odmítal.
Vlastní Swift scratch/cache byly inventarizovány a odstraněny; malé lokální logy zůstávají v
`/private/tmp/s8-pr61-review-7BE0306D-D48E-486C-A283-1C58C5DB60B4` (včetně `smoke-summary.json`).

**Omezení se nemění:** `profileVerified=false`, registration state unknown; statická validace
nedokazuje konkrétního signera, kompatibilitu skutečného Personal Team/self-signed podpisu ani
lifecycle/TCC. Advisory zámek koordinuje pouze příkazy nástroje; hostile same-UID TOCTOU a obecná
crash-atomicity zůstávají mimo garanci. H1 fuzzer a přezkoumaný L2 ownership/cleanup stále chybějí.
**A6 zůstává 🟨, A7/L2 neprovedené, S8 a SG-01…11 Neověřeno; žádná brána se nepovyšuje.**
GitHub CI bude posouzena na finálním PR head po předání koordinátorovi.

### Následná integrace PR #60 — 2026-11-13

Po sloučení D5 byl integrován nový `main` `b9a080a26d3cccc6b41997edd46ba312bc9d3398`;
testovaný merge commit je `f88612e4e2bdac9ca2bedbbc9e182bc899007bcc`. Merge změnil pouze D5
rešerši a její řádek COVERAGE. Byteově beze změny zůstaly S8 `Package.swift`, `Sources`, `Tests`,
`tools` a common package/zdroje proti výše testovanému `c0612a4`; native Debug/Release a ad-hoc
smoke se proto neopakovaly. Znovu prošlo **59 S8 Python testů** a **63 tools testů**, progress
build (**22/63 balíků, 0/155 případů**) i `git diff --check origin/main...HEAD`.
COVERAGE zachovává **D5 🟨, B2 ✅, A6 🟨 a F1 17 hotových / 7 rozpracovaných / 12 nezahájených**;
S8/SG ani jiná brána se nemění. Následující commit pouze doplňuje tento validační záznam.

## WP1.A6 H1 wire fuzzer a syntetický service workflow — 2026-11-14

Vymezené pokračování z `main` `75f3b5da13dfd7fca3acd376e06f1cd4d0fe2786`, claim
`7f914d9e14d1abfa12308d95ec3d5114e34b047b`, měřený implementační commit
**`4d730963f58979539e3410a06d1791ddd45cb14f`**. Původní autorství janfiedler / Codex + Astra
zachováno; navazující Astra má výslovné uživatelské zadání. Tento záznam je krátká offline validace
podle GUIDE §11, nikoli laboratorní důkaz. [Výstup, workflow a blokátory](A6-H1-FOLLOWUP.md).

Prostředí: arm64, macOS **27.2.1 `26B131`**, Apple Swift **6.4.2 `swiftlang-6.4.2.1.9`**,
clang `2100.4.1.1`, systémový `/usr/bin/python3` **3.9.6**. Závislosti pouze lokální common a H1;
žádný jejich zdroj nebyl změněn. Žádná síť při build/test; síť použita pouze k autorizovanému Git push.

- Native Swift `swift test --configuration debug` i `release`, oba s `--disable-sandbox`, vlastními
  scratch/cache/module-cache cestami: **53/53 + 53/53 testů**, 0 failures. Testy zahrnují čtyři
  sestavené service targets, all-message H1 controls, známé odmítnutí každého negativu, přesné
  envelope/body limity a +1 byte, determinismus dvou 10 000-iteration běhů, accept-all/reject-all/
  non-contract-error poruchy oracle, jednotlivé identity dimension/replay/revocation kontroly
  syntetického daemon seam a restart/conflict/cleanup workflow. Debug source bytes odpovídají
  uvedenému commitu, Release byl spuštěn po commitu. Zůstávají warnings pro user cache a deprecated
  native backend; build není warning-free.
- `/usr/bin/python3 -I -B -m unittest discover -s spikes/s8-signing/tools -v`: **60/60 testů**,
  0 failures/skips; nový test pinne zahrnutí všech H1 Package/Sources do build source inventury.
  Původní 59 testů včetně samostatných process/lock regresí zůstává zachovaných.
- Vlastní kopie Release `s8-probe` byla explicitně ad-hoc podepsána `--options runtime` s prázdnými
  entitlements, bez identity lookup/Keychain; strict/all-architectures verify prošel, flags obsahují
  `adhoc,runtime`, žádný `get-task-allow`. SHA-256 binárky:
  `8b02f6621f86ddcc37f913be4b9bcae572e4ff3269bbbdcc78af7e3832d90cc9`.
- **9 CLI smoke kontrol**: `h1-fuzz --iterations 10000 --seed 21304` má **84/84 controls,
  10 599 odmítnutých negativů, 0 unexpectedAccepts/failures**, corpusVersion 1 a SHA-256
  `16f8b498c825682662275f60df955d2d87c17c8336dcd7a3917c27557a4b1896`;
  `service-workflow` vrací šest syntetických variant, obě native allow hodnoty false;
  count 0/10001 a seed 0 vrací exit 4; oba příkazy odmítají `--apply` (exit 2) a chybnou audit
  session (exit 3, pouze identity report). CLI expectation vznikla z vlastní host diagnostiky
  výhradně pro tuto kontrolu; není nezávislá předregistrace L2 ani důkaz identity izolované oblasti.
- `git diff --check 75f3b5d..HEAD` prošel. Nezávislé review a GitHub CI se posoudí na publikovaném
  finálním PR head; tento záznam je nepředjímá.

První lokální smoke harness mylně očekával JSONL, zatímco společný `printJSON` vypisuje za sebou
pretty JSON dokumenty; selhal tedy parser testovacího výstupu. Po opravě na postupné `raw_decode`
prošlo všech devět kontrol, beze změny produktu. Původní Swift/Python průběžné testy také prošly;
nejde o výsledky S8. Smoke nikdy nespustil service/UI target ani signing handoff snippet.

Vlastní input roots odstranil `finally` v obou smoke pokusech. Vlastní scratch/cache root
`/private/tmp/a6-h1-20261114-7F914D9` byl po inventuře UID/type/inode odstraněn; rovněž vlastní
kopie CLI po opětovném ověření hashe. Zachované malé lokální záznamy:
`/private/tmp/a6-h1-cli-records-4D73096/{summary,fuzz-report,workflow-report,cleanup-summary}.json`,
`signature.txt` a `/private/tmp/a6-h1-{debug-final,release-final,python-final}.log`.
Žádné sdílené cache ani cizí run roots se nemazaly; testy uklidily své event/fixture roots.

**Neprovedeno a neověřeno:** skutečný Personal Team/self-signed podpis, registration/status API,
UI/helpers/daemon běh, durable native service ownership, unregister přes restart, login/reboot,
OS admin approval, účty, TCC/grant/capture, attach, nativní XPC/audit-token ověření a skutečné Mach
rights. Daemon seam i restart recovery jsou modely s mock autoritou/údaji, nikoli jejich native
adaptéry. Post-handoff artifact cleanup stále odmítá unknown registraci. H1 wire fuzzer je dodaný,
**A6 však zůstává 🟨 a S8/SG-01…11 Neověřeno**; přesná zbývající příprava je uvedena ve follow-up.

## Nezávislé integrační review po H4 a A3 — 2026-11-14

Nové nezávislé Astra review původního #77 headu `abafe42a3c4aa7081cfa2a4f3550c73cf4ea3862`
proběhlo v izolovaném worktree. Normální merge aktuálního `main`
`8faf6487cc805b5a3df8b8711e7c20d20d37202c` (H4 #79 a částečné A3 #78) vytvořil měřenou revizi
**`8186a3625c5d29cdffce10037902ef31e1d6a0d7`**; jediný konflikt byl A6 řádek COVERAGE.
Následující commit mění pouze dokumentaci, nikoli testovaný kód. Historie ani původní evidence
nebyly přepsané. GitHub CI a finální nezávislá integrační kontrola patří ke konečnému PR headu.

Review přečetlo celý A6 diff proti PLAN S8 a skutečným H1 helper/reply/broker API: nezávislé
raw controls, obě broker admission cesty, reply/delivery korelaci, rozsah vstupů a diagnostik,
known-error oracle, CLI identity/signature preflight, host-only mock identitu/one-use approval,
revokaci a restart/cleanup konflikty. Zkontrolovalo i nativní service policy a post-handoff cleanup:
syntetický model není na ně napojený a jeho `cleaned` stav ani user-review boolean nic neodblokují.
**Nový implementační defekt nebyl nalezen.** Opravená aktuální dokumentace rozlišuje dodaný H1
wire fuzzer od zbývající přípravy A6 a opravuje již sloučený stav A3 na `8faf648`.

Prostředí: arm64, macOS **27.2.1 `26B131`**, Apple Swift **6.4.2 `swiftlang-6.4.2.1.9`**,
clang **2100.4.1.1**, systémový Python **3.9.6**. Build používá výchozí SwiftPM backend;
všechny závislosti jsou lokální. Pro oba příkazy je scratch
`/private/tmp/sanjbox-pr77-review-swift`:

```sh
swift test --package-path spikes/s8-signing --configuration debug --scratch-path /private/tmp/sanjbox-pr77-review-swift
swift test --package-path spikes/s8-signing --configuration release --scratch-path /private/tmp/sanjbox-pr77-review-swift
/usr/bin/python3 -I -B -m unittest discover -s spikes/s8-signing/tools -v
/usr/bin/python3 -B -m unittest discover -s tools/tests -v
```

- Swift **53/53 Debug a 53/53 Release**, 0 failures; všechny produkty včetně čtyř service targets
  se sestavily. Existující cílené testy pokrývají accept-all/reject-all/non-contract-error oracle,
  přesné byte limity a +1, všechny H1 druhy, identity/replay/revocation a recovery/cleanup odmítnutí.
- Python **60/60 S8** a **94/94 repo tooling**, 0 failures/skips. S8 zahrnuje H1 source provenance
  i procesové lock regrese; non-ad-hoc podpisy v Python fixtures jsou stále stubs.
- **30/30 CLI kontrol v Debug a 30/30 v Release** nad vlastními kopiemi `s8-probe`, explicitně
  ad-hoc podepsanými s runtime a prázdnými entitlements. Strict/all-architectures verify prošel;
  žádný `get-task-allow`. Binární SHA-256: Debug
  `308bfaa193e3966715748f292af899fc09af76c9edef29379d1288b1413a67ea`, Release
  `742ac0dd53ba77495beb60b552560da5764339f1f938c8dc48836ddbbdd3d0a3`.
- V každém sestavení seeds **1, 21304 a UInt64.max** po 10 000 iteracích: **84/84 pozitivních
  controls, 10 599 odmítnutých negativů**, žádný unexpected accept/failure; minimum 1 se seedem
  21305: 84/84 a 600 odmítnutí. Pro seed 21304 reprodukován corpusVersion 1 SHA-256
  **`16f8b498c825682662275f60df955d2d87c17c8336dcd7a3917c27557a4b1896`**.
- CLI dále ověřilo šest workflow variant s oběma native allow flags `false`, count 0/-1/10001/Int.max,
  seed 0, syntaktické/overflow chyby čísel, duplicate/missing options a odmítnutí `--apply`, PID,
  service i command u obou nových příkazů. Chybná audit session skončila exit 3 s jediným identity
  reportem; chybějící expectation/zakázané argumenty nespustily příkaz.
- `git diff --check` a generování `tools/progress.py` ověřily dokumentaci: F0 **5/5**, F1
  **22 hotových / 5 rozpracovaných / 9 nezahájených**, všech **155 případů a 10 bran Neověřeno**.

Dvě počáteční chyby byly pouze v novém lokálním CLI harnessu: Python `os.getgroups()` na tomto
macOS vrací širší membership seznam než nativní kernel `getgroups`, a záměrně chybná expectation
nejprve neměla požadované pevné jméno. Harness byl opraven na přímé `getgroups` a samostatný vlastní
input root se jménem `s8-expectation.json`; úplná matice potom prošla beze změny produktu.
Host expectation byla pro tuto offline kontrolu porovnaná s vlastními credentials a diagnostikou;
nejde o nezávislou předregistraci L2 ani identitu izolované oblasti. Všechny nové input roots
byly odstraněné po testu. Malé lokální záznamy jsou v `/private/tmp/sanjbox-pr77-review-cli/`
a `/private/tmp/sanjbox-pr77-review-{debug,release,python-spike,python-repo}.log`.

**Hranice:** žádný skutečný Personal Team/self-signed podpis, certifikát/Keychain, SMAppService
status/register/unregister, UI/helper/daemon běh, OS admin approval, login/reboot, TCC, attach,
XPC transport ani Mach práva se nepoužily. Durable ownership/cleanup přes restart, nativní
host-only approval a SG-06 srovnatelná pozitivní attach kontrola jsou stále konkrétní chybějící
výstupy; [IMPLEMENTATION §0](../../docs/IMPLEMENTATION.md#0-co-dál) určuje další kroky a vlastníky.
A3 i A6 zůstávají rozpracované. Žádná brána ani akceptace nedostává pass z těchto mock/offline testů.

## WP1.A6 native durable provenance a recovery — 2026-11-14

Vymezené pokračování z `main` **`7b8294e4fd28a3e62f4998baf39d3da1fd904ccb`**, zveřejněný claim
`53bb52a`, výslovné uživatelské předání navazující Astře při zachování autorství janfiedler / Codex + Astra.
Měřený finální implementační commit je **`1a613da1aa0210c23d2d62ba1374be102795c34e`**;
následující commit pouze zapisuje tuto validaci. [Rozsah, native workflow a blokátory](NATIVE-RECOVERY.md).
Původní #77 evidence a historické manifesty zůstávají beze změny; není to laboratorní S8 výsledek.

Prostředí: arm64, macOS **27.2.1 `26B131`**, Apple Swift **6.4.2 `swiftlang-6.4.2.1.9`**,
clang `2100.4.1.1`, systémový Python **3.9.6**. Lokální common/H1 závislosti se nemění.
Finální Swift běhy použily `--build-system native`, `--disable-sandbox`, vlastní scratch
`/private/tmp/a6-native-recovery-swift`, package cache `…-cache` a module cache `…-modules`.
Native backend stále hlásí deprecation warning; warning-free build netvrdíme.

- `swift test --configuration debug` i `release` s výše uvedenými parametry:
  **74/74 + 74/74**, 0 failures. Nových **21 testů** používá skutečné directory fds, hashování,
  ACL/módy/inodes, fsync/full-sync, flock, vlastní proc/start/boot/audit údaje a samostatné Python
  child procesy. Pokrývají oba user-service typy, neadoptování stejného statusu po reopen,
  původně neznámou/přerušenou/chybnou registraci, replay/cizí pairing, changed inventory/run/UID/GID,
  process/start/boot/session drift, částečný/extra/oversize/duplicitní JSON, symlink/hardlink/FIFO,
  nahrazený root a 64 opakovaných malformed opens s okamžitým znovuzískáním locku.
  API statusy a signed-app binding těchto fixtures jsou **syntetické**; filesystem a process API
  jsou skutečné. Produkční `capture()` navíc odmítá nepodepsaný test runner. Žádné SM API se nevolá.
- Finální stress matice `--skip-build --filter native`: **20 Debug + 20 Release běhů × 21 testů =
  840 průchodů, 0 failures**, včetně celkem **2 560** malformed-open/lock kontrol a souběžných
  subprocess testů. `summary.json` a jednotlivé logy zůstávají v
  `/private/tmp/a6-native-recovery-stress-unlock/`. Explicitní syscall-order test ověřuje pořadí
  `fsync(file) → fsync(directory) → F_FULLFSYNC(file)` a odmítnutí na každém kroku; není to
  měření výpadku napájení. Deterministický lock test drží duplicitní open-file description i po
  uvolnění vlastníka a ověřuje, že další nezávislý fd získá lock.
- `/usr/bin/python3 -I -B -m unittest discover -s spikes/s8-signing/tools -v`:
  **60/60**, 0 failures/skips, finálně znovu na `1a613da`. Původní post-handoff cleanup refusal,
  source inventory a process-lock regrese zůstávají zachované. Non-ad-hoc signing v Python
  fixtures je nadále stub, nikoli skutečná uživatelská signing identity.
- Repo tooling `/usr/bin/python3 -B -m unittest discover -s tools/tests -v`: **98/98**, 0 failures
  na `8340e30`; následné commity mění pouze native S8 zdroj/test/dokumentaci, `tools/` je byteově
  stejné. `tools/progress.py --history-ref HEAD` na `1a613da` vytvořil **27/63 balíků celkem,
  0/155 prošlých případů**; `git diff --check` proti base prošel. COVERAGE mění pouze A6 řádek.
- Nový skutečný Release app po finální implementaci prošel původním builderem a samostatnou
  `verify`: všechny čtyři targets jsou thin arm64, strict/all-architectures validní, ad-hoc/runtime
  s prázdnými entitlements. Host SHA-256 je
  **`166ebed7973f177921233f37629485396a2079b19cfc81a8ff96f06d6cfd7879`**;
  hashe všech čtyř jsou v `/private/tmp/a6-native-recovery-builder-final.log`.
  **Žádný service executable, UI ani ServiceManagement status/register/unregister neběžel.**
  Nativní non-ad-hoc capture/recovery na skutečně uživatelsky podepsaném app zůstává neověřený.

### Nalezené chyby a opravy v tomto pokračování

První sandboxovaný native test nemohl číst `kern.boottime` (`EPERM`); vlastní `proc_pidinfo` a
audit data dostupná byla. Fail-closed boot kontrola zůstala zachovaná a finální testy běžely se
scoped read-only process/boot přístupem. Testovací helper původně použil produkční `BoundedTool`
pro chmod/Python, což správně odmítl allowlist; oprava přidala oddělený test-only helper, produkční
allowlist se nerozšířil. První repo tooling běh uvnitř sandboxu selhal v osmi watchdog kontrolách
při blokovaném `/bin/ps` a souvisejícím timeoutu; běh s potřebným read-only process přístupem
potom prošel všech 98 testů. Žádný produktový mechanismus nebyl kvůli sandboxu oslabený.

Nezávislé průběžné review našlo chybnou původní durability sekvenci: directory fsync následoval
po full-sync barrier. Oprava před API synchronizuje soubor i directory a teprve potom požaduje
finální device flush; ověřuje také shodný device creation ancestry a souboru. Další review našlo
intermitentní lock test. Plain `dup` byl nahrazen atomickým `F_DUPFD_CLOEXEC` (`0664217`), test
verifier dostal vlastní `O_CLOEXEC` (`655ac99`), ale stress stále zachytil krátké prodloužení locku:
close-on-exec neuzavírá sdílený descriptor v child procesu **před exec**. Finální `1a613da`
explicitně volá `LOCK_UN` před close vlastnického fd při deinit i neúspěšném init; totéž dělá
verifier. Výše uvedená finální 840-test matice už prošla celá. Původní neúspěšné stress běhy
zůstávají v `/private/tmp/a6-native-recovery-stress/` a `…-stress-final/`, nejsou přepsané pass.

Throwing-init cleanup byl navíc ověřen malým Swift reproducerem: po inicializaci všech stored
properties Swift při throw zavolá deinit. `transferred` proto předává fd právě v tomto bodě;
před ním jej uvolní catch, po něm deinit. Reproducer `/private/tmp/a6-native-recovery-stage/init.swift`
a nativní malformed reopen/lock regrese rozlišují tuto vlastnost od původní hypotézy uniklého fd.
Nezávislé review implementace a dokumentace na `73f692d` je dokončené, viz addendum níže;
CI se nadále posuzuje na přesném publikovaném PR headu.

### Vlastní úklid a hranice

Všechny testy odstranily pouze své přesné čerstvé temporary roots a reapovaly vlastní children.
Čtyři vlastní builder roots (poslední `…services-D908360A-3380-4F15-A023-EC50AC55B860` a předchozí
`…9417187C-0357-4F4A-BC72-7D89BEA64DC6`, `…345E864F-35B7-4F4E-B210-ED07EB372712`,
`…F77A6255-858A-4D26-9416-4E7C4CF0D723`) prošly vlastní manifest kontrolou a cleanup;
finální root navíc opakovaným no-op cleanup. Nebyl vydán signing handoff ani spuštěna služba.
Vlastní scratch/cache/module-cache rooty byly po kontrole UID/type/inode inventarizované a
odstraněné, **600 512 643 file bytes**; záznam je v
`/private/tmp/a6-native-recovery-stage/cache-cleanup.json`. Žádné sdílené cache, cizí worktree,
Application Support state, systémy nebo uživatelské účty se neměnily. Malé lokální test/build/log
záznamy `/private/tmp/a6-native-recovery-*` zůstávají pro review.

**Neprovedeno:** Personal Team/self-signed identity, certifikáty/Keychain, native služba či její
status, restart/login/reboot, OS admin approval/notarizace, TCC/attach, XPC audit token/transport
nebo skutečná Mach práva. Native journal dodává trvalou provenance a recovery inspection,
**nikoli registration generation či vlastnictví po restartu**. Neodblokovává post-handoff
artifact cleanup ani daemon. SG-06 nemá povolený kalibrovaný pozitivní control; přesné zdrojové
podklady a zbývající kroky jsou v NATIVE-RECOVERY/RESEARCH. **A6 zůstává 🟨, S8/SG-01…11 a všechny
laboratorní brány Neověřeno.** Další obecný mock tuto mezeru neuzavře.


### Nezávislé review finálního A6 headu — 2026-11-14

Nový nezávislý Astra reviewer dokončil review headu **`73f692d22b5b9127f3ac56f667859873d6c3a200`**,
včetně finální dokumentace; **nezůstalo žádné nevyřešené actionable zjištění**. P1 pořadí full-sync
barrier a P2 životnost zděděného locku jsou opravené. Reviewer samostatně ověřil **74/74 Debug,
74/74 Release a 10/10 adversarial kontrol**: recovery skutečným odděleným procesem, **512**
malformed opens s přesnou kontrolou počtu fd a skutečný deinit s ponechanou duplicitní
open-file description, po kterém další vlastník získá lock.

Reviewovaný zdroj odpovídá implementaci `1a613da`; SHA-256 obou dotčených Swift zdrojů i nového
test souboru byly znovu porovnány s nezávislým záznamem
`/private/tmp/a6-native-review-20261114-A6R/review-summary.json`. Tento addendum mění pouze
VALIDATION; nezměněné testy se znovu nespouštěly. Původní evidence, neúspěšné stress běhy a
atribuce zůstávají zachované. Review používá vlastní soubory/procesy a syntetické service výsledky;
neprovedlo skutečnou registraci/status API, TCC, reboot, signing identity ani daemon approval.

**Review neuzavírá A6 ani S8:** chybí nezávislý registration-continuity/cleanup oracle přes restart,
trusted native host/admin autorizace, kalibrovaná SG-06 pozitivní kontrola a skutečné podpisy/L2.
Post-handoff cleanup zůstává odmítnutý; PR #82 zůstává draft bez merge/automerge a CI náleží
novému přesnému headu, nikoli automaticky předchozí revizi.
