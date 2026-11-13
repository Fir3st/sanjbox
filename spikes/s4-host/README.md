# S4 — audit hosta pouze z metadat (WP1.B1)

Navazující WP1.B2: [omezený mode/ACL hardening a uninstall](HARDENING.md), samostatné nativní CLI
a dry-run wrappery. Níže zůstává původní rozsah a důkazy B1; audit sám nic nemění.

`audit-host.sh` spouští nativní Swift CLI, které zkontroluje **výhradně explicitně vybrané kořeny**,
zapíše omezený JSON inventář a případně porovná předchozí snapshot. Neprovádí hardening,
nečte obsah auditovaných souborů, nemění práva/ACL/mounty a nepotřebuje privilegia.
Není to důkaz efektivního přístupu ani izolace. B1 dodává podklad pro B2/B3/B5; **S4, R2/R7 a testy
z COVERAGE zůstávají Neověřeno**.

| Cíl | Vazba na plán a hranice tohoto balíku |
|---|---|
| R2: inventář deklarovaných chráněných kořenů, práv, ACL, socketů a mountů | FS-01…08, FS-10…11. Audit sám nezakazuje čtení/zápis, nechrání nové soubory ani nové mounty. |
| R7: evidence rozsahu a driftu jako vstup pro topologii/obnovu | RB-01, RB-08…10. Žádný manifest všech zápisových cest, snapshot, rollback ani uninstall se tím neprokazuje. |
| Identita a relace měření | WP0.3 / GUI-11: `ProbeExpectation` + `ProbeContext` ze společného balíku, navíc přesné očekávané audit session ID. |

## Prerekvizity a role

**[implementátor]** Swift 6.x, macOS s `O_NOFOLLOW_ANY` a `AT_SYMLINK_NOFOLLOW_ANY`; cílové laboratorní
měření podle GUIDE je macOS 27.x / Xcode 27.x / Apple Silicon. Package deployment minimum 15
není tvrzení o ověření na macOS 15. Žádné externí balíčky, jediná závislost je lokální `../common`.
Automatické testy vytvářejí jen vlastní syntetické stromy `/private/tmp/sanjbox-s4-tests.XXXXXX`.
Nevyžadují laboratorní slot ani zásahy do osobních kořenů. Nástrojový sandbox může zakázat
`bind(AF_UNIX)` pro vlastní socket fixture; pak musí tento test běžet mimo tento sandbox,
stále jako stejný neprivilegovaný uživatel. Odmítnutý bind není přeskočený úspěch.

**[uživatel]** Před skutečným během vymezí kořeny, účel každého kořene, očekávanou identitu/session,
limity a oracle do protokolu běhu. Pro důkaz brány platí evidence a review z GUIDE; tento nástroj
žádnou bránu neuzavírá. Privilegované operace neexistují ani v CLI, ani ve wrapperu.

## Sestavení a syntetické testy

Z kořene repozitáře:

```bash
swift build --package-path spikes/s4-host
swift test --package-path spikes/s4-host
bash -n spikes/s4-host/audit-host.sh
```

Pokud prostředí nepovoluje výchozí compiler cache, lze pro tento build explicitně použít vlastní
nové adresáře v `/private/tmp` přes `CLANG_MODULE_CACHE_PATH`, `SWIFTPM_MODULECACHE_OVERRIDE`
a `--cache-path`. `--disable-sandbox` vypíná pouze SwiftPM build sandbox, neposkytuje nástroji
žádná privilegia; v omezeném vývojovém prostředí může být pro kompilaci potřebný.

Wrapper **nikdy sám nekompiluje**. Výchozí binárka je `.build/out/Products/Debug/sanjbox-host-audit`
(Swift 6.4 swiftbuild). Pro jiný build layout/configuraci zadej přesnou již sestavenou binárku:

```bash
s4_bin_dir="$(swift build --package-path spikes/s4-host --show-bin-path)"
SANJBOX_HOST_AUDIT_BIN="$s4_bin_dir/sanjbox-host-audit" spikes/s4-host/audit-host.sh --help
```

Wrapper nemá `--apply`: audit je vždy pouze čtení metadat, tedy nic nemění ani ve výchozím režimu.
Build a testy samozřejmě vytvářejí vlastní build produkty a syntetické fixtures. Shell má
`#!/bin/bash` a `set -euo pipefail`; žádné `eval`, shell interpolation vstupů ani spuštění obsahu projektu.

## Explicitní inventář a konfigurace

