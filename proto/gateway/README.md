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
| Testy | `Tests/SanjboxGatewayServiceTests/` | 76 testů, bez sítě a bez portu |

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

`GatewayService.dispatch` dělá **před** handlerem tohle (a jednu věc po něm):

1. **Hraniční kontrola tvaru:** `path` i `method` nesmí obsahovat `|` ani řídicí znaky.
   Takový požadavek = 400 `invalidRequestTarget`, auditovaný, ale handler se nezavolá;
   hodnota z požadavku tak nemůže podvrhnout pole auditního řádku (viz Audit).
2. Klasifikuje `request.path` podle **tabulky mountů z politiky** (ne podle sestaveného
   routeru). Neznámý mount = 404 `operationNotConfigured`; vypnutý = 403 `operationDisabled`.
3. **Rezervuje místo v auditu ještě před handlerem** (fail-closed). Plná kapacita = 503
   `auditSaturationCount += 1`, **žádný** záznam a handler se **nezavolá**; dokončená
   historie se nezahazuje ani nepřepisuje. Rezervace se po zápisu spotřebuje, takže se záznam po
   obsloužení požadavku nikdy tiše nezahodí (dřívější chyba: záporné `reserved`).
4. Předá požadavek `TypedRouter` z WP1.D1, který sám odmítá zakázané hlavičky
   (`authorization`, `cookie`, `x-api-key`, …) a metody.
5. Zapíše rozhodnutí do auditu: `routed` pro běžnou odpověď handleru,
   `denied` pro odmítnutí bránou nebo `deniedByHandler` pro odmítnutí handlerem.
   Lokální kapacitní 503 nese explicitní `HTTPResponse.rejection = .capacity`;
   samotný status upstreamu se za kapacitní odmítnutí nepovažuje.
6. SSE nejdřív zapíše jako `pending` a vrátí jednorázového producenta. Po jeho
   skutečném dokončení finalizuje tentýž auditní slot: `routed`, `deniedByHandler`
   s důvodem `modelBudget`/`modelRate`/`handlerCapacity`, `failed` nebo `cancelled`.
   Nepoužitý producent zůstane `pending`; stále spotřebovává kapacitu. Replay
   nemůže znovu spustit handler ani přepsat konečný výsledek.

Neexistuje větev, která by požadavek předala dál "protože mount nesedí" nebo která by
mount z požadavku odvodila. Zdroj mountu je výhradně politika.

## Audit

`AuditRecord` má pevná typovaná pole (`sequence`, `operation`, `method`, `path`,
`decision`, `reason`, `status`). Hlavičky ani tělo požadavku do něj služba nevkládá. Rozhodnutí: `routed`, `denied`, `deniedByHandler`,
`pending`, `failed`, `cancelled` (viz výše). Důvody jsou stabilní značky, nikdy
text výjimky nebo zpráva upstreamu. `pending` a `cancelled` mají `status = 0`;
čekající SSE zatím nemá konečný výsledek. Kanonický řádek:

```
1|npm|GET|/npm/library-fixture|denied|operationDisabled|403
```

Volná pole (`operation`, `method`, `path`, `reason`) se do řádku escapují (`%` → `%25`,
`|` → `%7C`, řídicí znaky → `%XX`), takže řádek má **vždy právě 7 polí** a
`AuditRecord.parse(line)` ho vrátí na stejný záznam. Běžná cesta zůstává čitelná beze
změny; round-trip testy pokrývají `%`, `|` i řídicí znak.

`sequence` roste od 1 při vložení záznamu. SSE vloží čekající záznam při dispatchi
před spuštěním producenta a jeho finalizace zachová číslo i ostatní identifikační pole.
Auditní `status` SSE popisuje výsledek producenta, nikoli již odeslanou hlavičku:
po prvním eventu může mít klient hlavičku 200, zatímco audit skončí `failed/502`
a transport je zkrácený. Při sériových bězích je rozhodování deterministické.

**Audit artefaktů je samostatný:** `npmDownloadRecords()` a `pypiDownloadRecords()`
vracejí metadata z reálných handlerů včetně `prepared`, `transportAccepted` a
`sendFailed`. Transport volá veřejné `HTTPResponse.completeTransport(true/false)`
po lokálním sendu; callback se vykoná nejvýše jednou i při kopii odpovědi nebo souběhu.
`transportAccepted` není potvrzení přijetí klientem. Rozhodnutí `routed` před odesláním
artefaktu tento transportní stav nenahrazuje.

**Saturace (omezení prototypu):** když je audit plný, brána vrací 503 a `auditSaturationCount()`
roste, ale nezapisuje záznam — v plném auditu na něj není místo a zahození historie by
bylo tiché přepisování. Saturace je proto **nevratná do konce života služby**; rotace =
nová služba (nový proces) nad stejnou politikou, což test pinuje. Produkční řešení
(segmentace/rotace s markerem a limitem `lifetime` auditu) je věc WP2.5, ne prototypu.

## Poskytovatel klíčů

```swift
public protocol KeyProvider: Sendable {
    func key(for operation: GatewayOperation) -> ModelAPITestKey?
}
```

- `MockKeyProvider` vrací jen syntetický `ModelAPITestKey` z WP1.D3
  (`"sanjbox-test-…"`). `description`/`debugDescription` jsou redigované a testy
  ověřují, že se text klíče neobjeví v auditu ani v popisu služby.
- CLI to říká nahlas: když je modelový mount složený, vypíše
  `model key source: <mock key provider: synthetic model key>; real Keychain is not implemented (GUIDE §3)`.
  Bez modelu se řádek nevypisuje. `state=enabled` tedy nikdy neznamená Klíčenku.
