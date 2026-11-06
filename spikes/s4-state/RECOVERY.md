# WP1.B4 — recovery protokol a file-backed mock (částečně)

B4 dodává přísný stavový automat snapshot → nový zapisovatelný stav → postupné přepnutí → ověření,
trvalý host-control deník a testy pádu procesu. **Jediný adaptér je syntetický file-backed mock.**
Nevytváří APFS snapshot, nepřipojuje svazek, nezastavuje procesy a nemůže povolit skutečný start.
B4 zůstává **částečný**; RB-02…08, R2/R7 a brána S4 zůstávají **Neověřeno**.

Samostatná [APFS feasibility studie](research/wp1-b4-apfs/README.md) (2026-11-06) mapuje tento
model na primární SDK/man a Apple zdroje. Dokumentovaným kandidátem pro nový writable stav je
`asr` snapshot replication; samotný snapshot mount zůstává read-only a in-place revert nesplňuje
B3 prepare-then-switch strategii. Snapshot UUID se při replication může opakovat na jiném parent
svazku, takže nativní receipt musí zahrnout rodičovskou identitu. Studie dodává
[podmíněné uživatelské experimenty](research/wp1-b4-apfs/EXPERIMENTS.md), nikoli nativní adaptér:
oprávnění snapshot creation, whole-UID admission a crash/reboot completion zůstávají neprokázané.

B3 [manifest/schema](SCHEMA.md), příklady, validátor a předchozí důkazy zůstávají beze změny.
Koordinátor přijímá stejnou úplnou restore unit a odmítá backend s jinou množinou svazků. Deklarované
mountpointy se nikdy neotevřou. B2 není závislostí; společný balík poskytuje jen kontrolu identity CLI.

## Oddělení modelu, nativních souborů a neimplementovaných adaptérů

| Část | Co se skutečně děje | Co tím není prokázáno |
|---|---|---|
| `RecoveryCoordinator` | Přísné pořadí, připravenost všech svazků, durable intent/completion, odmítnutí konfliktů a neúplného stavu | Atomická obnova více svazků ani skutečný start gate |
| `RecoveryStore` | Native descriptor-relative I/O, soukromé soubory, zámek, flush, identity a bounded JSON | Root-owned control izolovaný od UID oblasti, power-loss durability |
| `FileBackedRecoveryMock` | Malé JSON obrazy kanárků a JSON selektory; snapshot/restore jsou nové syntetické záznamy | APFS snapshot/clone, mount/switch, filesystem ani aplikační konzistence |
| Lifecycle witness | Mock model whole-UID, blokování nových spuštění/sítě, fully-off, uzavřených fd/mappingů | Žádné skutečné PID, launchd, fd, mappings nebo síť se nekontrolují/neovládají |

JSON model obsahuje kanárky všech deklarovaných rolí; workload je změní a přidá **neaktivní řetězec**
startup/jobu pod home. Neinstaluje plist ani LaunchAgent. Obnova vyžaduje přesnou shodu původních
entries, tedy i odstranění této modelované perzistence. Všechna data jsou generovaná; žádný obsah
home, projektu, cache, databází či Keychain se nečte. Externí účinky se neobnovují.

## Stavový automat a fail-closed pravidla

Jeden běh obslouží jednu úplnou snapshot sadu a jednu obnovu. Svazky jsou řazeny podle stabilních
ID z manifestu, nejvýše 16. Deník musí odpovídat přesně prefixu této posloupnosti:

```text
begun (všechny původní binding receipts)
  [snapshot-intent(V) → vytvoření modelu → snapshot-done(V)] pro každý V
snapshot-ready
  ... jediná hranice, na níž je dovolena pozdější modelovaná práce oblasti ...
restore-begun (všechny aktuální binding receipts)
  [prepare-intent(V) → nový restored obraz + next selektor → prepare-done(V)] pro každý V
  [switch-intent(V) → náhrada jednoho selektoru → switch-done(V)] pro každý V
verified
```

- Před `begun` a každým snapshot krokem musí adaptér vydat a znovu validovat whole-UID witness,
  blokování admission a sítě. Pouhé zastavení vybraných PID nemá v protokolu cestu k úspěchu.
- Obnova navíc vyžaduje fully-off, uzavřené fd i mappings. Witness se ověřuje před a po mutaci;
  změna lease generation nebo ztráta některé podmínky zastaví postup. CLI nemá přepínač, kterým by
  uživatel mohl skutečné quiescence prohlásit za prokázané.
- Každý intent se zapíše a flushne před mutací. Každý completion až po mutaci a durable výsledku.
  Všechny obnovené obrazy/selektory musí být připravené před prvním přepnutím.
