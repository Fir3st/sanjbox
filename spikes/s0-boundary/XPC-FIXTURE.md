# WP1.A4 — vlastní procesová XPC fixture

`xpc-probe` již nepoužívá request equality jako mock identity. `xpc-fixture-service` je skutečný
embedded XPC service spuštěný systémem pro jedinou vlastní dočasnou aplikaci. Žádný daemon,
LaunchAgent, `launchctl bootstrap`, LaunchServices registrace, login item, systémová konfigurace
ani privilegovaný helper se neinstaluje. Jediné service jméno je pevné
`org.sanjbox.a4.fixture-service` uvnitř vlastního bundle. Příkaz nepřijímá cizí service/path/PID.
**WP1.A4 je partial; S0/S8, ID-07/11 a R2/R3 zůstávají Neověřeno.**

## Identita, autorizace a přesná mez

1. Klient nejprve ověří úplnou explicitní self identity expectation a vlastní runtime profil jako
   ostatní A4 sondy. XPC navíc požaduje kanonický UUID `runID` a přesné 20bajtové cdhash hodnoty
   klienta i služby. Ověří vlastní app seal včetně nested code a známý embedded service seal.
2. Služba ověří vlastní signature/resource seal a vlastní úplnou identitu proti expectation uložené
   v podepsaném Info.plist. `JoinExistingSession: true` záměrně připojí tuto lokální fixture do
   předregistrované session klienta. Výchozí nová audit session byla při vývoji skutečně odmítnuta.
3. Služba načte jediný předregistrovaný `Control/client-codehash` ve vlastním novém 0700 adresáři
   vedle aplikace: `openat`, no-follow, regular file, vlastník effectiveUID, mode 0400, jediný link,
   přesně 40 hex bajtů. Runner soubor vytvoří **po posledním podpisu celé aplikace, před spuštěním**.
   Tím nevzniká cyklus, kdy změna policy ve službě mění resource seal klienta a následně jeho cdhash.
   Toto je trust root syntetického runneru, ne nedůvěryhodná zpráva od klienta.
4. Server čte EUID, EGID a ASID přímo z `NSXPCConnection`, vyžaduje přesnou shodu a nastaví
   `setCodeSigningRequirement` na přesný preregistrovaný cdhash **před activate**. OS tuto podmínku
   kontroluje pro každou zprávu. Stejnou podmínku pro službu nastaví klient. `connectionCredentialsAccepted`
   ještě netvrdí úspěšný podpis; `messageAuthenticated` vznikne až v OS-dispatchované metodě a po
   opětovném ověření connection identity. Podpis se nikdy nezjišťuje podle holého PID.
5. Jediná chráněná operace je přesná 48bajtová ASCII zpráva `read-canary:<RUN-UUID>`; vrací vlastní
   syntetický kanárek. Cizí run ID, jiná operace, přidané UID/session claims i nadlimitní požadavek
   se odmítnou. `hello` je neoperativní denial control; pevná `wait:<RUN-UUID>` jen záměrně nevydá
   odpověď pro timeout/cancellation test. Nečte cestu a nespouští příkaz.

**Veřejné NSXPC API neposkytuje plný peer audit token ani peer auditUID.** Vlastní auditUID obou
procesů je ověřeno v jejich self gate, ale není vydáváno za credential získané ze spojení. Kód
nepoužívá private selector/KVC ani soukromou XPC funkci a nedoplňuje chybějící údaj z wire claims.
Plná audit-token autentizace je nepodporovaná; tato fixture měří pouze explicitně uvedenou podmnožinu
EUID/EGID/ASID + přesný OS cdhash. Není náhradou SG-08 ani produkčního brokeru.

Vlastní fixed hash file/journal nejsou odolné vůči škodlivému procesu stejného UID, který může změnit
jejich mode/obsah; 0700 není hranice vůči témuž UID. Runner předpokládá výhradní vlastnictví svých
nových fixtures a při změně odmítne úklid. Žádná produkční policy storage nebo audit authority se
z této konstrukce neodvozuje. Ad-hoc cdhash se při rebuildu mění; nejde o stabilní TCC identitu.

## Nezávislý záznam a životní cyklus

Server otevírá `Control/server.jsonl` přes O_EXCL/no-follow. Nejvýše 64 záznamů, každý do 2048 bajtů;
short write/EINTR se dokončí, jiná chyba ukončí službu před operací. Záznamy rozlišují spuštěnou
službu, pozorované spojení, credential rejection, podpisem autorizovanou zprávu, odmítnutou operaci
a dvě skutečné canary operace. Nezapisují žádný payload nebo canary obsah. Klient nemůže journal
přepisovat přes XPC; runner jej čte přímo, nezávisle na návratových hodnotách klienta.

