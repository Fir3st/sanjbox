# WP0.4 — oprava vlastnictví výstupů counterpartu

2026-11-08, offline oprava po reprodukovaném přesměrování `stopped` do syntetického kanárka výměnou
cesty logu za symlink. Implementátor Codex Astra; samostatné čerstvé Astra xhigh review dokončeno bez nálezů P0–P2. Testovaný source/test commit:
`63280b401fff8828136336ba552f16888a540433` (base `7b20c41496f9a8d2a8e49604e31c7598a4943adb`).

## Změna a hranice

Interní `CounterpartOutput` drží nový log FD, raw directory FD a otevřené capture FD. Cesty se pro další
zápisy znovu neotvírají; komponenty se otevírají přes `openat` + `O_NOFOLLOW`, výstupní soubory přes
`O_EXCL`. Přesné root-owned macOS aliasy `/tmp` a `/var` se validují a rozvinou před průchodem.
Kontroly vlastníka, typu, práv a počtu hardlinků odmítnou pozorovaný konflikt; full-write smyčka dořeší
krátké zápisy a `EINTR`. Chyba writer trvale uzavře a counterpart ukončí bez `stopped`. Deskriptory se
zavírají idempotentně, rollback podle cesty se neprovádí; již vytvořený prázdný výstup po chybě zůstane.

Výměna jména po otevření znamená **pokračování do původního objektu**, pokud jeho metadata stále projdou
kontrolou, nikoli automatické odmítnutí. Odlinkování souboru nebo pozorovaný další hardlink zápis odmítne.
Kontrola metadat není atomická s vytvořením/zápisem a nechrání obsah stejného inode před jiným procesem
se stejným UID; bez `fsync` nejde o záruku trvanlivosti při pádu systému. Schéma událostí, report/CLI,
počty kontaktů/bajtů, kanárky, raw limit a sdílené `JSONLines.swift` se nemění.

## Ověření

Vlastní syntetické soubory a procesy, TCP/UDP pouze loopback, macOS 27.2 build 26B123, Apple Swift 6.4.2,
arm64. Výchozí `TMPDIR` zůstal nezměněný (`/var/folders/.../T/`), aby testy pokryly i systémový alias.

- **Debug i Release: 47 testů / 0 selhání** v každé konfiguraci: 7 XCTest provenance + 18 ProbeKit +
  22 counterpart; z counterpartu je 15 nových testů s 25 případy po rozvinutí parametrů.
- Regrese: přejmenovaný log + symlink na kanárka, výměna společného předka, výměna raw adresáře před
  prvním bajtem a capture souboru mezi zápisy; cizí symlink komponenty, existující soubor/hardlink/FIFO/
  adresář, raw kolize po startu, nebezpečná práva, log uvnitř raw, zachování výstupů po selhání startu,
  nula bajtů UDP bez raw souboru, raw limit, `EINTR`/short write, zero-progress/ENOSPC a neobnovitelná chyba.
- **3 skutečné CLI scénáře v Debug i Release:** log nahrazený symlinkem → listen 0 / report 0 z původního
  přejmenovaného logu, kanárek nezměněn; další hardlink logu → proces SIGTRAP / report 3, bez `stopped`;
  raw filename symlink konflikt → proces SIGTRAP / report 3, bez `stopped`, kanárek nezměněn.

Příkazy z kořene repozitáře (stejné pro obě konfigurace, oddělené scratch/cache adresáře):

```sh
counterpart_scratch=$(mktemp -d /private/tmp/sanjbox-counterpart-output.XXXXXX)
CLANG_MODULE_CACHE_PATH="$counterpart_scratch/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$counterpart_scratch/module-cache" \
swift test -c debug --package-path spikes/common \
  --scratch-path "$counterpart_scratch/build" --cache-path "$counterpart_scratch/package-cache" \
  --disable-sandbox -Xswiftc -module-cache-path -Xswiftc "$counterpart_scratch/module-cache"
# Druhý nový scratch: stejný příkaz s -c release.
```

