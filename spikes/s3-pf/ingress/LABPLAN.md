# Předloha L4 / NET-10…12 — neaktivní plán

Tento dokument nic nerezervuje v LAB, nepovoluje wildcard/LAN aktivitu a nemění PLAN ani jeho kontrakt.
Offline příprava C3 dodává matice, bounded vlastní transport fixture, konzervativní classifier
a zapsaný [návrh bind policy](BIND-POLICY.md); tím je podle IMPLEMENTATION §0 hotová.
Dílčí offline propojení existujících C1/common wire výstupů dodává [ADAPTER.md](ADAPTER.md);
autentizace peeru, nezávislý capture, S0/S1 předpoklady, vynucení politiky a skutečný S3b/L4 běh zůstávají otevřené. Historické tvrzení o
pf `user` se zde neopakuje jako absolutní vlastnost kernelu; chování konkrétního mechanismu musí být
ověřeno pro konkrétní macOS a transport. Žádný filtr se tímto balíkem neinstaluje ani nečte.

## Návrh hranice — hypotéza k falzifikaci

Oblast smí obsluhovat jen vlastní předregistrovaný endpoint a komunikovat s prokázaným same-zone peerem.
Host, jiná oblast a LAN k němu nesmějí navázat zakázaný kontakt; oblast nesmí získat chráněný host port,
ani když je host služba dočasně zavřená. Rezervace UI nebo kontrola před spuštěním serveru nestačí:
user-level kód může socket otevřít přímo, použít wildcard, reuse varianty, IPv6/IPv4-mapped cestu nebo
přechod mezi startem a kontrolou. Kandidátní mechanismus proto musí být uplatněný před bind/connect,
bez mezery při startu, revokaci, pádu helperu a obnově. Vynucovací mechanismus tohoto návrhu **chybí**.

Není dovoleno tvrdit, že vlastní `EADDRINUSE`, unixová práva souborů, uid/session ani tento přístroj
vynucují bind policy. Neúspěch izolace je blokátor R2/R3; chybějící mechanismus neuzavírá ani dokonale
negativní konečný test. Souvislost s C2 ochranou nezávislou na rulesetu zůstává integrační práce.

## Matice budoucího uživatelského běhu

Každý řádek se opakuje zvlášť pro TCP/UDP, IPv4/IPv6, loopback/wildcard a všechny tři oblasti dle LAB.
Žádný výsledek jedné oblasti, transportu, rodiny ani bind varianty nezastupuje ostatní. Oddělené exact peer identity a
nové run/flow nonces brání záměně pozitivní kontroly s provozem jiné buňky.

| Případ | Scénář | Požadovaný oracle / finding |
|---|---|---|
| NET-10 | Host → oblast, LAN → oblast, jiná oblast → oblast. TCP listener / UDP přijímací socket bind `127.0.0.1`/`::1` i wildcard `0.0.0.0`/`::`, vlastní přidělený port. | Nezávislé vlastnictví a capture s polohou vůči hranici podle BIND-POLICY §4, cílový TCP accept/bytes nebo UDP receive log. Prokázaný zakázaný průchod za hranici, TCP spojení/accept či UDP doručení (i s 0 B) je finding; pouhý příchozí pokus před hranicí nikoli. |
| NET-11 | Oblast zkouší pevný host endpoint `(transport, family, address, port)` při držené rezervaci, během povoleného uzavření host služby i během/po jejím návratu. TCP a UDP rezervace se ověřují zvlášť. | Bind výsledek/errno (TCP navíc listen), nezávislý vlastník endpointu, kontinuita rezervace a úspěšné reclaim/host controls s TCP accept/bytes nebo UDP receive. Nabytí endpointu i v drainu je finding. Ephemeral collision je jen přístrojový control. |
| NET-12 | Dva odlišné procesy stejné oblasti provádějí TCP roundtrip a samostatnou UDP datagramovou výměnu; odděleně oblast → host a oblast → jiná oblast pro oba transporty. | Pozitivní expected-counterpart handshake/nonce před/test/po ve správném UID+audit/bootstrap kontextu; všechny plánované bajty/datagramy doručeny oběma směry. Negativní TCP spojení/accept a UDP příjem přes `recvfrom`/ekvivalent se ověřují nezávisle podle BIND-POLICY §4. Same-process/UID smoke nelze dosadit. |

LAN → loopback není směrovatelný test adresy 127/8 či ::1 napříč stroji: klient musí mířit na konkrétní
předregistrovanou cílovou LAN adresu stroje, na němž je listener vázaný jen na loopback. Pozitivní kontrola
musí doložit, že daný klient, trasa a capture fungují na záměrně přístupném syntetickém endpointu.
Nesmí mířit na localhost LAN stroje a označit to za cílovou oblast. IPv6 v6-only a mapped/dual-stack
varianty vyžadují vlastní předregistraci; současný live smoke nastavuje IPV6_V6ONLY a neprokazuje dual-stack.

