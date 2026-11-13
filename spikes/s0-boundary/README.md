# S0 boundary preparation — WP1.A4

Samostatná příprava proti `main`, závislá pouze na místním `../common`. **S0 ani žádný akceptační
případ tím neprošel.** Aktivní CLI pracuje výhradně v rozsahu `synthetic-self-fixture`; tento rozsah
není schválená oblast ani běh L2. Neobsahuje nástroj k libovolnému spuštění příkazu, připojení ke službě,
čtení cesty nebo signalizaci PID. `tcc-probe` a `capture-probe` mají jen identitní bránu a výslovné
`notImplemented`, nikoli falešný pozitivní výsledek. Praktické [postupy všech 31 případů](LAB-PLAN.md)
vymezují ruční kroky, kontroly, oracles a přesné blokátory; dokončení přípravy scénářů neznamená,
že všech 31 případů lze dnes spustit. Skutečné cross-session/TCC měření čeká na uživatelský L2.

## Co je skutečně implementované

| CLI | Skutečná operace a oracle | Mock / co tím není doložené |
|---|---|---|
| `host-read-probe` | Dva vlastní syntetické soubory v novém UUID adresáři. Čitelný kanárek před a po pokusu; nový `openat` souboru mode `000` musí vrátit `EACCES`/`EPERM`. Ověřený úklid. | Stejné UID; vlastník může změnit mode. Žádná ochrana hosta/jiné oblasti, zápisových kořenů nebo mountů. |
| `xpc-probe` | Vlastní podepsaný embedded XPC service v jiném procesu. OS kontroluje přesný cdhash každé zprávy, server porovnává connection EUID/EGID/ASID; dvě canary operace obklopují čtyři odmítnutí. Nezávislý serverový journal a NOTE_EXIT oracle. | Veřejné NSXPC neposkytuje peer auditUID/plný audit token. Jde o stejný UID/session a vlastní fixture, nikoli cross-session hranici, globální inventuru nebo broker. [Podrobnosti a živý runner](XPC-FIXTURE.md). |
| `ingress-probe` | Vlastní `127.0.0.1:0` TCP listener a klient, ověření adres/portu protistrany před čtením, přesný kanárek na serveru a ACK u klienta. Celé I/O má deadline 2 s. | Pouze pozitivní kontrola vlastní komunikace. Žádná negativní síťová hranice, `0.0.0.0`, LAN, IPv6 či port squatting. |
| `lifecycle-probe` | Jediný vlastní `/bin/cat -u`, syntetický vstup, přesný výstup, EOF, úspěšný exit a vlastní `waitpid`. I/O deadline 2 s. | Není odpojený CLI, pauza/vypnutí celého UID, zákaz restartu, forkování nebo launchd job. |
| `signing-probe` | `SecCodeCopySelf`, validace vlastní běžící signatury bez sítě, flags a přítomnost zakázaného entitlementu. | Jen profil vlastní binárky. Žádná podpisová identita/Keychain, certifikát/Team/trust, TCC persistence, attach, SMAppService ani náhrada WP1.A6. |
| `tcc-probe` | Po ověření identity vrací `notImplemented`, kód 5. | Žádné TCC API, prompt, grant, databáze nebo hardware. |
| `capture-probe` | Po ověření identity vrací `notImplemented`, kód 5. | Žádný window list, obrazovka, clipboard, event post ani AX. |

Každý JSON výstup má `acceptanceEvidence: false`, přesný `scope`, `status`, a po úspěšném sběru
také skutečný `context`. Výstup je na stdout; CLI nevytváří/nepřepisuje protokol důkazů. Použití
výsledku jako laboratorní evidence by bylo nesprávné i při `fixturePassed`.

## Sestavení a ověření [implementátor]

macOS, Swift 6; bez externích závislostí, instalací a rootu. Cílová laboratoř podle GUIDE je macOS 27.x.
Balík deklaruje minimální API platformu macOS 15, tím ale neslibuje ověřenou podporu tohoto systému.
Přesné příkazy, testy a limity jsou ve [VALIDATION.md](VALIDATION.md).

