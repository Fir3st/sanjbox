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


## Následné nezávislé review — adresní domény (2026-11-08)

Review commitu `aa6c234` našlo další neplatné běhy přijímané jako úplné: nativní IPv6
endpoint a IPv4-mapped IPv6 endpoint mají oba 16 bajtů, ale nemohou tvořit dvojici TCP
ani UDP s konkrétním bindem. Opravený zdroj: `0c44d8266e7aa0bbae938ff60ef780f07164631c`.
Původní výsledky výše zůstávají zachované; toto je nové ověření ve stejném prostředí
stejnými příkazy a s novými dočasnými soubory.

**Debug i Release: 55 testů prošlo, 0 selhání** (30 counterpart + 18 ProbeKit + 7 provenance).
Nová regrese má 18 případů přes report API i CLI: obě chybná pořadí endpointů pro TCP/UDP,
ekvivalentní dotted/hex zápisy, platné nativní/mapped dvojice, UDP wildcard a Darwin
mapped UDP listener s prostým IPv4 zdrojem. Celkem je v každé konfiguraci 29 CLI spuštění.
Neplatné dvojice vracejí 3 a zachovávají kontakt, 8 bajtů a nález; platné dvojice vracejí 1.
Nový skutečný TCP test na `::1` ověřil nativní endpointy z `accept`/`getsockname`, zatímco
stávající loopback testy dále ověřují mapped TCP a UDP s prostým IPv4 zdrojem.

Navíc obě hotové binárky odmítly všechny čtyři původní JSONL reprodukce review (2 TCP,
2 UDP; **8 kontrol**): exit 3, `complete=false`, zachovaný jeden kontakt bez bajtů.
Velké build/cache adresáře byly po ověření kopií binárek odstraněny. Omezení parseru
a důkazů uvedená výše se nemění.

## Nezávislé předslučovací review (2026-11-13)

Ověřený zdroj: `97b966c9b1c0ad06c12c4e98c83e124e8551a9dc`; review životního cyklu,
identity a domén endpointů, zachování pozorování při chybě a mezí parseru nenašlo další
blokující závadu. **Debug i Release: 55 testů prošlo, 0 selhání** (30 counterpart,
18 ProbeKit a 7 provenance), včetně 29 CLI regresí v každé konfiguraci.
Prostředí: arm64, macOS 27.2.1 (26B131), Xcode 27.2 (27B52), Apple Swift 6.4.2;
stejné build příkazy s novým dočasným adresářem jako výše. První běh v omezeném
sandboxu nemohl bindovat sockety (`Operation not permitted`); úplné ověření proběhlo
mimo toto omezení a nepotřebovalo privilegované operace.

Navíc čtyři skutečné Debug CLI běhy `listen` → syntetická loopback data → SIGTERM →
`report` ověřily bindy `127.0.0.1`, `0.0.0.0`, `::1` a `::`; poslední přijal IPv4 i IPv6.
Celkem pět TCP spojení, pět UDP datagramů a 100 bajtů: všechny reporty byly úplné,
vrátily exit 1 a správné počty bajtů, kontaktů i raw souborů. Všechny vlastní listenery
byly zastaveny a běhové soubory uklizeny. Jde o dokončený implementační follow-up
podle GUIDE §11; bez nového verdiktu S3/S5/S7, autentizace logů nebo změn starých důkazů.
