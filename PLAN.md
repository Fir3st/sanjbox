# Ohrádka — nativní izolované oblasti pro AI agenty na macOS (bez desktopové VM)

## Context

Uživatel chce X izolovaných, zabezpečených prostředí, ve kterých může s libovolnými agenty a nástroji
(OpenCode CLI, Claude Code, Codex, Cursor, Xcode, Android Studio, npm/pip/brew, Docker…) volně „blbnout“,
aniž by agent nebo škodlivý balíček vyleakoval cokoli z Macu. Hotové řešení neexistuje. Slepence nástrojů a VM
uživatel odmítl. Předchozí verze uváděla review tří nezávislých agentů a ověření na tomto Macu;
bez přiložených protokolů nejsou tato historická tvrzení důkazem splnění požadavků.

**Revize 2026-11-01, po druhém review:** nepřekročitelné bezpečnostní brány, průběžná ochrana souborů,
životní cyklus celého UID, síťové failure modes, rozsah přihlašovacích oprávnění, kontrola artefaktů,
úplný rozsah rollbacku a validní měření tří souběžných oblastí. Toto je návrh k ověření, ne ověřená izolace.

### Požadavky
- R1 X oblastí; uvnitř libovolní agenti (CLI i GUI), package managery, Xcode / Simulator, Android Studio, Docker.
- R2 Oblast nesmí číst ani měnit tvoje soubory, klíče, Klíčenku, schránku ani jiné oblasti; nesmí přežít mimo sebe.
  **Povinný invariant pro threat model níže, včetně nově vzniklých chráněných dat a vypnutého stavu.**
- R3 Žádný přímý únik do sítě (LAN, služby hosta, volná exfiltrace). Platí i pro projekt importovaný do oblasti;
  povolená komunikace musí mít vymezený cíl a operaci, nikoli automaticky neomezený upload na povolenou doménu.
- R4 Docker funguje, ale není únikovou cestou.
- R5 Nativní výkon, žádná desktopová VM na pozadí, žádné přepínání tvé konzole; zapnout/vypnout rychle.
- R6 Okna appek z oblastí na tvé ploše a v Docku, rozlišitelná podle oblasti (např. 3× stejná appka);
  fallback při selhání S1/S2 je změna rozsahu vyžadující tvoje rozhodnutí, ne automatické splnění R6.
- R7 Pracuješ s projektem a testuješ appku ze své plochy; soubory se do oblasti dostávají jen řízeným importem.
- R8 Agnostické vůči agentům a nástrojům; doménový allowlist je kandidát pro nepokryté protokoly, ale nesmí
  obejít R2/R3. Nepodporovaný nástroj se označí jako nepodporovaný, ne jako bezpečný passthrough.

### Threat model a hranice platnosti
- **Adversary:** kód spuštěný v oblasti (agent, balíček, GUI app) s user-level code execution pod UID oblasti.
  Ne cílený útočník s chybou jádra/globální služby, ne fyzický přístup, ne kompromitovaný hardware.
- **Cíl:** adversary nezíská chráněná data mimo oblast, nemění tvůj host a neběží po vypnutí oblasti.
  Sdílené veřejné systémové knihovny a hostem instalované nástroje jsou explicitní read-only vstupy, ne tajná data.
- **Není cíl:** odolat 0-day v jádře, hypervisoru, WindowServeru nebo globální XPC službě; zabránit sdíleným
  hardwarovým kanálům (mikrofon, kamera, GPU, audio) nebo DoS útoku na dostupnost hosta.
- R2/R3 jsou povinné **pro tento model**. Běžný user-level přístup k host datům, globální službě nebo síti
  není vyloučený 0-day. Nálezy v §Otevřené blokátory a zbytková rizika se posuzují proti těmto invariantům.

### Akceptační kontrakt a stav důkazů
- **Prošlo:** požadavek splňuje návrh i odpovídající negativní a pozitivní testy na uvedené verzi macOS.
  **Neprošlo:** existuje porušení. **Nejasné:** chybí mechanismus, platné měření nebo dostatečný důkaz.
- Zapsání selhání do reziduí nemění jeho výsledek. Výjimky z threat modelu nejsou totéž co nesplněné R2/R3.
  Ani omezená exfiltrace projektu, přístup k host localhostu nebo krátké otevření sítě nejsou automaticky přijatelné.
- **Vstup do F2:** S0, S1, S3/S3b, S4, S5, S6 a S8 musí splnit brány svého rozsahu, zejména R2/R3.
  Izolované prototypy lze dál zkoumat, ale nelze z nich sestavit ani označit bezpečné MVP s otevřeným blokátorem.
- F2 samo nedokazuje R6 ani R4: ty vyžadují F3/S2 a F4/S7. Nazvat už F2 „MVP“ lze jen po tvém rozhodnutí ve F0.
- Změna požadavku/fallbacku vyžaduje záznam původního požadavku, dopadu, nové akceptace a tvého výslovného
  rozhodnutí. Do té doby zůstává původní požadavek platný. Označení „snížené riziko“ není souhlas se změnou.

| Požadavek | Rozhodující důkaz | Aktuální stav |
|---|---|---|
| R1, R5: tři aktivní oblasti a nativní nástroje | S1/S6: tři oblasti vedle host konzole, skutečné renderování a zátěž | Neověřeno |
| R2: soubory, identita, IPC, vypnutí | S0/S4/S8: nové kanárky a mounty, celé UID, nepřevzetí grantů | Neověřeno; blokátory otevřené |
| R3: síť bez nekontrolované exfiltrace | S3/S3b/S5: měření na protistraně, failure modes, resolver a povolené operace | Neověřeno; blokátory otevřené |
| R4: Docker | S7/F4: CLI/build, host mounts, síť i published ports | Neověřeno |
| R6: jednotlivá okna a Dock | S2/F3: tři instance aplikace, menu a vstup v podporovaném rozsahu | Neověřeno |
| R7: řízený import, testování a obnova | S4/F2: import/export, úplný rozsah rollbacku a crash recovery | Neověřeno |
| R8: kompatibilita bez bezpečnostního bypassu | S5/S6: matice nástroj × protokol × policy | Neověřeno |

### Rozhodnutí uživatele (2026-10-31)
- GUI izolace: **každá oblast = vlastní neviditelná macOS relace**, jejíž okna Ohrádka zobrazuje na tvé ploše.
- **Bez placeného Apple Developer Programu** → žádná Network Extension, žádná Endpoint Security, žádné MDM PPPC.
  Vše stojí na mechanismech dostupných bez entitlementů. Lokální podpis musí dát stabilní identitu kvůli TCC,
  ale **nikdy nesmí obsahovat `get-task-allow`** — jinak je agent v oblasti injectable a jeho TCC granty jdou převzít.
  Ověřit, zda SMAppService s Personal Team funguje; self-signed identita je alternativa jen pokud projde S8.
- **Bez placeného účtu nejde centrálně před-nastavit TCC** pro mikrofon, kameru a Input Monitoring. Řeší se
  politikou, auditem grantů a varováním v UI, ne technickým zákazem.
  Toto rozhodnutí nepovoluje převzetí grantů ani čtení host vstupů; neuzavřený přístup v rozsahu R2 blokuje S0.

### Východiska a hypotézy k opětovnému ověření
Historická lokální zjištění níže vyžadují protokol; náprava v pravém sloupci je kandidát, ne důkaz účinnosti.
Agent je ověřuje jen povolenými metadaty a syntetickými kanárky, nikdy čtením skutečných tajemství.

| Východisko / historický nález | Důsledek a požadovaný důkaz |
|---|---|
| Tvůj home je `755`, `~/Work` a `~/.config` čitelné pro všechny | Zpevnění hosta: ochrana home i dalších chráněných kořenů; ověřit nová data |
| `/opt/homebrew/etc/npmrc` je `666`; v systému tisíce world-writable cest | Ochrana povolených kořenů a cílené opravy; audit pouze detekuje drift |
| Mimo home zůstávají world-readable data: konfigurace, cache, logy, externí disky, Time Machine | Ochrana nadřazených kořenů i nových dat; audit sám nestačí. Neuzavřený přístup = fail S4 |
| Omezení klientského procesu samo nedokazuje omezení operace zprostředkované jinou službou | Oddělené UID/relace a inventura globálních služeb v S0; běžná neoprávněná operace je blokátor, ne přijaté reziduum |
| GUI pod cizím UID ve tvé relaci = slepá ulička (Apple DTS) | Každá oblast má vlastní GUI relaci; **simultánnost, Metal a přežití bez klienta jsou gate S1** |
| pf `rdr` neumí `user`; přesměrování může selhat otevřeně | Ověřit `route-to` + `tag` + `rdr`; polling není fail-closed mechanismus |
| pf `user` je egress filtr; ingress na wildcard bindech (`0.0.0.0`) nerozliší | Ingress a port squatting jsou samostatný blokátor R2/R3 → S3b |
| DNS může jít přes mDNSResponder mimo UID oblasti | Ověřit resolver i zprostředkované kanály; únik importovaného projektu porušuje R3 |
| TCC granty nejsou nutně per-session | Input Monitoring, mikrofon, kamera a Bluetooth jsou shared hardware → S0/S8 testy a politika |
| Time Machine / externí disk obchází `chmod 700 ~` | Přístup musí být zakázaný i po novém mountu; šifrování nechrání už odemčený svazek |
| ACL na `.git/config` jde obejít (`commondir`, vnořené repo) | Host nikdy nespouští obsah projektu: git, IDE i testy běží v oblasti |
| Testování v prohlížeči hosta = JS oblasti s tvou sítí a cookies | Prohlížeč pro testy běží v relaci oblasti |
| Dřívější odhad uváděl relokaci 87,7 % bottles v brew 7 při prefixu ≤ 13 B | Kandidát je stock brew; skutečné pokrytí a krátký prefix ověřit v S6, procento není současný důkaz |
| Barevné rámečky lze podvrhnout | Schvalování jen přes menu bar + Touch ID |

