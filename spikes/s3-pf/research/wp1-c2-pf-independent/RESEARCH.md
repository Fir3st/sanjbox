# WP1.C2 — rešerše a návrh

Stav: **výzkumný výstup, blokátor otevřený**, 2026-11-03. Zdroje `[S…]` a `[L…]` odkazují do
[SOURCES.md](SOURCES.md). **Doloženo** znamená dokumentaci nebo čtený zdrojový kód; **odvozeno** je
náš závěr z těchto podkladů; **hypotéza** čeká na implementaci/experiment. Žádné síťové chování zde
není označeno jako změřené.

## 1. Co musí nezávislá hranice zaručit

Při flushi anchoru, flushi pravidel/states, `pfctl -F all` i `pfctl -d` musí dál existovat vynucená
hranice mezi kódem oblasti a každou nepovolenou síťovou operací. Platí od prvního spuštění, pro
nové potomky a jiné startovací cesty UID, pro IPv4 i IPv6 a všechny dostupné cesty, také po pádu
helperu či brány. Nemá vzniknout doba mezi poruchou a reakcí, během níž je přímý přenos možný.
Host a ostatní oblasti mají dál fungovat; pozitivní same-zone server a nativní nástroje jsou součást
kontraktu, nikoli automaticky zrušené požadavky.

Z toho **odvozujeme**: procesový watchdog řeší detekci a zotavení, nikoli zákaz bajtu před detekcí.
`SIGSTOP` také není odvoláním již předané práce resolveru, fronty kernelu nebo brány. Proxy nastavená
přes prostředí pouze nabízí cestu; nedokazuje zákaz libovolného socketu. Zákaz root přístupu oblasti
je nutný, ale failure modes v PLAN zahrnují i zásah mimo oblast; nenahrazuje test ztráty pf.

## 2. Porovnání mechanismů

| Mechanismus | Co podklady skutečně dokládají | Proč zatím neuzavírá C2 |
|---|---|---|
| pf anchor / druhý anchor / default deny v kořeni | Pravidla a states uvnitř téhož PF; disable vrací paket bez filtrace [S1–S3, L1–L2] | Mohou pokrýt konkrétní lokální flush, ne vypnutí PF. Odstraněný hook na anchor znepřístupní pravidla, i kdyby objekt anchoru zůstal. |
| `pfctl -E` a enable token | Reference pro koordinaci uživatelů PF [L1, S3] | `DIOCSTOP` v čtené revizi ruší reference i tokeny; není veto proti `-d`. |
| App Sandbox | Podporované omezení sandboxovaného procesu a jeho přímých potomků; client/server entitlements [S4–S8] | Není doložená per-UID instalace pro všechny starty ani úplná kompatibilita/službová a revokační hranice. |
| Seatbelt, `sandbox-exec`, custom SBPL | Wrapper aplikuje profil před exec; nástroj deprecated, SDK API unsupported [L3–L4] | Dostupnost není podporovaný stabilní kontrakt custom pravidel. Nutno prokázat pokrytí, dědění a kompatibilitu na každém cílovém buildu. |
| Network Extension | Apple doporučené content/packet filters, DNS proxy aj.; konkrétní deployment limity [S1, S9] | **Vyloučeno rozhodnutím F0.5/D-002.** Ani nové povolení samo o sobě nedokazuje úplné R3. |
| Endpoint Security | Autorizační události; macOS 27 také descendants klient a některé XPC/bootstrap události [S10–S12, L5–L6] | F0/D-002 vylučuje ES; descendants klient stále vyžaduje entitlement. Není doložený IP packet/send gate. |
| Vlastní MAC/KEXT, socket filter | XNU obsahuje hooky pro bind/connect/send/receive [S13] | Kernelový hook není veřejná userspace per-zone policy. Apple Silicon KEXT cesta vyžaduje jiné boot/deployment předpoklady [S14]; není schválená. |
| Privátní NECP policy | Čtený zdroj umí policy i podle UID a zprostředkované identity [S15] | Otevření policy session kontroluje platformový podpis i privilegium; root sám nestačí. Interní možnosti jádra nedokládají dostupné veřejné API. |
| Route / interface / globální firewall | Route má destination/interface scope, ALF incoming policy [L7–L9, S16] | Není doložené závazné přiřazení všech procesů/služeb oblasti k izolované síti. Globální blackhole/down poškozuje hosta; ALF nedokládá požadovaný egress. |
| Explicitní proxy + ACL k IPC | Lze navrhnout úzký autorizovaný transport k bráně | Použitelná část konstrukce až s nezávislým zákazem přímé sítě a jiného IPC. Samotné proxy nastavení je obejitelné vlastním kódem. |

## 3. pf: ruleset, states a disable jsou odlišné životní cykly

