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

Oblast je sada procesů pod vyhrazeným UID. Samotné egress pravidlo pro provoz **vysílaný oblastí**
není důkazem ochrany proti host/LAN/jiná oblast → endpoint oblasti. To neznamená, že pf `user`
je principiálně pouze egress: místní `pf.conf(5)` dokumentuje u lokálně iniciovaného spojení
vlastníka zdrojového socketu a u incoming spojení vlastníka naslouchajícího socketu. Připnutý
XNU provádí socket lookup podle směru; podklady a jejich meze jsou v §1.3 a §2.2.

**Odvozeno / hypotéza (GUIDE §7), nikoli pozorování:** samotná příprava egress filtru nedokládá,
že wildcard endpoint oblasti na `0.0.0.0`/`::` není dosažitelný z hosta či LAN. Skutečnou
reachability a atribuci na konkrétním macOS/transportu musí rozhodnout L4. pf ingress atribuce
(M10) i incoming policy ALF (M12) jsou kandidáti k ověření; zde se netvrdí, že existující
konfigurace hosta provoz určitě propustí nebo určitě odmítne.

### 1.2 Zdrojový klient a vlastník cílového listeneru jsou různé otázky

[PLAN §4 Síť](../../../PLAN.md) popisuje problém **klient oblasti → cílový listener**:
povolení cílové adresy a portu samo nedokládá, zda tam právě obsluhuje stejná oblast, host,
nebo jiná oblast. Není to tvrzení, že povolení spojení klientovi oblasti automaticky povolí
stejné spojení také klientovi hosta. Dokumentovaná atribuce zdrojového socketu přes `pf user`
čerpá identitu ze socketu, takže nepřítomnost UID v samotném IP paketu ji nevyvrací.

- Pokud se klientovi oblasti povolí loopback endpoint jen podle adresy/portu bez ověřené
  hranice vlastnictví, může tento endpoint obsluhovat host či jiná oblast. Samotná identita
  klienta ještě neřeší NET-12 ani port squatting.
- Pokud se oblasti zakáže celý same-zone loopback, nefunguje ani požadovaný devserver.
  To je regrese R3/R7 a kompatibility R8, nikoli automatické splnění kontraktu.

Požadavek PLAN na bind policy nebo jinou prokázanou hranici oddělení listenerů zůstává.
Pro opačný směr **host/jiná oblast → oblast** je nutné zvlášť ověřit zákaz přístupu k jejímu
endpointu (NET-10/B4). Z těchto požadavků neodvozujeme nemožnost jiné konstrukce: skutečné
`lo0` chování, cílová atribuce a kombinace pravidel zůstávají hypotézou pro L4.

### 1.3 Atribuce listeneru není vyřešená ani u pf

