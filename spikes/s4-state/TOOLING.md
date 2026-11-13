# WP1.B4 — APFS pilot: plánovač, záznam stavu a úklid (P0)

`apfs-pilot.sh` je **read-only plánovač a předávací skript** pro podmíněný uživatelský APFS pilot
z [karet P0–P4](research/wp1-b4-apfs/EXPERIMENTS.md). Nikdy nevytváří snapshot, nic nemountuje ani
neodmountuje, nespouští `asr`, nic nemaže a nespouští nic privilegované. Přečte jen metadata
(`diskutil apfs list -plist`, `diskutil info -plist`, `mount`, `sysctl -n kern.bootsessionuuid`),
zapíše jeden JSON plán a vypíše argv, které **spouští uživatel ručně**.

**Toto není APFS důkaz, adaptér ani verdikt S4.** Skript neumí ověřit whole-UID quiescence (G2),
oprávnění snapshot creation (G1) ani `asr` chování (G3). `whole-uid-interlock` je proto `manual`
gate, ne `pass`; skutečný důkaz vzniká až v rezervovaném L3 slotu podle [GUIDE §7](../../docs/GUIDE.md)
a uzavírá ho nezávislé review.

## Co dělá dry-run a co apply

| Režim | Co skutečně proběhne | Co se změní na disku |
|---|---|---|
| `--dry-run` (výchozí) | Přečte plán a metadata, spočítá gates, zapíše `<out-dir>/apfs-pilot-plan.json` a vypíše stejný JSON na stdout | Nic; jen jeden vlastní soubor v `--out-dir` |
| `--apply --i-understand --backup-receipt FILE` | Stejné čtení a stejné gates, navíc ověří zálohový receipt; vypíše runbook na stdout | Nic; apply **nezapisuje** ani plán, jen předává argv |

`--apply` je zakázané bez obou přepínačů (`--i-understand` = výslovné potvrzení, že každý vypsaný
příkaz spustí uživatel ručně, `--backup-receipt` = existující zálohový receipt). Odmítnutí je
deterministické: exit 4, jednoznačná zpráva na stderr, žádný výstupní soubor.

`--fixture-dir` je určený jen pro testy a review: čte zachycené plisty místo hosta a označí
`probe.source: "fixture-mock"`. S `--apply` se odmítá, protože apply vyžaduje živé read-only čtení.

## Vstupy

Plán `sanjbox.apfs-pilot.plan.v1` (max 64 KiB, vlastní soubor bez symlinku, group/world write
odmítnuto, stejně jako jeho rodičovský adresář). Musí být 1–2 páry podle pilotního budgetu; všechny
cesty a UUID jsou vlastní, ne nalezené v cizím stromu.

```json
{
  "schema": "sanjbox.apfs-pilot.plan.v1",
  "pilotId": "wp1-b4-p0",
  "transactionLabel": "T-20261107-01",
  "pilotRoot": "/Volumes/SanjboxPilot",
  "pairs": [
    {
      "id": "A",
      "snapshotName": "sanjbox-b4-T-20261107-01-A",
      "source": {"device": "disk9s1", "expectedVolumeUUID": "UUID", "expectedContainerUUID": "UUID"},
      "target": {"device": "disk9s2", "expectedVolumeUUID": "UUID", "expectedContainerUUID": "UUID"}
    }
  ]
}
```

`expectedVolumeUUID`/`expectedContainerUUID` musejí sedět na pozorování, jinak je gate
`identity-match` `fail`. Dry-run bez úplné deklarované identity všech svazků má gate
`inconclusive`, `verdict.identityChecked` je `false` a běh skončí exit 5; nestačí ověřit jen jeden
svazek nebo container UUID.
Pro `--apply` je `expectedVolumeUUID` povinné u source i target; pokud plán deklaruje alespoň jeden
`expectedContainerUUID`, je povinné i u obou stran každého páru. `pilotRoot` musí ležet pod
`/Volumes/…` nebo `/private/tmp/…`. Neznámé klíče, duplicitní JSON klíče a více než dva páry se
odmítají. Cílené `diskutil info` musí obsahovat platné APFS `DeviceIdentifier`/`VolumeUUID`
a souhlasit s `apfs list`; chybějící metadata znamenají exit 6, rozporná identita exit 5.
Duplicitní plist klíče, volume devices/UUID a container UUID, chybné typy kapacit/rolí,
neúplné nebo chybně typované `Bootable`/`Writable`/`APFSSnapshot`/`Sealed` metadata a nečitelná,
neúplná nebo nerozpoznaná mount tabulka znamenají exit 6. Každá neprázdná role je pro pilot
zakázaná, včetně neznámé budoucí role. XML i binary plisty jsou podporované.
Gate `mount-consistency` odmítá rozpor přímých mountů mezi `diskutil info` a mount tabulkou.
`target-not-active` kontroluje všechny pozorované mounty targetu včetně snapshot mountů.

