# WP1.B2 — lokální syntetická validace

Datum: 2026-11-04. Základ větve: `afae1ca`; převzetí B2: `2ae1170`.
Toto je záznam vývoje a testů, **nikoli laboratorní důkaz ani verdikt S4**.
Původní B1 zdroje, testy a existující evidence byly zachovány.

Konfigurace: Apple Silicon / arm64, macOS 27.2 build 26B123, Xcode 27.0 build 27A266a,
Apple Swift 6.4 (`swiftlang-6.4.0.34.1`, `clang-2100.3.34.1`). Package deployment minimum 15
neznamená otestování macOS 15. Native ACL/mode/descriptor/flush testy používaly vlastní syntetické
adresáře na místním APFS; nebyly změněny host home, skutečná data, uživatelé, systém, mounty,
Keychain ani databáze. Neproběhlo `sudo` ani stahování balíčků.

## Provedené příkazy

Pracovní adresář pro všechny příkazy: kořen izolované větve B2. Build cache a scratch byly explicitně
vlastní dočasné `/private/tmp/sanjbox-b2-build-cache`; wrappery během testu dostaly přesnou Release
binárku z téže testované konfigurace.

```bash
env CLANG_MODULE_CACHE_PATH=/private/tmp/sanjbox-b2-build-cache/module \
  SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/sanjbox-b2-build-cache/module \
  swift build -c release --package-path spikes/s4-host \
  --scratch-path /private/tmp/sanjbox-b2-build-cache/build \
  --cache-path /private/tmp/sanjbox-b2-build-cache/cache --disable-sandbox

env CLANG_MODULE_CACHE_PATH=/private/tmp/sanjbox-b2-build-cache/module \
  SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/sanjbox-b2-build-cache/module \
  swift test -c release --package-path spikes/s4-host \
  --scratch-path /private/tmp/sanjbox-b2-build-cache/build \
  --cache-path /private/tmp/sanjbox-b2-build-cache/cache --disable-sandbox

bash -n spikes/s4-host/audit-host.sh spikes/s4-host/harden-host.sh spikes/s4-host/uninstall.sh
git diff --check
```

`--disable-sandbox` platí jen pro SwiftPM build sandbox. Procesy/testy běžely pod běžným UID;
B1 obsahuje skutečný vlastní Unix socket fixture, pro který vnější tool sandbox nemusí povolit bind.
Opakování použije nový vlastní cache adresář, nikoli cizí existující cache. Pro vlastní fixture
`mkdtemp` a identity-checked teardown zajišťuje testovací kód.

## Výsledky

- Finální Release build/test: **37 XCTest metod, 0 failures**, celkem 8,781 s; 17 původních B1,
  20 B2 (z toho jedna metoda je subprocess crash harness). Oba vybrané child procesy skutečně
  skončily `_exit(77)` z hooku po mutaci a před completion zápisem. Následný uninstall odmítl
  obnovu jako nejednoznačnou, včetně případu, kdy původní mode již byl obnoven.
- `bash -n` pro všechny tři wrappery: exit 0. `git diff --check`: exit 0.
- End-to-end Release wrappery: default dry-run → apply → uninstall dry-run → restore → idempotentní
  restore, bez zásahu mimo syntetický strom.
- B2 native scénáře: přesný preview a absence deníku při dry-run; exkluzivní lock; durable before/after;
  legitimní mode změna a chmod-away/back ctime; child-creation ctime; target inode a parent inode
  replacement; existující/následná ACL odmítnuta a zachována; změna před závěrečnou kontrolou;
  rename a změna po mutaci; multi-root preflight; symlink/FIFO; reuse state; cizí položka deníku;
  truncation; unknown/duplicate JSON keys a nekanonické formátování; změněné boot UUID;
  symlink místo state; identity mismatch před čtením plánu/baseline/state; omezení flags/schema.
- Native teardown každé fixture prošel. Po finálním běhu nebyly ponechány B2 fixtures.
  Vlastní build/test cache (129 MiB) byla po validaci odstraněna pouze po ověření přesné cesty,
  typu, vlastníka a device/inode; žádné glob či cizí cache nebyly odstraněny.

## Zachované informace o vývojových neúspěších

1. První Release test compile neprošel: Darwin Swift `fork()` je unavailable. Nahrazeno vybraným
   XCTest subprocess přes `Process`, se samostatným prostředím a bez produkčních fault přepínačů.
2. První vykonaná sada: 34 metod, 40 assertions/failures (3 unexpected); žádný úspěšný hardening
   v těchto neúspěšných B2 scénářích. Příčina byla nepovolená kombinace
   `O_NOFOLLOW | O_NOFOLLOW_ANY` při otevírání komponent. Opraveno na samotné `O_NOFOLLOW_ANY`
   s `O_DIRECTORY`. Původních 17 B1 testů prošlo. Následný focused dry-run test prošel.
3. Po opravě prošlo 34 metod. Doplnění strict journal/race případů rozšířilo sadu na 37, všechny prošly.
4. Při review bylo upraveno předání vlastnictví descriptorů ve throwing initializers, aby chyba nemohla
   vést k dvojímu close. Finální výše uvedená sada 37 metod znovu prošla.

Tato stránka nepřepisuje starší gate evidence. Příprava dále vyžaduje nezávislé review; nejde o
průchod RB-09/10, host compatibility ani continuous R2. Neověřeno: skutečný chráněný home,
ACL hardening/restore, souběh oblastí, poslední check/syscall race, výpadek napájení a zařízení,
flush failure, reboot recovery, nové mounty/data/instalace a podpůrné TCC/IPC/lifecycle mechanismy.
