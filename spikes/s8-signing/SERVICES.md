# WP1.A6 — disposable SMAppService fixtures

**Příprava, ne výsledek S8/L2.** `S8ServiceFixture.app` se sestaví jako skutečný bundle se čtyřmi
nativními Release targets, bez externích balíčků. Implementátor pouze sestavuje, ad-hoc podepisuje
vlastní artefakty a kontroluje strukturu. Neregistruje služby, nespouští helpers/UI ani nemění systém.
Personal Team a podmíněná self-signed varianta zůstávají uživatelské experimenty po S1 v L2.
A6/SG-01…11 zůstávají částečné/Neověřeno; attach oracle, skutečný Broker a Contracts dále chybějí.

| Target | Umístění v app | Identifikátor / chování |
|---|---|---|
| S8ServiceHost | `Contents/MacOS/S8ServiceHost` | `org.sanjbox.s8.fixture.host`; výchozí `plan`, typované status/UI |
| S8LoginItem | `Contents/Library/LoginItems/S8LoginItem.app` | `org.sanjbox.s8.fixture.loginItem`; jeden startup marker a exit 0 |
| S8LaunchAgent | `Contents/MacOS/S8LaunchAgent` | `org.sanjbox.s8.fixture.agent`; vlastní plist v `Contents/Library/LaunchAgents` |
| S8LaunchDaemon | `Contents/MacOS/S8LaunchDaemon` | `org.sanjbox.s8.fixture.daemon`; vlastní plist v `Contents/Library/LaunchDaemons`; jen observation, žádný zápis souborů |

Agent/daemon mají přesně `Label`, `BundleProgram`, `RunAtLoad`, `ProcessType=Background`.
Žádné MachServices, KeepAlive, sockets, ProgramArguments, env overrides, shell dispatch, vstupní
argumenty, IPC ani libovolné cesty. Helper není root broker a nemá žádnou privilegovanou operaci.

## Build a statická kontrola [implementátor]

Z kořene repo, Apple Silicon, Swift 6/macOS 15+ (akceptační cíl GUIDE zůstává macOS 27.x):

```sh
python3 spikes/s8-signing/tools/service-fixtures.py prepare
python3 spikes/s8-signing/tools/service-fixtures.py prepare --apply
```

První příkaz je dry-run. Druhý vytvoří nový `/private/tmp/sanjbox-s8-services-<UUID>` (`0700`),
vypíše jeho přesnou cestu `OWN_ROOT`, izoluje module/cache/build cesty, sestaví native Release,
zabalí app a podepíše všechny čtyři targets od nejvnitřnějšího `codesign --sign - --options runtime
--timestamp=none` s prázdnými entitlements. Nikdy nehledá signing identity, nečte certifikáty ani
Keychain. Ad-hoc je pouze syntetický profil, ne Personal Team ani self-signed důkaz. SwiftPM native
backend má deprecation warning. Binárky v build cache nejsou schválené sondy; použitelné statické
artefakty jsou čtyři explicitně znovu podepsané targets uvnitř app.

Příprava ověří thin arm64 Mach-O, plist shape, shodné sealed run ID, strict/all-architectures
codesign, runtime/ad-hoc flags a prázdné entitlements. Vypíše SHA-256 všech čtyř executable bytes.
Manifest inventarizuje vlastní soubory, adresáře, link metadata a hashe, včetně build cache. Žádná
binárka při tom neběží. Zdroj balíčku je důvěryhodný vstup vývojového buildu, nikoli imported area kód.

```text
python3 spikes/s8-signing/tools/service-fixtures.py verify --root OWN_ROOT
python3 spikes/s8-signing/tools/service-fixtures.py cleanup --root OWN_ROOT
python3 spikes/s8-signing/tools/service-fixtures.py cleanup --root OWN_ROOT --apply
```

Cleanup je pouze pro původní **neinstalovaný ad-hoc artefakt**, jehož UI odmítá mutace. Nevolá
unregister ani neověřuje systémové registrace. Dry-run ověří celý manifest před prvním unlink;
aplikace odstraní jen přesnou ověřenou inventuru pomocí directory fd a prázdný root. Opakování na
neexistujícím validním rootu je no-op. Změněný obsah, módy, flags, ACL, UID/GID/inode, přidané položky
či hardlinky jsou konflikt. Symlinky v cache se pouze unlinkují, nikdy nenásledují. Po přerušení
částečného úklidu se stav **nepřebírá jako nový baseline**; zbytek vyžaduje ruční kontrolu vlastní
původní inventury. Nejde o crash-atomic nebo hostile same-UID TOCTOU mechanismus. Nepoužívat globální
reset ani `rm -rf` s převzatou cestou. Selhání přípravy zachová vlastní root a pokusí se ho inventarizovat;
chybějící/poškozený manifest znamená ruční kontrolu přesných vlastních položek.

