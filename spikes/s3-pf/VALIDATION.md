# C1 — validační záznam přípravy

Datum **2026-11-03**. macOS **27.2 (26B123)**, Apple Silicon arm64. Xcode **27.0
(27A266a)**; Apple Swift **6.4** (`swiftlang-6.4.0.34.1`, clang `2100.3.34.1`), sestavení
pro macOS přes Xcode **27.0 SDK**. Žádný z níže uvedených výsledků není verdikt S3/S3b.

| Kontrola | Skutečný výsledek | Co dokládá |
|---|---|---|
| Python unittest, PATH Python 3.15.0 | **24/24 pass** | Mock PF executor a memory journal, hranice config/template, normalizace, ownership/conflicts, crash windows, kapacita, dry-run; lokální vlastní filesystem fixtures. |
| Stejná suite přes `/usr/bin/python3` 3.9.6, `-I -B` | **24/24 pass** | Kompatibilitu s pevným interpretem shell wrapperů. |
| Swift debug `swift test` | **6/6 pass** | Injektovaný transport; chybná UID/audit/bootstrap/group identity nevolá transport, jiná konkrétní audit session nečte probe config, embedded NUL/family confusion nevolá transport, slabé očekávání/nekontrolovaný input odmítnut, regular input vs. symlink/ancestor/FIFO/hardlink/writable/zakázaný název. |
| Native Darwin ACL fixture | **pass**, součást Python suite | Vlastní dočasný regular soubor bez ACL přijat; grant-write ACE přidaná pouze tomuto souboru odmítnuta. Žádná změna ACL systémových nebo uživatelských dat. |
| `bash -n` load/unload | **pass** | Syntaxi wrapperů. |
| Oba shell dry-runy | **pass** | Vypíší pouze plán, pevný anchor a omezený filter reload; žádná state creation nebo skutečný executor. |
| `renderer.py` v4/v6 | **pass** | Bounded substituci hypotetické šablony, ne její PF syntaxi. |
| Sestavený `sanjbox-s3-probe` bez `--apply` | **pass** | Načtení vlastních fixtures a výpis plánu; bez identity capture nebo socketu. |
| `git diff --check`, relativní odkazy dokumentů | **pass** | Formát a existenci lokálních cílů odkazů. |

## Reprodukce

Z kořene worktree:

```bash
/usr/bin/python3 -I -B -m unittest discover -s spikes/s3-pf/python-tests -v
bash -n spikes/s3-pf/load.sh spikes/s3-pf/unload.sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/clang-cache" \
swift test --package-path spikes/s3-pf --disable-sandbox \
  --cache-path "$PWD/.build/c1-cache" --scratch-path "$PWD/.build/c1-build"
```

Default SwiftPM pokus nejprve odmítlo sandboxované prostředí při zápisu cache, druhý při
vnořeném `sandbox-exec`; izolované cache a `--disable-sandbox` následně sestavení umožnily.
Při vývoji se opravila chybná Darwin ACL return semantika, casty importovaných ACL typů,
FIFO/no-follow testovací cesta a nespoléhání na recursion limit nového Python JSON parseru.
Tabulka uvádí výsledný stav po opravách, ne zamlčenou první úspěšnost.

## Výslovně neověřeno

- Nebyl spuštěn **žádný skutečný pfctl**, ani parser `-n`, enable/disable/flush, `/dev/pf`
  operace nebo změna host konfigurace. Příkazy v `FakeSystem` jsou stringy/simulace.
- Nebyla spuštěna aktivní síťová sonda, ani loopback server/send, tvorba uživatelů,
  změna loginu, `sudo`, sleep/wake, VPN či globální ACL/settings. Testovací ACL změna je
  omezena na vlastní nový dočasný soubor a následně jej odstraní vlastník fixture.
- Neověřena skutečná root delegace, parser syntaxe a display všech macOS 27 buildů,
  průchod packetů, `user` atribuce, transparentní `route-to/tag/rdr`, NATLOOK ABI,
  samostatná autentizovaná služba, resolver/mDNS/ICMP, ingress nebo zachování hosta.
- Mock potvrzuje, že před mutací existuje journal a že po známých fázích umíme rozhodnout
  o opakování/refusal. Neprokazuje atomickou izolaci od dalšího root writeru, trvanlivost
  filesystemu po skutečném výpadku napájení nebo bezpečnost při změně start lifecycle.
- Chybějící ochrana při ztrátě PF zůstává blokátor. Nepřidává se NE, VM ani změna kontraktu.
  Zde hotová příprava C1 nemění žádný acceptance/gate verdict ani dokončení C2/C3/C4.