## Koncept

**Kandidát oblasti = skrytý uživatel macOS + vlastní neviditelná GUI relace + APFS stav oblasti.**
Oddělené UID a relace jsou základ, nikoli důkaz úplné izolace souborů, sítě nebo životního cyklu. Nikdy se ale
nepřihlašuješ ani nepřepínáš: relace běží na pozadí a Ohrádka z ní vytahuje jednotlivá okna na tvou plochu.
Funguje to jako Parallels Coherence, jen bez desktopové VM. Všechno uvnitř je nativní proces na tvém jádře.
Sdílí se jádro, GPU a globální system XPC služby; dopad rozlišuje §Otevřené blokátory a zbytková rizika.

Co se u oddělené relace musí potvrdit v S0/S1:
- oddělené `gui/<uid>` / login a `user/<uid>` domény; user doména může žít bez GUI přihlášení.
  Per-user služby a úlohy běží jako UID oblasti, ne jako ty; **globální system LaunchDaemons zůstávají společné**;
- vlastní schránka, Klíčenka (login keychain s náhodným heslem, které spravuje Ohrádka), TCC, preference,
  Dock/Finder relace;
- Accessibility a Screen Recording appky v oblasti **podle dostupných informací** působí jen na její relaci, ne na tvoji;
  S0 to ověří. **Input Monitoring, mikrofon, kamera a Bluetooth jsou shared hardware** a musí být otestované
  a politikou omezené.

## Architektura

### 1. Identita a relace
- Helper vytvoří skrytého standardního uživatele (`IsHidden`, vyhrazený blok UID, skupina `ohradka`,
  bez `staff`/`admin`) s náhodným heslem uloženým ve tvé Klíčence.
- Neviditelná relace: přihlášení do virtuální relace pro uživatele oblasti (mechanismus, kterým Sdílení obrazovky
  otevírá relaci jiného uživatele). **Musí se ověřit, že jde o skutečně paralelní session, ne fast user switching,
  a že relace přežije odpojení klienta.** Nejrizikovější předpoklad → spike S1.
  - Pokud ne: fallback rozhodnutý před F1 — jedna aktivní oblast na konzoli, jedna VNC plocha na oblast,
    CLI-only oblast, nebo VM. Jsou to alternativy pro tvoje rozhodnutí, ne již schválené varianty.
  - Session keeper (headless RFB) je samostatná hypotéza S1; jeho účinnost, souběžnost a náklady se musí změřit.
  - Apple dokumentuje jen jednu současnou **High Performance Screen Sharing** session na Mac. Z toho
    neplyne zákaz všech standardních virtuálních relací, ale ani jejich použitelnost. S1 musí prokázat tři
    oblasti vedle host konzole bez spoléhání na tři High Performance sessions.
- **Životní cyklus platí pro celé vyhrazené UID, ne jen GUI session:**
  - Zapnout: nejdřív připravit a ověřit souborovou, IPC a síťovou ochranu, až pak povolit řízený login a spouštění.
    SSH, Screen Sharing a jiné vstupní cesty nesmějí umožnit samostatné přihlášení do vypnuté oblasti.
  - Pauza: zablokovat nové spouštění a síťové požadavky a dosáhnout stabilního quiescence všech procesů UID,
    včetně CLI, background jobů a `user/<uid>`. Jednorázový výčet PID + `SIGSTOP` není důkaz proti souběžnému
    forku ani proti novému jobu. Systémové procesy hosta se nezastavují; jejich práci pro oblast musí pokrýt S0/S3.
  - `bootout` job ukončuje, nezmrazí jeho stav; `disable` není atomický zákaz všech budoucích jobů uživatele.
    Pouhé zastavení aplikací lze pojmenovat jen „pozastavení aplikací“, ne bezpečná pauza celé oblasti.
  - Vypnout: nejdřív odvolat schopnost nového loginu/spuštění a síťová/IPC oprávnění, ukončit GUI i user domény,
    odstranit nebo zneaktivnit naplánované úlohy a ukončit všechny procesy UID včetně zastavených a odpojených.
    Stav **vypnuto** vyžaduje nula procesů UID a neúspěšné pokusy o opětovný start; odhlášení GUI samo nestačí.
  - Konkrétní mechanismus zákazu opětovného spuštění, stabilního quiescence a crash recovery je blokátor S0/S4.
    Pokud neexistuje, nelze slíbit bezpečnou pauzu/vypnutí. UID se nesmí znovu přidělit před dokončením úklidu.

### 2. Coherence bez desktopové VM (okna oblasti na tvé ploše)
- **Agent v relaci** (LaunchAgent oblasti, náš podepsaný kód):
  - zachytává okna přes ScreenCaptureKit; S2 musí ověřit samostatná proxy okna i menu a popovery.
    App-filter nad displejem dává kompozici, ne automaticky nezávislé povrchy všech oken;
  - čte strukturu menu přes Accessibility;
  - vkládá vstup (`CGEventPostToPid`).
  - Screen Recording a Accessibility mu udělíš jednou, **ale bootstrap musí jít přes Screen Sharing.app**:
    dokud Coherence nefunguje, relaci nevidíš a TCC prompt nepotvrdíš. Vlastní RFB je optimalizace, ne podmínka.
  - Podepsaný s hardened runtime a **bez `get-task-allow`**; jinak same-UID proces agenta attachne a převezme granty (S8).
- **Přenos snímků** bez kopírování: IOSurface přes **Mach port** předaný brokerem, ne přes globální IOSurface ID.
  Helper je system LaunchDaemon, broker autentizuje klienta audit tokenem, code signature a session; schéma je pevné
  a úzké (S0/S8).
- **Proxy appka na hostu**: pro každou appku z oblasti vznikne malý bundle s ikonou té appky a barevným odznakem
  oblasti. Má vlastní položku v Docku a Cmd-Tab, vlastní okna (Metal/IOSurface vrstva) a zrcadlí menu appky
  do tvého menu baru (výběr → AXPress v oblasti). 3× Cursor ze 3 oblastí = 3 ikony s různými odznaky.
  **F3 podporuje definovanou podmnožinu:** menu, popovery, základní klávesové zkratky. Secure input, systémové
  auth dialogy, notifikace, file open/save, drag & drop, tisk a audio mají samostatný design; bez něj se do
  proxy okna nespoléhat.
- **Schránka**: oddělená. Ohrádka nabízí řízený most (vložit do oblasti / převzít z oblasti), ale **nikdy
  automatickou synchronizaci**: obsah z oblasti je datová cesta do hostu, proto preview + potvrzení, karanténa
  a žádné automatické vkládání shell-like obsahu.
- **Displej** relace: virtuální, Retina, rozlišení podle tvého monitoru. **Metal musí být akcelerovaný**; pokud
  je v non-console session jen software nebo nefungují požadované aplikace, S1 neprošel.
  Samotný výčet Metal zařízení není důkaz akcelerovaného renderování ani požadované použitelnosti.

### 3. Soubory
- **Vynucená hranice:** před F2 určit chráněné kořeny hosta a ostatních oblastí, explicitní read-only vstupy
  a všechny povolené zápisové kořeny oblasti. Ochrana nadřazených adresářů musí platit i pro nově vytvořené,
  přesunuté a obnovené soubory. Seznam jednotlivých nalezených citlivých souborů tuto hranici nenahrazuje.
  Veřejně čitelná data mimo chráněné kořeny a metadata poskytovaná službami musí pokrýt S0; neznámé pokrytí = nejasné.
