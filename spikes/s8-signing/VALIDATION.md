# WP1.A6 — vývojová validace, 2026-11-03

Toto je přezkoumatelná poznámka o přípravě, **nikoli uzavřený protokol S8/L2**. Všechny brány a
155 případů v COVERAGE zůstávají Neověřeno. A6 zůstává částečné; chybějící výstupy uvádí README.
Žádné původní `docs/evidence` nebyly změněny. Raw identity se nepublikují; lokální výstupy jsou
vlastní syntetické logy v `/private/tmp/s8-a6-*`, žádné skutečné účty/služby/TCC nebyly testovány.

## Přesný zdroj a prostředí

- Východisko `main`: `547f3c1e630cdd95662b9a9f339a22f7a1c47026`.
- Převzetí A6: `0f7ce02`; pracovní větev `codex/wp1.a6-signing-preparation`.
- [SOURCES.sha256](SOURCES.sha256) pinne Package.swift, všech sedm Swift source souborů a testy.
  Hash samotného seznamu: `5a31c2b56c4a64f7ff175fe6a5acaca0250abfdd0c419e0078ff7e1c1a86929d`.
  Tento seznam se týká právě této vývojové revize; budoucí změna vyžaduje nový záznam výsledků.
- Lokálně: arm64, macOS 27.2 build `26B123`, Swift 6.4 (`swiftlang-6.4.0.34.1`).
- Native SwiftPM Debug, izolované scratch/cache, žádné externí dependencies. Synchronous API
  deadline a same-UID souběžné změny zůstávají omezením podle README.

## Testy

```sh
env CLANG_MODULE_CACHE_PATH=/private/tmp/s8-a6-clang-cache \
  SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/s8-a6-swift-module-cache \
  swift test --build-system native --package-path spikes/s8-signing \
  --scratch-path /private/tmp/s8-a6-native-debug-build \
  --cache-path /private/tmp/s8-a6-swift-cache --disable-sandbox
```

**28 Swift Testing testů, 0 selhání.** XCTest wrapper hlásí 0 testů; rozhodující je následující
Swift Testing výsledek 28. Pokryté jsou úplnost/exaktnost identity a audit session, unknown group
membership, chybějící/přítomná window session včetně null round-trip, strict JSON duplicity/typy,
signature policy a malformed entitlements, role/session/capability/replay/kapacita mock brokeru,
deterministický fuzzer, šest plánů, statický plist validator, omezení souborů, hardlinks/symlinks,
změna módu/immutable flagu před úklidem, pokračování částečného úklidu a prázdný-root crash window.

Nezávislá kontrola koordinátora nad stejným zmrazeným zdrojem: **native Release 28 testů, 0 selhání**;
lokální log `/private/tmp/sanjbox-a6-root-release.log`. Native backend vypisuje deprecation warning;
nejde o warning-free build. Testy samy nepokoušejí attach, TCC, XPC ani systémovou službu.

## Podepsaná CLI smoke kontrola

Před každou CLI sérií byla vlastní scratch binárka znovu ad-hoc podepsána `--options runtime`,
`--timestamp=none` a prázdným entitlement plist. Ověřen výstup `codesign -dvv --entitlements -`:
flags `0x10002 (adhoc,runtime)`, prázdný dictionary; běhová Security self-check bez issues.
Očekávání bylo explicitně zafixováno v soukromém UUID input rootu před sérií. Jde o host diagnostiku,
nikoli o S1 testovací UID či předregistraci L2.