- **Skutečná Klíčenka je mimo rozsah.** GUIDE §3 zakazuje čtení tajemství; prototyp
  neumí číst Klíčenku, scopes ani revokace a nesmí se k tomu "domyslet".
- Chybí-li klíč pro zapnutou modelovou operaci, **složení selže** (`keyUnavailable`),
  nevznikne služba, která by modelový mount jen tiše odmítala.

## Proces a transport

- Testy i CLI používají **in-process dispatch** (`GatewayService.dispatch`). Žádný test
  neotevírá port; integrační testy jdou přes skutečné aktéry ze `spikes/s5-gateway`
  s odmítajícím resolverem i s plně paměťovým upstream dialerem pro úspěšné přenosy.
  Dokazují cestu kódu, ne skutečnou síť.
- `LoopbackConnection` je testovaný framing (`ByteChannel` + in-memory mock).
  SSE hlavičku 200 odešle až s prvním eventem: odmítnutí před začátkem proto vrátí
  403 (budget), 429 (rate), 503 (kapacita) nebo 502 (chyba streamu/upstreamu).
  Chyba po začátku ukončí stream bez koncového chunku a bez druhé odpovědi.
  Kanál se zavře i při chybě nebo zrušení.
- `LoopbackListener` (reálný POSIX socket na `127.0.0.1:<port>`) se konstruuje **jen**
  na explicitní `--listen 127.0.0.1:<port>`. Bez něj CLI složení jen vypíše a skončí
  s "no socket opened". **Otevřený socket není součástí prototypu** a žádný test ho
  nespouští; IMPLEMENTATION §3 zakazuje sestavit běžící celek.
- S `--listen` CLI vypíše potvrzení `listener ready: 127.0.0.1:<port> …` **před** vstupem
  do accept smyčky (přes `emit`), takže operátor vidí, že listener naběhl; selhání bind
  vrátí exit 4 a řádek `listener stopped: …`. Pořadí ověřuje test s mock `ListenerRunner`.

## Rozhraní (pro H2, H3, H5, H6 a WP2.5)

```swift
public enum GatewayOperation: String, CaseIterable, Comparable { case npm, pypi, git, model }

public struct GatewayPolicy {                  // Codable, draft v1
    static let currentSchemaVersion: Int
    let schemaVersion: Int; let zoneID: String; let auditCapacity: Int
    let gateways: [GatewayRule]
    static func decode(_ data: Data) throws -> GatewayPolicy
    var enabledRules: [GatewayRule]
    func rule(for: GatewayOperation) -> GatewayRule?          // jen enabled
    func declaredRule(for: GatewayOperation) -> GatewayRule?  // i vypnuté
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
    func npmDownloadRecords() async -> [NPMDownloadRecord]
    func pypiDownloadRecords() async -> [RegistryDownloadRecord]
}

public struct AuditRecord: Codable, Equatable { sequence, operation, method, path, decision, reason, status
    static let fieldCount = 7
    var canonicalLine: String
    static func fieldList(_:) -> [String]; static func parse(_ line: String) -> AuditRecord? }
public enum AuditDecision { routed, denied, deniedByHandler, pending, failed, cancelled }
public enum DenialReason { operationNotConfigured, operationDisabled, invalidRequestTarget,
    handlerForbidden, handlerRejected, handlerCapacity, modelBudget, modelRate, handlerReplay }

public protocol KeyProvider; public struct MockKeyProvider   // .unavailable, .defaultModelKey
public protocol ByteChannel; public struct LoopbackConnection
public protocol ListenerRunner { func run(serving: GatewayService) async throws }
public struct LoopbackListener: ListenerRunner { struct Address { init?(text: "127.0.0.1:<port>") } }
public enum GatewayCommand { enum Invocation; static func parse([String]) throws -> Invocation
    static func run([String], emit: @Sendable (String) -> Void = { _ in },
                    listener: (@Sendable (Address) -> any ListenerRunner)? = nil) async -> CommandResult }   // exit 0/2/3/4
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

Testy (76) pokrývají: validaci politiky pozitivně i negativně (neznámé pole/operace,
verze, mount, origin, limity) a **paritu rozsahů limitů** s `RegistryLimits`/
`ModelAPIConfiguration` ze `spikes/s5-gateway`, zakázanou operaci a neznámý mount
(auditované odmítnutí), odmítnutí uvnitř handleru (`deniedByHandler` + důvod), fail-closed
saturaci auditu (503 před handlerem) a její nevratnost, escapování a round-trip auditu
(7 polí, `|` v cestě i metodě), chybějící klíč, mock klíč nikdy v logu a jeho výpis v CLI,
potvrzení listeneru před smyčkou (mock runner, žádný port), framing transportu, a integraci
přes **skutečné** npm/PyPI/git/model handlery s lokálními fixtures, mock resolverem
nebo paměťovým dialerem — bez sítě, bez instalace balíčků, bez portu. Regrese kontrolují
úspěšný i selhaný artifact send, jednorázové completion, skutečné artifact audity,
modelový budget/rate/obě kapacity, čekající audit při saturaci, zrušení/replay,
chyby před i po prvním eventu a rozlišení lokálního npm 503 od chyby upstreamu.

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
4. Saturace auditu je nevratná do konce života služby (viz Audit); rotace je nový proces.
   Test `testAuditSaturationIsIrreversibleUntilServiceIsRecreated` to chování pinuje.
5. Homebrew chybí záměrně (viz výše) — do H1 je třeba rozhodnout, zda mount vůbec existuje.