- **Zpevnění hosta** (průvodce při instalaci, s tvým schválením; **periodický audit je jen kontrola driftu**):
  - `chmod 700 ~`;
  - metadata povolených nadřazených kořenů, práv, ACL a mountů; přístup se ověřuje syntetickými kanárky,
    ne čtením skutečných tajemství, Klíčenek nebo databází. Zakázané soubory se neotevírají ani nemění;
  - ochrana kořenů s konfigurací, cache, logy a dalšími host daty před čtením i zápisem UID oblasti;
  - sken povolených metadat a cílené opravy world-writable cest (`/opt/homebrew`, `/Applications`, `/Library`,
    `/Users/Shared`, `/usr/local`); nové soubory nesmějí vytvářet okno přístupu do dalšího auditu;
  - **externí disky a Time Machine**: oblasti je nesmí mountovat ani číst; exFAT/FAT ignoruje ownership i ACL,
    takže je nutný jiný ověřený mechanismus. Mount policy není per-UID mount namespace. Nový i už odemčený
    svazek musí zůstat nepřístupný bez přechodného okna; šifrování chrání uzamčená data, ne odemčený mount.
    Pokud to při zachování přístupu hosta nejde zajistit, S4 neprošel; varování není náhrada ochrany;
  - ACL deny pro skupinu `ohradka` na citlivých world-connectable socketech (usbmuxd, sockety VPN klientů,
    `/tmp/.s.PGSQL*`) a na `add_file`/`add_subdirectory`/`delete_child` v `/private/tmp`, `/private/var/tmp`,
    `/Users/Shared`, `/Library/Caches` (oblasti dostanou vlastní `TMPDIR`);
  - `cron.deny` / `at.deny` zapisují **jednotlivá uživatelská jména**, ne skupinu; zohlednit přednost allow souborů.
    Samy neodstraňují dřívější úlohy a neřeší LaunchAgents ani LoginItems;
  - **uninstall/rollback zpevnění**: záznam původního i nastaveného stavu povolených práv/ACL a vlastních objektů.
    Vrátit jen vlastní změny; pozdější změny uživatele či instalátorů nepřepsat. Konflikt vyžaduje uživatelské
    řešení. Odstranění oblasti je zvlášť potvrzená destruktivní operace; nikdy ne mazání podle neověřené cesty.
- **Stav oblasti:** kandidát je vlastní APFS stavový svazek s home, projektem a prefixem; konkrétní topologii
  a krátký brew prefix musí ověřit S4/S6. APFS sdílí místo, podporuje kvótu; `nobrowse` a vypnutí Spotlightu
  jsou omezení automatického procházení, ne bezpečnostní hranice. Hardlinky mimo svazek nejdou.
  Tobě přístup přes dědičnou ACL **jen pro backup/export**, pokud tak rozhodneš ve F0; přímé otevírání projektu
  host nástroji je vědomé riziko (QuickLook, Finder, Xcode indexing). Preferovaný import/export jde přes řízenou
  bránu, ne přes trvale writable ACL.
- **Host nikdy nespouští obsah projektu**: git, IDE, build, testy i prohlížeč běží v relaci oblasti (okna máš na ploše).
  Tím zaniká celá třída zpětných kanálů (hooky, `core.fsmonitor`, ESLint config, Gradle, Run Script, `.envrc`).
  Toto je **politika, ne enforcement**: host ACL výše ji může obejít, proto se do ní nesmí sahat.
- **Rozsah snapshotu/rollbacku:** home včetně startup konfigurace a LaunchAgents, projekt, prefix, nástroje,
  zapisovatelné cache/TMP a později stav Docker runtime. Před F2 musí manifest vyjmenovat všechny zápisové kořeny;
  stav mimo ně nesmí poskytovat nepokrytou perzistenci. Hostem vlastněná ochranná politika se ze snapshotu neobnovuje.
  Pokud se obnovuje jen projekt, operace se musí jmenovat „rollback projektu“, ne „rollback oblasti“.
- **Postup obnovy, k prokázání v S4:**
  1. Dosáhnout ověřeného quiescence celého UID, pak vytvořit snapshot všech zahrnutých svazků; pokud bezpečné
     zmrazení nejde, nejdřív oblast vypnout. Samotný `SIGSTOP` vybraných PID nestačí. FS snapshot není automaticky
     aplikačně konzistentní; aplikace musí prokázat zotavení z přerušených zápisů na syntetických datech.
  2. Pro rollback oblast plně vypnout, uzavřít její fd/mappingy a připravit zapisovatelný obnovený stav z vybraného
     snapshotu ověřeným postupem APFS. Snapshot není přímo zapisovatelný strom pro záměnu.
  3. Přepnout až kompletní obnovený stav. `renamex_np(RENAME_SWAP)` lze použít jen pro vhodné položky v témže
     filesystemu, ne pro výměnu svazků nebo mezi snapshot mountem a živým svazkem. Vícesvazková obnova není
     atomická: potřebuje hostem vlastněný záznam průběhu a zotavení po pádu; při neúplné obnově oblast nespustit.
  4. Znovu ověřit ochranu, manifest a odstranění testovací perzistence, až potom povolit start. Testovat pád
     v každém kroku. Vzdálené push/upload operace, vydaná oprávnění a jiné externí účinky se rollbackem nevracejí.
- Root operace helperu používají ověřené kořeny a descriptor-relative operace s dostupnými no-follow/beneath
  omezeními, kontrolou vlastníka a hardlinků. Konkrétní API, TOCTOU odolnost a podporu verze macOS ověří S4/S8;
  samotný název flagu není důkaz bezpečné práce se stromem ovládaným oblastí.

### 4. Síť (pf podle uživatele, bez entitlementů)
- **Požadovaný invariant:** oblast komunikuje jen schválenými operacemi brány, izolovaným same-zone loopbackem
  a výslovně řízeným vstupem. Platí i při startu, změně politiky, pádu helperu/brány a obnově po sleep/VPN.
  Zprostředkovaná komunikace přes systémové služby musí být pokrytá stejně jako přímé sockety.
- **Kandidát anchoru per oblast, nikoli ověřený mechanismus:**
  - `pass out route-to lo0 … user <oblast> tag O<n>` a `rdr on lo0 … tagged O<n> -> 127.0.0.1 port P<n>`;
  - UDP jen řízenému resolveru brány; ověřit, zda systémový resolver nelze použít mimo tuto cestu.
    **ICMP pf `user` neumí přiřadit (jen TCP/UDP)**; neuzavřený datový kanál je fail R3. Globální blok má dopad
    i na host a vyžaduje tvoje rozhodnutí. PMTUD řešit na bráně; schválení výjimky není implicitní;
  - na `lo0` povolit jen spojení do brány (P<n>); same-zone loopback jen pokud bind policy skutečně oddělí
    listenery; oblast → host a oblast → oblast zakázané;
  - **ingress není vyřešený**: `user` je egress filtr a u wildcard bindů (`0.0.0.0`/`::`) pf vlastníka listeneru
    nerozliší. Host → oblast a LAN → oblast proto nejsou garantované; řeší S3b ověřením bind policy nebo jiné
    hranice. Filesystemová mount policy sama listenery neodděluje. Do vyřešení je S3b blokovaný. Stejné omezení platí pro
    „v rámci stejné oblasti“: pf neumí rozlišit, kdo na cílovém portu listenuje, takže buď zakáže i same-zone
    loopback, nebo povolí i host localhost. Bez bind policy je to binární volba.
  - IPv4 i IPv6, včetně `awdl0`/`llw0`; mDNS/AirDrop/APNs jsou samostatně testované kanály.
- **Síťová brána** (neprivilegovaný proces pod vlastním systémovým uživatelem, sandboxovaný):
  - Původní cíl zjistí přes úzkou službu helperu (`DIOCNATLOOK`); helper autentizuje klienta a je to jediná privilegovaná operace.
  - SNI a **vlastní DNS dotaz** svážou spojení s IP přeloženou bránou; nejde však o kontrolu HTTP obsahu,
    cílového účtu ani oprávnění operace. Passthrough na multi-tenant službě není automaticky bezpečný.
  - **Odmítne loopback, RFC1918, link-local, ULA, multicast, `100.64/10` a vlastní IP hosta**; IP literály bez SNI
    a ECH fail-closed. Jinak je to SSRF/DNS rebinding do hosta nebo LAN.
  - Non-TLS provoz má explicitní policy; QUIC/UDP 443 je blokované.
  - Nová doména/operace → schválení v menu baru (Jednou / Vždy / Zakázat, s Touch ID), svázané s konkrétní
    oblastí, cílem a policy. Samotný doménový souhlas nepovoluje libovolné odesílání dat; nevymezený passthrough
    nesplňuje R3 a je blokátor kompatibility R8.
- **Typované brány místo slepé důvěry**: npm, PyPI, Homebrew, git a API modelů jdou přes lokální HTTP endpointy brány.
  Oblast je dostane přes standardní proměnné a konfiguraci (`*_BASE_URL`, registry URL, `url.insteadOf`).
  Brána pak:
  - **vkládá klíče** (oblast vidí jen zástupnou hodnotu; u HTTPS jde o per-zone CA, ne o únik tvého klíče)
    a omezuje metody, cesty, rate a budget;
    pokud SDK vyžaduje HTTPS, řeší se per-zone lokální CA a explicitní trust store (S5); HTTP base URL není
    univerzální;
  - **vynucuje jen čtení u registrů** (žádné `npm publish`) a push jen do repa projektu; u gitu zvážit per-repo
    deploy key místo proxy (smart HTTP v2, LFS a submodules jsou velká komplexita);
  - **odmítá cizí autorizační hlavičky u typed operací**. OAuth a další passthrough se posuzují odděleně,
    včetně účtu a scopes. Na témže hostname může být OAuth i git/API: SNI je nerozliší. Buď brána bezpečně
    ukončí TLS a vynutí pravidla operací, nebo kombinaci nepodporuje; žádný automatický passthrough bypass;
  - **vynucuje cooldown při každém vydání artefaktu**, ne jen filtrováním seznamu verzí. Před vydáním ověří
    package/verzi, datum publikace z důvěryhodných metadat, hash a povolený původ; totéž pro redirect/CDN a cache
    brány. Přímá tarball URL ani lockfile nesmějí kontrolu obejít. Neznámé datum = odmítnout, ne vynechat cooldown;
  - vede **audit vydaných/stažených artefaktů**. To není seznam instalací: klientská cache, lokální soubory,
    git a odstranění balíčku nejsou z provozu brány spolehlivě patrné. Přehled instalací sbírá agent oblasti
    odděleně a označuje neznámé položky; pod kompromitovatelným UID není autoritativní bezpečnostní důkaz.
    Síťový cooldown nekontroluje libovolný už existující/importovaný kód; pokud se vyžaduje
    zákaz všech instalací nové verze, samotná brána jej nesplňuje a tato část zůstává blokovaná;
  - **Přímé TLS na vázané domény je zakázané**: všechny TCP jdou přes bránu, IP literál je blokovaný, ECH fail-closed.