Malé lokální logy a reprodukční CLI skript jsou v `/private/tmp/sanjbox-counterpart-output.jiBtij/`:
`debug-final.log`, `release-final.log`, `cli-output-check.py`, `cli-debug.json`, `cli-release.json` a jejich
syntetické `cli-output-*` adresáře. Zachovány jsou i předchozí pokusy: `debug-first.log` (sandbox odmítl
výchozí compiler cache), `debug-second.log` (sandbox odmítl bind a existing membership smoke),
`debug-tests.log` (první úspěšná sada) a `cli-debug-first.stderr` (harness chybně čekal compact stdout;
opraveno čtením `started` z JSONL). Finální testy běžely po schválení mimo sandbox; žádné balíčky se
neinstalovaly. Po review byly vlastní velké build/module cache odstraněny; ověřené CLI binárky, malé logy a receipt `cache-cleanup.json` zůstávají.

To je test opravy kódu, nikoli laboratorní důkaz R2/R3, průchod brány nebo změna historického verdiktu.

Nezávislý reviewer ověřil shodný source/test commit a dokumentační HEAD `400ad1536fff6e1b018b2c230398a108f05903d3`:
**47/47 Debug**, **12/12 vlastních CLI scénářů** a **4/4 kontrol descriptorů**, včetně 500 konfliktních
startů bez úniku a souběžného close/write. Release nezávisle neopakoval; výše je běh implementátora.
Malý nezávislý souhrn a harnessy: `/private/tmp/sanjbox-output-independent.HZI0Og/review-summary.txt`;
reviewerovy velké cache jsou odstraněny. Tato následná aktualizace mění jen dokumentaci a vlastní řádek coverage.

## Opakované nezávislé review před integrací PR #69 (2026-11-13)

Codex Astra xhigh zkontroloval HEAD `8396013e455b1c68a09dd4f58172549f6532f947` bez dalšího nálezu
P0–P2 v rozsahu vlastnictví deskriptorů a přesměrování cest. Source ani produkční testy se nemění.
Na macOS 27.2.1 build 26B131, arm64, Apple Swift 6.4.2 proběhlo:

- **47/47 testů Debug i Release** celého `spikes/common` (7 XCTest + 18 ProbeKit + 22 counterpart).
- **10/10 skutečných CLI scénářů v každé konfiguraci:** výměna logu za symlink, výměna raw adresáře
  před prvními daty, výměna společného předka, výměna TCP capture mezi zápisy, zero-byte UDP,
  hardlink logu, nebezpečný mode logu, raw symlink konflikt, odlinkovaný log a neúspěšný start.
  První čtyři zachovaly zápisy v původních objektech; konflikty skončily bez `stopped`, dostupné
  neúplné logy měly report exit 3 a syntetické cíle symlinků se nezměnily.
- **3/3 doplňkové kontroly Debug:** `FD_CLOEXEC`, uzavření deskriptorů po úspěchu a 500 konfliktních
  inicializacích; 512 souběžných write/close operací; 512 souběžných create/close operací. Uzavřené
  objekty nezasáhly následně otevřené náhradní deskriptory. Dočasný testovací soubor byl po běhu
  odstraněn z balíku; jeho kopie zůstává s logem review.

Review upřesňuje hranici dokumentace: validace práv kontroluje **jen POSIX mode bits**, nikoli
rozšířené ACL. Vlastní syntetický adresář s dědičným `allow` ACL byl přijat a nové objekty zachovaly
zděděný ACL i při `0600`/`0700`. To není důkaz vyloučení zápisu jiným UID; přístup jiného UID se
netestoval. ACL hardening je samostatný rozsah. Držený deskriptor stále brání přesměrování pozdějšího
zápisu výměnou cesty; neměnnost stejného inode ani laboratorní izolační verdict se netvrdí.

Lokální reprodukce a malé záznamy jsou v `/private/tmp/sanjbox-pr69-review.eeQ7AUVv/`:
`debug-all.log`, `release-all.log`, `cli-review.py`, `cli-debug/receipt.json`, `cli-release/receipt.json`,
`OutputReviewChecks.swift`, `descriptor-checks.log` a `acl-boundary/receipt.txt`. Všechny CLI procesy
skončily; šlo pouze o vlastní syntetické soubory a loopback TCP/UDP. Review bylo provedeno před
integrací PR #64; kontrolu společného výsledku a CI po aktualizaci větve musí dokončit integrátor.
