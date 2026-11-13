# WP1.H3 — offline validace

Ověřeno 2026-11-14 na macOS 27.2.1 (26B131), arm64, Apple Swift 6.4.2
(`swiftlang-6.4.2.1.9`, target `arm64-apple-macosx27.2.0`). Balík cílí na macOS 15+;
jiné OS buildy zde změřené nejsou.

- Podklad H1/H2: `main` `5d2005a6398249bcdbcebba0fd98928c29d193c0`.
- Claim pouze řádku H3: `a221bfa`, publikovaný na `origin/codex/wp1-h3-cli` před implementací;
  při převzetí nebylo otevřené PR ani jiný remote claim H3.
- Ověřený kód a testy: `6756cce3d13f33380d20b2d2a36841a0963af9ae`.
  Následující validační commit přidává tento záznam a mění pouze řádek H3 v COVERAGE.

## Spuštěné kontroly

```sh
swift test --package-path proto/cli --scratch-path /private/tmp/sanjbox-h3-build -c debug
swift test --package-path proto/cli --scratch-path /private/tmp/sanjbox-h3-build -c release
git diff --check
```

| Sada | Debug | Release | Co kontroluje |
|---|---|---|---|
| ParserTests | 6/6 | 6/6 | Pět příkazů → H1 kind, přesná syntaxe, doslovné argv, cesty/ID, 64 argumentů, 1024 B jednotlivě a 32 KiB celkem, NUL |
| XPCTests | 16/16 | 16/16 | Skutečné NSXPC round trips všech příkazů, H1 receiver, špatný kind/zone i failure, malformed/oversized reply a request, odpojení, timeout, neplatný vstup před připojením, late callback/consumer |
| MockTests | 8/8 | 8/8 | Admission/opaque handles, pause, neznámá zóna/root, plná restore unit a neobnovená host policy, quiescence/stopped model, unsupported operace a bounded historie |
| ExecutableTests | 4/4 | 4/4 | **13 procesních scénářů** vlastní binárky: pět příkazů, sedm odmítnutí, help; navíc bezpečné diagnostiky přes knihovní vstup |
| **Celkem** | **34/34** | **34/34** | **0 selhání**, bez compiler warningů |

Procesní scénáře binárky běží v test targetu, nejsou navíc k 34 XCTest metodám. Každý child má
watchdog a test čeká na jeho exit. XPC testy používají skutečný `NSXPCListener.anonymous()` a
`NSXPCConnection(listenerEndpoint:)`; assertions potvrzují počet přijatých spojení a přesnou
H1 zprávu zaznamenanou receiverem. Nejde pouze o injektovaný in-memory transport.

Při malformed požadavcích receiver přeruší spojení před mock mutací. Při wrong-kind/wrong-zone
odpovědi klient odmítne i syntakticky validní H1 reply. Test ztracené odpovědi provede admission
v mocku a až potom spojení uzavře: handle existuje právě jednou, klient hlásí neznámý výsledek
a není retry. Test tichého peeru doběhne přes deadline; samostatné deterministické latch testy
odmítnou pozdní callback i již připravenou success hodnotu čtenou po deadline.

Snapshot/rollback test nejprve zachytí všech šest kořenů, změní každý kořen i host control policy,
obnoví celý snapshot a ověří původní hodnoty všech kořenů, zachovanou novou host policy a stopped
stav. Jde o paměťové hodnoty, nikoli soubory nebo APFS.

## Rozsah a zbývající hranice

Podmínka offline dokončení H3 z IMPLEMENTATION §0 je splněná. Změny se omezují na `proto/cli/`
a vlastní řádek H3; H1 schéma a ostatní evidence/coverage se nemění. Nový Package.swift a jeho
lokální dependency na contracts odpovídají automatickému CI discovery; vzdálený CI běh ani
nezávislé review se tímto lokálním výsledkem netvrdí.

NSXPC je skutečné, ale server je **same-process mock** s privátním endpointem: žádné balení či
instalace samostatného helperu, host-only peer autorizace, audit token, podpis ani session nebyly
ověřeny. Každá CLI invokace má čerstvou fixture, pro snapshot paused a rollback stopped.
Neexistuje trvalý snapshot, skutečný workload, stdio/PTY ani exit status workloadu; `accepted`
znamená pouze paměťovou registraci execution handle. H2/B4 nejsou integrovány, fixture není
H1 manifest. Deadline neprokazuje, že helper operaci neprovedl, proto výsledek zůstává neznámý.

Neprováděly se OS UID operace, APFS, skutečné cesty z požadavků, launchd registrace, síť, TCC,
privilegované či systémové změny. Soubory s tajemstvími a credential stores se nečetly.
Všechny brány, 155 akceptačních případů a R1–R8 zůstávají **Neověřeno**. Nejde o laboratorní
protokol podle GUIDE §7; podle §11 jde o offline přípravu doloženou testy.