Žádný kořen se nepřidává automaticky: ani home, `/Volumes`, `/private/tmp`, ani seznam mountů.
`/` je jako kořen zakázán. Absolutní cesty musí být normalizované, bez `.`/`..`, prázdných komponent,
koncového `/` a symlinků v ancestor cestě. Na macOS tak použij skutečnou cestu `/private/tmp`, ne alias `/tmp`.
Kořeny mohou být adresáře i jednotlivé položky; překryvy různých kořenů spotřebují limit znovu.

Tato tabulka je **checklist pro explicitní výběr uživatele**, nikoli přednastavený scan:

| Kategorie k inventarizaci | Co musí být před během konkrétně vyjmenované |
|---|---|
| Chráněný home / pracovní data | Každý zvolený nadřazený kořen a důvod jeho zařazení |
| Konfigurace, cache, logy mimo home | Konkrétní kořeny; neobsazená kategorie je stále nepokrytá |
| Sdílené a dočasné cesty | Vybrané adresáře a jejich filesystem sockety |
| Host nástroje a startup cesty | Vybrané prefixy/adresáře nástrojů; tento nástroj nic neopravuje |
| Ostatní oblasti | Každý jednotlivě deklarovaný kořen, nikdy autodiscovery uživatelů |
| Externí/testovací svazky a zálohy | Každý explicitně deklarovaný root; neodemknuté/nevybrané mounty jsou nepokryté |

Vlastní soubor `run.s4-config.json` (syntetický příklad, cesta musí být vlastní existující fixture):

```json
{
  "schema": "sanjbox.host-audit.config.v1",
  "roots": [
    {"id": "fixture", "path": "/private/tmp/MY-OWN-S4-FIXTURE/root", "purpose": "synthetic fixture only"}
  ],
  "limits": {"maxDepth": 4, "maxEntries": 128}
}
```

Povinné limity: 1–32 kořenů, hloubka 0–32 (`0` = jen kořen), **1–1024 položek celkem přes všechny
kořeny**, cesta nejvýše 4096 UTF-8 bajtů. Dosud neotevřený kořen po vyčerpání rozpočtu má vlastní
mezeru `entry-limit`. Vyčerpaný limit neznamená, že ostatní položky neexistují. Průchod používá pořadí
`readdir`, takže při neúplném rozpočtu se konkrétní pozorovaná podmnožina může mezi běhy lišit.
Výstupní entries a gaps jsou seřazené. JSON má tvrdý limit 32 MiB; překročení znamená chybu bez snapshotu.

Zjevné názvy `.env*`, obsahující `secret`/`token`/`credential`/`keychain`, `.ssh`, `.gnupg`, `id_rsa`,
`id_ed25519`, `Login Data`, `Cookies` a přípony `.pem`/`.key`/`.p12`/`.p8`/`.pfx`/`.db`/`.sqlite`/`.sqlite3`
se záměrně neinspektují ani neotevírají. Dostanou `restricted-name-no-inspection`; adresář se neprochází.
To je dodatečná výluka, **nikoli detektor tajemství**. Obsahy všech auditovaných souborů jsou zakázané
bez ohledu na název; rozpoznané výluky zůstávají explicitní mezerou pokrytí.

## Identita před první sondou

**[uživatel]** Stanov očekávání předem podle plánované identity/session. Kontext lze samostatně
zjistit nástrojem `sanjbox-whoami` z `spikes/common`; nepřebírej automaticky právě naměřený kontext
jako očekávání pro důkaz izolace. Automatické testy používají vlastní aktuální kontext pouze jako
**syntetický smoke test validace**, ne jako laboratorní oracle.

`run.s4-expect.json` obaluje společné `ProbeExpectation` vlastním schématem:

```json
{
  "schema": "sanjbox.host-audit.expect.v1",
  "expectation": {
    "effectiveUID": 450,
    "realUID": 450,
    "effectiveGID": 701,
    "realGID": 701,
    "requiredGroups": [701],
    "forbiddenGroups": [20, 80],
    "launchdManagerName": "Aqua",
    "launchdManagerUID": 450,
    "windowSessionUID": 450,
    "onConsole": false
  },
  "auditSessionID": 100123
}
```

Čísla jsou ilustrační. Real/effective UID/GID, obě group lists (mohou být explicitně prázdné),
launchd manager name/UID a auditSessionID jsou povinné. Další pole podporuje WP0.3. Nesoulad
nebo chybějící požadovaná session znamená kód **3**, JSON pouze s identitou a mismatches. Config,
baseline ani auditovaný kořen se při tomto výsledku vůbec nečtou.

