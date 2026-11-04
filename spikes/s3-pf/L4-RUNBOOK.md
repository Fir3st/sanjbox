# L4 — uživatelský laboratorní postup, zatím neprovedený

Všechny síťové pokusy, `sudo`, změny PF, login/start testovacích oblastí, signály procesům,
sleep/wake a VPN v tomto dokumentu provádí **uživatel**. Implementátor pouze připravil
artefakty a mock testy. Tento postup není automaticky spustitelný skript. Neměnit host síť
na běžném pracovním stroji; laboratorní účty obsahují pouze syntetická data.

## Vstup, předregistrace a oracle

- Rezervovaný L4, záznam stroje, záloha a S1/S0 podle [GUIDE](../../docs/GUIDE.md) a
  [IMPLEMENTATION](../../docs/IMPLEMENTATION.md). Tři oblasti vedle host konzole; jejich
  nečinnost při load/cleanup neznamená, že test s jednou oblastí nahrazuje souběh brány.
- V `environment.md` uveď HW, macOS/build, Xcode/SDK, kód/hash, síť/topologii/VPN, rozhraní,
  host i gateway/test UID. `inputs.md` předem stanoví jednotlivé směry, cíle, porty,
  kanárky, přesné audit sessions, počet opakování a časové okno. **Žádné potvrzené prahy
  WP0.5 zde nenahrazujeme**: přípravná sonda má bezpečnostní limit 20 s; není to statistická
  délka gate testu. Bez předem schválené metodiky nelze bránu vyhodnotit.
- Použij [common protistranu](../common/README.md) na **jiném řízeném hostu**, u host-local
  testu v host relaci a u cross-zone v jiné oblasti. Záznam od brány nebo senderu není oracle.
- První akce každé aktivní sondy = credentials/session kontrola. Nesoulad, chybějící audit
  nebo chybějící field znamená **neplatné měření**, ne bezpečnostní pass. `launchctl asuser`
  samo o sobě nenastavuje UID/GID; relaci dodá ověřený S1 start, ne nový root wrapper C1.
- Protistrana má nový log/raw adresář. Nejprve samostatný **kontrolní běh** z povolené cesty
  musí zachytit spojení, všechny plánované bajty a kanárek. Po negativním běhu proveď druhý
  kontrolní běh; outage protistrany se nesmí vydávat za blokaci. Kontrolní tok nikdy slepě
  nesčítej do negativního verdiktu.
- Po negativním pokusu čekej předem zvolenou dobu ustálení, pak oracle zastav `SIGTERM` a
  vyhodnoť `sanjbox-counterpart report`. Vyžaduje start/stop a uzavřené toky. Exit 3 =
  neúplné měření. Exit 1 = kontakt, včetně TCP accept bez bajtů; zaznamenej ho, i když kanárek
  nepřišel. R3 test nesmí přijmout zakázané bajty ani před reakcí hlídače.
- Pro ICMP, mimo aplikační porty, zahazované handshaky, mDNS a encrypted traffic doplň
  packet capture **na kontrolované straně**. U TLS je kontakt/počet bajtů evidence, ale raw
  scanner nemusí vidět kanárek; použij vlastní terminační endpoint. NIC/packet capture není
  oprávnění sbírat provoz skutečných účtů. Raw obsah musí být pouze syntetický.

Očekávání pro negativní případ: nula zakázaných bajtů/kanárků a žádný nepovolený kontakt
na oracle. Pozitivní případ musí doručit přesně registrovaný payload jen správné oblasti,
operaci a cíli. Požadavek nula bytes se nemění na „hlídač reagoval do 250 ms“.

## Postup baseline a transparentní cesty

1. Uživatel připraví instalaci/delegaci a stav dle [README](README.md), zkontroluje root
   pravidla, `set skip`, NAT, interfaces a případnou VPN. S3 `user` nelze přenést na ICMP
   nebo systémový resolver jen podle výsledku přímého TCP.
2. Na nových kontrolních tocích ověř oracle bez kandidáta. Testovací oblast obsahuje jen
   sondu a kanárek. Ulož credentials každého procesu. Host kontrola musí zůstat funkční.
3. Zastav oblasti/start capability, `load.sh` dry-run a teprve uživatelské `--apply`.
   Start controlled sondy následuje až po ruční kontrole záznamu `loaded` a aktivních
   pravidel; **nejde o svolení spustit nedůvěryhodný nástroj nebo reálný projekt**.
