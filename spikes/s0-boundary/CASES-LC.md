# LC — ruční příprava jedenácti případů

Společné identity, signing, výstupy a konfliktní úklid jsou v [LAB-PLAN](LAB-PLAN.md).
**Tento checkout nemá controller pro vypnutí/pauzu celého UID, revokaci loginu ani UID allocator.**
Karty popisují konkrétní kontrolované experimenty s existujícími OS mechanismy; chybějící controller
je skutečný stop, nikoli pomyslný příkaz. `lifecycle-probe` testuje pouze echo/EOF/waitpid jediného
vlastního `/bin/cat`; nepřijímá PID, UID, label ani lifecycle akci. Žádný LC běh se zde neprovedl.

## Společná lifecycle časová osa

U v L2 použije jen vyhrazené testovací UID A/B/C a čistého H pozorovatele O. Předem určí důvěryhodnou
host cestu start/stop/pause, její konkrétní commit/API a okamžiky „start blokován“, „stop requested“,
„off confirmed“, případně „quiescent confirmed“. Dokud tato cesta neexistuje, uvedené kroky se
**nespouštějí** a neregistrují se joby jen pro získání prázdného neúplného výsledku.

O musí nezávisle sledovat celý vyhrazený UID, oba `gui/<uid>` a `user/<uid>` rozsahy, naplánované
triggery a opětovné spuštění po celou předregistrovanou dobu. Potřebuje číselnou identitu instance
(PID, real/effective UID, start), ne jména/argumenty cizích procesů. Ztráta observeru = Nejasné.
A2 [process-series](../s1-session/PROCESS-SERIES.md) sleduje jen předregistrované instance stejného
UID a nedetekuje všechny nové děti; není tento úplný oracle. Jednorázový `ps`, nulový heartbeat,
`bootout`, `disable`, odhlášení GUI ani `SIGSTOP` vybraných PID nejsou důkaz nulového UID/quiescence.
**Úplný observer a review zákazu nového startu zatím chybějí.**

Každá budoucí job fixture má pevný inertní executable bez shell dispatch, vlastní run/sequence,
self gate a finální podpis, explicitní omezení počtu procesů a doby života. Před spuštěním musí být
hotové její ověření a cílený úklid. Více helperů stejného názvu se rozlišuje skutečnou instancí;
číselný PID z nedůvěryhodného logu nedává oprávnění poslat signál. O vede vlastní journal a vedle
A i povolený kontrolní heartbeat H nebo B, který prokáže funkční recorder během vypnutí A.

„Pozitivní kontrola po“ u stopu není spuštění vypnuté A: O ověří živý H/B control ve stejné době.
Teprve po uzavření negativního intervalu může U **novým autorizovaným startem** A ověřit původní
trigger znovu. Před tímto startem ověřit/uklidit zbytky předchozího běhu; žádný dodatečný control
nesmí smazat fail. Návrh LAB §9 (≥3 přechody, race 10 min a ≥100 přechodů) doplní U/R konkrétními
intervaly podle triggeru. Neznámá horní mez retry/job doby je otevřená mezera.

## LC-01

- **Role / prerekvizity:** U registruje vlastní GUI LaunchAgent v oblasti A, O pozoruje H.
  Přesně očekávaný A Aqua/ASID, finální podpis jobu i controlleru; label a plist jsou nové a vlastní.
- **Nástroj / dostupnost:** OS `launchctl bootstrap gui/<uid> <vlastní-plist>`, `kickstart` na
  přesný service-target a `bootout` téhož vlastního service-targetu. Jsou to formy ručního
  **budoucího U kroku**, ne povel k registraci zde. Bounded heartbeat job a controller chybí.
- **Postup a kontroly:** registrovaný job nejprve skutečně startuje a O vidí A heartbeat; H/B
  control běží. U vypne A přes skutečný controller. U vyvolá původní trigger po off; job nesmí
  vzniknout. O dál ověřuje H/B control; po uzavření intervalu a autorizovaném startu ověřit A znovu.
- **Zakázáno / oracle:** libovolný přeživší/nový A proces po off, včetně nově restartovaného
  LaunchAgentu, je fail. O ověří celý UID a domény, nejen původní PID či ztracený marker.
- **Nejasné / blokátor:** bez controlleru, bounded jobu a úplného observeru se případ nespouští.
  `bootout` samotného fixture jobu by jen dokazoval ruční odstranění té jedné registrace.
