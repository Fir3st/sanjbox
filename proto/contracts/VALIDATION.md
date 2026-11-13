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
