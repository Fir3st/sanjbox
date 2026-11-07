# S3b — návrh bind policy

**Stav: specifikace k review. Nic v tomto dokumentu není ověřené, nainstalované ani změřené.**
S3b, NET-10…12, R2 a R3 zůstávají **Neověřeno**. Dokument neobsahuje spustitelný příkaz, žádné
pf pravidlo vydávané za řešení, žádnou změnu systému a žádnou změnu PLAN.md ani `Contracts/`.
Důkaz, který by tento návrh posunul, vzniká až v uživatelském L4 podle [LABPLAN.md](LABPLAN.md)
a [L4-RUNBOOK.md](../L4-RUNBOOK.md).

**Rozhodnutí orchestrátora — stav balíku:** WP1.C3 je **hotový balík** ve chvíli, kdy je návrh
bind policy zapsaný. Podle [IMPLEMENTATION §0](../../../docs/IMPLEMENTATION.md) (řádek WP1.C3)
je hotovo, až je „Návrh bind policy zapsaný; další offline provenance, zbytek je L4“. Vynucení
mechanismu a verdikt proto patří balíku **WP1.C4/L4**, ne C3; tento dokument nikde netvrdí
„C3 zůstává partial“ a neposouvá hranici balíku jinam.

Vztah k ostatním dokumentům: invariant je v [PLAN §4 Síť](../../../PLAN.md) („oblast komunikuje
jen schválenými operacemi brány, izolovaným same-zone loopbackem a výslovně řízeným vstupem“),
scénáře v [LABPLAN.md](LABPLAN.md), mezery offline adapteru v [ADAPTER.md](ADAPTER.md),
nezávislá ochrana v [C2 rešerši](../research/wp1-c2-pf-independent/RESEARCH.md).

---

## 1. Problém a proč je dnes volba binární

### 1.1 Co dnes chybí

Oblast je sada procesů pod vyhrazeným UID. Egress filtr umí rozhodovat o provozu, který oblast
**vysílá**. Ingress — provoz, který někdo **navazuje na listener uvnitř oblasti** — egress filtr
neovlivní: paket na `lo0` nebo na LAN adresu hosta nevzniká v oblasti, takže se na něj `user`
podmínka vztáhnout nemůže.

**Odvozeno / hypotéza (GUIDE §7), nikoli pozorování:** [PLAN §4 Síť](../../../PLAN.md) tuto otázku
výslovně nechává „není uzavřená“ a změřený výsledek nikde neuvádí; následující tvrzení je odvozeno
z egress sémantiky pf `user` a z chybějícího ingress pravidla, ne z měření. Odvozená hypotéza zní,
že oblast si dnes může otevřít listener na `0.0.0.0`/`::` a být dosažitelná z hosta i z LAN, aniž
by to jakékoli existující pravidlo zachytilo. To je mezera, kterou má S3b uzavřít. [C2 RESEARCH §2](../research/wp1-c2-pf-independent/RESEARCH.md)
však jako incoming policy uvádí **ALF** (Application Layer Firewall) — kandidáta, který by tuto
hypotézu mohl vyvrátit (M12 níže). Dokud ALF není změřen, zůstává hypotéza otevřená, ne potvrzená.

### 1.2 Binární volba same-zone loopbacku

Pro same-zone loopback (devserver v oblasti, klient ve stejné oblasti přes `127.0.0.1:P`) platí
totéž omezení z druhé strany:

- Pokud pravidlo **povolí** spojení na `127.0.0.1:P`, povolí je i hostovi. Na `lo0` není v paketu
  nic, co by rozlišilo „klient je ze stejné oblasti“ od „klient je host“; rozhoduje cílová adresa
  a port, ne vlastník listeneru ani vlastník klienta.
- Pokud pravidlo spojení na `127.0.0.1:P` **zakáže**, přestane fungovat i povolený same-zone
  devserver. To je regres proti R3/R7 a proti kompatibilitě nástrojů (R8).

Bez politiky, která omezí **bind**, tedy neexistuje třetí stav: buď je same-zone loopback otevřený
i hostovi, nebo je zavřený i oblasti. Rozhoduje o tom enforcement, ne dokumentace. Odstavec
v PLAN.md „Bez bind policy je to binární volba“ tím zůstává v platnosti.

