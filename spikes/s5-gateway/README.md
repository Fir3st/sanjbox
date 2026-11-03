# S5 — jádro typované brány (WP1.D1, rozpracováno)

První samostatně spustitelná část WP1.D1. Swift 6 + Network.framework, bez externích balíčků;
jediná závislost je lokální `../common` (WP0.3). **Laboratorní mock, nikoli síťová izolace.**
Žádný skutečný upstream, účet, klíč nebo projekt se nepoužívá.

## Cíl a rozsah

Základ pro WP1.D2 (npm), WP1.D3 (API modelů) a WP1.D4 (fixtures):

| Část | Aktuální chování |
|---|---|
| `HTTPRequestDecoder` | Inkrementální HTTP/1.1 origin-form; limity hlaviček/těla; povinný Host; odmítá duplicitní/foldované hlavičky, TE, TE+CL, Expect, Upgrade, neplatné délky a nadbytečná data |
| `TypedRouter` | Explicitní jednosegmentové mounty, např. `/npm`, `/api`; hranice segmentu, žádný catch-all ani CONNECT; pouze registrované GET/POST operace; ostatní metody 403 |
| Auth policy | Authorization, Proxy-Authorization, Cookie, X-API-Key a Api-Key jsou před handlerem odmítnuté; nejde o autentizaci volající oblasti |
| `GatewayServer` | NWListener pouze `127.0.0.1`, přesný Host `127.0.0.1:<port>`, jeden požadavek na spojení, Connection: close; limity spojení, velikostí a času |
| SSE | HTTP chunked odpověď; každý event má vlastní chunk a limit 64 KiB; producer čeká na dokončení každého send, konec streamu má nulový chunk |
| `DestinationPolicy` | Mockovatelný resolver, kontrola všech A/AAAA výsledků, zákaz privátních/lokálních/speciálních adres a dodaných vlastních IP hosta; numerické/alternativní IP cíle odmítnuté |
| Transport policy | Pouze HTTPS port 443; ECH deklarované vstupem je odmítnuté; žádný transparentní TLS/passthrough listener |
| CLI | Výhradně `--mode mock`; ověří očekávanou identitu přes WP0.3 před otevřením listeneru; nabízí `/mock/status` a `/mock/events` |

Výchozí limity: hlavičky 16 KiB, tělo požadavku 1 MiB, běžná odpověď 4 MiB,
32 spojení, 10 s na přijetí požadavku, 120 s na celé spojení včetně SSE a handleru.
Časový limit spojení ruší transport a task handleru; handlery musí spolupracovat na cancellation.
HTTP keep-alive, chunked request body, HEAD, WebSocket, HTTP/2 a lokální HTTPS listener zatím nejsou podporované.

`DestinationPolicy` přijímá jen konzervativně vymezený public unicast. Vedle rozsahů z PLAN odmítá
například dokumentační adresy, IPv4-mapped IPv6, NAT64 a 6to4. Vlastní adresy hosta se porovnávají
podle bajtů, takže zkrácený/rozšířený zápis IPv6 kontrolu neobejde. DNS výsledek obsahující bezpečnou
**i** zakázanou adresu se celý odmítne. Policy nedrží cache povolení.

## Prerekvizity a sestavení

**[implementátor]** Apple Silicon, macOS 27.x a Xcode 27.x / Swift 6.x podle GUIDE.
Balík deklaruje minimum macOS 15 pro použité API; to není důkaz podpory projektu na macOS 15.
Z kořene repozitáře:

```bash
cd spikes/s5-gateway
swift build
swift test
```

Testy používají pouze syntetická data, injektované DNS odpovědi a TCP na `127.0.0.1` s dočasnými porty.
Nedělají vnější síťové dotazy a nečtou credential stores. Testy nepotřebují podpis, sudo ani TCC granty.
Debug binárky z `swift build` nejsou podepsané laboratorní sondy pro S8.

## Lokální mock demo

**[implementátor]** Vytvoř očekávání pro vlastní vývojovou identitu **před** během:

```bash
mock_run_dir=$(mktemp -d /tmp/sanjbox-gateway-mock.XXXXXX)
printf '{"effectiveUID":%s,"realUID":%s,"effectiveGID":%s,"realGID":%s}\n' \
  "$(id -u)" "$(id -ru)" "$(id -g)" "$(id -rg)" > "$mock_run_dir/expect.json"
swift run sanjbox-gateway --mode mock --expect "$mock_run_dir/expect.json" --port 8765
```

V jiném terminálu:

```bash
curl --noproxy '*' -i http://127.0.0.1:8765/mock/status
curl --noproxy '*' -N http://127.0.0.1:8765/mock/events
curl --noproxy '*' -i -X PUT http://127.0.0.1:8765/mock/status
curl --noproxy '*' -i -H 'Authorization: Bearer synthetic' http://127.0.0.1:8765/mock/status
```