Obsah lze číst pouze z těchto vlastních schema vstupů: `*.s4-expect.json` a `*.s4-config.json`
(max. 64 KiB každý), `*.s4-report.json` (max. 32 MiB). Vstup musí být owned regular file s jediným
hardlinkem, bez group/world write, bez symlinků v celé cestě a nesmí mít výše zakázaný název.
Před i po čtení se kontroluje metadata identita/stabilita. Přípony a schema nejsou autentizace:
používej jen vlastní důvěryhodné soubory ve vlastním adresáři, nikdy nalezené soubory z auditovaného stromu.

## Spuštění a výstup

**[uživatel]** Připrav vstupy mimo auditované kořeny, aby zápis reportu sám netvořil drift.
Následující příkaz vypíše JSON na stdout a nic nezapíše do souboru:

```bash
spikes/s4-host/audit-host.sh \
  --expect /private/tmp/MY-OWN-S4-RUN/run.s4-expect.json \
  --config /private/tmp/MY-OWN-S4-RUN/run.s4-config.json
```

Pro baseline ulož stdout do **nového** souboru v ověřeném vlastním adresáři. Použij `umask 077`
a `set -C` (noclobber) před přesměrováním; existující výstup nepřepisuj. Vhodný pracovní adresář
vytvoří `mktemp -d /private/tmp/sanjbox-s4-run.XXXXXX`; uchovej konkrétní vrácenou cestu.
CLI samo žádné výstupní soubory neotvírá. Kód 4 je platný **neúplný** snapshot a smí sloužit jako
baseline s přiznaným omezením. Kód 3 či 2 baseline nevytváří.

```bash
spikes/s4-host/audit-host.sh \
  --expect /private/tmp/MY-OWN-S4-RUN/run.s4-expect.json \
  --config /private/tmp/MY-OWN-S4-RUN/run.s4-config.json \
  --baseline /private/tmp/MY-OWN-S4-RUN/baseline.s4-report.json
```

| Kód | Význam |
|---|---|
| 0 | Úplně pozorovaný deklarovaný metadata rozsah; žádné tvrzení o efektivním přístupu či bezpečnosti |
| 4 | Alespoň jedna mezera pokrytí; platný JSON snapshot |
| 3 | Neplatné měření identity/session; žádný audit |
| 2 | Použití, schema, I/O nebo velikostní chyba; žádný snapshot |

JSON `sanjbox.host-audit.report.v1` obsahuje identitu, přesnou konfiguraci, výsledky per root, drift a limity:

| Pole | Co bylo skutečně měřeno |
|---|---|
| `entries[].stat` | `fstatat`/`fstat`: device/inode, typ, mode (číselně), UID/GID, file flags, počet hardlinků, ctime. Žádné uživatelské názvy z filesystemu ani obsahy. |
| `entries[].acl` | U běžných souborů/adresářů `acl_get_fd_np(ACL_TYPE_EXTENDED)`: pořadí ACE, UUID principála, tag, numeric permissions a známé flagy; žádné překládání UUID na osobní jména. `absent` je výslovná Darwin absence, `error`/`unsupported` je unknown. |
| `entries[].mount` | `fstatfs` z téhož descriptoru: typ FS, opaque fsid, raw flags, local/readOnly/ignoresOwnership. Žádné názvy zdrojových zařízení, mountpointů ani globální seznam mountů. |
| `entries[].listing` | Zda byl výčet potomků dokončen, nebo skončil na hloubce/počtu/mount hranici/chybě/race. |
| `gaps[]` | Relativní cesta, rozsah (`metadata`/`subtree`), konkrétní důvod nepozorování. Absolutní kořen je vždy v konfiguraci. |
| `enumerationComplete` | Dokončený výčet pouze deklarovaného stromu **bez následování symlinků**; neznamená dostupnost všech ACL/mount metadata. |
| `metadataComplete` | Žádná metadata/subtree mezera v tomto kořeni. Absence kořene není úplné metadata pokrytí. |

Položky zjištěné jako socket/FIFO/zařízení/symlink se neotevírají; nečte se `readlink` ani se nepřipojuje k socketu.
Mají jen no-follow stat metadata; jejich ACL a mount jsou přiznané mezery. Nástroj tedy nedokazuje
`world-connectable` ani efektivní socket access. Hardlinky se nedereferencují do dalších cest ani
nehledají po disku; zaznamená se jen počet odkazů a inode.

Mount hranice (změna `st_dev` nebo fsid proti kořeni) se zaznamená, ale nepřekročí. Chceš-li vybraný
mount projít, musí mít vlastní explicitní root. Nonlocal mounty se po zjištění FS metadat neprocházejí
a jejich ACL se nečtou. Samotný počáteční kernel lookup/open/stat na nedostupném FS může blokovat:
limity počtu a hloubky nejsou wall-clock timeout. Bezprivilegovaný test nevytváří/odpojuje žádný mount.

