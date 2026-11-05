# S5 — jádro, npm typed brána a API modelů (WP1.D1, WP1.D2, WP1.D3)

Swift 6 + Network.framework, bez externích balíčků; jediná závislost je lokální `../common`
(WP0.3). Obsahuje npm handler WP1.D2, API modelů WP1.D3 a základ pro WP1.D4 (fixtures).
**Hotové balíky D1/D2/D3 nejsou důkaz síťové izolace ani prošlá brána S5.** CLI nabízí pouze lokální mock;
knihovna obsahuje samostatný HTTPS upstream klient pro důvěryhodné typed handlery.

**WP1.D2:** [npm typed handler, protokol, limity a integrační příklad](NPM.md). Kontroluje packumenty,
přímé tarbally, cache a redirecty; přidává bounded audit vydání. Živé npm registry testy neběžely.

**WP1.D3:** [API modelů, lokální HTTPS/per-zone CA, budget a limity](MODEL-API.md). Úzký Anthropic
text-stream subset používá pouze syntetický klíč; skutečný loopback TLS má izolované testy. F0.7 a
živá SDK kompatibilita zůstávají otevřené.

## Cíl a rozsah

| Část | Chování |
|---|---|
| `HTTPRequestDecoder` | Inkrementální HTTP/1.1 origin-form; limity hlaviček/těla; povinný Host; odmítá duplicitní/foldované hlavičky, TE, TE+CL, Expect, Upgrade, neplatné délky a nadbytečná data |
| `TypedRouter` | Explicitní jednosegmentové mounty, např. `/npm`, `/api`; hranice segmentu, žádný catch-all ani CONNECT; pouze registrované GET/POST operace; ostatní metody 403 |
| Auth policy | Authorization, Proxy-Authorization, Cookie, X-API-Key a Api-Key od klienta jsou před handlerem odmítnuté; nejde o autentizaci volající oblasti |
| `GatewayServer` | NWListener pouze `127.0.0.1`, přesný Host `127.0.0.1:<port>`, jeden požadavek na spojení, Connection: close; volitelné explicitní TLS z D3; limity spojení, velikostí a času; stop/restart/cancellation a peer EOF monitor |
| Odchozí SSE klientovi | HTTP chunked odpověď; event má limit 64 KiB; producer sekvenčně awaituje každý send; úspěšný konec má nulový chunk |
| `DestinationPolicy` | Všechny A/AAAA výsledky musí být veřejný unicast a mimo vlastní IP hosta; IP literály, lokální hostname, ECH, non-TLS a port jiný než 443 jsou odmítnuté |
| `SystemDestinationResolver` | AF_UNSPEC `getaddrinfo`, absolutní DNS jméno bez search suffixů, nejvýše 64 různých adres; bounded workers, timeout a cancellation volajícího |
| `SystemHostAddresses` | Čerstvý `getifaddrs` snapshot IPv4/IPv6 včetně neaktivních rozhraní, po DNS a před spojením; selhání se propaguje, žádná prázdná fallback policy |
| `UpstreamClient` | Nové schválení pro každou operaci; spojení na konkrétní numerickou IP, TLS 1.2+, SNI a kontrola certifikátu proti hostname; žádné automatické retry ani následování redirectu |
| Příchozí upstream HTTP/SSE | Bounded inkrementální response parser (Content-Length nebo chunked), UTF-8 SSE parser; průběžná dodávka a backpressure; truncation/timeout/cancellation zavřou socket |
| CLI | Výhradně `--mode mock`; ověří očekávanou identitu přes WP0.3 před otevřením listeneru; `/mock/status` a `/mock/events` |

`DestinationPolicy` konzervativně odmítá loopback, RFC1918, link-local, ULA, multicast, `100.64/10`,
vlastní IP a další special-purpose rozsahy (např. dokumentační, IPv4-mapped IPv6, NAT64 a 6to4).
Adresy porovnává podle bajtů, takže textové aliasy IPv6 kontrolu neobejdou. Smíšená bezpečná a zakázaná
DNS odpověď se odmítne celá. Numerické IPv4 aliasy (integer, octal, hex, zkrácený zápis) nejsou hostname.

Žádný transparentní TLS/passthrough listener není podporovaný. ECH se odmítá jako explicitní vstup policy;
opaque TLS, ClientHello parsing, QUIC a transparentní pf cesta zde nejsou. HTTPS klient vytváří vlastní
TLS spojení ke známému hostname; nepřebírá ClientHello oblasti.

