# WP1.B4 — lokální syntetická validace

Datum: 2026-11-04. Základ: `afae1ca`, první claim commit: `513b183`.
Jde o vývojové mock testy, **nikoli laboratorní důkaz, APFS test ani verdikt S4**.
B3 schema, příklady, validátor, 21 původních testů a starší evidence nebyly upraveny.

Konfigurace: Apple Silicon / arm64; macOS 27.2 build 26B123; Xcode 27.0 build 27A266a;
Apple Swift 6.4 (`swiftlang-6.4.0.34.1`, `clang-2100.3.34.1`). Deployment minimum 15
neznamená otestování macOS 15. Nebyly použity externí balíčky, sudo, mount/system/root operace,
Keychain, skutečná tajemství ani data. Čtou se jen vlastní návrhové JSONy a generované fixtures.

## Přesné příkazy

Všechny příkazy běžely z kořene izolované větve B4. Cache byla nová `mkdtemp` fixture s uloženým
UID/device/inode pro následný úklid. `--disable-sandbox` se týká SwiftPM buildu, nikoli změny
oprávnění mocku. Wrapper test dostal Release binárku z téhož build adresáře.

```bash
swift --version
sw_vers
xcodebuild -version

env CLANG_MODULE_CACHE_PATH=/private/tmp/sanjbox-b4-build.l75y5tuk/module \
  SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/sanjbox-b4-build.l75y5tuk/module \
  swift build -c release --package-path spikes/s4-state \
  --scratch-path /private/tmp/sanjbox-b4-build.l75y5tuk/build \
  --cache-path /private/tmp/sanjbox-b4-build.l75y5tuk/cache --disable-sandbox

env CLANG_MODULE_CACHE_PATH=/private/tmp/sanjbox-b4-build.l75y5tuk/module \
  SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/sanjbox-b4-build.l75y5tuk/module \
  swift test -c release --package-path spikes/s4-state \
  --scratch-path /private/tmp/sanjbox-b4-build.l75y5tuk/build \
  --cache-path /private/tmp/sanjbox-b4-build.l75y5tuk/cache --disable-sandbox

# Po drobné změně idempotence teardownu jen oba přímo ovlivněné testy:
env CLANG_MODULE_CACHE_PATH=/private/tmp/sanjbox-b4-build.l75y5tuk/module \
  SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/sanjbox-b4-build.l75y5tuk/module \
  swift test -c release --package-path spikes/s4-state \
  --scratch-path /private/tmp/sanjbox-b4-build.l75y5tuk/build \
  --cache-path /private/tmp/sanjbox-b4-build.l75y5tuk/cache --disable-sandbox \
  --filter 'RecoveryTests/(testOwnedCleanupRemovesCompletedMockAndRejectsUnexpectedRootEntry|testCLIWrapperDefaultDryRunApplyAndIdentityFirst)'

# Po zahrnutí koncového newline do 64 KiB limitu:
env CLANG_MODULE_CACHE_PATH=/private/tmp/sanjbox-b4-build.l75y5tuk/module \
  SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/sanjbox-b4-build.l75y5tuk/module \
  swift test -c release --package-path spikes/s4-state \
  --scratch-path /private/tmp/sanjbox-b4-build.l75y5tuk/build \
  --cache-path /private/tmp/sanjbox-b4-build.l75y5tuk/cache --disable-sandbox \
  --filter 'RecoveryTests/(testExactRecordByteLimitRoundTripsThroughStoreAndOverflowCreatesNoFile|testMissingTruncatedUnknownDuplicateOversizeAndDeepJournalDeny)'

bash -n spikes/s4-state/validate-state.sh spikes/s4-state/recovery-mock.sh
/private/tmp/sanjbox-b4-build.l75y5tuk/build/out/Products/Release/sanjbox-state-recovery --help
git diff --check
```

Po validaci nezůstala žádná B4 mock fixture; vlastní 130 MiB build/cache strom byl odstraněn
pouze po kontrole přesné cesty, typu, mode, vlastníka, device a inode. Žádné archivy nevznikly.

