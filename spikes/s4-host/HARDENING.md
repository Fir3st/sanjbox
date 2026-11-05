# S4 — omezené zpevnění a uninstall (WP1.B2, částečně)

`harden-host.sh` a `uninstall.sh` spouštějí nativní Swift CLI bez externích závislostí. Oba mají
**výchozí dry-run**. B2 implementuje konzervativní podmnožinu: změnu mode explicitně vybraných vlastních
adresářů na `0700` podle metadat [B1 reportu](README.md), trvalý deník a podmíněné vrácení vlastní změny.
**ACL se nikdy neupravuje. B2 zůstává částečný; S4, R2/R7, RB-09 a RB-10 zůstávají Neověřeno.**

## Rozsah a odmítnuté operace

- Plán obsahuje 1–16 ID kořenů z B1 reportu; mění se pouze jejich položka `.`. Žádná rekurze,
  automatické hledání kořenů ani výchozí home. Překrývající se kořeny se odmítají.
- Podporován je adresář vlastněný skutečným/efektivním volajícím (shodné nenulové UID), owner mode
  `0700`, bez special mode bitů a file flags; group/other bity mohou být odstraněny. Již `0700`
  je odmítnuto jako změna, kterou tento běh nemůže vlastnit. Vlastník, skupina a ACL se nemění.
- Pouze lokální zapisovatelný APFS s účinným vlastnictvím. Read-only APFS ancestor je povolen,
  read-only cíl ne. ExFAT/FAT, síťové FS, unknown ACL/mount a libovolné ACL entries/flags jsou odmítnuty.
  To zahrnuje běžný home s existující ACL: nástroj ji nesmaže, nepřepíše ani neprohlásí za bezpečnou.
- Každá komponenta cesty je připnutá descriptor-em a má prázdnou ACL. Ancestors musí vlastnit root nebo
  volající a nesmějí být group/world writable; výjimkou je rootem vlastněný sticky adresář, například
  `/private/tmp`. Kořen `/`, nenormalizované cesty, symlinky, hloubka nad 64 a omezené názvy z B1
  jsou odmítnuty. Root/setuid spuštění není podporováno. Skripty nespouštějí `sudo`.
- Nejsou podporovány soubory, hardlinky na soubory, sockety, FIFO, zařízení, ACL deny/inheritance,
  mounty, kvóty, účty, služby, nastavení systému, Keychain ani databáze. Žádný obsah chráněných dat
  se nečte; čtou se pouze explicitní vlastní schema vstupy a vlastní deník.

**[implementátor]** Veškeré skutečné změny a simulované konflikty při automatických testech jsou
v nových vlastních syntetických `/private/tmp/sanjbox-b2-tests.XXXXXX`. Žádné host home či osobní
projekty se nezpevňují. **[uživatel]** Použití na skutečném chráněném kořeni vyžaduje samostatně
zkontrolovaný konkrétní plán a uživatelské spuštění, zálohu a odpovídající laboratorní postup GUIDE.

## Sestavení a vstupy

Z kořene repozitáře:

```bash
swift build -c release --package-path spikes/s4-host
s4_b2_bin_dir="$(swift build -c release --package-path spikes/s4-host --show-bin-path)"
export SANJBOX_HOST_HARDEN_BIN="$s4_b2_bin_dir/sanjbox-host-harden"
spikes/s4-host/harden-host.sh --help
```

Wrapper sám nekompiluje. Bez override očekává Swift 6.4 swiftbuild layout
`.build/out/Products/Release/sanjbox-host-harden`; pro jiný layout použij přesnou absolutní cestu
výše. Shell používá `#!/bin/bash`, `set -euo pipefail` a žádné `eval` ani interpolované příkazy.

Očekávání `*.s4-expect.json` má stejné schema jako B1 a ověří skutečné/efektivní UID/GID, požadované
skupiny, launchd manager a audit session **před čtením plánu, baseline či deníku**. Nesoulad vrací
kód 3 a jen identity report. Baseline je vlastní `*.s4-report.json` z B1; musí mít platnou identitu,
shodné real/effective UID a audit session. Vybrané root metadata musí přesně souhlasit s aktuálním
stat/ACL/mount. Neúplná enumerace B1 při `maxDepth: 0` nevadí: B2 nepřisuzuje žádnou ochranu potomkům.
Chybějící či neznámá metadata vybraného kořene jsou vždy odmítnuta.

Vlastní `run.s4-harden.json` (max. 64 KiB; soubor není group/world writable, symlink ani hardlink):

```json
{"schema":"sanjbox.host-harden.plan.v1","roots":["synthetic"],"mode":448}
```

`448` je JSON desítkový zápis `0700`; žádný jiný výsledný mode není povolen. ID `synthetic` musí
existovat v baseline. Stejně jako v B1 jsou schema vstupy důvěryhodné vlastní soubory, nikdy
nalezené soubory z chráněného stromu. Nejde o autentizaci souboru příponou.