Výstup nesmí být totožný s plánem, receiptem ani čtenou metadata fixture (ani přes alias nebo
hardlink). Existující výstup musí být vlastní regular file s přesným mode 0600, i pokud jsou jeho
bytes shodné. Kolize nebo nebezpečný existující výstup znamenají exit 2 bez přepsání vstupu.
Jiný existující obsah se také odmítne: změněný plán nebo nové pozorování potřebuje nový out-dir.
Kompletní 0600 soubor se publikuje atomickým exkluzivním `link`, takže ani souběžně vložený
objekt nebude přepsán; vlastní dočasný soubor se uklidí. Toto není durable recovery deník ani
důkaz odolnosti vůči výpadku napájení. Opakovaný shodný plán nemění bytes, inode ani mtime.

Vstupy a výstupní adresář se otevírají přes directory descriptory s `O_NOFOLLOW` v každé
komponentě, včetně předků; soubory musejí mít jedno hardlink jméno. Group/world writable předek
se odmítá kromě root-owned sticky adresáře, např. `/private/tmp`, pod kterým musí být vlastní
privátní strom. Plán/receipt/fixture se validuje přes otevřený descriptor; receipt se hashne ze
stejných bytes, které se validovaly. Cesty s `..` a nenormalizovaný `pilotRoot` se odmítají.

Zálohový receipt `sanjbox.apfs-pilot.backup-receipt.v1` (max 16 KiB), povinný jen pro `--apply`:

```json
{
  "schema": "sanjbox.apfs-pilot.backup-receipt.v1",
  "pilotId": "wp1-b4-p0",
  "transactionLabel": "T-20261107-01",
  "planSha256": "<pilot.planSha256 ze shodného dry-runu>",
  "createdAt": "2026-11-07T12:00:00Z",
  "backupLocation": "/Volumes/Backup/synthetic-pilot",
  "backupDigest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "coversDevices": ["disk9s1", "disk9s2"]
}
```

`coversDevices` musí být nadmnožinou všech zařízení z plánu. `backupDigest` je volitelné pole ve tvaru
`sha256:` + 64 malých hex znaků; jiný tvar je odmítnut exitem 4. Receipt je záznam o záloze, kterou
uživatel skutečně vytvořil; skript zálohu neověřuje ani ji netvoří. `createdAt` musí být skutečně
platné kalendářní datum a UTC čas, ne pouze text správného tvaru.
`planSha256` je povinný hash přesného kanonického vstupního plánu (64 malých hex znaků), který
dry-run vypisuje v `pilot.planSha256`; změna UUID při zachování BSD locatoru proto starý receipt
zneplatní. Starý receipt bez tohoto pole se odmítne exitem 4. Datum v budoucnosti, null digest,
prázdný, neplatný nebo příliš velký JSON receipt se rovněž odmítne exitem 4.
Skript nemá časovou expiraci receiptu a nezná změny obsahu zálohovaných dat. Stáří, čerstvost,
skutečnou existenci a obnovitelnost zálohy musí uživatel znovu ověřit; hash plánu je nedokazuje.

## Kroky pro uživatele (L3)

1. **Předregistruj slot.** V [docs/LAB.md](../../docs/LAB.md) §3 zafixuj run-id, commit metodiky,
   konkrétní container/volume UUID, device locatory, role, mountpointy, kvóty, mapping A/B na role
   B3 a oracle. Skript slot nerezervuje ani neověřuje; bez slotu pilot nezačínej.