Při opakování zvol nový vlastní cache adresář; výše uvedený byl po běhu odstraněn, nikoli archivován.
Testy samy generují `/private/tmp/sanjbox-b4-mock.XXXXXX` a odstraňují jen identitou ověřené vlastní
fixtures. Produkční CLI default dry-run i `--apply` jsou testované přes shell wrapper.

## Původní ověření před nezávislým review

- Finální plná Release sada: **40 XCTest metod, 0 failures**, 24,222 s (19 B4 + 21 původních B3).
- Po závěrečné úpravě idempotence cleanupu: oba dotčené Release testy prošly (1,701 s).
- Následně ověřen exact-limit round trip 65536 B včetně newline přes durable store a strict decode;
  65537 B odmítnuto před vytvořením souboru. Po této úpravě proběhl i samostatný Release build.
  Obě závěrečné hraniční/corruption regrese prošly (0,972 s).
  Celkem sada obsahuje 41 metod; plná sada 40 a následné cílené regrese jsou zde rozlišené.
- **31 crash bodů**: 7 globálních hranic plus intent / před mutací / po mutaci / completion
  pro každý ze 3 kroků (snapshot, prepare, switch) a každý ze 2 modelovaných svazků.
  Každý crash child skutečně skončil `_exit(77)`. Každý druhý, nový helper proces načetl disk,
  ověřil očekávaný deny/allow a provedl recovery nebo odmítl pending intent. Celkem 62 subprocessů.
  Produkční CLI nemá fault-injection přepínače.
- Oracle před dokončením: `mockStartAllowed == false`; po dokončeném a nově ověřeném `verified`
  může být true. **Ve všech výstupech `realStartAllowed == false`.** 18 crash bodů zanechá pending
  intent a bezpečně odmítá automatické pokračování; zbývajících 13 je ověřitelně pokračovatelných
  checkpointů včetně již dokončeného `verified`.
- Úplná obnova home/projekt/prefix/cache/tmp kanárků, odstranění inertního startup řetězce,
  nový inode obnoveného modelu proti snapshotu, zachovaný přesný host policy receipt.
- Všechny volume preparations před prvním switch; explicitní smíšený stav po prvním switch
  nesmí startovat. Drift již přepnutého svazku před final verify nesmí vytvořit `verified`.
- Odmítnuté chybějící whole-UID/admission/network předpoklady; fully-off/fd/mapping podmínky;
  stale lease; backend s chybějícími/duplicitními/cizími volume IDs; workload změny před snapshot-ready.
- Konflikty: pozdější binding obsah, ABA se stejnými bytes a změněným ctime, změna před switch,
  snapshot/restored/policy drift, náhrada adresáře, extra state entries. Pozorované změny se nepřepíší.
- Journal: chybějící/truncated/unknown/duplicate/deep/oversize obsah, hash chain a phase mismatch,
  extra entry, hardlink, symlink a FIFO; druhý spolupracující opener nedostane lock.
- CLI: dry-run, apply demo s vlastním úklidem, identity mismatch před manifest read,
  nepodporované skutečné operace a konfliktní přepínače. Cleanup odmítne cizí root entry;
  opakovaný cleanup již odstraněné přesné fixture je no-op.
- `bash -n`, CLI `--help` a `git diff --check`: exit 0.

## Vývojové neúspěchy

První Release build neprošel: Swift nedokázal včas odvodit typ dlouhé kombinace `flatMap`/`+` pro
seznam kroků; tři throwing guard podmínky také potřebovaly vlastní `try`. Seznam byl přepsán
na přehledné omezené smyčky a `try` doplněno. První test compile dále odhalil kolizi názvu helperu
`open()` s Darwin `open`; syscall je nyní výslovně `Darwin.open`.

První skutečně spuštěná sada prošla: 37 metod / 0 failures. Review doplnilo inventory/backend/drift
případy a finální plná sada 40 metod znovu prošla. Po idempotentním cleanupu se ověřily jen dvě
přímo ovlivněné metody. Finální kontrola zahrnula newline do 64 KiB encoded limitu a přidala
hraniční store/decode regresi; spolu s existující corruption regresí se spustily cíleně. Žádné testovací selhání nebylo přejmenováno na prošlý výsledek.

## Oprava po nezávislém review: chyba flush

