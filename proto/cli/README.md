# CLI prototyp (WP1.H3)

Swift 6 `sanjbox shell/run/pause/snapshot/rollback` používá skutečné lokální NSXPC spojení k mock
helperu a jediný [H1 helper kontrakt](../contracts/README.md). Jde o izolovaný prototyp podle
[IMPLEMENTATION §0](../../docs/IMPLEMENTATION.md#0-co-dál), ne běžící MVP nebo důkaz brány.
`--mock` je povinné; žádná větev programu nepřipojuje skutečný helper ani nespouští zadaný program.

## Použití

**[implementátor]** Na macOS se Swift 6, bez externích balíčků:

```sh
swift build --package-path proto/cli -c debug
swift run --package-path proto/cli sanjbox --help
swift run --package-path proto/cli sanjbox --mock shell a1b2
swift run --package-path proto/cli sanjbox --mock run a1b2 --executable-root tools -- bin/probe 'two words' '' '--help'
swift run --package-path proto/cli sanjbox --mock pause a1b2
swift run --package-path proto/cli sanjbox --mock snapshot a1b2 checkpoint --restore-unit full-state
swift run --package-path proto/cli sanjbox --mock rollback a1b2 baseline --restore-unit full-state
```

Shell/run přijímají `--working-root ROOT` (výchozí `project`) a `--working-directory RELATIVE`
(výchozí `.`). Run vyžaduje `--executable-root ROOT` a oddělovač `--`, za nímž je relativní
executable a doslovné argumenty. Neprobíhá shell parsing, expanze, PATH lookup, čtení prostředí,
změna pracovního adresáře ani host `Process`/`exec`. Citování v uživatelově terminálu je jeho
obvyklá práce před předáním argv; CLI již obdržené řetězce nikdy znovu neinterpretuje.
Duplikované/neznámé přepínače, neúplné dvojice a nadbytečné položky se odmítnou.

Fixture má zónu `a1b2`, root IDs `home/project/prefix/tools/cache/tmp`, celou restore unit
`full-state` a počáteční snapshot `baseline`. **Každé spuštění začíná novou paměťovou fixture:**
pro snapshot ve stavu paused, pro rollback stopped, jinak running. Samostatný příkaz pause tedy
neovlivní další spuštění CLI; nový snapshot se mezi spuštěními neuchovává. Testy knihovny drží
jednu fixture přes více požadavků, ověřují změny všech kořenů a jejich úplné obnovení.

Shell/run vrátí `mock accepted ... execution=mock-exec-N; process completion unknown
(no process executed)`. Handle je opaque identifikátor navázaný na původní H1 požadavek a zónu
v dané fixture, není PID. Není implementované stdio, PTY, attach ani čekání na dokončení procesu;
žádný zadaný executable se neotevře. Pole H1 `accepted` se nikdy nepřekládá na dokončení workloadu.

| Exit CLI | Význam |
|---|---|
| 0 | Zobrazená nápověda nebo validní přijetí/dokončení **mock požadavku**; nikoli exit procesu |
| 64 | Chybná syntaxe či H1 vstup |
| 69 | Ztracené spojení / deadline; výsledek operace neznámý |
| 70 | Korelované H1 `failed` nebo interní chyba fixture |
| 76 | Neplatná nebo nekorelovaná odpověď; výsledek operace neznámý |

## XPC a hranice odpovědí

`MockXPCServer` vytváří `NSXPCListener.anonymous()`. Klient dostane jeho privátní
`NSXPCListenerEndpoint` přímo z kompozice a pro každý požadavek otevře nový `NSXPCConnection`.
Jde o skutečný Foundation/XPC transport a jeho reply callback, **mock helper žije ve stejném
procesu**, tedy i stejném uživateli. Neregistruje se launchd/Mach service, služba se nevyhledává
podle jména, endpoint se nepublikuje a netestuje se samostatný servisní proces. Tento omezený
mechanismus umožňuje ověřit transport a přerušení bez instalace, podpisů či systémových zásahů.

ObjC rozhraní má jedinou metodu `exchange(Data, reply: Data)`. Data jsou beze změny H1 envelope;
nevzniká další JSON DTO ani status wrapper. Receiver používá `HelperMessage.decode` **před**
paměťovou mutací. Malformed wire nemá důvěryhodný kind/zone, proto receiver uzavře spojení.
Klient používá `HelperReply.decode` a následně `reply.validate(for: request)` na reply kanálu
konkrétního požadavku. I korektní H1 odpověď pro cizí kind/zone se odmítne, včetně `failed`.

Každé spojení má deadline 2 s (knihovní/testový rozsah >0 až 10 s), uzavření v `defer` a latch,
kde vyhraje první konečný výsledek. Ztráta spojení, timeout a chybná odpověď nejsou úspěch;
pozdní callback ani pozdní konzument je neoživí. **Žádný automatický retry:** helper mohl operaci
přijmout před ztrátou odpovědi, což ověřuje test. Přenesená data jsou omezena H1 byte limity;
NSXPC objekt může být alokovaný před aplikační kontrolou velikosti, nejde o důkaz odolnosti vůči
paměťovému DoS. Fixture omezí současná spojení na 16 a historii požadavků/handle na 128.

## Co mock kontroluje

- Pouze známou zónu a její root IDs; ne čtení cest, symlinky, descriptor-relative rozlišení nebo
  skutečné oprávnění executable. Jakýkoli validní relativní executable v deklarovaném rootu je
  jen syntetický admission požadavek.
- Shell/run jen v running; pause přejde do paused a blokuje další admission. Mock drží handle,
  ale žádný OS proces, celé UID ani síť nezastavuje. Resume a další H1 operace se nevystavují.
- Snapshot jen v paused/stopped, bez přepisu existujícího ID; kopíruje všechny uvedené kořeny.
  Rollback jen v stopped, se známým snapshotem a přesným `full-state`; obnoví všechny kořeny a
  neobnovuje host control policy. Neexistuje přepínač pro částečný rollback oblasti.

Fixture není H2 lifecycle integrace ani B4 durable recovery a nepředstírá, že je H1 state manifestem.
Je to pevná syntetická restore unit s hodnotami v paměti. Docker/runtime je mimo MVP; filesystem,
APFS, durable journal, crash/reboot recovery a whole-UID quiescence se zde neprovádějí.

## Ověření a úklid

```sh
swift test --package-path proto/cli -c debug
swift test --package-path proto/cli -c release
```

Testy zahrnují skutečnou binárku sanjbox, všechny příkazy přes NSXPC, doslovné argv včetně
prázdných/Unicode/metaznakových argumentů, H1 limity a malformed wire, nekorelované i neplatné
odpovědi, živé přerušení, zaniklý listener, tichý peer, pozdní callback a úplnou mock restore unit.
CI balík objeví přes verzovaný `Package.swift`; lokální dependency na `../contracts` zároveň
zařadí H3 při změně H1. [VALIDATION](VALIDATION.md) obsahuje výsledky konkrétního běhu.

Provoz nečte soubory ani nedělá trvalé změny; spojení/listener se explicitně invalidují. Testy
spouštějí pouze vlastní sestavenou CLI binárku a čekají na její exit s watchdogem. Nejsou potřeba
apply/cleanup skripty, credential sonda, root, TCC, uživatelé, mounty, APFS ani síťové endpointy.
SwiftPM zanechá obvyklé build artefakty v zvoleném scratch path.

Produkční host-only autorizace (audit token, podpis, session), oddělený helper, reálné UID a
procesy, stdio/PTY i všechny brány/R1–R8 zůstávají **Neověřeno**. Převzetí do WP2.7 čeká na vstup
F2 a nativní ověření; tento prototyp neřeší otevřené blokátory PLAN.