### 1.3 Atribuce listeneru není vyřešená ani u pf

[LABPLAN.md](LABPLAN.md) správně neopakuje historické tvrzení o `pf user` jako absolutní vlastnost
kernelu: připnutý XNU má při hledání socketu i wildcard PCB lookup, takže chování ingress atribuce
na konkrétním macOS a transportu **musí být změřeno**, ne odvozeno. Současně platí, že i kdyby
wildcard listener byl přiřaditelný, zůstávají u pf tři strukturální meze: je jen pro TCP/UDP,
je to jeden globální ruleset (flush/disable/state lifecycle je jiný životní cyklus než revokace
oblasti) a nemá per-oblast oddělení, které by přežilo vypnutí PF. Test pf atribuce je proto
**jen měřená hypotéza** (M10 níže), nikoli předpoklad tohoto návrhu.

### 1.4 Port squatting je jiná otázka než ingress

Port squatting není „kdo se dostane dovnitř“, ale „kdo obsadí endpoint, který host očekává“.
Bind předchází každé kontrole, kterou by šlo udělat po něm. Rezervace v UI, zápis do konfigurace
nebo kontrola před spuštěním serveru nejsou vlastnická hranice — user-level kód otevře socket
přímo. Požadavek je proto na **vlastníka endpointu v okamžiku vzniku socketu**, ne na pořadí kroků
v aplikaci.

### 1.5 Co by politika musela splnit, aby otázku vůbec řešila

Uplatněná **před** `socket`/`bind`, nikoli mezi startem a kontrolou; platná při startu, revokaci,
pádu helperu/brány, sleep/wake a změně VPN/rozhraní; fail-closed při konfliktu; a doložená
nezávislým oracle na protistraně, ne logem oblasti. Dnes žádný takový mechanismus ověřený není
a [LABPLAN.md](LABPLAN.md) to říká výslovně: „Vynucovací mechanismus tohoto návrhu chybí.“

---

## 2. Kandidátní vynucovací mechanismy

**Žádný z řádků níže není prohlášen za fungující.** U každého je uvedeno, co podklady dokládají,
kde je mezera (start / revokace / pád helperu / sleep-wake / VPN) a co by ho vyvrátilo. Odkazy
na veřejné podklady a jejich omezení jsou v [C2 RESEARCH §2](../research/wp1-c2-pf-independent/RESEARCH.md);
tvrzení o „dokumentovaném“ chování znamená „v prozkoumaných veřejných podkladech“, nikoli měření
na macOS 27.