Globální Mach lookup se vůbec neprovádí. Samotné vytvoření `NSXPCConnection` není dosažitelnost;
`serviceStart` dokládá aktivaci vlastního bundle, `connectionObserved` spojení a `operation` skutečnou
schopnost. Absence odpovědi není důkaz odmítnutí; negativní případ potřebuje journal a exit oracle.

Každá odpověď má absolutní monotonic deadline 2 s, kontrolovaný i při callbacku a po probuzení
čekajícího klienta. Ani již frontovaná pozdní odpověď nesmí pokračovat další operací. Chyba/timeout
invaliduje spojení; pevný watchdog ukončí službu nejpozději 8 s po její inicializaci. Autorizované
`finish` ukončí službu po odpovědi. Launchd může po zániku klienta ukončit službu dříve, bez posledního
journal záznamu. Cleanup proto vyžaduje skutečný kernel `NOTE_EXIT`, nikoli pouze text `serviceExit`.

Runner vytváří a reaps pouze své `Popen` klienty; cancellation signalizuje pouze tento dosud vlastněný
child. Službu spravuje/reaps launchd, runner ji nikdy nesignalizuje. PID ze serverového záznamu a
klientského OS connection metadata slouží pouze k read-only exit observation, nikdy k podpisové
validaci nebo autoritě pro kill. Služba po `serviceStart` nejvýše 2 s čeká na pevný marker stejného run ID. Runner nejprve registruje watch a teprve pak atomicky publikuje dokončený 0400 marker přes vlastní dočasný hardlink (1–2 linky během publikace), bez přepsání existujícího jména. Teprve poté služba aktivuje listener. Watch se tedy registruje za běhu; selhání registrace/exit oracle je chyba
měření a ponechá fixture. Toto není mechanismus vypnutí celého UID, crash recovery ani process tree
supervisor. OS metadata a regular-file zápisy nemají obecný hard wall-clock timeout.

## Opakovatelný běh [implementátor]

```bash
python3 spikes/s0-boundary/validate-xpc.py
python3 spikes/s0-boundary/validate-xpc.py --apply --expect-json '<předem zkontrolované úplné A4 self expectation bez xpc>'
```

Výchozí režim je dry-run. `--apply` vytvoří nový jedinečný `/private/tmp/sanjbox-a4-xpc-validation-*`,
spustí úplné native Release XCTest bez externích balíčků a sestaví vlastní dvě binárky. Zapečetí
službu a pak celou fixture app ad-hoc runtime s prázdnými entitlements, strict-verify, zaznamená
cdhash/run policy před aktivací. Nedělá capture-and-auto-approve identity wrapper. JSON identity
musí dodat implementátor podle běžného README; skutečné neshody aktivaci zablokují.

Šest živých případů: dvě pozitivní operace kolem čtyř denials; OS-rejected cdhash; chybný přesný peer
ASID policy; cizí run ID; záměrně chybějící odpověď/deadline; zánik vlastního klienta během pending reply.
Posledních pět očekává **nulu operací**, nikoli jen chybový kód. Wrong-signature i wrong-session
navíc vyžadují nulu `messageAuthenticated`. Všechny vyžadují reaped klienta a nezávisle pozorovaný exit
služby. Timeout/cancellation nejsou výsledkem „izolace prošla“.

Po kontrole runner odstraní jen nezměněné objekty své přesně inventarizované fixture, ověřené podle
device/inode/mode/UID/GID/obsahu. Cizí položka/symlink/změna je konflikt. Zachová build/test/raw výstupy
v jedinečném scratch pro review. Tyto vlastní build/cache lze odstranit až po zaznamenání validace;
script nedává obecné mazání podle dodané cesty. Neúplné běhy se nemažou nebo neoznačují pass.

API opora: [NSXPCConnection](https://developer.apple.com/documentation/foundation/nsxpcconnection),
[embedded XPC services](https://developer.apple.com/documentation/xpc/creating-xpc-services),
SDK `Foundation/NSXPCConnection.h` a lokální `man xpcservice.plist` (`JoinExistingSession`).
Podrobné výsledky a zachované neúspěšné pokusy jsou v [VALIDATION.md](VALIDATION.md).