[LABPLAN.md](LABPLAN.md) správně neopakuje historické tvrzení o `pf user` jako absolutní vlastnost
kernelu: připnutý XNU má při hledání socketu i wildcard PCB lookup, takže chování ingress atribuce
na konkrétním macOS a transportu **musí být změřeno**, ne odvozeno. Současně platí, že i kdyby
wildcard listener byl přiřaditelný, zůstávají tři strukturální meze: atribuce `user` je jen pro TCP/UDP,
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
| M1 | App Sandbox: entitlement client/server + profil | Omezení sandboxovaného procesu a jeho přímých potomků; `network.server` existuje. Přímý potomek dědí sandbox i bez vlastního `inherit` entitlementu [§2.2, C2 S6] | Start: není doloženo pokrytí **všech** startů oblasti a systémových služeb. Revokace: změna entitlementů ani pád brokeru nejsou doloženým odvoláním existujícího listeneru/fd. Pád brokeru, sleep-wake/VPN: ověřit nové starty přes externí `launchd` a práci služeb mimo dědící procesový strom; samotná událost nedokládá zánik již zděděného sandboxu. Address/port scope `network.server` není v podkladech doložen | Proces při zamýšlené deny policy obslouží zakázaný wildcard/host/LAN kontakt; nebo jiná startovací cesta spustí kód bez požadované policy |
| M2 | Seatbelt / custom SBPL s bind allowlistem (local ip/port) | **Doloženo:** `sandbox-exec(1)` spouští příkaz s aplikovaným profilem [§2.2, C2 L3]. **Hypotéza:** přesná grammar a účinnost bind allowlistu podle adresy/portu na cílovém buildu; wrapper sám ji nedokládá | Start: nástroj deprecated, veřejné `sandbox_init` nepodporované → není stabilní kontrakt custom pravidel. Pokrytí všech startů, dědění a family/transport forem není doloženo. Revokace: zákaz nového bindu sám nedokládá odvolání existujícího listeneru/fd. Pád helperu, sleep-wake/VPN: ověřit zachování profilu a starty mimo wrapper; nepředpokládat automatický zánik profilu | Proces s allowlistem bindne adresu/port/transport mimo seznam, nebo wildcard; nebo povolený endpoint obslouží zakázaný kontakt hosta |
| M3 | Host-owned listen proxy + zákaz vlastního bindu v oblasti | Port drží hostem vlastněný proces, oblast dostane fd nebo jen broker kanál; wildcard ingress v oblasti nevzniká | Start: fd předaný při startu obchází pozdější kontrolu (fd transfer, `dup`, `fork`). Bez M1/M2/M5 oblast bindne sama. Revokace: již předaný fd zůstává. Pád proxy: fail-closed jen když to klient doloží. Sleep-wake/VPN: proxy musí revalidovat adresy. Kompatibilita: mění, na jaký `HOST:PORT` nástroje v oblasti míří (R1/R8) | Oblast otevře vlastní socket mimo proxy; nebo proxy po pádu nechá starý fd obsluhovat; nebo se povolený devserver nerozběhne |
| M4 | Per-zone adresa (alias `127.0.0.x`, dedikovaná LAN/ULA adresa) + bind allowlist | Oddělí adresy, na kterých kdo listenuje; same-zone klient míří na vlastní adresu | Start: alias sám o sobě nic nevynutí — wildcard bind je dosažitelný přes všechny adresy. Revokace: alias zůstává. Pád helperu: politika vázaná na adresu vydrží jen s M2/M5. Sleep-wake/VPN: adresa se může změnit/zmizet. Kompatibilita: nástroje s hardcoded `127.0.0.1` přestanou fungovat | Wildcard bind je dosažitelný přes jakoukoli adresu; nebo nástroj v oblasti na `127.0.0.1` nefunguje |
| M5 | MAC framework / socket filter (XNU hooky pro bind/connect/send) | Kernelový hook existuje; teoreticky bind gate | Start/revokace by byly správné, ale: není veřejná userspace per-zone policy; Apple Silicon KEXT cesta vyžaduje Reduced Security, approval a reboot → rozsah **čeká na Q5** (§6); podpis/deployment nedoložen | Bez změny boot policy neexistuje instalovatelná podepsaná cesta; nebo by šlo jen s vypnutou System Integrity Protection |
| M6 | Privátní NECP policy | Čtený zdroj umí policy podle UID i zprostředkované identity | Otevření policy session kontroluje platformový podpis a privilegium; root nestačí. Interní možnosti jádra nejsou veřejné API | Platformově nepodepsaný proces policy session neotevře; nebo API není dokumentované |
| M7 | Network Extension (content/packet filter) | Apple doporučená cesta pro síťové filtry | **Vyloučeno** F0.5/D-002 (žádný placený Developer Program). Navíc: per-UID atribuce listeneru a fail-closed při pádu rozšíření nejsou doložené | Vyloučení platí, dokud trvá D-002. Zpět do hry by ho vrátil pozorovatelný jev: veřejná (nepodepsaná placeným programem) cesta k content/packet filtru na macOS 27, nebo změřený per-UID ingress filtr bez Developer Programu — pak by se D-002 muselo znovu rozhodnout, ne obejít |
| M8 | Endpoint Security authorization | Autorizační události; macOS 27 descendants klient | **Vyloučeno** D-002; v prozkoumaném enumu není IP bind/packet authorization. Entitlement i tak vyžaduje placený program | Vyloučení platí pro prozkoumaný enum. Zpět do hry by ho vrátil pozorovatelný jev: veřejně dokumentovaná IP bind/packet authorization událost v SDK 27 a současně cesta k entitlementu bez placeného programu — jinak zůstává vyloučeno |
| M9 | launchd socket activation + hostem držená rezervace | **Hypotéza bez zdroje:** že launchd aktivace předá oblasti jen aktivovaný fd a jinak endpoint drží host, není v prozkoumaných podkladech doloženo; zdroj chybí | Je to **rezervace, ne bind policy**: user-level kód v oblasti otevře socket přímo. Revokace: aktivovaný fd přežívá. Pád: rezervace může zůstat viset. Sleep-wake: aktivace po wake neopakuje kontrolu | Oblast bindne rezervovaný port sama; nebo rezervace nepřežije zavření host služby |
| M10 | pf ingress atribuce (jen jako měřená hypotéza) | Místní `pf.conf(5)` uvádí `user` i pro naslouchajícího uživatele; XNU má wildcard PCB lookup [§2.2, C2 S2/L2] | Atribuce `user` jen TCP/UDP; jeden globální ruleset; flush/disable/state je jiný životní cyklus než revokace oblasti; credentials socketu, ne aktuální EUID. Paket odpovídající existující state může projít bez nové evaluace pravidel; při chybějící state čtený XNU vyhodnocuje pravidla. Nový socket tedy sám neznamená bypass. Sleep-wake/VPN: změřit přežití states, změny trasy/rozhraní i nové toky na cílovém buildu | Wildcard endpoint obslouží zakázaný kontakt i s deny pravidlem; nebo rodina/transport/reuse varianta poruší očekávanou atribuci |
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

