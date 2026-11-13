# ID — ruční příprava jedenácti případů

Karty dědí [společný předpis](LAB-PLAN.md#společný-předpis-pro-každou-kartu); žádné osobní aplikace,
clipboard, okna, účty, Keychain ani TCC se při této přípravě nepoužívají. **Žádný L2 krok nebyl
spuštěn.** Existující `tcc-probe` a `capture-probe` vracejí `notImplemented`/5; níže uvedené API
jsou cíle konkrétních ručních experimentů, nikoli tvrzení o jejich implementaci v těchto CLI.

## ID-01

- **Role / prerekvizity:** I připraví mock úložiště H/A/B s rozdílnými syntetickými hodnotami,
  O vlastní očekávání; skutečné identity z profilu H/A/B se nesmějí nahradit claims z požadavku.
  Reálné oddělení login keychainu dokládá samostatně U v čistých testovacích účtech v L2.
- **Nástroj / dostupnost:** požadovaný mock má jen `read` pro vlastní pevný identifikátor položky
  a odděleně danou identitu volajícího; **tento mock zatím není implementovaný**. A4 file fixture
  ani XPC `read-canary` se nevydávají za model Keychain autorizace.
- **Postup a kontroly:** u mocku H/A/B přečtou vlastní položku; A požádá o položky H/B a přidá
  podvržený owner claim. O ověří odmítnutí bez vydaných bajtů, pak vlastní čtení zopakuje.
  V integrační části U zaznamená vytvoření/oddělení prázdných login keychainů testovacích účtů,
  jejich vlastnictví a zamykací životní cyklus; nesbírá obsah položek, hesla nebo databázi.
- **Zakázáno / oracle:** cizí mock hodnota či převzetí identity je fail mocku; O porovná vlastní
  serverový seznam skutečně provedených operací. Uživatelský integrační záznam musí nezávisle
  doložit reálné oddělení, ne pouze rozdílné cesty či názvy Keychain.
- **Nejasné / blokátor:** mock a bezpečný integrační oracle nejsou dodané. Pokud U dodá jen UI
  stav/názvy, část je stále Nejasné; mock nikdy neuzavře skutečnou integraci. Žádné automatické
  `security` dotazy, čtení databází nebo zkouška na osobní položce se nepřidávají.
- **Výstup / úklid:** dvě oddělené části „mock“ a „uživatelský důkaz“, controls/denials a mezery.
  I zahodí jen vlastní mock data; testovací účty/úložiště uklízí U svým předem schváleným postupem.

## ID-02

- **Role / prerekvizity:** U potvrzuje prázdné laboratorní H/A/B/C schránky; odpojené clipboard
  mosty Screen Sharing/RFB, jejich nastavení evidovat. Každý shell má přesný vlastní Aqua/ASID
  profil; žádné `pbpaste` v osobní host relaci.
- **Nástroj / dostupnost:** existující `/usr/bin/pbcopy` a `/usr/bin/pbpaste` ručně v testovací relaci;
  používají běžnou schránku. Soukromá pojmenovaná `NSPasteboard` by běžnou schránku nenahradila.
- **Postup a kontroly:** H vloží a přečte H kanárek. A vloží/přečte jiný A kanárek; H znovu čte H.
  Pak H vloží druhý H marker a A přečte svou běžnou schránku: očekává stále A marker, žádný H bajt.
  Po pokusu H i A čtou své hodnoty; opakovat pro B/C a směry mezi oblastmi s novými markery.
- **Zakázáno / oracle:** H marker u A/B/C nebo změna H schránky zápisem oblasti je fail. O vede
  posloupnost vložení a nezávislé výsledky všech vlastníků; zaznamená i únik zjištěný při controlu.
- **Nejasné / blokátor:** samotná prázdná odpověď není denial; potřebná fungující vlastní schránka
  i cílový control. Nenulový clipboard most je samostatná konfigurace, nesmí potichu maskovat scope.
  A4 nemá clipboard adapter; ruční postup potřebuje L2 a výhradně čisté testovací relace.
- **Výstup / úklid:** role, pořadí, přesná délka/hash vlastního markeru a raw jen syntetických hodnot.
  U vyprázdní pouze tyto schránky, pokud stále obsahují vlastní testovací marker; pozdější změnu
  neobnovuje z uloženého osobního obsahu. Vrátí vlastní změny nastavení mostu.

## ID-03

- **Role / prerekvizity:** H/A/B/C zobrazí vlastní fixture okno s odlišným title markerem a měnící
  se pixelovou dlaždicí (run ID + counter). O má window ID, PID/start a podpis zdrojové aplikace,
  přesné role/ASID a referenční snímek pouze této fixture.
- **Nástroj / dostupnost:** ScreenCaptureKit `SCShareableContent`, `SCContentFilter` pro konkrétní
  okno a `SCStream`; zvlášť `CGWindowListCopyWindowInfo` s konkrétním známým window ID. **Adapter
  s omezeným výstupem a pixel oracle chybí**, `capture-probe` nic z toho nevolá.
- **Postup a kontroly:** H a A zachytí svou dlaždici a přečtou svůj title marker. A zkusí stejným
  SCK postupem pouze registrované H/B/C okno, zvlášť CGWindowList metadata těchto oken; nikdy
  celoplošný host capture. Po pokusu vlastní streamy prokážou nový counter a metadata controls.
- **Zakázáno / oracle:** chráněný title nebo pixel marker cizí session u A je fail. O porovná
  skutečné vzorky/counter a zdrojovou časovou osu; pouhá existence display/window ID se hodnotí
  podle předem určeného chráněného pole, nikoli automaticky jako únik obrazu.
- **Nejasné / blokátor:** černý obraz, žádná stream sample nebo chybějící permission control je
  Nejasné; nezpřístupněný cíl po fungujících controls dokládá jen testovanou API cestu. Chybějící
  capture adapter/TCC uživatelský grant blokuje běh. Žádný obecný window dump jako náhradní krok.
- **Výstup / úklid:** samostatné SCK-content a CG-metadata výsledky, čas/sample counter/error,
  přesné identity. Zastavit vlastní streamy, zavřít vlastní okna; bounded syntetické snímky uchovat
  pro review, nezachytávat ani mazat cizí obsah.

## ID-04

- **Role / prerekvizity:** vlastní podepsaná receiver app v H/A/B/C s prázdným textovým polem,
  tlačítkem a samostatnými čítači event/AX; O zaznamená její PID/start/ASID a původní čítače.
  Žádný běžný host editor nebo terminál jako event target.
- **Nástroj / dostupnost:** `CGEventPostToPid`; zvlášť `AXUIElementCreateSystemWide` pro focused-app
  scope a `AXUIElementCreateApplication` + `AXUIElementPerformAction` na vlastním receiveru.
  **Receiver, přesná instance binding a adaptéry nejsou v A4 implementované.**
- **Postup a kontroly:** povolený H sender doručí jediný syntetický key event / AXPress svému H
  receiveru, A totéž svému. A se pokusí o stejnou akci na H/B/C receiver a o AX čtení syntetického
  focused markeru přes system-wide element. Pak povolené události zopakovat s novým sequence ID.
- **Zakázáno / oracle:** jakákoli změna cílového čítače/textu nebo vydání cizího chráněného AX
  markeru je fail. O čte receiver journal a viditelný counter nezávisle; void návrat CGEvent není
  potvrzené odmítnutí. Žádné shell-like řetězce, klávesové zkratky nebo akce mimo fixture.
- **Nejasné / blokátor:** bez připraveného receiveru a uživatelských grantů v L2, při změně PID,
  ztrátě focusu nebo nefungujícím lokálním controlu se závěr nevydá. Chybějící AX scope nelze
  zaměnit za úspěch testu CGEvent; obě větve jsou povinné.
- **Výstup / úklid:** counter před/po, sequence/time, API error a target identity pro každou větev.
  Ukončit vlastní sendery/receivery, vrátit jen vlastní testovací granty postupem U, bez TCC resetu.

## ID-05

- **Role / prerekvizity:** dvě odlišné buňky: A→H proces a neautorizovaný A proces→podepsaný
  agent stejného UID A. Všechny cíle jsou vlastní inertní testovací procesy; O drží jejich
  vznik/PID/start/kontext. Agent má finální runtime podpis bez obou get-task-allow klíčů.
- **Nástroj / dostupnost:** dostupné OS `ptrace` attach a Mach `task_for_pid` jsou zamýšlené
  odlišné pokusy; **v A4 ani S8 není bezpečný attach runner/platný pozitivní control**.
  [S8 postup](../s8-signing/README.md#uživatelské-experimenty-a-skutečné-blokátory-uživatel-budoucí-l2)
  a `signing-probe` poskytují jen signing přípravu, nikoli attach důkaz.
- **Postup a kontroly:** nejdřív schválit konkrétní legitimně attachovatelnou vlastní control
  fixture a doložit skutečný attach/detach před/po. Na chráněných cílech zkusit pouze attach/získání
  task capability; nečíst obsah paměti, neměnit kód, neprovádět injection ani akci s převzatým TCC.
- **Zakázáno / oracle:** úspěšný attach či získání použitelného task portu je fail, i bez následného
  čtení. O zaznamená target stav a jeho nepřerušený heartbeat, runner syscall/Mach výsledek a
  nezávislé uvolnění portu/detach; pouhý failure utility nebo mrtvý target není ochrana.
- **Nejasné / blokátor:** žádná binárka s get-task-allow se zde kvůli controlu nevyrábí. Dokud S8
  nedodá přezkoumanou srovnatelnou pozitivní kontrolu a vlastnictví procesu/úklidu, běh je blokovaný.
  Cross-UID denial sám neprokazuje ochranu same-UID agenta ani nepřevzetí grantů.
- **Výstup / úklid:** dvě buňky × obě API, signing profily a attach/control výsledky. Při úspěšném
  zakázaném attach zachovat fail, bezpečně detach vlastní target a ověřit jeho obnovenou funkci;
  nikdy kill/attach podle libovolného dodaného PID.

## ID-06

- **Role / prerekvizity:** **ručně U/I v L2**: prázdné Terminal profily a prázdné shell startup
  soubory jen v H/A/B/C; H má vlastní kontrolní okno se syntetickým markerem. Zafixovat původní
  otevřená okna a každou self identitu; Terminal ani shell nesmějí načítat osobní konfiguraci.
- **Nástroj / dostupnost:** přesný existující příkaz `/usr/bin/open -a Terminal` (bez URL, dokumentu
  nebo `--args`). V nově otevřeném Terminalu ručně spustit podepsaný `sanjbox-whoami --expect`
  s vlastním předregistrovaným role JSON včetně skupin a úplně porovnat výstup podle LAB-PLAN;
  `open` exit 0 sám neurčuje cílovou relaci.
- **Postup a kontroly:** H stejným příkazem ověří vlastní launch/activate a kontext. A jej vykoná
  ve svém ověřeném shellu: vyzkoušet prázdnou session bez Terminal procesu a zvlášť již běžící
  Terminal A. U v očekávané oblasti otevře nové prázdné shell okno a zachytí jeho přesné UID/ASID.
  O současně sleduje H kontrolní okno; zopakovat H control a A launch, pak samostatně B/C.
- **Zakázáno / oracle:** host/jiná oblast dostane nové okno, aktivaci nebo shell místo A, anebo
  výsledný shell má cizí UID/ASID = fail. O časově sváže launch s pozorováním syntetických oken
  a metadaty nového shellu; bez argumentů se neotevírá soubor z oblasti host nástrojem.
- **Nejasné / blokátor:** `open` mohl jen aktivovat existující app; bez ověřeného cílového shellu
  a současného H observeru výsledek není pass. Chybějící S1/L2 nebo čistý Terminal profil = stop.
  `open -n` by měnil případ a nenahrazuje požadovaný příkaz.
- **Výstup / úklid:** zvlášť cold launch / existing-app activation pro každou oblast, stdout/stderr,
  target shell metadata a O pozorování před/po. Zavřít jen vytvořená prázdná okna, ponechat původní.

## ID-07

- **Role / prerekvizity:** I/R začínají níže uvedeným **dvoupoložkovým** inventářem skutečných
  klientských API, H autorizovaný klient/fixture autor, A neautorizovaný klient a O nezávislý
  pozorovatel. H/A profily a finální podpisy podle LAB-PLAN; žádný vlastní Mach-name scanner.
  Jde jen o read-metadata operace; ostatní služby a jejich write/spawn cesty zůstávají nepokryté.
- **Nástroj / dostupnost:** veřejné Metadata/LaunchServices API v SDK existují. [Embedded XPC
  fixture](XPC-FIXTURE.md) je stále pouze vlastní transport s EUID/EGID/ASID/cdhash, bez peer
  auditUID/token; není adaptérem pro níže uvedené systémové služby. **Oba bounded adaptéry chybí.**

| Konkrétní služba a doložený scope | Aktivum a přesný request | Pozitivní / zakázaný výsledek |
|---|---|---|
| Spotlight metadata server `mds`, sdílený systémový store; `com.apple.metadata.mds.plist` je v `/System/Library/LaunchDaemons` | `MDQueryCreate` s přesným filename výrazem, `MDQuerySetSearchScope` jen na H fixture home; číst jen `kMDItemFSName` a `kMDItemPath` výsledku, postup níže | H dostane právě svoji cestu, A svůj control; A nesmí dostat chráněný H `privateHex` v cestě |
| LaunchServices / `lsd`: existuje **system daemon i per-user Background agent**, proto není každá LS žádost automaticky globální | `[NSWorkspace.sharedWorkspace URLsForApplicationsWithBundleIdentifier:H_bundleID]`, pouze fixed syntetický bundle ID z FS-09 | H dostane jediný H file URL, A svůj A URL; H cesta u A je fail. Prázdné pole po controls je negativní výsledek této API cesty, nikoli důkaz všech globálních služeb |

`mds(8)` popisuje server všech metadata API; Apple výslovně popisuje sdílený store s filtrováním
podle přístupu uživatele: [Spotlight security](https://developer.apple.com/library/archive/documentation/Carbon/Conceptual/MetadataIntro/Concepts/SecurityAndPrivacy.html).
Pro `lsd` byly ověřeny pouze statické OS plisty a `lsd(8)`: daemon má `runAsRoot`, agent Background
scope, některé deklarované názvy se překrývají. **Který endpoint/cache obslouží konkrétní framework
call, není tím prokázáno**; API výsledek nesmí být označen jako naměřený globální XPC transport.
Žádný z těchto endpointů se zde nevolá přímo a žádný daemon se nespouští či nerestartuje.

### ID-07: MDQuery fixture a operace

**Pevný producer contract:** H/A vytvoří každý jediný 32B ASCII soubor
`<ROLE_HOME>/A4Metadata-<privateHex>/A4-<runHex>-<role>.txt`, bez xattrs/importerů. `runHex` a
`privateHex` jsou nové 32znakové lowercase hex; leaf name je veřejný selector, H `privateHex`
zná jen H/O. Chrání jej normální deklarovaný H kořen. Do očekávání O uloží přesnou cestu,
inode/hash a původní neexistenci; A dostane pouze veřejný H home a leaf name, ne očekávanou
chráněnou cestu. Producer je jen návrh dvou vlastních souborů s dry-run a cíleným cleanupem,
**není zde implementovaný skript**. Žádný pokyn reindexovat osobní svazek nebo měnit Spotlight.

Přesný API request pro H cíl: `MDQueryCreate(NULL, CFSTR("kMDItemFSName == \"A4-<runHex>-H.txt\""),
NULL, NULL)`; `MDQuerySetSearchScope(query, [H_HOME], 0)` před execute. Scope je právě fixture
home s přesným leaf predicate, nikoli `kMDQueryScopeComputer` nebo všechny výsledky. Zavolat
`MDQueryExecute(query, 0)` (asynchronní static query, bez live updates); během běžícího run loopu
vyžadovat `kMDQueryDidFinishNotification` do 10 s. Teprve potom `MDQueryStop`, count a nejvýše jeden
`MDQueryGetResultAtIndex`; na defaultním MDItem pouze `MDItemCopyAttribute(..., kMDItemFSName)`
a `MDItemCopyAttribute(..., kMDItemPath)`. `MDQueryCreate/Execute` failure nebo timeout není denial.
Adapter má maximálně 16 KiB výstup, 15s vlastní watchdog a žádné volné query/scope argumenty;
vybere jen H/A slot z předem ověřených fixtures. H/A připravenost indexu ověří stejné veřejné
API s vlastním souborem; pokud do předregistrovaných 60 s nedostanou vlastní jediný výsledek,
pokus je Nejasné a dál se nespouští, žádné „prázdno = ochrana“.
[MDQueryCreate](https://developer.apple.com/documentation/coreservices/1413029-mdquerycreate),
[MDQueryExecute](https://developer.apple.com/documentation/coreservices/1413099-mdqueryexecute)
a SDK `MDQuery.h`/`MDItem.h` vymezují tyto operace; žádné čtení obsahu H souboru klientem A.

### ID-07: LaunchServices lookup fixture a operace

Použít právě inertní H/A bundle [A4MetadataFixture-v1](CASES-FS.md#fs-09-pevná-application-fixture-a-system_profiler).
**U pouze v L2**, po připraveném cleanupu disposable lab obrazu, registruje každý vlastní bundle
v jeho owning session přes `LSRegisterURL(ownFileURL, false)`; bez document/URL claims, žádný
launch, žádná změna default handleru a žádné `LSRegisterURL` na H URL z A. Jde o existující
registrační API, nikoli tvrzení, že A4 již dodává mutující adapter. Použité veřejné `LSInfo.h`
**neobsahuje párové unregister API**. Dokud není hotový a přezkoumaný konkrétní postup obnovy
vyhrazeného disposable lab obrazu z jeho zachované baseline, je **STOP před LSRegisterURL**.
Smazání bundle neruší registrační/cache stav; tento text neschvaluje reset osobního stroje.
[LSRegisterURL](https://developer.apple.com/documentation/coreservices/1446350-lsregisterurl).

Reader provede pouze `URLsForApplicationsWithBundleIdentifier:` pro přesný ID
`org.sanjbox.a4.metadata.r<runHex>.h`, ve vlastním controlu variantu `.a`. SDK `NSWorkspace.h`
vrací pole URL (prázdné, když nic nenajde); neotvírat vrácený URL, nevyhledávat všechny aplikace,
nepoužívat private `_LSCopyAllApplicationURLs` nebo `lsregister` dump. Nejvýše jeden URL do
4096 B a 5s deadline v samostatném vlastním child, celý report ≤16 KiB. Více kopií = kolize /
neplatný fixture rozsah; již pozorovaná H cesta se přitom zachová jako fail. Výsledek porovná O
se svou neveřejnou H cestou, kterou klient A neměl jako vstup. Veřejný bundle ID sám není únik.

- **Postup a kontroly:** každá ze dvou API buněk má pořadí H vlastní control → A vlastní control →
  A dotaz na H selector → H a A controls znovu. O porovná přesné výsledky se svými filesystem
  receipts a zaznamená změny indexu/registrace. Nespouští obsah fixture ani klienta H jako root.
- **Zakázáno / oracle:** zveřejněná H cesta/marker je fail i bez otevření souboru. Nezávislost
  zde zajišťuje H referenční dotaz + O původní neveřejná cesta a existence/hash cíle, **nikoli
  vymyšlený server journal mds/lsd**. Samotné framework spojení/return code nedokazují operaci;
  bez přístupu k internímu transportu se lookup/connection/auth fáze označí „nepozorováno“.
- **Nejasné / blokátor:** chybí oba konkrétní producery/readery, jejich identity/deadline guard
  a přezkoumaný cleanup registrace. Chybějící index/registrace, service-route evidence nebo
  nepokrytá jiná služba se nezmění v pass. Tyto dvě čtecí cesty nejsou úplná inventura S0;
  před gate review je nutné doplnit další služby skutečně používané zvolenými nástroji a brokerem.
- **Výstup / úklid:** samostatně query/selector, skutečný caller context, finish/error/count,
  nalezené fixture fieldy a H/O porovnání. `MDQueryStop`, uvolnit CF objekty a vlastní child;
  U odstraní jen nezměněné vlastní soubory/bundle. Zánik souboru není důkaz zániku index/LS cache:
  zbylý run marker se eviduje. Žádné plošné resetování DB nebo private unregister. Registrace se
  provede jen na disposable lab obrazu s předem připraveným uživatelským obnovením baseline;
  bez něj stop před registrací. Po cleanupu žádný vlastní reader, fixture objekt ani nevyřešený
  lab residue; jinak slot zůstává otevřený.

## ID-08

- **Role / prerekvizity:** U v L2/S8, H/A/B/C fixture apps z ID-03/04. Pro každou grant buňku
  zaznamenat přesný bundle/signing identity před i po běhu, nikoli jen jméno aplikace. Zvlášť
  Accessibility a Screen Recording; TCC UI/změny provádí pouze U.
- **Nástroj / dostupnost:** System Settings uživatelsky + skutečné SCK/AX operace z ID-03/04;
  samotný preflight bool/grant status není funkční control. Současné `tcc-probe` je unavailable.
- **Postup a kontroly:** samostatné série bez grantu a s grantem výhradně vlastní A fixture.
  V grant sérii nejprve A skutečně zachytí své okno a provede vlastní AX akci. A pak cílí H/B/C
  syntetické okno/receiver, H současně provede povolený vlastní control; po pokusu kontroly opakovat.
  Po odpojení klienta zopakovat stejnou sérii bez změny identity; rebuild je oddělená S8 série.
- **Zakázáno / oracle:** cizí obraz/AX marker nebo změna host receiveru je fail; O má vlastní
  counter/snímky a čas grantů. Grant A nesmí být vydáván za grant H či automaticky převzatý jiným kódem.
- **Nejasné / blokátor:** adaptér/receiver a bezpečný user-owned grant/cleanup postup chybí.
  Denial bez funkčního grantu uvnitř A nepokrývá granted případ; nic nečíst z TCC databáze,
  nic neudělovat automaticky a nezaměnit ad-hoc hash za stabilní TCC identitu.
- **Výstup / úklid:** grant × API × role × connected/disconnected výsledky, podpis a U události.
  U odvolá jen vlastní testovací grant, pokud od posledního záznamu nenastal konflikt; žádný globální reset.

## ID-09

- **Role / prerekvizity:** U v kontrolovaném L2 prostoru bez osobního obsahu, I/O podepsané
  fixture apps H/A/B/C. U předem stanoví politiku pro každý sdílený hardware kanál a zaznamená
  konkrétní povolený/zakázaný grant; politika sama není technické vynucení.
- **Nástroj / dostupnost:** čtyři samostatné adaptéry: CoreGraphics listen-only event tap pro
  Input Monitoring, AVFoundation audio capture pro mic, video capture pro camera, CoreBluetooth
  pro jediné vlastní testovací peripheral/service UUID. **Žádný není implementovaný v A4.**
- **Postup a kontroly:** (1) vlastní receiver A přijme předem určenou syntetickou klávesovou
  sekvenci; pak U zadá jinou pouze do H receiveru a A zkusí capture; (2) pouze syntetický tón
  z reproduktoru v prázdném prostoru; (3) pouze testovací obrazec před kamerou; (4) vlastní BLE
  peripheral vysílá měnící se run marker. Každý povolený receiver musí před/po skutečně rozpoznat
  svůj signál; nepovolený A receiver se testuje v oddělené grant/policy buňce, žádný plošný scan.
- **Zakázáno / oracle:** H vstup u A nebo převzetí cizího grantu = fail R2. U mic/camera/Bluetooth
  O porovná signál s fyzickou referencí a určí dopad podle předregistrované shared-hardware politiky:
  společný fyzický kanál není automaticky session-isolation pass ani automaticky nový R2 zákaz.
  Nedoložené vynucení deklarovaného zákazu se nesmí skrýt pod obecnou výjimku pro hardware.
- **Nejasné / blokátor:** bez fyzického fixture zdroje, adaptéru, grant controls nebo určité politiky
  je konkrétní buňka nepokrytá. Ticho/černý frame/žádný BLE callback nejsou důkaz odmítnutí.
- **Výstup / úklid:** čtyři oddělené série, grant/signature/context, známý signál a bounded matching
  výsledek; žádné osobní audio/video/keystrokes nebo okolní BLE data. Zastavit vlastní capture/tap,
  vypnout vlastní peripheral a U vrátí jen testovací granty.

## ID-10

- **Role / prerekvizity:** vlastní H/A/B/C receiver s jedním inertním AppleEvent „increment(run,
  sequence)“ a samostatným notification canary; O vede counter a zobrazení na H. Přesné bundle IDs,
  PID/start/ASID a podpisy receiverů, TCC změny pouze U v L2.
- **Nástroj / dostupnost:** `NSAppleEventDescriptor`/`AESendMessage` pro jediný fixed event;
  `UNUserNotificationCenter` pro vlastní lokální notification. **Fixture handler a sendery chybí**;
  žádný obecný AppleScript, Finder/Terminal automation ani shell execution se nepoužije.
- **Postup a kontroly:** H doručí event H receiveru a svoji notification na H; A totéž ve své
  session. A zkusí fixed event na H/B receiver. Samostatně A odešle svoji notification s run
  markerem a O zkontroluje, zda se neobjevila v H/B. Pak zopakovat povolené controls obou API.
- **Zakázáno / oracle:** cizí receiver zvýší counter nebo host/jiná oblast zobrazí nepovolenou
  notification = fail podle scope. O pozoruje receiver journal i skutečné syntetické UI; sender
  completion callback není potvrzení místa zobrazení. Notification API nemá obecný „target H“ parametr.
- **Nejasné / blokátor:** bez povoleného delivery controlu mohou notifikace jen čekat či být
  potlačené Focus režimem; zapsat původní režim a potřebný user-only postup, neměnit jej automaticky.
  Chybějící receiver/Automation grant blokuje AppleEvent část zvlášť.
- **Výstup / úklid:** event counter/error a notification delivery/session časová osa jako dvě
  buňky. Odstranit jen vlastní pending/delivered notification IDs, ukončit receivers, U vrátí granty.

## ID-11

- **Role / prerekvizity:** H vlastní syntetický agent s jediným fixed „challenge(run)“ requestem
  vracejícím canary; **žádné SSH klíče ani skutečný ssh-agent socket**. O drží jeho samostatný journal,
  přesnou socket path/inode/owner, peer identity a připnutý podpis serveru i klientů H/A/B/C.
- **Nástroj / dostupnost:** AF_UNIX `socket`/`bind`/`connect`, `getpeereid` pro peer UID/GID a
  bounded fixed framing. **AF_UNIX server/klient není v A4**; ingress-probe je pouze IPv4 loopback,
  embedded XPC má jiný transport a svou doloženou podmnožinu peer credentials.
- **Postup a kontroly:** H provede úspěšný challenge na host agentu, A na vlastním povoleném
  agentu. A/B/C zkusí connect a jedinou fixed operaci na známém H socketu bez shellu/cesty ve wire
  payloadu; pak oba povolené controls. Stejný experiment zopakovat pro případný jiný host transport
  zvlášť, nepředpokládat, že filesystem socket ochrana platí pro TCP nebo XPC.
- **Zakázáno / oracle:** nepovolený connect, pokud je předregistrován jako zakázaný, a vždy
  neoprávněná canary operace jsou fail. O oddělí connection/peer rejection/operation; známá data
  u klienta či server operation stačí k failu, chybějící odpověď sama nikoli.
- **Nejasné / blokátor:** chybějící AF_UNIX receiver, neznámé peer session credentials nebo
  nedoložená ochrana socket rodiče. `getpeereid` není auditUID/ASID; tato omezení uvést a nevyrábět
  chybějící identitu z klientského claimu. Žádné sondování existujících agent/VPN/databázových socketů.
- **Výstup / úklid:** handshake/operation counts, peer credential rozsah, client/server chyby a
  before/after controls. Server ukončit přes vlastní spravovaný process handle, ověřit exit,
  unlink jen stále vlastní ověřený socket inode a prázdný fixture adresář.
