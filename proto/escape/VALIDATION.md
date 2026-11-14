# WP1.H6 — ověření offline přípravy

Ověřeno 2026-11-14 na Apple Silicon / macOS 27.2.1 (26B131), Apple Swift 6.4.2.
Testované zdroje: **`7d960069c1f19fa11007bf798dc2788a2b66b333`**,
základ `main` **`5d2005a6398249bcdbcebba0fd98928c29d193c0`**.
Claim **`6446a7996c6f42c11a5fbce4ae99eb64f422f585`** byl zveřejněn před implementací
na `origin/codex/wp1-h6-escape`; v době kontroly nebyl konkurenční claim ani otevřené PR.

## Spuštěné kontroly

| Příkaz | Výsledek |
|---|---|
| `swift test --package-path proto/escape --scratch-path /private/tmp/h6-swift-build -c debug` | **18 testů, 4 suites, 0 selhání**, test run 18,916 s. |
| `swift test --package-path proto/escape --scratch-path /private/tmp/h6-swift-release -c release` | **18 testů, 4 suites, 0 selhání**, test run 24,766 s. |
| `git diff --cached --check` před implementačním commitem | Bez chyby whitespace. |

Oba běhy sestavily a spustily skutečný lokální `sanjbox-counterpart` ve stejné debug/release
konfiguraci. Testy používají nové soukromé stromy a ephemeral IPv4 loopback TCP porty; jejich
scratch stromy se uklidily. Nebyl potřeba přepínač pro opt-in síťových testů, zařízení, účet,
privilegovaná operace, změna systémové konfigurace, TCC grant ani skutečná oblast.

## Co testy skutečně prokázaly

- **155 přesných a unikátních ID:** ručně připnutý nezávislý literál se porovnává s katalogem
  i aktuální COVERAGE §3; shodují se také titul, požadavky a brána. Chybějící/duplicitní řádek,
  neúplný oracle nebo nesprávné svázání sondy jsou odmítnuty. Odstranění ID z obou zdrojů
  nezmění očekávání testu.
- **Osm syntetických úspěchů**, 133 ručních a 14 nepodporovaných případů. Kompletní report
  i skutečné CLI vracejí `incomplete` / exit **3** a všech 155 `acceptanceStatus` je `unverified`.
  Ruční a nepodporovaný případ odmítají stát se pass i s vloženou dokonale úspěšnou observation.
- **Vlastní souborové stromy:** pozitivní kontroly přečtou vlastní kanárky; mock odmítá cizí root,
  symlink, hardlink, traversal a zvláštní soubor. Chybějící soubor je chyba, nikoli důkaz zamítnutí.
  Záměrně propustná fixture dá FS-01 `syntheticFailed` a souhrnný exit **1**.
- **H1 modely:** start ve `stopping`/`stopped` je odmítnut bez změny stavu/identity; návrhové UID
  se uvolní až při `cleaned`. Helper i broker dekodéry přijmou validní controls a odmítnou osm
  konkrétních neplatných wire fixtures. Návrhová UID se nikdy nepoužívají k OS operacím.
- **Skutečná protistrana:** samostatné listen/report procesy přijmou před/po kontrolní kanárky
  a povolenou NET-12 fixture s přesnými raw bajty; izolovaný NET-02 běh má nula kontaktů/bajtů.
  Záměrný bypass opravdu otevře TCP a odešle kanárek: NET-02 se změní na `syntheticFailed`, exit **1**.
  Odebrání závěrečného `stopped` z vlastního logu opravdu vrátí report exit **3** a NET-02 `incomplete`.
  Nulabajtové TCP spojení nevyhoví oracle „žádný kontakt“; nesprávné raw bajty, kanárek, počty,
  neúplný report nebo nesouhlas exit kódu nemohou potvrdit pozitivní kontrolu.
- **Neúplnost a identita:** chybějící pokus, kontrola, úplnost nebo shodná identita nemohou projít.
  Injektovaný identity mismatch ukončí runner před fixture/protistranou a nevytvoří audit akcí.
- **H1 audit:** `AuditLog.decode` přečte výstup runneru s akcemi `zone.created`,
  `gate.request.denied`, `zone.cleaned`, sekvencí 1–3, stejnou oblastí a skutečným actor UID.
  Neplatná sekvence i vymyšlená akce jsou odmítnuty původním H1 kontraktem.
- **Úklid a CLI:** úklid je idempotentní, symlink nesmaže cíl mimo vlastní strom a výměna kořene
  je odmítnuta. Timeout ukončí vlastní testovací proces. CLI bez argumentů vypíše přesný katalog;
  `run` bez `--apply` vrátí **2**; platný úplný syntetický běh vrátí **3**.

## Hranice a předání