- **Hlídač je detektor, ne fail-closed hranice:** kontroluje pf a anchory v nominálním intervalu 250 ms
  a při network change/sleep/wake/VPN. Skutečnou reakci ovlivňuje plánování; interval není garantovaná horní mez.
  Při odchylce zahájí izolaci/zastavení oblastí a notifikaci, ale `SIGSTOP` nezruší kernelové send buffery ani
  požadavky už předané systémovým službám. Samotný polling proto R3 při výpadku pf nezajišťuje.
- **Před F2 je nutné prokázat ochranu nezávislou na odstraňovaném pf rulesetu**, která při jeho vypnutí,
  flushi či pádu helperu nepustí zakázaná data; konkrétní dostupný mechanismus zatím chybí. Jestli bez
  entitlementů neexistuje, S3 neprošel. Explicitní proxy nebo další watchdog samy tento problém neřeší.
- **Změna politiky/obnova:** nejdřív zastavit přijímání nových operací, uzavřít dotčené tunely brány a odstranit
  relevantní staré pf states; změna pravidel sama neruší již povolená spojení. Po obnově znovu ověřit deny policy
  a funkční bránu, až pak povolit start/resume. Mechanismus musí zachovat síť hosta a ostatních oblastí.
- Kolize portů mezi oblastmi (dvě oblasti na :3000) se neřeší skrytě: Ohrádka ukáže, která oblast port drží.
  **Host → oblast port squatting je samostatný test S3b**, ne důsledek této UI.

### 5. Tajemství
- API klíče: výhradně v tvé Klíčence, do oblasti nikdy (typované brány). Brána omezuje metody, cesty, rate a budget.
- Git: buď **per-repo deploy key v oblasti** (jednodušší; únik dopadá jen na jedno repo), nebo **SE klíč držený
  bránou**, která provádí push. SE klíč + ssh-agent v oblasti je vlastní komponenta, kterou je třeba ověřit (S8).
  Volitelně Touch ID na každý push.
- **Údaj uvnitř oblasti je považován za kompromitovatelný; jeho oprávnění neomezuje UID ani svazek.**
  OAuth login agenta může otevírat celý účet/organizaci. App Store Connect **team API key** může podle role
  zasahovat všechny aplikace týmu; minimální role není omezení na projekt. Podpisové údaje mají vlastní dopad.
- Před povolením integrace musí být znám poskytovatel, oddělená identita, zdroje/aplikace/repozitáře, skutečné
  scopes, role, možnost revokace a dopad úniku. Preferovat projektově omezené údaje nebo brokerovanou operaci;
  široký osobní/týmový účet se automaticky nepovoluje. Neomezitelná integrace zůstává nepodporovaná, dokud
  výslovně nerozhodneš o změně kontraktu. Doménový passthrough sám scopes ani izolaci externího účtu nevynucuje.
- Agentovy automatické testy používají mocky autorizačních API a syntetické hodnoty; nečtou ani nemění živé
  credential stores. Skutečné uživatelské integrační ověření se eviduje zvlášť; mock není důkaz reálné integrace.

### 6. Nástroje
- npm/pip/uv/bun/cargo: volně, do home a projektu oblasti.
- **Homebrew per oblast**: stock brew v prefixu `/opt/ohr/<4 znaky>` (≤ 13 B → brew sám relokuje bottles),
  zapisovatelném jen oblastí. Volně i z tapů. Tvůj `/opt/homebrew` po zpevnění jen ke čtení a host prefix oblasti
  nikdy nespouští. **Root instalace (`.pkg`, rozšíření) z oblasti neexistuje**; host-side instalace mimo oblast
  je vědomé rozhodnutí tebe, ne požadavek agenta.
- Xcode + Simulator, Android Studio + emulátor (vlastní `ANDROID_ADB_SERVER_PORT` per oblast), Electron appky,
  prohlížeče: nativně v relaci oblasti. **Root komponenty (simulator runtimes, SDK pkg) instaluje host mimo oblast**;
  z oblasti jen fail + instrukce.
- Terminálová práce: `ohradka shell <oblast>` v libovolném terminálu → shell jako UID oblasti v její launchd doméně
  (CLI agenti, `xcodebuild`, `simctl` mluví se službami oblasti).
- **Docker**: výjimka z R5 — linuxové kontejnery potřebují linuxové jádro. Preferovaně Apple `container`
  (macOS 26+) nebo Colima/Lima **s vlastní instancí per oblast** (sdílená instance by porušila izolaci);
  vlastní mikro-jádro per oblast je kandidát F4. Zařazení Dockeru mimo MVP vyžaduje rozhodnutí ve F0.
  Startuje až při prvním `docker` a po nečinnosti zhasne. Požadavek je runtime pod UID oblasti, bez přímé sítě
  mimo bránu (kandidát: bez síťové karty, přes vsock), sdílení jen projektu; stock runtime to musí prokázat v S7,
  nejde o automatickou vlastnost Apple `container`/Colimy. Nutná je i skutečná kompatibilita Docker CLI/build.

### Komponenty
| Část | Role | Technologie |
|---|---|---|
| Ohrádka.app | Oblasti, menu bar, schvalování (Touch ID), proxy appky, zobrazení oken | SwiftUI, AppKit, Metal, LocalAuthentication |
| ohradka-helper (system LaunchDaemon) | Uživatelé, svazky, relace, pf, hlídač, NATLOOK, broker frames/input, zpevnění hosta, ACL | SMAppService, OpenDirectory, APFS, pf |
| Agent relace | Capture oken, vstup, menu, schránka, hlášení procesů a portů | ScreenCaptureKit, Accessibility, IOSurface |
| Síťová brána | Spojení, DNS, typované brány, vkládání klíčů, log | Network.framework, SwiftNIO (HTTP/1–2, WebSocket) |
| Docker runtime | Apple `container`/Colima (instance per oblast) nebo lazy mikro-VM | Containerization/Virtualization.framework |
| CLI `ohradka` | shell, run, pause, snapshot, rollback | XPC |

Helper je system LaunchDaemon v global bootstrap namespace, takže je dosažitelný i z oblasti. Privilegované XPC
přijímá jen od tvého UID, podepsané Ohrádky a podepsané brány (pro NATLOOK); agentovi oblasti poskytuje
**pouze úzký broker frames/input** s ověřením audit tokenu, code signature a session. Žádné jiné operace.
To je nejcitlivější attack surface — viz S0, S8 a fuzzing v `Tests/Escape/`.

Design card:
- Workload: tři aktivní oblasti vedle tvé konzole; další uložené oblasti vypnuté. Odhad režie 0,5–1 GB na relaci
  není měření; uvést model Macu, RAM, macOS, displeje, počet oken/streamů a souběžně běžící aplikace.
- Resource limity: APFS kvóta řeší jen příslušné svazky. CPU/RAM/GPU/bandwidth limity nemají doložený mechanismus;
  per-process limit ani polling nedokazují per-UID hard limit. Před slibem „runaway agent nepoloží host“ je nutné
  doložit mechanismus a zátěžový test, nebo tento slib výslovně odlišit od threat modelu, který DoS vylučuje.
- Cíle: cold login 10–30 s, warm/resume < 2 s, pauza aplikací < 100 ms; nejde o důkaz bezpečné pauzy celého UID.
  Input-to-photon 30–50 ms při 60 fps (120 Hz není gate), `npm install` přes bránu ≤ 1,1× nativně.
  Uvést rozdělení latencí, výpadky snímků a cold/warm cache; před testem stanovit acceptance statistiku,
  délku testu a reprezentativní workload, bez zpětného přizpůsobování prahů naměřenému výsledku.
- Hlídač: nominální interval 250 ms; měřit detekci, skutečné zastavení, uzavření spojení i přenesené zakázané bajty.
  Bezpečnostní gate R3 je nulový zakázaný přenos, ne splnění časovače. Budget Docker start/stop zatím není určen;
  musí být rozhodnutý před S7, chybějící budget není pass.

## Fáze

**F1 — Spiky s branami** (`spikes/<n>/`, výsledky `docs/spikes.md`):
- S1 Neviditelná relace: skrytý uživatel, virtuální relace z localhostu, přežití bez klienta, Metal/GPU, Retina,
  Xcode + Simulator, Android emulátor, Electron, prohlížeč; čas přihlášení, RAM.
  **Brána: tři souběžné oblasti, přežití 10 min bez klienta nebo s ověřeným keeperem, skutečně akcelerované
  aplikace v požadovaném rozsahu, viditelný TCC prompt a dál funkční host konzole. Jinak neprošlo.**