4. Pro každé UID porovnej `in/out × inet/inet6 × tcp/udp`: přímý LAN cíl (NET-01), host
   loopback (02), jinou oblast (03), nepovolenou doménu přes předem známé IP (04), doslovné
   IP (05), UDP/443 (19), ULA/link-local a zvlášť `awdl0/llw0` (27). Stock sonda používá
   unscoped literal; scoped IPv6 interface test potřebuje předem přezkoumanou doplňkovou sondu.
5. Dokumentuj owner socketu při vytvoření, nikoli jen aktuální EUID procesu. Negativní
   kontroly: socket vytvořen před změnou UID; zprostředkovaný proces; wildcard listener;
   host/jiné UID na stejném portu. Pro skutečné UID-change/socket-pass experimenty je
   nutná samostatná uživatelská příprava, ne skrytý privilege switch v sondě.
6. Transparentní v4/v6 scénář pokračuje podle [NATLOOK-PLAN](NATLOOK-PLAN.md). Ruční
   translation/filter delegace a úklid musí být přezkoumány zvlášť. Načítací skript C1
   na široký proxy pass ani route variantu nepřepne. Rozhodnutí, že je neověřený experiment
   přijatelný na izolovaném testovacím Macu, náleží uživateli.
7. NET-06/07/13/14/15: vlastní TLS endpoint, kontrolovaná jména a DNS odpovědi, SNI jiného
   cíle, přímé TLS mimo bránu, rebinding do host/RFC1918/link-local, ECH a non-TLS. Typed
   policy S5 musí posoudit i operaci/metodu/identitu; SNI samo není oprávnění. Současná
   TCP/UDP sonda neterminuje TLS a tyto případy bez dalších nástrojů nevyhodnocuje.

## Failure matice — každý řádek samostatný běh

Pro každou poruchu připrav tři odlišné canary streamy: nový zakázaný connect, již existující
spojení/UDP flow a dříve povolený flow právě odvolané operace. Oracle běží před poruchou,
během ní, po ní i během obnovy. Zaznamenej monotonic event marker a čas na obou stranách;
clock rozdíl neřeš odhadem až po běhu. Opakuj v4/v6 a ve třech souběžných oblastech.

| ID | Ruční porucha / přesná otázka | Evidence a podmínka návratu |
|---|---|---|
| NET-20a | Vyprázdnit **jen vlastní** filter anchor. Zůstává jiná nezávislá hranice? | Oracle po celou mezeru; samotný návrat deny pravidel není pass. Stav byl uložen před změnou. |
| NET-20b | Odděleně odstranit testovací pravidla vs. příslušné syntetické states. | Nezaměňovat životní cyklus pravidel a states. Scope `-a` není důkaz, že state flush je omezen na anchor; žádné takové použití automaticky nedodáváme. |
| NET-21 | `pfctl -F all` na vyhrazeném lab Macu. | Ovlivňuje i host a další správce. Předem samostatná záloha/topologie/recovery, žádné živé účty. Scripts neobnovují globální pravidla. |
| NET-22 | `pfctl -d`. | PF ruleset není nezávislá ochrana. Nula bytes vyžaduje jiný doložený mechanismus; tato příprava jej nedodává. Není přípustné vydat následné zastavení procesu za hranici. |
| NET-23a | Ukončit **zaznamenaný vlastní** helper PID, včetně násilného pádu během autorizace/NATLOOK. | Nové operace deny, starý lease není fallback; oracle i po restartu. Žádné `killall`/obecný výběr PID. |
| NET-23b | Samostatný pád brány během header/body/idle tunnel/queued send a restart bez staré authority. | Sockets/tunely/buffery se nesmějí znovu autorizovat z cache; měřit skutečné bajty na protistraně. |
| NET-24a | User sleep/wake s existujícími toky a queued požadavky. | Sonda/oracle timestamps, gate ještě před start/resume a při rekey; pouze odečtení watchdog intervalu nestačí. |
| NET-24b | User VPN connect/disconnect/reconnect, routovací/rozhraní změna, Wi-Fi/síť. | Default route, DNS ownership, v4/v6/utun, host pozitivní provoz. Uživatelský profil s původním stavem, nikoli automatické networksetup. |
| NET-25a | TCP state vytvořen před deny loadem/revokací, pak nový kanárek na stejném socketu. | Zvláštní marker pro před/po; stávající state může obejít nové rules. Žádný state dump skutečného host provozu v protokolu. |
| NET-25b | Zaplněný send buffer, částečně odeslaný kanárek, zastavený proces, čekající resolver/IPC práce. | Přezkoumaná bounded pressure sonda + řízená pomalá protistrana; malý sender C1 plný kernel buffer negarantuje. Pozdější bytes = fail, i když proces již nežije. |
| NET-25c | Dlouhý tunel brány (např. SSE/WebSocket) a backlog v kernelu/bráně při odvolání. | Revokace celé operace i obou směrů; měřit drain a starý upstream, ne pouze přijetí nových spojení. |
| NET-26 | Revokace operace/pause/stop/start, stará policy generace, reuse portu/PID. | Starý state, token, cache ani tunel nesmí znovu projít. Start gate před spuštěním a kontrolní pozitivní nové oprávnění odděleně. |