Oracle: status vrátí 200 s `mode: mock` a `upstream: false`; events vrátí tři postupně doručené
SSE události; PUT i syntetická Authorization vrátí 403. CLI na stdout zaznamená identitu jako
`unclear` (mock není výsledek brány). Neshoda očekávání ukončí CLI kódem **3** před otevřením portu.
Chyba argumentů nebo startu má kód **2**. Port 0 zvolí dočasný port vypsaný na stderr.

**Úklid:** Ctrl-C zavře proces i sockety. V terminálu, který vytvořil očekávání, smaž pouze vlastní
`"$mock_run_dir/expect.json"` a prázdný adresář přes `rmdir "$mock_run_dir"`. Žádná systémová konfigurace,
uživatelé, ACL, pf pravidla ani persistentní služba nevznikají.
**[uživatel]** Pro tento mock nejsou potřeba privilegované kroky ani laboratorní slot.

## Rozhraní pro navazující balíky

`TypedRoute(mount:methods:handle:)` předává původní `HTTPRequest` důvěryhodnému async handleru.
Handler vrací `.response(HTTPResponse(...))` nebo `.events { emit in ... }`. Každé `emit` musí být
awaitované sekvenčně; handler nesmí vytvořit neomezené fronty/tasks. Výjimka před odpovědí dává 500;
chyba po začátku SSE zavře spojení bez další HTTP odpovědi. Obsah výjimek se klientovi nevypisuje.

Registrace mountu **nepovoluje libovolné operace upstreamu**. D2/D3 musí samy ověřit metodu, cestu,
query i tělo operace, implementovat cooldown/auth/budget a audit. Handlery nesmějí přímo spojovat
klientský target s upstream URL, slepě přeposílat hlavičky ani interpretovat raw target jako novou autoritu.
Escapovaný scoped název (`@scope%2fname`) zůstává v raw targetu; sémantiku dekódování vlastní D2.

`DestinationResolver` se injektuje do `DestinationPolicy.approve`. Volající musí dodat aktuální,
úplný snapshot IP adres hosta. Výsledek `ApprovedDestination` obsahuje ověřený hostname pro TLS a
konkrétní ověřené IP. **Výsledek sám není socket a nepředstavuje ochranu proti rebindingu v transportu.**
Budoucí transport smí připojit jen jednu z ověřených IP a musí ověřit certifikát/SNI proti hostname;
nesmí provést nový DNS lookup přes URLSession/NWConnection. Každé nové spojení i redirect musí projít
novým schválením, včetně nové kontroly host-interface snapshotu. Redirect nesmí automaticky následovat.

## Testy a hranice důkazů

- Parser: všechny hranice fragmentace, smuggling/TE+CL/duplicitní hlavičky, traversal/control znaky, limity.
- Router: žádná kolize mountů/prefixů ani fallback, blokace zápisových metod a klientských credentials.
- SSE: multiline encoding, blokace injekce metadat, limit eventu.
- DNS **mock**: IPv4/IPv6 zakázané rozsahy, alternativní numerické cíle, vlastní IP a IPv6 aliasy,
  smíšené DNS odpovědi, změna odpovědi mezi dvěma schváleními, HTTP/ECH/port policy.
- **Měřeno lokálně:** reálný TCP listener, fragmentovaný POST, přesný Host, auth/framing odmítnutí,
  první SSE event dorazí před odblokováním produceru, chunk terminátor, timeout neúplného požadavku, restart, zrušení aktivního SSE přes stop/lifetime
  a chyby handleru bez úniku jejich obsahu či druhé odpovědi.

Mapování: příprava pro **R2/R3/R8**, části **GW-08, GW-09, GW-10, GW-12, GW-14**.
Tyto testy **neuzavírají** žádný případ COVERAGE: chybí npm/API handler, skutečný upstream a integrace oblasti.
S5 i všechny testové případy zůstávají **Neověřeno**. Skutečný běh S5 vyžaduje S3/S3b a nezávislou protistranu
WP0.4; protistranu tento balík neduplikuje.

## Co zbývá v WP1.D1

1. Systémový DNS resolver a sběr aktuálních host-interface adres s testovanými failure modes.
2. Ověřený upstream transport: spojení na připnutou IP, ověření TLS identity/SNI, bounded HTTP response
   parser a inkrementální SSE příjem; integrační test rebindingu/redirectů a odpojení upstreamu.
3. Potvrdit rozhraní s D2/D3/D4; případný passthrough jen podle samostatné policy. Tento listener opaque TLS
   vůbec nepodporuje a neměří detekci ECH ClientHello na transparentní pf cestě.

Tyto body jsou nutné před označením WP1.D1 jako hotové. Per-zone CA, klíče, rate/budget, cooldown a npm
metadata patří D2/D3; pf, NATLOOK, autentizace oblastí a zprostředkované síťové kanály se řeší zvlášť.