| # | Mechanismus | Co by vynutil (dle podkladů) | Mezera: start / revokace / pád helperu / sleep-wake / VPN | Co by ho vyvrátilo |
|---|---|---|---|---|
| M1 | App Sandbox: entitlement client/server + profil | Omezení sandboxovaného procesu a jeho přímých potomků; `network.server` existuje | Start: není doložena per-UID instalace pro **všechny** starty oblasti a systémové služby. Revokace: zastavení/restart procesu, ne uzavření již otevřeného listeneru. Pád brokeru: děti bez politiky. Sleep-wake/VPN: nové starty bez profilu. Address/port scope `network.server` není v prozkoumaných podkladech doložen | Sandboxovaný proces bindne `0.0.0.0`/`::` a host i LAN ho dosáhne; nebo same-zone listener je dosažitelný z hosta |
| M2 | Seatbelt / custom SBPL s bind allowlistem (local ip/port) | **Hypotéza bez zdroje:** filtr na bind adresu/port uvnitř profilu a wrapper aplikující profil před `exec` nejsou v prozkoumaných podkladech doloženy; [C2 RESEARCH](../research/wp1-c2-pf-independent/RESEARCH.md) řadí bind/ingress mezi chybějící schopnosti Seatbeltu | Start: `sandbox-exec` je deprecated, veřejné `sandbox_init` nepodporované → není stabilní kontrakt. Pokrytí dědiců, `exec`, launchd startů a family forem není doloženo. Revokace: zavřený jen nový bind, starý listener žije. Pád helperu: profil drží proces, ale helper nemůže politiku měnit. Sleep-wake/VPN: nové procesy mimo wrapper | Proces s allowlistem bindne adresu/port mimo seznam, nebo wildcard; nebo port z allowlistu je dosažitelný z hosta |
| M3 | Host-owned listen proxy + zákaz vlastního bindu v oblasti | Port drží hostem vlastněný proces, oblast dostane fd nebo jen broker kanál; wildcard ingress v oblasti nevzniká | Start: fd předaný při startu obchází pozdější kontrolu (fd transfer, `dup`, `fork`). Bez M1/M2/M5 oblast bindne sama. Revokace: již předaný fd zůstává. Pád proxy: fail-closed jen když to klient doloží. Sleep-wake/VPN: proxy musí revalidovat adresy. Kompatibilita: mění, na jaký `HOST:PORT` nástroje v oblasti míří (R1/R8) | Oblast otevře vlastní socket mimo proxy; nebo proxy po pádu nechá starý fd obsluhovat; nebo se povolený devserver nerozběhne |
| M4 | Per-zone adresa (alias `127.0.0.x`, dedikovaná LAN/ULA adresa) + bind allowlist | Oddělí adresy, na kterých kdo listenuje; same-zone klient míří na vlastní adresu | Start: alias sám o sobě nic nevynutí — wildcard bind je dosažitelný přes všechny adresy. Revokace: alias zůstává. Pád helperu: politika vázaná na adresu vydrží jen s M2/M5. Sleep-wake/VPN: adresa se může změnit/zmizet. Kompatibilita: nástroje s hardcoded `127.0.0.1` přestanou fungovat | Wildcard bind je dosažitelný přes jakoukoli adresu; nebo nástroj v oblasti na `127.0.0.1` nefunguje |
| M5 | MAC framework / socket filter (XNU hooky pro bind/connect/send) | Kernelový hook existuje; teoreticky bind gate | Start/revokace by byly správné, ale: není veřejná userspace per-zone policy; Apple Silicon KEXT cesta vyžaduje Reduced Security, approval a reboot → rozsah **čeká na Q5** (§6); podpis/deployment nedoložen | Bez změny boot policy neexistuje instalovatelná podepsaná cesta; nebo by šlo jen s vypnutou System Integrity Protection |
| M6 | Privátní NECP policy | Čtený zdroj umí policy podle UID i zprostředkované identity | Otevření policy session kontroluje platformový podpis a privilegium; root nestačí. Interní možnosti jádra nejsou veřejné API | Platformově nepodepsaný proces policy session neotevře; nebo API není dokumentované |
| M7 | Network Extension (content/packet filter) | Apple doporučená cesta pro síťové filtry | **Vyloučeno** F0.5/D-002 (žádný placený Developer Program). Navíc: per-UID atribuce listeneru a fail-closed při pádu rozšíření nejsou doložené | Vyloučení platí, dokud trvá D-002. Zpět do hry by ho vrátil pozorovatelný jev: veřejná (nepodepsaná placeným programem) cesta k content/packet filtru na macOS 27, nebo změřený per-UID ingress filtr bez Developer Programu — pak by se D-002 muselo znovu rozhodnout, ne obejít |
| M8 | Endpoint Security authorization | Autorizační události; macOS 27 descendants klient | **Vyloučeno** D-002; v prozkoumaném enumu není IP bind/packet authorization. Entitlement i tak vyžaduje placený program | Vyloučení platí pro prozkoumaný enum. Zpět do hry by ho vrátil pozorovatelný jev: veřejně dokumentovaná IP bind/packet authorization událost v SDK 27 a současně cesta k entitlementu bez placeného programu — jinak zůstává vyloučeno |
| M9 | launchd socket activation + hostem držená rezervace | **Hypotéza bez zdroje:** že launchd aktivace předá oblasti jen aktivovaný fd a jinak endpoint drží host, není v prozkoumaných podkladech doloženo; zdroj chybí | Je to **rezervace, ne bind policy**: user-level kód v oblasti otevře socket přímo. Revokace: aktivovaný fd přežívá. Pád: rezervace může zůstat viset. Sleep-wake: aktivace po wake neopakuje kontrolu | Oblast bindne rezervovaný port sama; nebo rezervace nepřežije zavření host služby |
| M10 | pf ingress atribuce (jen jako měřená hypotéza) | Místní `pf.conf(5)` uvádí `user` i pro naslouchajícího uživatele; XNU má wildcard PCB lookup | Jen TCP/UDP; jeden globální ruleset; flush/disable/state je jiný životní cyklus, než revokace oblasti; credentials socketu, ne aktuální EUID. Sleep-wake/VPN: nové sockety bez nové evaluace | Wildcard listener je z hosta/LAN dosažitelný i s deny pravidlem; nebo atribuce závisí na rodině/reuse variantě |
| M11 | Oddělený network namespace / VM | Úplné oddělení adresního prostoru | macOS nemá veřejné netns; VM je odmítnutá (F0.6) | **Netestovatelné v rozsahu projektu**, protože macOS nemá veřejné netns a VM je vyloučená F0.6; falsifikátor by byl jen veřejný netns ekvivalent pro macOS nebo zrušení F0.6 uživatelem. Do té doby se netestuje |
| M12 | ALF / Application Layer Firewall (incoming policy) | Dokumentovaná incoming/per-app policy a výjimky [S16, L9]; teoreticky by mohl odmítnout incoming spojení na oblast | Start: ALF je globální a per-app/path, ne per-UID ani per-oblast — mapování sady procesů oblasti na „app“ není doložené. Revokace: změna policy je globální stav, ne revokace oblasti; zavření existujícího listeneru není doložené. Pád helperu: policy drží systém, ale nemá per-oblast generaci. Sleep-wake/VPN: bez doložené revalidace. Loopback a vlastnictví portu (B4/B5) ALF nedokládá | Falsifikátor: doložený veřejný způsob, jak ALF rozhoduje incoming **per-oblast** (ne per-app), jak po revokaci zavře existující listener a jak odmítne host/LAN kontakt na wildcard listener oblasti nezávisle na bundle. Pokud by to doloženo bylo, vrací se do hry jako doplněk M3; zůstává-li jen globální per-app policy, strukturální skladbu nenahrazuje |

