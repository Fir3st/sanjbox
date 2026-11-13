# WP1.H5 — lokální validace PR #53

2026-11-13, implementace `f21751ab114fc8893a6009a295ec192791b72e10`, po integraci
`main` `dc482d972376ed67c6e83eff65fe303cc50f3f70`. Následující dokumentační commit
mění pouze README, tento záznam, komentář k preview a řádek WP1.H5 v COVERAGE.
Jde o offline ověření prototypu podle GUIDE §11, nikoli laboratorní běh nebo verdikt brány.

Prostředí: Apple Silicon arm64, macOS 27.2.1 (26B131), Xcode 27.2 (27B52), Apple Swift 6.4.2.
Žádné externí balíčky, root operace, skutečná oblast ani osobní data; pouze vlastní
syntetické stromy `/private/tmp/h5-export-*`, které testy uklidily.

| Kontrola | Výsledek |
|---|---|
| `swift test --package-path proto/export -c debug` | 80 testů, 0 selhání, 0 přeskočení |
| `swift test --package-path proto/export -c release` | 80 testů, 0 selhání, 0 přeskočení |
| Samostatný proces `sanjbox-export`, Debug i Release | 9 scénářů v každém sestavení, všechny prošly |
| `git diff --check` | bez chyb |

Buildy používaly oddělené `--scratch-path /private/tmp/sanjbox-pr53-{debug,release}`,
cache modulů v `/private/tmp/sanjbox-pr53-modules` přes `CLANG_MODULE_CACHE_PATH` a
`SWIFTPM_MODULECACHE_OVERRIDE` a `--disable-sandbox` pro SwiftPM. Finální testovací
procesy běžely mimo sandbox nástroje, protože sandbox při vytváření zdrojové fixture
odstranil setuid. Počáteční sandboxový běh přeskočil přesně
`CopyTests.testSpecialModeBitsAreNotPropagated`: požadovaný mode `04755`, zjištěný `0755`.
Finální Debug i Release tento případ skutečně provedly a prošly; sticky bit test také prošel.

Samostatné CLI procesy měly limit 5 s na scénář: dry-run bez cíle či auditního souboru;
úspěšná kopie 251 000 syntetických bajtů, mode `0640`, `nlink=1`, skutečný xattr
`0081;00000000;Sanjbox;`, zdroj bez změny či nové karantény a JSONL preview/copy;
existující cíl (exit 1), symlink a hardlink (exit 3), cíl přes `alias/..` dovnitř zdroje
a audit uvnitř zdroje (exit 2), auditní FIFO bez blokování (exit 1), neplatný zdrojový
kořen bez vytvoření auditu (exit 1). Úklid všech jejich dočasných stromů byl ověřen.

Regrese navíc ověřují připnutí rodiče při přesměrování aliasu oběma směry, náhradu
zdrojového kořene se zachovaným inode souboru, vložené/vyměněné cílové adresáře a kořen,
kolize soubor/adresář a zápisů adresáře, NUL v cestách, omezené hashování rostoucího
řídkého zdroje, redakci odmítnutého absolutního vstupu v auditu a úklid aktuálního
souboru po selhání copy auditu při zachování předchozí auditované kopie.
Selhání xattr, zápisu a auditního sinku jsou **injekce/mocky**; běžná kopie a xattr jsou reálné.

Předpoklad soukromého a stabilního cílového/auditního prostoru platí po celý běh:
fd zabrání přesměrování symlinku, ale nezabrání pozdějšímu přesunu připnutého rodiče
dovnitř zdroje ani všem záměnám mezi syscally. Testy nedokazují atomickou obranu proti
aktérovi se stejným UID či právem měnit rodiče, děděné ACL, Gatekeeper při spuštění,
obnovu po výpadku ani reálnou izolaci. Konsolidace s auditem H1 a integrace pod UID
oblasti patří WP2.11; R2/R7, FS-12, POS-09 a všechny brány zůstávají Neověřeno.