## Limity a podporovaná podmnožina protokolů

| Limit | Výchozí hodnota |
|---|---|
| Listener: hlavičky / request body / běžná odpověď | 16 KiB / 1 MiB / 4 MiB |
| Listener: spojení / request deadline / celá session | 32 / 10 s (i start listeneru) / 120 s |
| Upstream: hlavičky / běžné tělo / celé SSE tělo / jeden event | 16 KiB / 4 MiB / 32 MiB / 64 KiB |
| Upstream: souběžné operace / connect / nečinný send nebo read / celá operace | 8 / 10 s / 15 s / 120 s včetně DNS |
| DNS: souběžní pracovníci / lookup timeout | 8 / 5 s |

Překročení souběhu vrací chybu ihned; nevzniká neomezená čekací fronta. Blokující `getaddrinfo` se nedá
přerušit: timeout/cancellation uvolní volajícího, ale worker drží svůj slot do návratu libc.
Vlastní injektovaný resolver musí spolupracovat na cancellation. Handler/consumer musí také spolupracovat
na cancellation a sekvenčně awaitovat emit; knihovna nemůže zastavit libovolný cizí výpočet.

Upstream request má pouze GET/POST a origin-form target; hlavičky Host, framing, proxy a Accept-Encoding
vlastní transport. Žádá `identity` encoding. Odpověď podporuje jeden finální HTTP/1.1 status a explicitní
Content-Length nebo chunked framing; 204/304 bez těla. Odmítá 1xx, duplicitní/foldované hlavičky,
TE+CL, compression, upgrade, trailers, chunk extensions a close-delimited tělo. Framing chunků má
samostatný limit 16 KiB + min(body limit, 1 MiB). Poškozené nebo neúplné
odpovědi nejsou úspěch. HTTP keep-alive, HEAD, HTTP/2, WebSocket a chunked request body nejsou podporované.
Tyto konzervativní limity jsou kontrakt spike; npm podmnožinu vymezuje [D2](NPM.md), [D3](MODEL-API.md) má vlastní
podmnožinu, další kompatibilitu ověří D6.
Po requestu listener sleduje EOF/error nebo další zakázaný bajt, aby odpojení rušilo i čekající
upstream. Request half-close a pipelining nejsou podporované; klient musí pro odpověď držet spojení.

SSE přijímá BOM, UTF-8 rozdělené mezi TCP čteními, CR/LF/CRLF, multiline data, event a sticky id.
Komentáře a neznámá pole nevytvářejí události. Neprovádí reconnect ani retry. Neúplný poslední event
se odmítne; i po korektním HTTP konci musí D3 sám ověřit provider-specific completion marker.

## Prerekvizity a sestavení

**[implementátor]** Apple Silicon, macOS 27.x a Xcode 27.x / Swift 6.x podle GUIDE.
Balík deklaruje minimum macOS 15 pro použitá API; to není důkaz podpory projektu na macOS 15.
TLS testy používají systémový `/usr/bin/openssl` (LibreSSL), žádnou instalaci balíčků.
Z kořene repozitáře:

```bash
swift build --package-path spikes/s5-gateway
swift test --package-path spikes/s5-gateway
```

Automatické testy používají syntetická data, injektované DNS odpovědi a TCP/TLS pouze na `127.0.0.1`
s dočasnými porty. Snapshot rozhraní čte pouze adresy. Testy nedělají vnější síťové dotazy, nečtou
skutečné credential stores a nepotřebují podpis, sudo ani TCC granty. TLS identita vzniká na každý běh
v soukromém dočasném adresáři a importuje se s `kSecImportToMemoryOnly`; nic se neinstaluje do Klíčenky
ani systémového trust store. Soubory se po importu uklidí. Debug binárky nejsou podepsané sondy pro S8.

## Lokální mock demo

**[implementátor]** Vytvoř očekávání pro vlastní vývojovou identitu **před** během:

```bash
mock_run_dir=$(mktemp -d /tmp/sanjbox-gateway-mock.XXXXXX)
printf '{"effectiveUID":%s,"realUID":%s,"effectiveGID":%s,"realGID":%s}\n' \
  "$(id -u)" "$(id -ru)" "$(id -g)" "$(id -rg)" > "$mock_run_dir/expect.json"
swift run --package-path spikes/s5-gateway sanjbox-gateway --mode mock --expect "$mock_run_dir/expect.json" --port 8765
```