### 2.1 Co z toho plyne pro architekturu

Z **posouzené množiny M1–M12** je jediná **skladba**, která problém řeší strukturálně, M3
(host-owned proxy drží endpoint, oblast nikdy nelistenuje na host portu) **plus** enforcementský
zákaz vlastního bindu v oblasti (M1/M2/M5). ALF (M12) je v této množine posouzený a skladbu
nenahrazuje: dokládá globální per-app incoming policy, ne per-oblast rozhodnutí. Skladba není
ověřená; nedoložené jsou čtyři části: (a) sám zákaz vlastního bindu vynutitelný bez NE/ES/KEXTu,
(b) jeho platnost v pěti životních fázích B7, (c) fail-closed při pádu proxy (M3), (d) kompatibilita
nástrojů s `HOST:PORT` injektovaným hostem (R1/R8). M4 je doplněk (oddělení adres), ne náhrada zákazu.

Dokument proto **nedoporučuje** žádný mechanismus jako řešení. Pořadí, ve kterém je má smysl
falsifikovat, a odpovídající důkaz, patří do L4 plánu uživatele (§4).

---

## 3. Požadované vlastnosti politiky

Formulace je závazná pro budoucí implementaci a pro `Contracts/` (návrh, ne změna kontraktu).
Každá vlastnost musí být pozorovatelná zvenčí; „politika to zakazuje“ není důkaz.

### 3.1 Per-oblast