Toto je ověření **přípravného balíku**, žádný laboratorní důkaz. Stejné UID, mock rozhodnutí,
krátké loopback intervaly, H1 model a wire validace neprokazují izolaci procesů/sítě/souborů,
konkrétní systémovou identitu klienta, globální UID allocator, APFS, whole-UID admission,
TCC/podpisy, XPC transport/Mach práva, fyzická zařízení nebo skutečné integrační účty.
Katalog popisuje cílové kroky, ne potvrzení jejich provedení. Skutečný běh pod UID oblasti
patří až do WP2.8/laboratoře s příslušnými branami, přeregistrací a nezávislým review.

Původní implementační balík měnil COVERAGE pouze v řádku **WP1.H6**. Jeho ✅ znamená dokončený katalog, runner a testy;
všech 155 akceptací, brány a R1–R8 zůstávají beze změny. Sdílené kontrakty/WP0.3/WP0.4 ani
historické protokoly nebyly upraveny. Podrobné bezpečné spuštění a omezení: [README](README.md).

## Oprava katalogu po nezávislém review PR #76 — 2026-11-14

Review verze `2920b24` odhalilo nesprávné pořadí RB-03: vytvoření startup/job kanárku před baseline
snapshotem by jej při správné obnově zachovalo. Opravený postup nejdřív snímkuje quiescent celou
restore unit bez této perzistence, potom ji vytvoří a kontrolou potvrdí její existenci a nakonec
po dalším quiescence obnoví baseline. Oracle požaduje odstranění přidaného startup stavu a
nemožnost jeho opětovného spuštění.

Při kontrole sousedních RB-01…10 a souvisejícího HB-07 byly zpřesněny ještě dva ruční postupy:
RB-04 nyní výslovně zaznamená a snímkuje baseline před mutacemi všech kořenů; RB-10 provede
kontroly host nástrojů před změnou, během aktivního zpevnění i po úklidu a odkazuje přímo na
`spikes/s4-host/HARDENING.md`. Ostatní kontrolované kroky neobsahovaly obdobné obrácené pořadí.
Opora: PLAN §stav/rollback a S4, B4 `RECOVERY.md`/`TOOLING.md` a B2 `HARDENING.md`.

Testovaný opravený katalog má Git blob **`5c92516f03fe70a2fd11684edab841b57eac4434`**:

| Příkaz | Výsledek |
|---|---|
| `swift test --package-path proto/escape --scratch-path /private/tmp/h6-swift-build -c debug --filter CatalogTests` | **7 testů, 1 suite, 0 selhání**. |
| `swift test --package-path proto/escape --scratch-path /private/tmp/h6-swift-release -c release --filter CatalogTests` | **7 testů, 1 suite, 0 selhání**. |
| `git diff --check` | Bez chyby whitespace. |

Tyto testy znovu ověřily načtení změněného resource, přesný katalog, unikátnost a nemožnost
povýšit ruční případ na pass. Sémantické pořadí ručních kroků je výsledkem review, nikoli testu
porovnávajícího pořadí slov. Runtime, schéma, sondy a testy se nezměnily; předchozí úplné běhy
18 testů zůstávají zaznamenané výše. Oprava mění pouze tři ruční položky katalogu a tuto poznámku;
COVERAGE, všech 155 akceptačních stavů i historická evidence zůstávají beze změny.

## Review po integraci H3 — 2026-11-14

Základ je sloučené H3 `main` **`e21c31de019c704643eed743b3518959fac34dfb`**. Větev #76 jej
převzala normálním merge **`6c5b092439c67213242c33171c0f52d2d3adc46b`**, bez přepisování historie.
Nezávisle znovu zkontrolován celý H6 diff: Package.swift, všechny zdroje/testy, všech 155 položek
katalogu včetně kroků/oraclů, použitý H1 lifecycle/wire/audit a WP0.3/WP0.4, CLI, řízení potomků,
identita, souborové/síťové hranice a tvrzení vůči PLAN/IMPLEMENTATION/GUIDE. Původní opravy
RB-03/RB-04/RB-10 z `05e27f8` zůstávají beze změny; katalog má stále blob `5c92516f03fe70a2fd11684edab841b57eac4434`.

**Výsledek review:** žádná další oprava runtime nebo katalogu není potřeba pro vymezené offline
dokončení H6. Opraveno zastaralé předání po H3: H6 již není rozpracovaná/volná příprava a skutečný
součet F1 je **21 hotových / 6 rozpracovaných / 9 nezahájených**. Doplněno konkrétní předání WP2.8
a zbývající H4/A2/A3/A6 práce. Upřesněn jediný komentář `IdentityGuard` a odpovídající README:
preflight ověřuje původní non-root same-user kontext, neumí určit, zda UID patří do skutečného
registru oblastí. Nedokazuje tak autorizaci oblasti; runner nemění ani nevybírá OS identitu.
Výkonný kód a verzované testy jsou proti uvedenému merge beze změny.
Swift build/test a doplňkové CLI kontroly níže použily zdroje/binárky post-merge headu
**`6c5b092439c67213242c33171c0f52d2d3adc46b`** a proběhly před finálním dokumentačním
commitem `a04ca04ebd3c5a596a443e2ba109e65454ad2f54` s jedinou změnou komentáře ve zdrojích.
Lokální výsledky se nevydávají za test tohoto ani následujícího headu; **přesný finální head
#76 musí znovu projít CI před merge**. Tato navazující poznámka upřesňuje pouze původ evidence.