V jiném terminálu:

```bash
curl --noproxy '*' -i http://127.0.0.1:8765/mock/status
curl --noproxy '*' -N http://127.0.0.1:8765/mock/events
curl --noproxy '*' -i -X PUT http://127.0.0.1:8765/mock/status
curl --noproxy '*' -i -H 'Authorization: Bearer synthetic' http://127.0.0.1:8765/mock/status
```

Oracle: status vrátí 200 s `mode: mock` a `upstream: false`; events vrátí tři postupně doručené SSE události;
PUT i syntetická Authorization vrátí 403. CLI na stdout zaznamená identitu jako `unclear` (mock není výsledek
brány). Neshoda očekávání ukončí CLI kódem **3** před otevřením portu; chyba argumentů/startu má kód **2**.
Port 0 zvolí dočasný port vypsaný na stderr. CLI nepovoluje výběr upstreamu ani nastavení trust anchors.

**Úklid:** Ctrl-C zavře proces i sockety. Smaž pouze vlastní `"$mock_run_dir/expect.json"` a prázdný adresář
přes `rmdir "$mock_run_dir"`. Žádná systémová konfigurace, uživatelé, ACL, pf pravidla ani služba nevznikají.
**[uživatel]** Pro tento mock nejsou potřeba privilegované kroky ani laboratorní slot.

## Rozhraní pro D2/D3/D4

`TypedRoute(mount:methods:handle:)` předává původní `HTTPRequest` důvěryhodnému async handleru.
Handler vrací `.response(HTTPResponse(...))` nebo `.events { emit in ... }`. Každé emit musí být awaitované
sekvenčně. Výjimka před odpovědí dává 500; chyba po začátku SSE zavře spojení bez druhé HTTP odpovědi.
Obsah výjimek se klientovi nevypisuje.
Volitelný `HTTPResponse.completion` dostane výsledek lokálního transportního sendu; D2 ho používá
pro audit. Úspěšný callback neprokazuje příjem celé odpovědi klientem ani instalaci.

Registrace mountu **nepovoluje libovolné operace upstreamu**. D2/D3 musí ověřit metodu, cestu, query i tělo,
implementovat cooldown/auth/budget a audit. Nesmějí přímo spojit klientský target s upstream URL, slepě
přeposílat hlavičky ani interpretovat raw target jako novou autoritu. Escapovaný scoped název (`@scope%2fname`)
zůstává v raw targetu; sémantiku dekódování vlastní D2.

Sdílej jednu instanci `UpstreamClient` mezi handlery, aby sdílely limit souběhu. `UpstreamRequest` tvoří
handler z ověřené operace a vlastního hostname; klientské credentials se nekopírují. Odchozí credentials,
pokud je bude D3 potřebovat, dodává pouze handler. Příklad bez klíče (není součástí mock CLI):

```swift
let upstream = UpstreamClient()
let route = TypedRoute(mount: "/api", methods: ["GET"]) { request in
    guard request.target == "/api/events" else { return .response(.error(404)) }
    let operation = try UpstreamRequest(hostname: "api.example", target: "/v1/events")
    return .events { emit in
        _ = try await upstream.events(for: operation, onEvent: emit)
    }
}
```

`response(for:)` vrací bounded tělo a `UpstreamResponseHead`; `events(for:onEvent:)` přijímá pouze 200
s `text/event-stream` a awaituje consumer před dalším čtením. Consumer běží v izolaci volajícího aktoru.
Hlavičky odpovědi jsou metadata pro policy, nikoli povolení k přeposlání klientovi.

`Location` u 3xx se **nenásleduje**. D2 musí ověřit nový origin a artefakt, sestavit nový `UpstreamRequest`
a znovu zavolat klienta; credentials starého originu se nesmějí přenést. Nový lookup a snapshot proběhnou
i pro stejný hostname. Selhání/mixed DNS/nová vlastní IP zastaví operaci před vytvořením socketu.