## Dry-run, apply a uninstall

**[uživatel]** Připrav samostatný existující run directory s mode `0700`, prázdnou ACL a vlastnictvím
volajícího. `--state` musí končit `/state`; při hardeningu ještě nesmí existovat. Run directory,
jeho `state` ani cíl se nesmějí překrývat. Cesty v příkladu jsou záměrně neexistující zástupné hodnoty:

```bash
spikes/s4-host/harden-host.sh \
  --expect /private/tmp/MY-OWN-S4-RUN/run.s4-expect.json \
  --baseline /private/tmp/MY-OWN-S4-RUN/run.s4-report.json \
  --plan /private/tmp/MY-OWN-S4-RUN/run.s4-harden.json \
  --state /private/tmp/MY-OWN-S4-RUN/state
```

Dry-run nic nevytvoří ani nepřepíše. JSON vypíše přesné cesty, aktuální `before` včetně původního
mode, ancestry metadata a nový mode. `--dry-run` lze uvést explicitně. Pro skutečné použití
**[uživatel]** zkontroluje tento výstup a stejný příkaz spustí s `--apply --acknowledge-quiescent`.
Druhý přepínač je výslovné potvrzení provozní podmínky klidného jmenného prostoru, **nikoli technický
zámek nebo důkaz quiescence**. Bez něj je `--apply` usage error. Dry-run a apply nelze kombinovat.

```bash
spikes/s4-host/uninstall.sh \
  --expect /private/tmp/MY-OWN-S4-RUN/run.s4-expect.json \
  --state /private/tmp/MY-OWN-S4-RUN/state
```

Uninstall ve výchozím dry-run otevře a zamkne již existující deník, nic do něj nezapisuje.
JSON `before.stat.mode` označuje původní mode každé změny. Po kontrole **[uživatel]** přidá stejné
`--apply --acknowledge-quiescent`. Všechny aktuálně obnovitelné položky se předem ověří, takže
předem viditelný konflikt kterékoliv položky zabrání všem obnovám tohoto spuštění.
Při závodu/pádu během sekvence mohou být některé položky již změněny; nejde o atomickou transakci.

| Kód | Význam |
|---|---|
| 0 | Dokončený preview/apply/restore nebo idempotentní stav již obnovených/neprovedených změn; žádný verdikt izolace |
| 3 | Nesoulad identity/session; žádný přístup k plánu/baseline/state |
| 4 | Konflikt nebo nepodporovaný stav; JSON obsahuje důvod, deník se zachová |
| 2 | Usage, schema vstupu nebo I/O chyba; stderr; deník případně už existuje a musí zůstat zachován |

## Trvalý deník a pravidla obnovy

Soukromé `state/` vznikne exkluzivně s mode `0700`. `lock` a všechny JSON záznamy vznikají exkluzivně
s mode `0600`, jediným hardlinkem a prázdnou ACL. Žádný záznam se nepřepisuje a `state` se nerecykluje.
`flock(LOCK_EX | LOCK_NB)` brání souběhu spolupracujících procesů nad týmž deníkem. Není to globální
zámek cílů mezi různými deníky, ani obrana proti důvěryhodnému host procesu se stejným UID.

1. `manifest.json` zaznamená UUID transakce, boot session UUID, UID, identitu/cestu deníku a všech
   cílových kořenů, původní stat/ACL/mount, birth time/generation a ochranu/identitu ancestorů.
2. `NN-intent.json` se plně zapíše a flushne **před** `fchmod`. Zápis používá `fsync` + `F_FULLFSYNC`,
   poté `fsync` adresáře a znovu `F_FULLFSYNC` souboru; selhání flush znamená konec bez další mutace.
3. Po opětovné kontrole cesty a původního stavu proběhne `fchmod` pouze na připnutém descriptoru.
   Ověří se výsledek a vazba do parenta, `fsync` cíle, potom vznikne trvalý `NN-applied.json`
   s přesným skutečným stavem po změně. Měnit se smí pouze mode a automatické ctime.
4. Restore vyžaduje přesný zaznamenaný `applied.after` včetně ctime, owner/group, link count,
   flags, birth time/generation, ACL a mount. Ancestors musí mít shodnou identitu a ochranu.
   Jejich ctime/link count nejsou stabilní, protože se mění i vytvořením nesouvisejícího sourozence.
5. Před restore vznikne `NN-restore-intent.json`; po ověření, `fchmod`, kontrole a flush
   `NN-restored.json`. Při opakovaném uninstallu se dokončeně obnovený cíl už nemění ani
   nepovažuje za vlastněnou změnu, i když na něm uživatel později něco změnil.