## Drift a oracle

**[implementátor]** Oracle syntetických testů je předem známý vlastní strom a explicitně vložené změny.
**[uživatel]** Pro běh brány je oracle oddělená sonda syntetického kanárku pod správnou identitou;
nulový drift nikdy není oracle izolace. B1 nesbírá FS-09 metadata služeb (`ps`/`mdfind`/logy).

- `root-added-to-scope` / `root-removed-from-scope` mění **konfiguraci**, neexistenci/smazání dat netvrdí.
  Změna cesty téhož ID je `root-path-changed`, změna limitů `limits-changed`.
- `metadata-changed` porovnává stat a společně dostupné ACL/mount; obsah souboru se neporovnává.
  Ctime může znamenat změnu nesouvisející s ochranou; inode/fsid nejsou trvalé identity přes reboot/remount.
- `added-observation` / `absent-observation` vyžadují dokončený relevantní výčet parent adresáře nebo
  výslovně chybějící root/ancestor. Není to historický důkaz vytvoření/smazání; scan není atomický.
- Neúplné předchozí pokrytí dává `newly-observed-unknown-before`; neúplné současné dává `unobserved-now`.
  Chyba ACL se nikdy nezamění s prázdnou ACL. Raced ancestor nesmí podpořit závěr absence.
- `coverage-changed` / `observation-status-changed` oddělují změnu pozorovatelnosti. I beze změny gaps
  zůstávají v reportu a neúplná baseline se nestává úplnou. Baseline není podepsaná ani důvěryhodnostní hranice.

Descriptor-relative `openat`/`fstatat`, `O_NOFOLLOW_ANY`, `O_NOFOLLOW`, `O_NONBLOCK` a kontroly
před/po omezují záměny cest. **Neodstraňují TOCTOU a nevytvářejí atomický snapshot.** Mezi stat a open může původně běžný soubor
nahradit speciální uzel: metadata-only `O_EVTONLY | O_NONBLOCK` open se pak může uskutečnit,
načež kontrola typu/device/inode výsledek odmítne bez čtení dat. Nelze tedy slíbit absolutní
zákaz každého special-node open za souběžné manipulace; test pokrývá náhradu za syntetické FIFO.
Přesunutý již
otevřený adresář zůstává pinned inode; při unwind se kontroluje jeho vazba do parentu. Detekovaná změna
znehodnotí úplnost podstromu; krátké souběžné změny přesto mohou uniknout. Ancestor práva/ACL nejsou
inventarizovaná jako samostatné položky, pokud nejsou explicitní root; mount flags a ACL nejsou výpočtem
skutečného efektivního přístupu. Periodický audit nic nevynucuje mezi dvěma běhy.

## Rozsah testů a úklid

17 automatických testů používá nativní `stat`/ACL/socket/FIFO, mode `000`, symlinky, bounded traversal,
missing root, baseline JSON a skutečný CLI proces; nikdy data osobních kořenů. Deterministické hooky
provádějí jen syntetické rename/symlink/FIFO races. **Mockované jsou mount boundary, nonlocal mount,
unavailable mount a unknown ACL drift**; ty nejsou důkazem živé mount policy/exFAT/Time Machine.

Každá fixture vzniká `mkdtemp` s mode 0700. Teardown před odstraněním ověří přesnou prefixovanou cestu,
vlastníka, typ, mode a původní device/inode kořene. Neprovádí glob/prefix cleanup. Při pádu test runneru
může fixture zůstat: **[implementátor]** zkontroluje konkrétní známou cestu z daného běhu a odstraní jen ji,
nikdy všechny `/private/tmp/sanjbox-*`. Audit sám žádný úklid nevyžaduje. **[uživatel]** případně smaže jen
svůj ověřený run directory a vlastní reporty; žádná oprávnění, ACL ani mount se neobnovují, protože nebyly měněny.
Do evidence necommituj osobní cesty, jména nebo surové host reporty; publikuj pouze syntetické/redigované podklady.

## API opory

Implementace se opírá o lokální macOS SDK `sys/fcntl.h`, `sys/stat.h`, `sys/acl.h`, `sys/mount.h`.
[Apple: eventOnly](https://developer.apple.com/documentation/system/filedescriptor/openoptions/eventonly)
a [Apple: acl_get(3)](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/acl_get.3.html)
popisují metadata descriptor a ACL API. [Apple XNU fcntl.h](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/fcntl.h)
obsahuje no-follow flags. Zdroje vysvětlují API; nejsou důkazem průchodu S4.
