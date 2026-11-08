# WP0.4 — regrese validace reportu (2026-11-08)

Review našlo falešný úspěch: `started`, `accepted` bez `flowID`, `closed` bez `flowID`
s 8 bajty, `stopped` dávaly úplný běh bez kontaktu a CLI exit 0. Stejně prošel běh
s prázdným seznamem listenerů. Oprava je nový, konečný review balík; nemění staré důkazy.

Ověřený zdrojový commit: `aa6c2342f8ecd463bc6c42179b7b8025dfbed4fd`.
Prostředí: aktuální Mac, arm64, macOS 27.2 (26B123), Xcode 27.2 (27B52), Apple Swift 6.4.2.

| Ověření celého `spikes/common` | Výsledek |
|---|---|
| `swift test --configuration debug` | **53 testů prošlo**, 0 selhání |
| `swift test --configuration release` | **53 testů prošlo**, 0 selhání |

Každá konfigurace: 28 testů counterpartu, 18 ProbeKit, 7 network provenance. Počty jsou
součtem deklarovaných testů podle Swift Testing/XCTest; parametrické a vnitřní případy
nejsou vykazované jako další deklarované testy. Sdílené knihovny se nezměnily.

Regrese zahrnují chybějící/null a zakázaná pole pro každý druh události, neprázdné
jedinečné listenery, pozitivní ID bez mezer/opakování, pořadí a identitu toků, numerické
endpointy včetně wildcard a Darwin dual-stack UDP, metadata raw capture, záporné počty,
`Int.min`/`Int.max`, přetečení součtu a omezenou diagnostiku se zachováním dalších pozorování.
JSONL round-trip zachovává stávající formát. CLI test má 11 spuštění na konfiguraci:
platné ticho → 0, TCP s bajty/bez bajtů a prázdné UDP → 1, chybějící ID, prázdné listenery,
duplicita, špatné pořadí a přetečení → 3; chybná syntaxe a chybějící soubor → 2.

Skutečné lokální socketové testy ověřily TCP bez bajtů, TCP s kanárky, UDP s kanárky/DNS,
prázdný UDP datagram, dočtení otevřených TCP spojení při stop a platný běh bez kontaktu.
Listenery testů jsou vázané na `::ffff:127.0.0.1`, odesílatelé na IPv4 loopback; testy
uklízejí vlastní soubory a zastavují vlastní protistrany. Bez externích zařízení, změn hosta
nebo privilegovaných operací.

Sestavení použilo vlastní dočasný adresář pod `/private/tmp`; ekvivalent příkazů z kořene repa:

```bash
scratch=$(mktemp -d /private/tmp/sanjbox-counterpart-validation.XXXXXXXX)
for configuration in debug release; do
  CLANG_MODULE_CACHE_PATH="$scratch/clang-cache" SWIFTPM_MODULECACHE_OVERRIDE="$scratch/module-cache" \
    swift test --disable-sandbox --package-path spikes/common --configuration "$configuration" \
    --scratch-path "$scratch/build" --cache-path "$scratch/package-cache" \
    --config-path "$scratch/config" --security-path "$scratch/security"
done
```

Jde o implementační regresi podle GUIDE §11, **ne o průchod S3/S5/S7**. Report
neautentizuje log, neověřuje obsah raw souborů ani skutečnou izolaci. Sdílený parser načítá
celý JSONL soubor, ignoruje neznámé klíče a nekontroluje striktně duplicitní klíče objektů;
tato oprava validuje dekódované události. Podrobnosti kontraktu: [README](README.md#sanjbox-counterpart).