| ID | Vlastnost | Pozorovatelné kritérium |
|---|---|---|
| B1 | **Allowlist bindů**: pro každou oblast přesně vyjmenované `(family, address, port nebo rozsah)`. Výchozí stav je prázdný seznam. | Bind mimo seznam skončí chybou na straně oblasti a žádný accept na protistraně. |
| B2 | **Zákaz wildcard** `0.0.0.0`/`::` mimo výslovnou výjimku s uvedeným důvodem, rodinou a portem; výjimka je samostatně evidovaná a testovaná buňka, ne globální přepínač. | Wildcard buňka má vlastní řádek v předregistraci a vlastní oracle; nesplývá s loopback buňkou. |
| B3 | **Rodiny odděleně**: IPv4 a IPv6 (a `IPV6_V6ONLY` / v4-mapped varianta) mají vlastní allowlist i vlastní výsledek. | Jeden výsledek v4 nezastupuje v6; v4-mapped cesta je samostatná buňka. |
| B4 | **Same-zone loopback jen s doloženým oddělením listenerů**: povolen pouze tehdy, když politika skutečně zajistí, že host (a jiná oblast) na tentýž endpoint nedosáhne. | Současně: same-zone roundtrip projde **a** host/other-zone kontakt nepřijde. Jeden z těch dvou výsledků sám nestačí. |
| B5 | **Zákaz port squattingu** na host port: hostem vlastněný rezervující proces drží endpoint před startem oblasti a po celou dobu, kdy host služba nesmí být dostupná; oblast na rezervovaný port nesmí bindnout. | Bind oblasti na rezervovaný port selže; vlastník endpointu je nezávisle ověřen; rezervace je spojitá. |
| B6 | **Fail-closed při konfliktu**: nejednoznačné vlastnictví, nečitelná identita, neplatná generace politiky, výpadek rezervace nebo neznámý výsledek = listener se neotevře (a start oblasti se nezapočne jako úspěšný). Nikdy „povolit s varováním“, nikdy fallback na wildcard. | Konfliktní buňka končí odmítnutím, ne prázdným úspěchem; prázdný úspěch bez accept logu je Nejasné. |
| B7 | **Životní fáze**: politika platí před prvním `socket`, při revokaci (existující listenery zavřené nebo nedosažitelné), po pádu helperu/brány (žádná zděděná schopnost), po sleep/wake a po změně VPN/rozhraní (nový bind vyžaduje novou validaci). | Každá fáze má vlastní běh a vlastní oracle; návrat deny pravidel po poruše není pass. |
| B8 | **Pozorovatelnost**: rozhodnutí politiky se logují s generací, oblastí, rodinou, adresou, portem a výsledkem. Log je podpůrný, **není** oracle. | Verdict stojí na přijetí/nepřijetí na protistraně, ne na logu oblasti. |
| B9 | **Oblast nemá privilegovanou cestu**: politiku vlastní host; oblast ji nemůže měnit, obnovit ani obejít jiným startem. | Pokus oblasti o změnu politiky (nebo o start mimo ni) končí odmítnutím, ne tichým úspěchem. |
| B10 | **Kompatibilita**: povolený same-zone devserver a běžné nástroje v oblasti fungují beze změny jejich konfigurace, nebo je změna (`HOST`/`PORT` injektované hostem) výslovně přijatá jako změna kontraktu R1/R8. | Pozitivní buňka projde se stock nástrojem; pokud ne, je to blokátor, ne poznámka. |
| B11 | **Nezávislost na UID samotném**: všechny procesy oblasti mají stejné UID a host služby často také listenují na loopbacku; politika se nesmí opírat o UID, souborová práva ani filesystem mount policy. | Buňka, kde host i oblast mají stejný nebo nerozlišitelný kontext, musí být rozhodnutá politikou, ne shodou náhod. |

### 3.2 Datový model (návrh pro `Contracts/`, nerealizováno)

Pole, která musí politika umět vyjádřit, aby B1–B11 šla vůbec měřit. Tabulka **není** změna
`Contracts/`; formát síťové politiky patří do **WP1.H1** (`proto/contracts/`, viz
[IMPLEMENTATION §0](../../../docs/IMPLEMENTATION.md)), zatímco kořenový `Contracts/` je F2/WP2.0.