- S0 Hranice a attack surface (po S1): globální XPC/Mach services, TCC (AX, Screen Recording, Input Monitoring, mic, camera),
  `CGEventPostToPid` a SCK cross-session, `ps`/`mdfind`/`log show`, ingress bind, externí disk/Time Machine,
  TCC bootstrap, signing/`get-task-allow`, životní cyklus celého UID a opětovné spuštění.
  **Brána: R2 v testovaném rozsahu splněno; neznámé pokrytí nebo přesun selhání do reziduí není pass.**
- S2 Coherence: ScreenCaptureKit se samostatnými proxy okny, IOSurface/Mach port přes broker, vstup, menu, popovery, IME;
  latence a FPS. Brána: input-to-photon 30–50 ms při 60 fps a použitelnost Xcode, Simulatoru, Electron appky a Safari;
  supported subset definovaný v S2 (menu, popovery, základní zkratky).
- S3 pf: `route-to` + `tag` → `rdr tagged`, přežití tagu přes `lo0`, izolace `lo0`, IPv6, NATLOOK, test `pfctl -F all`
  a vypnutí pf (žádný zakázaný přenos), staré states, pád helperu/brány, VPN, network change/sleep/wake.
  **S3b ingress: wildcard listenery, LAN → oblast, host → oblast, port squatting a funkční same-zone loopback;
  bez vynucené hranice neprošlo.**
- S4 Zpevnění: dopad `chmod 700 ~`, audit povolených metadat, chráněné kořeny a nově vzniklá data, ACL na socketech
  a `/tmp`, APFS topologie home/projekt/prefix, nové mounty a odemčené zálohy, úplný rollback a crash recovery,
  periodický audit a nekonfliktní uninstall. Kanárky a mocky, ne přístup ke skutečným tajemstvím či databázím.
- S5 Typované brány: npm, PyPI, brew, git, API modelů; typed/passthrough dle cíle a operace; Cargo/Go/Gradle/NuGet/
  Conda/RubyGems; artefaktový cooldown; lockfile/URL/redirect/cache; scopes přihlášení; cizí auth;
  SSRF/DNS rebinding/ECH/IP literál/non-TLS; HTTP vs HTTPS a WebSocket u agentů.
- S6 Homebrew per oblast: top 200 formulí, stock relokace; ověřit, zda je datum publikace pro cooldown.
- S7 Docker: preferovaně Apple `container`/Colima (instance per oblast); jinak mikro-jádro bez síťové karty jako proces oblasti;
  registry, published ports, vsock.
- S8 Signing/TCC: hardened runtime, `get-task-allow` absence, TCC persistence, SMAppService s Personal Team,
  broker autentizace, fuzzing helperu.

**F2 — Jádro:** helper, životní cyklus oblasti (uživatel, svazek, relace, prefix), pf + brána + hlídač,
typované brány a klíče, CLI, pauza/snapshot/rollback, menu bar se schvalováním, průvodce zpevněním hosta,
audit povolených metadat a uninstall. **Kandidát omezeného MVP: CLI + jedna VNC plocha na oblast, jen pokud
to schválíš ve F0 a projdou bezpečnostní brány. Není to splnění celého R1–R8.**
**F3 — Coherence:** agent relace, proxy appky v Docku, zrcadlení menu, most schránky, notifikace, file open/save
a drag & drop. Supported subset, ne plná náhrada Finderu.
**F4 — Docker, zařízení, git:** Apple `container`/Colima (instance per oblast) nebo mikro-jádro, deploy klíče, iOS/Android
zařízení (usbmuxd/adb jen s výslovným oprávněním oblasti). Až po tom, co F2/F3 projdou.

Struktura repa: `Ohradka/` (appka), `Helper/`, `Broker/`, `SessionAgent/`, `Gateway/`, `Docker/`, `spikes/`, `Tests/Escape/`, `docs/`.

## Postup F1 — detail spiků

**Dělba práce.** Kroky, které mění systém (vytvoření uživatelů, zapnutí Sdílení obrazovky a Vzdáleného přihlášení,
pravidla pf, zápisy do `/opt`, cokoli přes `sudo`), spouštíš ty. Ke každému dostaneš skript, ke kterému si
nejdřív přečteš, co dělá, a úklidový skript, který vše vrátí. Kód, sondy, měření a vyhodnocení připravím já.
Stahování a spouštění cizích balíčků v testech (brew, npm) proběhne až s tvým výslovným souhlasem s konkrétním příkazem.
**Root operace z oblasti neexistují**; každá změna systému je host-side a explicitně tvoje.
Před prokázáním hranic se v testovacích oblastech spouštějí jen kontrolované sondy a požadované testovací aplikace
s prázdnými profily a syntetickými daty; žádné skutečné projekty, účty nebo nepřezkoumané balíčky.
Agent nečte, neupravuje ani nemaže soubory s tajemstvími a neotevírá živé databáze ani credential stores.
Testy systémových úložišť používají mocky; skutečná integrace vyžaduje zvlášť evidovaný uživatelský důkaz.

**F0 — rozhodnutí před F1** (bez nich nelze gates vyhodnotit):
1. **Kontrakt:** potvrdit threat model výše; případné další výjimky z R2/R3 nejsou dosud schválené.
   Označení útočníka jako „oportunistický balíček“ samo nevyřazuje běžné user-level útoky.
2. **R6:** je per-app Coherence podmínkou MVP, nebo je přípustná jedna VNC plocha na oblast?
3. **Host access:** smí host číst svazek projektu (backup/export), nebo jen řízený export?
4. **Docker:** v MVP, nebo až F4?
5. **Signing:** je přípustný placený Developer ID / NE, pokud free Personal Team nestačí?
6. **Fallback:** pokud S1/S2 neprojde, která varianta je přijatelná (jedna aktivní oblast, VNC plocha, CLI only, VM)?
   Dosavadní odmítnutí VM platí, dokud výslovně nerozhodneš jinak.
7. **Externí identity:** které integrace lze provozovat s oddělenými a omezenými účty? Široká oprávnění nejsou
   automaticky akceptovaná jen proto, že jejich údaje leží v oblasti.
8. **Měření:** cílový Mac, displeje, tři aktivní oblasti a acceptance statistiky; Docker start/stop budget
   nejpozději před S7. Chybějící rozhodnutí se značí jako otevřené, ne jako souhlas s nižším cílem.

**Pořadí:** S1 (tři kontrolované testovací relace) → S0/S8 → S4 a S3/S3b (souborová, lifecycle a síťová hranice)
→ S5 → S6 → S2-A/S2-B → S7. Nejdřív rozhodující bezpečnostní proveditelnost, až potom rozsáhlé instalace
a Coherence. Nezávislé mock/fixture testy S5 lze připravovat dřív; systémové zásahy a cleanup se nesmějí střetnout.
Po bezpečnostním failu pokračovat jen nezávislým výzkumným prototypem bez skutečných dat, ne závislou integrací.

### S1 — Neviditelná relace (brána celého GUI návrhu)
- Připravím `spikes/s1-session/`:
  - `create-users.sh`: vytvoří 3 skryté testovací uživatele (`sysadminctl`, `IsHidden`, skupina `ohradka`)
    a jejich hesla uloží do tvé Klíčenky;
  - `probe`: Swift CLI uvnitř relace, hlásí skutečné/efektivní UID/GID, skupiny, audit session a bootstrap
    kontext, displeje, Metal zařízení, skutečnou renderovací zátěž a RAM procesů UID; neloguje tajemství;
  - `observe.sh`: jen povolená metadata (`who`, procesy podle UID, domény `gui/<uid>` a `user/<uid>`);
  - `cleanup.sh`: smaže testovací uživatele a vrátí nastavení;
  - README s kroky.
- Spouštíš ty:
  - povolit Sdílení obrazovky jen pro testovací uživatele; **port 5900 nevystavovat do LAN** (firewall/localhost);
  - dočasně zapnout Vzdálené přihlášení (SSH tunel na localhost, protože Screen Sharing.app se k vlastnímu Macu nepřipojí);
    **port 22 jen localhost/firewall**;
  - přihlásit se jako testovací uživatel do virtuální relace, odpojit se;
  - spustit sondu jako UID testovací oblasti v jejím bootstrap/audit kontextu. `launchctl asuser` **nemění
    UID/GID**; případný root launcher musí před spuštěním sondy explicitně nastavit předepsané credentials;
  - po odpojení 10 min sledovat, zda relace a procesy žijí, a zda tvá konzole zůstala funkční.
- Měří se:
  1. relace vznikne souběžně s tvou (ne jen fast user switching);
   2. přežije odpojení uživatelského klienta 10 min; zvlášť výsledek bez keeperu a s případným keeperem;
   3. běží 3 testovací relace najednou (vedle tvé), včetně ověření limitu High Performance režimu;
   4. každá relace má displej a požadované aplikace skutečně **akcelerovaně renderují**; zjištění Metal zařízení nestačí;
  5. uvnitř funguje Xcode + Simulator, Android emulátor, Electron appka a Safari, a CoreSimulatorService běží pod UID relace;
  6. čas přihlášení (cold/warm), RAM na relaci;
   7. TCC prompt je viditelný a potvrditelný; po odpojení klienta se granty neztratí;
   8. při všech těchto měřeních se UID/GID, skupiny a session shodují s předem určenými očekáváními.