**Doloženo:** manuál rozlišuje `-F rules`, `-F states` a `-F all`; `-a` volí anchor. Default akce při
nenalezení pravidla je pass. Paket odpovídající state projde bez nové evaluace pravidel. Čtený XNU
`pf_test` i `pf_test6` při vypnutém PF vracejí `PF_PASS`; `DIOCSTOP` nuluje enable reference a ruší
tokeny. `PF_PASS` je verdikt této vrstvy, nikoli důkaz doručení přes jiné případné ochrany. [L1–L2; S2–S3]

| Událost | Důsledek pro návrh (odvozeno; rozsah konkrétního příkazu musí L4 zaznamenat) |
|---|---|
| Flush pravidel Sanďbox anchoru | Deny v jiném stále vyhodnocovaném anchoru může vydržet tento jeden scénář. Není nezávislý na PF. |
| Ztráta hlavního attachment pravidla | Nestačí existence pojmenovaného anchoru; musí být skutečně dosažen při vyhodnocení. |
| Flush states | Nezabíjí proces ani BSD socket. Nový paket z existujícího socketu vyžaduje účinný deny, nesmí využít obnovenou příliš širokou policy. |
| Flush rules bez states | Stará povolená state může nadále rozhodovat; nová deny pravidla nejsou sama revokace. |
| `pfctl -F all` | Zkoušet jako samostatnou globální poruchu. Neodvozovat, že rekurzivně maže každý pojmenovaný objekt; důležité jsou dosažitelné rules, NAT a states. |
| `pfctl -d` | Záložní PF pravidlo se neuplatní, i kdyby zůstalo uložené. Reference `-E` tento zdrojově doložený stop neblokuje. |
| Opětovné zapnutí / reload | Nemá samo obnovit autorizaci operace, starý tunel ani klientské spojení. Revokace má vlastní generaci policy a identitu operace. |

**Důležitá nuance ingress:** místní `pf.conf(5)` uvádí `user` také pro uživatele naslouchajícího na
cílovém portu. Připnutý XNU má v `pf_socket_lookup` i wildcard PCB lookup pro IPv4/IPv6. Proto zde
netvrdíme, že `user` je principiálně pouze egress nebo nikdy nerozliší wildcard listener. Je omezený
na TCP/UDP a credentials socketu; skutečné lo0/ingress atribuce na macOS 27 musí ověřit S3b.
Tato nuance nemění PLAN ani není pass S3b. [L2 §user; S2 `pf_socket_lookup`]

Apple navíc PF výslovně nepovažuje za API pro široce distribuovaný produkt; uvádí kolize s uživatelem,
systémovými službami a jinými produkty. To je samostatné omezení dlouhodobé podpory, nikoli empirické
zjištění úniku na tomto stroji. [S1]

## 4. App Sandbox není totéž co custom Seatbelt profil

### Veřejný App Sandbox

**Doloženo:** client entitlement dovoluje otevírat spojení i k serveru na stejném stroji. U TCP jde
o iniciaci, nikoli směr následných dat; u UDP dokumentace popisuje i omezení toku. Boolean client/server
samy nevyjadřují per-zone cíl, port a typovanou operaci. [S4–S5]

Sandbox přímého potomka není podmíněn jeho vlastním `inherit` entitlementem: Apple DTS výslovně uvádí
i `/bin/sh` a helper bez obou App Sandbox entitlementů mimo Mac App Store. Pravidlo dvou entitlementů
v návodu k vloženému helperu tedy **neznamená nutnost přepodepsat každý externí nástroj**. Neslučitelné
entitlements nebo pokus inicializovat druhý sandbox ale mohou vést k ukončení. [S6–S8]

**Odvozené návrhové důsledky, nikoli doložené úniky:**

- Statický zákaz přímé sítě od startu procesu je podstatně silnější kandidát než následná reakce na pf.
  Není vyvrácen TCP poznámkou v dokumentaci: pokud žádný zakázaný socket nikdy nevznikl ani nebyl předán,
  není co zpětně odvolávat. Naopak již existující/předaný TCP socket nelze považovat za zrušený pouhou
  změnou entitlementů na disku, pravidel PF nebo zastavením jeho původce.
- UID oblasti samo nepřipojuje sandbox k novému procesu. Všechny cesty vstupu musí být uzavřené před
  prvním nedůvěryhodným kódem. Nový job spuštěný externím `launchd` nebo práce systémové služby nejsou
  důkazem přímého dědění jen proto, že požadavek pochází od sandboxovaného klienta. Naopak obyčejný
  fork/double-fork není sám důkazem úniku ze sandboxu. [S6, S18]
- Frameworkové IPC, zděděné deskriptory, Mach/XPC práva a operace již přijaté službou potřebují vlastní
  autorizaci. Zákaz klientova `connect` nedokládá zákaz služby, která vytvoří jiný socket.
