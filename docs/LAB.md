# Sanďbox — laboratoř a metodika měření (WP0.5)

**Stav: návrh LAB-v1 k potvrzení F0.8; žádný běh ani brána tímto dokumentem neprošly.**
Autoritativní je [PLAN.md](../PLAN.md), přijaté změny jsou v [DECISIONS.md](DECISIONS.md).
WP0.5 dodává metodiku; zůstává rozpracované do potvrzení minimální konfigurace a cílů uživatelem.
WP1.A1 je příprava, skutečné ověření S1 je [WP1.A2 / L1](../spikes/s1-session/README.md).

## 1. Návrh rozhodnutí F0.8

Všechny nové číselné meze v tomto dokumentu jsou **návrhy**, nikoli již přijatá akceptace.
Před ostrým během uživatel zaznamená přijetí nebo změny LAB-v1 v DECISIONS.md s datem a commitem.
Rozhodnutí neuděluje souhlas s konkrétními systémovými zásahy, granty ani stahováním.

| ID návrhu | K potvrzení | Důvod a rozsah |
|---|---|---|
| P1 | Minimum: Apple Silicon M1 nebo novější, 16 GiB RAM, macOS 27.x. Referenční běh na minimálním M1/16 GiB; další stroje samostatně. | Navazuje na dosud nepotvrzený návrh F0.8. Měření na rychlejším stroji nedokazuje minimum. Přesný model, build a displeje omezují platnost každého výsledku. |
| P2 | S1: tři oblasti + funkční host konzole; standardní Sdílení obrazovky. Každá virtuální plocha 1280 × 800 bodů, 2560 × 1600 pixelů (2×), cílová kadence 60 Hz. Host displej alespoň 60 Hz, pevná konfigurace. | Reprodukovatelný základ Retina; není to velikost okna sondy (960 × 600 bodů) ani důkaz podpory všech monitorů. Nemožnost nastavit profil se zaznamená, před měřením se navrhne jiný profil. |
| P3 | Cold login připraveného profilu: medián ≤ 20 s a p95 ≤ 30 s. Warm opětovný login: p95 < 2 s. Resume: zvlášť p95 < 2 s, až existuje příslušná konstrukce. | Zpřesnění cílů PLAN 10–30 s / < 2 s. Rychleji než 10 s není chyba; first-run se měří zvlášť. Viz §5. |
| P4 | Holé tři relace: p95 systémového přírůstku RAM ≤ 4,5 GiB, včetně WindowServeru a nutného klienta/keeperu. Zátěž: žádný vzorek varovného/kritického memory pressure a růst použitého swapu ≤ 1 GiB za každých 10 min. | 4,5 GiB je nový budget (1,5 GiB amortizovaně na relaci), ponechává na 16 GiB prostor aplikacím. Odhad PLAN 0,5–1 GB **není** závazný limit. Nejde o per-UID hard limit ani ochranu před DoS. Účtování §6. |
| P5 | GPU: 0 neshod pixelů; medián poměrů vůči host referenci ≤ 1,25, p95 ≤ 1,50. Prezentace: v každém 60s bloku ≥ 57 snímků/s, p95 intervalu ≤ 25 ms, nejdelší mezera ≤ 100 ms, vynechané 60Hz sloty ≤ 5 %. | Návrh tolerance měřitelné režie a krátkých výpadků; není odvozen z neprovedeného S1. 120 Hz není gate. Přesný výpočet a omezení §7. |
| P6 | Workloady, počty opakování, délky, způsob souběhu a rozhodování podle §3–8. | Platí nejhorší povinný případ/oblast, ne průměr tří relací. S2/S5/S7 vyžadují vlastní doplnění předregistrace (§9). |

Možný výsledek je, že M1/16 GiB tyto cíle nesplní. Pak se zaznamená Neprošlo, případně se uživatel
rozhodne pro nové minimum/cíl a **nový** běh. Prahy se nezměkčují zpětně podle výsledků.
Docker start/stop zůstává otevřený před S7; F0.7 není tímto návrhem uzavřené.

## 2. Registr strojů a rezervace

Stroj má trvalé ID v prostoru veřejného aliasu vlastníka, např. `LAB-janfiedler-01`, aby si různí
vývojáři nepřidělili stejné číslo. Konfigurace má revizi `r1`, `r2`… Změna macOS buildu, hardwaru, ovladačů,
displejů, režimu napájení nebo runtime vyžaduje novou revizi a určení opakovaných testů. Žádný výsledek
se automaticky nepřenáší na jiné čipy, buildy nebo displeje. „M1 a novější“ je kandidátní rozsah podpory,
nikoli tvrzení, že byly všechny jeho konfigurace ověřeny.

