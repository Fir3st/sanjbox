# S4 — manifest a topologie stavu (WP1.B3)

Tento balík dodává **návrhový manifest**, jeho offline validátor a syntetické příklady. Mapuje home,
projekt, prefix, cache, TMP a později runtime na plánované APFS svazky, mountpointy a společnou jednotku
obnovy. Obsahuje deklarace volume kvót/rezerv a samostatné hostem vlastněné policy/recovery úložiště.
**Nic nevytváří, nemountuje, nesnapshotuje ani neobnovuje.** Nepřistupuje k žádné cestě deklarované
v manifestu, a tedy neověřuje existenci svazku, kvótu, práva, úplnost zápisových cest ani rollback.

Výsledek `consistentDesign: true` říká pouze, že deklarace splňuje pravidla tohoto návrhu.
`deploymentReady` zůstává `false`, `observedTopology` je `not-inspected` a `acceptanceStatus` je
`Neověřeno`. **Hotový B3 není průchod S4 ani RB-01.** Balík nemá závislost na B1/B2, otevřených PR
ani případné živé topologii hosta; závisí pouze na lokálním `spikes/common` pro identitu validátoru.

| Požadavek / případy | Podklad z B3 | Co musí dodat další práce |
|---|---|---|
| R2/R7, RB-01 | Povinné role a plánované umístění všech deklarovaných kořenů | Skutečný inventář všech možných zápisů a enforcement mimo deklarované kořeny |
| RB-02…07 | Jednotka obnovy zahrnující všechny svazky, požadavek whole-UID quiescence a deny-start | B4: zapisovatelný obnovený stav, fd/mappingy, konzistence aplikací, crash recovery |
| RB-08 | Host policy/recovery explicitně mimo obnovované svazky | Skutečné vlastnictví, ACL, fyzická separace, durability a odolnost proti oblasti |
| FS-10/11, S4/S6 | Mountpointy, desired ownership, prefix a volume kvóty | Kontinuální ochrana, nové mounty, reálná APFS identita a kompatibilita nástrojů |
| R4/F4/S7 | Runtime explicitně odložený v MVP; samostatný návrhový příklad F4 | Volba runtime, skutečný storage/socket/mount rozsah a důkazy izolace |

## Návrhová topologie

[MVP příklad](examples/mvp.state-manifest.json) je kandidát se dvěma svazky. Všechny cesty,
UID/GID a velikosti jsou ilustrativní návrh; nebyly na hostu vytvořeny ani změřeny.

```text
logical container zone-pool (physical UUID a planning budget zatím neznámé)
├── state: /Volumes/Sanjbox/t001/state       návrh kvóty 64 GiB, reserve 0
│   ├── home                               celý home včetně startup/LaunchAgents
│   ├── project                            importovaný projekt a build výstupy
│   ├── cache                              explicitně přesměrované cache
│   └── tmp                                kandidát TMPDIR
└── tools: /opt/snj/t001                    návrh kvóty 16 GiB, reserve 0
    └── .                                  prefix

restore unit t001-full-state = state + tools
host control: /Library/Application Support/Sanjbox/control/t001
              policy.json + recovery.json — mimo restore unit
```

Dva svazky oddělují celý krátký prefix od home/projektu. Krátký prefix je kandidát podle PLAN,
**ne důkaz relokace bottles**; to musí prokázat S6. Kořeny `cache`/`tmp` jsou plán pro explicitní
přesměrování nástrojů, nikoli tvrzení, že nastavení `TMPDIR`/cache variables pokryje všechny aplikace.
Cache, nastavení a startup soubory, které aplikace dál zapisují pod home, zůstávají součástí celého home.

[F4 příklad](examples/f4.state-manifest.json) přidává svazek a roli `runtime` a používá
`declared-unverified`. Neaktivuje Docker ani neprokazuje jeho storage rozsah. V MVP je povinné
`deferred-f4` a runtime kořen je odmítnutý (C-002). V1 nepodporuje nested volumes ani overlapping
kořeny. Nepoužívá bind mount, symlink či firmlink jako cestu k propojení prefixu s jiným svazkem.

## APFS fakta a jejich hranice

