# WP1.B2 — ACL příprava, syntetická validace

Datum: 2026-11-07. Čistý základ `7b20c41496f9a8d2a8e49604e31c7598a4943adb`, převzetí `977f202`,
testovaný implementační commit `62edbd0`. Samostatná větev bez kódu z jiných otevřených PR.
Původní [mode-only validace](VALIDATION-B2.md) zůstává historickým záznamem.

**Offline příprava podle GUIDE §11, nikoli laboratorní běh nebo verdikt brány.** Změny pouze
v čerstvých vlastních `/private/tmp/sanjbox-b2-tests.XXXXXX`. Bez sudo, změn home, systému,
účtů, mountů a čtení skutečných dat/tajemství. Membership API čte metadata; neotevíráme databáze.
Žádné externí Swift závislosti.

Konfigurace: arm64, macOS 27.2 (26B123), Xcode 27.2 (27B52), Swift 6.4.2
(`swiftlang-6.4.2.1.9`, `clang-2100.4.1.1`), lokální APFS. Minimum package macOS 15 není test macOS 15.

## Příkazy a výsledky

Z kořene worktree, s vlastní novou dočasnou build cache:

```bash
s4_b2_build="$(mktemp -d /private/tmp/sanjbox-b2-acl-build.XXXXXX)"
for configuration in debug release; do
  env CLANG_MODULE_CACHE_PATH="$s4_b2_build/module" \
    SWIFTPM_MODULECACHE_OVERRIDE="$s4_b2_build/module" \
    swift test --configuration "$configuration" --package-path spikes/s4-host \
    --scratch-path "$s4_b2_build/build" --cache-path "$s4_b2_build/cache" --disable-sandbox
done
bash -n spikes/s4-host/audit-host.sh spikes/s4-host/harden-host.sh spikes/s4-host/uninstall.sh
python3 -B -m unittest discover -s tools/tests -v
git diff --check
```

`--disable-sandbox` vypíná jen SwiftPM build sandbox. Native testy potřebovaly také běžné oprávnění
procesu k boot-session sysctl a vlastnímu Unix socket bind; vnější tool sandbox je blokoval.
Nevyužily root ani zvýšení UID. Build cache je samostatná od fixtures a chráněných kořenů.

| Ověření | Výsledek |
|---|---|
| Debug | **52 XCTest metod, 0 failures, 0 skips**, 17,435 s |
| Release | **52 XCTest metod, 0 failures, 0 skips**, 17,076 s |
| Rozdělení | 17 původních B1 + 20 původních B2 mode + 15 nových ACL metod |
| Wrappery | V1 i v2 skutečné CLI: default preview → apply → uninstall preview → restore → idempotentní restore, v obou konfiguracích |
| Crash | Dva mode a dva ACL child procesy na konfiguraci skončily `_exit(77)` po mutaci a před completion. Uninstall odmítl nejednoznačný stav. Harness metoda je zahrnuta v 52; children nejsou další prošlé XCTest metody. |
| Shell syntax / whitespace | Všechny tři wrappery a `git diff --check`: exit 0 |
| Python tools / progress | 63 testů, 0 failures, 0 skips; agregace z detailních řádků: F1 13 hotovo / 8 rozpracováno / 15 nezahájeno, 0 z 10 bran prošlo |

Native ACL scénáře: přesný dry-run bez deníku, zachování mode, návrat úplné původní ACL včetně
absence, odmítnutí přesné duplicity, pořadí allow/deny a native `access(W_OK)` oracle, skutečně
zděděné ACE, zachování všech pěti entry flags a globálního `no_inherit`, žádné dědění nových deny,
částečné multi-root apply/restore, konflikt blokující všechny obnovy, pozdější ACL/mode/ctime
drift, ABA a závody před/po mutaci. Neplatné UUID, masky, flags, tag, pořadí a v1/v2 kombinace
v deníku se odmítají. Dále hranice 128 ACE a odmítnutí ancestor ACL.

Ochrana znovuotevření používá skutečné členství: volající, jeho efektivní skupina, everyone
a nevyřešené UUID jsou pro `list/search` odmítnuty před state. Jiný UID (`nobody`, bez přepnutí
identity či vytvoření účtu) má úspěšný ACL apply/restore pro `list/search/readattr`; tento test
neprokazuje efektivní přístup pod jiným UID. Plány nemají deklarovaný strict duplicate-key parser;
kanonický round-trip proti neznámým/duplicitním klíčům se týká vlastního deníku.

Finální fixture teardown prošel. Kořen se před smazáním kontroluje proti původnímu device/inode,
UID, typu a mode. ACL fixtures mají také předem připnuté cíle a před odstraněním testovacího
deny ověřují původní identitu i vazbu cesty. Žádné glob cleanup.

## Vývojové neúspěchy a opravy

1. První build prošel, ale vnější sandbox blokoval existující sysctl a socket fixture.
   Opakování získalo oprávnění k těmto bounded operacím; žádný skip je nenahradil.
2. Teardown zachycoval XCTest `self` přes izolační hranici Swift 6; compile error opraven
   statickým helperem, bez změny izolace produkčního kódu.
3. První native ACL sada (49 metod) měla 53 assertions/failures (46 unexpected): deny `list`
   vůči volajícímu znemožnil i `O_EVTONLY` reopen. Přidána kontrola volajícího a skupin;
   restore testy vůči volajícímu používají `add_file`. Všech 14 zbylých přesných fixture stromů
   bylo ověřeno proti původnímu device/inode v jejich manifestu, testovací ACL odstraněna
   a stromy uklizeny. Teardown nyní drží descriptor ještě před hardeningem.
4. APFS normalizoval prázdnou ACL s `no_inherit` na absenci. Test očekává skutečný výsledek;
   neprázdná ACL flag zachová. Produkce nepřijímá nepřesný post-stav.
5. Další 49metodová sada měla tři chyby oracle: `W_OK` adresáře vyžaduje více práv. Pozitivní
   allow nyní obsahuje **add_file i add_subdirectory**, deny obsahuje add_file. Native test
   potvrzuje allow-before-deny i opačné pořadí po prependu, nikoli pouze pořadí Swift pole.
   Následných 51 metod prošlo v Debug/Release; finálních 52 přidává v2 wrapper cestu.
   Membership lookup je před posledním filesystem checkem, aby neprodlužoval check/set interval.

Příprava ACL/dry-run/deníku/úklidu je dokončena v rozsahu [HARDENING.md](HARDENING.md).
**Zbývá L3 host kompatibilita a laboratorní RB-09/10/S4.** Neověřeno: reálný home, UID oblastí,
nové mounty, nepřetržitá ochrana, poslední check/set race, souběžná změna členství, výpadek
napájení, zařízení/flush failure a reboot recovery. Žádná brána ani R2/R7 se nemění.
