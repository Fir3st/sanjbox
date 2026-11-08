# WP0.4 — oprava vlastnictví výstupů counterpartu

2026-11-08, offline oprava po reprodukovaném přesměrování `stopped` do syntetického kanárka výměnou
cesty logu za symlink. Implementátor Codex Astra; nezávislé review následuje. Testovaný source/test commit:
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
neinstalovaly. Build/module cache zůstávají pro review a potom lze odstranit pouze vlastní velké cache.

To je test opravy kódu, nikoli laboratorní důkaz R2/R3, průchod brány nebo změna historického verdiktu.
