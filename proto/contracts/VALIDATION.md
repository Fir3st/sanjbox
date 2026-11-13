# WP1.H1 — offline validace dokončených kontraktů

Datum: 2026-11-13. Testovaný implementační commit:
`510b0bf21865b9352c286fae6aa9462820f038ce`, nad přímým základem main
`6477806c0e99fa5abf2b1b4a8c4f5ab9d8187825`; claim předání `7b89e0e`.
Prostředí: Apple Silicon, macOS 27.2.1 (26B131), Apple Swift 6.4.2
(`swiftlang-6.4.2.1.9`, Swift language mode 6). Jde o vývojové testy, nikoli laboratorní běh.

## Výsledek H1

| Kontrola | Výsledek |
|---|---|
| `swift test --package-path proto/contracts --scratch-path /private/tmp/h1-completion-build -c debug` | **124 testů / 11 suites prošlo**, včetně sestavení; test fáze 6,561 s |
| Stejný příkaz s `-c release` | **124 testů / 11 suites prošlo**, včetně release sestavení; test fáze 7,133 s |
| `python3 proto/contracts/tools/test_manifest_parity.py` | **140 syntetických případů, všech 48 finding kódů B3; úplné reporty shodné**; navíc automaticky v obou Swift bězích přes `B3ParityTests` |
| `git diff --check` | Prošlo |

Broker testy pokrývají všechny tři skutečné zprávy, role/směr, zone/stream binding, sequence replay,
rozměry/coordinates, attachment index/count, neznámé typy/verze/pole, chybějící a chybně typovaná
pole, duplicity, přesné celočíselné zápisy a byte/field hranice v encode i decode. Ani kladný
mock kontext neověřuje skutečnou identitu nebo Mach právo.

H3 testy pokrývají shell/run/pause/resume/snapshot/rollback, explicitní argv a relativní root odkazy,
zakázané dodatečné kanály, velikosti argumentů, typed success/failure replies a korelaci s požadavkem.
Run/shell success znamená admission s execution handle, ne skutečné spuštění/exit status.

Manifest testy přidávají odmítnutí dříve vynechaných pravidel přes validate/encode/decode, přesné
severity varování, odvozené kořeny/svazky/rozpočty, overflow a encoded byte limit včetně JSON
escapování. Parity oracle kompiluje **aktuální** tři čisté B3 zdroje a aktuální H1 nezávisle,
porovnává všechny report fields a vyžaduje výsledek každého případu. Zahrnuje oba originální
syntetické MVP/F4 příklady a negativní mutace všech 48 sémantických finding kódů. Chybějící B3
zdroj nebo `swiftc` je jasná chyba, nikdy skip; kompilace má timeout 90 s na program, běh 30 s,
celý test zůstává pod existujícím 300 s CI watchdogem. Dočasný vlastní adresář se uklidí.

Stávající testy lifecycle (10 povolených a 54 zakázaných dvojic, crash points, LC-06/LC-11), sítě,
auditu a striktního JSON zůstaly zelené. Síť navíc odmítá IP literály v DNS upstream poli,
včetně zkrácených, octal a hexadecimal dotted IPv4 forem. Politika H4 se tím nerozšiřuje.

## Doplňková repo sada — omezení sandboxu

`python3 -B -m unittest discover -s tools/tests` spuštěné v základním sandboxu:
**87 testů, 8 failures (125,259 s)**, všechny v nezměněném `test_watchdog.py`.
Šest failures výslovně uvádí `Operation not permitted: '/bin/ps'` a návrat watchdogu 125 místo
čekaného statusu (clean-exit 0/7/124, exec failure, orphan status 9, signal exit). Zbylé dvě jsou
časový limit orphan fixture (4,183 s místo <4 s) a `owned reporter did not start`.
Tento běh není zelené ověření repo watchdogu; vliv omezeného prostředí je doložen zákazem `ps`,
ale příčinu zbylých dvou failures samotný výstup nerozlišuje. H1 tyto zdroje ani CI nemění;
opakování v prostředí s povoleným procesovým přehledem patří k ověření CI, nikoli opravám H1.

## Hranice výsledku