Capture musí mít předregistrované umístění vůči vynucované hranici. Hostový interface capture
může zaznamenat odmítnutý LAN SYN/datagram, i když oblast endpoint nezískala. Takový pokus
není automaticky bezpečnostní finding; nezávisle je nutné doložit nezískání endpointu nebo
zákaz průchodu/příjmu za hranicí. Nejasná poloha či neúplný oracle = Nejasné. Podrobné rozlišení
pokus / průchod / TCP spojení a accept / UDP doručení i primární podklady jsou v
[BIND-POLICY §4](BIND-POLICY.md#4-mapování-na-net-10-net-11-net-12). TCP rezervace není rezervace
UDP portu téhož čísla; každý transport potřebuje vlastní negativní i pozitivní controls.

## Prerekvizity před jakoukoli aktivací

**[uživatel]** Teprve po doložení testovacích relací z L1 a S0 pass, doplnění C1 integrace, zvoleného
mechanismu ochrany a doplnění konkrétní předregistrace podle přijaté metodiky F0.8 zaregistruje
oddělený L4 slot, zálohu a reviewerem prošlý přesný plán. Dodá syntetické LAN protistrany,
endpointy, UID/GID/skupiny/audit/bootstrap mapu, kód/OS
verze a hashe. Privilegované kroky, případný capture a změny systému provádí uživatel dle samostatně
reviewované implementace. Tento package k nim nemá příkaz.

**Varování:** wildcard listener může vystavit endpoint všem dosažitelným interface. Budoucí aktivní
wildcard/LAN runner musí mít samostatnou explicitní volbu, konkrétní reviewed plan, pevnou endpoint
allowlist, kontrolu identity a podpisu ještě před socketem, konečnou dobu/buffer budget a připravený
úklid. Volba `smoke --apply` jej nesmí aktivovat. Aktivovat jej nyní přes libovolný host/port či shell
příkaz není součást tohoto balíku.

**[implementátor, navazující WP1.C4/L4 integrace]** Offline `link` již parsuje skutečné výstupy obou producerů
a zveřejní explicitní mezery. Doplní jejich chybějící run/flow/tuple/identity metadata a nezávislý oracle, bez jejich
kopírování či nahrazování. Upraví výhradně samostatně reviewovaný adapter, který nezávisle sváže raw
started/accepted/datagram/closed/stopped, endpoint transport/family/bind/local+remote tuple,
capture ID/interface a polohu vůči ochranné hranici,
sequence/time/run/flow nonce a očekávané peer identity. Receiver záznamy obsahují TCP accept/bytes
a UDP datagramy, nikoli každý SYN či packet; samotný log proto není oracle nulového průchodu hranicí. Capture musí
být nezávislý na nedůvěryhodném UID oblasti a mít doložené clocks, losses a nepřetržité intervaly.
Nulové payloady, chybějící handshake nebo klientský connect error bez oracle nejsou pass.

## Předregistrace a rozhodování

Před měřením zafixovat povolenou/zakázanou operaci, každý směr/transport/family/bind, přesnou
host endpoint rezervaci, ochrannou hranici a umístění capture vůči ní,
reuse/dual-stack varianty, nové i existující flows, retry upper bound, 2× RTT a clock uncertainty,
intervaly před/test/drain/po a opakování. Návrh LAB §9: nejméně 3 běhy na buňku, 60 s před poruchou,
600 s během/po; dočtení nejméně 60 s a delší než retry upper bound + 2× RTT, s rezervou pro clock uncertainty.
LAB-v1 je přijaté v [DECISIONS F0.8](../../../docs/DECISIONS.md); tyto síťové návrhy z LAB §9 se
zafixují v konkrétní předregistraci L4. 8s transport smoke je nenahrazuje. Chybějící TCP/UDP/IPv6/LAN/oblast/SDK je missing,
nikoli N/A nebo pass. Neověřená horní mez retry znamená neúplnou observation window.

Pozitivní controls před i po musí obsahovat správný peer a nonce, skutečný přijatý a vrácený kanárek,
receiver log a nezávislé capture. Zachovat všechny neúspěchy i neplatné pokusy. Při zachyceném porušení
zastavit závislou integraci, zachovat raw a provést pouze vlastní ověřený úklid. Žádné měnění prahů podle
výsledku. Po skončení prokázat uzavření vlastních listenerů/flows a návrat vlastních změn, případný
konflikt zachovat k řešení. Zápis skutečného výsledku do evidence/COVERAGE přijde samostatně po review.
