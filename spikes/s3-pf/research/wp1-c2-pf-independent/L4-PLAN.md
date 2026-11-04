# Návrh falsifikačních experimentů — nespouštěno

Tento dokument je vstup do WP1.C1/C3/C4 a S0; **není schválený ani vykonaný laboratorní protokol**.
Konkrétní harness, záznam metadat, rezervace L4 a review cleanupu teprve musí vzniknout. Žádný
výsledek níže není Prošlo/Neprošlo. Cílem je vyvrátit konkrétní hypotézu a určit chybějící mechanismus,
ne negativní výsledek několika volání zaměnit za úplný důkaz.

## Prerekvizity a oracle

**[uživatel]** Testovací Mac bez reálných projektů/tajemství v oblastech, čerstvá záloha, rezervovaný
L4, testovací uživatelé z L1 a prošlá S0 podle GUIDE. Zapsat přesný macOS build, chip/model, SDK,
podpisy a absentující `get-task-allow`, policy hash, sestavení sond a host/zone identity. Přístupy
k reálným účtům/APNs nejsou výchozí součástí; bez schválené izolované integrační konfigurace je
příslušný kanál nepokrytý. Nečíst soukromá data, host DNS cache ani skutečné credential stores.

**[implementátor]** Před L4 musí být konkrétní kandidát ochrany a manifest všech cest startu/IPC.
Každá sonda nejdřív ověří credentials/session přes společnou sadu; nesoulad, mezera ve capture nebo
chybějící pozitivní kontrola znamená neplatné měření, ne pass. Budoucí měnící skripty musí mít
dry-run, předchozí stav, ověření vlastních cest a idempotentní konfliktně bezpečný cleanup.

**Oracle:** řízená nezávislá protistrana a podle protokolu raw capture na řízeném segmentu;
současně syntetický host listener a listener jiné oblasti pro lokální cesty. Každá operace má
unikátní kanárek a ID, každý běh pozitivní kontrolu stejné síťové cesty. Syntetické DNS zóny/domény,
listener IP a porty předem pevně povolené uživatelem; žádné náhodné cíle internetu/LAN.
Použitelná společná protistrana WP0.4 nepokrývá sama všechny ICMP, TLS obsah ani službové kanály.

Před během určit přesné začátky/konce capture, počty/pacing pokusů, timeout a korelaci hodin; tyto
parametry nesmějí být upravené podle výsledku. Bez nich není důkaz platný. Pro PF-loss zkoušet
kontinuální **již před poruchou zakázanou** přímou cestu; tím se nevytvoří nejasnost o dříve legálně
odeslaném paketu. Pro revokaci zvlášť zafixovat bod přijetí revokace, ID payloadů a fronty; pakety
odeslané před hranicí a až později doručené se musí odlišit, ne přepsat výsledek posunem timestampu.
Není-li revokační hranice implementovatelná nebo doložená, výsledek je Nejasné.

Nulový počet zakázaných bajtů na kompletně pozorované protistraně je nutná podmínka. Jakýkoli
jednoznačně zakázaný kanárek/bajt vyvrací tvrzení pro danou konfiguraci; log deny/errno bez oracle
nestačí. Nula bajtů v konečném běhu není univerzální matematický důkaz. Zachování host konektivity,
jiných oblastí a povolených operací se měří paralelně.

## Scénáře