- Zapnutí `network.client` kvůli localhost HTTP proxy nepředstavuje dokumentovaný allowlist pouze
  tohoto portu. Pro kandidáta bez přímých socketů je vhodnější zkoumat úzké IPC k bráně; kompatibilitu
  stock HTTP klientů, SDK a vývojových serverů tato konstrukce zatím nedokládá.
- Nativní nástroje nejsou automaticky kompatibilní s App Sandbox. Apple DTS popisuje omezení statického
  sandboxu při spouštění executables a chybějící dynamický executable grant. Je nutná pozitivní matice
  Xcode/Simulator, Android, Electron, package managerů a jimi spouštěného libovolného kódu. Nekompatibilita
  se nesmí řešit neoznačeným unsandboxed spuštěním. [S17]

### Seatbelt / `sandbox-exec` / `sandbox_init`

**Doloženo:** místní `sandbox-exec(1)` je DEPRECATED a popisuje profil aplikovaný před příkazem.
SDK 27.2 má veřejný `sandbox_init` označený `API_DEPRECATED("No longer supported", macos(10.5, 10.8), …)`;
header dovoluje jako flags pouze `SANDBOX_NAMED`, při již existujícím sandboxu popisuje chybu.
Custom SBPL ani nedokumentované varianty nejsou tímto public headerem podporovaným kontraktem.
Deprecated neznamená, že binárka už nefunguje; nepoužíváme to jako runtime fail. [L3–L4]

XNU dokládá MAC socket hooky nezávislé na `pf_test`, nikoli kompletní implementaci konkrétního
Seatbelt profilu. **Hypotéza H1:** předstartovní profil s úzkým IPC, zakázanými internetovými sockety
a uzavřenými jinými službami může ochránit omezenou sadu nativních workloadů při vypnutí PF.
Zatím chybí: přesná podpora grammar/operací pro macOS 27 buildy; inheritance přes všechny starty;
DNS/mDNS/ICMP a zprostředkované operace; bind/ingress a přenos fd; kompatibilita požadovaného R1/R8.
Řetězec typu `deny network*` není bez těchto důkazů certifikát kompletní síťové izolace. [S13; L3–L4]

## 5. Kanály, které nesmí vypadnout z návrhu

| Kanál / životní fáze | Doložený podklad | Co zůstává neověřeno a jak by se tvrzení vyvrátilo |
|---|---|---|
| DNS přes resolver | `mDNSResponder` provádí dotazy za klienty; OSS předává také PID/UUID/UID [L10, S19] | Není správné tvrdit ani „vždy obejde sandbox“, ani „sandbox vždy blokuje“. Unikátní název nesmí dorazit k řízenému DNS serveru při zakázané operaci; testovat i dotaz předaný před poruchou. |
| mDNS / DNS-SD | Společný daemon, browse/register a multicast [L10, S19] | Query jméno, service/TXT payload, link-local IPv4/IPv6, už dříve přijatá registrace. Lokální privacy prompt není doklad celé hranice. |
| ICMP / ICMPv6 | PF user attribution není pro tyto protokoly [L2, S2] | Ověřit dostupné unprivilegované sockety/frameworky na cílovém buildu. Nelze předpokládat zákaz veškerého ICMP jen z chybějícího rootu nebo zachytávání TCP/UDP. |
| AirDrop/APNs a další system IPC | Apple PF compatibility checklist zahrnuje AirDrop/Continuity [S1] | Reachability služby není důkaz úniku, existence sandboxu není důkaz zákazu. Inventura přesných běžných operací a schopnosti nést kanárek; nevyřešená operace = chybějící důkaz, ne 0-day výjimka. |
| Existující TCP/UDP socket, fd transfer | TCP initiation-only contract [S4]; PF state lifecycle [L2] | fd zděděný při startu, předaný přes IPC, dup/fork, již navázané spojení, queued send. Oracle na protistraně i po zastavení/ukončení klienta. |
| Brána, CONNECT/tunely, multiplex | Samostatná identita brány, typovaná policy je požadavek PLAN | Po revokaci neobnovit starý session/tunel ani queued request. Broad CONNECT není typovaná brána. Test pádu, restartu a stale generation. |
| IPv6 / VPN / nové interface | `pf_test6` také bypass při disable [S2]; route interface scope [L7] | ULA/link-local/global, multicast, scoped address, dual-stack/v4-mapped, dostupné `awdl0`/`llw0`/`utun`, wake a změna trasy. Zákaz IPv4 sám nestačí. |
| Ingress / lo0 / port squatting | server entitlement, PF listener attribution [S5, L2] | LAN/host/jiná oblast nesmějí dosáhnout zakázaného listeneru; oblast nesmí obsadit hostem očekávanou službu. Zároveň musí fungovat povolený same-zone server. Vyhrazené číslo portu není vlastnická hranice. |