```bash
a4_build=$(mktemp -d /private/tmp/sanjbox-a4-build.XXXXXXXX)
export CLANG_MODULE_CACHE_PATH="$a4_build/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$a4_build/modules"
swift test --build-system native --configuration release \
  --package-path spikes/s0-boundary --scratch-path "$a4_build/scratch" \
  --cache-path "$a4_build/cache" --disable-sandbox
swift build --build-system native --configuration release \
  --package-path spikes/s0-boundary --scratch-path "$a4_build/scratch" \
  --cache-path "$a4_build/cache" --disable-sandbox --show-bin-path
```

Poslední příkaz vypíše adresář binárek. Bez argumentů nebo s `--dry-run` každá z nich pouze vypíše
přesný rozsah a změny; nečte identitu, nevytvoří fixture ani nespustí child. Debug testovací knihovna
je vhodná pro unit testy, debug CLI není platná aktivní sonda. SwiftPM může přidat `get-task-allow`;
ani Release sám není důkaz hardened runtime. Před aktivním CLI je potřeba vlastní finální binárku
po **posledním** buildu ad-hoc zapečetit s runtime a prázdnými entitlements (VALIDATION). Každý další
build vyžaduje novou kontrolu. Žádná identita z Keychain se nezískává.

## Identita a explicitní aktivace

Jediná aktivní syntaxe je:

```text
host-read-probe --apply --expect-json '<úplné předregistrované JSON očekávání>'
```

Ostatní binárky mají stejnou syntax. XPC navíc vyžaduje vlastní dočasný bundle a pole `xpc` s přesným `runID`, `clientCodeHash`, `serviceCodeHash`; tyto hodnoty připravuje [omezený fixture runner](XPC-FIXTURE.md) před aktivací. Žádné souborové `--expect`, `--path`, `--pid`, `--service`,
`--command`, volný host/port ani identitní bypass neexistují. Očekávání je inline, nejvýše 16 KiB,
s přesnými známými klíči, bez duplicitních (včetně escapovaných) JSON klíčů. Čísla jsou nezáporné
desítkové celé hodnoty, skupiny bez duplicit a konfliktů. Nulové/root UID, nekladný auditSessionID,
neznámý auditUID a implicitní scope se odmítnou před sběrem identity. Chyba očekávání a neshoda jsou
`invalidMeasurement`, **nikdy odmítnutí testované zakázané operace**.

Ilustrační očekávání níže záměrně neodpovídá osobní host relaci. Hodnoty musí být předem nezávisle
určené pro konkrétní self-fixture kontext. CLI nikdy automaticky nezmění aktuální host relaci na
očekávanou/schválenou oblast. Na tomto balíku nelze aktivovat budoucí host nebo L2 operaci.

```json
{
  "schemaVersion": 1,
  "scope": "synthetic-self-fixture",
  "realUID": 450,
  "effectiveUID": 450,
  "realGID": 701,
  "effectiveGID": 701,
  "kernelGroups": [701],
  "forbiddenGroups": [20, 80],
  "auditSessionID": 12345,
  "auditUID": 450,
  "launchdManagerName": "Aqua",
  "launchdManagerUID": 450,
  "window": {
    "userID": 450,
    "auditSessionID": 12345,
    "onConsole": false,
    "loginDone": true
  }
}
```

### Jak získat vlastní metadata bez automatického schválení

**[implementátor]** Z důvěryhodného `main` sestavit common metadata sondu ve zvláštním scratch adresáři:

```bash
a4_whoami_build=$(mktemp -d /private/tmp/sanjbox-a4-whoami.XXXXXXXX)
CLANG_MODULE_CACHE_PATH="$a4_whoami_build/clang" \
SWIFTPM_MODULECACHE_OVERRIDE="$a4_whoami_build/modules" \
swift build --build-system native --configuration release --product sanjbox-whoami \
  --package-path spikes/common --scratch-path "$a4_whoami_build/scratch" \
  --cache-path "$a4_whoami_build/cache" --disable-sandbox
```