## UI a evidence [uživatel, budoucí L2]

`S8ServiceHost` bez argumentů nebo s `plan` pouze vypíše dry-run bez SMAppService API.
CLI nepřijímá registraci, unregister, apply, label, executable ani cestu služby.

```text
OWN_APP/Contents/MacOS/S8ServiceHost status --expect OWN_EXPECTATION
OWN_APP/Contents/MacOS/S8ServiceHost ui --expect OWN_EXPECTATION
```

`OWN_EXPECTATION` je přesný vlastní expectation JSON z [README](README.md#identita-před-každou-sondou-implementátor--uživatel-v-l2),
zafixovaný před během; žádná automatická akceptace pozorované identity. Status/UI před použitím
API ověří real/effective UID/GID, kernel a požadované skupiny, audit UID/session, launchd a window
session, hardened runtime a absenci všech entitlements. Scope signing class se zaznamenává zvlášť;
kontrola nevydává ad-hoc za Personal Team ani self-signed. UI je výchozí preview, status je zvláštní
read-only tlačítko. Žádné automatické otevření System Settings ani autorizační dialog OS.

Pro LoginItem/LaunchAgent vyžaduje mutace non-ad-hoc profil, nové ověření přesné identity po dialogu,
explicitní uživatelskou akci a nejvýše 32 eventů v UI session. Před API se uloží `intent` se stavem
před změnou; pak `result` se stavem, NSError domain/code a skutečnou identitou. Nedostatek evidence
kapacity nebo chyba zápisu před API znamená žádnou mutaci. Chyba po API ponechá intent a neúplný
běh; nesmí se pokládat za úspěšný cleanup. Dialog není trusted host authorization boundary.

**Ownership:** register vyžaduje stav `notRegistered`. Unregister je dostupný jen po doloženém
úspěšném register v téže živé UI session, na stejném service enum a při stejném pozorovaném stavu.
Nejasný API výsledek, neúplný result, restart UI nebo změna statusu znamená odmítnutí a ruční L2
review. Staré receipts nejsou oprávněním měnit nynější službu; SMAppService neposkytuje vlastní
registration generation. Stejný status po cizím unregister/re-register nelze zjistit: vyžaduje se
sériový LAB slot bez souběžných změn, není zde produkční ownership/TOCTOU garance.

**Daemon register/unregister není v mutujícím adaptéru vůbec implementován.** K dispozici je
pouze compiled target, plist, preview a status. Root operace z oblasti nesmí existovat; onConsole,
UI alert nebo znalost run ID nejsou host-only autorizace. Budoucí uživatelský L2 experiment musí
nejprve dodat oddělenou přezkoumanou host autorizační a cleanup cestu. Admin schválení je samostatná
uživatelská událost, nikoli závěr ze statusu nebo z úspěchu LoginItem/LaunchAgent.

## Startup markers a úklid evidence

Helper nejprve zachytí skutečný common `ProbeContext`; ověří svůj runtime/entitlements a seal
vlastního enclosing bundle před čtením `S8FixtureRunID`. Run ID je kanonické UUID vytvořené builderem
před podpisem a shodné ve všech targets. Zaznamená jedinečné event ID, čas, `kern.boottime`, společnou
identitu, podpisový code hash a `launchCause=unknown`. Změna boot time pomůže rozlišit restart,
změna audit session login; stejný boot/session další start. **Příčina není odvozena jako fakt.**
Všechny eventy mají `validMeasurement=false`; až nezávislá předregistrace a uživatelská časová osa
mohou vyhodnotit konkrétní lifecycle případ. Chybějící/nesprávná identita zneplatňuje měření.

Jeden marker má nejvýše 16 KiB. Helper má 12s nouzový process watchdog a exit 0 i při refusal,
aby chybový exit LoginItem nevyvolával restart storm. Chybějící marker není pass; při refusal je
jen pevná chyba. launchctl se používá pouze pro `managername/manageruid` s 2s limitem; žádný bootstrap.
Synchronous Security/membership/OS logging nemají dokázaný hard deadline; ani watchdog není důkaz
OS scheduling limitu. Helper nestartuje dlouhožijící proces. Crash/restart po nenulovém exitu se
netestuje touto defaultní fixture — potřebuje zvláštní preregistrovanou a ohraničenou konstrukci.

Všechny helpers emitují jednu strukturovanou startup observation na stdout a do unified logu
(`org.sanjbox.s8.fixture`, category `startup`). Jen vlastní syntetické L2 účty; raw identita patří
privátnímu protokolu a před publikací se aliasuje. Daemon nemá žádný filesystem output, jeho log
sbírá uživatel zvlášť podle předregistrace; log persistence/loss není zde ověřená.

User-level helper a UI eventy navíc vytvoří nový `/private/tmp/sanjbox-s8-event-<UUID>` (`0700`).
Pevné `event.json` a `manifest.json` (`0600`) vznikají `O_EXCL|O_NOFOLLOW`, bez přepsání; FD kontroly
vlastníka, inode, ACL/flags a skutečné audit session předcházejí zápisu. Root cesta se vypíše hned,
aby i neúplný zápis šel lokalizovat. Manifest váže hash/inode eventu, vlastníka, root inode, run ID
(audit session není odvozena z názvu cesty). Nejde o ochranu proti plně kompromitovanému témuž UID.

```text
python3 spikes/s8-signing/tools/service-fixtures.py cleanup-event --root OWN_EVENT_ROOT --run-id RUN_UUID --session ORIGINAL_AUDIT_SESSION
python3 spikes/s8-signing/tools/service-fixtures.py cleanup-event --root OWN_EVENT_ROOT --run-id RUN_UUID --session ORIGINAL_AUDIT_SESSION --apply
```

Po exportu důkazu tyto příkazy ověří run/session/UID, typy, obsah, inode a přesně dva názvy před
unlink. Konflikt/partial write se uchová pro ruční review; opakování úplného cleanup je no-op.
Žádná enumerace cizích logů ani odstraňování podle globu.

## Uživatelský postup a dosud blokované kroky

1. Až po S1: rezervovat L2, potvrdit LAB/F0.8 a předregistrovat samostatné SG-04 varianty pro tři
   služby. Prázdné profily, žádné skutečné účty či data. Vyjasnit cleanup ještě **před** registrací.
2. Pro konkrétní user signing použít [nový copy/handoff postup](HANDOFF.md): dry-run i apply
   připraví **novou kopii** s vlastní provenance/inventurou a zachovají původní ad-hoc manifest.
   Identitu vybírá a používá jen uživatel; čtyři cíle se podepisují zevnitř ven a samostatně ověří.
   Po vydání podpisových příkazů je registration state unknown a automatický artifact cleanup
   odmítá. Podepsaná inventura není vlastnictví služby ani unregister. Kroky 3–6 níže jsou budoucí
   L2 postup a vyžadují přezkoumanou lifecycle cleanup cestu; nový handoff je neodblokovává.
   Daemon boot experiment potřebuje aplikaci dostupnou před loginem (Apple doporučuje
   `/Applications`); builder ani handoff ji nikam neinstalují.
3. Zafixovat očekávání pro konkrétní uživatelskou relaci. Spustit user-level UI, ověřit status a
   pouze v připraveném scénáři výslovně zvolit registraci. Uchovat intent/result a startup marker.
   Same-session register/unregister smoke je oddělený od následného login/reboot.
4. **Login/reboot i daemon cykly zůstávají blokované chybějící přezkoumanou cleanup/host cestou.**
   Nespouštět je jen proto, že target existuje. UI po restartu neadoptuje cizí/předchozí registraci.
   Po doplnění této cesty evidovat okamžitý start, další login, reboot a samostatný admin approval;
   pro každý nový audit context znovu ověřit očekávání. Žádný autoregister ani globální reset.
5. Unregister API samo nezaručuje zánik procesu. Oracle musí potvrdit nulu vlastních helpers a žádný
   restart po příslušném login/reboot; až potom app odstranit. Nevyřešený stav drží LAB slot blokovaný.
6. Self-signed matice je samostatná a podmíněná neúspěchem Personal Team; ad-hoc nikdy nenahrazuje ani
   jednu. Po zdokumentování výsledků zachovat minulou historii a raw důkazy, aktualizovat S8 až review.

Primární opory: [RESEARCH.md](RESEARCH.md). Přesné build/test výsledky a limity: [VALIDATION.md](VALIDATION.md).
