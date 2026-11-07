# Předloha L4 / NET-10…12 — neaktivní plán

Tento dokument nic nerezervuje v LAB, nepovoluje wildcard/LAN aktivitu a nemění PLAN ani jeho kontrakt.
WP1.C3 je hotový balík, jakmile je návrh bind policy zapsaný v [BIND-POLICY.md](BIND-POLICY.md); vynucení mechanismu a verdikt patří WP1.C4/L4.
Dílčí offline propojení existujících C1/common wire výstupů dodává [ADAPTER.md](ADAPTER.md);
chybějící producer nonce/tuple/identity/capture vazby, S0/S1 předpoklady a skutečný S3b/L4 běh zůstávají otevřené. Historické tvrzení o
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

Každý řádek se opakuje zvlášť pro IPv4/IPv6, loopback/wildcard a všechny tři oblasti dle LAB. Žádný
výsledek jedné oblasti, rodiny ani bind varianty nezastupuje ostatní. Oddělené exact peer identity a
nové run/flow nonces brání záměně pozitivní kontroly s provozem jiné buňky.

| Případ | Scénář | Požadovaný oracle / finding |
|---|---|---|
| NET-10 | Host → oblast, LAN → oblast, jiná oblast → oblast. Listener bind `127.0.0.1`/`::1` i wildcard `0.0.0.0`/`::`, vlastní přidělený port. | Nezávislý target-side packet capture plus skutečný accept/bytes log a handshake protistrany. Každý zakázaný packet/kontakt podle předregistrace je finding, i accept s 0 B. |
| NET-11 | Oblast zkouší pevný předregistrovaný host port při držené rezervaci, během povoleného uzavření host služby i během/po jejím návratu. | Explicitní bind/listen výsledek/errno a nezávisle ověřený vlastník endpointu, kontinuita rezervace a úspěšné reclaim/host controls. Nabytí portu i v drainu je finding. Ephemeral collision je jen přístrojový control. |
| NET-12 | Dva odlišné procesy stejné oblasti provádějí devserver roundtrip; odděleně oblast → host a oblast → jiná oblast. | Pozitivní expected-counterpart handshake před/test/po ve správném UID+audit/bootstrap kontextu; zákaz cizích listenerů se ověřuje nezávisle. Same-process/UID smoke nelze dosadit. |

LAN → loopback není směrovatelný test adresy 127/8 či ::1 napříč stroji: klient musí mířit na konkrétní
předregistrovanou cílovou LAN adresu stroje, na němž je listener vázaný jen na loopback. Pozitivní kontrola
musí doložit, že daný klient, trasa a capture fungují na záměrně přístupném syntetickém endpointu.
Nesmí mířit na localhost LAN stroje a označit to za cílovou oblast. IPv6 v6-only a mapped/dual-stack
varianty vyžadují vlastní předregistraci; současný live smoke nastavuje IPV6_V6ONLY a neprokazuje dual-stack.

## Prerekvizity před jakoukoli aktivací

**[uživatel]** Teprve po doložení testovacích relací z L1 a S0 pass, doplnění C1 integrace, zvoleného
mechanismu ochrany a potvrzení metodiky F0.8 zaregistruje oddělený L4 slot, zálohu a reviewerem prošlý
přesný plán. Dodá syntetické LAN protistrany, endpointy, UID/GID/skupiny/audit/bootstrap mapu, kód/OS
verze a hashe. Privilegované kroky, případný capture a změny systému provádí uživatel dle samostatně
reviewované implementace. Tento package k nim nemá příkaz.

**Varování:** wildcard listener může vystavit endpoint všem dosažitelným interface. Budoucí aktivní
wildcard/LAN runner musí mít samostatnou explicitní volbu, konkrétní reviewed plan, pevnou endpoint
allowlist, kontrolu identity a podpisu ještě před socketem, konečnou dobu/buffer budget a připravený
úklid. Volba `smoke --apply` jej nesmí aktivovat. Aktivovat jej nyní přes libovolný host/port či shell
příkaz není součást tohoto balíku.

**[implementátor, dokončení C1 integrace]** Offline `link` již parsuje skutečné výstupy obou producerů
a zveřejní explicitní mezery. Doplní jejich chybějící run/flow/tuple/identity metadata a nezávislý oracle, bez jejich
kopírování či nahrazování. Upraví výhradně samostatně reviewovaný adapter, který nezávisle sváže raw
started/accepted/closed/stopped, endpoint family/bind/local+remote tuple, capture ID/interface,
sequence/time/run/flow nonce a očekávané peer identity. Common `CounterpartReport` vidí accept/bytes,
nikoli každý SYN či packet, takže samotný listener log není oracle nulových kontaktů. Capture musí
být nezávislý na nedůvěryhodném UID oblasti a mít doložené clocks, losses a nepřetržité intervaly.
Nulové payloady, chybějící handshake nebo klientský connect error bez oracle nejsou pass.

## Předregistrace a rozhodování

Před měřením zafixovat povolenou/zakázanou operaci, každý směr/family/bind, pevnou host-port rezervaci,
reuse/dual-stack varianty, nové i existující flows, retry upper bound, 2× RTT a clock uncertainty,
intervaly před/test/drain/po a opakování. Návrh LAB §9: nejméně 3 běhy na buňku, 60 s před poruchou,
600 s během/po; dočtení nejméně 60 s a delší než retry upper bound + 2× RTT. Tyto návrhy čekají na
konkrétní schválení; 8s transport smoke je nenahrazuje. Chybějící IPv6/LAN/oblast/SDK je missing,
nikoli N/A nebo pass. Neověřená horní mez retry znamená neúplnou observation window.

Pozitivní controls před i po musí obsahovat správný peer a nonce, skutečný přijatý a vrácený kanárek,
receiver log a nezávislé capture. Zachovat všechny neúspěchy i neplatné pokusy. Při zachyceném porušení
zastavit závislou integraci, zachovat raw a provést pouze vlastní ověřený úklid. Žádné měnění prahů podle
výsledku. Po skončení prokázat uzavření vlastních listenerů/flows a návrat vlastních změn, případný
konflikt zachovat k řešení. Zápis skutečného výsledku do evidence/COVERAGE přijde samostatně po review.
