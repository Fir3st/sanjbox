# API modelů — WP1.D3

Přípravný prototyp přidává `ModelAPIGateway`: úzký textový streaming Messages API, vložení pouze
syntetického klíče, konečný lokální rozpočet, rate limit a skutečný lokální HTTPS listener.
**S5, R2/R3/R8 i GW-09…14 zůstávají Neověřeno. F0.7 není uzavřené.** Neproběhlo volání veřejného
API, přihlášení, čtení Klíčenky, instalace SDK ani ověření jeho kompatibility či účtování.

## Operace a důvěryhodná konfigurace

| Část | Kontrakt tohoto prototypu |
|---|---|
| Lokální endpoint | Pouze `POST /model/v1/messages`, přesný target bez query/fragmentu/alternativního encoding |
| Upstream | Pevné `https://api.anthropic.com:443/v1/messages`, `anthropic-version: 2023-06-01`; žádný klientský host/endpoint, proxy, redirect ani retry |
| Model | Přesná shoda s trusted `allowedModels`; testy používají neexistující `fixture-model` |
| Oblast | `zoneID` z trusted konfigurace vlastníka listeneru, nikdy z hlavičky nebo body klienta |
| Klíč | `ModelAPITestKey` přijme jen laboratorní hodnotu `sanjbox-test-…`, 24–128 ASCII znaků; skutečné API klíče tento prototyp nepřijímá |
| Hlavičky klienta | Jen Host, Content-Length, Content-Type, Accept, User-Agent, Connection; pouze `Content-Type: application/json` |
| Vložené hlavičky | Handler vytvoří x-api-key, anthropic-version, Content-Type, Accept; žádnou hlavičku klienta nepřepošle |

Tělo má právě `model`, `messages`, `max_tokens`, `stream: true`. Zprávy mají právě `role` a neprázdný
textový `content`; 1–64 zpráv striktně střídá user/assistant a končí user. `max_tokens` je celé kladné
číslo do nakonfigurovaného limitu. Body parser odmítá duplicitní dekódované klíče i escapované aliasy,
hloubku nad 16 a více než 4 096 JSON uzlů. Booleany, záporná čísla a exponenty nejsou tokenový limit.

Nejsou podporovány system prompt, tools, thinking, obrázky, soubory, URL vstupy, cache directives,
assistant prefill, bety, OAuth, jiné endpointy/poskytovatelé ani non-streaming JSON odpověď.
Authorization, X-API-Key a cookies se odmítnou **i pro zástupnou hodnotu SDK**. Klient, který je neumí
vynechat, je zatím nepodporovaný. Není zde passthrough ani automatická adaptace SDK.

Každou odchozí operaci provede sdílený D1 `UpstreamClient`: nové DNS, snapshot host adres, SSRF policy,
numerický dial, TLS hostname/certificate validation. 3xx/4xx/5xx, non-SSE a chybný framing nedají
úspěšný modelový výsledek. Location ani odpověď s chybou se nevrací klientovi.

## SSE, klíč a odpojení

Podporovaný stream má právě jednu posloupnost:

`message_start → content_block_start(index 0, prázdný text) → text_delta* → content_block_stop → message_delta → message_stop`

Ping se ignoruje v rámci limitu počtu událostí. Oficiální protokol připouští více bloků a více
message_delta; ty zde nejsou podporované. Nepodporovaný typ, nesprávné pořadí, duplicate fields,
upstream error, cizí model, neplatné usage nebo nedokončený stream ukončí spojení bez terminálního
`message_stop`. Ten se vydá až po potvrzení úplného HTTP těla D1, takže následná chyba/truncation
nemůže být vydaná jako úplný výsledek. Před chybou mohl klient již obdržet část ověřeného textu.

Výstup se rekonstruuje z pevného schématu. Upstream ID se nahradí lokálním ID; hlavičky, cookies,
chybové zprávy a neznámá pole se nevydávají. Usage jsou jen omezené nezáporné diagnostické počty,
nikdy podklad pro vracení rozpočtu. Stop reason je jen `end_turn`/`max_tokens`, stop_sequence je null.

Každý parsovaný string se kontroluje na přesnou hodnotu syntetického klíče. Textové delty mají
bounded holdback posledních `délka klíče − 1` bajtů (s dorovnáním UTF-8), aby se celý klíč nevydal ani
při rozdělení přes více SSE událostí/TCP čtení. To může zpozdit krátkou odpověď až do konce bloku.
**Není to obecná DLP záruka:** neprokazuje ochranu proti změně encodingu, transformovanému/skrytému
kanálu nebo skládání fragmentů mezi nezávislými požadavky. Živý provider a skutečné tajemství nejsou
tímto mockem autorizované; invariant PLAN se nesnižuje. Testy dokazují přesně uvedené přímé echo případy.