- Přepnutí je **sekvenční**, nikoli atomické. Po prvním ze dvou přepnutí existuje modelovaný smíšený
  stav. Ten je výslovně deny-start. `renameat` zde nahrazuje jen malý soubor selektoru v jednom
  soukromém adresáři; není to výměna svazků ani převod read-only snapshotu na writable mount.
- Každý další krok znovu ověří receipts všech relevantních snapshotů/připravených obrazů a všech
  aktuálně vybraných svazků, včetně již přepnutých. Host policy a manifest se ověřují při I/O.
  Pozdější změna obsahu, inode či metadata není přepsána, pokud ji kontrola pozoruje. ABA změna
  bindingu se stejnými bytes je konflikt přes ctime. Není žádné `force`.
- `verified` je poslední durable záznam. Ani jeho existence sama nestačí: `inspect()` znovu kontroluje
  deník, policy, manifest, bindingy, obrazy a lifecycle witness. Jen úplný konzistentní mock vrací
  `mockStartAllowed: true`; **`realStartAllowed` je vždy `false`**. Žádný launch API zde není.
- Chybějící, chybný, neúplný, smíšený nebo nečitelný stav znamená deny. Prázdný deník neznamená
  implicitní oprávnění ke startu. Start rozhodnutí je okamžitá kontrola, nikoli přenositelná capability.

## Restart a nejednoznačné mutace

Po procesu ukončeném `_exit(77)` nový koordinátor načte výhradně durable záznamy. Dokončené
checkpointy mohou pokračovat s novým platným witness. Při `snapshot-ready` lze zachytit aktuální
změněný workload do `restore-begun`; po této hranici je další drift konflikt. Dokončená obnova je
idempotentní a při opakování znovu ověřuje stav.

**Intent bez completion je nejednoznačný a automaticky nepokračuje.** To platí pro pád před syscall,
po vytvoření obrazu, po přípravě i po skutečné náhradě selektoru. Shoda nynějších bytes neprokazuje,
kdo změnu provedl. Prototyp zachová celý stav a vyžaduje samostatné posouzení; nemá automatický
abort, mazání orphanů, odhad výsledku ani návrat starých bindingů. Jde o bezpečnou karanténu, nikoli
obnovitelnost všech přerušení bez zásahu. Přes reboot se odmítá i jinak konzistentní deník.

## Host-control záznam a meze

Každý mock vytvoří exkluzivně `/private/tmp/sanjbox-b4-mock.XXXXXX` mode `0700`. Uvnitř jsou právě
sourozenci `control/` a `state/`, oba `0700`. `control/` obsahuje `identity.json`, `manifest.json`,
`policy.json`, `lock` a `000.json`…; `state/` obsahuje jen vlastní syntetické obrazy a selektory.
Control/policy se neobnovují. **Oba sourozence vlastní vývojářské UID**, nikoli root a oblast pod
různými UID: fyzická cesta je oddělená, bezpečnostní izolace zatím není implementovaná.

- Identity zahrnuje transaction UUID, boot session, UID, přesnou cestu a device/inode, birth time,
  generation, mode/GID soukromých adresářů; manifest/policy jsou připnuté receipts.
- Receipt souboru obsahuje device/inode, owner/group, mode, birth time/generation, ctime, velikost
  a SHA-256. Každé čtení ověřuje private regular single-link metadata, prázdnou ACL/flags, vazbu
  jména a stabilitu před/po. Symlinky ve vstupních cestách a FIFO jsou odmítnuté bez blokujícího read.
- Deník je append-only, exkluzivní `O_EXCL` create, `0600`, kanonický sorted-key JSON + newline.
  Hash chain váže pořadí na manifest a transakci; schema, exact phase, volume IDs a receipt names
  se kontrolují. Mezery v pořadí, unknown/duplicate JSON keys, změna hashů a cizí entries jsou chyba.
  Kanonické bytes ani správný hash samy o sobě nedokazují, že dřívější flush uspěl.
- Nejvýše 100 eventů (16 svazků), nejvýše 128 entries na adresář, nejvýše 64 KiB na JSON záznam,
  depth 16, 128 prvků/klíčů a 4096 B string podle společného B3 preflightu. Model images mají
  nejvýše 65 entries, path 1024 B a value 256 B. B3 vstup manifestu zůstává 256 KiB, ale mock jej
  pro uložení do control musí umět zakódovat do 64 KiB. Větší návrh konzervativně odmítne.
- Zápis: `fsync` + `F_FULLFSYNC` souboru, `fsync` jeho adresáře a adresářů kořene fixture i
  `/private/tmp`, znovu `F_FULLFSYNC`; chyba uzamkne aktuální instanci do deny, i když na disku
  již leží úplný `verified` záznam. Stejnou instanci nelze resetovat ani použít k úklidu.