- **Výstup / úklid:** label/plist hash, registrace, trigger/time a observer časová osa. U odstraní
  jen vlastní stále shodnou registraci a plist po potvrzení exit; konflikt drží slot otevřený.

## LC-02

- **Role / prerekvizity:** U/I v čistém A testovacím účtu, O na H; zvlášť cron a at. Job self
  identity používá předem pozorovaný Background profil/ASID, nikoli předpokládaný GUI profil.
- **Nástroj / dostupnost:** `crontab` a `at`/`atq`/`atrm` OS utility; U inventarizuje pouze vlastní
  testovací tabulku/job IDs. `/usr/lib/cron/cron.allow` má přednost před `cron.deny`, obdobně
  `at.allow` před `at.deny`; řádky obsahují **uživatelská jména, ne skupinu sanjbox**.
- **Postup a kontroly:** před off nechat jeden přesně naplánovaný inertní job skutečně vykonat;
  druhý vlastní job již musí čekat na termín po off. U vypne A, po off projde naplánovaný termín
  a U zkusí testovací cestou vytvořit další job. H/B control před/po potvrzuje běh recorderu/scheduleru;
  po autorizovaném restartu ověřit povolený trigger A znovu.
- **Zakázáno / oracle:** již naplánovaný job po off vykoná operaci nebo nový job spustí A proces
  = fail. O ověří nulu UID i původní job IDs/termíny. Deny soubor sám neodstraňuje staré úlohy.
- **Nejasné / blokátor:** vypnutý/nefunkční scheduler není pozitivní control. Chybí bounded job,
  revokace stávajících i nových úloh, controller a observer; U musí dodat dry-run/původní stav
  systémových změn, žádná úprava allow/deny ani zapnutí služby automaticky.
- **Výstup / úklid:** cron a at zvlášť, tabulka username/allow precedence, IDs, skutečné časy.
  U odstraní jen své přesné testovací řádky/job IDs při stále shodném původním stavu; nemaže celou
  cizí tabulku ani spool. Vlastní změny allow/deny vrací konfliktně bezpečně.

## LC-03

- **Role / prerekvizity:** U v L2/S8, A user-level fixture app, O na H. Samostatně LoginItem a
  SMAppService LaunchAgent; přesná očekávání startup markerů, app/helper signing identity a run ID.