`ApprovedDestination` není socket ani dlouhodobé oprávnění. Produkční klient schválení a dial drží pohromadě:
`NWEndpoint.Host.ipv4/ipv6` zabraňuje druhému DNS lookupu, hostname se použije pro SNI, Host a SSL trust policy.
Každé spojení má vlastní privacy context bez proxy konfigurací, obchází systémové proxy a nepoužívá
TLS resumption/tickets. Certifikát se ověřuje systémovým trust evaluation; network fetch je vypnutý, aby validace
neotevřela další neověřenou síťovou cestu. Volí se první schválená IP; automatický fallback/retry není.
Testovací dialer a trust anchors jsou interní test seam, nikoli veřejná konfigurační možnost.

D4 může injektovat `DestinationResolver` a `HostAddressProvider`; záměrně nejsou veřejné volby pro vypnutí
SSRF/TLS kontroly či nahrazení transportu. Interní testy prokazují použití tohoto rozhraní pro rebinding,
redirect policy, backpressure a skutečný lokální TLS transport. Další změny kontraktu patří do review D2/D3/D4.

## Testy, oracle a hranice důkazů

- **Mock / unit:** fragmentace HTTP request/response, smuggling, limity a truncation; router bez fallbacku;
  SSE multiline/UTF-8/metadata/limity; zakázané IPv4/IPv6 rozsahy, IP aliasy, ECH/non-TLS policy;
  smíšené DNS odpovědi, rebinding a čerstvý interface snapshot; selhání resolveru/snapshotu;
  DNS timeout/cancellation s udržením bounded worker slotu; redirect bez dalšího dialu a nová kontrola cíle.
- **Měřeno lokálně:** TCP listener, přesný Host, fragmentovaný POST, SSE doručené před dokončením produceru,
  request/session timeout, stop/restart/cancellation; host-interface snapshot, sockaddr převod a skutečný libc překlad `localhost`;
  propojený typed handler → TLS upstream → SSE klient; skutečný Network.framework TLS handshake se syntetickou identitou, SNI a HTTP Host;
  nedůvěryhodný certifikát/chybný hostname odmítnuté před HTTP; TLS stream, odpojení a timeout/cancellation.
- **Neměřeno:** živé veřejné DNS/PKI/upstream služby, npm/SDK kompatibilita mimo lokální fixtures [D2](NPM.md) a [D3](MODEL-API.md), oblast a její síťové omezení,
  transparentní ECH detekce, pf/NATLOOK, souběh tří oblastí a podepsané laboratorní sondy.

Oracle: zakázaný cíl nikdy nedojde k dialu; špatná TLS identita nikdy neodešle HTTP request; redirect nevytvoří
druhé spojení; první SSE event přijde před uvolněním upstreamu; odpojení/limit nesmí vrátit částečné tělo
jako úspěch; handler chyba nesmí odhalit obsah chyby ani připojit druhou HTTP odpověď.

Mapování: příprava pro **R2/R3/R8**, části **GW-08, GW-09, GW-10, GW-12, GW-14** a **NET-13…15**.
Tyto testy **neuzavírají** žádný případ COVERAGE. S5 i jednotlivé případy zůstávají **Neověřeno**.
Laboratorní integrace D7 vyžaduje S3/S3b a nezávislou protistranu WP0.4 (již v `spikes/common`).
npm cooldown, metadata a artefaktový audit dodává [WP1.D2](NPM.md). [D3](MODEL-API.md) dodává lokální HTTPS
s oddělenou testovací CA, syntetický klíč a rate/budget. Skutečné identity/scopes a širší fixtures zůstávají další balíky.

Použité kontrakty: [HTTP/1.1 framing, RFC 9112](https://www.rfc-editor.org/rfc/rfc9112.html),
[SSE formát](https://html.spec.whatwg.org/multipage/server-sent-events.html),
[Network TLS options](https://developer.apple.com/documentation/network/nwprotocoltls/options),
[import testovací identity pouze do paměti](https://developer.apple.com/documentation/security/ksecimporttomemoryonly).

## WP1.D5 — PyPI, Homebrew a Git

[TYPED-REGISTRIES.md](TYPED-REGISTRIES.md) popisuje JSON PyPI s per-file cooldownem,
explicitní odmítnutí Homebrew bez autoritativního bottle publish-time a Git smart HTTP v0
pro přesné projektové repo. Balík je částečný; live/F0.7, D7 a S5/S6 zůstávají Neověřeno.
[Validace D5](VALIDATION-D5.md) rozlišuje unit/mock a skutečné lokální pip/Git klienty.