- Nová zamčená instance před přijetím každého dosud neověřeného receipt provede znovu celý flush
  souboru a uvedených directory bindings. Před/po ověří přesný inode, metadata, ctime a obsah.
  Týká se lock souboru, identity, policy, manifestu, celého deníku i všech používaných snapshotů, obrazů a selektorů.
  `inspect()` tedy může provést durable I/O; není to jen čtení hashů. Opakovaná chyba znovu uzamkne deny.
- Úspěšný reflush celého konzistentního stavu umožní zotavení po předchozí chybě flush. Není to
  tvrzení, že původní flush uspěl. Neúplný/poškozený záznam a pending intent zůstávají odmítnuté.
  Cache platí jen pro přesný receipt úspěšně flushnutý v aktuální instanci; změna identity/bytes/ctime
  ji zneplatní. Tento postup vyžaduje stále tentýž důvěryhodný výlučný namespace.
- Záznamy se nepřepisují. `flock(LOCK_EX | LOCK_NB)` chrání souběh spolupracujících instancí.

Host namespace musí být důvěryhodný a výlučný. Hash chain není podpis ani ochrana proti přepsání
host vlastníkem. Descriptor checks nejsou atomický filesystem snapshot: mezi poslední kontrolou
bindingu a `renameat` může souběžný host proces změnit jméno; prototyp nemá atomic compare-and-swap.
Totéž platí pro finální check/unlink při teardown. Deník nezajišťuje OS zákaz spouštění po helper crash.
Skutečný adaptér musí vynucovat admission interlock mimo životnost helperu a držet jej od předběžné
quiescence po ověřený start; tato chybějící implementace zůstává blokátorem S0/S4.

## Použití a úklid

**[implementátor]** Sestavení a syntetické testy, z kořene repozitáře:

```bash
swift build -c release --package-path spikes/s4-state
swift test -c release --package-path spikes/s4-state
b4_bin_dir="$(swift build -c release --package-path spikes/s4-state --show-bin-path)"
export SANJBOX_STATE_RECOVERY_BIN="$b4_bin_dir/sanjbox-state-recovery"
spikes/s4-state/recovery-mock.sh --help
```

**[uživatel/implementátor]** Identita používá stejné vlastní `*.state-expect.json` jako
[B3 CLI](README.md#použití). Default je dry-run bez zápisů; `--apply` znamená pouze syntetický demo run:

```bash
spikes/s4-state/recovery-mock.sh mock-demo \
  --expect /ABSOLUTE/OWN/run.state-expect.json \
  --manifest /ABSOLUTE/OWN/run.state-manifest.json
# Požadované spuštění mocku: stejný příkaz s --apply.
```

CLI odmítne nesprávnou identitu/session před čtením manifestu nebo vytvořením fixture. Neexistuje
`apfs`, `mount`, `start`, libovolný output root ani příkaz ke změně skutečného host stavu.
Wrapper nekompiluje, nic neinicializuje a má `set -euo pipefail`.

Úspěšné demo odstraní jen svou generovanou fixture po kontrole přesné identity kořene i sourozenců,
pravidel souborů a absence cizích root entries. Opakovaný teardown již odstraněné přesné fixture je no-op; náhradní kořen se odmítne.
Teardown je flat descriptor-relative unlink, žádná
rekurze/glob ani mazání cizí cache. Při chybě demo zachová fixture a vypíše přesnou cestu; neúplný deník
se automaticky nemaže. Testy mají samostatný identity-checked teardown svých úmyslně poškozených
fixtures. Pád celého test runneru může ponechat fixture k samostatnému posouzení.

## Zbývající práce a akceptace

| Případ | Dodaný podklad | Stále chybí |
|---|---|---|
| RB-02/05 | Witness preconditions a stale/lost witness testy | Skutečné whole-UID quiescence, fork/job race, fully-off a fd/mapping closure |
| RB-03/04 | Restore všech rolí a odstranění inertního startup kanárku v JSON modelu | Native APFS writable reconstruction a skutečné kanárky/app crash consistency |
| RB-06/07 | 31 procesních crash bodů, 6 injected flush-error hranic, fresh-process deny/reflush recovery, smíšené bindingy | Skutečné APFS/device/power-loss chyby, reboot recovery, OS start interlock |
| RB-08 | Policy/manifest/control mimo modelovanou obnovu, kontrola driftu | Root ownership a nepřístupnost z UID oblasti, durable host-side produkční záznam |

Žádné automatické testy tohoto balíku neuzavírají bránu. Přesné příkazy, vývojové neúspěchy,
konfigurace a výsledky jsou v [VALIDATION-B4.md](VALIDATION-B4.md). Native APFS a lifecycle adaptéry
se musí navrhnout a ověřit na zvláštním testovacím svazku v uživatelském laboratorním slotu.