2. **Připrav zálohu a receipt.** Zazálohuj vše, co bude `--erase` na targetu měnit, a vytvoř receipt
   s digestem/umístěním zálohy. Bez receiptu `--apply` odmítne.
3. **Dry-run.** Vlastní `--out-dir` musí mít přesně mode 0700 (skript jiný mode odmítne) a plán:

   ```bash
   spikes/s4-state/apfs-pilot.sh \
     --plan /private/tmp/MY-OWN-B4-RUN/plan.json \
     --out-dir /private/tmp/MY-OWN-B4-RUN/out
   ```

   Zkontroluj `preState` (boot UUID, container UUID, volume UUID/role, kvóty, mountpointy),
   `gates` a `steps`. Exit 0 = gates prošly. Exit 5 = některý gate `fail` nebo `inconclusive`
   (např. plán bez deklarovaných UUID), nic nespouštěj. Exit 6 = metadata nešla přečíst.
   Exit 2 = chyba vstupu/argumentů. Exit 4 = odmítnutý apply/backup.
4. **Ověř G1 a G2.** Snapshot creation path (`P0-G1`) a whole-UID interlock (`G2`) musí být doložené
   v P0/S0. Plánovač pro ně schválně negeneruje žádné argv; `snapshot-create`, `snapshot-mount`,
   `switch-writable-state` mají `argv: null` s důvodem v `decision`/`reason`. Krok
   `asr-switch-support` (`P0-G3`) výslovně vyžaduje ověřit, že tvůj `asr` zná `--toSnapshot`,
   `--useReplication` a `--erase`; `asr help` je neuvádí, takže nestačí ho pouze přečíst.

5. **Hand-off.** Po kontrole spusť stejný příkaz s `--apply --i-understand --backup-receipt …`.
   Výstup `mode: apply-handoff` znamená pouze vytištěný návrh runbooku; není schválením mutací,
   důkazem čerstvé zálohy ani povolením startu. G1–G3 a aktuální identity stále ověřuje uživatel.
6. **Proveď P1/P2 ručně.** Každý vypsaný příkaz spouštěj sám, po jednom, po opětovné kontrole
   konkrétního zařízení. `asr restore` je template: `<snapshot-uuid-from-P1>` nahraď tuplem z P1 a
   před potvrzením erase promptu znovu ověř target. Žádný `--noprompt` ani force-unmount.
7. **Úklid.** Teprve po uzavření P2/P3 a kontrole „nic neběží, oblast je fully-off, snapshoty nejsou
   mounted“ použij `cleanup.steps` v opačném pořadí závislostí: vlastní snapshot mount → vlastní
   `deleteSnapshot … -uuid <snapshot-uuid-from-P1> -wait` (`-wait` proto, že mazání může pokračovat po návratu; `rootRequired` je
   `true`, protože tento systém ownership vyžaduje) → finální `diskutil apfs list -plist`. Target bez
   doložené completion zůstává v karanténě, nemaže se.
   Parent device je také placeholder: znovu ověř celý container/parent/snapshot UUID/XID/name tuple
   proti vlastnímu receiptu, nikdy nemaž podle shody názvu nebo starého BSD locatoru. Již chybějící
   vlastní objekt přeskoč; konflikt nebo neuzavřený intent znamená stop a zachování objektu.
8. **Publikuj běh** jako nový `docs/evidence/…` podle GUIDE §7; uzavřené běhy jsou neměnné.

## Význam výsledku

| Exit / stav | Význam |
|---|---|
| 0 | Metadata a všechny deklarované identity jsou konzistentní; `verdict.gatesPassed: true`. **Žádný** verdikt izolace ani rollbacku. |
| 2 | Chyba vstupu/argumentů: neznámý argument, plán nebo receipt s neexistujícím souborem, symlinkem, cizím vlastníkem, group/world write nebo neprivátním rodičovským adresářem, out-dir bez 0700, existující výstup bez vlastnictví/0600, kolize vstupu s výstupem, neplatný plán/JSON, I/O chyba; nic se nezapsalo. |
| 4 | Odmítnutý apply/backup: chybí ack/receipt, fixture apply, receipt schema/typ/digest/createdAt/pilot/transaction/coverage/size, nebo apply plán bez povinných UUID; nic se nezapsalo. |
| 5 | `fail`/`inconclusive` gate: neshoda UUID, system/boot/role svazek, aktivní target, rozpor mountů mezi sondami, neověřená identita. |
| 6 | Read-only metadata nešla přečíst nebo chybí platná identita v `diskutil info`; výsledek je neplatný, ne úspěch. |
| `warn` | Otevřený návrh (kterákoli kvóta 0 = unbounded, chybějící receipt v dry-run); exit může být 0. |
| `manual` | `whole-uid-interlock`: G2 musí doložit uživatel v L3; planner na něm negatuje ani nepředstírá pass. |
| `inconclusive` | `identity-match` bez deklarovaného UUID: nic se neporovnalo, `verdict.identityChecked` je `false`, exit 5. |

