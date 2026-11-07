# proto/gateway — brána jako služba (WP1.H4, prototyp)

Prototyp proudu H podle [IMPLEMENTATION §3](../../docs/IMPLEMENTATION.md#3-fáze-a-pracovní-balíky)
a [PLAN.md](../../PLAN.md): **jeden proces**, který složí typované handlery ze
[`spikes/s5-gateway`](../../spikes/s5-gateway) podle politiky, a poskytovatele klíčů
drží jen jako rozhraní s mockem.

Balík **nedokazuje žádnou bránu** (S5 ani jiná zůstávají Neověřeno) a **nesmí se sestavit
do běžícího celku**. Otevřený socket, Klíčenka, skutečná oblast ani skutečný upstream
nejsou součástí prototypu. Ve F2 ho převezme WP2.5.

## Co je hotové

| Část | Soubor | Stav |
|---|---|---|
| Verzovaný draft politiky, striktní decoding | `Sources/SanjboxGatewayService/Policy.swift` | hotovo, čeká na formát z WP1.H1 |
| Skládání handlerů a deterministické odmítání | `Sources/SanjboxGatewayService/Composition.swift` | hotovo |
| Poskytovatel klíčů: protokol + mock | `Sources/SanjboxGatewayService/KeyProvider.swift` | hotovo |
| Deterministický audit rozhodnutí | `Sources/SanjboxGatewayService/Audit.swift` | hotovo |
| In-process dispatch, framing, opt-in listener | `Sources/SanjboxGatewayService/Transport.swift` | hotovo |
| CLI obálka (`--policy`, `--listen`) | `Sources/SanjboxGatewayService/Command.swift` | hotovo |
| Testy | `Tests/SanjboxGatewayServiceTests/` | 54 testů, bez sítě a bez portu |

### Které handlery jsou skutečně složené

Skutečně složené (policy → konfigurace → `route()` → `TypedRouter` → handler):

| Operace | Handler ze spike | Mount | Poznámka |
|---|---|---|---|
| `npm` | `NPMGateway` (WP1.D2) | z politiky (`/npm`) | limit `metadataBytes`/`artifactBytes`/`auditRecords`/`operations`/`lifetime` |
| `pypi` | `PyPIGateway` (WP1.D5) | z politiky (`/pypi`) | `RegistryLimits` + `cooldownSeconds` |
| `git` | `GitGateway` (WP1.D5) | z politiky (`/git`) | D5 obsluhuje jen pevný projekt `project.git`; jiná cesta se odmítne už v politice |
| `model` | `ModelAPIGateway` (WP1.D3) | pevně `/model` | mount musí být `/model`; klíč výhradně z `KeyProvider` |

Deklarované, ale záměrně nesložené:

- **Homebrew** (`HomebrewGateway` ve `spikes/s5-gateway`) — jeho vlastní dokumentace
  ([`TYPED-REGISTRIES.md`](../../spikes/s5-gateway/TYPED-REGISTRIES.md), WP1.D5) říká, že bez
  přijatého zdroje času publikace lahve **vždy odmítne**. Složit ho do brány by vyrobilo
  "zelený" mount, který nikdy nic neobslouží a jen by maskoval chybějící kontrakt.
  Operace `homebrew` proto v draftu politiky **není**; `"operation": "homebrew"` je chyba
  validace (`unknownOperation`), ne tichý průchod.
- Skutečná Klíčenka, scopes a revokace — mimo rozsah, viz níže.

## Draft politiky (čeká na WP1.H1)

Formát v `Policy.swift` je **provizorní lokální návrh** (`schemaVersion: 1`). Až WP1.H1
přinese formát politiky, mění se **jen dekodér a mapování na typy**; výměna formátu
**nesmí změnit chování handlerů** — složení pracuje s `GatewayPolicy`/`GatewayRule`,
nikdy s JSONem, a handler dostává stejnou konfiguraci jako dnes.

Vlastnosti draftu:

- `Codable`, explicitní `schemaVersion` (jiná verze = `unsupportedVersion`, žádná migrace).
- **Striktní decoding**: neznámé pole kdekoliv v dokumentu = `unknownField` s cestou pole
  (seřazené, aby výsledek nezávisel na pořadí klíčů), chybějící pole = `missingField`.
  Žádné implicitní doplňování hodnot.
- Křížová validace: jedinečná operace i mount, mount `"/" + [a-z0-9-]{1,63}`, `zoneID`,
  `auditCapacity`, rozsahy všech limitů **shodné s kontraktem handleru** (WP1.D5), takže
  chyba v politice se pozná dřív než v handleru.
- `enabled: false` = deklarováno, ale neskládá se. Požadavek na vypnutý mount se
  deterministicky odmítne (403) a audituje; nikdy nepropadne dál.

Příklad (zkráceně, celý je ve `Fixture.policyJSON` v testech):

```json
{
  "schemaVersion": 1,
  "zoneID": "zone-fixture-01",
  "auditCapacity": 256,
  "gateways": [
    {
      "operation": "npm",
      "enabled": true,
      "mount": "/npm",
      "publicOrigin": "http://127.0.0.1:18765",
      "upstreamHostname": "registry.npmjs.org",
      "artifactHostnames": [],
      "cooldownSeconds": 3600,
      "limits": {
        "metadataBytes": 4194304, "artifactBytes": 4194304, "files": 10000,
        "operations": 4, "auditRecords": 1024, "lifetimeSeconds": 90
      }
    }
  ]
}
```

`publicOrigin` musí být `http://127.0.0.1:<port>` — stejné pravidlo, jaké vynucuje
`NPMConfiguration`/`PyPIConfiguration` (žádný veřejný origin, žádný hostname).
Ostatní voliče handleru (cache, redirecty, `maximumVersions`, …) zůstávají na
konzervativních výchozích hodnotách handleru; politika je záměrně nevystavuje, dokud
je H1 nepřinese jako kontrakt.

## Skládání a odmítání

`GatewayService.dispatch` dělá tři věci **před** handlerem a jednu po něm:

1. Klasifikuje `request.path` podle **tabulky mountů z politiky** (ne podle sestaveného
   routeru). Neznámý mount = 404 `operationNotConfigured`; vypnutý = 403 `operationDisabled`.
2. Zkontroluje kapacitu auditu; plná kapacita = 503 `auditSaturated` **bez** zahození
   historie (žádné tiché přepisování).
3. Předá požadavek `TypedRouter` z WP1.D1, který sám odmítá zakázané hlavičky
   (`authorization`, `cookie`, `x-api-key`, …) a metody.
4. Zapíše rozhodnutí do auditu (i to odmítnuté handlerem).

Neexistuje větev, která by požadavek předala dál "protože mount nesedí" nebo která by
mount z požadavku odvodila. Zdroj mountu je výhradně politika.

## Audit

`AuditRecord` má pevná typovaná pole (`sequence`, `operation`, `method`, `path`,
`decision`, `reason`, `status`) a **žádné volné textové pole**, do kterého by mohl
proniknout klíč, hlavička nebo tělo. Kanonický řádek:

```
1|npm|GET|/npm/library-fixture|denied|operationDisabled|403
```

Pořadí je pořadí dokončených rozhodnutí, `sequence` roste od 1. Při sériovém dispatchi
( takto testy postupují) je text bit po bitu stejný mezi běhy; to je i test.

## Poskytovatel klíčů

```swift
public protocol KeyProvider: Sendable {
    func key(for operation: GatewayOperation) -> ModelAPITestKey?
}
```

- `MockKeyProvider` vrací jen syntetický `ModelAPITestKey` z WP1.D3
  (`"sanjbox-test-…"`). `description`/`debugDescription` jsou redigované a testy
  ověřují, že se text klíče neobjeví v auditu ani v popisu služby.
- **Skutečná Klíčenka je mimo rozsah.** GUIDE §3 zakazuje čtení tajemství; prototyp
  neumí číst Klíčenku, scopes ani revokace a nesmí se k tomu "domyslet".
- Chybí-li klíč pro zapnutou modelovou operaci, **složení selže** (`keyUnavailable`),
  nevznikne služba, která by modelový mount jen tiše odmítala.

## Proces a transport

- Testy i CLI používají **in-process dispatch** (`GatewayService.dispatch`). Žádný test
  neotevírá port; integrační testy jdou přes skutečné aktéry ze `spikes/s5-gateway`
  s mock resolverem, který každé volání odmítne — dokazují cestu kódu, ne síť.
- `LoopbackConnection` je testovaný framing (`ByteChannel` + in-memory mock),
  včetně chunked SSE a chování při zkráceném streamu.
- `LoopbackListener` (reálný POSIX socket na `127.0.0.1:<port>`) se konstruuje **jen**
  na explicitní `--listen 127.0.0.1:<port>`. Bez něj CLI složení jen vypíše a skončí
  s "no socket opened". **Otevřený socket není součástí prototypu** a žádný test ho
  nespouští; IMPLEMENTATION §3 zakazuje sestavit běžící celek.

## Rozhraní (pro H2, H3, H5, H6 a WP2.5)

```swift
public enum GatewayOperation: String, CaseIterable, Comparable { case npm, pypi, git, model }

public struct GatewayPolicy {                  // Codable, draft v1
    static let currentSchemaVersion: Int
    let schemaVersion: Int; let zoneID: String; let auditCapacity: Int
    let gateways: [GatewayRule]
    static func decode(_ data: Data) throws -> GatewayPolicy
    var enabledRules: [GatewayRule]
    func rule(for: GatewayOperation) -> GatewayRule?
    func rule(forMount: String) -> GatewayRule?
}

public enum GatewayRule { case npm(NPMRule), pypi(PyPIRule), git(GitRule), model(ModelRule) }
public struct NPMRule / PyPIRule / GitRule / ModelRule   // + RegistryRuleLimits, AnyCodingKey
public enum PolicyError: Error, Equatable { malformed, unsupportedVersion, unknownOperation,
    unknownField, missingField, invalidField, duplicateOperation, duplicateMount, emptyGateways }

public struct GatewayRuntimeConfiguration {    // neměnný pohled na složení
    let zoneID, auditCapacity, entries: [RouteTableEntry]
    var activeOperations, declaredOperations: [GatewayOperation]
    func classify(path: String) -> RouteClass   // .unknown / .disabled(op) / .active(op)
    var summaryLines: [String]
}

public enum CompositionError: Error, Equatable { policy, handlerConfiguration, keyUnavailable, invalidRouter }

public actor GatewayService {
    init(policy: GatewayPolicy, keyProvider: any KeyProvider = MockKeyProvider(),
         upstream: UpstreamClient = UpstreamClient()) throws
    nonisolated let runtime: GatewayRuntimeConfiguration
    func dispatch(_ request: HTTPRequest) async throws -> GatewayReply
    func auditRecords() -> [AuditRecord]; func auditText() -> String
    func auditSaturationCount() -> UInt64
}

public struct AuditRecord: Codable, Equatable { sequence, operation, method, path, decision, reason, status
    var canonicalLine: String }
public enum AuditDecision { routed, denied }; public enum DenialReason { operationNotConfigured,
    operationDisabled, auditSaturated }

public protocol KeyProvider; public struct MockKeyProvider   // .unavailable, .defaultModelKey
public protocol ByteChannel; public struct LoopbackConnection
public struct LoopbackListener { struct Address { init?(text: "127.0.0.1:<port>") }; func run(serving:) }
public enum GatewayCommand { enum Invocation; static func parse([String]) throws -> Invocation
    static func run([String]) async -> CommandResult }   // exit 0/2/3/4
```

CLI:

```
sanjbox-gateway-service --policy <file> [--listen 127.0.0.1:<port>] [--help]
```

## Testy a brány

```bash
swift build --package-path proto/gateway -c debug
swift build --package-path proto/gateway -c release
swift test  --package-path proto/gateway -c release
swift test  --package-path spikes/s5-gateway -c release   # závislý balík zůstal zelený
/usr/bin/python3 -m unittest discover -s tools/tests
```

Testy (54) pokrývají: validaci politiky pozitivně i negativně (neznámé pole/operace,
verze, mount, origin, limity), zakázanou operaci a neznámý mount (auditované odmítnutí),
chybějící klíč, mock klíč nikdy v logu, deterministický audit a jeho kapacitu, framing
transportu, a integraci přes **skutečné** npm/PyPI/git/model handlery s lokálními fixtures
a mock resolverem — bez sítě, bez instalace balíčků, bez portu.

## Co tento balík nedokazuje

- Že brána drží v produkci: S5/GW zůstávají **Neověřeno**, žádná brána neprošla.
- Že politika odpovídá H1: je to draft; výměna formátu je očekávaná.
- Že fungují skutečné upstreamy, Klíčenka, revokace, schvalování ani běžící služba.
- Že POSIX listener je produkčně správný: je za explicitním flagem a mimo rozsah prototypu.

## Omezení draftu, která je třeba při převzetí WP2.5 rozhodnout

1. `git` podporuje jen pevný projekt `/project.git` (vlastnost `GitGateway.operation()`
   z WP1.D5). Jiná cesta je odmítnuta už v politice, místo aby vznikla neobsluhovaná route.
2. `model` mount je pevně `/model` (`ModelAPIGateway.route()`); politika jiný mount odmítne.
3. Politika nevystavuje všechny voliče handlerů (cache, redirecty, `maximumVersions`);
   dokud nejsou v H1, platí konzervativní výchozí hodnoty handleru.
4. Homebrew chybí záměrně (viz výše) — do H1 je třeba rozhodnout, zda mount vůbec existuje.