Čtení je omezené na 1 MiB na záznam, nejvýše 66 položek v deníku. Neočekávané soubory, symlinky,
hardlinky, nesprávná ochrana, neplatné přechody a identity se odmítají. Deník musí mít **přesně
kanonické JSON bytes vytvořené nástrojem** (sorted keys a koncový newline): decode/encode shoda
odmítne duplicitní i neznámé klíče včetně nested objektů, jiné formátování i částečný zápis.
Přes boot session se automatická obnova nepovoluje. Deník není podepsaný ani chráněný proti
přepsání host vlastníkem; musí zůstat důvěryhodným host artefaktem.

**Intent bez odpovídajícího completion je nejednoznačný.** Ani shoda aktuálního mode s `0700` nebo
původním mode nedokazuje, kdo změnu provedl. Uninstall odmítne automatickou obnovu, i kdyby pád
nastal těsně před `chmod` a ke změně ve skutečnosti nedošlo. Záznam poškozený či chybějící po
procesním pádu má stejné pravidlo. Neexistuje přepínač force, implicitní resume ani automatický
rollback. Zachovej celý run/state a metadata pro samostatnou uživatelskou kontrolu; neodstraňuj
pending záznamy za účelem vynucení obnovy.

## Konflikty, závody a nepokryté garance

Pozdější legitimní změna práv, ACL, vlastníka, flags, mountu nebo inode se nepřepíše, **pokud ji
zaznamenané kontroly pozorují**. Změna mode pryč a zpět se rozpozná změněným ctime. I obyčejné přidání
podadresáře může změnit ctime cíle a konzervativně zabránit obnově. Náhrada parent inode je konflikt,
i když do nového parenta někdo přesune původní cílový inode. Při pooperaci zjištěném závodě se
neprovádí automatické vracení, které by mohlo přepsat další změnu.

**`fchmod` nemá atomický compare-and-swap.** Závod v posledním intervalu mezi kontrolou a syscall
může změnit práva, která syscall následně přepíše, nebo přesunout připnutý inode, na němž syscall
stále působí. Kontrola po operaci takový zásah neumí vzít zpět a krátký ABA závod může uniknout.
Ani birth time/generation ani kontrola ancestry nejsou atomický namespace snapshot. Vyžadovaný
klidný host namespace je provozní omezení tohoto prototypu, nikoli uzavřený TOCTOU důkaz pro S4/S8.

Native testy dokazují chování na vlastních syntetických adresářích v dané konfiguraci. Náhlé `_exit`
ověřuje procesní přerušení mezi mutací a completion záznamem; fyzický výpadek napájení, chyby zařízení,
APFS crash recovery a flush failure nejsou tímto testem prokázány. Metadata syscall může blokovat;
počet/velikost/hloubka nejsou hard wall-clock timeout.

| Akceptační případ | Dodaný podklad | Zbývá |
|---|---|---|
| RB-09 | Native mode/ACL drift, ABA ctime, inode/parent změny; uninstall konflikt bez přepsání pozorované změny | Skutečný laboratorní důkaz, souběh oblastí, poslední check/syscall race |
| RB-10 | Mode-only before/after deník, přesný restore, idempotence, odmítnutí nejednoznačného přerušení | ACL hardening/restore a kompatibilita host nástrojů po změně home |
| FS-10/11, R2 | Žádné průběžné vynucování | Nová data, přesuny/obnovy, instalace, nové/odemčené mounty a nulové okno přístupu |

Audit ani tento jednorázový hardening neprokazují efektivní přístup, TCC/IPC ochranu, existující otevřené
fd, životní cyklus ani průběžnou ochranu R2. Chybějící mechanismus zůstává blokátorem, ne přijatým reziduem.

## Ověření a úklid

[VALIDATION-B2.md](VALIDATION-B2.md) uvádí skutečné lokální příkazy, konfiguraci, výsledky i neúspěšné
vývojové pokusy. Testy používají jen vlastní syntetická data; nejsou evidence uzavírající bránu.
Každý test ověřuje před cleanup přesnou `mkdtemp` cestu, UID, typ, mode a původní device/inode
kořene. Testovací podsložky, kanárky i deníky se odstraní pouze uvnitř této ověřené fixture.
Při přerušeném test runneru se zachová konkrétní fixture k samostatné kontrole; žádné glob cleanup.

Produkční uninstall **nikdy nic nemaže**: zachová deník a nemá rozsah odstranění uživatelů, svazků
či položek aplikace. Případné smazání vlastního run directory po review je samostatný uživatelský
krok. Nezahazuj deník u neobnoveného či konfliktního zásahu.

Implementace ověřila deklarace v lokálním SDK `sys/fcntl.h` (`O_NOFOLLOW_ANY`, `F_FULLFSYNC`),
`sys/stat.h` (`fchmod`, birth time/generation), `sys/acl.h` a `sys/mount.h`. Nativní test ukázal,
že kombinace `O_NOFOLLOW | O_NOFOLLOW_ANY` je na této konfiguraci odmítnuta; používá se samotné
`O_NOFOLLOW_ANY` a `O_DIRECTORY`. API opora není důkaz brány.
