# proto/gateway — brána jako služba (WP1.H4, prototyp)

Jeden proces skládá skutečné typované handlery z
[`spikes/s5-gateway`](../../spikes/s5-gateway) podle H1 `NetworkPolicy` přes explicitní
[adaptér a doplňkovou konfiguraci](H1-ADAPTER.md), nebo podle samostatného lokálního draftu.
`KeyProvider` je rozhraní se syntetickým mockem. Jde o izolovaný prototyp proudu H
podle [IMPLEMENTATION §3](../../docs/IMPLEMENTATION.md#3-fáze-a-pracovní-balíky),
ne o sestavenou oblast ani bezpečné MVP. **S5/GW, R2/R3 a ostatní brány zůstávají Neověřeno.**

H1 adaptér napojuje [`proto/contracts`](../contracts) na skutečný `GatewayService.dispatch`
i loopback listener. Přesná podporovaná podmnožina a rozdíl vůči CLI jsou v
[H1-ADAPTER.md](H1-ADAPTER.md); produkční integrace tím nevzniká.
[VALIDATION.md](VALIDATION.md) uvádí přesnou otestovanou revizi a rozsah lokálních testů.

## Co je implementováno

| Část | Rozsah |
|---|---|
| `Policy.swift`, `PolicyJSON.swift` | uzavřený draft v1, omezený JSON vstup, validace polí a limitů |
| `H1GatewayAdapter.swift` | přesné gate ID bindingy, deny-all, žádné širší cíle/metody/limity |
| `Composition.swift` | npm, PyPI, Git a modelový handler, deterministický deny a audit |
| `KeyProvider.swift` | protokol a syntetický mock; žádná Klíčenka |
| `Audit.swift`, `StreamOutcome.swift` | rezervace auditu, jednorázový SSE výsledek, kanonický text |
| `Transport.swift` | in-memory kanál i opt-in POSIX loopback listener s omezenými prostředky |
| `Command.swift` | složení bez socketu, explicitní `--listen`, pravdivá readiness a exit kódy |

Skutečné cesty jsou policy → konfigurace → `route()` → `TypedRouter` → handler:

| Operace | Handler | Omezení |
|---|---|---|
| `npm` | `NPMGateway` | read-only; `limits.files` omezuje počet verzí packumentu, ostatní limity se mapují na handler |
| `pypi` | `PyPIGateway` | `RegistryLimits`, publication-time/hash/cooldown |
| `git` | `GitGateway` | jen `/project.git`, push pouze při explicitním `allowPush` |
| `model` | `ModelAPIGateway` | pevný mount `/model`, textové Messages SSE, konečný lokální budget/rate |

Homebrew se neskládá: D5 bez přijatého zdroje data publikace lahve vždy odmítá.
`"operation":"homebrew"` je chyba politiky, žádný passthrough. Limity a nepodporované
varianty handlerů platí dál podle dokumentace D1–D5; složení je nerozšiřuje.

## Draft politiky a mezera vůči H1

Wire vstup přijímá pouze `GatewayPolicy.decode(Data)`. Typ je `Encodable`, nikoli
veřejně `Decodable`, takže nelze omylem obejít preflight přes `JSONDecoder`.

- Nejvýše 65 536 bajtů a hloubka 8; CLI načte nejvýše limit + jeden bajt.
- Duplicitní **dekódované** klíče jsou odmítnuté i po Unicode escape a uvnitř objektů.
- Celočíselná pole přijímají jen desetinné číslice, žádné exponenty nebo zaokrouhlené
  zlomky. Pouze `cooldownSeconds` připouští konečné nezáporné desetinné číslo.
- Neznámé/chybějící pole, verze a operace jsou chyba; žádné implicitní doplnění.
- Operace i mount jsou jedinečné. Mount má tvar `/[a-z0-9-]{1,63}`; limity se
  validují před sestavením handleru. Zapnutý handler navíc validuje své hostname/config.
- `enabled:false` se neskládá a odpoví 403. Neznámý mount odpoví 404.

Příklad s jedinou operací; plný syntetický vstup je `Fixture.policyJSON` v testech:

```json
{
  "schemaVersion": 1,
  "zoneID": "zone-fixture-01",
  "auditCapacity": 256,
  "gateways": [{
    "operation": "npm", "enabled": true, "mount": "/npm",
    "publicOrigin": "http://127.0.0.1:18765",
    "upstreamHostname": "registry.npmjs.org", "artifactHostnames": [],
    "cooldownSeconds": 3600,
    "limits": {
      "metadataBytes": 4194304, "artifactBytes": 4194304, "files": 10000,
      "operations": 4, "auditRecords": 1024, "lifetimeSeconds": 90
    }
  }]
}
```

`publicOrigin` musí být kanonické `http://127.0.0.1:<port>`; pro zapnuté registry
musí při `--listen` souhlasit se skutečnou adresou listeneru. Jinak listener odmítne
start před bindem. Cache a redirecty používají konzervativní výchozí hodnoty handleru.

H1 používá `schema/defaultAction/gates` a vyžaduje explicitní doplňkovou konfiguraci
podle [H1-ADAPTER.md](H1-ADAPTER.md). `H1GatewayAdapter.decode` ověří H1 wire a vazby;
`GatewayService(adapting:)` drží H1 oprávnění i při dispatchi a obsluze socketu.
Samostatný CLI `--policy` dál přijímá pouze výše uvedený draft. H1 wire se mu odmítne;
veřejná H1 cesta je knihovní API, nikoli automatická migrace CLI konfigurace.

## Směrování, audit a poskytovatel klíčů

`GatewayService.dispatch` klasifikuje cestu podle politiky, odmítne neznámý/vypnutý
mount a řídicí znaky nebo `|` v metodě/cestě. Před handlerem rezervuje místo v auditu.
Plný audit vrátí 503 a zvýší počítadlo saturace; handler se vůbec nespustí. Kapacita se
neobnovuje rotací ani přepisem historie, jen vznikem nové služby.

`TypedRouter` a handlery odmítají klientské autorizační hlavičky, nepovolené metody
nebo operace. Status upstreamu se sám nepovažuje za lokální kapacitní odmítnutí:
pro něj existuje `HTTPResponse.rejection = .capacity`.

Audit obsahuje `sequence/operation/method/path/decision/reason/status`, nikdy hlavičky
ani tělo requestu. Důvody jsou stabilní značky, nikoli text upstream chyby. Cesta je
klientský text, nikoli důkaz identity nebo neškodného obsahu. `%`, `|` a řídicí znaky
se escapují; řádek má vždy sedm polí a parser přijímá jen kanonický round-trip.

```text
1|npm|GET|/npm/library-fixture|denied|operationDisabled|403
```

Rozhodnutí jsou `routed`, `denied`, `deniedByHandler`, `pending`, `failed`, `cancelled`.
SSE má nejprve `pending/0` a spotřebovává kapacitu i při nevyužitém producentovi.
Producent je jednorázový; replay nemůže spustit druhý upstream ani přepsat audit.
Při transportu se úspěch zapíše až po terminálním HTTP chunku, takže jeho send failure
končí `failed/streamFailed/502`. Při přímém dispatchi bez transportu audit dokládá jen
výsledek producenta. Po prvním eventu může mít klient HTTP 200, ale konečný audit 502
s useknutým streamem. `cancelled` má status 0. Souběžné requesty se řadí podle commitů
do auditu, ne podle času přijetí; sériové běhy jsou deterministické.

`npmDownloadRecords()` a `pypiDownloadRecords()` jsou samostatné audity artefaktů.
`HTTPResponse.completeTransport(true/false)` dokončí callback nejvýše jednou i při
kopii/souběhu. `transportAccepted` dokládá lokální send, nikoli převzetí klientem;
requestové `routed` samotné send neprokazuje. Audit není perzistentní ani podepsaný.

`KeyProvider.key(for:)` vrací pouze syntetický `ModelAPITestKey`. Chybějící modelový
klíč odmítne celé složení. Mock se nevypisuje v logu, description je redigovaný; CLI
výslovně uvádí syntetický zdroj. Handler může mock vložit do upstream requestu.
Žádná implementace nečte skutečné tajemství, Klíčenku, scopes ani revokace.

## Transport a jeho hranice

Bez `--listen` CLI pouze složí službu, vypíše konfiguraci a skončí bez socketu.
Opt-in listener používá IPv4 `127.0.0.1`, `O_NONBLOCK`, `FD_CLOEXEC` a `SO_NOSIGPIPE`.
Obsluhuje jeden HTTP/1.1 request na spojení; nepodporované/chybné framingy zavře.
SSE vrátí před prvním eventem pravdivou 403/429/503/502; po začátku chyby ukončují
stream bez terminálního chunku a bez druhé odpovědi.

Výchozí meze: 16 obsluhovaných klientů, kernel listen backlog 16, 10 sekund na jednu
read/send operaci a pevný 120sekundový deadline kontrolovaný při socketovém I/O.
Příchozí data deadline neprodlužují. Upstream má navíc vlastní limity handleru;
socketový deadline není samostatný časovač, který přeruší libovolný cizí resolver.
Při plné kapacitě další spojení čekají v kernelové frontě. Strukturovaná skupina drží
nejvýše stanovený počet tasků; zrušení `run` zruší a vyčká obsluhy, zavře sockety a
uvolní port. Nejde o výkonový benchmark: neblokující syscally se při čekání opakují
po 5 ms. Aktuální CLI při SIGTERM ukončí proces; ověřené OS uzavření socketů není
důkaz trvalého auditu nebo graceful service shutdown.

CLI vypisuje `listener starting` před runnerem a `listener ready` teprve po úspěšném
bind/listen. Aktivní výstup jde okamžitě i do pipe. Selhání startu vrátí exit 4 a jeden
řádek `listener stopped`; špatné argumenty/I/O mají exit 2, politika/složení exit 3.
Duplicitní `--policy` a `--listen` jsou odmítnuté.

**Listener neautentizuje klienta.** `zoneID` je statický štítek politiky; nepochází z
ověřeného UID, audit tokenu nebo session. Port je přístupný jiným lokálním procesům,
Host hlavička nedokazuje původ a žádná bind policy ani pf ochrana se zde nezavádí.
Odmítání klientských credentials chrání upstream request, ale neověřuje oprávnění
volajícího. Výchozí `UpstreamClient` umí síť; při explicitním `--listen` mohou zapnuté
handlery kontaktovat konfigurované HTTPS upstreamy (model jen se syntetickým klíčem).
Ověření v tomto balíku používá výhradně mock upstreamy a místní sockety.

## Ověření a úklid

```bash
swift build --package-path proto/gateway -c debug
swift build --package-path proto/gateway -c release
swift test --package-path proto/gateway -c debug
swift test --package-path proto/gateway -c release
/usr/bin/python3 proto/gateway/Tests/listener_cli.py proto/gateway/.build/debug/sanjbox-gateway-service
/usr/bin/python3 proto/gateway/Tests/listener_cli.py proto/gateway/.build/release/sanjbox-gateway-service
swift test --package-path spikes/s5-gateway -c debug
swift test --package-path spikes/s5-gateway -c release
/usr/bin/python3 -m unittest discover -s tools/tests
```

117 Swift testů zahrnuje devět skutečných loopback/socket testů a odmítnutí nesouladu
originu před bindem, úspěšný přenos
syntetického npm artefaktu, zrušení aktivního modelového handleru, timeout/backpressure,
kapacitu a opětovný bind po úklidu. Dalších pět subprocess CLI testů ověřuje výchozí
režim, kolizi portu bez falešného ready, chybný JSON/adresu, nesoulad originu a skutečnou
HTTP obsluhu včetně ukončení procesu. Ostatní testy skládají skutečné D1–D5 handlery
s paměťovým upstreamem, včetně npm/PyPI auditů, Git, modelového budget/rate, saturace,
replay a SSE chyb před/po eventu i při posledním chunku.

Testy vytvářejí pouze vlastní dočasné policy soubory, syntetická data a lokální
sockety. Jejich úklid zavírá vlastní descriptory/procesy a odstraňuje vlastní temporary
adresář; nemění systém, pf ani uživatele. Potvrzení bran vyžaduje samostatné laboratoře
podle PLAN/GUIDE; lokální úspěch nezavírá identitu klienta,
produkční lifecycle, TLS/trust, autentizaci, živé upstreamy ani billing.
