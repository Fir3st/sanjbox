# WP0.3 — pravdivý výsledek diagnostiky whoami

Ověřeno 2026-11-08 na čistém zdrojovém commitu `0267d187cc0ea6778bd44f2409dca742fe0f4d75`.
Konfigurace: arm64, macOS 27.2 (26B123), Xcode 27.2 (27B52), Apple Swift 6.4.2
(`swiftlang-6.4.2.1.9`).

`swift test --package-path spikes/common --configuration debug` i `release` prošly: **36 testů
v každé konfiguraci, 0 selhání** (11 XCTest + 25 Swift Testing). Build, cache a TMPDIR používaly
vlastní adresář pod `/private/tmp`. Stávající CI spouští stejné testy v obou konfiguracích.

Čtyři nové `WhoamiCLITests` spouštějí skutečnou binárku ze stejného build adresáře: diagnostika
s logem (`unclear`, nevyhodnocené `valid`, exit 0), diagnostika bez logu (exit 0), shoda očekávaného
vlastního efektivního UID (`passed`, `valid: true`, exit 0) a neshoda (`invalidMeasurement`,
`valid: false`, exit 3). Ověřují stdout, JSONL včetně kontextu a neshod, case ID a návratové kódy;
čekání na vlastního potomka je omezené na 10 s a čtení každého výstupu na 64 KiB.

Jde o regresní testy ve vlastní relaci a stávající lokální loopback fixtures balíku, nikoli o laboratorní
běh nebo důkaz izolace. Formát `RunRecord`, stdout a historické protokoly zůstávají beze změny.

## Nezávislé integrační review PR #66 (2026-11-13)

Ověřený source/test commit: `0af9d6901a3fd023ce9b1a769a07f9786e3377e8`, po lokální
integraci `main` `ebfc1ded94d0514f328a535c437c3611862e3e8e`. Prostředí: arm64,
macOS 27.2.1 (26B131), Xcode 27.2 (27B52), Apple Swift 6.4.2 (`swiftlang-6.4.2.1.9`).
Review nenašlo další produkční závadu v mapování tří stavů `valid` na outcome; doplnilo
stávající čtyři CLI testy o přesné top-level klíče stdout a `RunRecord` a prázdné `details`.
Samotné dekódování `Bool?` nerozlišovalo chybějící `valid` od JSON `null`.

- **74/74 testů Debug i Release**, 0 selhání: 4 whoami CLI + 18 dalších ProbeKit +
  45 counterpart + 7 provenance (11 XCTest a 63 Swift Testing). Tím prošly i společné
  regrese striktního counterpart reportu z PR #64 a vlastnictví výstupů z PR #69.
- **15/15 dalších CLI scénářů v každé konfiguraci (17 spuštění):** bez argumentů;
  diagnostický log bez/s case ID; shodné a neshodné efektivní UID s/bez logu; zakázaný
  současný audit session ID při správném UID; shoda UID/GID a dostupných session polí;
  append tří různých výsledků do jednoho logu; prázdné/chybné/chybějící očekávání;
  chybějící hodnota přepínače; chyba zápisu logu. Ověřeny návratové kódy, stdout a JSONL
  klíče, shoda kontextu/neshod i absence úspěšného reportu při chybě I/O nebo vstupu.
- **Negativní kontrola Debug:** oddělená dočasná kopie stejného zdroje s původním
  `mismatches.isEmpty ? .passed : .invalidMeasurement` spustila čtyři whoami CLI testy.
  Přesně test diagnostiky s logem selhal (`passed` místo `unclear`), zbývající tři prošly.
- **63/63 Python tools testů**, `git diff --check` bez nálezu. Ověření coverage zachovalo
  všechny řádky kromě poznámky WP0.3 a všechny stavy požadavků, případů a bran.

Příkaz pro každou konfiguraci s vlastním scratch adresářem:

```sh
CLANG_MODULE_CACHE_PATH="$whoami_scratch/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$whoami_scratch/module-cache" \
swift test --disable-sandbox --package-path spikes/common --configuration debug \
  --scratch-path "$whoami_scratch/build" --cache-path "$whoami_scratch/package-cache" \
  --config-path "$whoami_scratch/config" --security-path "$whoami_scratch/security"
python3 -B -m unittest discover -s tools/tests -v
```

Pro Release se změnila konfigurace a scratch cesta. Testy běžely mimo omezení sandboxu
kvůli existujícím loopback a membership kontrolám, bez privilegovaných operací.
Malé logy, `cli-review.py` a sanitizované `cli-debug.json`/`cli-release.json` jsou v
`/private/tmp/sanjbox-pr66-review.W4OaBjbU/`; vlastní běhové fixtures byly odstraněny.
První externí harness pokus použil neexistující starší SwiftPM cestu, takže nespustil
žádnou binárku; finální běhy použily skutečné `build/out/Products/{Debug,Release}`.

Souvislost s PR #64 je sémantická: chybějící důkaz neznamená úspěšné měření. Diagnostika
whoami bez očekávání je dovolená a nevyhodnocená (`unclear`, exit 0); neúplný counterpart
report a nesoulad whoami s očekáváním nadále znamenají neplatné měření (exit 3).
[A4 preflight](../s0-boundary/LAB-PLAN.md) stále vyžaduje `--expect` s členstvími skupin
a ruční porovnání všech dalších předregistrovaných polí, včetně kernel groups, pozitivního
ASID a auditUID. Opraveno je pouze jeho chybné tvrzení o `valid: null`: klíč se vynechává.
Tyto výsledky neprokazují izolaci ani průchod brány; historické protokoly a akceptace jsou
beze změny. Následná integrace PR #65 a vzdálené CI finální větve patří integrátorovi.