### Izolované destruktivní kroky — pouze [uživatel]

Následující příkazy jsou **fault injection**, nikdy úklid ani součást skriptů. Nejsou
pokynem ke spuštění na pracovním hostu. User je smí zařadit až po rezervaci, review návratu,
záznamu původního stavu a vyloučení reálného provozu. Tři oddělené běhy:

```text
NET-20a: /sbin/pfctl -a sanjbox_c1 -F rules
NET-21:  /sbin/pfctl -F all
NET-22:  /sbin/pfctl -d
```

Neuvádíme automatický „undo“ enable/reload host konfigurace. Po NET-21/22 neplatí předpoklady
loaderu ani delegace. Uživatel zastaví testovací start cesty, porovná uložený původní stav se
současným a obnoví jen vlastní stále nezměněné zásahy podle schváleného manuálního plánu.
Konflikt znamená review, ne přepsání systémových anchorů. `unload.sh` po změně parentu nebo
při vypnutém PF správně odmítne pokračovat. Nový baseline run až po ověřeném návratu hosta.

## Zprostředkované kanály a ingress (otevřené)

| Případ | Příprava a skutečný oracle |
|---|---|
| NET-16 DNS | Kontrolovaná autoritativní doména se syntetickým canary v QNAME; zvlášť native `getaddrinfo`/systémový resolver vs. přímý UDP/TCP, cache hit/miss, pending request během poruchy. Autoritativní server + capture. Nečíst skutečné DNS cache ani měnit resolver automaticky. |
| NET-16 mDNS | Dva kontrolované stroje/rozhraní, canary service-name/TXT, IPv4 i IPv6 multicast, system-service mediated registration. Aplikační TCP oracle to nepokrývá; vlastní capture a přijímač služby. |
| NET-17 ICMP | Přezkoumaný nativní sender syntetického payloadu + capture na protistraně, v4/v6, před/během/po PF ztrátě. PF `user` pro ICMP není UID hranice; plošný host block není schválený fallback. |
| NET-18 AirDrop/APNs | Jen vyhrazené testovací identity/zařízení a syntetická zpráva, zvlášť API/IPC handoff a pozdější doručení. Není zde automatický pokus, skutečný Apple účet ani fiktivní mock-pass. Bez vhodného testovacího prostředí zůstává případ Neověřeno. |
| NET-10/11 | Listener pod každým UID na `0.0.0.0` a `::`, host/LAN/cross-zone pokusy, stejné a rozdílné porty, vlastnictví socketu při jeho vzniku, port squatting před startem host služby. Nativní schopnost bind/listen není prokázána zákazem egress. |
| NET-12 | Pozitivní same-zone server a současné negativní cizí listenery, IPv4/IPv6. Diagnostický deny takovou pozitivní funkci neposkytuje; C3 musí dodat bind policy a její test. |

Každý výstup ukládat do `docs/evidence/S3/<datum-běh>/` podle GUIDE: environment, inputs,
credentials, raw oracle/capture a verdict po případech. C1 nevytváří evidence adresář s
mockovanými údaji. Označení **mock / příprava / hypotéza / měřeno** se nesmějí sloučit.
Bez pozitivních kontrol, úplných logs, platné identity nebo po neplánované změně metodiky
je výsledek Nejasné/neplatné měření. Zakázaný přenos při platném testu je Neprošlo, nikoli
reziduum. Změna kontraktu, NE či VM vyžaduje rozhodnutí autora; C1 ji nepřijímá.
