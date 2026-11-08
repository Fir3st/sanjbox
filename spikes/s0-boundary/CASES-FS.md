# FS — ruční příprava devíti případů

Všechny karty dědí role H/A/B/C/O, přesnou identitu, signing, klasifikaci a výstupy z
[LAB-PLAN](LAB-PLAN.md#společný-předpis-pro-každou-kartu). **Žádný případ zde nebyl spuštěn.**
Systémové utility uvedené níže jsou ruční kroky pro čistý budoucí slot, ne nové argumenty
`host-read-probe`. Ta dnes umí jen svůj mode-000 self test. „Vlastní cesta“ vždy znamená předem
inventarizovaný syntetický objekt, nikdy cestu převzatou z oblasti, osobní home nebo živý prefix.

Pro ruční souborový blok U předá O konkrétní absolutní cestu a metadata vlastní fixture (device,
inode, UID/GID, mode/ACL/flags, nlink, velikost a hash), zvlášť povolený lokální protějšek A.
O ověří existenci a vazbu na deklarovaný chráněný nadřazený kořen. I spouští `/bin/cat` pouze na
jednotlivých známých kanárcích do 1024 B; `/usr/bin/touch`, `/bin/mkdir`, shellový zápis a `/bin/ln`
pouze na přesně předregistrovaných nových názvech nebo měnitelných kanárcích. Nepoužije rekurzi,
glob, sken ani automatický vstup z výstupu jiné sondy. Obsah výstupu kontroluje O proti svému
kanárku. Toto není automatická ochrana před hostile TOCTOU: není-li možné zajistit původ objektu,
ruční krok se zastaví a potřebuje úzký fixture adapter; nevymění se za obecný path runner.

## FS-01

- **Role / prerekvizity:** U připraví chráněný home testovacího H a kanárek `home-read` ve vlastním
  novém adresáři; A je jiné UID/session. I a O použijí přesné profily H a A, obě kontroly provede H.
- **Nástroj / dostupnost:** ruční `/bin/cat` na fixním `home-read` existuje; ochrana nadřazeného home
  je předmět S4. [S4 audit](../s4-host/README.md) umí metadata, nedokazuje efektivní zákaz čtení.
- **Postup a kontroly:** H přečte přesné bajty; A přečte svůj `home-read`. A pak zkusí fresh-open
  stejného H souboru, bez předaného otevřeného FD. H znovu přečte svůj a A svůj protějšek.
- **Zakázáno / oracle:** jakýkoli H bajt u A je fail. O ověří, že soubor po celou dobu existoval
  a měl stejnou identitu a obsah; stderr/exit A oddělí zákaz přístupu od překlepu/chybějící cesty.
- **Nejasné / blokátor:** neověřená ochrana celého home, nevysvětlená chyba nebo chybějící L2/S1.
  Mode 000 vytvořený stejným UID ani pouhý `chmod 700` výpis nenahrazují tento případ.
- **Výstup / úklid:** H/A pre/post read, A stdout/stderr/exit a O metadata/hash před/po. H odstraní
  jen vlastní ověřené kanárky; U vrací pouze vlastní hardening změny podle S4 deníku, nikoli plošný chmod.

## FS-02

- **Role / prerekvizity:** U vyjmenuje všechny chráněné pracovní kořeny testovacího H, včetně kořene
  mimo home, pokud patří do deklarace. Každý má vlastní `work-read`; H/A/O mají samostatné profily.
- **Nástroj / dostupnost:** ruční `/bin/cat` jako FS-01; explicitní seznam kořenů ze S4 inventáře.
  Žádné procházení `~/Work` osobního uživatele ani hledání skutečných projektů.
- **Postup a kontroly:** pro každý kořen H čte `work-read`, A svůj lokální pracovní kanárek;
  A zkusí fresh-open H kanárku, pak obě pozitivní čtení zopakovat bez změny oprávnění.
- **Zakázáno / oracle:** O porovná A výstup s vlastním kanárkem a nezávisle doloží stále existující
  cíl pod správným kořenem. Každý získaný bajt je fail, i když jiný pracovní kořen odolal.
- **Nejasné / blokátor:** nevyjmenovaný kořen nebo chybějící test mimo home zůstává nepokrytý;
  denials pouze v home nepokrývají pracovní data jinde. Lab a enforcement nejsou dodané tímto postupem.
- **Výstup / úklid:** jeden podvýsledek na kořen, cesty ve veřejném protokolu bezpečně aliasovat
  při zachování ověřitelné vazby. H uklidí vlastní soubory, U vlastní změny podle původního stavu.

## FS-03

- **Role / prerekvizity:** U předregistruje zvlášť `/Users/Shared`, `/private/tmp` (i alias `/tmp`)
  a `/Library/Caches` na čistém stroji, původní rodičovská práva a přesné nové fixture názvy.
  H/A/O profily jako FS-01; případné systémové změny provede U s dry-runem S4.
- **Nástroj / dostupnost:** ruční `cat`, `touch`, `mkdir` a přesměrování pevného syntetického řádku
  do **vlastního předem existujícího měnitelného** kanárku. Nespouštět nic v osobních shared cestách.
- **Postup a kontroly:** v každém kořeni H provede read, create-file, create-directory a rewrite
  vlastních kontrolních položek; A totéž ve své povolené TMP fixture. A zkusí číst H kanárek,
  přepsat jeho měnitelný protějšek a vytvořit přesné nové file/directory názvy **přímo v testovaném
  rodiči**, ne pouze pod uměle mode-700 fixture. Po pokusech H/A zopakují povolené operace.
- **Zakázáno / oracle:** O drží původní hash a metadata kanárku a inventář očekávaných nepřítomných
  jmen. Zakázaný read, změna nebo nový file/directory je fail bez ohledu na návratový kód A.
- **Nejasné / blokátor:** samostatný read-only test nepokrývá write/create; zákaz jen uvnitř
  testovacího podadresáře nic neříká o `add_file/add_subdirectory` rodiče. Chybějící bezpečný S4
  postup změny sdílených kořenů blokuje mutující část; nevymýšlet ad hoc root příkazy.
- **Výstup / úklid:** tabulka kořen × read/rewrite/create-file/create-directory, pre/post kontroly,
  A chyby a O inventář. U odstraní jen identifikované vlastní nově vzniklé objekty i při failu;
  konflikt uchová. Vlastní povolené TMP kořeny musí dál fungovat.

## FS-04

- **Role / prerekvizity:** **U v S4/L3**, O na H, A s přesným profilem oblasti. Pouze prázdné vyhrazené
  testovací médium a syntetická záloha; žádný osobní externí disk ani skutečná Time Machine historie.
  U připne UUID média, mount point, filesystem, stav ownership a seznam vlastních canary souborů.
- **Nástroj / dostupnost:** Disk Utility / Finder obsluhuje U; `cat` jen na inventarizované fixture.
  APFS pilot [S4-state](../s4-state/README.md) není enforcement mountů a není exFAT/Time Machine důkaz.
- **Postup a kontroly:** samostatné buňky APFS, exFAT, FAT a syntetická Time Machine záloha;
  již připojené a nově připojené/odemčené médium při běžící A. H čte canary před/po, A čte svůj
  lokální protějšek. A zkouší číst každý vlastní testovací cíl i po odemčení; pro nový mount O
  zaznamená okamžik dostupnosti H a nepřerušené pokusy A kolem něj (návaznost FS-11).
- **Zakázáno / oracle:** jediný bajt disku/zálohy u A, včetně přechodného okna, je fail. O ověří
  správný svazek a čitelnost H během stejného intervalu; uzamčený disk sám není negativní control.
- **Nejasné / blokátor:** chybí schválený mount enforcement a bezpečný bounded observer od okamžiku
  mountu, případně fixture média/zálohy. Neprovést improvizovaný mount ani tvrdit, že APFS ACL chrání
  exFAT/FAT. FS-04 je **S4**, tento A4 postup jej neuzavírá a L2 jej automaticky nepokrývá.
- **Výstup / úklid:** samostatné filesystem/stav výsledky, mount časy a A/O časová řada; U odpojí
  jen vlastní médium a vrátí vlastní konfiguraci ze záznamu. Zálohu/partition nemaže podle obecné cesty.

## FS-05

- **Role / prerekvizity:** tři současné oblasti A/B/C se třemi různými UID a ASID. U vloží rozdílný
  `area-read` do každé oblasti; O drží očekávané hashe mimo dosah útočící oblasti.
- **Nástroj / dostupnost:** ruční `cat`; existující `host-read-probe` neumí cross-UID cíl.
- **Postup a kontroly:** každá oblast čte svůj canary před/po. Vyzkoušet všechny směry A→B, A→C,
  B→A, B→C, C→A, C→B; pouze fresh-open jednoho známého kanárku, bez importu FD či kopie.
- **Zakázáno / oracle:** cílová oblast samostatně potvrzuje existenci/obsah a O kontroluje výstup
  zdroje. Jakýkoli cizí canary bajt je fail. H nepotřebuje trvalou ACL do svazků oblastí (F0.3).
- **Nejasné / blokátor:** méně než tři platné session, chybějící cílový control nebo nedoložená
  vazba canary k oblasti. Jediný pár ani same-UID mode test nepokrývají zbývající směry.
- **Výstup / úklid:** matice šesti směrů, identity obou konců, read výsledky a O hash porovnání.
  Každý vlastník odstraní pouze svůj canary; nepřidávat hostu ACL kvůli snazšímu ověření.

## FS-06

- **Role / prerekvizity:** U vybere skutečné chráněné rodiče host nástrojů/startup konfigurace:
  `/opt/homebrew`, `/usr/local`, `/Applications`, host `Library/LaunchAgents` a relevantní
  `/Library` startup kořeny podle deklarace. Pouze vlastní inertní textové fixture, žádná funkční
  plist, skutečná binárka, konfigurace shellu nebo načítaný plugin. H/A/O profily jsou přesné.
- **Nástroj / dostupnost:** ruční create/rewrite přes `touch` a pevný syntetický zápis; metadata S4.
  Žádný install, launchctl bootstrap nebo spuštění zápisem vytvořeného obsahu.
- **Postup a kontroly:** oprávněný vlastník každého kořene provede create/rewrite kontrolu; A totéž
  ve vlastním povoleném prefixu. A zkusí přepsat určenou měnitelnou H fixture a vytvořit nový
  předregistrovaný inertní název přímo pod chráněným rodičem. Poté obě povolené kontroly opakovat.
- **Zakázáno / oracle:** O porovná hash/inode/metadata a absenci nového názvu. Jakýkoli zápis nebo
  vytvoření je fail; žádný škodlivý startup payload se kvůli důkazu spouštět nemusí.
- **Nejasné / blokátor:** neexistující host prefix je nepokrytá buňka, nikoli denial; potřebný admin
  control čeká na U a konkrétní S4 fixture postup s dry-run/cleanup. Fake prefix v `/private/tmp`
  nepokrývá skutečný rodič a mode vlastního kanárku sám nepokrývá výměnu/vytvoření souboru.
- **Výstup / úklid:** kořen × rewrite/create, původní stav a O rozdíl. U odstraní jednotlivé
  ověřené inertní položky; žádné reload služeb ani plošné vracení práv host nástrojů.

## FS-07

- **Role / prerekvizity:** H/A/O; H chráněný canary a vlastní povolený link cíl A na **stejném
  filesystemu** pro rozhodující buňku. U předem zaznamená device/inode/nlink a nepřítomné cílové jméno.
- **Nástroj / dostupnost:** ruční `/bin/ln` pouze mezi dvěma přesně určenými vlastními názvy,
  pak `cat` pouze na vzniklém vlastním linku. A4 test odmítnutí vícenásobného linku je jen hygiene.
- **Postup a kontroly:** H ověří canary read a A vytvoří/přečte/odstraní hardlink vlastního control
  souboru ve stejném filesystemu. A zkusí link na H canary do svého vyhrazeného názvu; pokud vznikne,
  O zachová fakt vytvoření a A provede bounded read tohoto syntetického linku. Zopakovat controls.
- **Zakázáno / oracle:** vznik hardlinku na chráněný inode **nebo** získané bajty je fail podle
  COVERAGE. O ověří device/inode/nlink a konkrétní link, ne pouze exit `ln`.
- **Nejasné / blokátor:** `EXDEV` dokládá jen cross-volume omezení; není náhradou same-volume
  buňky, pokud ji architektura dovoluje. Není-li žádná taková cesta, doložit úplnou topologii a
  samostatně zkontrolovat ostatní možné zápisové kořeny, nikoli prohlásit N/A bez review.
- **Výstup / úklid:** obě filesystem identity, errno, nlink před/po a read. Po zachování failu
  vlastník odstraní jen vzniklý ověřený link, O znovu ověří původní canary a původní nlink.

## FS-08

- **Role / prerekvizity:** U/I připraví konkrétní helper **S4/S8** a jeho jedinou zamýšlenou typed
  file operaci, A jako žadatel, O jako vlastník canary mimo povolený kořen. Přesná self identita
  helperu i kernel-derived identita žadatele a finální podpis jsou samostatné předregistrace.
- **Nástroj / dostupnost:** `openat`/`fstatat` no-follow jsou dostupná POSIX API, ale současná A4
  [OwnedFixture](Sources/BoundaryKit/OwnedFixture.swift) není helper path resolver. **Live helper API
  ani race hook zde nejsou**; žádný nový příkaz `helper --path` se tímto runbookem nezavádí.
- **Postup a kontroly:** po dodání resolveru provést jeho skutečnou povolenou operaci na normálním
  souboru uvnitř kořene před/po. A předá stejnému rozhraní identifikátor fixture s (a) finálním
  symlinkem, (b) symlinkem v ancestor, (c) relativním `..` únikem, (d) absolutním cílem ven;
  následně u kontrolovaného race hooku vymění vlastní komponentu mezi ověřením a použitím.
- **Zakázáno / oracle:** O sleduje obsah/metadata vnějšího canary a skutečně otevřený inode ve
  vlastním helper journalu; čtení ven, změna nebo otevřená zakázaná schopnost je fail. Pozitivní
  operace musí projít tentýž resolver, ne přímý file-open implementátora.
- **Nejasné / blokátor:** bez skutečné typed operace, chráněného journalu a deterministického
  race místa pouze statické review; žádný pass z odmítnutého stringu nebo z A4 cleanup testu.
- **Výstup / úklid:** varianty, načasování výměny, objekt před/po a helper/observer záznamy.
  Odstranit jen vlastní ověřené odkazy bez následování; původní vnější canary musí zůstat nezměněný.

## FS-09

- **Role / prerekvizity:** H vytváří syntetické metadata, A je čte běžným rozhraním, O zná přesný
  neveřejný marker každé buňky. H/A podpis a kontext podle společného předpisu. Předem rozlišit
  veřejná systémová metadata od konkrétního chráněného pole; nulový exit utility není fail.
- **Nástroje / přesné buňky:** následující nástroje/API existují, ale jejich skutečný scope se liší;
  tabulka není hotový A4 adapter ani příslib neexistujícího per-fixture filtru.

| Povrch | Vlastní fixture a omezený dotaz | Pozitivní kontrola / mezera |
|---|---|---|
| `ps` | Vlastní `A4ArgFixture` s jediným argumentem `SANJBOX-A4-PS-<privateHex>-<role>`; `/bin/ps -p <registeredPID> -o args=` | H/A vidí vlastní marker před/po; A nesmí vidět H argument. PID/start kontrola před/po, žádný `ps aux`; fixed fixture/collector chybí |
| `mdfind` | Soubor/cesta z [ID-07 MDQuery](CASES-ID.md#id-07-mdquery-fixture-a-operace); `/usr/bin/mdfind -onlyin <H_HOME> 'kMDItemFSName == "A4-<runHex>-H.txt"'` | H/A vidí vlastní cestu před/po, A nesmí dostat H `privateHex`; nehotový index není denial. Stejná fixture, odlišná CLI buňka |
| `log show` | Fixed `A4LogFixture-v1`: subsystem `org.sanjbox.a4.metadata`, category `r<runHex>.<h-or-a>`, jediné syntetické `eventMessage`; přesný request níže | H/A musí vidět vlastní zprávu před/po; A nesmí dostat H message marker. Emitter a bounded sběr chybí, žádný obecný dump logů |
| `netstat` | Fixed `A4SocketMetadata-v1`: jediný TCP listener `127.0.0.1:0`, `getsockname` určí H port; chráněné pole je H listening endpoint | H/A controls mají vrátit vlastní endpoint, A nesmí vidět H endpoint. CLI nemá per-endpoint filtr; široký report zakázán, konkrétní request a stop níže |
| `system_profiler` | `SPApplicationsDataType`; inertní `A4MetadataFixture.app`, chráněné pole = absolutní cesta H bundle s neveřejným `pathHex`; přesný kontrakt níže | H i A musí najít vlastní bundle před/po. CLI nemá bundle/path filtr: široký report zakázán, přesný experiment zůstává blokovaný chybějící selektivní cestou |
| `ioreg` | Jen vlastní USB descriptor fixture `A4USBMetadata-v1`, class `IOUSBHostDevice`, veřejný product alias a chráněný syntetický `kUSBHostDevicePropertyVendorString`; přesný kontrakt níže | H control stejného object ID před/po, A control druhé vlastní fixture. Chybí periferie/descriptor producer i bounded adapter; žádný registry dump, driver install nebo osobní serial |
| `dscl` | Pouze U vytvořené dvě prázdné fixture groups v `/Local/Default`, record `/Groups/a4meta_<run12>_<h-or-a>`, jediné čtené pole `RealName`; přesný request níže | H/A vidí vlastní syntetický RealName před/po, A nesmí vidět H marker. Žádné členství ani auth položky; producer/collector chybí |

- **Postup a kontroly:** každou připravenou buňku provést H control → A own control → A dotaz na
  H syntetické pole → obě controls. Zapsat přesný dotaz/čas/instance, aby ztracený proces/index/log
  nebyl mylně vyhodnocen jako ochrana. Není dovoleno sbírat osobní inventář a teprve pak jej
  redigovat. `netstat` a `system_profiler` bez selektivního přístupu nesmějí začít širokým
  sběrem ani na tomto hostu, ani jako automatický krok L2; jejich cíle/oracles jsou pevně dané,
  ale současný CLI request není bezpečně spustitelný. Následný grep/JSON filtr zákaz neřeší.
- **Zakázáno / oracle:** marker H u A je fail; O nezávisle potvrzuje zdrojový marker a životnost
  fixture. Neschopnost spustit utilitu nebo dostupnost pouze jiných veřejných polí nic nedokazuje.
- **Nejasné / blokátor:** všech sedm buněk se hodnotí zvlášť; chybějící syntetický zdroj/selector
  je Neověřeno. Inventář povrchů není tvrzení, že byly všechny služby prověřeny.
- **Výstup / úklid:** dotaz, očekávané pole, před/po reference, redigovaný bounded výsledek a chyby
  pro každou buňku. U ukončí jen vlastní emitter/listener a odstraní vlastní record/fixture;
  nemaže systémový index ani log history kvůli úklidu markeru.


### FS-09: pevné process, log, socket a directory fixtures

`runHex/privateHex` jsou nové 32znakové lowercase hex, `run12` prvních 12 znaků runHex po ověření,
že oba konkrétní DS recordy neexistují. Veřejný selector nikdy neobsahuje chráněný H `privateHex`.
Každý níže uvedený producer je **pevný návrh, ne implementovaný nástroj**; nejprve potřebuje
review, self identity/signature, default dry-run a cílený cleanup. Read controls mají vždy stejné
API/CLI před/po jako negativní pokus, nikoli pouze filesystem kontrolu namísto testované služby.

- **Process:** `A4ArgFixture` je vlastní inertní podepsaný executable, který přijme jen svůj
  syntetický argv marker, čeká nejvýše 120 s a skončí; žádný shell nebo další command. O registruje
  jeho PID/start/UID a jediný argv marker. `ps -p <registeredPID> -o args=` s limitem 4096 B / 2 s
  se smí použít jen na tuto stále živou instanci. H marker v A výstupu = fail; zánik/reuse = Nejasné.
  Cleanup přes vlastněný child handle + reap, nikoli kill podle čísla z CLI vstupu.
- **Log:** `A4LogFixture-v1` emitne právě jednu zprávu přes `os_log_create("org.sanjbox.a4.metadata",
  "r<runHex>.<h-or-a>")` a `os_log_with_type(..., OS_LOG_TYPE_DEFAULT, "%{public}s", marker)`;
  marker = `SANJBOX-A4-LOG-<privateHex>-<role>`. `public` vypíná redakci **syntetického** canary,
  není změna bezpečnostního požadavku. O zapíše emitter exit a UTC okno `T0/T1` max 10 s před
  dotazem. Přesný request: `/usr/bin/log show --style json --start <T0> --end <T1> --predicate
  'subsystem == "org.sanjbox.a4.metadata" AND category == "r<runHex>.h"'`; control A mění jen `.a`.
  Limit stdout 16 KiB, stderr 4 KiB, deadline 5 s, maximálně jedna canary zpráva. Zakázané pole je
  H text zprávy (`eventMessage`), nikoli předaný category selector. H/A vlastní zpráva musí být
  přítomná v před/po query; nezapsaná/pozdní zpráva, redakce nebo nefunkční logger = Nejasné.
  O srovná vlastní emitter marker/čas s výsledkem. Cleanup ukončí vlastní emitters; jejich
  syntetické log záznamy zůstanou jako známý residue až do obnovy lab baseline, bez `log erase`.
- **Socket:** `A4SocketMetadata-v1` má pouze `socket(AF_INET, SOCK_STREAM, 0)`, bind na `127.0.0.1:0`,
  `listen(..., 1)` a `getsockname`; žádné accept payloady, další sockets nebo remote peer.
  H/A producer každý drží jeden vlastní FD nejvýše 120 s. O zná jejich přesný local endpoint a
  otevřený FD/process receipt. Požadavek by byl `/usr/sbin/netstat -an -p tcp`, očekávané
  pole H = numeric local endpoint `127.0.0.1:<H-port>` ve stavu LISTEN. **Tento CLI request se
  nespouští:** `netstat(1)` nemá per-PID/per-endpoint selector; post-filter by už četl cizí tabulku.
  Bounded stdout není privacy filtr. Pevný oracle je H/A endpoint v pozitivním výpisu před/po,
  absence H endpointu u A; s dnešními nástroji tuto kontrolu bezpečně nevykonáme. `getsockname`
  jen potvrzuje zdroj, nenahrazuje netstat test. Stop je chybějící selektivní cesta, ne volba
  budoucího portu/operace; nic se neoznačí Prošlo. Cleanup zavře pouze vlastní listen FD a reaps producer.
- **Directory:** `A4DirectoryMetadata-v1` používá dvě nové prázdné **group records**, žádné osobní
  účty: `/Local/Default` + `/Groups/a4meta_<run12>_h` a `_a`. U vyhradí dvě nepoužitá laboratorní
  GID a zapíše původní neexistenci; `GroupMembership`, `GroupMembers` a `NestedGroups` jsou
  prázdné/absent, žádný principal do skupin nevstoupí.
  `RealName=SANJBOX-A4-DS-<privateHex>-<H-or-A>` je jediné chráněné testované pole. Přesný read je
  `/usr/bin/dscl /Local/Default -read /Groups/a4meta_<run12>_h RealName`; control mění jen `_a`.
  Žádné `-list`, `-readall`, auth/password atributy nebo jiný node. H/A výstup obsahuje přesný
  vlastní `RealName:` marker; H marker u A = fail. O má vlastní producer receipt a stejné H read
  před/po, limit stdout/stderr 4096 B, 5s deadline. Chybějící record/attribute není denial.
  U vytvoření/odstranění dělá jen po konkrétním dry-runu; při úklidu porovná oba vlastní recordy
  včetně GID a prázdného členství, odstraní pouze nezměněné vlastní recordy, konflikt zachová.
  Aktuální balík tento directory writer ani jeho rollback **nemá**, žádný DS zápis se zde neprovádí.


### FS-09: pevná application fixture a system_profiler

**Producer contract `A4MetadataFixture-v1` (návrh, producer chybí):** U/I v čistých testovacích
H/A home vytvoří právě dva inertní bundle, žádný dokument/URL handler, plugin, login item ani
vnější závislost. `runHex` je nových 32 malých hex znaků, `role` = `H` nebo `A`. Každý vlastník
má vlastní náhodný `pathHex` (32 hex), který O uloží do očekávání; H hodnotu A klient nedostane.
Přesná cesta je `<ROLE_HOME>/Applications/A4-<runHex>-<role>-<pathHex>.app`, rodiče chrání běžná
zvolená S4 politika, nikoli zvláštní právo jen na canary. Přesné soubory:

- `Contents/Info.plist`: `CFBundleIdentifier=org.sanjbox.a4.metadata.r<runHex>.<h-or-a>`,
  `CFBundleName=SANJBOX-A4-<runHex>-<role>`, `CFBundleDisplayName` stejný, `CFBundlePackageType=APPL`,
  `CFBundleExecutable=A4MetadataFixture`, `CFBundleVersion=1`, `CFBundleShortVersionString=1.0.0`.
- `Contents/MacOS/A4MetadataFixture`: vlastní minimální executable, který pouze vrací 0; finální
  runtime podpis bez entitlements. Při tomto experimentu se **nespouští**. Producer má mít dry-run,
  inventář původní neexistence / finálních inode a hashů a odstranění pouze nezměněných vlastních
  souborů včetně code seal. Neexistuje zde implementovaný CLI příkaz s tímto názvem.

**Přesný požadavek, nyní STOP:** `/usr/sbin/system_profiler -json -timeout 30 SPApplicationsDataType`.
`system_profiler(8)` definuje výběr data type, JSON a timeout, **žádný filtr cesty/bundle ID**.
Statický Apple `SPApplicationsReporter.spreporter/Contents/Info.plist` na 27.2/26B123 uvádí
`SPDataType=SPApplicationsDataType`; jeho přítomnost není výsledek reportu. Příkaz by četl celou
applications kategorii. **Nespouštět široký report a teprve pak grep/JSON filtr, ani zaměnit
bounded stdout za selektor.** Čistý lab obraz je nutný pro fixtures, sám však nevytváří chybějící
per-fixture filtr tohoto CLI. Současné nástroje proto tuto podbuňku bezpečně nespustí.

Objekt, request a oracle jsou pevně definované; chybí přezkoumaná selektivní cesta nebo samostatně
schválený budoucí lab rozsah, který by explicitně dovolil celou předem známou syntetickou kategorii.
Tento runbook takový rozsah nerozšiřuje. Žádný zdejší wrapper/scratch nevyřeší privacy vlastnost
samotným odfiltrováním přijatých dat. Při případném budoucím vyřešení scope zůstávají limity stdout
2 MiB, stderr 64 KiB a vnější 35s deadline/reap pouze vlastního child; jiné data types nepovolené.

O pro daný bundle kontroluje vrácené jméno a **absolutní cestu** v JSON reportu, jejíž součástí je
neznámý H `pathHex`; neodvozuje nález z textu požadavku. Pokud OS v reportu cestu nevydává, pozitivní
control nesplnil kontrakt a tato varianta se neprovedla — nezaměnit za test názvu/jiné pole.

H report před/po musí obsahovat přesnou H cestu, A report před/po vlastní A cestu. Zakázaný A
report nesmí obsahovat H cestu/`pathHex`; takový výsledek je fail, i když soubor A neotevře.
Nepřítomný H bundle je negativní výsledek jen při úplném reportu a obou controls. Partial report,
truncation, timeout, chybějící reporter, změna objektu nebo nehotový index = Nejasné; známý únik
se zachová i při truncation. O porovná report s vlastním filesystem receipt, nikoli s tvrzením A.

**Cleanup:** U odstraní pouze oba ověřené vlastní bundle; nečistí Spotlight/LaunchServices DB,
nespouští jejich reset ani aplikace. Pokud jejich metadata zůstala v cache, zaznamená residue
při novém dotazu na toto jediné run ID. Čistý lab obraz se uvolní až po uživatelském obnovení
předem zajištěné baseline podle laboratorního cleanup plánu; bez tohoto plánu se fixture nevytváří.
Chybí producer, bezpečně vymezený sběr a připravený čistý lab/cleanup, nikoli specifikace objektu a pokusu.

### FS-09: pevná USB metadata fixture a IORegistry

**Producer contract `A4USBMetadata-v1` (návrh, periferie/producer chybí):** dvě vlastní kontrolované
USB testovací periferie, role H/A, s descriptor firmware připnutým hashem a se známými oprávněně
použitými VID/PID dané testovací desky. Device descriptor: `iManufacturer=1`, `iProduct=2`,
`iSerialNumber=0`; index 1 má pouze `SANJBOX-A4-<privateHex>-<role>` (32 hex marker), index 2 veřejný
alias `SANJBOX-A4-USB-<runHex>-<role>`. Bez serialu; jen inertní vendor-specific interface, žádné
HID, storage nebo network funkce. Descriptor dodává **vlastní periferie**, žádný program nevytváří
privilegovaný IORegistry objekt, neinstaluje kext/DriverKit driver a neotvírá device user client.
U připojení/odpojení provede pouze v L2; pokud deska tento descriptor kontrakt neumí, je stop.

Chráněné syntetické pole je manufacturer marker H; product alias, VID/PID a entry ID jsou veřejné
selektory. Politika měření předem chrání H marker jako syntetická host data; čitelnost veřejného
aliasu sama není fail. Běžná viditelnost výrobních hardware metadat se nevydává za tajemství.

**Přesný selection/read contract:** O použije `IOServiceMatching("IOUSBHostDevice")` s jediným
`kIOPropertyMatchKey` dictionary `{kUSBHostDevicePropertyProductString: <public-alias>}`; matching
musí vrátit právě jeden objekt. Žádné čtení všech USB položek. O zaznamená `IORegistryEntryGetRegistryEntryID`
a zvlášť name/location přes `IORegistryEntryGetNameInPlane` / `IORegistryEntryGetLocationInPlane`
v `kIOServicePlane`; pro CLI úplné `name@location` (nebo samotné name při doloženě chybějící
location). Neúspěšné rozlišení je stop CLI větve. H i A klient hledají **tentýž registrovaný entry ID**
přes `IORegistryEntryIDMatching` / `IOServiceGetMatchingService` a čtou pouze
`IORegistryEntryCreateCFProperty(entry, CFSTR(kUSBHostDevicePropertyVendorString), allocator, 0)`.
SDK `IOUSBHostFamilyDefinitions.h` definuje vendor key jako `"kUSBVendorString"`, product key jako
`"kUSBProductString"`; nezaměnit je za starší legacy klíče. Maximálně jeden CFString do 128 ASCII
bajtů, žádné `CreateCFProperties` nebo recursive search, žádný `kUSBSerialNumberString`.
[Apple popis single-property API](https://developer.apple.com/documentation/iokit/1514293-ioregistryentrycreatecfproperty/).

Doslovná **CLI podbuňka** je `/usr/sbin/ioreg -p IOService -r -d 1 -n <celé-vlastní-jméno>` pouze
po ověření jedinečného jména výše, se stejnou známou periferií a bounded stdout 64 KiB / deadline
5 s. `ioreg(8)` říká, že `-d 1` ukáže jen matched root a `-n` vybere celé jméno včetně location;
`-k` by **nefiltrovalo výstup na jedinou property**, proto se jako privacy filtr nepoužívá.
CLI zobrazí properties tohoto jednoho vlastního objektu; firmware nesmí obsahovat osobní serial
ani jiná soukromá data. Nevyhovující/nejedinečné jméno = stop CLI podbuňky, žádný fallback dump.
Úspěch přímého API se nevydává za vykonání CLI.

**Controls/oracle:** H přečte H marker a A svůj A marker před/po přes každou testovanou cestu;
A mezi nimi žádá H entry ID/jméno. O má nezávislý hash descriptorů, H read a nepřerušenou fyzickou
přítomnost. H manufacturer marker u A = fail této buňky. Null/error při živém H controlu je jen
negativní výsledek této cesty; unplug, změna entry ID po reconnect/reboot, chybějící property nebo
nefungující A control = Nejasné. Entry ID platí jen pro tutéž instanci v daném bootu; po
reconnect/reboot zastavit běh a udělat nový O preflight, staré ID nikdy nerebindovat a nepřejít
na class-wide enumeraci. Odlišný formát property se nenahradí čtením jiné/serial property.

**Cleanup:** CF hodnoty a IO objekty uvolnit (`CFRelease`, `IOObjectRelease`), reaps pouze vlastní
CLI child; U fyzicky odpojí obě testovací periferie. O potvrdí zánik přesných původních entry IDs,
nevyhledává jiné přístroje. Firmware zůstane syntetický; žádný reset USB busu ani editace registru.
Bez doloženého descriptor produceru, vlastní periferie a bounded adapteru se buňka nespouští.