- **Brána:** body 1–5, 7 a 8 musí projít ve třech souběžných oblastech s funkční host konzolí; bod 6 musí
  splnit předem určené výkonnostní cíle. Chybné credentials zneplatňují měření, nejsou důkazem izolace.
  Android emulátor a Electron jsou součást R1; jejich selhání není pass bez explicitní změny rozsahu.
  Keeper varianta může projít jen jako samostatně změřená konstrukce včetně režie a chování po pádu klienta.
- Navazuje: vlastní RFB klient v Ohrádce (Apple autentizace + výběr virtuální relace) je **optimalizace**;
  dokud není hotový, musí být prokázaná cesta přes Screen Sharing.app. Pokud zvolená konstrukce vyžaduje
  keeper, ten je naopak povinnou součástí runtime a brány S1. Protokol pro výběr relace je nutné prozkoumat.

### S0 — Hranice a attack surface (nové, hned po S1, před S2)
- Připravím `spikes/s0-boundary/` (běží v testovací relaci z S1):
  - `xpc-probe`: výčet a dosažitelnost globálních Mach services z oblasti;
  - `tcc-probe`: AX, Screen Recording, Input Monitoring, mic, camera, AppleEvents, notifikace;
  - `capture-probe`: SCK, `CGWindowListCopyWindowInfo`, `CGEventPostToPid`, `AXUIElementCreateSystemWide`;
  - `host-read-probe`: syntetické kanárky v povolených kořenech a testovací metadata z `ps`, `mdfind`,
    `log show`, `netstat`, `system_profiler`/`ioreg`, `dscl`; úložiště tajemství jen přes mocky, ne živé položky;
  - `ingress-probe`: listener na `0.0.0.0`, přístup z hosta/LAN/jiné oblasti;
  - `signing-probe`: `codesign -d --entitlements`, `get-task-allow`, TCC persistence;
  - `lifecycle-probe`: joby v `user/<uid>` i GUI, odpojené CLI procesy, forkování během přechodu do pauzy,
    cron/at, LoginItems a SMAppService. Testovat start během vypínání i po něm a po pádu řídicí komponenty;
  - všechny sondy nejdřív ověří skutečné/efektivní credentials a audit/bootstrap kontext, jinak měření odmítnou.
- **Brána:** žádný prokázaný přístup ke chráněným datům, cizí relaci nebo privilegované operaci; vypnutá oblast
  nemá procesy UID ani funkční cestu k novému spuštění. Dosah na globální službu není automaticky únik,
  ale známá neoprávněná operace je fail; neznámé pokrytí zůstává nejasné. Mock nedokazuje skutečné oddělení
  Klíčenek/TCC: bez uživatelského integračního důkazu se tato část nesmí vykázat jako prošlá.
  Nález se vede u konkrétního R2/R3; přesun do seznamu rizik nesplněný požadavek neuzavírá.

### S2 — Coherence
- **S2-A (ve tvé relaci, bez rootu):** prototyp, který zachytí okna jiné appky (např. TextEdit) přes ScreenCaptureKit
  a vykreslí je v jiném procesu jako samostatná proxy okna přes IOSurface, předává vstup a zrcadlí menu přes
  Accessibility. Ověřit více oken, překryvy, skrytá okna, přesun/resize a vazbu popupu na správné okno;
  app-filter nad displejem sám tyto vlastnosti nedává. Od tebe: udělit prototypu Screen Recording a Accessibility.
- **S2-B (po S1):** stejný agent uvnitř relace oblasti; IOSurface přes **Mach port brokerem**, ne globální IOSurface ID.
- Měří se: latence vstup → pixel, FPS, menu a popovery, IME, Retina, secure input, notifikace, file dialogy,
  drag & drop a routing zkratek; na Xcode, Simulatoru, Electron appce a Safari.
- **Brána:** input-to-photon 30–50 ms při 60 fps, žádné chybějící menu ani popovery v supported subsetu
  (menu, popovery, základní zkratky); secure input/notifikace/file dialogy jsou samostatné testy, ne gate.
  Měřit tři souběžné oblasti dle design card; jedna úspěšná proxy v host session nedokazuje S2-B.
  120 Hz je nice-to-have, ne gate. Neotestovaná interakce nesmí být nabízena jako funkční.

### S3 — pf podle uživatele
- Připravím `spikes/s3-pf/`:
  - šablonu anchoru;
  - testovací listener a kontrolovanou protistranu, která nezávisle zaznamenává přijaté syntetické kanárky/bajty;
  - `load.sh` / `unload.sh` (sudo, spouštíš ty);
  - testy spouštěné jako testovací uživatel s ověřenými skutečnými/efektivními credentials a session;
  - návrh nezávislé ochrany při ztrátě pf; pokud dostupný mechanismus chybí, zaznamenat blokátor, ne náhradu pollingem.
- Měří se:
  - `route-to` podle `user` + `tag` → `rdr tagged`;
  - zda tag přežije průchod přes `lo0`;
  - izolace `lo0` (oblast → host, host → oblast, oblast → oblast);
  - IPv6, včetně link-local a ULA;
  - `DIOCNATLOOK`;
  - odděleně flush pravidel/anchoru, `pfctl -F all`, vypnutí pf, pád helperu i brány, network change, sleep/wake a VPN;
    měřit zakázané bajty na protistraně, nikoli jen čas doručení `SIGSTOP`;
  - nová i existující TCP spojení, pf states, požadavky už předané resolveru, send buffery při zastavení procesu
    a odvolání dříve povolené operace; po obnově nesmí přežít starý průchod;
  - **S3b ingress:** wildcard listenery IPv4/IPv6, host/LAN/jiná oblast, port squatting na host port;
    zároveň pozitivní same-zone dev server bez přístupu k cizím listenerům;
  - resolver, DNS/mDNS/ICMP a další zprostředkované kanály; vzorek přenosu projektu nahradit syntetickým kanárkem;
  - **SSRF:** doména rezolvující na loopback/RFC1918/link-local, IP literál, ECH, non-TLS.
- **Brána:** přesměrování, oddělení listenerů a legitimní provoz fungují a žádná testovaná cesta včetně failure
  modes nepřenese zakázaný kanárek/bajt. Zakázaná spojení se neobnoví přes staré states ani tunely.
  Úspěšný přenos byť před zásahem hlídače = fail R3; neuzavřený ingress/port squatting nebo cizí localhost = fail.
  Záložní explicitní proxy je jiná konstrukce k ověření, ne automatické řešení resolveru a výpadku pf.
  Regrese kompatibility nebo přijetí úniku vyžaduje tvoji explicitní změnu kontraktu, jinak F2 blokováno.

### S4 — Zpevnění hosta
- Připravím:
  - `audit-host.sh`: jen povolená metadata kořenů, práv/ACL, socketů a mountů; žádné čtení obsahu skutečných
    tajemství, Klíčenek ani databází. Report rozlišuje ověřené pokrytí, nepokryté cesty a drift;
  - `harden-host.sh`: cílené povolené změny podle reportu, spouštíš ty po kontrole; zaznamená původní i nastavený stav;
  - manifest home/projekt/prefix/cache/TMP a později runtime, mountpointy, kvóty a implementovatelný postup
    snapshotu/obnovy, včetně hostem vlastněného recovery záznamu;
  - `uninstall.sh`: obnoví jen vlastní nezměněné zásahy do práv/ACL; konflikty nezamete obnovením starého stavu.
    Odstranění vlastních uživatelů/svazků a položek aplikace má samostatný potvrzený rozsah.
- Měří se: co se rozbije tvým nástrojům po `chmod 700 ~`; co se rozbije v oblasti s ACL deny na `/tmp` a vlastním
  `TMPDIR`; zda oblast dosáhne na externí disk/Time Machine; zda `ps`/`mdfind`/`log show` vrací tvá data;
  zda nový install znovu zavede přístupný kanárek nebo zapisovatelnou host cestu.
  - Za běhu oblasti vytvořit, přesunout, obnovit a vyměnit kanárky v chráněných kořenech; připojit testovací
    svazek i odemčenou zálohu. Nepřetržitá sonda nesmí uspět ani mezi změnou a dalším auditem.
  - Ověřit perzistenci syntetickým startup souborem/jobem v home; plný rollback ji musí odstranit. Pád během
    každé fáze obnovy nesmí vést ke startu smíšeného stavu. Zvlášť ověřit nezměněnou ochrannou politiku.
  - Při uninstallu vložit následnou legitimní změnu práv; nesmí být přepsána původní zálohou.
- **Brána:** doložená ochrana všech deklarovaných kořenů včetně nových dat/mountů, nejen momentálně nalezených
  kanárků; nulové přechodné zpřístupnění, funkční host nástroje, správný rozsah rollbacku a crash recovery.
  Nepokrytá cesta/perzistence, obnova mezi filesystemy přes `RENAME_SWAP` nebo chybějící mechanismus = neprošlo/nejasné.
  Periodický audit neudělá z prodlevy ochranu. Uninstall nesmí přepsat cizí následné změny.