Review zjistilo, že původní writer mohl zanechat úplné kanonické `verified` bytes i po chybě
`fsync`/`F_FULLFSYNC`; původní reader je zaměňoval za durable completion. Oprava uzamkne aktuální
instanci do deny a při novém otevření vyžaduje skutečný úspěšný reflush každého relevantního receipt
včetně jeho adresáře, kořene fixture a `/private/tmp`. Cache platí jen pro přesný již flushnutý receipt
aktuální instance. Kanonický obsah sám již není potvrzení durability.

Regrese vytváří právě původní nebezpečný stav: úplný `015.json` s `phase: verified` a následně
injektovanou chybu na každé z šesti syscall hranic (file fsync, file fullfsync, directory fsync,
fixture-root fsync, temp-parent fsync, final fullfsync). Kontroluje deny stejné instance i po vypnutí
fault hooku. Pro každou hranici nový proces znovu injektuje chybu při revalidation a musí zůstat deny;
druhý nový proces bez chyby musí nejdřív úspěšně flushnout lock/identity/policy/manifest, všech 16 eventů,
oba snapshoty, restored obrazy a aktuální selektory, teprve potom smí vrátit mock allow. Celkem
12 dalších subprocessů. Produkční CLI stále nemá fault switch.

Použita nová vlastní cache s uloženým UID/device/inode. Přesné příkazy z kořene B4:

```bash
env CLANG_MODULE_CACHE_PATH=/private/tmp/sanjbox-b4-flush-build.bdnuii7m/module \
  SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/sanjbox-b4-flush-build.bdnuii7m/module \
  swift test -c release --package-path spikes/s4-state \
  --scratch-path /private/tmp/sanjbox-b4-flush-build.bdnuii7m/build \
  --cache-path /private/tmp/sanjbox-b4-flush-build.bdnuii7m/cache --disable-sandbox \
  --filter RecoveryTests/testCompleteVerifiedBytesAfterEveryFlushFailureDenyUntilFreshSuccessfulRevalidation

env CLANG_MODULE_CACHE_PATH=/private/tmp/sanjbox-b4-flush-build.bdnuii7m/module \
  SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/sanjbox-b4-flush-build.bdnuii7m/module \
  swift test -c release --package-path spikes/s4-state \
  --scratch-path /private/tmp/sanjbox-b4-flush-build.bdnuii7m/build \
  --cache-path /private/tmp/sanjbox-b4-flush-build.bdnuii7m/cache --disable-sandbox
```

Focused flush-error regrese prošla: 1 metoda, 0 failures, 5,048 s. Finální plná Release sada po
zahrnutí lock souboru prošla: **42 metod, 0 failures, 27,574 s** (21 B4 + 21 zachovaných B3).
Původních 31 crash/restart scénářů, CLI a všechny konfliktní/bounded-input testy znovu prošly.
`git diff --check` a oba `bash -n` wrapper checks: exit 0. Druhá vlastní 130 MiB cache byla po
kontrole uložené identity odstraněna; žádné B4 mock fixtures ani archivy nezůstaly.

Injektované chyby testují error paths; nejsou měřením skutečné chyby zařízení, ztráty napájení nebo pravdivosti filesystemového flush API.

## Omezení

Není implementován nativní APFS snapshot/writable reconstruction/mount switch ani OS whole-UID
lifecycle/start interlock. Caller-owned sibling control není root-owned ochrana proti oblasti.
Není měřen fyzický výpadek napájení, skutečná chyba zařízení/flush, reboot recovery, aplikační crash
consistency, skutečné fd/mappings, nové mounty ani současné tři oblasti. Poslední check/rename
nebo check/unlink interval vyžaduje důvěryhodný výlučný namespace; nejde o atomický CAS.
Pending intent vyžaduje ruční posouzení; automatická oprava všech přerušení není prokázána.
Detailní kontrakt a zbývající RB-02…08 jsou v [RECOVERY.md](RECOVERY.md).

## Oprava review APFS pilotu — offline příprava (2026-11-07)