APFS svazky sdílejí volné místo kontejneru; rezerva a kvóta jsou vlastnosti svazku. Rezerva vyjadřuje
minimální přidělitelnou kapacitu, kvóta horní limit. Kvóta není příslib dostupného místa — kontejner
může být plný dříve. Tyto vlastnosti neřeší CPU/RAM/GPU/DoS ani zápisy mimo dané svazky.
[Apple Disk Utility: APFS volumes](https://support.apple.com/en-ie/guide/disk-utility/dskua9e6a110/mac).

APFS snapshot je read-only kopie stavu jednoho svazku v čase; sám není připraveným zapisovatelným
stromem pro přepnutí. [Apple: APFS snapshots](https://support.apple.com/en-gb/guide/disk-utility/dskuf82354dc/mac).
Dvousvazkový návrh proto vyžaduje koordinaci B4, host-owned recovery záznam a zákaz startu při
neúplném přepnutí. Neexistuje zde předstíraný atomický skupinový snapshot nebo rollback.

`rename` vyžaduje tentýž filesystem; `RENAME_SWAP` není výměna APFS svazků a nelze jím převést
read-only snapshot mount na živý zapisovatelný stav. Opora: lokální SDK `rename(2)`/`renamex_np(2)`
a [Apple rename(2)](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/rename.2.html).
Kontrolováno také v lokálním Apple `diskutil(8)`: reserve nesmí překročit quota. B3 žádné uvedené
nástroje pro správu disků nespouští. Zdroje popisují API/FS; nedokládají průchod S4 na konkrétním Macu.

## Použití

**[implementátor]** Swift 6.x, macOS, žádné externí Swift balíčky. Cílový laboratorní kontrakt podle
GUIDE je macOS 27.x/Xcode 27.x. Package minimum macOS 15 není tvrzení o otestování na macOS 15.
Z kořene repozitáře:

```bash
swift build --package-path spikes/s4-state
swift test --package-path spikes/s4-state
bash -n spikes/s4-state/validate-state.sh
```

V omezeném vývojovém prostředí lze nasměrovat `CLANG_MODULE_CACHE_PATH`,
`SWIFTPM_MODULECACHE_OVERRIDE` a SwiftPM `--cache-path` do vlastních build/cache adresářů.
Použitý `--disable-sandbox` se týká SwiftPM buildu, nikoli privilegií validátoru.

Wrapper spouští hotovou binárku; sám nekompiluje. Výchozí cesta je Swift 6.4 swiftbuild
`.build/out/Products/Debug/sanjbox-state-manifest`. Pro jiný layout/configuraci:

```bash
state_bin_dir="$(swift build --package-path spikes/s4-state --show-bin-path)"
SANJBOX_STATE_MANIFEST_BIN="$state_bin_dir/sanjbox-state-manifest" spikes/s4-state/validate-state.sh --help
```

**[uživatel]** Připrav vlastní `*.state-expect.json` ve vlastním adresáři. Očekávání urči předem
podle role a relace procesu; `sanjbox-whoami` ze společného balíku může samostatně ukázat kontext.
Tato kontrola je pouze identita validátoru, **nikoli oracle topologie či izolace**. Všechny hodnoty
níže jsou ilustrační:

```json
{
  "schema": "sanjbox.state-expect.v1",
  "expectation": {
    "effectiveUID": 501, "realUID": 501,
    "effectiveGID": 20, "realGID": 20,
    "requiredGroups": [], "forbiddenGroups": [],
    "launchdManagerName": "Aqua", "launchdManagerUID": 501
  },
  "auditSessionID": 100123
}
```

Povinné jsou real/effective UID/GID, obě group lists (výslovně mohou být prázdné), launchd
manager name/UID a přesné audit session ID. Volitelně lze použít další pole `ProbeExpectation`
včetně window session, console a zakázaných audit sessions. Nesoulad ukončí běh před čtením manifestu.
Automatické testy si očekávání odvodí z vlastní identity pouze pro smoke test rozhraní.

```bash
spikes/s4-state/validate-state.sh \
  --expect /private/tmp/MY-OWN-STATE-RUN/run.state-expect.json \
  --manifest /ABSOLUTE/REPOSITORY/spikes/s4-state/examples/mvp.state-manifest.json
```

`--manifest` musí být vlastní schema soubor; příklad můžeš zkopírovat a upravit jako plán. Není nutné,
aby deklarované mountpointy existovaly. Validátor je ani neotevře. Výstup je jen JSON na stdout;
žádný příkaz ke spuštění, `eval`, export environment nebo deployment skript se negeneruje.
Shell wrapper má `#!/bin/bash` a `set -euo pipefail`. Nemá `--apply`: ve výchozím režimu nic nemění.

| Kód | Význam |
|---|---|
| 0 | Návrhová deklarace je konzistentní; všechny reálné důkazy stále Neověřeno |
| 1 | Sémanticky nekonzistentní návrh, JSON obsahuje konkrétní chyby |
| 2 | Použití, schema/type/ambiguity/limit/I/O chyba; žádný validační report |
| 3 | Neplatná identita/session, výstup pouze s kontrolou identity |

Výstup případně ulož s `umask 077` a `set -C` do **nového** souboru ve vlastním ověřeném
adresáři; nepřepisuj neověřenou cestu. CLI neotevírá výstupní soubory. Vstupní schema nesmí být
symlink v žádné komponentě cesty, musí patřit volajícímu, být regular file s jediným hardlinkem
bez group/world write a projít kontrolou identity/stability před/po čtení. Známé názvy tajemství,
Klíčenek/databází se jako vstupy odmítají. To je obranná výluka, nikoli detektor tajemství;
čti jen vlastní návrhové JSONy. Obsahy deklarovaných kořenů se nikdy nečtou.

## Schéma, meze a interpretace

Podrobný kontrakt je v [SCHEMA.md](SCHEMA.md); příklady jsou úplné strojově čitelné manifesty.
Neznámá pole a duplicitní dekódované JSON klíče (včetně `\u` aliasů) se odmítají. Vstup očekávání
má limit 32 KiB, manifest 256 KiB, depth 16, pole nejvýše 128 prvků, dekódovaný string 4096 B.
Sémantický model je přísnější: 8 kontejnerů, 16 svazků, 64 kořenů, 32 read-only vstupů;
normalizovaná či sestavená cesta nejvýše 1024 B. JSON report má tvrdý limit 1 MiB.

`requiredRolesDeclared` znamená jen přítomnost správného počtu povinných rolí dané fáze,
nikoli bezchybnost umístění nebo úplnost skutečných zápisů. `plannedRoots` ukazuje vypočtené
**řetězcové** cesty a restore unit; `plannedVolumes` deklarované APFS požadavky;
`containerBudgets` aritmetiku návrhu. Report vždy obsahuje další požadované důkazy.
Při chybě nejsou odvozené řádky podkladem ke spuštění žádné operace.

Část příkladů má nevyřešený planning budget; F4 také runtime quota. Jde o platné otevřené návrhy,
ne o garantované kapacity. Nulová rezerva je výslovně žádná rezervace. `limited` vyžaduje kladný
limit, `unbounded`/`unresolved` žádný limit (nikdy ne `0`). Součty jsou chráněné proti přetečení.
Rezervy nad deklarovaný planning budget jsou chyba; součet quota ceilings nad budget je varování
o oversubscription. Model nezjišťuje existující host svazky, metadata overhead, snapshot spotřebu,
reálnou volnou kapacitu ani úspěšnost přijetí rezerv filesystemem.

Porovnání cest používá component boundaries, Unicode canonical normalization a konzervativní
lowercase porovnání i při deklarovaném case-sensitive APFS. Odmítá známé aliasy `/tmp`, `/var`,
`/etc`, `/System/Volumes/Data` včetně variant velikosti písmen. **Nejde o filesystem resolver**:
neodhalí symlinky, firmlinky, neznámé aliasy, existující mounty, chybné UUID bindingy nebo TOCTOU.
Nenahrazuje bezpečný descriptor-relative přístup budoucího helperu. UUID v manifestu je pouze
nedoložená deklarace; duplicitní hodnoty se odmítají, chybějící UUID nic neověřuje.

## Oracle, nepokryté případy a úklid

**[implementátor]** Oracle 21 syntetických testů jsou předem připravené JSONy a očekávané chyby:
role/reference, overlap/nesting/alias, UUID, quota/reserve/overflow, úplnost restore unit,
host control, runtime deferred, strict JSON, input path metadata a skutečné CLI stejné build konfigurace.
Nativně se testuje jen čtení vlastních schema souborů, identity a proces CLI; **všechna APFS topologie,
kvóty a rollback jsou návrhové fixtures**, žádný živý APFS test ani simulovaný důkaz izolace.

**[uživatel + B4/B5]** Před použitím návrhu pro start oblasti je nutné doložit minimálně:

- všechny skutečné zápisové kořeny včetně per-UID dočasných adresářů, service-mediated databází,
  uživatelských jobů a cest mimo home; samotné `HOME`/`TMPDIR` nic nevynucuje;
- skutečné APFS volume/container identity, mountpointy, ownership a quota/reserve a chování při
  nových mountech, kolizích cest a nedostatku kapacity;
- úplné quiescence UID, zavření fd/mappingů, writable restore a zotavení po pádu v každé fázi;
- host-owned recovery záznam vně zóny i obnovy, ochranu host policy a zákaz startu smíšeného stavu;
- skutečné obnovení startup/job kanárků i projektu/prefixu/cache/TMP; externí push/upload,
  vydaná oprávnění a vzdálené účinky se filesystem rollbackem nevracejí.

Testy vytvářejí jen vlastní `/private/tmp/sanjbox-state-tests.XXXXXX` mode 0700. Před úklidem
ověří přesnou cestu, device/inode, vlastníka a typ kořene. Po úspěšném běhu vše odstraní. Při
přerušeném běhu se uklízí jen konkrétní známá a ověřená fixture; nikdy prefix/glob hromadné mazání.
Validátor sám nemá co vracet zpět. **[uživatel]** případně odstraní vlastní vstupy/reporty z ověřeného
run directory. Osobní cesty ani živé host reporty do evidence nepatří.