### S5 — Typované brány (bez rootu, testovatelné hned)
- Prototyp brány (Swift, Network.framework, bez závislostí):
  - npm registry:
    - filtr packumentu podle cooldownu a přepis URL tarballů přes bránu;
    - kontrola způsobilosti každého tarballu podle package/verze, publish-time, hashe a původu, i bez předchozího
      požadavku na packument; opakovaná kontrola při vydání z cache brány a při redirectu na CDN;
    - `PUT`/`DELETE` → 403;
    - odmítnutí cizí `Authorization` u typed operací;
    - seznam stažených balíčků.
  - API modelů: vložení klíče, streamování SSE, odmítnutí cizího klíče, rate/budget limity.
  - **SSRF:** odmítnutí loopback/RFC1918/link-local/ULA/multicast/`100.64/10`, IP literál, ECH fail-closed,
    non-TLS policy.
- Testy:
  - `npm view` / `npm pack` přes bránu (bez spouštění install skriptů);
  - pokus o publish přes `curl -X PUT`;
  - mock upstream s testovacím klíčem;
  - fixture s verzí před/po hranici cooldownu, přímá tarball URL, připravený lockfile/`npm ci`, redirecty,
    scoped packages, neznámé datum a cache brány; zakázaný artefakt se nesmí vydat žádnou z těchto cest;
  - klientská cache a importovaný lokální artefakt: doložit hranici síťového cooldownu, ne vykázat je jako
    kontrolované instalace. Požadavek na úplný zákaz instalací bez dalšího enforcementu zůstává nesplněný;
  - kolize typed/passthrough na stejném hostname, cizí účet stejného poskytovatele, git mimo projekt přes jiné
    API/protokol; ověřit, že kompatibilitní výjimka neobejde typed policy;
  - mocky širokého a omezeného OAuth/API oprávnění; skutečné scopes a revokaci doložit uživatelským ověřením,
    ne skutečnými přihlašovacími údaji v automatických sondách;
  - DNS rebinding doména na `127.0.0.1` a LAN IP;
  - HTTP vs HTTPS base URL u každého SDK (některé vyžadují TLS).
- Potom PyPI (simple index, `upload-time` pro cooldown), Homebrew (`HOMEBREW_API_DOMAIN`, `HOMEBREW_BOTTLE_DOMAIN`),
  git smart HTTP (jen repo projektu, push jen tam) **nebo per-repo deploy key bez proxy**.
- Měří se:
  - pokrytí: npm, pnpm, yarn, bun, pip, uv, brew, git, Cargo, Go, Gradle/Maven, NuGet, Conda, RubyGems,
    SDK Anthropic/OpenAI, OpenCode, Claude Code, Codex, WebSocket/SSE;
  - typed vs passthrough podle cíle a operace, včetně kolizí na stejném hostname;
  - audit stažení odděleně od neautoritativního přehledu instalací; rozsah a revokace externích oprávnění;
  - režie proti přímému spojení na stejných fixtures, cache a workloadu dle design card.
- **Brána:** typed režim pro npm/PyPI/brew včetně artefaktové kontroly projde; SSRF/ECH/IP literál pokusy jsou
  blokované; žádná URL, lockfile, redirect ani cache brány nevydá zakázaný artefakt. Neznámé stáří se neobchází.
  Auth/účtová policy funguje i přes alternativní endpointy, široké přihlášení není automaticky povolené;
  pro reálné integrace jsou doložené scopes. Nevymezený passthrough = fail R3 nebo nepodporovaná integrace R8.
  Režie ≤ 1,1× nativně podle předem určeného měření; mock upstream není důkaz skutečné integrace SDK.

### S6 — Homebrew per oblast
- V testovacím uživateli z S1 prefix `/opt/ohr/t001` (vytvoření v `/opt` spouštíš ty).
- Instalace top 200 formulí (stažení schválíš). Měří se poměr nalitých bottles vs. kompilace,
  vzorek `brew test` a casky do `~/Applications` uživatele; **ověřit, zda API dává datum publikace pro cooldown**
  a zda metadata pokrývají přímo vydávaný artefakt. Pokud ne, označit cooldown jako nesplněný; vypuštění
  této funkce není automatické a vyžaduje tvoje rozhodnutí. Volné tapy/source buildy nemají neprokázané garance cooldownu.
- **Brána:** top 200 formulí má známý poměr bottle/kompilace, `brew test` sample projde, casky jdou do
  `~/Applications`; žádná podporovaná instalace nevyžaduje root z oblasti, host prefix se nemění.
  Prefix je zahrnutý v ověřené APFS topologii a rollbacku; zjištěná nepodpora se nesmí skrýt statistickým průměrem.

### S7 — Docker
- Preferovaně otestovat Apple `container` (macOS 26+) nebo Colima/Lima **s vlastní instancí per oblast**
  (sdílená instance je pro vývoj, ne izolaci); vlastní prototyp jen pokud nevyhoví.
- Vlastní prototyp: Virtualization.framework, linuxové jádro + initrd s `dockerd`, bez síťové karty, síť přes vsock
  do brány (S5), spouštěný jako testovací uživatel v jeho relaci.
- Měří se: start, `docker run`, `docker build`, síť kontejneru přes bránu, registry auth, published ports,
  host mount policy i při změně konfigurace runtime z oblasti; `docker run -v /:/host` nesmí zpřístupnit Mac
  ani jiné oblasti. Očekávaný strom se určí podle skutečné topologie runtime, ne podle předpokladu o mikro-jádru.
  Ověřit vsock proxy, vlastní daemon/socket a síťové failure modes stejně jako S3.
- **Brána:** `docker run`/`build` projde; kontejner nevidí host; síť jde jen přes bránu; start/stop je v limitu
  stanoveném před S7. Kompatibilita Docker CLI není automatická vlastnost Apple `container`; chybějící
  budget nebo neověřená izolace stock runtime znamená nejasné, ne pass.

### S8 — Signing, TCC a broker (nové)
- Ověřit: hardened runtime, absence `get-task-allow`, stabilní identitu pro TCC, SMAppService s Personal Team,
  self-signed varianta. Zvlášť registrace LoginItem, LaunchAgent a LaunchDaemon: admin approval vyžaduje
  LaunchDaemon, nikoli každé použití SMAppService. Schopnost standardního uživatele registrovat vlastní
  agent/login item se musí zahrnout do životního cyklu, nesmí se předpokládat její zákaz.
- Ověřit: agent v oblasti nejde attachnout same-UID procesem; TCC granty nejdou zneužít neoprávněnou modifikací
  bundle; broker ověřuje audit token, code signature a session.
- Fuzzovat XPC broker: neplatné zprávy, velikosti, IOSurface Mach porty, path traversal, TOCTOU.
- **Brána:** žádný same-UID proces nezíská TCC granty agenta ani nepřiměje broker k operaci mimo schema.

### Výstup F1
`docs/spikes.md` s výsledkem každé brány (prošlo / neprošlo / nejasné + důkaz), mapováním na R1–R8,
verzí macOS/hardware, credentials sond, vstupy, očekávaným výsledkem a odkazy na skutečné protokoly.
Rozlišit měřený výsledek, odvozený závěr, mock a neověřenou hypotézu. Uvést blokátory zvlášť od reziduí mimo model.
F2 lze spustit jen po splnění vstupního kontraktu. Bezpečnostní fail se neopraví přejmenováním na reziduum;
změna konstrukce je možná, změna požadavku jen s tvým výslovným rozhodnutím. „Nevyřešeno“ není pass.

## Otevřené blokátory a zbytková rizika

### Blokátory současného kontraktu — nejsou automaticky přijaté
- **R2, soubory:** ochrana nových dat mimo home, přesunů/obnov a nových mountů není prokázaná. Audit a varování
  nezabrání přechodnému čtení. Odemčené šifrované zálohy nejsou chráněné samotným šifrováním. Řeší S0/S4.
- **R2, životní cyklus:** zákaz nového spuštění a zánik všech procesů UID mimo GUI session nejsou prokázané.
  Stejně tak plný rozsah rollbacku, stav mimo svazek a zotavení po přerušené obnově. Řeší S0/S4/S8.
- **R3, resolver a jiné kanály:** DNS přes systémové služby, mDNS, ICMP, AirDrop/APNs musí být otestované
  a případné nekontrolované datové cesty uzavřené. Importovaný projekt je také chráněné aktivum; argument
  „osobní klíče oblast nevidí“ únik projektu neomlouvá. NE je alternativní směr k ověření, ne prokázaná jediná
  ani automaticky dostatečná oprava všech zprostředkovaných kanálů.
- **R3, výpadek pf:** polling ani zastavení aplikací negarantují nulový únik. Existuje detekční/provozní mezera
  bez doložené horní meze; ochrana při ztrátě rulesetu a práce se starými states/tunely chybí. Řeší S3.
- **R2/R3, ingress a loopback:** wildcard listenery, port squatting a rozlišení same-zone serveru od host
  localhostu nejsou uzavřené. Filesystem mount policy tuto síťovou hranici sama nevytvoří. Řeší S3b.
- **R2/R3/R8, autorizace a passthrough:** rozsah externího účtu není omezen umístěním přihlašovacího údaje.
  Obecně povolená doména může umožnit exfiltraci nebo obejít repo/účtová pravidla. Je nutná omezená operace
  a identita, jinak integraci nepodporovat nebo vyžádat explicitní změnu kontraktu. Řeší S5/S8.