Najít binárku pomocí stejného `swift build ... --show-bin-path`, ověřit její původ a finální signing
profil podle GUIDE, pak spustit `sanjbox-whoami` **bez `--expect`** v zamýšleném vlastním fixture kontextu.
Výstup je pouze metadata vlastního procesu/session s `valid: null`. Common collector nemá bounded
launchctl čekání; tento ruční metadata krok není aktivní A4 sonda ani laboratorní důkaz. Při chybě,
chybějícím údaji nebo zaseknutí se hodnoty neodhadují. Výstup může obsahovat vlastní userName, proto
jej neposílat automaticky do veřejného repozitáře; A4 při vlastním sběru jména nezapisuje.

**[implementátor / reviewer]** Výstup vědomě zkontrolovat, zapsat nové inline očekávání před během a
ponechat rozsah `synthetic-self-fixture`. Žádné propojení „capture → automaticky approve → apply“ není
součástí nástroje. Naměřené metadata nedokazují, že relace je bezpečná oblast.

| Zdroj z common `context` | Povinné pole A4 |
|---|---|
| `realUID`, `effectiveUID`, `realGID`, `effectiveGID` | Stejná přesná pole |
| úplné `kernelGroups` | `kernelGroups`, žádné vypuštění skupin |
| `audit.sessionID`, `audit.auditUID` | `auditSessionID`, `auditUID` |
| `launchdManager.name`, `.uid` | `launchdManagerName`, `launchdManagerUID` |
| `windowSession.userID`, `.auditSessionID`, `.onConsole`, `.loginDone` | `window` se všemi čtyřmi hodnotami; pokud session není, explicitní `null` |
| předem stanovená politika nepřípustných groups | `forbiddenGroups`; pro pouhý self-fixture test lze výslovně uvést `[]`, což netvrdí zákaz staff/admin |

`schemaVersion: 1` a přesný scope se doplní ručně. Nepřenášet `pid`, `parentPID`, jména ani audit flags
do očekávání; nepatří do jeho schématu. Budoucí L2 musí být nezávisle autorizované a současné CLI pro
něj nemá aktivní backend. Jakákoli neshoda při následném vlastním sběru A4 běh zastaví před fixtures.

Kontroluje se real/effective UID/GID, **přesná množina kernel groups** (včetně zákazu duplicit), členství
každé z nich přes membership API a nepřítomnost každé explicitní forbidden group. Membership API
není enumerátor všech možných directory groups: netvrdíme úplnost nevyjmenovaných dynamických
členství. AuditSessionID je povinná pozitivní přesná hodnota a auditUID se kontroluje zvlášť.
Manager musí přesně odpovídat `Aqua` nebo `Background` a očekávanému UID. `window` musí obsahovat
všechny čtyři položky, nebo explicitní `null`, které vyžaduje skutečnou absenci window session.
Chybějící/nerozhodnutelný údaj je neplatné měření.

Collector sdílí common `ProbeContext`/`ProbeExpectation`, doplňuje chybějící přesnou audit/session
kontrolu a nevolá neomezený common collector. Pro manager spouští jen pevné `/bin/launchctl managername`
a `manageruid`. Jde o metadata vlastní relace, nikoli `bootstrap`, výčet služeb nebo konfiguraci launchd.
`CGSessionCopyCurrentDictionary` čte vlastní session metadata, nikoli obsah/okna hosta. Membership,
audit, CoreGraphics a Security API jsou synchronní OS volání bez obecného hard timeoutu; deadliny
child/socket/XPC nejsou zárukou celkového wall-clock limitu při zablokovaném systému.

