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

Podmínka offline dokončení H3 z IMPLEMENTATION §0 je splněná. Původní implementační změny
se omezily na `proto/cli/` a vlastní řádek H3; H1 schéma a akceptační evidence se nezměnily.
Nový Package.swift a jeho lokální dependency na contracts odpovídají automatickému CI discovery.
Tato původní lokální validace netvrdila vzdálené CI ani nezávislé review; jejich následné ověření
a rozšíření dokumentačního rozsahu jsou zaznamenané v dodatku níže.

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

## Nezávislé review a předání 2026-11-14

Znovu zkontrolován celý diff PR #75 vůči `main`
`5d2005a6398249bcdbcebba0fd98928c29d193c0`, zdrojový head
`48c27931ac38dc74e891a63ba4efd5ba1ca7abf1`. Prostředí stejné jako výše, navíc
Xcode 27.2 (`27B52`). Review zahrnulo všechny zdroje/testy H3, použitý H1 wire kontrakt,
hranice argv/ID/cest, korelaci úspěšných i chybových odpovědí, NSXPC lifecycle, souběh,
deadline, neznámý výsledek bez retry, rozsah restore unit a tvrzení dokumentace.

**Nález:** plán stále nabízel H3/H6 jako volné a souhrn COVERAGE uváděl F1 19/6/11,
ačkoli zdejší H3 již bylo hotové. Opraveno na **20 hotových / 6 rozpracovaných /
10 nezahájených**; H6 je výslovně obsazené v otevřeném, dosud nesloučeném PR #76.
README, IMPLEMENTATION §0 a předání WP2.7 nyní uvádějí skutečný rozsah a další práci.
Ve zdrojovém kódu nebyl nalezen další problém vyžadující opravu; zdroje H3/H1 ani
verzované testy tento dokumentační commit nemění.

Čisté sestavení všech produktů a kompletní testy byly spuštěné z H3 worktree:

```sh
swift build --package-path proto/cli --scratch-path /private/tmp/sanjbox-pr75-review-20261114 -c debug
swift test --package-path proto/cli --scratch-path /private/tmp/sanjbox-pr75-review-20261114 -c debug
swift build --package-path proto/cli --scratch-path /private/tmp/sanjbox-pr75-review-release-20261114 -c release
swift test --package-path proto/cli --scratch-path /private/tmp/sanjbox-pr75-review-release-20261114 -c release
```

Výsledek **34/34 Debug a 34/34 Release, bez compiler warningů**, v obou sestaveních
včetně 13 procesních scénářů již zahrnutých v původních čtyřech ExecutableTests.
Další nezávislé ověření mimo verzovanou sadu:

- **6/6 doplňkových XCTest v Debug**, na `git archive` kopii stejného headu v
  `/private/tmp/sanjbox-pr75-adversarial-20261114`: osm souběžných XPC požadavků a
  jedinečné handly; 200 souběžných admission pokusů s přesně 128 přijetími a 72 odmítnutími;
  nadlimitní odchozí frame bez připojení; duplicitní JSON klíč přes Unicode escape bez mutace;
  NaN/infinity/záporný/nulový/příliš dlouhý timeout stále skončí přes dvousekundový limit;
  odmítnutý restore/snapshot nemění kořeny, snapshoty ani host policy.
- **4/4 další procesní scénáře v Debug i Release**: vytvoření snapshotu, jeho odmítnutí
  v nové invokaci, dostupná čerstvá `baseline` a neexistující executable s doslovnými
  shell metaznaky. Vlastní syntetický soubor, který by vytvořila expanze, nevznikl.

Doplňkové testy a logy jsou dočasné lokální artefakty review, nejsou novou sadou v CI
ani laboratorním důkazem. Šest metod je v `ReviewAdversarialTests.swift` pod uvedenou
kopií, spouštěné přes `swift test --filter ReviewAdversarialTests` s vlastním scratch path.
Čtyři další procesní scénáře používají pouze vlastní binárku, dočasný kanárek a šestisekundový
subprocess timeout; nespouští cizí workload.

Repo kontroly používaly existující `tools/tests` beze změny kódu:

```sh
python3.11 -B -m unittest discover -s tools/tests -v
python3.11 -B tools/progress.py --out /private/tmp/sanjbox-pr75-progress-review
git diff --check
```

Finální plný běh s **Python 3.11.4: 94/94, 0 skips** (38,459 s), tedy stejná major/minor
verze a stejný discovery jako CI. Předchozí neúspěšné pokusy zůstávají rozlišené:

- Python 3.15.2 v sandboxu vykonal 94 metod, ale měl `failures=8` v watchdog subcases.
  Sandbox odmítl `/bin/ps` (`Operation not permitted`), takže nešlo ověřit scope/cleanup;
  související readiness/timing assertions také nemohly projít.
- Diagnostický plný běh systémovým Python 3.9.6 mimo sandbox s `-I -B` měl 49 úspěchů
  a jednu import chybu `test_lab_evidence` (`tools` není v izolovaném import path).
  Tato nevhodná kombinace plného discovery a `-I` selže stejně i na čistém `main`;
  CI v `tools/tests` používá `-I` jen pro watchdog sadu, jejíchž **24/24** zde prošlo.
- První plný běh Python 3.11.4 mimo sandbox měl 93/94 úspěchů: watchdog FIFO fixture
  jednou nedosáhla ready před svým 0,3s limitem. Cílený stejný test pak prošel na H3 i
  čistém `main`, následně prošlo celé discovery 94/94. Jde o pozorovanou nestabilitu
  lokální přípravy fixture, nikoli opravu či doloženou regresi H3; tento pokus se neskrývá.

`git diff origin/main -- tools .github` byl prázdný. Výše uvedené lokální komplikace
nejsou důvodem přeskočit povinné finální CI. Logy jsou pod `/private/tmp/sanjbox-pr75-*`.

Projektový stav a handoff jsou ověřené i parsováním skutečných COVERAGE/IMPLEMENTATION a
sestavením stránky přes `tools/progress.py`: souhrn balíků odpovídá řádkům, všech 10 bran F1
a 155 akceptačních případů zůstává Neověřeno. `git diff --check` prochází. Řádek H6 se v #75
nemění; jeho validaci a případné opravy posuzuje samostatné review #76.

Původní CI na `48c2793` prošlo v
[běhu 43526047577](https://github.com/Fir3st/sanjbox/actions/runs/43526047577), včetně
Swift Debug/Release, obou Python jobů a `CI required`. To není potvrzení CI nového
dokumentačního commitu: před merge musí projít kontroly jeho přesného finálního headu.
Merge H3 lze doporučit v offline rozsahu po tomto CI; žádný výsledek zde neotevírá F2
ani neuzavírá autentizaci helperu, nativní izolaci, APFS/UID/PTY nebo laboratorní brány.
