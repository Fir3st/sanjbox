# Kontrakty v0 (WP1.H1)

Izolovaný prototyp jádrových kontraktů podle [IMPLEMENTATION §3](../../docs/IMPLEMENTATION.md#proud-h--prototypy-jádra-proti-mockům-bez-laboratoře).
Balík **nedokazuje žádnou bránu**, nikdy se nesestavuje do běžícího celku a neprovádí žádnou systémovou
operaci: žádný uživatel, svazek, proces, `pf` anchor, socket ani soubor. Všechny vstupy v testech jsou
syntetické fixtures a mocky; nic se nečte z reálného systému a nic se nezapisuje na disk.

- Swift 6 (`swift-tools-version: 6.0`), `.macOS(.v15)`, **nula externích závislostí** a žádná
  `.package(path:)` hrana. Balík jde sestavit samostatně a záměrně nemá žádného závislého.
- Veřejná knihovna: `SanjboxContracts`. Testy používají Swift Testing (`import Testing`, `@Test`),
  stejně jako `spikes/s3-pf`.

## Rozsah a co tu záměrně není

| Oblast | Stav v0 |
|---|---|
| XPC obálka helperu + striktní validace zpráv | hotovo, negativní test na každé pravidlo |
| Broker | **jen** verzovaná obálka `broker-v0`, zprávy odmítány (viz níže) |
| Stavový automat oblasti | hotovo, explicitní tabulka přechodů, body pádu, LC-06/LC-11 |
| Formát síťové politiky a typovaných bran | hotovo, uzavřená množina klíčů, validace |
| Formát audit logu | hotovo, stabilní klíče, striktní decoding |
| Manifest stavu | **duplikované** schema `sanjbox.state-manifest.v1` (viz níže) |
| Skutečná XPC komunikace, podpisy, audit token, sandbox, `pf` | **není** — patří WP2.x |

## Veřejné rozhraní

```swift
// Chyby: stabilní kód + volný popis. Kódy jsou součást kontraktu.
public struct ContractError: Error, Equatable, Sendable { public let code: String; public let detail: String }

// Lexikální identifikátory (žádné OS lookup).
public enum Identifier {
    static func isValidZoneID(_:) -> Bool      // přesně 4 lowercase ASCII [a-z0-9]
    static func isValidPlanID(_:) -> Bool      // 1...32 [a-z0-9-]
    static func isValidFileName(_:) -> Bool    // 1...128 B, bez "/", "." a ".."
    static func isValidHostname(_:) -> Bool    // lowercase LDH, bez scheme/portu/cesty/wildcardu
}

// Obálka a zprávy helperu (protokol verze 1).
public struct XPCEnvelope: Codable, Equatable, Sendable {
    static let helperProtocolVersion: UInt32   // 1
    static let maxBytes: Int                   // 73 728 (72 KiB)
    static let maxBodyBytes: Int               // 49 152 (48 KiB, surové tělo)
    var version: UInt32; var kind: String; var body: Data
    static func decode(_:) throws -> XPCEnvelope
    func headerProblem() -> ContractError?
    func encoded() throws -> Data
}
public enum HelperMessageKind: String, CaseIterable, Sendable
public enum HelperMessage: Equatable, Sendable {            // .capabilities, .createZone(..), ...
    var kind: HelperMessageKind
    static func decode(_:) throws -> HelperMessage
    func validate() throws
    func encoded() throws -> Data
}
public struct CreateZoneRequest: Codable, Equatable, Sendable  // zoneID, uid, gid
public struct ZoneRef: Codable, Equatable, Sendable           // zoneID
public struct ApplyNetworkPolicyRequest: Codable, Equatable, Sendable // zoneID, policy

// Broker v0: prázdná množina zpráv.
public enum BrokerContract {
    static let protocolVersion: UInt32   // 0
    static let maxBytes: Int             // 4 096
    static let acceptedKinds: Set<String> = []
    static func decode(_:) throws -> BrokerEnvelope
}
public struct BrokerEnvelope: Codable, Equatable, Sendable

// Stavový automat oblasti.
public enum ZoneState: String, CaseIterable, Codable, Sendable
public enum ZoneEvent: String, CaseIterable, Sendable
public struct ZoneTransition: Equatable, Sendable
public struct ForbiddenTransition: Equatable, Sendable
public enum ZoneCrashPoint: String, CaseIterable, Sendable
public enum ZoneRecoveryAction: String, CaseIterable, Sendable   // permitsStart, permitsUIDReuse
public struct ZoneStateMachine: Equatable, Sendable {
    static let allowedTransitions: [ZoneTransition]
    static var forbiddenTransitions: [ForbiddenTransition]
    static func target(from:on:) -> ZoneState?
    var zoneID: String; var state: ZoneState; var uid: UInt32?; var gid: UInt32?
    init(zoneID:) throws
    var uidAvailableForReuse: Bool
    func canApply(_:) -> Bool
    mutating func assignIdentity(uid:gid:) throws
    mutating func apply(_:) throws
    func assertInvariants() throws
}

// Síťová politika a typované brány.
public struct NetworkPolicy: Codable, Equatable, Sendable        // schema, zoneID, defaultAction, gates
public struct TypedGate: Codable, Equatable, Sendable            // id, type, upstream, methods, limity
public enum GateType: String, CaseIterable, Codable, Sendable    // npm, pypi, git, brew, model-api
public static func NetworkPolicy.decode(_:) throws -> NetworkPolicy
public func NetworkPolicy.encoded() throws -> Data
public func NetworkPolicy.validate() throws

// Audit log.
public enum AuditAction: String, CaseIterable, Codable, Sendable
public enum AuditOutcome: String, CaseIterable, Codable, Sendable
public struct AuditRecord: Codable, Equatable, Sendable
public enum AuditLog {                                           // decode, encode, validate
    static let maxBytes: Int                  // 1 MiB
    static let maxRecords: Int                // 4 096
}

// Manifest stavu (duplikace, viz riziko driftu).
public enum StateManifestSchema { static func decode(_:), encode(_:), validate(_:) }
public struct StateManifestDocument: Codable, Equatable, Sendable
public struct ManifestZone, ManifestContainer, ManifestQuota, ManifestVolume,
              ManifestRoot, ManifestRollback, ManifestHostControl, ManifestReadOnlyInput
```

## XPC obálka a zprávy helperu

Obálka je jeden JSON objekt s **uzavřenou množinou klíčů** `version`, `kind`, `body`. `body` je
base64 JSON dokument, který se dekóduje až podle `kind`. Pořadí kontrol je pevné:

1. velikost vstupu (`input-too-large`, limit 72 KiB; surové tělo 48 KiB),
2. JSON preflight: prázdný vstup, gramatika, trailing bytes, duplicitní klíč, hloubka > 16,
   pole > 128 prvků (audit log si explicitně zvedá strop na `maxRecords`), řetězec > 4096 B
   (base64 `body` obálky si zvedá strop na limit obálky),
3. uzavřená množina klíčů obálky (`unknown-field`, `missing-field`),
4. verze protokolu (`invalid-version`; jiná verze se neinterpretuje „best effort"),
5. syntaxe `kind` a členství v množině zpráv (`unknown-message-kind`),
6. uzavřená množina klíčů těla podle `kind`,
7. typová dekce (`invalid-value`) a rozsahy (`invalid-range`),
8. sémantická validace (`invalid-identifier`, `invalid-policy`).

Množina zpráv v0 (`HelperMessageKind`): `helper.capabilities` (tělo musí být přesně `{}`),
`zone.create`, `zone.start`, `zone.pause`, `zone.stop`, `zone.status`, `policy.apply`. Tělo bez
deklarovaných klíčů je odmítnuto; neznámý `kind` se odmítá **před** čtením těla. Číselné rozsahy:
`uid`/`gid` 501…`UInt32.max` (nula i přetečení jsou chyba), limity velikostí 1…8 MiB / 16 MiB.
Kanonické kódování (`sortedKeys`) je deterministické, takže `decode(encode(x)) == x` i bajtově.

Tělo se na drátě kóduje jako base64, takže jeho text má až 4/3 surových bajtů. Preflight proto pro
`body` používá strop obálky, ale surový limit 48 KiB vynucuje `headerProblem()` až po dekódování.
Hraniční testy ověřují tělo na `48 KiB − 1`, `48 KiB` a `48 KiB + 1`: první dvě se round-tripují,
třetí je odmítnuto. Strop celé obálky (72 KiB) je dost velký i pro base64 plného těla.

## Broker `broker-v0`

**Broker message set je záměrně prázdná podmnožina** budoucího brokeru: Broker/WP3.2 neexistuje,
takže v0 fixuje jen verzovanou obálku a pravidla odmítnutí. `BrokerContract.acceptedKinds` je prázdná
množina, `decode` tedy u každé dobře utvořené obálky skončí `unknown-message-kind`; chybná verze se
hlásí jako `invalid-version` **dřív** než neznámý typ, aby se záměna verze nepletla s neimplementovanou
zprávou. Až broker vznikne, rozšíří se `acceptedKinds` a volající místa zůstanou stejná.

## Stavový automat oblasti

Stavy: `created → starting → running → paused → stopping → stopped → cleaning → cleaned`.
`cleaned` je koncový stav; nový běh znamená novou oblast, ne restart téže identity.

Povolené přechody (`ZoneStateMachine.allowedTransitions`, celkem 10):

| z | událost | do |
|---|---|---|
| `created` | `start` | `starting` |
| `starting` | `launched` | `running` |
| `starting` | `stop` | `stopping` |
| `running` | `pause` | `paused` |
| `running` | `stop` | `stopping` |
| `paused` | `resume` | `running` |
| `paused` | `stop` | `stopping` |
| `stopping` | `quiesced` | `stopped` |
| `stopped` | `cleanup` | `cleaning` |
| `cleaning` | `cleaned` | `cleaned` |

Všech 54 ostatních dvojic (stav, událost) je zakázaných. Testy drží **pinovaný literál** tabulky
nezávislý na implementaci: 10 povolených dvojic a všech 54 zakázaných se počítá z tohoto literálu,
ne z `forbiddenTransitions`. Pro každou zakázanou dvojici test ověří `forbidden-transition` **a** že
se stav ani identita nezměnily. Odmítnutá událost nesmí mít částečný efekt.

Invarianty (`assertInvariants`, volané po každém přechodu):

- `starting`…`cleaning` vyžadují navázanou identitu (`state-invariant`);
- `cleaned` nesmí držet UID;
- identita jde navázat jen jednou a jen v `created` (`uid-already-assigned`, `state-invariant`).

**LC-06** (start během vypínání i po něm neprojde): `start` je povolen pouze z `created`; z `stopping`
a `stopped` je odmítnut (`forbidden-transition`) a stav zůstává nezměněn. Testováno jmenovitě.

**LC-11** (UID se nepřidělí znovu před dokončením úklidu): UID se uvolní **jen** přechodem
`cleaning → cleaned`; do té doby `uidAvailableForReuse == false` a `assignIdentity` v `stopped`/
`cleaning` skončí `uid-reuse-before-cleanup`. Po `cleaned` už oblast identitu nedostane
(`state-invariant`), musí vzniknout nová. Automat hlídá pořadí **v rámci jedné oblasti**; globální
přidělování UID mezi oblastmi (kdo smí UID znovu vydat) je věc WP1.H2/WP2.2 a zde modelováno není.

**Body pádu.** Každá událost deklaruje pozorovatelné body pádu (`ZoneEvent.crashPoints`); každý bod
má jednu akci obnovy (`ZoneCrashPoint.recoveryAction`). Start smí povolit jen
`refuseAndRollbackToCreated` (před commit identitou) a `identityReusable` (po dokončeném úklidu);
UID smí znovu použít jen `identityReusable`. Testy ověřují obě mapy pro všechny body.

## Síťová politika a typované brány

Stabilní formát `sanjbox.network-policy.v1` (`NetworkPolicy`, `Codable`, `sortedKeys`):

```json
{"schema":"sanjbox.network-policy.v1","zoneID":"a1b2","defaultAction":"deny",
 "gates":[{"id":"npm-edge","type":"npm","upstream":"registry.npmjs.org","methods":[],
           "requestBytesLimit":1048576,"responseBytesLimit":4194304}]}
```

Pravidla: uzavřená množina klíčů na všech úrovních (neznámé pole = `unknown-field`, chybějící
povinné = `missing-field`); `defaultAction` jen `deny` (formát neumí „povolit zbytek");
`type` z uzavřené množiny `npm|pypi|git|brew|model-api`; `upstream` je lowercase DNS jméno bez
scheme, portu, cesty a wildcardu; `id` je plánovací identifikátor a v rámci politiky unikátní;
`methods` smí být jen u `model-api` a jen z `{GET, POST}`, jinde musí být prázdné; limity velikostí
1…8 MiB (`requestBytesLimit`) a 1…16 MiB (`responseBytesLimit`); nejvýše 16 bran, dokument 16 KiB.
Politika nenese žádný klíč, schválení ani credential a **není** důkaz vynucení ani bind policy.

## Audit log

`sanjbox.audit.v1` = pole záznamů s **stabilními klíči**
`schema, sequence, timestampUTC, zoneID, actorUID, action, outcome, subjectID?, detail?`.

- `action` z uzavřené množiny (`zone.created`, `zone.started`, `zone.paused`, `zone.resumed`,
  `zone.stopped`, `zone.cleaned`, `policy.applied`, `gate.request.denied`, `export.completed`),
  `outcome` z `allowed|denied|failed`; neznámá hodnota je chyba dekódování.
- `timestampUTC` je přesně `YYYY-MM-DDTHH:MM:SS.sssZ` (24 B, UTC, milisekundy, bez offsetu a přestupné
  sekundy) a datum musí existovat v kalendáři (`2026-02-31` je chyba, `2024-02-29` projde).
  `sequence` začíná na 1 a každý další záznam je přesně `previous + 1`; díra, start ≠ 1, pokles,
  duplicita i dvě oblasti v jednom dokumentu jsou `sequence-violation`. `subjectID` je plánovací
  identifikátor, `detail` ≤ 512 B bez kontrolních znaků. `actorUID = 0` označuje hostitelskou řídicí
  rovinu.
- Limity: 1 MiB **a** 4 096 záznamů na dokument, oba vynucené při dekódování. Bajtový a početní
  strop mají samostatné hraniční testy: přesně 1 MiB / 1 MiB + 1 B a přesně 4 096 / 4 097 záznamů.

## Manifest stavu — duplikace schématu

`sanjbox.state-manifest.v1` **přebírá** `spikes/s4-state`, ale tamní typy `StateManifest` jsou
`internal`, a proto balík schéma **duplikuje** (typy `StateManifestDocument` a `Manifest*`
odpovídají `spikes/s4-state/SCHEMA.md`). Do `spikes/s4-state/` se nesahá.

> **Duplikace schématu, drift riziko.** Konsolidace (společný balík, ze kterého by čerpal spike i
> `proto/`) patří do samostatného balíku s review. Do té doby platí: změna ve `spikes/s4-state/SCHEMA.md`
> musí být zrcadlena sem a naopak, jinak se obě schémata rozejdou.

Decoding je striktní (uzavřené klíče, duplicitní klíč, přetečení čísel) a validace je **záměrně
podmnožina** B3 validátoru ve spiku: kontroluje jen offline strukturální pravidla (schema/intent/phase,
tvary identifikátorů, kolekce, kvóty a rezervy, role kořenů, prefix layout, rollback jednotku, host
control, read-only vstupy, přetečení součtů). Nic nemountuje, nic neměří a nevydává se za deployment.

Z B3 validátoru jsou navíc převzatá tato pravidla a mají negativní testy:

- párový překryv `volumes[].mountPoint` (rovnost, case/Unicode alias i vnoření),
- disjunktnost plánovaných cest `roots` (`mountPoint` + `relativePath`, case/Unicode folded),
- case/Unicode folding všech porovnávaných cest,
- odmítnutí absolutních hostitelských aliasů `/tmp`, `/var`, `/etc`, `/System/Volumes/Data`
  (a jejich podcest) jako mountpointu, control adresáře nebo read-only vstupu.

Záměrně vynechaná pravidla B3 (proto je tento balík **nevynucuje**; doplnění patří do konsolidačního
balíku s review): `unused-container` a `unused-volume`, `hostControl.ownerUID != zone.uid`,
kombinovaný limit 1024 B pro `mountPoint` + `relativePath`, varování `quota-unverified`,
`container-budget-unresolved`, `quotas-oversubscribed` a `multi-volume-recovery`, plnění
`plannedRoots`/`plannedVolumes` a rozlišení severity error/warning. Duplicitní UUID se nadále
odmítá bez ohledu na case (kanonická podoba `UUID`).

## Co tento balík nedokazuje

- Žádnou bránu (S0–S8) a žádný požadavek R1–R8. Kontrakty v0 se mohou po F1 změnit.
- Žádné skutečné XPC, podpis, audit token, sandbox, `pf`, APFS ani síťové vynucení.
- Žádnou ochranu proti útočníkovi, který umí obejít volající kód; to je práce WP2.1 a WP2.4.
- Duplicitní schéma manifestu není náhrada `spikes/s4-state` ani jeho testovací sady.

## Brány balíku

```sh
swift build --package-path proto/contracts -c debug
swift build --package-path proto/contracts -c release
swift test  --package-path proto/contracts -c release --scratch-path /private/tmp/h1-contracts-test
/usr/bin/python3 -m unittest discover -s tools/tests
```

Testy jsou mocky: fixtures jsou syntetické dokumenty v paměti, nic se nečte z hostitele.