## 6. Alternativy a macOS 27

**Endpoint Security:** nepřebíráme staré tvrzení, že ES neumí nic kolem IPC. Ve čtených SDK 27.2
hlavičkách jsou od 27.0 `es_new_descendants_client`, `AUTH_XPC_CONNECT` a bootstrap auth události.
Descendants klient nevyžaduje root ani TCC, ale výslovně stále potřebuje
`com.apple.developer.endpoint-security.client`. Poznámka o subtree není příslib kontroly všech
systémových služeb; authorizations se týkají existujících typů událostí. V prohlédnutém enumu není
veřejná IP send/packet authorization. WWDC20 odkazuje networking k NE, s výjimkou Unix sockets;
novější hlavičky mají přednost pro nová IPC rozhraní. ES je navíc vyloučeno D-002. [S10–S12, L5–L6]

**MAC/KEXT:** v jádře jsou relevantní checky; jejich existence tedy brání paušálnímu tvrzení,
že macOS technicky nemá žádný enforcement mimo PF. Chybí však povolená veřejná cesta instalace
vlastní per-zone policy v běžné userspace aplikaci. KEXT cesta na Apple Silicon přidává Reduced
Security, approval/reboot a jiné deployment požadavky; samovolně měnit boot policy je mimo zadání.
Tato rešerše neověřila uskutečnitelnost konkrétního KEXT podpisu nebo MAC modulu. [S13–S14]

**NECP, routing, ALF:** UID podmínky v interní NECP struktuře nejsou oprávnění je veřejně nastavovat.
Čtená `necp_session_open` odmítá neplatformově podepsaného volajícího ještě před kontrolou UID/root.
U route není popsána vynucená per-UID namespace, pouze cíle a interface scope. Vynucení, aby libovolný
škodlivý proces nemohl použít jinou cestu, by potřebovalo další hranici. Globální blok nebo interface-down
má dopad i na hosta. ALF dokumentuje incoming policy a výjimky, ne univerzální per-zone egress deny.
Žádné z těchto pozorování není úplný průzkum všech interních policy mechanismů macOS. [S15–S16; L7–L9]

## 7. Otevřený blokátor a návrh další práce

**C2-B1 — nedoložená úplná hranice nezávislá na PF.** Pro platný kontrakt zatím není doložen povolený mechanismus,
který společně pokryje (a) všechny starty a práci jménem oblasti, (b) každý přímý i službou
zprostředkovaný síťový kanál při nefunkčním PF, (c) revokaci rozpracovaných operací a (d) pozitivní
kompatibilitu a fungující host. Toto je technický důvod otevřeného blokátoru, nikoli jen chybějící
benchmark nebo pomalejší watchdog. S3/NET/R3 zůstávají Neověřeno a blocker Otevřený.

**Návrh k ověření H1, nikoli schválená architektura:** zkoumat nejprve App Sandbox od startu s nulovou
přímou internetovou konektivitou, uzavřeným souborem povolených IPC operací a hostem chráněným
brokerem. Broker by ověřoval audit identitu/oblast, metodu, cíl, payload a generaci autorizace;
žádné obecné předávání otevřených síťových fd do oblasti. Existence takové hranice musí být doložena
před experimenty ztráty PF. Custom SBPL lze porovnat jako explicitně nepodporovaný výzkumný kandidát,
ne jej potichu zaměnit za veřejný App Sandbox. [Experimenty E1–E12](L4-PLAN.md)

Otevřené otázky pro další rešerši/Apple (zde se žádný dotaz neposílá):

1. Existuje podporované veřejné macOS 27 rozhraní, které uzavírá všechny startovací cesty vyhrazeného
   UID a všechny procesy/služby pracující jeho jménem pod neměnnou no-network policy bez NE/ES?
2. Jaký je dokumentovaný no-network kontrakt App Sandbox pro resolver, DNS-SD, ICMP a běžné systémové
   služby, včetně operací přijatých před revokací? Které operace potřebují samostatné deny?
3. Lze s veřejným App Sandbox zachovat povolený same-zone TCP server a stock nástroje a současně
   odmítnout host/other-zone/LAN přístup a port squatting bez spoléhání na PF?
4. Jak zavést revokační okamžik pro práci mimo klientský proces, již přijaté IPC a queued data bez
   zastavení hosta? Které části vyžadují synchronní broker/kernel potvrzení?

Pokud H1 nesplní bezpečnost nebo kompatibilitu, předložit autorovi konkrétní změnu kontraktu:
omezené workloady/transport, NE s jiným deploymentem, nebo oddělené jádro/VM. **Nic z toho není
schváleno**; VM a NE jsou nyní vyloučené a méně podporovaných nástrojů samo nesplní původní R1/R8.
Nezávislé prototypy mohou pokračovat, bezpečné F2 z otevřeného blokátoru nevzniká.