| Kontrola | Pozorování | Rozsah závěru |
|---|---|---|
| `mock --iterations 10000 --seed 21304` | 4 pozitivní kontroly, 10 000 negativů, 0 unexpectedAccepts, prázdné failures | Pouze toy wire/policy |
| Corpus SHA-256 | `a9d18dbb0f51df4edbbec2df5228d5907b88543e498fa147b0e0544bff4b6ef3` | Deterministická reprodukce této série |
| `experiments` | 6 plánů, exit 0 | Plány se nevykonaly |
| `prepare` dry-run | Exit 0, popis vlastních změn | Bez vytvoření fixtures |
| `prepare --apply yes` | Čtyři vlastní thin arm64 fixtures a manifest | Pouze vlastní nový temp root, žádná binárka nebyla spuštěna |
| `inspect hardened` | Exit 0, Security validity 0, flags 65538, issues prázdné | Statický fixture oracle |
| `inspect plain` | Exit 1, validity 0, flags 2, chybí runtime | Očekávaný negativní oracle |
| `inspect unsigned` | Exit 1, validity -67062, flags neznámé | Očekávaný negativní oracle |
| `inspect tampered` | Exit 1, validity -67061, flags 65538 | Očekávaný negativní oracle |
| Cleanup dry-run, apply, apply znovu | Vše exit 0; dry-run zachoval root, apply odstranil vlastní root, opakování no-op | Žádné zbylé fixtures této série |
| Úmyslně jiná očekávaná audit session | Exit 3, jediný identity report s valid false; mock se nespustil | Mismatch není důkaz izolace |

Reporty ukládají SHA-256 jednotlivých fixture bytes. Byte hashe kompilovaných Mach-O se mohou mezi
buildy lišit; jejich expected výsledky se nepřizpůsobovaly pozorování. Čtyři signing výsledky byly
zafixované před spuštěním v README. Neověřují stabilní identitu TCC, Personal Team ani self-signed.

**Nezávislý Release CLI smoke koordinátora:** stejný zdroj, vlastní ad-hoc runtime/empty-entitlement
binárka a nová fixture sada. Potvrdil všechny čtyři výše uvedené validity/flags/exity, 10 000 negativů
a čtyři kontroly se stejným corpus hashem, šest service plánů, identity-only exit 3 při chybné přesné
audit session (ještě před použitím úmyslně neplatného rootu) a cleanup dry/apply/repeat.
Lokální souhrn: `/private/tmp/sanjbox-a6-root-smoke-_wdz53hc/summary.json`. Ani tato nezávislá kontrola
není uživatelský S8/L2 experiment.

## Zachované vývojové problémy a omezení

První build selhal kvůli výchozí module cache mimo writable scratch. Následující sestavení odhalilo
chybějící public inicializátory common vnořených typů a Swift názvy Security enumů; opraveno pouze
v A6. První souborový test selhal na Foundation převodu `/private/tmp` → `/tmp`; přešlo se na POSIX
`realpath`. Pak se doplnilo zacházení s Darwin ENOENT u ACL na otevřeném vlastním fd. Všechny tyto
neúspěchy byly vývojové testy, nikoli negativní výsledky bezpečnostní brány.

**Důležité:** původní Debug build výchozím Swift 6.4 `swiftbuild` backendem vložil `get-task-allow`.
První diagnostický context a odmítnutý mock pokus s tímto buildem nejsou platná signing měření;
neproběhla TCC/attach/grant operace. Metadata to odhalila před finální smoke sérií. README nyní
požaduje preflight po každém rebuildu a CLI se sama odmítne při nesplněném signing profilu.
Finální uvedené výsledky používají výslovně znovu podepsaný native build.

První host smoke také odmítl soukromý input adresář, protože macOS dědí skupinu parentu `/private/tmp`.
Kód nyní vyžaduje vlastní UID/0700/no-ACL/no-flags a pro fixture cleanup porovnává skutečnou původní
skupinu z manifestu; nezaměňuje ji s effective GID procesu, které se nadále kontroluje přesně.

Review doplnilo explicitní null pro non-GUI expectation a ochranu před později nastavenými file
flags, plus pokračování úklidu po vlastním partial unlink a po posledním unlink před rmdir.
Tyto případy mají regresní testy; nejde o obecnou crash-atomicity či hostile TOCTOU garanci.