Pouze syntetické dokumenty, mock delivery context a zdrojový parity oracle; žádná systémová změna,
privilegovaný příkaz, skutečný uživatel/oblast, APFS, XPC, signing, audit-token autentizace, Mach
přenos, síťové vynucení nebo process/stdio adaptér. Historické evidence ani cizí výsledky se nemění.
H1 je hotový offline balík; všechny brány, R1–R8 a runtime integrace zůstávají Neověřeno.

## Navazující opravy nezávislého review — 2026-11-13

Nezávislé Astra xhigh review původního dokončení našlo dva P2 nálezy. Původní výsledky výše
zůstávají zachované; tento doplněk popisuje opravy a nové ověření na commitu
`80dab00e9480f8666182946517c5ca9f314f8ec0` (obsahuje také síťovou opravu
`b54d269be45f6d9e97acadbfed3d0690fadbf66f`).

1. **Legacy IPv4:** bare hex komponenta `0x` obcházela lexikální výluku a review doložilo, že
   `127.0x.0x.1` může být Darwin parserem interpretováno jako loopback. Oprava považuje i prázdnou
   hex číselnou část za numeric-looking a odmítá celý takový adresní zápis. Nový test odmítá
   15 číselných/legacy zápisů v `Identifier`, typed gate validaci, policy encode i wire decode;
   zahrnuje uppercase varianty (H1 nemá lowercase normalizaci vstupu). Tři skutečné DNS názvy
   s numeric-looking labelem nadále projdou. Všechny vstupy jsou syntetické, bez DNS/socket operací.
2. **B3-only CI:** změny `spikes/s4-state/Sources/`, `examples/` nebo `SCHEMA.md` nyní výslovně
   vybírají `proto/contracts` a jeho případné SwiftPM dependenty. Je to testovací vazba, nikoli
   runtime package dependency. `--no-renames` zachovává starou cestu i při přesunu zdroje mimo B3;
   chybějící H1 balík je chyba. Sedm nových Python testů vykonává skutečný discovery blok workflow
   nad syntetickými Git výstupy/manifesty, včetně B3-only, smazání/přesunu, chybového grafu,
   nezávislých změn, `.github` změn a všech stávajících event fallbacků.

| Kontrola na opraveném stromu | Výsledek |
|---|---|
| `swift test --package-path proto/contracts --scratch-path /private/tmp/h1-completion-build -c debug` | **125 testů / 11 suites prošlo**, test fáze 6,903 s |
| Stejný příkaz s `-c release` | **125 testů / 11 suites prošlo**, test fáze 6,389 s |
| Source-backed parity uvnitř obou Swift běhů | **140 případů / 48 B3 kódů**, úplné reporty shodné |
| `/usr/bin/python3 -I -B -m unittest discover -s tools/tests -p test_ci_selection.py -v` | **7/7 prošlo** |
| `/usr/bin/python3 -B -m unittest discover -s tools/tests -v` | **94/94 prošlo** za 41,470 s, Python 3.9.6, s povoleným `/bin/ps` |
| Ruby `YAML.parse_file` nad `.github/workflows/ci.yml` | Prošlo |
| Skutečné multiline `run` bloky workflow přes `/bin/bash -n` | **6/6 prošlo** |
| Skutečný `CI required` shell se syntetickými job statusy | **14/14 scénářů**: úspěchy včetně povoleného no-Swift skip a failure/cancelled/skipped každé závislosti |
| `git diff --check` | Prošlo |

Plná repo sada byla nejprve omylem spuštěna s `-I`: 49 testů prošlo včetně všech watchdog testů,
ale `test_lab_evidence` nešlo importovat (`No module named 'tools'`). Opravený příkaz výše používá
zdokumentovaný repository import mode a všech 94 testů prošlo; žádná změna existujícího tooling
nebyla kvůli této chybě příkazu potřeba. Dřívější sandbox-limited výsledek 87/8 zůstává historickým
záznamem, nová sada s povoleným procesovým přehledem není jím blokovaná.

Nové CI pravidlo a jeho regresní testy jsou zdokumentované v [docs/CI.md](../../docs/CI.md).
Neproběhl hosted GitHub Actions běh, push, PR ani merge. Hranice offline důkazu a stav bran výše
zůstávají beze změny.