Tabulka exit kódů je závazná a testovaná v `ExitCodeContractTests`: chybějící/neznámý klíč receiptu
nebo špatný typ = 4; neexistující soubor, symlink a 0666 = 2. `verdict.realStartAllowed` je vždy
`false`, `diskMutated` vždy `false`. Skript nedokazuje APFS snapshot, writable restore, mount switch,
crash/reboot recovery ani úklid skutečných objektů.

## Testy a hranice

```bash
bash -n spikes/s4-state/apfs-pilot.sh
/usr/bin/python3 -I -B -m unittest discover -s spikes/s4-state -p 'test*.py' -v
```

Syntetické testy v `spikes/s4-state/tools/test_apfs_pilot.py` zkoušejí dry-run i apply hand-off
včetně odmítnutí. Apply používá pouze recording shimy; žádný skutečný APFS ani mutující příkaz
se nespouští. Testy používají vlastní `/private/tmp/sanjbox-b4-apfs-tests.XXXXXX` fixtures a recording
shimy, které jakýkoli jiný než dokumentovaný read-only argv odmítnou. Ověřují `bash -n`, že dry-run
vytvoří jen deklarovaný výstupní soubor, schéma JSON, determinismus (druhý běh je byte-identický a
soubor se nepřepíše), odmítnutí `--apply` bez ack/receiptu, povinné UUID pro apply, inconclusive
identity v dry-runu, exit kódy vstupu/receiptu, kvóty, mode adresářů, digest receiptu a to, že živá
sonda volá pouze read-only příkazy. Regrese navíc odmítají rozpornou/chybějící identitu z info,
rozporné nebo aktivní mounty, kolize vstupu s výstupem, nebezpečný mode shodného výstupu,
neplatné typy `coversDevices` a neexistující UTC datum. Neověřují skutečné APFS chování,
oprávnění ani `asr`.

### Důvěryhodné prostředí a izolace testů

Distribuovaný skript **odmítá** nastavené `APFS_PILOT_DISKUTIL`, `APFS_PILOT_SYSCTL`
a `APFS_PILOT_MOUNT`, a to i v fixture režimu. Živé sondy mají pevné cesty
`/usr/sbin/diskutil`, `/usr/sbin/sysctl`, `/sbin/mount`; Python je `/usr/bin/python3 -I -B`
a shell nastavuje systémový PATH. Program se nestává read-only tím, že dostane read-only argv.
Testy recording sondy a pozitivního apply hand-off vytvářejí vlastní dočasnou **kopii skriptu**
a mění jen tyto tři přesně kontrolované literály na shimy odmítající jiné argv. Fault injection
publication/open závodů rovněž existuje jen v testové kopii, bez produkčního přepínače.
Tyto výsledky zůstávají mock; fixture režim má `probe.source: fixture-mock` a apply jej odmítá.

Planner předpokládá důvěryhodný host shell, systémové binárky a výlučný privátní workspace:
nechrání před kompromitovaným stejným UID, administrátorem ani ACL poskytujícími cizí zápis.
Kontroly POSIX mode nejsou audit ACL. `pilotRoot` je lexikální deklarace, nikoli důkaz identity
namountovaného filesystemu; před ruční mutací musí uživatel znovu ověřit skutečné objekty.
Jednotlivé metadata sondy nejsou atomický snapshot ani quiescence witness. Nepodporované
metadata se odmítají; jejich skutečný tvar na cílovém macOS se musí připnout v L3.
