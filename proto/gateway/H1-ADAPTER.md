# H1 → H4: explicitní konfigurace a běžící cesta

Navazující rozsah WP1.H4, 2026-11-14. Původní vlastníci a autoři: janfiedler /
Codex + Astra; navazující Astra implementuje výslovně zadaný H1 adaptér.
H1 se nemění. Toto je offline prototyp, žádný verdikt S5/GW ani R2/R3.

## Vstup a použití

`H1GatewayAdapter.decode(data, configuration:)` používá skutečné
`SanjboxContracts.NetworkPolicy.decode`: uzavřená pole, duplicitní dekódované klíče,
přesné integer lexémy a limit 16 KiB. `init(networkPolicy:configuration:)` znovu
validuje i programově sestavené/měnitelné DTO. Adaptér drží neměnnou kopii H1 politiky.

H1 neurčuje mount, origin, cooldown, repozitář/push, audit, lifetime, modely ani
budget/rate. Důvěryhodný volající proto musí dodat `H1GatewayConfiguration`:
`auditCapacity` a slovník **přesné gate ID → úplné GatewayRule**. Hodnoty pravidel
mají již existující H4 typy a rozsahy. Pro pravidla z JSON použij
`GatewayPolicy.decode`, jehož povinná pole nemají wire defaulty; ne `JSONDecoder`.
Při použití Swift konstruktorů volající přijímá jejich dokumentované konečné defaulty.
Konfigurace není vstup od klienta oblasti a nepředstavuje jeho autentizaci.

Příklad čistě knihovní kompozice pro H1 gate `npm-edge`, type `npm`, upstream
`registry.example`, request limit 1 MiB, response limit 4 MiB:

```swift
let settings = H1GatewayConfiguration(
    auditCapacity: 256,
    rulesByGateID: ["npm-edge": .npm(NPMRule(
        enabled: true, mount: "/npm", publicOrigin: "http://127.0.0.1:18765",
        upstreamHostname: "registry.example", artifactHostnames: [],
        cooldownSeconds: 3600,
        limits: try RegistryRuleLimits(metadataBytes: 4_194_304, artifactBytes: 4_194_304,
                                       files: 10_000, operations: 4, auditRecords: 1024,
                                       lifetimeSeconds: 90)))])
let adapter = try H1GatewayAdapter.decode(h1Data, configuration: settings)
let service = try GatewayService(adapting: adapter) // syntetický MockKeyProvider
// service.dispatch(request) obslouží skutečné typované handlery.
// Explicitní opt-in do socketu a síťových upstreamů:
// try await LoopbackListener(address: .init(port: 18765)!).run(serving: service)
```

Běžící veřejná cesta je **H1 decode → H1GatewayAdapter → GatewayService(adapting:)
→ dispatch/LoopbackListener.run(serving:) → skutečné D1–D5 handlery**. Adaptér není
samostatná validace následovaná nechráněným draftem; H1 zůstává připojený k dispatchi.
`service.networkPolicy` uchovává původní gate ID, zónu, cíle a limity; audit operace
se dá jednoznačně přiřadit díky jediné gate daného typu.

**Samostatný CLI `--policy` dál přijímá jen původní draft.** Nemá přepínač pro H1
ani parser doplňkového slovníku. H1 wire mu nelze podstrčit jako draft; nevydává se
za H1 autorizovanou službu. Uvedené veřejné knihovní API je dosažitelná cesta H4,
otestovaná i skutečným loopback listenerem. Bez další integrace nevzniká helper,
broker, nainstalovaná služba ani oblast. Ty patří F2/L5.

## Převod oprávnění

| H1 | Přijaté mapování H4 |
|---|---|
| `zoneID` | beze změny do runtime i modelového handleru; žádný druhý zdroj zóny |
| `defaultAction` | pouze `deny`; prázdné `gates` + prázdné bindings složí deny-all službu |
| `id` | přesný klíč konfigurace; chybějící/přebývající ID odmítne celou kompozici |
| `npm` | GET; upstream přesně H1; artifact host může být jen tento stejný host (npm jej zahrnuje i při `[]`) |
| `pypi` | GET; registry i případné artifact hosty pouze přesný H1 host |
| `git` | pevný `/project.git`, GET advertisement a POST upload-pack; receive-pack pouze při explicitním `allowPush:true` |
| `model-api` | pouze upstream `api.anthropic.com`, přesně `methods:["POST"]`, mount `/model`, endpoint `/v1/messages`, textové SSE |
| `brew` | odmítnuté; chybí přijatý zdroj data publikace |

Každá H1 gate musí mít aktivní pravidlo správného typu. Dvě gate stejného typu,
`enabled:false`, neplatný mount/repozitář, model GET nebo GET+POST a rozšíření hostů
se odmítnou; žádné částečné složení. H1 prázdné `methods` u npm/PyPI/git znamená
výše uvedený typovaný podprotokol, ne libovolné HTTP metody. Model POST je stejná
metoda na lokální i upstream straně. Klientské credentials zůstávají zakázané.