Každý emit se awaituje až do socket sendu. Během čekání consumeru se nečte další upstream část,
nevzniká neomezená fronta. Timeout/cancellation zavře upstream a uvolní aktivní slot. D1 listener
po dokončeném requestu sleduje jedním receive (max. 1 bajt) odpojení a zakázaná další data. EOF/error
zruší práci i během čekání na upstream. **Request half-close a pipelining jsou nepodporované**;
klient pro SSE musí držet obousměrné spojení. Deadline je kooperativní: structured task group čeká
na ukončení child tasku a nespolupracující vlastní consumer může návrat zdržet. D1 consumer používá
socket send a session close/lifetime cancellation; vlastní consumer musí cancellation respektovat.

## Rate, rozpočet a audit

Rozpočet je **konečný počet lokálních jednotek**, ne peníze ani odhad providerových tokenů. Vlastník
konfigurace zvolí kladný `chargePerRequest` pro celý povolený rozsah vstupu/max_tokens. Každý zahájený
pokus spotřebuje celou částku; počet pokusů je nejvýše `floor(budgetUnits / chargePerRequest)`.
Nezáleží na údaji usage, skutečně vydaném textu ani na tom, zda poskytovatel nakonec něco účtuje.
Pro finanční limit chybí schválená identita/scopes, aktuální cenový kontrakt a persistentní účetnictví.

Rezervace/debit proběhne atomicky na actoru **až při spuštění single-use SSE produceru**, před prvním
await. Nepoužitá odpověď neobsadí slot; opakované/souběžné spuštění téhož produceru selže. Paralelní
operace nemohou utratit tutéž zbývající kapacitu. Debit se nevrací ani při DNS chybě, timeoutu,
zrušení či odpojení; vzdálené účtování nelze odvolat. Rate se počítá v klouzavém okně pomocí
ContinuousClock; zpětný posun injektovaných hodin selže zavřeně. Žádné automatické obnovování budgetu.

Protože rezervace je lazy, odmítnutí rate/budget může nastat až po lokálních HTTP 200 SSE hlavičkách:
spojení skončí bez dokončovací události a **bez upstream requestu**. Klient nesmí samotné HTTP 200
považovat za úspěšnou generaci. Chybové detaily ani syntetický klíč se do odpovědi/logů nepíšou.

| Limit | Výchozí hodnota / tvrdá konfigurační mez |
|---|---|
| Request JSON | 32 KiB / 64 KiB; 64 zpráv |
| max_tokens | 1 024 / 8 192 |
| Jeden příchozí SSE JSON | 16 KiB |
| Celý rekonstruovaný SSE výstup | 256 KiB / 1 MiB |
| Počet událostí včetně ping | 4 096 / 16 384 |
| Rate | 10 pokusů / 60 s; nejvýše 1 000/okno, okno do 24 h |
| Aktivní operace | 2 / 32, současně platí D1 upstream cap |
| Kooperativní deadline streamu včetně consumeru | 60 s / 120 s; nikoli tvrdý limit pro cizí nespolupracující consumer |
| Audit | 1 024 / 10 000 záznamů; plný audit odmítne další pokus |

`auditRecords()` obsahuje lokální ID, trusted zone/model, účtované jednotky a running/completed/
cancelled/failed. Completed znamená korektně dokončený relay do consumeru, ne instalaci, úplné
přečtení klientem ani provider billing. Prompty, odpovědi a klíče se neukládají. Trusted vlastník
exportuje `takeFinishedRecords()`; běžící záznamy nejdou odebrat. Export nevrací budget ani rate slot.
**Stav je v paměti:** nový proces/nová instance s novým budgetem není trvalý finanční limit. Ukládání,
obnova, revokace a přidělení budgetu patří do pozdějšího schváleného provozního kontraktu.

## HTTPS a per-zone CA

D1 `GatewayServer(..., tls: GatewayTLSConfiguration)` nyní skutečně přijímá TLS 1.2+ a HTTP/1.1.
Bez parametru zůstává explicitní HTTP režim. TLS listener nepřijme plaintext HTTP; nemá downgrade.
Stále binduje pouze `127.0.0.1` a vyžaduje přesný HTTP Host `127.0.0.1:<port>`.

Trusted vlastník dodá samostatnou leaf identitu podepsanou CA konkrétní oblasti se SAN **IP:127.0.0.1**.
`GatewayTLSConfiguration(pkcs12:passphrase:)` importuje nejvýše 64 KiB PKCS#12 pouze do paměti pomocí
`kSecImportToMemoryOnly`; nic nehledá v Klíčence ani neinstaluje do trust store. Alternativou je
explicitně dodané SecIdentity. Privátní CA/leaf klíče zůstávají mimo oblast; klient dostane jen veřejný
CA certifikát a base URL `https://127.0.0.1:<port>/model`. V klientovi musí být explicitně ověřená
důvěra k této CA a hostname; nikdy `verify=false`, `-k` nebo globální instalace CA.