| Pole | Význam |
|---|---|
| `zoneID` | Identita oblasti, ke které se záznam vztahuje; žádný globální záznam. |
| `generation` | Monotónní generace politiky; stará generace po revokaci nesmí autorizovat nic. |
| `family` | `ipv4` / `ipv6` / `ipv6-v6only`; výchozí hodnota neexistuje. |
| `address` | Přesná adresa, nebo `wildcard` **jen** spolu s `exceptionReason`. |
| `portMin`/`portMax` | Přesný port nebo uzavřený rozsah; `0` (ephemeral) musí být výslovně povoleno, ne implicitní. |
| `direction` | `listen` (a odděleně `connect`, aby se egress a bind nepletly). |
| `reservationOwner` | Kdo endpoint drží před startem oblasti (`helper`, `launchd`, `agent`); povinné pro host porty. |
| `conflictAction` | Vždy `failClosed`; jiná hodnota je neplatná politika. |

---

## 4. Mapování na NET-10, NET-11, NET-12

Oracle je vždy **na protistraně** a nezávislý na oblasti: skutečný accept/bytes log
(common protistrana na jiném řízeném hostu/relaci/oblasti), samostatný target-side packet
capture s doloženými clocks/losses/intervaly a samostatné ověření vlastníka endpointu
(např. host-side kontrola, kdo port drží — nikoli tvrzení oblasti). Vlastní log oblasti
ani návratový kód nejsou verdikt. Buňky se nepočítají dohromady: `family × bind × směr`
je samostatný řádek předregistrace.

Práh a délky oken zde **nevymýšlím**; platí návrhy z [LABPLAN.md](LABPLAN.md) (nejméně 3 běhy
na buňku, 60 s před poruchou, 600 s během/po, drain alespoň 60 s a delší než retry upper bound
+ 2× RTT) až po schválení uživatelem.

### 4.1 NET-10 — ingress na listener oblasti z hosta, LAN a jiné oblasti

| Buňka | Co se měří (oracle) | Předregistrované očekávání pro L4 |
|---|---|---|
| Listener oblasti bind `127.0.0.1`, `::1`, `0.0.0.0`, `::`; vlastní přidělený port | Target-side packet capture + accept/bytes log protistrany + `getsockname`/`accept` záznam vlastního listeneru | Přesně **nula** packetů a **nula** acceptů od hosta, LAN a jiné oblasti na zakázaných buňkách. Povolená same-zone buňka doručí přesně předregistrovaný kanárek jen správné oblasti. Accept s 0 B je **finding**, ne pass. |
| Pozitivní kontrola před i po | Stejný oracle na záměrně přístupném syntetickém endpointu | Kontrola musí doručit všechny plánované bajty; bez ní je negativní výsledek Nejasné, ne pass. |
| LAN → listener | Klient míří na **předregistrovanou LAN adresu stroje** (ne na `localhost`), listener je vázaný jen na loopback | Doručení = finding. Neprovedená LAN buňka = missing, nikoli N/A ani pass. |
| IPv6 / v4-mapped | Vlastní buňka, `IPV6_V6ONLY` zaznamenáno | Samostatný výsledek; dual-stack se nepředpokládá. |

### 4.2 NET-11 — port squatting na host port

| Buňka | Co se měří (oracle) | Předregistrované očekávání pro L4 |
|---|---|---|
| Oblast zkouší bind na pevný předregistrovaný host port při držené rezervaci | Explicitní `bind`/`listen` výsledek a errno v oblasti **a** nezávisle ověřený vlastník endpointu **a** spojitost rezervace | Bind oblasti selže nebo port nezíská; jakékoli nabytí portu je finding. |
| Povolené uzavření host služby a její návrat | Vlastník endpointu v okně zavřeno/otevřeno, accept log host služby, úspěšný reclaim host controls | Během zavření port nezíská oblast; po návratu host služba funguje a drží port. Nabytí i v drainu je finding. |
| Ephemeral kolize | Instrumentální kontrola | Kolize efemérního portu **není** NET-11 a nesmí se vydávat za důkaz. |
| `SO_REUSEADDR`/`SO_REUSEPORT`, restart, dual-stack | Vlastník endpointu a bind výsledek pro každou variantu | Reuse ani restart nesmí změnit vlastníka; varianta bez vlastní buňky je missing. |

### 4.3 NET-12 — pozitivní same-zone dev server bez přístupu k cizím listenerům

