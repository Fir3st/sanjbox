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
odmítnuto). Musí být 1–2 páry podle pilotního budgetu; všechny cesty a UUID jsou vlastní, ne
nalezené v cizím stromu.

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

`expectedVolumeUUID`/`expectedContainerUUID` jsou volitelné, ale pokud jsou uvedené, musí sedět na
pozorování, jinak je gate `identity-match` `fail`. `pilotRoot` musí ležet pod `/Volumes/…` nebo
`/private/tmp/…`. Neznámé klíče, duplicitní JSON klíče a více než dva páry se odmítají.

Zálohový receipt `sanjbox.apfs-pilot.backup-receipt.v1` (max 16 KiB), povinný jen pro `--apply`:

```json
{
  "schema": "sanjbox.apfs-pilot.backup-receipt.v1",
  "pilotId": "wp1-b4-p0",
  "transactionLabel": "T-20261107-01",
  "createdAt": "2026-11-07T12:00:00Z",
  "backupLocation": "/Volumes/Backup/synthetic-pilot",
  "coversDevices": ["disk9s1", "disk9s2"]
}
```

`coversDevices` musí být nadmnožinou všech zařízení z plánu. Receipt je záznam o záloze, kterou
uživatel skutečně vytvořil; skript zálohu neověřuje ani ji netvoří.

## Kroky pro uživatele (L3)

1. **Předregistruj slot.** V [docs/LAB.md](../../docs/LAB.md) §3 zafixuj run-id, commit metodiky,
   konkrétní container/volume UUID, device locatory, role, mountpointy, kvóty, mapping A/B na role
   B3 a oracle. Skript slot nerezervuje ani neověřuje; bez slotu pilot nezačínej.
2. **Připrav zálohu a receipt.** Zazálohuj vše, co bude `--erase` na targetu měnit, a vytvoř receipt
   s digestem/umístěním zálohy. Bez receiptu `--apply` odmítne.
3. **Dry-run.** Vlastní `--out-dir` (mode 0700, bez group/world write) a plán:

   ```bash
   spikes/s4-state/apfs-pilot.sh \
     --plan /private/tmp/MY-OWN-B4-RUN/plan.json \
     --out-dir /private/tmp/MY-OWN-B4-RUN/out
   ```

   Zkontroluj `preState` (boot UUID, container UUID, volume UUID/role, kvóty, mountpointy),
   `gates` a `steps`. Exit 0 = gates prošly. Exit 5 = některý gate `fail`, nic nespouštěj.
   Exit 6 = metadata nešla přečíst. Exit 2 = chyba vstupu/argumentů.
4. **Ověř G1 a G2.** Snapshot creation path (`P0-G1`) a whole-UID interlock (`G2`) musí být doložené
   v P0/S0. Plánovač pro ně schválně negeneruje žádné argv; `snapshot-create`, `snapshot-mount`,
   `switch-writable-state` mají `argv: null` s důvodem v `decision`/`reason`.
5. **Hand-off.** Po kontrole spusť stejný příkaz s `--apply --i-understand --backup-receipt …`.
   Výstup `mode: apply-handoff` znamená jen „runbook je schválený k ručnímu provedení“.
6. **Proveď P1/P2 ručně.** Každý vypsaný příkaz spouštěj sám, po jednom, po opětovné kontrole
   konkrétního zařízení. `asr restore` je template: `<snapshot-uuid-from-P1>` nahraď tuplem z P1 a
   před potvrzením erase promptu znovu ověř target. Žádný `--noprompt` ani force-unmount.
7. **Úklid.** Teprve po uzavření P2/P3 a kontrole „nic neběží, oblast je fully-off, snapshoty nejsou
   mounted“ použij `cleanup.steps` v opačném pořadí závislostí: vlastní snapshot mount → vlastní
   `deleteSnapshot … -wait` (`-wait` proto, že mazání může pokračovat po návratu) → finální
   `diskutil apfs list -plist`. Target bez doložené completion zůstává v karanténě, nemaže se.
8. **Publikuj běh** jako nový `docs/evidence/…` podle GUIDE §7; uzavřené běhy jsou neměnné.

## Význam výsledku

| Pozorování | Význam |
|---|---|
| exit 0, `verdict.gatesPassed: true` | Metadata a deklarované identity jsou konzistentní; **žádný** verdikt izolace ani rollbacku |
| `gates[*].status: warn` | Otevřený návrh (kvóta 0 = unbounded, chybějící receipt v dry-run) |
| `gates[*].status: manual` | `whole-uid-interlock`: G2 musí doložit uživatel v L3; planner na něm negatuje ani nepředstírá pass |
| exit 5 | `fail` gate: neshoda UUID, system/boot/role svazek, aktivní target, chybějící receipt |
| exit 4 | Odmítnutý apply/backup; nic se nezapsalo |
| exit 6 | Read-only metadata nešla přečíst; výsledek je neplatný, ne úspěch |

`verdict.realStartAllowed` je vždy `false`, `diskMutated` vždy `false`. Skript nedokazuje APFS
snapshot, writable restore, mount switch, crash/reboot recovery ani úklid skutečných objektů.

## Testy a hranice

```bash
bash -n spikes/s4-state/apfs-pilot.sh
/usr/bin/python3 -I -B -m unittest discover -s spikes/s4-state -p 'test*.py' -v
```

Syntetické testy v `spikes/s4-state/tools/test_apfs_pilot.py` nikdy nespouštějí apply cestu ani
mutující příkaz: používají vlastní `/private/tmp/sanjbox-b4-apfs-tests.XXXXXX` fixtures a recording
shimy, které jakýkoli jiný než dokumentovaný read-only argv odmítnou. Ověřují `bash -n`, že dry-run
vytvoří jen deklarovaný výstupní soubor, schéma JSON, determinismus (druhý běh je byte-identický a
soubor se nepřepíše), odmítnutí `--apply` bez ack/receiptu a to, že živá sonda volá pouze read-only
příkazy. Neověřují skutečné APFS chování, oprávnění ani `asr`.