Po identitě se před file/XPC/TCP/child interakcí ověří profil vlastní signatury: validní kód, runtime,
žádný klíč `get-task-allow` ani `com.apple.security.get-task-allow` (i hodnota `false` je odmítnuta).
Raw entitlements bez dostupného validního decoded dictionary znamenají neplatné měření. Signing
sonda sama pouze tento profil pozoruje; při nesplnění vrátí `fixtureFailed`. TCC/capture nic neprovádějí.

## Úklid a meze bezpečnosti

`host-read-probe` generuje `/private/tmp/sanjbox-a4-fixture-<UUID>`, mode 0700; soubory pouze `control`
a `denied`, nejvýše 1024 bajtů. Nikdy nemění existující kořen hosta. Původní stav je neexistence nových
objektů; nový vlastní adresář dostane effectiveGID procesu (Darwin jinak může zdědit group rodiče).
In-memory receipts drží fd/inode/device/GID/flags/mode a přesná syntetická data. Žádný cizí
manifest nebo cesta nejsou autoritou pro smazání. `openat` používá no-follow, nonblocking a close-on-exec;
ověřují se typ, vlastník, single link a identita, extended ACL se nepřijímají. FIFO, symlink, hardlink,
neznámá položka, změněný mode/GID/flags/ACL/obsah i přesun mimo adresář jsou konflikt. Při chybě
se před jakýmkoli unlink zkontrolují všechny položky. Chybějící název je idempotentní případ jen pokud
retained fd potvrzuje `st_nlink == 0`. Na přejmenované místo se nesahá.

Úklid není atomická izolace proti škodlivému procesu stejného UID: mezi kontrolou a unlink existuje
race. Balík nedokazuje TOCTOU odolnost privilegovaného helperu, nemá crash recovery ani persistentní
cleanup registr. Při násilném přerušení může vlastní UUID fixture zůstat. Konflikt se hlásí kódem 4 a
zachová se k ručnímu ověření; žádný `rm -rf`, hledání/mazání podle prefixu ani oprava pozdější změny se
nenabízí. Běžná cesta cleanup je opakovatelná a testovaná. Regresní testy mění mode/flags/ACL/GID pouze
uvnitř svých nových fixtures a před konečným cleanup změny vrátí.

Vlastní child používá `posix_spawn` jen pro tři pevné varianty (dva manager dotazy a cat), prostředí
`PATH`/`LC_ALL`, vlastní pipes a výhradní `waitpid`. Před spawn vyžaduje původní `SIGCHLD=SIG_DFL`
a nepřítomnost `SA_NOCLDWAIT`; inherited ignore/custom handler odmítne bez změny globálního stavu.
Po timeoutu TERM, 200 ms grace, pak KILL a 200 ms
čekání na reap. Signalizuje jen svůj ještě nereapnutý child; nepracuje s dodaným PID ani neenumeruje
procesy hosta. Pokud reap selže, hlásí konflikt, nikoli úspěšný cleanup. Není to lifecycle mechanismus
pro celé UID. XPC a TCP objekty jsou dočasné a vždy invalidované/uzavřené.

| Kód | Význam |
|---|---|
| 0 | `dryRun` nebo úspěch konkrétní self fixture; ne brána |
| 1 | Vlastní fixture/profil nesplnil očekávaný výsledek |
| 2 | Chybná syntax CLI |
| 3 | Neplatné měření: očekávání, identita, signature prerequisite, chybějící kontrola, I/O nebo timeout |
| 4 | Změněná fixture / neověřitelný úklid, zachovat k ručnímu review |
| 5 | Vyžadovaná sonda ještě není implementovaná |

## Přesné mapování na COVERAGE

Všechny řádky akceptačních testů zůstávají **Neověřeno**. Mapa popisuje přípravu, nikoli pokrytí
akceptace. Žádný z 155 případů se syntetickými unit testy neuzavírá.