- **Cooldown:** filtr seznamu verzí není kontrola artefaktů; lokální cache/import není vidět v síti.
  Chybějící metadata pro brew/tapy nelze vyřešit tichým vypuštěním funkce. Řeší S5/S6.
- **R1/R5/R6, GUI kapacita:** tři použitelné akcelerované relace vedle host konzole, limit High Performance
  režimu a případný keeper nejsou ověřené. S1/S2 musí projít v cílovém souběhu, ne na jediné relaci.

### Rezidua v mezích výslovně uvedeného threat modelu a provozní omezení
- **Sdílené jádro/GPU/WindowServer:** chyby těchto komponent jsou mimo model, nikoli řešené tímto návrhem;
  držet macOS aktuální. Skryté hardwarové/timing kanály a DoS jsou výslovně mimo model, bez tvrzení o propustnosti.
- **Globální XPC:** system LaunchDaemons jsou společná attack surface. Pouhá dosažitelnost není porušení R2,
  ale neoprávněné čtení/zápis či spouštění přes běžné rozhraní je blokátor S0, ne automaticky přijaté reziduum.
- **TCC/shared hardware:** sdílené fyzické kanály jsou mimo model. Převzetí grantů, čtení host schránky/obrazovky
  či vstupu běžnou cestou ale mimo model není; neuzavřený nález blokuje R2. Politika a audit nejsou technický zákaz.
- **Dostupnost:** bez prokázaných CPU/RAM/GPU limitů může oblast zatížit host; proto zatím neslibovat ochranu před DoS.
- **TCC prompt phishing:** obsah oblasti není důvěryhodné approval UI; schvalování musí probíhat na hostu
  a být svázané s konkrétní oblastí a žádostí. Root instalace se z oblasti neautorizují.
- **Kompatibilita relací:** chování Sdílení obrazovky může Apple změnit; potřebný regresní test podporovaných
  verzí macOS. Keeper ani alternativní režim se nepovažují za funkční, dokud nemají vlastní důkaz.
- **Screen Sharing/SSH:** služba je host ingress surface; jen výslovně nutné porty a doba zapnutí, ověřené
  localhost/firewall omezení a zákaz samostatného loginu do vypnutých oblastí. Úklid musí obnovit vlastní změny.

## Verifikace — únikový test suite (`Tests/Escape/`)
Sondy běží pod UID oblasti (CLI i GUI), v souběhu tří oblastí podle příslušné brány. Před každým testem ověří
skutečné/efektivní UID/GID, skupiny a session/bootstrap kontext proti očekávání; nesoulad = neplatné měření.
Pouze syntetické kanárky, povolená metadata a mocky; žádné čtení či změna skutečných tajemství, credential stores
nebo interakce s živou databází. Důkaz reálné integrace od uživatele se eviduje odděleně od mock testu.
Každý případ má předem určený požadavek, povolenou/zakázanou operaci a oracle. Nejde o požadavek, aby celé
`ps` nebo `netstat` skončilo chybou, ale aby neposkytlo chráněný kanárek či nepovolenou schopnost.
Zakázaná operace musí být odmítnuta a zaznamenána; známý únik = fail, chybějící důkaz = nejasné.

1. Soubory: kanárky v chráněném home, pracovním kořeni, sdílených cestách, na testovacím disku/záloze a v jiné oblasti;
   zakázaný zápis do host nástrojů/startup kořenů, hardlink na chráněný kanárek, symlink zpracovávaný helperem;
   testovací metadata dostupná přes `ps`, `mdfind`, `log show`, `netstat`, `system_profiler`/`ioreg`, `dscl`.
2. Identita: mocky Klíčenky a autorizačních API, testovací agent/socket, schránka a obrazovka s kanárkem,
   události do host relace, `ptrace`, `open -a Terminal` (jen relace oblasti); **globální XPC/Mach services**;
   **TCC: AX, Screen Recording, Input Monitoring, mikrofon, kamera, Bluetooth, AppleEvents, notifikace**;
   `CGEventPostToPid`, `AXUIElementCreateSystemWide`, `CGWindowListCopyWindowInfo`, SCK cross-session.
3. Perzistence: LaunchAgent / cron / at / login item, `user/<uid>` job i odpojený CLI proces po vypnutí neběží;
   nové spouštění/login neprojde během přechodu ani po něm. Fork/job race, pád helperu a znovupřihlášení nesmějí
   obejít vypnutý stav. SMAppService agent/login item může být registrovatelný bez admina, ale nesmí obejít
   životní cyklus; privilegovaný LaunchDaemon nesmí být autorizovatelný z oblasti.
4. Síť: LAN, tvůj `localhost`, jiná oblast, nepovolená doména, raw IP, SNI s cizí IP, přímé TLS na vázanou doménu,
   `npm publish`, mock cizího API oprávnění, **ingress/port squatting**, pozitivní same-zone server bez přístupu
   k cizím listenerům, DNS rebinding, ECH, non-TLS, DNS/mDNS/ICMP/AirDrop/APNs, QUIC a běžné změny sítě.
   Flush anchoru/pravidel/states, `pfctl -F all`, vypnutí pf, pád helperu/brány, sleep/wake/VPN: protistrana
   nesmí přijmout zakázaný kanárek ani ze starého spojení/send bufferu. Kontrolovat také revokaci a opětovný start.
   Únik resolverem či během zásahu hlídače není pass se zapsaným reziduem.
5. Docker: zákaz zpřístupnění Macu/jiné oblasti i při změně mount konfigurace, vlastní daemon/socket,
   síť podle brány oblasti, registry auth, published ports, vsock a stejné failure modes jako v bodě 4.
6. Pozitivní: `npm`/`pip`/`brew install` (bottle, relokace, cask), Cargo/Go/Gradle/NuGet, `xcodebuild` + Simulator,
   Android emulátor, OpenCode i jiný agent, 3× stejná GUI appka ze 3 oblastí jako 3 položky v Docku,
   notifikace/file dialog/drag & drop/print/audio; tvůj `/opt/homebrew` beze změny.
7. Výkon: cold/warm login, bezpečná pauza odděleně od pauzy aplikací, skutečný render v každé ze tří oblastí,
   latence input-to-photon/FPS včetně rozdělení a výpadků, `npm install`/build vs. srovnatelně nativně,
   čas detekce i reakce hlídače. Dodržení intervalu není náhrada za nulový zakázaný přenos.
8. Helper/broker: path traversal, symlink/hardlink, TOCTOU, neplatné XPC zprávy, velikosti, IOSurface Mach porty;
   fuzzing; same-UID proces nezíská TCC granty agenta.
9. Průběžná ochrana: vytvoření/přesun/obnova kanárku, nový install a nový/odemčený testovací mount za běhu;
   sonda nesmí získat přístup ani před re-auditem. Uninstall nepřepíše následnou legitimní změnu práv.
10. Artefakty a účty: cooldown metadat i tarballu, lockfile/`npm ci`, přímé URL, CDN/redirect/cache brány,
    neznámé datum, odlišení lokální cache a stažení od instalace; zákaz typed bypassu přes OAuth/API na stejném
    hostname a jiné externí účty. Mocks scopes doplnit skutečným uživatelským důkazem před podporou integrace.
11. Rollback: startup/job kanárek v home i změny projektu/prefixu/cache, manifest všech zápisových kořenů,
    uzavřené fd, obnovitelný zapisovatelný stav a pád v každé fázi přepnutí. Nikdy nespustit neúplně obnovenou oblast.

## Dokumentační opory a hranice jejich důkazu
Ověřeno při review v dokumentaci, nikoli provedením lokálních sond. Platnost konkrétní implementace musí
potvrdit test na cílovém macOS; tyto odkazy neprokazují průchod F1.
- [launchctl(1)](https://keith.github.io/xcode-man-pages/launchctl.1.html): `asuser` nemění UID/GID; user doména
  může existovat nezávisle na GUI loginu.
- [crontab(1)](https://manp.gs/mac/1/crontab) a [at(1)](https://manp.gs/mac/1/at): allow/deny soubory obsahují
  jednotlivá uživatelská jména, ne skupiny.
- [SMAppService.register](https://developer.apple.com/documentation/servicemanagement/smappservice/register()):
  odlišná pravidla LoginItem, LaunchAgent a LaunchDaemon; admin approval není univerzální podmínka registrace.
- [rename(2)](https://manp.gs/mac/2/rename): záměna položek je operace v témže filesystemu, nikoli obnova APFS svazku.
- [Apple: Screen sharing type options](https://support.apple.com/en-hk/guide/mac-help/mchl1883115d/mac):
  pouze jedna současná High Performance session na Mac; ne důkaz proveditelnosti tří standardních relací.
- [Apple: Creating API keys](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api):
  týmový klíč má přístup ke všem aplikacím týmu v rozsahu role; ne automaticky jen k jednomu projektu.
- [npm: package-lock.json](https://docs.npmjs.com/cli/v11/configuring-npm/package-lock-json) a
  [npm install](https://docs.npmjs.com/cli/v11/commands/npm-install): lockfile a přímé tarball/git/lokální zdroje
  vyžadují vlastní kontrolu hranice; filtr registry metadat sám není enforcement všech instalací.
- [pfctl(8)](https://manp.gs/mac/8/pfctl): pravidla a state table mají odlišný životní cyklus; reload pravidel
  sám neprokazuje odvolání již povolených spojení.