Tato poznámka dokládá offline opravu `apfs-pilot.sh`, `TOOLING.md` a syntetických testů podle
review PR #56. Nejde o laboratorní běh, APFS důkaz ani verdikt S4: apply cesta se v testech nikdy
nespouští reálně, žádný `asr`, `diskutil` mutace, mount ani sudo neproběhly. Fixtures jsou syntetické
a živá sonda používá recording shimy.

Ověřeno na commitu `6f0eb0a5a1b9eed49246bc123d056913f840d00b` (větev
`wp1/b4-apfs-pilot-dryrun`):

- `bash -n spikes/s4-state/apfs-pilot.sh`: exit 0.
- `/usr/bin/python3 -I -B -m unittest discover -s spikes/s4-state -p 'test*.py' -v`:
  **37 testů, 0 failures, 0 errors**.
- `swift test -c release --package-path spikes/s4-state --scratch-path /private/tmp/fix-b4`:
  **42 testů, 0 failures** (21 B4 + 21 zachovaných B3).
- `/usr/bin/python3 -m unittest discover -s tools/tests`: **63 testů, OK**.

Nové regrese pokrývají: `backupDigest` (`sha256:` + 64 malých hex) přijatý i odmítnutý; povinné
`expectedVolumeUUID` pro apply a `inconclusive` identity gate v dry-runu bez UUID; exit kódy pro
chybějící/neznámý klíč receiptu a špatný typ (4) versus neexistující soubor, symlink a 0666 (2);
warn při kterékoli kvótě 0; přesný mode 0700 out-diru; privátní rodičovský adresář plánu; `rootRequired:
true` u `delete-snapshot`; explicitní P0 krok `asr-switch-support`; a dokumentaci testovacích hooků
`APFS_PILOT_DISKUTIL`/`_SYSCTL`/`_MOUNT`. `docs/COVERAGE.md`, `PLAN.md`, `spikes/common/`, `Contracts/`
ani `.pi/` nebyly v této opravě měněny.


## Druhé review APFS planneru — identity, mounty a ochrana vstupů (2026-11-07)

Oprava navazuje na HEAD `77c4621d2103def7a47b27a056be0700fc78c139` v PR #56.
Uzavírá šest reprodukovaných chyb pouze offline planneru: identity `diskutil info` se křížově
ověřují proti `apfs list`; mount tabulka a info musejí souhlasit a všechny target mounty
zůstávají v pilot rootu; výstup nesmí kolidovat s plánem, receiptem ani čtenou fixture;
i byte-identický existující výstup vyžaduje správného vlastníka a mode 0600; neplatné typy
`coversDevices` deterministicky vracejí exit 4; `createdAt` musí být platné UTC kalendářní datum.
TOOLING a popis testů nyní přesně uvádějí také pozitivní apply hand-off nad shimy.

Ověření z kořene tohoto worktree:

```bash
/usr/bin/python3 -I -B -m unittest discover -s spikes/s4-state -p 'test*.py' -v
git diff --check
```

Výsledek: **52 testů, 0 failures, 0 errors**, 26,522 s, včetně `bash -n`, původních 37 testů
a 15 nových regresních metod. Přesné původní reprodukce jsou v nové `ReviewRegressionTests`:
rozporné UUID/device a prázdné info; target mimo pilot root pouze v mount tabulce; vstupní plán
na výstupní cestě; opakování se shodným výstupem 0666; `coversDevices: [{}]`; neexistující
`2026-99-99T99:99:99Z`. Rozšíření zahrnuje chybějící info pole, chybějící/rozporný mount,
target snapshot mount, kolizi receiptu, hardlink aliasy všech čtených metadata fixtures,
nepřestupné datum a pozitivní kontrolu přestupného dne. Identity/mounty/receipty se zkoušejí
v dry-run i apply přes recording shimy. Výstupní kolize a nebezpečný mode ponechávají původní
soubor i jeho bytes beze změny.

Všechny fixtures byly vlastní dočasné stromy v `/private/tmp`; Python běžel s `-I -B`.
Žádná skutečná APFS/snapshot/asr/mount/unmount/sudo operace neproběhla. Swift zdroje ani jejich
kontrakty se nemění, takže Swift sada se v této rundě znovu nespouštěla. Živý APFS pilot,
G1–G3, L3 a S4 nadále nejsou ověřené. Starší validační záznamy výše zůstaly zachované.
