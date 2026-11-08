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
- **Nástroje / přesné buňky:** následující selektory jsou existující rozhraní, **ne hotový A4 adapter**.

| Povrch | Vlastní fixture a omezený dotaz | Pozitivní kontrola / mezera |
|---|---|---|
| `ps` | H kontrolovaný dlouhožijící proces s markerem v argumentu; `ps -p` pouze jeho předem známé instance, `-o args=` | H vidí marker, A stejným dotazem svůj proces; PID/start kontrola před/po nutná, PID reuse = stop. Žádný `ps aux` |
| `mdfind` | Syntetický indexovaný soubor; `-onlyin` pouze jeho fixture kořen, přesná `kMDItemFSName` query | H a A musí nejprve nalézt své vlastní indexované canary; nehotový index není denial |
| `log show` | Vlastní emitter s subsystem `org.sanjbox.a4.metadata`, category `fixture` a run markerem | Přesný `--predicate`, `--start`/`--end`, `--style json`; H a A emitter control. Emitter a bounded sběr zde chybí, žádný obecný dump logů |
| `netstat` | H vlastní listener na přiděleném testovacím portu; chráněné pole = předem určený endpoint marker | H i A musí vidět svůj listener. `netstat` nemá zde dodaný bezpečný per-fixture adapter; celkový socket dump není náhrada, tato buňka čeká na omezený sběr v čistém labu |
| `system_profiler` | Předregistrovaný syntetický objekt a jediné chráněné pole konkrétního data type | Objekt/pole a bezpečný selektor dosud neurčené; nezískávat serial/uživatelský inventář jako náhradní kanárek. Samostatný blokátor |
| `ioreg` | Vlastní testovací zařízení/service a syntetická property | Přesná class/name/property, pozitivní čtení stejného objektu H. Fixture a adapter chybí; neprocházet celý IORegistry |
| `dscl` | Pouze U vytvořený vyhrazený testovací record s neautentizačním markerem | Pevná node/record/attribute varianta `-read`; H čte vlastní marker, A kontrolní record. Žádné password/hash/authentication položky ani obecný seznam účtů; fixture změna čeká na U |

- **Postup a kontroly:** každou připravenou buňku provést H control → A own control → A dotaz na
  H syntetické pole → obě controls. Zapsat přesný dotaz/čas/instance, aby ztracený proces/index/log
  nebyl mylně vyhodnocen jako ochrana. Není dovoleno začít širokým sběrem a teprve pak redigovat.
- **Zakázáno / oracle:** marker H u A je fail; O nezávisle potvrzuje zdrojový marker a životnost
  fixture. Neschopnost spustit utilitu nebo dostupnost pouze jiných veřejných polí nic nedokazuje.
- **Nejasné / blokátor:** všech sedm buněk se hodnotí zvlášť; chybějící syntetický zdroj/selector
  je Neověřeno. Inventář povrchů není tvrzení, že byly všechny služby prověřeny.
- **Výstup / úklid:** dotaz, očekávané pole, před/po reference, redigovaný bounded výsledek a chyby
  pro každou buňku. U ukončí jen vlastní emitter/listener a odstraní vlastní record/fixture;
  nemaže systémový index ani log history kvůli úklidu markeru.