Prostředí: Apple Silicon `arm64`, macOS **27.2.1 (26B131)**, Xcode **27.2 (27B52)**,
Apple Swift **6.4.2**, repo testy Python **3.15.2**. Čistý scratch
`/private/tmp/h6-post-h3-review-20261114/build` vznikl pro tuto revizi:

| Ověření | Výsledek |
|---|---|
| `swift build --package-path proto/escape --scratch-path /private/tmp/h6-post-h3-review-20261114/build -c debug` a následné `swift test` se stejnými argumenty | Build všech produktů; **18/18 testů, 4 suites**, 16,211 s. |
| Stejné build/test příkazy s `-c release` | Build všech produktů; **18/18 testů, 4 suites**, 22,784 s. |
| Nezávislé procesní CLI scénáře v obou sestaveních | **14/14**: explicitní plan, chybějící apply, relativní counterpart, neznámý argument, chybějící executable, předčasný exit, readiness deadline. |
| `python3 -B -m unittest discover -s tools/tests` s nativním přístupem k vlastním procesům | **94/94**, 39,634 s. |
| `python3 -B tools/progress.py --out /private/tmp/h6-post-h3-review-20261114/progress` + kontrola skutečných řádků/odkazů | Stránka sestavena; F1 **21/6/9**, přesných **155 ID**, 8 synthetic / 133 manual / 14 unsupported; lokální reference existují. |
| Read-only `tools.lab_evidence` nad dokumentovaným M1 během a `docs/spikes.md` | **consistent**, 21 souborů, žádný finding; acceptance stále **unverified**, bez zápisu do evidence. |
| `git diff --check`; porovnání rozsahu vůči `origin/main` | Bez whitespace chyb; PLAN, H1, common, CI, tools a historická evidence beze změny. |

Běhy 18 testů v každém sestavení skutečně znovu sestavily lokální counterpart a ověřily pozitivní
controls, záměrný TCP leak (`syntheticFailed`/exit 1), odebraný stopped event (`incomplete`/exit 3),
H1 audit, přesné kanárky a úklid. Doplňkové CLI scénáře s chybějící/předčasně končící/tichou
protistranou vždy vracejí exit 3, šest syntetických úspěchů a dvě neúplné síťové sondy; nic z toho
se nemění na skutečný pass. Readiness deadline ukončil vlastní spící child, nevznikl žádný nový
zbylý `sanjbox-h6-*` strom. Logy a samostatný kontrolní skript jsou lokálně pod
`/private/tmp/h6-post-h3-review-20261114/`; nejde o laboratorní protokol.

První repo discovery v sandboxu mělo **8 watchdog failures**: `/bin/ps` bylo odmítnuto
(`Operation not permitted`), navazující scope/readiness assertions nemohly projít. Tento pokus
zůstává v `repo-tests.log`; úspěšný nativní běh je v `repo-tests-native.log`. Repo testy ani
watchdog nebyly kvůli tomu změněny. Lokální Python 3.15 výsledek nenahrazuje povinné CI na jeho
verzích Pythonu/macOS; před merge #76 musí projít kontroly přesného finálního headu.

**Stav a další agent:** README, IMPLEMENTATION §0, COVERAGE a oba H3/H6 handoffy nyní uvádějí
dokončení pouze offline. Sekce požadavků/bran/akceptací jsou byte-for-byte stejné jako `main`:
všech **8 požadavků, 10 bran F1 a 155 případů zůstává Neověřeno**. Řádky a vlastníci
**H4/A2/A3/A6/D5/G2** jsou rovněž beze změny. Pokračovat může přidělený vlastník H4 adaptérem
H1 politiky nebo vlastník A2/A3/A6 přesně popsaným zbytkem přípravy; nový claim vyžaduje předání.
D5 čeká na U4 a zůstává fail-closed, G2 je zmrazené, U0/U1/U5 a laboratorní akce patří uživateli.
WP2.8/2.7 čekají na vstup F2; H2/H3/H6 se před branami nespojují do běžící oblasti.
Merge #76 lze doporučit po kontrole finálního headu a jeho CI v tomto rozsahu; žádný výsledek
nedokazuje nativní izolaci, autorizaci, whole-UID admission, APFS, TCC ani síťové failure modes.