**Veřejné PyPI s CDN na `files.pythonhosted.org` tento jednocílový adaptér nepodporuje.**
Ani další H1 gate neopravňuje první handler použít její hostname. Volající musí
použít podporovaný server s artefakty na témže hostu, nebo konfiguraci odmítnout.
Redirect může zůstat pouze na stejném povoleném hostu podle D1–D5; žádné nové cíle.
Prázdný PyPI seznam artifact hostů úmyslně nedovoluje vydat žádný artefakt.

## Jednotky a vynucení limitů

Tento adaptér interpretuje H1 request/response limit jako **bajty HTTP entity body
na jednu HTTP operaci**, na klientské i upstream straně. SSE počítá celý zakódovaný
SSE text včetně `event:`, `data:` a oddělovačů. HTTP hlavičky, chunk framing, TLS,
TCP a DNS mají samostatné D1/transportní limity. Nejde o celkový datový budget
oblasti: stažení artefaktu může vyvolat metadata, artefakt a čerstvá metadata,
každé s vlastní mezí. Lokální budget/rate modelu určuje doplňková konfigurace.

- `metadataBytes`, `artifactBytes` a model `maximumOutputBytes` musejí být ≤ H1
  response limit. Git `maximumRequestBytes` a model `maximumInputBytes` musejí být
  ≤ H1 request limit. Větší hodnoty jsou chyba konfigurace, nikdy zaokrouhlení nahoru.
- Menší H4 meze a pevné limity D1 zůstávají. Např. H1 16 MiB není příslib podpory
  16MiB artefaktu; H4 registry přijímají nejvýše 4 MiB. Caller musí vybrat platné meze.
- Dispatch před handlerem odmítne příliš velké tělo: 413, `denied/h1RequestLimit`.
  Model navíc předem přepočítá JSON stejnými Foundation encoding volbami jako D3;
  H1 mez musí splnit příchozí i rekonstruované tělo. Striktní schema/duplicate-key
  validaci nadále provádí D3, pomocná serializace ji nenahrazuje.
- npm/PyPI nepřenášejí request body, Git předává omezené tělo beze změny. Handler
  nadále omezuje konkrétní cestu, operation a případné push oprávnění.
- Veřejný `GatewayService(adapting:)` sestaví jeden sdílený `UpstreamClient`, aby
  zůstal cap osmi spojení. Jeho buffered/stream body ceiling je **minimum všech H1
  response mezí a 4 MiB**, event ceiling navíc nejvýše 64 KiB. Hodnota je zveřejněná
  jako `adapter.upstreamResponseBytesLimit`. To může zpřísnit větší gate; nikdy ji
  nerozšíří. Například npm 1 KiB + model 4 MiB omezí upstream odpovědi obou na 1 KiB.
  Volající musí tento společný limit zohlednit při sestavování služby.
- Upstream parser počítá i data, která handler zahodí (např. modelové ping eventy).
  Přes veřejné H1 API nelze podsunout klienta s většími limity; testovací factory je
  package-internal a fixtures dostávají stejný `UpstreamLimits`.
- Každá hotová odpověď se kontroluje i po přepsání handlerem. Překročení se zahodí,
  completion se dokončí jako neúspěch, audit je `failed/h1ResponseLimit/502`.
  SSE klientské bajty omezuje skutečný D3 handler přes `maximumOutputBytes`.
- Lokální chyby v H1 režimu mají prázdné tělo, včetně chyby SSE před prvním eventem.
  Tím je respektovaný i nejmenší H1 response limit 1. Chyba po prvním eventu nechá
  stream nedokončený a audit `failed`; nepřidává další odpověď ani terminální chunk.

## Ověření a hranice

`H1AdapterTests` používají skutečné handlery a D1 klienta nad in-memory dialerem.
`ListenerTests.testH1WirePolicyReachesRealListenerHandlerAndRejectsExcessBeforeUpstream`
přenáší syntetický npm artefakt přes skutečný 127.0.0.1 socket, ověřuje H1 mount,
request mez, audit, odmítnutí neznámé cesty, cancellation a opětovný bind portu.
Výsledky Debug/Release a přesná revize jsou ve [VALIDATION](VALIDATION.md).

Klíče jsou pouze syntetické. Žádný test nepoužívá skutečné DNS/upstream, účet,
Klíčenku, billing ani instalaci balíčku. Nemění se systém, uživatelé, pf, TCC ani
zařízení. H1 zóna je stále statický štítek, listener neověřuje UID/session; autorizace
klienta, durable audit, produkční lifecycle/TLS trust a laboratorní brány zůstávají
mimo tento prototyp.