| ID / mapování | Otázka, varianta a podmínka falsifikace |
|---|---|
| E1 — S0/LC, předpoklad všech NET | Spustit syntetický workload přes launcher, přímý fork/exec, interpreter, vlastní nativní binárku a povolenou službovou/job cestu. Zkoumat i restart/pád launcheru a běžný pokus vytvořit nový job. Libovolný start workloadu mimo požadovanou policy vyvrací úplnost launcherové hranice. Obyčejné přerodičování není automaticky bypass; ověřit skutečnou policy. |
| E2 — NET-01…09,20…22 | Nejprve s nefunkčním PF ověřit kandidáta zvlášť, pak za kontinuálních pokusů odděleně flush vlastního anchoru, ztrátu attachmentu, flush rules, flush states, `-F all`, `-d`. Jen uživatel spouští privilegované kroky. Zaznamenat úspěch i skutečný rozsah každé mutace; příkaz, který selhal, není provedená fault injection. Přímý IPv4/IPv6 TCP/UDP kanárek na protistraně vyvrací deny. |
| E3 — NET-16 | `getaddrinfo`, podporované frameworkové resolution API a DNS-SD query se syntetickým unikátním názvem; zvlášť přímý DNS socket. Ověřit studenou/neopakovanou query bez čtení host cache, resolver změny a požadavek přijatý před PF loss/revokací. Dotaz může exfiltrovat jméno i když API vrátí chybu; rozhoduje kontrolovaný authoritative/capture oracle. |
| E4 — NET-16,27 | Browse/register/update řízené DNS-SD služby, service name/TXT kanárky, mDNS IPv4 i IPv6, dostupná povolená interface. Registrace nesmí vysílat zakázanou změnu ani po stopu klienta/revokaci. Neprovádět plošný browse skutečných host/LAN služeb. |
| E5 — NET-17,27 | Nejprve zjistit dostupnost konkrétní unprivilegované ICMP/ICMPv6 cesty na přesném buildu, pak pouze řízené payloady k protistraně. Nepovolovat root oblasti. Je-li jedna sonda odmítnutá, neprokazuje to zákaz všech cest; nedostupná cesta se eviduje přesně. IPv6 control traffic hosta nesmí být zničen globálním zákazem. |
| E6 — NET-18, S0 IPC | Pro každou předem vyjmenovanou běžnou službu oddělit možnost připojit se, možnost zadat operaci a její skutečný přenos. U testovatelného AirDrop použít jen určenou syntetickou protistranu; APNs/účty pouze po samostatném integračním schválení. Mock pomůže ověřit broker, nikoli zákaz reálné globální služby. Chybějící reálná cesta/oracle = nepokryto. |
| E7 — NET-25 | Socket z doby před restrikcí, zděděný fd, dup/fork a povolený syntetický IPC fd transfer; zvlášť TCP, connected/unconnected UDP a queued send před stopem. Předstartovní konstrukce má ukázat, že zakázaný fd nemůže vůbec vstoupit. Post-start konstrukce musí doložit jeho revokaci. Chyba jednoho connect nezastupuje všechny varianty. |
| E8 — NET-25…26 | Povolená typovaná operace + následná revokace; dlouhé TCP/SSE spojení a případný tunel/multiplex, požadavek čekající v bráně, restart se starým ID/generací. Po definované revokaci nesmí projít nový zakázaný payload ani opakování staré autorizace. Brána nesmí dát oblasti obecný upstream fd nebo neomezený CONNECT. |
| E9 — NET-10…12,27 | TCP/UDP bind `127.0.0.1`, `::1`, wildcard IPv4/IPv6, v4-mapped a konkrétní syntetické LAN adresy; host/LAN/jiná oblast jako klient. Port obsazený oblastí před startem host testovací služby, reuse/collision a restart. Nepovolený kontakt či záměna služby vyvrací hranici; povolený same-zone dev server musí fungovat. PF user/wildcard atribuci měřit, ne předpokládat z historického tvrzení. |
| E10 — NET-23 | Pád helperu a brány v každé fázi start/revoke/restart, ještě existující klientský socket a službou přijatá práce. Zakázaná data nesmějí projít ani před reakcí watchdogu. Watchdog latenci evidovat odděleně jako PERF-02, nikdy místo byte oracle. |
| E11 — NET-24,27 | Předem určené připojení/odpojení testovací VPN, sleep/wake, síťová změna a nová interface/adresa. Test IPv4, IPv6 global/ULA/link-local a dostupných awdl/llw/utun cest; nedostupné interface zapsat jako neotestované. Zachovat host i sousední oblast. Žádná síťová konfigurace se nemění při pouhé přípravě. |
| E12 — R1/R8, POS, S5/S6 | Pozitivní nativní workloady se syntetickými projekty: CLI/interpreter, package manager bez cizích instalačních skriptů, GUI aplikace, Xcode/Simulator/Android dle jejich slotů. Spuštění dítěte nesmí vytvořit unsandboxed compatibility fallback. Všechny povolené operace musí jít přes definovanou bránu; nekompatibilní nástroj není bezpečnostní pass původního kontraktu. |

## Co musí další výsledek obsahovat

U každého testu konkrétní policy a její enforcement místo, předpokládané pokrytí, očekávaný důvod
odmítnutí, pozitivní kontrolu, credentials, raw oracle a verzi platformy. Pro obecný App Sandbox
a custom SBPL oddělené konfigurace a výsledky. Rozlišit selhání parseru/podpisu/spuštění od zákazu
síťové operace; syntax error nesmí vyprodukovat „sandbox zablokoval síť“.

**[uživatel] Úklid L4:** nejprve uzavřít testovací operace a všechny jejich joby/službové požadavky;
ověřit credentials a ukončení vlastních testovacích procesů. Odstranit pouze evidované laboratorní
objekty, obnovit jen vlastní nezměněné zásahy do pf/route/VPN/interface; konflikt s novou změnou
uživatele zastavit k řešení. Globální `-F all`/disable nelze na živém hostu bezpečně „vrátit“ pouhým
načtením starého textového dumpu, zejména kvůli states a dynamickým cizím pravidlům. Proto tyto
poruchy vyžadují předem obnovitelnou izolovanou laboratoř a výslovný uživatelský krok, ne automatický
cleanup běžného vývojového stroje. Ověřit host síť a absenci zbývajícího testovacího listeneru/registrace.
Neúplný nebo konfliktní cleanup se uvede jako nedokončený běh.

Rozhodnutí o prošlé S3/S3b vyžaduje GUIDE review a všechny případy jejich rozsahu. Tento plán
pokrývá otázky C2 a vazby, nenahrazuje celou testovací sadu S3 ani S0/S5/S6.
