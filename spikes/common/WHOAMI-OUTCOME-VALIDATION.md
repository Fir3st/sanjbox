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