- **Nástroj / dostupnost:** existující [S8ServiceHost UI](../s8-signing/SERVICES.md#ui-a-evidence-uživatel-budoucí-l2)
  umí po uživatelské akci `register/unregister` jen těchto dvou služeb a jen non-ad-hoc profil.
  Default `plan` a builder `prepare` jsou dry-run. Helpers emitují jediný startup marker a končí;
  nejsou dlouhožijící heartbeat job. Daemon mutace nejsou implementované.
- **Postup a kontroly:** po vyřešení níže uvedených blockerů U skutečně registruje v A, O potvrdí
  správný startup kontext. Zvlášť okamžitý start, další login a reboot; před off odpovídající
  trigger prokazatelně funguje. U vypne A a zkusí stejný trigger při blokovaném A loginu/startu.
  H/B kontrola po + nový autorizovaný start A teprve po uzavření negativního intervalu.
- **Zakázáno / oracle:** nový/přeživší A proces po off je fail, i když marker chybí nebo má helper
  exit 0. O váže startup marker na nezávislou časovou osu a celý UID; `validMeasurement=false`
  v S8 markeru se nepřepisuje na true bez samostatného hodnocení.
- **Nejasné / blokátor:** S8 dokumentuje **chybějící cleanup po restartu UI/login/reboot** a host
  cestu; jeho UI neadoptuje starou registraci. K tomu chybí controller/observer. Žádná registrace,
  podpis identitou nebo login/reboot zde; pouhá sestavitelná app neznamená připravený LC běh.
- **Výstup / úklid:** intent/result/status + startup events pro obě služby a každý trigger.
  U provede jen předem schválený vlastní unregister/removal a ověří exit i nemožnost restartu.
  Ad-hoc builder cleanup **není** cleanup re-signované/registrované aplikace.

## LC-04

- **Role / prerekvizity:** A job v `user/<uid>`, samostatný od `gui/<uid>`; O na H. Preregistrovat
  skutečný manager, auditUID/ASID a window profile jobu. Jméno domény není self identity důkaz.
- **Nástroj / dostupnost:** OS `launchctl bootstrap user/<uid> <vlastní-plist>` a exact-target
  `kickstart/bootout`. Bounded non-GUI job, celý-UID controller a observer nejsou dodané.
- **Postup a kontroly:** nejprve job skutečně spustit, doložit funkci i po řízeném odhlášení
  GUI A (to ještě není off). Znovu ověřit jeho kontext; pak U provede skutečné vypnutí celého A.
  Zkusit vlastní původní user-domain trigger během/po stopu, H/B controls před/po.
- **Zakázáno / oracle:** přežití user jobu nebo opětovné spuštění po off je fail. O sleduje user
  i gui doménu a veškeré A procesy; nepřítomnost GUI není nulou UID.
- **Nejasné / blokátor:** pokud job nepřežil samotný GUI logout, tento pokus neověřil zamýšlený
  zbylý user-domain povrch; jeho skutečné chování zachovat a doplnit platný fixture control.
  Bez controlleru/observeru stop; nepoužít ruční bootout jako náhradu vypnutí.
- **Výstup / úklid:** oddělené mezníky GUI logout versus whole-UID off, marker a domain identity.
  U zruší jen vlastní user-domain service a jeho plist po potvrzení zániku, nezruší celou host doménu.

## LC-05

- **Role / prerekvizity:** A inertní CLI fixture, která se odpojí od původního terminálu a
  přežije jeho zavření, O na H. Předregistrované instance/start/UID, přesná původní i odpojená
  session identita a bounded lifetime; žádný osobní proces nebo PID vybraný podle jména.
- **Nástroj / dostupnost:** pevný job může použít POSIX `setsid`/odpojení a heartbeat; **takový
  fixture není dodaný**. `lifecycle-probe` vlastní child s EOF naopak zaniká s řízeným vstupem,
  takže není control odpojeného procesu.
- **Postup a kontroly:** O prokáže heartbeat před i po zavření původního Terminalu; přímý
  parent wait není důkaz, že detached potomek zmizel. U provede off a pozoruje se celý A UID,
  nejen fixture tree; H/B controls pokračují. Po uzavření intervalu případný autorizovaný start.
- **Zakázáno / oracle:** kterýkoli A proces, i zastavený nebo odpojený, po off = fail.
  Nulový heartbeat s existujícím procesem není pass; O musí doložit procesní inventář i start exclusion.
- **Nejasné / blokátor:** chybí bezpečný detached fixture, celé UID observer a controller.
  Krátce žijící child/reap test ani ztracený stdout/příkaz `ps` jednou po stopu nestačí.
- **Výstup / úklid:** původní/odpojená instance vazba, terminál-close/off časy, plná UID pozorování
  a H/B liveness. Ukončit jen vlastní stále prokázané instance přes schválený controller/handle;
  při neověřitelném ownership nedávat numerický kill, konflikt předat U.

## LC-06

- **Role / prerekvizity:** U ovládá skutečný controller A z H, vlastní externí start sender z H/B,
  O zaznamenává přechody. Podepsané fixtures i controller mají přesná samostatná očekávání.
- **Nástroj / dostupnost:** potřebný konkrétní start/stop API a deterministické bariéry controlleru
  **neexistují v tomto checkoutu**. Čistý budoucí H2 model nemůže nahradit OS start enforcement.
- **Postup a kontroly:** povolený start na začátku vytvoří přesně jednu fixture. Vyvolat stejný
  start před uzavřením admission, po uzavření, při ukončování domén, při ověřování nuly a po off.
  Každý přijatý požadavek před revokací musí být buď vyřízen a před off zrušen, nebo doloženě odmítnut;
  po revokaci žádný nový start. O drží pořadí/sequence, H/B control před/po a až pak nový start A.
- **Zakázáno / oracle:** nový start po uzavření admission nebo jakýkoli proces po off = fail.
  O porovná controller transition journal s kernel procesními událostmi; odpověď „denied“ bez
  kontroly procesu nestačí. Souběžné platně přijaté požadavky se nesmějí ztratit z účtování.
- **Nejasné / blokátor:** chybějící bariéra/časová vazba neumístí pokus do kritického okna;
  takový race je Nejasné. Chybí controller, sender a úplný observer, ne pouze testovací dokument.
- **Výstup / úklid:** transition × request ID × admission result × process identity, bez mezer
  v čase; nejméně navržený race budget LAB. U vyprázdní jen vlastní pending requests a fixture,
  ověří nulu A a neponechá automatický retry sender aktivní.

## LC-07

- **Role / prerekvizity:** A bounded fork fixture + vlastní job trigger, O na H, skutečný pause
  controller. Přesné profily všech instancí, předem pevný limit současných dětí a celkových forků;
  nejde o fork bombu ani test dostupnosti hosta.
- **Nástroj / dostupnost:** POSIX `fork` a launchd job trigger jsou dostupné; **bezpečný fixture,
  quiescence mechanismus a race bariéry nejsou implementované**. SIGSTOP jedné tree není tento mechanismus.
- **Postup a kontroly:** před pause O vidí růst heartbeat/child counter a funkční vlastní job.
  Vyvolávat omezené forky/job starty před bariérou, při vstupu do pause a po quiescent potvrzení.
  Po celou pause nesmí narůstat žádný A computation/operation counter ani vzniknout nový A proces;
  H/B control pokračuje. Po výslovném resume se A povolený counter znovu rozběhne.
- **Zakázáno / oracle:** nový/progressující A proces po potvrzeném quiescence nebo vykonaná
  zprostředkovaná A operace = fail. O sleduje celé UID a konkrétní cílový receiver, ne pouze
  vlastní parent; u pause se neočekává nula existujících procesů, nýbrž nulový běh a nové starty.
- **Nejasné / blokátor:** bez doložené ochrany proti novému jobu/forku a práce služeb jménem A
  nelze tvrdit stabilní quiescence. Vyčerpaný fixture limit či mrtvý generátor race není denial.
- **Výstup / úklid:** fork/job counts, bariéry, quiescent/resume časy, target counters a procesní
  řada. Controller bezpečně obnoví nebo vypne A, ověří všechny vlastní děti a registrace; žádné
  neomezené forkování nebo nezávislé signály na seznam PID.

## LC-08

- **Role / prerekvizity:** U na H, vlastní controller/helper pro testovací A, O nezávislý na něm.
  Přesné podepsané buildy a jejich instance; žádný kill systémového launchd či sdílené služby.
- **Nástroj / dostupnost:** potřebné bounded fault hooks a recovery controller **chybějí**.
  Fixture-only crash má mířit pouze na vlastněnou instanci, nikdy na libovolný dodaný PID.
- **Postup a kontroly:** nejprve normální autorizovaný start/stop a H/B liveness. V nových bězích
  vyvolat pád před revokací admission, po revokaci/před zánikem procesů a po off; během pádu i
  restartu controlleru opakovat přesnou start/login žádost z LC-06/09. Recovery nesmí zpřístupnit A
  před obnovením ochran a dokončením úklidu; po uzavření intervalu povolený control znovu.
- **Zakázáno / oracle:** fail-open start, falešný off s procesem nebo restart zakázané operace
  je fail. O má nepřerušenou nezávislou řadu a journal stavů před/po pádu; pád recorderu spolu
  s controllerem by zničil oracle a není důkaz vypnutí.
- **Nejasné / blokátor:** bez konkrétního recovery mechanismu/fault hooku/úplného observeru se
  případ nespustí. Zabití jediného A4 child nezkouší selhání řídicí komponenty.
- **Výstup / úklid:** fault point, skutečný exit/restart, zachovaný nedokončený stav a start
  attempts. U obnoví jen vlastní komponentu podle předem otestovaného recovery/cleanup postupu;
  nevyřešená recovery znamená neuklizený slot, nikoli odstranění chybového journalu.

## LC-09

- **Role / prerekvizity:** U v L2, samostatný kontrolovaný testovací klient H/B, A účet a O mimo
  klienta i controller. Remote Login/Screen Sharing a síťovou ochranu konfiguruje pouze U;
  pouze testovací účet, žádné uložené osobní SSH credentials/Keychain ani produkční RFB cíl.
- **Nástroj / dostupnost:** systémový SSH klient a Screen Sharing.app (S1 postup). **A4 neumí
  tyto přihlašovací pokusy ani revokaci loginu**; dostupný klient není lifecycle enforcement.
- **Postup a kontroly:** nejprve obě cesty jednotlivě úspěšně přihlásí povolenou A, cílový shell
  nebo session doloží přesný A kontext. Zvlášť již navázaná session a nové spojení: U vypne A,
  pokusy běží během revokace i po off, včetně reconnectu. H/B autorizovaný control prokáže
  funkční službu před/po; A teprve po uzavření intervalu nově autorizovaně zapnout.
- **Zakázáno / oracle:** nový A proces/session nebo přetrvávající stará A práce po off = fail.
  O sleduje UID/session vznik i skutečné vykonání pevné canary operace; pouhé auth UI „error“
  nestačí. Síťově mrtvá služba bez pozitivního controlu není důkaz zákazu loginu A.
- **Nejasné / blokátor:** chybí controller, revokace a úplný oracle; S1 login samotný je opakem
  chybějícího zákazu. Bez schválené ochrany ingress a cleanupu se služby nezapínají.
- **Výstup / úklid:** SSH a Screen Sharing zvlášť, existující/nové/reconnect, auth/session časy
  a O procesní řada bez hesel. U odpojí vlastní klienty a vrátí jen své původní sharing/network
  změny; žádná změna pf nebo systému z tohoto přípravného balíku.

## LC-10

- **Role / prerekvizity:** U na důvěryhodném H, A neautorizovaný žadatel, O. Vlastní inertní
  LaunchDaemon má jen canary startup observation; přesný system helper context/podpis a host
  approver context se předregistrují odděleně. Root operace z oblasti nesmějí existovat.
- **Nástroj / dostupnost:** [S8 disposable daemon](../s8-signing/SERVICES.md) existuje jako target/
  plist/preview/status; **register/unregister adaptéry a host-only autorizace nejsou implementované**.
  UI alert, onConsole flag ani znalost run ID nejsou důvěryhodnou host autorizační hranicí.
- **Postup a kontroly:** až po dodání host cesty U z H schválí vlastní testovací operaci a O
  ověří skutečný canary start. Před negativním blokem vlastní registraci bezpečně zrušit a ověřit
  nulový výchozí stav. A zkusí tutéž žádost a podvržené host approval claims bez jakéhokoli
  zadání admin hesla v A. O ověří nulu registrací/startů; následný host control opět musí fungovat.
- **Zakázáno / oracle:** přijetí privilegované operace nebo daemon start vyvolaný pouze A je fail.
  O ověří účinek/registraci a kernel-derived caller identity; odmítnuté tlačítko samo není oracle.
- **Nejasné / blokátor:** bez host-only autorizační/cleanup cesty a oprávněného pozitivního
  controlu se experiment nespouští. Tento dokument nepřidává daemon mutaci do S8 ani root API pro A.
- **Výstup / úklid:** host approval jako samostatná U událost, request/response a nezávislý
  registration/start journal. Jen U z H zruší vlastní schválenou registraci, ověří exit/no restart
  a odstraní stále shodnou instalaci; případný konflikt nesmí být zameten plošným bootout/resetem.

## LC-11

- **Role / prerekvizity:** **F2**, U/O na H, konkrétní UID allocator a recovery controller,
  dvě logické oblasti A-old/A-new a oddělená generace identity. Současné A4 ani izolovaný mock
  H2 nejsou F2 integrace; účet/UID se zde nevytváří ani nepřiděluje.
- **Nástroj / dostupnost:** požadované allocator/create/delete/recover rozhraní **v tomto checkoutu
  chybí**. Není OS utility, která by sama garantovala zákaz opětovného přidělení UID Sanďboxu.
- **Postup a kontroly:** s hotovým F2 nejprve úspěšně přidělit jiný čistý UID jako pozitivní
  control. U odstraní A-old; deterministicky zadrží úklid (zbylý vlastní proces, job registrace,
  svazek/souborová vlastnictví, pending oprávnění) a požádá o stejný UID pro A-new v každém
  mezistavu i po pádu/recovery. A-new musí být odmítnut, zatímco jiný volný UID zůstává použitelný.
  Po úplném ověřeném úklidu povolit reuse podle politiky a ověřit novou generaci bez starého stavu.
- **Zakázáno / oracle:** předčasný reuse, přístup A-new ke starému canary nebo přijetí starého
  jobu/handle/generace je fail. O porovná allocator ledger s reálnou nulou procesů, zrušenými
  registracemi, stavem svazků/objektů a revokací starých oprávnění, nikoli jen `deleted=true`.
- **Nejasné / blokátor:** chybí allocator, cleanup/recovery bariéry i úplný seznam zdrojů;
  mock odmítnutí v paměti je jen příprava. LC-11 zůstává **F2**, nelze jej vykázat z L2 ani ze
  samotného smazání účtu. Neznámá stará oprávnění blokují prohlášení bezpečného reuse.
- **Výstup / úklid:** stará/nová generace, každý cleanup blocker, rozhodnutí allocatoru a O stav
  před/po recovery; pozitivní přidělení jiného UID i případný legitimní reuse zvlášť. U uklidí
  vlastní testovací oblasti přes hotový controller; UID se při konfliktu ponechá rezervovaný.