Povinná pole záznamu: ID/revize, datum a způsob ověření, veřejný kontakt vlastníka, model identifier,
čip/CPU/GPU, fyzická RAM v bajtech a GiB, macOS verze/build, Xcode/Swift, displeje (body/pixely/škála/Hz,
interní/externí/virtuální), napájení/režim výkonu, volné místo pro fixtures a obnovu, role minimum/reference,
stav připravenosti. Sériové číslo, UUID hardwaru, hostname, osobní uživatelská jména, IP a obsah home sem nepatří.
Přesné provozní údaje nezbytné pro test drží soukromý protokol; publikovaná kopie používá konzistentní aliasy.

| Stroj / revize | Veřejný vlastník | Ověřená metadata | Role a stav |
|---|---|---|---|
| LAB-janfiedler-01 / r1 | janfiedler | 2026-11-03, cílené čtení metadat: `MacBookPro17,1`, Apple M1, arm64, CPU 8 fyzických / 8 logických; RAM 17179869184 B = 16 GiB; macOS 27.2 (26B123); Xcode 27.0 (27A266a), Swift 6.4 (`swiftlang-6.4.0.34.1`) | Kandidát minima/reference. **Nepřipraveno pro L1:** GPU počet jader, volné místo, záloha a připravenost úklidu nejsou ověřené. Doplňující host měření a displeje viz níže; žádný verdikt brány. |

Údaje o M5 Pro v README S1 jsou historická diagnostika host sondy; nejde o tento M1 ani o běh brány.

### Samostatná host diagnostika M1 (2026-11-03)

[Protokol M1](evidence/s1/20261103T134131Z-janfiedler-LAB-janfiedler-01-r1-a8a26eeb/verdict.md)
uchovává tři předem naplánované 5s pokusy stejné Metal sondy v host konzoli. GPU mediány byly
10,481500 / 10,483625 / 10,483042 ms, každý pokus s 0 neshodami z 4096 ověřených pixelů;
prezentace 96,6 / 99,0 / 99,8 fps. Aktivní hlavní externí displej měl 3440×1440 pixelů, 100 Hz, 1×;
druhý interní 1680×1050 bodů / 3360×2100 pixelů, 60 Hz, 2×. Napájení AC. Tyto údaje doplňují registr r1.
Pozadí ani cache nebyly řízené, sonda běžela na běžném pracovním hostu. Nejde o S1/A2, měření RAM oblasti
ani o přímé výkonnostní srovnání s M5; oba záznamy zůstávají samostatné. Podrobné zdroje, identita,
sanitizované raw výstupy a review jsou v protokolu. P1–P6 zůstávají návrhem.

### Slot na konkrétním stroji

Použij [šablonu stroje a slotu](templates/lab/machine-slot.md). Rezervace se zapisuje před zásahem;
současně ji potvrdí vlastník stroje. Samotná rezervace v jiné nesloučené větvi není zámek.
Na jednom stroji je nejvýše jeden aktivní slot **včetně přípravy, restartů, obnovy a úklidu**.
Od konce plánovaného času se zámek neuvolní sám. Různé stroje mohou běžet souběžně.

| Rezervace | Stroj/revize | Slot / běh | Od–do (časová zóna) | Operátor / reviewer | Záloha, dry-run, úklid | Stav |
|---|---|---|---|---|---|---|
| — | — | — | — | — | — | Žádná rezervace ani aktivní slot |

Stavy: `návrh → rezervováno → připraveno → běží → úklid → uzavřeno`; `blokováno` drží zámek,
pokud mohl zůstat změněný systém. `zrušeno` lze použít bez úklidu jen před první změnou.
Před stavem připraveno musí být:

- splněné závislosti [IMPLEMENTATION §4](IMPLEMENTATION.md#4-laboratorní-sloty-sériové-běhy)
  pro danou konfiguraci, přijaté cíle a předregistrace;
- uživatelem potvrzená dokončená záloha nejvýše 24 h stará, ověřená možnost obnovy syntetického souboru,
  privátní odkaz na zálohu a lokální přístup uživatele pro obnovu; pouhá existence snapshotu nestačí;
- přečtený dry-run konkrétního commitu, manifest vlastních změn, zachycený původní stav a proveditelný úklid;
- dost místa dle manifestu (fixtures, výstupy, stav obnovy + 20 % rezerva), žádný jiný systémový test;
- operátor dostupný po celý zásah; jasný postup při ztrátě relace/spojení, rebootu nebo selhání ochrany portů.

Čísla 24 h / 20 % jsou provozní návrh LAB-v1. Privilegované kroky, TCC a změny nastavení provádí uživatel
(GUIDE §3). Do oblastí patří pouze prázdné profily, kontrolované aplikace a syntetická data.
Při poruše ochrany nebo nečekané změně hosta se test zastaví, zachová důkaz a provede připravený úklid.
S1 neprokazuje bezpečné vypnutí UID pro S0; jeho úklid musí přesto ověřit nulu zbylých testovacích procesů,
odstranění vlastních účtů, instalovaných objektů, listenerů a návrat vlastních změn skupin/služeb/pf.
Nevyřešený zbytek nebo konflikt znamená blokovaný slot; žádné slepé přepsání pozdější uživatelovy změny.

## 3. Předregistrace a platnost důkazu

Zkopíruj [šablonu běhu](templates/lab/run.md) do struktury [GUIDE §7](GUIDE.md#7-důkazy-a-verdikty).
Před měřením zafixuj commit metodiky, commity kódu, hashe fixtures/binárek, konfiguraci, všechny případy,
oracle, intervaly, velikosti vzorku, pořadí, očekávané credentials, prahy a pravidla vyřazení. Uchovej
časovaný schválený `inputs.md` (commit nebo hash v protokolu); dodatek nikdy nepřepisuje původní verzi.
Kalibrační/pilotní běh je označený předem a nepočítá se do potvrzovacího souboru.

### Více vývojářů, více výsledků — historie se nepřepisuje

Každý běh má vlastní adresář `docs/evidence/<brána>/<run-id>/`, kde brána je např. `s1` a
`run-id = <UTC-YYYYMMDDTHHMMSSZ>-<veřejný-alias>-<stroj>-<revize>-<náhodných-8-hex>`.
Použít ASCII písmena/číslice/pomlčky; ID musí být v repozitáři jedinečné. Existující adresář se nikdy
nepoužije znovu. Stejný vývojář na stejném stroji vytvoří při každém dalším běhu nové ID.

Předregistrace se zafixuje před měřením; raw během běhu pouze přibývá. Po uzavření se připojí manifest
SHA-256 publikovaných souborů a review. Uzavřený `environment.md`, `inputs.md`, raw i `verdict.md`
zůstávají neměnné. Oprava interpretace nebo metadat se přidá jako nový datovaný soubor v `amendments/`
s vlastním ID, autorem, důvodem a odkazy na původní obsah; původní soubor se neupraví. Další review také
dostává vlastní datovaný soubor. Oprava kódu, metodiky nebo nové měření vždy zakládá **nový běh**, nikoli
opravu starých čísel. Neplatné a neúspěšné běhy se zachovávají také. Veřejný obsah se kontroluje před
publikací; toto pravidlo nevyžaduje zveřejnit tajemství ani osobní metadata. Pokud se omylem objeví,
řeší se samostatná náprava se zachováním netajného záznamu o vynechání; incident se nesmí vydávat
za neexistující měření.

[spikes.md](spikes.md) vede pro každou bránu **přidávací index všech běhů** a samostatné závěry pro
konfigurace. Konfigurační klíč obsahuje stroj/revizi, macOS build, displeje/workload, konstrukci,
commit kódu a verzi akceptace. Výsledek jiného autora nebo stroje nepřepíše předchozí řádek.
Při konfliktu merge zachovat oba běhy; nevolit automaticky „novější vyhrává“. Opravy i nové souhrnné
závěry se přidávají jako další odkázaný záznam, původní závěr zůstává dohledatelný.

Rozdílné konfigurace mohou současně nést Prošlo a Neprošlo; vyjmenuje se jejich přesný rozsah.
Rozpor dvou platných běhů **stejné** konfigurace/kódu/metodiky se nesmí zprůměrovat ani přehlasovat:
bezpečnostní porušení znamená Neprošlo, u ostatních rozporů zůstává potvrzení konfigurace Nejasné do
review příčiny. Jednotlivé verdikty přitom zůstávají beze změny. COVERAGE je odvozený souhrn s odkazem
na index, ne úložiště posledního výsledku. Globální Prošlo vyžaduje všechny konfigurace výslovně
zařazené do schváleného rozsahu včetně minima; výzkumné či nepodporované stroje se vedou odděleně.
Pass na jednom Macu není obecný pass. Dokud není podklad, zůstává Neověřeno.

### Kontrola jednotlivého běhu

1. **Identita:** každá sonda má shodu skutečného/efektivního UID/GID, skupin, bootstrap a audit session
   s předem určeným očekáváním. Host reference má vlastní explicitní očekávání. `valid: null`, chybějící
   hodnoty nebo neshoda nejsou důkaz; exit 0 sám neznamená platný ani úspěšný případ. `asuser` nemění UID.
2. **Čas a souběh:** monotónní čas pro délky, UTC pro korelaci; zaznamenat skutečný začátek/konec fáze,
   nikoli jen spuštění procesu. Pro společné okno `[max(start_i), min(end_i)]` všech tří oblastí a host
   kontrol musí zbýt celá požadovaná délka. Na více strojích doložit synchronizaci/nejistotu času.
3. **Oracle:** pozitivní kontrola před i po negativním testu musí dokázat, že měřicí cesta funguje.
   Nula přijatých bajtů při mrtvé protistraně, ztraceném záchytu či neplatných credentials je Nejasné.
   Kontrolní a testované toky odlišit ID a směrem, ne ručně odstranit nechtěné bajty z výsledku.
4. **Úplnost:** raw data a stderr se zachovají i pro neúspěch, timeout a neplatný pokus. Slepé opakování
   „dokud to projde“ je zakázané. Předem povolené důvody neplatnosti: chybné credentials, výpadek
   záznamu/oracle, neplánovaná vnější změna konfigurace, nedoložený souběh. Pád testované konstrukce,
   neschopnost renderovat, tlak na RAM nebo pomalost nejsou důvody vyřazení.
5. **Opakování:** nejvýše dva náhradní pokusy za neplatný vzorek; pak série Nejasné a nový běh po opravě.
   Platné selhání zůstává selháním, opravená konstrukce dostává nový commit a běh. Bezpečnostní nález
   se uchová i tehdy, když jiná část měření byla neplatná.
6. **Publikace:** kontrola obsahu před commitem; `who`, procesní cesty i `state/` mohou obsahovat osobní
   metadata. Nepublikovat surové systémové snapshoty bez kontroly. Anonymizace nesmí vymazat důkaz;
   chybějící ověřitelný podklad se otevřeně označí. Žádná skutečná tajemství ani účty v automatických testech.

**Statistika LAB-v1:** p95 = seřazený vzorek na pozici `ceil(0,95 × n)` (pozice od 1); medián = stejný
nearest-rank postup s 0,5, shodný se sondou. Uvést n, minimum, medián, p95, maximum a každý neúspěch.
Nekombinovat stroje, oblasti, cold/warm, cache ani konstrukce keeper/bez keeperu. p95 z 10 opakování je
maximum; z 30 je 29. hodnota. Jde o empirické akceptační statistiky, ne odhad 95% spolehlivosti produktu.
Snímky a sekundové vzorky jednoho běhu nejsou nezávislá opakování. Nesmí se průměrovat p95 z různých běhů.
Nejistota přístroje se přičte k horním časovým mezím; pokud pak mez není prokazatelně splněná, je Nejasné.

**Rozhodnutí:** Prošlo pouze při splnění všech povinných případů, prahů, platnosti, závislostí a review.
Jediné prokázané porušení invariantu R2/R3 = Neprošlo, i kdyby šlo o jediný bajt nebo přechodné okno.
Čas reakce hlídače není náhradou nulového úniku. Chybějící podklad = Nejasné; neprovedený případ = Neověřeno.
Povinný případ nelze označit N/A kvůli chybějící aplikaci. Podmíněný GUI-13 může být nepoužitý jen s důkazem
GUI-02 bez keeperu; v záznamu GUI-13 pak výslovně doložit, proč konstrukce keeper nepotřebuje.

## 4. S1: workloady a uspořádání

Ve všech hlavních blocích existují tři různé relace se třemi audit sessions vedle aktivní host konzole.
Pevné pořadí profilů: W0 → W1 → WX → WA → WE → WS → WM; pořadí UID v opakovaných měřeních cyklicky
1-2-3, 2-3-1, 3-1-2. Uvést přesné verze aplikací, SDK/OS obrazy, projekty a SHA-256 fixtures.
Vše lokální, bez Apple ID/OAuth a skutečných projektů. Instalace/stahování mají vlastní uživatelský souhlas.

| Profil | Obsah každé ze tří oblastí | Délka a opakování |
|---|---|---|
| W0 holá relace | Dock/Finder, bez vývojových aplikací. Nutný klient/keeper běží v registrovaném režimu. | 5 min ustálení + 10 min RAM; celá série 3× po samostatném loginu. |
| W1 render | Jedno okno Metal sondy 960 × 600 bodů v každé oblasti, nezakryté. Host kontrolní okno průběžně renderuje. | 5 s zahřátí mimo výsledek + 10 souběžných bloků po 60 s; navíc párový offscreen test §7. |
| WX | Xcode: lokální šablona aplikace, build a spuštění v Simulatoru, měnící se syntetický obsah. | 3× start/build/run v každé oblasti, pak 10 min běžícího zobrazení ve všech třech. |
| WA | Android Studio + stejný připravený emulátor a lokální testovací appka, stejné AVD RAM/GPU nastavení. | 3× start/run v každé oblasti, pak 10 min animace ve všech třech. |
| WE / WS | Electron / Safari, lokální `webgl-check.html`, stejné okno a drawing buffer. | Každá aplikace 3× start v každé oblasti; 10 min provozu, WebGL kontrolu opakovat na začátku a konci. |
| WM smíšený | Oblast 1: Xcode + Simulator; 2: Android Studio + emulátor; 3: Electron + Safari (obě okna viditelná). | 3× 10 min, při každém bloku rotovat role, aby každý UID nesl každý workload. |

Zátěž aplikací je test funkčnosti a akcelerace, nikoli ještě benchmark rychlosti buildů. Každá musí
vykonat plánovanou práci, renderovat měnící se obsah, přijmout vstup a neztratit relaci; doplnit dostupný
renderer/backend a procesní důkaz. Samotný název GPU, existence procesu ani `requestAnimationFrame` callback
nedokazují, že bylo okno prezentováno. Syntetický podklad záznamu musí zachytit skutečný výstup aplikace.
Pro WX potvrdit CoreSimulatorService pod UID příslušné oblasti, pro WA proces emulátoru a akcelerovaný backend.
Chybějící SDK/obraz/Electron = neprovedený povinný test, nikoli pass. Nehromadit všechny IDE ve všech
oblastech současně: WM definuje smíšenou zátěž, WX/WA ověřují i tři souběžné instance téhož nástroje.

Host po celou dobu provozuje stejné kontrolní syntetické okno; nejméně každých 30 s doložit reakci
na předem určenou lokální akci (např. změnu markeru). Žádné přepnutí konzole, zamrznutí, odhlášení
nebo neodpovězená akce; návrh pomocného limitu odezvy hosta je ≤ 1 s. Nejde o S2 input-to-photon.
Při automatizaci/monitorování musí být zaznamenaná její režie a stejné podmínky u reference.

GUI-02: **3× nepřerušených 600 s** se všemi třemi klienty odpojenými, host konzole živá; kontinuita
domén/procesů se sleduje po celou dobu, prezentace před, během a po odpojení. Pozdní jednorázová sonda
neprokáže, že relace mezitím nezanikla a nevznikla znovu. ID session se nesmí změnit.
Keeper/fallback s trvale připojeným klientem je samostatná série s vlastní spotřebou a konfigurací;
3× kontrolovaně ukončit klienta/keeper a zaznamenat přežití, obnovu a ztrátu rozpracovaného stavu.
Selhání bez keeperu se zachová. F0.6 dovoluje samostatnou plochu, ale neobchází nemožnost souběžných
akcelerovaných relací; závislost na klientovi se v závěru výslovně uvede.

## 5. Login, first-run, warm a resume (GUI-12)

- **First-run:** úplně první login nově vytvořeného účtu včetně průvodců, přípravy home a TCC.
  1× pro každý UID, uvést automatický čas a čekání na člověka zvlášť; nepatří do cold/warm statistiky.
- **Cold:** profil již připravený; první login této oblasti po restartu Macu, předem neběží její GUI/user
  procesy. Nemazat svévolně systémové cache ani nepoužívat `purge`. 10 cyklů restartu, každý poskytne
  1 vzorek každého UID; pořadí UID rotovat a u každého vzorku uvést pořadí i počet již aktivních oblastí.
  Start prvního uživatele po rebootu není vydáván za start vedle dvou aktivních relací.
  Vypnout Sdílení obrazovky před rebootem a obnovit ověřenou
  ochranu portů před jeho zapnutím (S1 anchor není persistentní). Boot hosta sám není součást login času.
- **Warm login:** řízené odhlášení a nové přihlášení připraveného profilu bez rebootu, zaznamenat zbylé
  `user/<uid>` procesy a stav cache. 30 vzorků na UID při ostatních dvou aktivních oblastech.
- **Resume:** obnovení skutečně pozastavené existující oblasti; 30 vzorků na UID v samostatném profilu.
  Reconnect ke stále běžící relaci je **reconnect**, ne resume ani warm login. S1 dnes nemá mechanismus
  bezpečné pauzy; resume/POS-05/PERF-03 se tím nevykazují. Pause aplikací < 100 ms nenahrazuje S0 quiescence.

`start` je potvrzení připraveného přihlašovacího požadavku (poslední potvrzení credentials, bez času jejich
psaní); `ready` je první kompletní interaktivní frame plochy oblasti, doložený předem určenou reakcí UI
a platným kontextem relace. Zvlášť zaznamenat mezníky navázání klienta, Dock/Finder a první frame.
Pro F2 se start předefinuje na příkaz Zapnout včetně přípravy ochran; výsledky S1 se na něj nepřenášejí.
Po 60 s bez ready zaznamenat timeout a selhání cíle, nikoli vyřadit vzorek. Nikdy nepočítat dobu ručního
spouštění sondy jako čas dokončení loginu bez uvedení této nejistoty.

Časování musí mít pro < 2 s cíl doloženou nejistotu nejvýše 10 ms (časované UI události/záznam syntetického
výstupu s dostatečnou frekvencí a kalibrací). Sekundový polling `observe.sh` má navíc režii příkazů,
takže tuto akceptaci nedokazuje. Stejné start/ready pravidlo a recorder platí pro všechny vzorky.

## 6. RAM a sdílené služby (GUI-12)

**Rozhodující je systémový přírůstek pro celou konstrukci**, nikoli součet RSS. Zaznamenat po 1 s
skutečné časy, `hw.memsize`, velikost stránky, `HOST_VM_INFO64.free_count`, použitý swap a stav memory
pressure. Definice LAB-v1: `M(t) = hw.memsize − pageSize × free_count(t)`. Tento konzervativní ukazatel
obsazené fyzické paměti zahrnuje i cache, jádro, klienty, GPU alokace a WindowServer; není totéž co
„Memory Used“ v Activity Monitoru ani čistá paměť aplikací. Speculative stránky jsou ve `free_count`
již zahrnuté — znovu je neodečítat; komprimovanou logickou velikost ani swap k M nepřičítat.
Přístroj musí číst stejnou metriku před/během/po; nenahrazovat ji beze změny metodiky jiným údajem.

Pro W0: 5 min host baseline bez oblastí, klientů a keeperů → 5 min ustálení všech tří → 10 min měření
→ úklid relací/klientů → 5 min host baseline. Referenční host aplikace/recorder zůstávají stejné.
`B = min(medián M před, medián M po)`; `ΔM(t) = M(t) − B`. Záporné hodnoty se zachovají a vyšetří,
neberou se jako úspora. Liší-li se baseline mediány o více než 512 MiB nebo chybí vzorek déle než 2 s,
RAM série je Nejasné (drift/záznam), ne automaticky úspěšná. Platí `p95(ΔM) ≤ 4,5 GiB` pro každou
ze tří sérií. `ΔM / 3` se smí popsat pouze jako **amortizovaný** náklad; není to přesná paměť každé relace.

Diagnosticky zaznamenat `phys_footprint` všech procesů jednotlivých UID a relevantních WindowServerů,
klientů/keeperů v samostatné tabulce PID + čas vzniku + role. Každý proces započítat nejvýše jednou;
sdílený WindowServer nelze přičíst třikrát. Nelze-li jeho vazbu na relaci doložit, uvést jej jako sdílený.
Součty per-process footprint nejsou unikátní fyzické stránky a **nesčítají se s ΔM**. RSS z `observe.sh`
se nesmí přičítat k `phys_footprint`. Chybějící/nečitelný proces znamená neúplnou atribuci, ne nulovou RAM.

U W1/WX/WA/WE/WS/WM uvést systémové M, footprint rozpad, medián/p95/max, memory pressure a swap před/po
každém 10min bloku. Pro P4 je přírůstek swapu `max(0, usedSwapEnd − usedSwapStart) ≤ 1 GiB` a všechny
vzorky pressure musí být normální. Samotné M zahrnuje i cache; pro zátěž se hodnotí pressure a swap,
zatímco M a jeho rozdělení zůstávají diagnostickým údajem.
Úplnost sběru a odezva hosta se vyžadují i zde. Tyto limity nedokazují izolaci zdrojů ani odolnost proti DoS.

## 7. GPU a prezentace (GUI-05)

**Offscreen:** stejná binárka a zařízení, 2048 × 2048, 512 iterací/pixel, 60 snímků, ověření 4096 pixelů
posledního snímku proti CPU referenci. Všechny časy musí být konečné a kladné, neshod 0, žádné chyby sekce.
Deset párových bloků pro každý UID: host před → oblast → host po. Jedna těžká offscreen práce najednou,
všechny tři relace po celou dobu aktivní se stejnou lehkou zátěží, pořadí UID rotuje. Poměr bloku =
medián GPU času oblasti / průměr mediánů host před a po. Rozdíl host referencí > 10 % jejich průměru
zneplatní pár pro nestabilní baseline, s raw a limitem náhrad dle §3. Vyhodnotit medián ≤ 1,25 a p95 ≤ 1,50
z 10 poměrů **každé** oblasti. Uvést i p95 GPU časů a wall time. Nesrovnávat tři zatížené oblasti
s jedinou nezatíženou host úlohou; souběžná prezentace je jiný profil W1.

**Prezentace:** měřit 10 nepřekrývajících se 60s bloků společné fáze všech tří relací po 5 s zahřátí,
udržet stejnou velikost okna/škálu. Uchovat jednotlivé časy skutečně prezentovaných snímků, start/end,
submitted, timeouts a viditelnost alespoň každých 5 s. Pro každý blok/oblast počítat:

- fps = počet prezentací v pevném okně / 60 s (ne počet odeslaných drawable);
- intervaly mezi po sobě jdoucími prezentacemi včetně mezer od začátku a do konce okna;
- medián/p95/max mezer; `T = 1000/60 ms`, odhad vynechaných slotů
  `D = Σ max(0, floor(mezera/T + 0,5) − 1)`, podíl `D / (N + D)`, kde N je počet prezentací;
- počet sekund bez snímku, počet timeouts a neprezentovaných snímků. Hraniční neúplný interval má
  nejistotu nejvýše jednoho slotu; pro rozhodnutí použít nepříznivou mez, nikoli zaokrouhlení k pass.

Každý blok musí splnit P5, včetně nejdelší mezery a ≤ 5 % vynechaných slotů. 60Hz cíle platí i na rychlejším
displeji; 120 Hz není podmínka. Tato metrika dokládá kompozici v relaci, **nikoli** fyzický photon na monitoru
hosta, latenci přenosu přes RFB nebo S2. `windowVisible` jednou uprostřed a `presentedTime > 0` nestačí
k vyloučení všech zakrytí/uspání/výpadků. Neznámá frekvence virtuálního displeje (`0`) se uvede jako neznámá,
ne jako 60 Hz; cílových 60 fps musí prokázat časová řada. WebGL rAF je pouze podpůrný signál, ne tento oracle.

## 8. Připravenost A2 a mapování S1

**A2 zatím není připravené ke kompletnímu akceptačnímu běhu.** Následující mezery se musí zavřít před
stavem slotu připraveno; nejde o runtime změny dodané WP0.5. Lze předem registrovat dílčí diagnostický
běh, ale nesmí být označen za kompletní bránu S1.

| Důkaz / případ | Co již existuje | Co ještě vyžaduje L1 |
|---|---|---|
| GUI-01/03/04 | Identita/session, pozorování domén, forwarder, standardní přihlášení | Tři různé relace + host ve společném okně; zaznamenat limit HP samostatným pokusem bez narušení standardní série. |
| GUI-02/13 | Watch procesů a krátká prezentace | 3×600 s kontinuita s odpovídajícími časovými řadami; případný keeper samostatně, včetně pádu a režie. |
| GUI-05 | Offscreen výpočet a souhrn prezentace | Sběr časů jednotlivých prezentací, hranic fází a viditelnosti. Dnešní JSON má jediný timestamp před prací a jen souhrn; nelze z něj dopočítat max gap, podíl výpadků ani souběh fází. |
| GUI-06…09 | Návod a 5s WebGL stránka | Stejné aplikace/fixtures ve všech třech relacích, skutečný výstup a akcelerace podle §4; WebGL callback není důkaz prezentace. |
| GUI-10 | Vyvolání Screen Recording a preflight | Prompt a udělení uživatelem v **každé** relaci, 3× odpojení/znovupřipojení se zachovaným grantem a správnou identitou. To nedokazuje S8 stabilní podpis. |
| GUI-11 | Očekávání v `run-probe.sh`, kontrola sondou | Pevné očekávání i pro host/ruční TCC měření, log kontextu před každou fází; žádné měření s `valid: null`. |
| GUI-12 čas | Sekundové `observe.sh` | Kalibrovaný recorder start/ready podle §5; watch lze použít jako podpůrný důkaz, ne k < 2 s. |
| GUI-12 RAM | Jednorázový footprint UID před zátěží, včetně samotné sondy; RSS a počet WindowServerů ve watch | Systémový sběrač podle §6, baseline a unikátní atribuce procesů. Dnešní sonda není idle monitor a opakované spouštění samo přidává GPU zátěž. |

Manuální záznam může doložit prompt, přihlášení, přežití a akci aplikace, pokud obsahuje jen syntetická
data a má doložený čas. Pro jemné frame intervaly a RAM je potřeba skutečný sběrač; lidský odhad nestačí.
Před paralelním voláním `run-probe.sh` oddělit výstupy per UID a zajistit sériovou instalaci téže binárky:
současný skript instaluje na společnou cestu a připojuje JSON do společného souboru. Starty z několika
terminálů samy o sobě nezaručují překryv krátké offscreen fáze. Konkrétní orchestraci a instrumentaci
musí doplnit příprava A2, s ověřením recorderu na známém syntetickém výsledku.

Po běhu reviewer kontroluje každý GUI-01…13, konfiguraci, raw a použitelnost fallbacku vůči F0.6.
Zápis do [spikes.md](spikes.md) a [COVERAGE.md](COVERAGE.md) přijde až po skutečném výsledku;
WP0.5 nemění žádný stav testu, brány ani požadavku.

## 9. Další brány: co metodika pokrývá a co zbývá

Společná pravidla §2–3 platí všude. Tabulka je požadavek na jejich budoucí předregistraci, **není**
prohlášení připravenosti L2–L8. Žádná konečná délka testu nenahrazuje mechanismus ochrany R2/R3.

| Brána / případy | Předem určit a následně doložit |
|---|---|
| S0/S4/S8 — FS/ID/LC/RB/SG | Matice všech operací a lifecycle stavů z PLAN/COVERAGE, kanárky, správný kontext a pozitivní kontrola každé cesty. Návrh minimálně 3 opakování každého deterministického přechodu; races 10 min nepřetržité sondy a ≥100 vyvolaných přechodů. Každý přístup fail; nepokrytý mechanismus Nejasné. Fuzzing potřebuje vlastní corpus/seed/budget/coverage, počet opakování jej nenahrazuje. Reálné Klíčenky/TCC až oddělený uživatelský integrační důkaz. |
| S3/S3b/S7 síť — NET/DK/PERF-02 | Každý směr, IPv4/IPv6, nové i existující toky, resolver, buffery, staré states, revokace a každý failure mode samostatně. Návrh ≥3 běhy na buňku, 60 s před poruchou + 600 s během/po ní; nepřetržité pokusy a nezávislý záchyt. Doba dočtení nejméně 60 s a zároveň delší než předem zdokumentovaný nejdelší retry/timeout + 2× RTT; neznámá horní mez = neúplný oracle. Nulové zakázané bajty/kontakty dle případu; známý únik vždy fail. |
| Protistrana WP0.4 | `started`/`stopped`, úplnost toků, pozitivní kontrola před/po, identifikace zdrojů. Listener nevidí všechny pakety; ICMP/handshaky potřebují záchyt na protistraně, TLS neprokazuje obsah bez vhodného zakončení. Zero-byte TCP kontakt posoudit podle předregistrované zakázané operace. |
| S5 — GW-20, PERF-01 | Návrh 30 párových běhů native/gateway pro **každý** pevný fixture workload a cold/warm cache odděleně, pořadí AB/BA; p95 poměrů časů ≤1,10. Stejný UID, obsah, síťová cesta kromě brány a stav cache, žádné smíchání různých balíčků. Definovat cache klienta/brány/upstreamu a konec úlohy; warmup mimo vzorek. Mock `npm pack` není důkaz skutečného `npm install`. Před L5 chybí přesné workloady, integrační cesta a schválené příkazy; bezpečnostní případy GW zůstávají povinné. |
| S6 — HB-01…07 | Zmrazit konkrétní top-200 seznam, zdroj/datum pořadí, verze, bottle platformu a SHA; uvést každou formuli (bottle/kompilace/nepodpora/selhání), dobu/zdroje a předem vybraný vzorek `brew test`. Žádné procento ani náhodný vzorek nenahrazuje povinnou kompatibilitu, cooldown metadata a nulové změny host prefixu. |
| S2/F3 — GUI-14…24 | Návrh input-to-photon: medián ≤30 ms, p95 ≤50 ms; ≥200 vstupů na oblast a interakční třídu ve 3 blocích ≥60 s, společný souběh tří oblastí, 60fps časové řady. Kalibrované měření fyzického vstupu a odpovídajícího pixelu se známou nejistotou; RFB/SCK timestamp sám není photon. Před L7 chybí recorder, fixture interakcí, supported subset a konkrétní display/stream profily. |
| F2 — POS-05/PERF-03; S7 DK-10 | Produkční start včetně ochran, cold/warm/resume odděleně; app pause <100 ms oddělit od bezpečného quiescence celého UID. Docker cold start / warm start / idle stop mají vlastní definici start/end, workload, 30 opakování a **dosud neurčený** budget rozhodnutý před S7. |

Tyto rozšiřující návrhy se při přípravě konkrétní brány doplní a zafixují před měřením. Nezávislý
mock/fixture vývoj může pokračovat; závislá integrace čeká na své brány podle IMPLEMENTATION.md.