| Buňka | Co se měří (oracle) | Předregistrované očekávání pro L4 |
|---|---|---|
| Dva odlišné procesy stejné oblasti provedou devserver roundtrip | Expected-counterpart handshake ve správném UID + audit/bootstrap kontextu, doručený kanárek oběma směry, receiver log, nezávislý capture | Roundtrip projde; same-process ani same-UID smoke se **nedosazuje**. |
| Současně cizí listenery | Host i jiná oblast mají vlastní listener a vlastní oracle; měří se kontakty **z** oblasti | Nula kontaktů na cizí listenery; zakázané listenery ověřeny nezávisle, ne z logu oblasti. |
| Souběh s NET-10 buňkami | Stejné okno, oddělené run/flow nonce | Pozitivní a negativní buňka se nesčítají; záměna nonce = neplatné měření. |

### 4.4 Co by který výsledek znamenal pro tento návrh

| Výsledek L4 | Důsledek pro bind policy |
|---|---|
| Nula zakázaných kontaktů **a** funkční pozitivní buňky | Kandidátní skladba přežila jeden scénář; zdaleka ne celý kontrakt (fáze B7, LAN, obě rodiny). |
| Jakýkoli zakázaný kontakt při platném měření | **Neprošlo** pro danou konfiguraci; blokátor R2/R3, ne residuum. |
| Neúplné capture, chybějící kontrola, nejasná identita | Nejasné / neplatné měření; nic se nezapisuje jako pass. |
| Chybějící buňka (IPv6, LAN, nástroj, oblast) | Missing → Neověřeno zůstává. |

### 4.5 Kam se zapisuje který fázový výsledek (B7)

B7 žádá oracle pro pět fází, ale S3b v [COVERAGE](../../../docs/COVERAGE.md) vlastní jen NET-10…12;
fázové případy jsou pod S3. Mapování je závazné, aby běh neskončil ve špatné bráně:

| Fáze B7 | Kde se měří | Řádek COVERAGE a brána | Poznámka |
|---|---|---|---|
| Start (politika platí před prvním `socket`) | Buňky §4.1–4.3; listener vzniká při startu | NET-10, NET-11, NET-12 — **S3b** | Start není samostatný případ; je to podmínka buňky. |
| Revokace (existující listenery zavřené nebo nedosažitelné) | Postup NET-25a/NET-26 v [L4-RUNBOOK](../L4-RUNBOOK.md) | NET-25, NET-26 — **S3** | Fázový výsledek patří do S3, ne do S3b. |
| Pád helperu/brány (žádná zděděná schopnost) | Postup NET-23a/NET-23b v [L4-RUNBOOK](../L4-RUNBOOK.md) | NET-23 — **S3** | Sem patří i ověření, že pád nenechá otevřený fd ani rezervaci. |
| Sleep/wake, VPN, změna sítě | Postup NET-24a/NET-24b v [L4-RUNBOOK](../L4-RUNBOOK.md) | NET-24 — **S3** | Nový bind po wake/VPN vyžaduje novou validaci; nepatří do NET-10…12. |
| Souběh fáze s pozitivní buňkou | §4.3 (dva procesy stejné oblasti) | NET-12 — **S3b** | Pozitivní same-zone důkaz zůstává v S3b, fázový důkaz v S3. |

Fázový výsledek se **nikdy** nezapisuje do NET-10…12 a výsledek bind buňky do NET-23/24/25/26.
Jeden řádek COVERAGE tak nemůže být uzavřen výsledkem z jiné brány.

---

## 5. Co tento dokument NEdokazuje

1. **Žádný mechanismus není ověřený.** M1–M12 jsou kandidáti; žádný nebyl spuštěn, nainstalován
   ani změřen. Tabulka „co by vynutil“ je tvrzení podkladů, ne pozorování.
2. **Není zde pf pravidlo ani skript.** Žádná změna systému, žádný slot LAB, žádná evidence.
   Nic z tohoto dokumentu není důkazní adresář podle GUIDE §7.
3. **Není dokázáno, že bind policy jde na macOS 27 vůbec vynutit** bez Network Extension,
   Endpoint Security nebo KEXTu. To zůstává otevřený blokátor C2 a S3b.