Test `ModelTLSMaterial` v `ModelAPITLSTests.swift` je reprodukovatelný issuer fixture: systémový
openssl vytvoří novou CA a leaf v novém adresáři 0700, paměťový import, po sobě smaže pouze vlastní
dočasný adresář. Dvě CA jsou nezávislé; klient s cizí/neznámou CA nebo chybným jménem handshake odmítne.
Test používá explicitní test anchors a vypíná síťový fetch při validaci, ne systémové trust výjimky.
Provisioning/rotace skutečných identit a konfigurace jednotlivých SDK zde nejsou implementované.

**CA ověřuje server, nikoli UID klienta.** Loopback, port ani CA nejsou důkaz per-UID/per-session
izolace. Jedna trusted instance handleru se musí svázat s jednou zónovou cestou; jiné procesy na hostu
mohou před branami S3/S8 port oslovit. Žádný klientský claim nemůže změnit zoneID. Vlastnictví listeneru,
port squatting, pf cesta a autentizace oblasti vyžadují samostatné důkazy.

## Integrace a bezpečný test

**[implementátor]** Konstrukční příklad; nic nespouští ani nevolá veřejné API. Volající nejdřív ověří
vlastní identitu přes WP0.3 jako stávající CLI. PKCS#12 i upstream v testu pocházejí pouze z fixture:

```swift
@MainActor
func preparedModelListener(pkcs12: Data, passphrase: String,
                           fixtureUpstream: UpstreamClient) throws -> GatewayServer {
    let policy = try ModelAPIConfiguration(
        zoneID: "zone-fixture", allowedModels: ["fixture-model"],
        budgetUnits: 100, chargePerRequest: 10)
    let handler = try ModelAPIGateway(
        configuration: policy,
        testKey: ModelAPITestKey("sanjbox-test-fixture-never-a-live-key-12345"),
        upstream: fixtureUpstream)
    return GatewayServer(router: try TypedRouter(routes: [handler.route()]),
                         tls: try GatewayTLSConfiguration(pkcs12: pkcs12, passphrase: passphrase))
}
```

CLI `--mode mock` zůstává původním D1 demem. Praktický D3 end-to-end důkaz je lokální test
`modelHTTPSUsesZoneCAAndRejectsWrongRootNameUntrustedAndPlainHTTP`: skutečný HTTPS klient → D1 listener
→ typed D3 → D1 UpstreamClient se scripted transportem → ověřený SSE klientovi. Upstream transport je
mock; D1 sada samostatně testuje skutečný upstream TLS. Není to důkaz Anthropic SDK ani veřejné PKI.

```bash
swift test --package-path spikes/s5-gateway
```

Testy používají pouze syntetické hodnoty, mock DNS a loopback. Nespouštějí SDK, instalační skripty,
sudo ani uživatelské účty. **[uživatel]** Pro tyto testy není potřeba privilegovaný laboratorní slot,
TCC grant nebo skutečný klíč. Úklid socketů a vlastních dočasných certifikátů je automatický.

Ověřeno 2026-11-03 na arm64 macOS 27.2 / Swift 6.4: **61 debug testů prošlo, 0 skips**,
z toho 16 nových D3. Pokrytí zahrnuje přímé echo klíče i všechny jeho rozdělovací body mezi deltami,
UTF-8, chyby/truncation, bezvýhradné odmítnutí redirectů, souběžný debit a concurrency cap, rate hranici,
timeout/cancel, lazy/repeated producer a reálné HTTPS trust/disconnect případy. Použitý příkaz:

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/sanjbox-d3-module-cache \
  swift test --package-path spikes/s5-gateway \
  --scratch-path /private/tmp/sanjbox-d3-build \
  --cache-path /private/tmp/sanjbox-d3-cache --disable-sandbox
```

Hostitelský sandbox musel povolit lokální listenery. Release sestava a nezávislé review jsou
samostatné kontroly finálního commitu; uvedený počet je debug výsledek této větve nad D1.

Mapování: příprava GW-09…14 a R2/R3/R8. Živá identita/scopes/revokace F0.7, matice SDK D6 a cesta
z oblasti D7 zůstávají otevřené. Hotový balík D3 neuzavírá žádný případ ani bezpečnostní bránu.

## Primární kontrakty

- [Anthropic Messages](https://platform.claude.com/docs/en/api/messages/create): POST, messages, max_tokens a stream.
- [Anthropic streaming](https://platform.claude.com/docs/en/build-with-claude/streaming): pořadí událostí, text_delta, errors, message_stop a kumulativní usage; tento spike podporuje užší schéma.
- [Anthropic versioning](https://platform.claude.com/docs/en/api/versioning): explicitní version header; zde pin 2023-06-01 bez beta rozšíření.
- [Apple NWParameters TLS](https://developer.apple.com/documentation/network/nwparameters/init(tls:tcp:)) a [paměťový import](https://developer.apple.com/documentation/security/ksecimporttomemoryonly): explicitní TLS listener a import bez zápisu do Klíčenky.