| Případy | Příprava zde | Chybějící důkaz |
|---|---|---|
| FS-01, FS-02, FS-03, FS-05 | Fresh-open canary oracle a bezpečná vlastní file fixture | Skutečné oddělené UID, chráněné kořeny, sdílené cesty; u FS-03 i zákaz zápisu |
| FS-06 | Nic aktivního | Host nástroje a startup kořeny: syntetické write fixtures za skutečnou hranicí |
| FS-07 | Odmítnutí hardlinku do vlastní file sondy | Zákaz vytvoření/zneužití hardlinku z oblasti |
| FS-09 | Nic aktivního | Povolené syntetické metadata a jednotlivé service oracles pro ps/mdfind/log/netstat/system_profiler/ioreg/dscl |
| FS-04, FS-08, FS-10…12 | Pouze vlastní symlink/FIFO/TOCTOU hygiene; žádná akceptace S4/S8 | Mounty, helper, průběžná ochrana, export a host ACL jsou mimo tuto implementaci |
| ID-01, ID-02 | Nic aktivního; ani Keychain mock se nevydává za implementovaný | Mock úložiště + uživatelský důkaz oddělení; syntetická schránka v L2 |
| ID-03, ID-04, ID-08 | `capture`/`tcc` explicitně unavailable | Syntetická okna/vstupy ve třech session, pozitivní kontrola a nezávislý příjemce |
| ID-05 | Jen profil vlastní signatury | Attach na vlastní kontrolované testovací targety; vazba na S8 |
| ID-06 | Nic aktivního | Otevření prázdné fixture aplikace jen v očekávané relaci |
| ID-07 | Reálný embedded XPC transport, OS cdhash a connection EUID/EGID/ASID autorizace vlastních fixtures | Inventura globálních Mach/XPC služeb a oprávněnost konkrétních operací |
| ID-09, ID-10 | `tcc` explicitně unavailable | Hardware politika/testy, AppleEvents a notifikace s kontrolovaným příjemcem |
| ID-11 | Vlastní TCP/XPC transport jsou jen infrastruktura | Kontrolovaný host agent/socket a skutečné cross-UID odmítnutí |
| LC-01, LC-02, LC-03, LC-04 | Nic aktivního | LaunchAgent, cron/at, login item/SMAppService a user domain v L2 |
| LC-05 | Own-child echo, EOF, exit/reap oracle | Odpojený proces, celý UID a nula procesů po vypnutí |
| LC-06, LC-07, LC-08, LC-09, LC-10 | Nic aktivního | Start/fork race, helper crash, nové login cesty, privilegovaná autorizace |
| LC-11 | Nic aktivního; případ F2 | Zákaz opětovného přidělení UID před úklidem |
| NET-10…12 | Pouze pozitivní vlastní IPv4 loopback | S3b wildcard ingress, other-area/host/LAN, port squatting |
| SG-01, SG-02 | Runtime/no-get-task-allow profil **vlastní** sondy | Profil všech komponent a celý rozsah S8; stabilní identita/TCC není měřena |

XPC nyní zachová pozorovanou zakázanou odpověď jako `fixtureFailed`/kód 1 i při sekundární chybě úklidu. Runner ukládá bounded stdout/stderr, dostupný server journal a stav chyby/úklidu také při neplatném měření; podrobnosti v [XPC-FIXTURE.md](XPC-FIXTURE.md).

Praktický [LAB-PLAN](LAB-PLAN.md) má přesný index 31 případů a společné ověření kontextu/podpisu.
Každý [FS případ](CASES-FS.md), [ID případ](CASES-ID.md) a [LC případ](CASES-LC.md) má vlastní
prerekvizity, nástroj/API, pozitivní kontroly před/po, zakázanou operaci, nezávislý oracle,
klasifikaci chyby a úklid. Ruční krok nikdy nepřidává argumenty současným CLI. Chybějící receiver,
collector, helper nebo lifecycle controller je skutečný stop; FS-04/FS-08/LC-11 zachovávají
vazbu na S4/S8/F2. Nejde o systémový runner, rezervaci L2 ani náhradu chybějícího mechanismu.