4. **Není dokázáno, že same-zone loopback lze oddělit** od host localhostu. Pokud ne, platí
   fail-closed varianta (same-zone loopback zakázán) a je to změna komfortu/kompatibility,
   kterou musí rozhodnout uživatel (§6).
5. **Není dokázáno nic o port squattingu** — rezervace, `launchd` aktivace ani UI nejsou
   vlastnická hranice; to je zde jen požadavek B5.
6. **Není dokázáno, že se tento návrh shoduje s PLAN.md.** Návrh se nepovyšuje na kontrakt;
   případná změna jde přes DECISIONS.md.
7. **S3b, NET-10…12, R2 a R3 zůstávají Neověřeno.** To není stav C3: balík WP1.C3 je hotový
   právě tím, že je tento návrh zapsaný ([IMPLEMENTATION §0](../../../docs/IMPLEMENTATION.md), řádek
   WP1.C3). Vynucení mechanismu a verdikt patří WP1.C4/L4 a jsou tam zatím otevřené.
8. **Není zde tvrzení o výkonu, kompatibilitě nástrojů ani o chování po sleep/wake či VPN**;
   ty patří do L4 běhů podle [L4-RUNBOOK.md](../L4-RUNBOOK.md).

---

## 6. Otevřené otázky pro uživatele

Rozhodnutí, která nejde udělat offline. Dokud nejsou rozhodnutá, S3b se neposouvá.

| # | Otázka | Proč to nejde offline | Co rozhodnutí blokuje |
|---|---|---|---|
| Q1 | Má oblast **vůbec** smět listenovat na host portu, nebo všechny host endpointy drží host-owned proxy (M3) a oblast dostane jen broker kanál? | Mění produktový kontrakt (R1/R8). Proxy varianta je bezpečnější, ale rozbíjí nástroje s hardcoded portem. | Volbu kandidáta pro L4 a podobu `Contracts/`. |
| Q2 | Je přijatelné, aby same-zone loopback byl **zakázaný**, dokud se neprokáže oddělení listenerů (fail-closed default, B4/B6)? | Je to komfortní regrese pro devservery; PLAN to pripouští, ale rozhodnutí je produktové. | Start oblasti a akceptaci NET-12. |
| Q3 | Smí se povolený devserver v oblasti odkázat na injektované `HOST`/`PORT` (a je to změna kontraktu R1/R8)? | Mění chování nástrojů a dokumentaci pro uživatele. | B10 a všechny pozitivní buňky. |
| Q4 | Které mechanismy se smějí v L4 **experimentálně** zkusit, i když nejsou podporované API (custom SBPL / Seatbelt)? A je přípustné, že shipping cesta pak vyžaduje změnu kontraktu? | Vyžaduje tvůj souhlas s rizikem a s nepodporovaným API; D-002 vylučuje NE/ES. | Rozsah L4 a důkazní hodnotu výsledku. |
| Q5 | Je Reduced Security / KEXT cesta (M5) úplně mimo zadání, nebo smí být prozkoumána na vyhrazeném Macu? | Vyžaduje změnu boot policy a fyzický přístup; nemá to dělat agent. | Zda M5 zůstává jen v tabulce, nebo se falsifikuje. |
| Q6 | Kdo je budoucí `reservationOwner` host portů (`helper`, `launchd`, `agent`) a jak široký je statický seznam host portů, které musí zůstat nedosažitelné? | Je to architektonické a bezpečnostní rozhodnutí s dopadem na S0/S8 identity. | B5, NET-11 a integraci s helperem. |
| Q7 | Připouští první verze **jakoukoli** wildcard výjimku (B2), nebo je wildcard v MVP zakázaný úplně? | PLAN wildcard nezavrhuje výslovně, ale každá výjimka je trvalá plocha. | Rozsah matice NET-10 a počet buněk L4. |

**Poznámka k rozsahu:** podle [IMPLEMENTATION §0](../../../docs/IMPLEMENTATION.md) je tímto
dokumentem balík C3 hotový (návrh zapsán). Další offline provenance ani rozšiřování adapteru do
přípravy nepatří; následuje rozhodnutí uživatele (Q1–Q7) a běh WP1.C4/L4.
