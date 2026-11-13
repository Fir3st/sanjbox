# Kontrakty v0 (WP1.H1)

Izolovaný prototyp jádrových kontraktů podle [IMPLEMENTATION §3](../../docs/IMPLEMENTATION.md#proud-h--prototypy-jádra-proti-mockům-bez-laboratoře).
**Hotový H1 není průchod žádné brány ani běžící MVP.** Knihovna neprovádí systémové operace,
nečte deklarované cesty, nevytváří uživatele/svazky/procesy a neposílá XPC ani síťový provoz.
Testy používají syntetické dokumenty a mock kontexty; parity oracle navíc kompiluje čisté zdroje B3.

- Swift 6, `.macOS(.v15)` jako minimum balíku; knihovna `SanjboxContracts` bez externích závislostí
  a bez `.package(path:)` hran. Runtime integrace patří do dalších balíků.
- Původní prototyp Pi z PR #52 obsahoval prázdný broker v0 a podmnožinu pravidel B3. Uživatelské
  předání Codex + Astra 2026-11-13 doplnilo níže uvedený rozsah; původní autorství zůstává zachované.
- [VALIDATION.md](VALIDATION.md) uvádí skutečně spuštěné offline kontroly a jejich omezení.

| Oblast | Výstup |
|---|---|
| Helper | 12 typů požadavků, včetně všech H3 příkazů, a korelované typované odpovědi |
| Broker | Tři úzké zprávy frames/input, verze 1, kontextové kontroly a explicitní Mach příloha |
| Lifecycle | Povolené/zakázané přechody, body pádu, LC-06/LC-11 |
| Síť | Deny-default `NetworkPolicy` a pět typů `TypedGate` |
| Audit | Bounded `sanjbox.audit.v1`, monotónní sekvence a stabilní slovník |
| Manifest | Všechna sémantická pravidla B3, úplný report a parity test proti aktuálním zdrojům B3 |

Vstupní wire API jsou `HelperMessage.decode`, `HelperReply.decode`, `BrokerMessage.decode`,
`BrokerContract.decode`, `NetworkPolicy.decode`, `AuditLog.decode` a `StateManifestSchema.decode`.
Přímý `JSONDecoder` nad veřejnými `Codable` DTO **neprovádí** striktní preflight ani sémantickou
validaci a nesmí být vstupem receiveru. `ContractError.code` je stabilní strojový důvod;
`detail` je diagnostika, nikoli autorizační rozhodnutí.

## XPC obálka a zprávy helperu

`XPCEnvelope` má přesně `version`, `kind`, `body`. Helper verze je **1**; jiná verze se odmítne.
`body` je base64 JSON, nikoli shell příkaz nebo libovolný payload. Limit obálky je 72 KiB,
surového těla 48 KiB. Encoder kontroluje skutečné výsledné bajty i base64 expanzi a používá
`sortedKeys` + `withoutEscapingSlashes`.

Pořadí: byte limit → striktní JSON preflight → uzavřené klíče obálky → verze → známý typ →
uzavřené klíče a typy těla → rozsahy a sémantika. Preflight odmítá duplicitní dekódované klíče,
trailing bytes, hloubku >16, pole >128 a řetězce >4096 UTF-8 B; obálka povoluje base64 řetězec do
svého byte limitu. Celočíselná pole přijímají jen desetinné číslice, bez znaménka, tečky a exponentu,
s přesným `UInt64` převodem, nikdy přes `Double`. Neznámá pole, typy i verze se odmítají.

| Kind / případ `HelperMessage` | Tělo |
|---|---|
| `helper.capabilities` / `capabilities` | Přesně `{}` |
| `zone.create` / `createZone` | `CreateZoneRequest`: `zoneID`, návrhové `uid`, `gid` v 501…UInt32.max |
| `zone.start/pause/resume/stop/status` | `ZoneRef`: jen `zoneID` |
| `policy.apply` / `applyNetworkPolicy` | `ApplyNetworkPolicyRequest`: `zoneID`, validní `policy` stejné oblasti |
| `zone.shell` / `shell` | `ShellRequest`: `zoneID`, `workingRootID`, `workingDirectory` |
| `zone.run` / `run` | `RunRequest`: stejné tři položky + `executableRootID`, `executablePath`, `arguments` |
| `zone.snapshot/rollback` | `SnapshotRequest`: `zoneID`, `snapshotID`, `rollbackUnitID` |

`zoneID` je přesně čtyřznakové lowercase ASCII `[a-z0-9]`. Root/snapshot/unit/execution IDs mají
1…32 znaků `[a-z0-9-]`. Pracovní adresář je normalizovaná relativní cesta nebo `.`; executable
je relativní soubor, nikdy `.`. Cesty mají nejvýše 1024 UTF-8 B, bez traversal, backslash a control
znaků. `arguments` je doslovný argv vektor (max. 64 argumentů, každý 1024 B, celkem 32 KiB, bez NUL),
ne parsovaný shell text. Shell používá konfiguraci oblasti, požadavek nevybírá host shell.
Žádné pole nepřijímá caller UID, env, host path, bootstrap doménu nebo privilegovaný příznak.

**H3 mapování:** `sanjbox shell/run/pause/snapshot/rollback` používá příslušný kind výše; `resume`
je explicitní protějšek pause. Receiver musí před operací ověřit host-only autorizaci, lifecycle,
manifest root IDs a descriptor-relative rozlišení uvnitř autentizované oblasti. Run executable
může být jen z manifestu oblasti nebo explicitního veřejného read-only vstupu. Textové ověření
cesty neřeší symlinky/TOCTOU. Snapshot a rollback odkazují na **celou** manifestovou restore unit;
helper musí ověřit její shodu, snapshot binding a whole-UID quiescence. B4
[RECOVERY.md](../../spikes/s4-state/RECOVERY.md) určuje durable fáze obnovy; H1 nevytváří druhý journal.

`HelperReply` používá stejnou obálku s kind `helper.reply` a uzavřené tělo
`requestKind, zoneID?, outcome, executionID?, state?, errorCode?`:

- Shell/run mají úspěch `accepted` a povinné `executionID`; je to přijetí operace, **nikoli exit status**.
  H3 mock může ověřit admission; budoucí stdio/PTY adaptér musí použít tento zone-bound handle,
  ne libovolný PID. Žádné skutečné spuštění ani streamování zde není.
- Ostatní úspěchy jsou `completed`; pouze status vyžaduje `state`. Capabilities nemá zoneID,
  všechny ostatní odpovědi jej vyžadují.
- `failed` vyžaduje `errorCode` z `invalid-request|unauthorized|invalid-state|unavailable|operation-failed`
  a zakazuje success data. Success zakazuje errorCode.
- Po decode musí klient volat `reply.validate(for: request)` na XPC reply kanálu daného požadavku;
  nesouhlas kind/zone je chyba. Požadavkový decoder odmítne reply kind a obráceně.

## Broker `broker-v1`

První neprázdný broker používá **verzi 1**; původní verze 0 se odmítá. `BrokerEnvelope` má stejné
uzavřené klíče jako helper, ale limit **4096 B** obálky a **2048 B** surového těla. Oba encode/decode
ověřují i tělo; `BrokerContract.decode` už nikdy nevrátí nezkontrolovaný payload.

| Kind | Směr / přesné tělo |
|---|---|
| `broker.frame` | Session agent → host: `zoneID, streamID, sequence, width, height, surfaceAttachmentIndex` |
| `broker.input.key` | Host controller → session agent: `zoneID, streamID, sequence, keyCode, action, modifiers` |
| `broker.input.pointer` | Host controller → session agent: `zoneID, streamID, sequence, x, y, action, button` |

Společné ID mají výše uvedená pravidla; `sequence` je 1…UInt64.max. Frame má šířku/výšku 1…8192,
`surfaceAttachmentIndex` přesně **0**, odkaz na jediný **mimo JSON přenesený IOSurface Mach send right**.
Není to globální IOSurface ID ani číselný název Mach portu. Key code je 0…127, action `down|up`,
modifiers je pětibitová maska shift/control/option/command/caps-lock. Pointer x/y je 0…8191,
action `move|down|up`; move vyžaduje button 0, down/up button 1 nebo 2 (primary/secondary).
Scroll, text, clipboard, menu, obecné event blobs, PID, host path ani privilegované helper operace
nejsou součástí této úzké podmnožiny a odmítají se. Další zprávy vyžadují explicitní rozšíření kontraktu.

`message.validateDelivery(in: BrokerDeliveryContext)` vyžaduje důvěryhodný role/zone/stream binding,
přesný počet příloh (frame 1, input 0), novější sekvenci pro daný stream a směr, shodu frame rozměrů
s registrovaným streamem a pointer uvnitř jeho hranic. Kontext **nepochází ze zprávy**. Adaptér musí:

1. autentizovat peer audit tokenem, podpisem a session, ověřit vlastnictví registrovaného streamu;
2. ověřit skutečný typ/práva/rozměry/size přijaté Mach přílohy, nikoli jen počet;
3. atomicky svázat kontrolu sekvence s jejím posunem a při odmítnutí uvolnit přijatá práva.

Metadata, počet příloh ani mock kontext **nedokazují** autentizaci, existenci/platnost Mach práva,
izolaci relací nebo doručení vstupu. Tyto části zůstávají A6/WP2/S2; testy zde dokazují pouze
odmítnutí chybného kontextu a wire formátu. Runtime nesmí callerovi z oblasti zpřístupnit helper operace; samotné H1 decode není autorizace.

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
scheme, portu, cesty, wildcardu a IP literálu (včetně zkrácených/octal/hex IPv4 zápisů); `id` je plánovací identifikátor a v rámci politiky unikátní;
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
- Limity: 1 MiB **a** 4 096 záznamů na dokument, oba vynucené při kódování i dekódování.
  Encoder kontroluje konečné bajty JSON včetně escapování; strukturální `validate` samotný počet
  zakódovaných bajtů nepočítá. Hraniční testy pokrývají přesně 1 MiB / 1 MiB + 1 B při encode i decode,
  přesně 4 096 / 4 097 záznamů a odmítnutí 4 096 validních záznamů s 512 B `detail`.

## Manifest stavu — shoda s B3

`StateManifestDocument` a `Manifest*` reprezentují `sanjbox.state-manifest.v1` ze
[SCHEMA.md](../../spikes/s4-state/SCHEMA.md). B3 typy jsou internal; H1 proto zůstává izolovanou
kopií schématu. B3 soubory se nemění, žádná runtime package dependency se nepřidává.

`StateManifestSchema.report(document)` vrací **úplný B3 report**: `consistentDesign`,
`requiredRolesDeclared`, všechny `findings` s `severity/code/location/explanation`, `plannedRoots`,
`plannedVolumes`, `containerBudgets` a explicitní nezměřený stav/požadované další důkazy.
`ManifestValidation.swift` přebírá celou sémantiku B3, včetně:

- nepoužitých kontejnerů/svazků, všech referencí, rolí, runtime fáze a celé restore unit;
- host control owner odlišného od UID oblasti, mode, policy/recovery jmen a vyloučení z obnovy;
- 1024 B limitu jednotlivých **i sestavených** cest, Unicode control znaků, case/normalization aliasů,
  překryvů mountů/kořenů/read-only vstupů a známých absolutních host aliasů;
- přesných UInt64 kapacit, overflow, reserve/budget vztahů a chybějících/duplicitních UUID;
- warning `quota-unverified`, `container-budget-unresolved`, `quotas-oversubscribed`,
  `multi-volume-recovery`. Varování se neztrácejí ani se nepřeklasifikují na error.

`validate`, `encode` a `decode` odmítnou každou sémantickou error finding; warning samotný zůstává
platným **návrhem**, nikoli ověřenou kapacitou nebo deployem. Původní `ContractError` slovník je
zachován; podrobný kód B3 a severity jsou v reportu, nikoli v obecném `invalid-value`.
Wire decoding je navíc přísný na pole, velikosti a celočíselný zápis; jeho dřívější odmítnutí některých
neplatných dokumentů není změnou sémantiky B3. Report nad typovanou hodnotou může zobrazit více
chyb najednou. Encode kontroluje 256 KiB konečných bajtů a wire shape stejně jako decode.

**Executable parity oracle:** [tools/test_manifest_parity.py](tools/test_manifest_parity.py) zkompiluje
aktuální `Manifest.swift`, `Paths.swift`, `Validation.swift` z B3 a aktuální H1 do dvou nezávislých
čistých programů. Na 140 syntetických případech porovná **celý JSON report**, včetně závažnosti,
textů, odvozených cest/svazků/rozpočtů, a připíná pokrytí všech 48 B3 finding kódů. Nevyužívá
zlatou kopii B3 výsledků, proto zachytí i budoucí drift originálu. Změny B3/H1 se musí koordinovat;
parity test je povinný před sloučením změny manifestu a `B3ParityTests` jej spouští i v běžném Swift test targetu/CI.
[CI výběr balíků](../../docs/CI.md) vybírá H1 také při B3-only změně zdrojů, příkladů nebo SCHEMA.md;
tato testovací vazba nepřidává runtime package dependency. H1 Swift testy navíc ověřují odmítnutí
nových chyb všemi admission API a přijetí návrhů s varováními.

## Předání navazujícím balíkům

- **H2:** použije existující lifecycle automat, report/manifest, audit a B4 recovery kontrakt;
  globální UID allocator, durable operace, start admission a mock systémových efektů jsou jeho práce.
- **H3:** příkaz/reply mapování výše je jediné H1 schéma; žádné lokální alternativní wire DTO.
  Žádný úspěšný decode nepovoluje spustit příkaz pod host UID. Skutečná stdio/PTY vrstva není implementovaná.
- **H4:** `NetworkPolicy`/`TypedGate` formát, metody a limity se nerozšiřují. H4 musí výslovně dodat
  chybějící cooldown, artifact origins, repo/push scope, rate/budget a další konfiguraci uvedenou v
  [jeho README](../gateway/README.md#draft-politiky-a-mezera-vůči-h1), nebo konfiguraci odmítnout;
  nesmí odvodit neomezené oprávnění z hostname. Převod do H4 není součást H1 a není tímto dokončen.
- **A6:** fuzzer může přímo volat helper/reply/broker decode a trusted-context check; prefix helper
  a broker verze jsou nezávislé. Živá host-only autorizace, podpisy a Mach rights nejsou zde ověřené.
- **H6:** audit formát zůstává stabilní; stejné záznamy/protokoly nepředstavují laboratorní pass.

## Ověření a hranice

```sh
swift build --package-path proto/contracts -c debug
swift test --package-path proto/contracts -c release --scratch-path /private/tmp/h1-contracts-test
python3 proto/contracts/tools/test_manifest_parity.py
```

Swift unit testy používají paměťové fixtures. `B3ParityTests` vyžaduje checkout tohoto repozitáře
a `/usr/bin/python3` + Swift compiler; samotná knihovna zůstává samostatně sestavitelná.
Parity harness čte pouze zdroje a dva checked-in
syntetické příklady B3, kompiluje ve vlastním novém `/private/tmp/sanjbox-h1-parity-*` adresáři a po
běhu jej odstraní; nic nečte z cest deklarovaných manifestem. Nespouští B3 CLI ani identity sondy.

Žádné skutečné XPC, audit token/signature/session ověření, Mach rights, UID/process isolation,
APFS, snapshot/rollback, síťové vynucení ani stdio/PTY nebyly otestovány. `deploymentReady` zůstává
false, všechny brány a R1–R8 zůstávají Neověřeno. Runtime fail-closed vlastnosti musí prokázat
navazující implementace a laboratoř; zelené offline testy je nenahrazují.