### 2.2 Primární podklady a jejich meze

Statické review 2026-11-07 ověřilo následující podklady. Dokládají popsanou sémantiku, ne
funkční bind policy ani výsledek na cílovém macOS. Připnutý OSS není doloženou shodou s jeho
binárním kernelem; lokální manuál dokládá text dané instalace.

| Podklad | Co z něj tento návrh používá |
|---|---|
| `/usr/share/man/man5/pf.conf.5`, `user` (ř. 1591–1611), stateful filtering (ř. 1296–1304); [C2 zdroje L2](../research/wp1-c2-pf-independent/SOURCES.md#lokální-apple-manuály-a-sdk) | Zdrojová a cílová socket atribuce, creation credentials, TCP/UDP; zachované states se vyhodnocují před pravidly. |
| [Apple XNU `pf.c`, připnutý commit `f6217f8`](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/net/pf.c), funkce `pf_socket_lookup`, `pf_test`, `pf_test6` | Lookup podle směru včetně wildcard; pokud state chybí, následuje `pf_test_rule`. Nejde o runtime důkaz aktuálního buildu. |
| [Apple DTS: On File System Permissions, App Sandbox](https://developer.apple.com/forums/thread/678819) a [C2 RESEARCH §4](../research/wp1-c2-pf-independent/RESEARCH.md#4-app-sandbox-není-totéž-co-custom-seatbelt-profil) | Přímé dítě dědí sandbox i bez `inherit`; oddělit dědění od startů přes externí služby. |
| `/usr/share/man/man1/sandbox-exec.1`, DESCRIPTION/options; [C2 zdroje L3–L4](../research/wp1-c2-pf-independent/SOURCES.md#lokální-apple-manuály-a-sdk) | Deprecated wrapper spouští příkaz s profilem. Z toho neplyne podporovaný přesný bind allowlist ani úplné pokrytí. |
| `/usr/share/man/man4/udp.4`, DESCRIPTION (ř. 54–93) | UDP má vlastní portový prostor a příjem datagramů (`recvfrom` nebo ekvivalent), nikoli TCP `listen`/`accept`. TCP rezervace není UDP rezervací. |
| `/usr/share/man/man4/bpf.4`, DESCRIPTION (ř. 35–62) | Capture je pohled na pakety rozhraní, nikoli potvrzení doručení socketu. Umístění vůči enforcementu musí určit předregistrace. |

---

## 3. Požadované vlastnosti politiky

Formulace je závazná pro budoucí implementaci a pro `Contracts/` (návrh, ne změna kontraktu).
Každá vlastnost musí být pozorovatelná zvenčí; „politika to zakazuje“ není důkaz.

### 3.1 Per-oblast

| ID | Vlastnost | Pozorovatelné kritérium |
|---|---|---|
| B1 | **Allowlist bindů**: pro každou oblast přesně vyjmenované `(transport, family, address, port nebo rozsah)`. TCP a UDP jsou oddělené; výchozí stav je prázdný seznam. | Bind mimo seznam skončí chybou a nezávisle se ověří nezískání endpointu; žádný TCP accept ani doručený UDP datagram. Samotný návratový kód nestačí (§4). |
| B2 | **Zákaz wildcard** `0.0.0.0`/`::` mimo výslovnou výjimku s důvodem, transportem, rodinou a portem; výjimka je samostatně evidovaná a testovaná buňka, ne globální přepínač. | Wildcard buňka má vlastní řádek v předregistraci a vlastní oracle; nesplývá s loopback buňkou ani s jiným transportem. |
| B3 | **Rodiny odděleně**: IPv4 a IPv6 (a `IPV6_V6ONLY` / v4-mapped varianta) mají vlastní allowlist i vlastní výsledek. | Jeden výsledek v4 nezastupuje v6; v4-mapped cesta je samostatná buňka. |
| B4 | **Same-zone loopback jen s doloženým oddělením listenerů**: povolen pouze tehdy, když politika skutečně zajistí, že host (a jiná oblast) na tentýž endpoint nedosáhne. | Současně: same-zone roundtrip projde **a** host/other-zone kontakt nepřijde. Jeden z těch dvou výsledků sám nestačí. |
| B5 | **Zákaz port squattingu** na host endpoint: hostem vlastněný rezervující proces drží `(transport, family, address, port)` před startem oblasti a spojitě i při dočasném uzavření host služby. Oblast jej nesmí získat. | Bind oblasti na rezervovaný endpoint selže; vlastník a kontinuita rezervace se ověří nezávisle, pro TCP a UDP zvlášť. Stejné číslo portu nedokládá rezervaci obou transportů. |
| B6 | **Fail-closed při konfliktu**: nejednoznačné vlastnictví, nečitelná identita, neplatná generace politiky, výpadek rezervace nebo neznámý výsledek = endpoint se neotevře (a start oblasti se nezapočne jako úspěšný). Nikdy „povolit s varováním“, nikdy fallback na wildcard. | Konfliktní buňka končí doloženým odmítnutím; prázdný výstup bez nezávislého ověření vlastnictví a příjmu TCP/UDP je Nejasné. |
| B7 | **Životní fáze**: politika platí před prvním `socket`, při revokaci (existující listenery zavřené nebo nedosažitelné), po pádu helperu/brány (žádná zděděná schopnost), po sleep/wake a po změně VPN/rozhraní (nový bind vyžaduje novou validaci). | Každá fáze má vlastní běh a vlastní oracle; návrat deny pravidel po poruše není pass. |
| B8 | **Pozorovatelnost**: rozhodnutí politiky se logují s generací, oblastí, transportem, rodinou, adresou, portem a výsledkem. Log je podpůrný, **není** oracle. | Verdict stojí na nezávislém ověření vlastnictví a zákazu kontaktu/doručení za ochrannou hranicí (§4), ne na logu oblasti. |
| B9 | **Oblast nemá privilegovanou cestu**: politiku vlastní host; oblast ji nemůže měnit, obnovit ani obejít jiným startem. | Pokus oblasti o změnu politiky (nebo o start mimo ni) končí odmítnutím, ne tichým úspěchem. |
| B10 | **Kompatibilita**: povolený same-zone devserver a běžné nástroje v oblasti fungují beze změny jejich konfigurace, nebo je změna (`HOST`/`PORT` injektované hostem) výslovně přijatá jako změna kontraktu R1/R8. | Pozitivní buňka projde se stock nástrojem; pokud ne, je to blokátor, ne poznámka. |
| B11 | **UID samotné není hranicí vlastnictví endpointu**: identita zdrojového socketu je jiný údaj než vlastník cílového listeneru. UID může být vstupem politiky, ale samotná shoda UID, souborová práva ani mount policy oddělení listenerů nedokládají. | Klient oblasti míří na vlastní i cizí kontrolované endpointy; vlastnictví cíle a povolení klienta se ověřují odděleně. Nejasný kontext je neplatné měření. |

### 3.2 Datový model (návrh pro `Contracts/`, nerealizováno)

Pole, která musí politika umět vyjádřit, aby B1–B11 šla vůbec měřit. Tabulka **není** změna
`Contracts/`; formát síťové politiky patří do **WP1.H1** (`proto/contracts/`, viz
[IMPLEMENTATION §0](../../../docs/IMPLEMENTATION.md)), zatímco kořenový `Contracts/` je F2/WP2.0.

| Pole | Význam |
|---|---|
| `zoneID` | Identita oblasti, ke které se záznam vztahuje; žádný globální záznam. |
| `generation` | Monotónní generace politiky; stará generace po revokaci nesmí autorizovat nic. |
| `transport` | Výslovně `tcp` nebo `udp`; bez výchozí hodnoty a bez implicitního společného portového prostoru. |
| `family` | `ipv4` / `ipv6` / `ipv6-v6only`; výchozí hodnota neexistuje. |
| `address` | Přesná adresa, nebo `wildcard` **jen** spolu s `exceptionReason`. |
| `portMin`/`portMax` | Přesný port nebo uzavřený rozsah pro uvedený transport; `0` (ephemeral) musí být výslovně povoleno. Skutečně přidělený endpoint se zaznamená a nesmí obejít chráněnou rezervaci. |
| `direction` | `ingress`: TCP bind/listen/accept nebo UDP bind/příjem datagramů; egress `connect`/odesílání má oddělenou policy. UDP nepotřebuje TCP listen/accept. |
| `reservationOwner` | Kdo přesný `(transport, family, address, port)` drží před startem oblasti (`helper`, `launchd`, `agent`); povinné pro chráněné host endpointy. |
| `conflictAction` | Vždy `failClosed`; jiná hodnota je neplatná politika. |

---

## 4. Mapování na NET-10, NET-11, NET-12

Oracle musí být **nezávislý na nedůvěryhodném UID oblasti**. Pro ingress do oblasti se cílový
TCP accept/bytes nebo UDP receive log váže na přesný endpoint a kontrolovanou sondu; vlastní
log oblasti ani návratový kód sám není verdikt. Doplňuje jej nezávislé ověření vlastníka
endpointu a capture/pozorování s doloženými clocks, losses a souvislými intervaly. U opačného
směru oblast → host/jiná oblast běží receiver oracle na kontrolované protistraně.

Předregistrace stanoví **ochrannou hranici a polohu každého měřicího bodu vůči ní**, interface,
filtr, směr, transport a vazbu na konkrétní endpoint. Rozlišují se:

- **Příchozí pokus před hranicí:** například LAN SYN nebo UDP datagram na hostově interface.
  Jeho zachycení, ani doložená odmítací odpověď stacku, samo nedokazuje kontakt s oblastí.
- **Prokázaný průchod zakázaného provozu za stanovenou hranici:** je finding i bez aplikačního
  payloadu. Označit capture jako „target-side“ nestačí k důkazu, že leží za touto hranicí.
- **TCP:** zakázané navázání spojení na cílový socket, accept (i s 0 B) nebo přijatá data jsou
  finding. Pouhá absence acceptu nevylučuje navázání do kernelové fronty; handshake/capture
  a identita cílového socketu proto musí být svázané a nezávisle doložené.
- **UDP:** doručení zakázaného datagramu cílovému socketu, včetně datagramu s 0 B, je finding;
  přijímací záznam používá `recvfrom`/`recvmsg` nebo ekvivalent a oba endpointy. Absence TCP
  acceptu není UDP oracle; samotný příjem na hostově interface není příjem socketem oblasti.

Příklad interpretace: bind správně odmítnutý politikou, žádný endpoint oblasti a LAN SYN
zachycený před hranicí nejsou porušení ingressu jen kvůli tomuto SYN. Pro negativní výsledek
je stále nutné doložit pokusy, odmítnutý bind/nezískání endpointu, úplnost oracle a pozitivní
kontroly. Pokud umístění/úplnost pozorování nedovolí odlišit odmítnutý pokus od průchodu či
příjmu socketem, výsledek je **Nejasné**, nikoli pass. Raw packet observations se zachovají;
`packetContact` v offline adapteru není automatický bezpečnostní verdikt.

Buňky se nepočítají dohromady: `transport × family × bind × směr × oblast` je samostatný
řádek předregistrace, včetně pozitivních controls. TCP a UDP mají samostatné portové prostory
(§2.2); rezervace, bind výsledek ani roundtrip jednoho transportu nezastupuje druhý.

Práh a délky oken zde **nevymýšlím**; platí návrhy z [LABPLAN.md](LABPLAN.md) (nejméně 3 běhy
na buňku, 60 s před poruchou, 600 s během/po, drain alespoň 60 s a delší než retry upper bound
+ 2× RTT) až po schválení uživatelem.

### 4.1 NET-10 — ingress na listener oblasti z hosta, LAN a jiné oblasti

| Buňka | Co se měří (oracle) | Předregistrované očekávání pro L4 |
|---|---|---|
| TCP listener / UDP přijímací socket oblasti: bind `127.0.0.1`, `::1`, `0.0.0.0`, `::`; vlastní přidělený port | Samostatné TCP/UDP buňky: capture s určenou polohou vůči hranici, skutečné socket endpointy (`getsockname`), nezávislé vlastnictví a cílový TCP accept/bytes nebo UDP receive log | Nula zakázaných průchodů za hranici, TCP spojení/acceptů a UDP doručení od hosta, LAN a jiné oblasti. Accept či doručený datagram s 0 B je finding. Paket před hranicí se vyhodnotí podle §4, nikoli automaticky jako fail. |
| Pozitivní kontrola před i po, zvlášť TCP/UDP | Stejná klientská cesta a měřicí body na záměrně přístupném syntetickém endpointu daného transportu | TCP doručí všechny plánované bajty; UDP všechny předregistrované datagramy a jejich payloady/nonce. Bez kompletní kontroly je negativní výsledek Nejasné. |
| LAN → TCP/UDP endpoint | Klient míří na **předregistrovanou LAN adresu stroje** (ne na `localhost`), cílový socket je vázaný jen na loopback | Prokázaný zakázaný průchod/doručení = finding; samotný pokus na LAN interface není doručení loopback socketu. Neprovedená buňka = missing, nikoli N/A ani pass. |
| IPv6 / v4-mapped | Vlastní buňka, `IPV6_V6ONLY` zaznamenáno | Samostatný výsledek; dual-stack se nepředpokládá. |

### 4.2 NET-11 — port squatting na host port

| Buňka | Co se měří (oracle) | Předregistrované očekávání pro L4 |
|---|---|---|
| Oblast zkouší bind na pevný předregistrovaný host endpoint při držené rezervaci, zvlášť TCP/UDP | Explicitní bind výsledek/errno (u TCP navíc listen), nezávisle ověřený vlastník přesného transport/family/address/port a spojitost rezervace | Oblast endpoint nezíská; jakékoli nabytí je finding. TCP rezervace bez UDP rezervace neověřuje UDP buňku. |
| Povolené uzavření host služby a její návrat, zvlášť TCP/UDP | Vlastník endpointu v okně zavřeno/otevřeno, TCP accept/bytes nebo UDP receive log host služby, úspěšný reclaim a pozitivní host controls | Během zavření endpoint nezíská oblast; po návratu host služba funguje a drží jej pro správný transport. Nabytí i v drainu je finding. |
| Ephemeral kolize | Instrumentální kontrola | Kolize efemérního portu **není** NET-11 a nesmí se vydávat za důkaz. |
| `SO_REUSEADDR`/`SO_REUSEPORT`, restart, dual-stack, zvlášť TCP/UDP | Vlastník endpointu a bind výsledek pro každou transport/family/reuse variantu | Reuse ani restart nesmí umožnit oblasti získat nebo sdílet chráněný endpoint; varianta bez vlastní buňky je missing. |

### 4.3 NET-12 — pozitivní same-zone dev server bez přístupu k cizím listenerům

| Buňka | Co se měří (oracle) | Předregistrované očekávání pro L4 |
|---|---|---|
| Dva odlišné procesy stejné oblasti provedou devserver roundtrip, odděleně TCP/UDP | Expected-counterpart handshake ve správném UID + audit/bootstrap kontextu; TCP kanárek nebo předregistrovaná UDP datagramová výměna s nonce oběma směry; receiver log a nezávislý capture dle §4 | Příslušný roundtrip doručí všechny plánované bajty/datagramy správnému peeru; TCP výsledek nenahrazuje UDP, same-process ani same-UID smoke se nedosazuje. |
| Současně cizí TCP listenery a UDP přijímací sockety | Host i jiná oblast mají vlastní kontrolované endpointy a nezávislý oracle; měří se kontakty **z** oblasti | Nula zakázaných průchodů za hranici, TCP spojení/acceptů a doručených UDP datagramů; vlastnictví cíle i příjem ověřeny nezávisle, ne z logu oblasti. |
| Souběh s NET-10 buňkami | Stejné okno, oddělené run/flow nonce | Pozitivní a negativní buňka se nesčítají; záměna nonce = neplatné měření. |

### 4.4 Co by který výsledek znamenal pro tento návrh

| Výsledek L4 | Důsledek pro bind policy |
|---|---|
| Nula zakázaných kontaktů/průchodů podle §4 **a** funkční pozitivní buňky | Kandidátní skladba přežila jeden scénář; zdaleka ne celý kontrakt (fáze B7, LAN, obě rodiny i TCP/UDP). |
| Jakýkoli prokázaný zakázaný průchod hranicí, TCP spojení/accept nebo UDP doručení při platném měření | **Neprošlo** pro danou konfiguraci; blokátor R2/R3, ne residuum. Pouhý pokus zachycený před hranicí takový závěr nedokládá. |
| Neúplné capture, nejasná poloha vůči hranici, chybějící kontrola nebo nejasná identita | Nejasné / neplatné měření; nic se nezapisuje jako pass. |
| Chybějící buňka (TCP/UDP, IPv6, LAN, nástroj, oblast) | Missing → Neověřeno zůstává. |

### 4.5 Kam se zapisuje který fázový výsledek (B7)

B7 žádá oracle pro pět fází, ale S3b v [COVERAGE](../../../docs/COVERAGE.md) vlastní jen NET-10…12;
fázové případy jsou pod S3. V každé fázi se podle její předregistrace opakují ingress,
rezervační a pozitivní/negativní buňky §4.1–4.3 pro TCP i UDP; samotný egress výsledek S3
je nenahrazuje. Mapování určuje zápis výsledků, nikoli vynechání těchto oraclů:

| Fáze B7 | Kde se měří | Řádek COVERAGE a brána | Poznámka |
|---|---|---|---|
| Start (politika platí před prvním `socket`) | Buňky §4.1–4.3; listener vzniká při startu | NET-10, NET-11, NET-12 — **S3b** | Start není samostatný případ; je to podmínka buňky. |
| Revokace (existující listenery zavřené nebo nedosažitelné) | Postup NET-25a/NET-26 v [L4-RUNBOOK](../L4-RUNBOOK.md) | NET-25, NET-26 — **S3** | Fázový výsledek patří do S3, ne do S3b. |
| Pád helperu/brány (žádná zděděná schopnost) | Postup NET-23a/NET-23b v [L4-RUNBOOK](../L4-RUNBOOK.md) | NET-23 — **S3** | Ověřit, že nepřežije zakázaná schopnost přes fd a nezanikne ochrana rezervovaného endpointu podle B5. |
| Sleep/wake, VPN, změna sítě | Postup NET-24a/NET-24b v [L4-RUNBOOK](../L4-RUNBOOK.md) | NET-24 — **S3** | Nový bind po wake/VPN vyžaduje novou validaci; nepatří do NET-10…12. |
| Souběh fáze s pozitivní buňkou | §4.3 (dva procesy stejné oblasti) | NET-12 — **S3b** | Pozitivní same-zone důkaz zůstává v S3b, fázový důkaz v S3. |

Fázové výsledky mají primární zápis pod NET-23/24/25/26 a odkazy na konkrétní ingress,
rezervační a pozitivní buňky, které se během fáze měřily. Výsledky NET-10…12 na tyto důkazy
navazují, ale běžný bind test neuzavírá fázový případ a samotný egress výsledek neuzavírá S3b.
Žádný řádek COVERAGE se neuzavře pouze výsledkem odlišného scénáře.

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
