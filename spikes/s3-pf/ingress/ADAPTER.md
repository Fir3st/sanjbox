# WP1.C3 — offline propojení C1, common raw a ingress matice

`link` čte pouze stdin a zapisuje deterministický JSON na stdout. Spojuje **dostupná tvrzení**
ze skutečných wire formátů se scénáři `evaluate`; nevyrábí chybějící metadata. Výsledek je
podklad pro nezávislé review. **C3 zůstává partial; S3b/NET-10…12 zůstávají Neověřeno.**
Žádný výstup adapteru není pass, atestace identity/podpisu, měření packet absence ani změna COVERAGE.

## Spuštění a rozsah

Z kořene repozitáře, s vlastními izolovanými cache:

```bash
C3_TMP=$(mktemp -d /private/tmp/sanjbox-c3-adapter-XXXXXX)
mkdir -p "$C3_TMP/tmp" "$C3_TMP/modules" "$C3_TMP/cache"
TMPDIR="$C3_TMP/tmp" CLANG_MODULE_CACHE_PATH="$C3_TMP/modules" \
SWIFTPM_MODULECACHE_OVERRIDE="$C3_TMP/modules" \
swift test --package-path spikes/s3-pf/ingress -c release --build-system native \
  --disable-sandbox --scratch-path "$C3_TMP/build" --cache-path "$C3_TMP/cache"
"$C3_TMP/build/release/sanjbox-ingress" link \
  < spikes/s3-pf/ingress/Tests/IngressKitTests/Fixtures/link-fixture.json
```

Exit 0 znamená, že vznikl report, **i když obsahuje konflikty či finding**. Exit 2 odmítá
CLI/envelope nebo limit stdin. Automatizace musí číst `problems`, `missingBindings`, původ
každého zdroje a všechny `findings`; návratový kód se nesmí použít jako verdikt izolace.
Fixture je výslovně syntetická, krátká a nemá úplné controls/L4 délky. Nevytváří skutečnou
relaci, listener, capture ani síťovou aktivitu. V tomto follow-upu se živý `smoke` nepoužívá.

CLI nemá argument pro cestu, PID, příkaz, target, interface nebo privilegiovaný runner.
`rawFile` v common záznamu se kontroluje jako basename a **nikdy se neotevírá**. Ani ostatní
řetězce nejsou cestou k souboru či příkazem. Nevzniká výstupní adresář ani potřeba runtime
cleanup. Po vývojové validaci odstranit jen vlastní přesně identifikovaný `C3_TMP`;
neuklízet globální prefixy a neodstraňovat cizí nebo uzavřené důkazy.

## Vstup: envelope v1

Úplný spustitelný příklad: [link-fixture.json](Tests/IngressKitTests/Fixtures/link-fixture.json).
Typy a přísné schéma: [WireEvidence.swift](Sources/IngressKit/WireEvidence.swift).

| Pole | Význam |
|---|---|
| `schemaVersion`, `runID`, `runStartUTC` | Verze 1, UUID předregistrovaného běhu, UTC epocha `YYYY-MM-DDTHH:mm:ss.SSSZ`. |
| `matrixJSON` | Volitelný řetězec s nezměněným vstupem existujícího `evaluate`. Vnořený decoder samostatně odmítá unknown/duplicate keys. Chybná či chybějící matice nezahodí raw finding. Jiný runID se neasociuje. |
| `sources[]` | Jedinečné `id`, `format`, `origin`, volitelné `clock` a přesné raw `text`. Hodnoty `origin`: `fixture`, `importedMeasured`, `unknown`. `importedMeasured` je tvrzení dodavatele, nikoli ověření měření. |
| `clock` | `id`, `offsetMs` přičtený k raw UTC, `uncertaintyMs` včetně kvantizace a driftu, `discontinuities`, `calibrationID`. Jsou to externí tvrzení, ne sběr nebo ověření synchronizace. |
| `endpoints[]` | Allowlist: `id`, `scenarioID`, `transport`, přesné `bind`, cílové `local` a zdrojové `remote`; každý endpoint má numeric `host` a `port`. Žádné rozšiřování allowlistu z observed raw. |
| `bindings[]` | `flowID` ingress UUID, `scenarioID`, `stage`, `endpointID`, volitelný přesný `canary`, `sender`, `senderIdentity`, `counterpart`, `capture`. Jde o explicitní kandidátní asociace, ne fakt přítomný v C1/common wire. |
| `sender`, `senderIdentity` | `sourceID` a **první fyzický řádek** `line` příslušného raw objektu, od 1. C1 identity a send musí být sousední objekty stejného zdroje a mít totožný context. |
| `counterpart` | `sourceID` a numerické `flowID` common. Toto číslo platí jen uvnitř daného zdroje, není run nonce ani ingress UUID. |
| `capture` | `sourceID` a `captureID` odděleného packet importu. Packet má přímo ingress flow UUID; shoda je stále neautentizované tvrzení importéra. |

Legacy `c1RunRecordStream` přímo nepředává svůj run/flow/canary/endpoint. Adapter neztotožní source ID, PID, caseID,
číslo common flow, úspěšný kernel send ani podobný čas s chybějícím nonce. Report tyto mezery
vypisuje **i při shodě všech dostupných údajů**. Jediný sender řádek/common flow nelze přiřadit
více bindingům. Jediný ingress flow UUID nelze recyklovat mezi buňkami nebo controls;
pozdní událost původní test flow v drainu zůstává u původního bindingu `stage: test`.

### Skutečné podporované producer formáty

Všechny odkazy níže jsou repo zdroje přečtené na výchozím main
`afae1ca7dfe78f03d5006c42b6b01093772eba0c`; tento follow-up je nemění.

| `format` | Zdroj wire / skutečné vlastnosti / limit |
|---|---|
| `c1RunRecordStream` | [C1 main](../Sources/sanjbox-s3-probe/main.swift) volá [common `printJSON`](../../common/Sources/SanjboxProbeKit/CommandLine.swift), tedy **po sobě jdoucí pretty JSON objekty, nikoli JSONL**. Bounded framer zachová první/poslední řádek; každý objekt jde přes strict decoder. [RunRecord](../../common/Sources/SanjboxProbeKit/RunRecord.swift), [ProbeContext](../../common/Sources/SanjboxProbeKit/ProbeContext.swift): identity outcome/details, send case/context, `localKernelAcceptedBytes` nebo `clientError`. Čas send je čas dokončení, není pokus/connect/interval. |
| `commonCounterpartJSONL` | [CounterpartEvent](../../common/Sources/SanjboxCounterpart/CounterpartEvent.swift), [emitter](../../common/Sources/SanjboxCounterpart/Counterpart.swift), [JSONLines encoder](../../common/Sources/SanjboxProbeKit/JSONLines.swift): started/listeners, accepted před bytes, closed, datagram, stopped; lokální/vzdálený tuple, raw basename, bytes, canary findings/truncation/end reason. Parsuje se raw log, **nikoli agregovaný CounterpartReport**. |
| `packetImportV1JSONL` | Nový C3 import formát níže pro již dodaný transcript nezávislého packet observeru. Není to výstup common, živý capture ani parser pcap/tcpdump. |

C1 knihovna a counterpart target nejsou public library produkty. Adapter je neimportuje,
nekopíruje ani nenahrazuje jejich enforcement/transport. Používá wire DTO a již exportovaný
`SanjboxProbeKit` context, outcome, canary model a **sdílený identity/membership validator**.
Případné neznámé rozšíření wire formátu se odmítne, nesmí být tiše ignorované.

[producer-vectors.json](Tests/IngressKitTests/Fixtures/producer-vectors.json) vznikl kompilací
[čistého generátoru](tools/producer-vectors/main.swift) s **nezměněným** `CounterpartEvent.swift`
a současnými common object files. Pokrývá success/error/invalid identity C1 a TCP/zero TCP,
UDP/zero UDP, IPv6 a IPv6 wildcard receiver. Generátor nevolá produkční sender/listener ani
capture; fixuje všechny hodnoty. Přegenerování po výše uvedeném Release buildu:

```bash
C3_REL="$C3_TMP/build/arm64-apple-macosx/release"
swiftc -O -I "$C3_REL/Modules" \
  spikes/s3-pf/ingress/tools/producer-vectors/main.swift \
  spikes/common/Sources/SanjboxCounterpart/CounterpartEvent.swift \
  "$C3_REL"/SanjboxProbeKit.build/*.o -o "$C3_TMP/producer-vectors"
"$C3_TMP/producer-vectors" > "$C3_TMP/producer-vectors.json"
cmp "$C3_TMP/producer-vectors.json" \
  spikes/s3-pf/ingress/Tests/IngressKitTests/Fixtures/producer-vectors.json
```

Testy navíc dekódují C1 vektory public `RunRecord` modelem a znovu je serializují skutečným
pretty encoderem. Není potřeba změna common Package.swift ani nový library produkt.

### Oddělený packet import

Každý řádek obsahuje `timestamp`, `kind` (`captureStarted`, `packetContact`, `captureStopped`),
`runID`, `scenarioID`, `captureID`, `clockID`, `interface`, `oracleInstanceID`, `family`.
Packet navíc obsahuje `flowID`, `transport`, cílové `local` a zdrojové `remote`; stopped má
`droppedPackets` a `gapsMs`. Start/stop nejsou packet observations. Jeden packet řádek odpovídá
jedné matrix `packetContact` události, nikoli agregovanému počtu či payloadu. Packet import
nemá podporu transport handshake/payload/pcap analýzy. Original capture, filtr, umístění,
interface attribution, drops, souběh a identity recorderu musí ověřit reviewer mimo tento CLI.

Common `.bin` jsou application bytes, nikoli packet capture. Příjem 0 B při acceptu/datagramu
je stále kontakt. Naopak absence acceptu/bytes nevylučuje SYN, ICMP nebo jiný packet.
Dodané booleany podpisu/identity a jakýkoli hash nezakládají důvěru v původ. SHA-256 ve výstupu
se počítá z přesných dodaných source bytes a slouží pouze k reprodukci importu.

## Kontroly a zachování nálezů

- Přísný envelope/schema, escaped duplicate/unknown keys, typy/enumy, bounds; raw dokumenty
  mají vlastní strict decoding. Chybný raw řádek/objekt se označí jako neinterpretovaný,
  **neobnovuje se heuristicky**, ale platné sibling záznamy a jiné zdroje zůstanou.
- Přesný case/run/flow/stage matrix binding, rodina, transport, listener bind/port a oba
  endpointy podle allowlistu; adresy se kanonizují numeric parserem bez resolveru.
  LAN → loopback cíl musí být adresa cílového stroje, ne localhost LAN klienta.
- Started/stopped pořadí, TCP accept/close a UDP flow jedinečnost, změny tuple, raw basename;
  neúplný/malformed lifecycle, změna tuple či capture nevymaže kontakt. Truncated application
  raw není automaticky ztráta packet capture; drain limit je samostatná neúplnost.
- C1 identity/send context se porovnává s přesným matrix initiator PID/credentials/session,
  včetně skutečné membership odpovědi sdíleným validátorem. Receiver nemá procesní identitu;
  `remote` je síťový tuple, **ne audit token nebo důkaz identity peeru**.
- Raw accepted/closed/payload/packet observations a odpovídající matrix události se párují
  **jedna ku jedné**. Deterministické maximum bipartitní párování přes augmenting paths
  zohledňuje druh, flow, actor/stage, doložené tuple/provenance a čas včetně uncertainty.
  Pozdější observation může přeuspořádat dřívější shodu; překryv časových intervalů proto
  nezpůsobí falešný konflikt kvůli první greedy volbě. Každá occurrence má vlastní vrchol,
  i při stejném timestampu. Nepřiřazené raw **i** matrix události se explicitně hlásí.
  Každá strana má nejvýše 256 událostí pro druh/flow; algoritmus má mez O(V×E).
- Payload vyžaduje přesnou shodu skutečně uvedeného `bytes` s matrix `value`, bez sčítání
  nebo domýšlení. Explicitních 0 B smí mít žádný payload event nebo právě odpovídající
  zero-valued event; nemůže podpořit kladný matrix payload. Chybějící `bytes` jsou neznámé,
  nikdy nula, a nepodpoří ani zero-valued claim. Chybějící counterpart binding/terminal
  nemůže skrýt existující matrix payload. Zero-byte kontakty v globálních findings zůstávají.
- Exact canary findings se vážou na dodaný syntetický canary; generic prefix není nonce.
  Nesoulad canary, tuple či count je konflikt. I shoda canary na receiveru nedoplní chybějící
  C1 canary/flow field. C1 více UDP sendů se nesmí rozdělit na zdánlivě ověřené jednotlivé flow.
- Čas: `(raw UTC − runStartUTC) + offsetMs`. Literal millisecond field se zachovává,
  neprochází znovu truncating formatterem. Uncertainty nejméně 1 ms zahrnuje kvantizaci,
  kalibraci i drift. Neznámý offset/bound nebo clock jump zneúplní asociaci. Všechny použité
  časové intervaly musí ležet ve stage i s uncertainty, lifecycle musí pokrývat controls,
  test i drain, drain musí překročit retry + 2× RTT + 2× max(clock uncertainty).
- Změna run/case/clock/interface/oracle/family/capture ID u packet importu, chybějící packet
  k matrix claimu, ztráty či gaps jsou explicitní problémy. Capture nedoplňuje absentující
  C1 nonce a neprokazuje důvěryhodnost samotným oracleInstanceID.

`findings` je globální seznam **raw observačních záznamů** accepted/closed/datagram/packet;
accepted + closed + packet nejsou tři unikátní flows. Obsahuje původ a referenci na raw řádek,
případné `claimedBindings` a indikaci invalid/incomplete zdroje. Nezávisí na platnosti
matrix, podpisu, jiné identity, canary, clocks nebo capture. Chybné jiné evidence nesmějí
proměnit známý kontakt v „nic nepozorováno“. Chybně syntaktický samotný záznam nelze bezpečně
interpretovat; report výslovně říká, že může obsahovat další neinterpretované findings.

`links` uvádí `checks`, konflikty `problems`, **vždy nenulové** `missingBindings`, source lines,
endpoint registration a projekce časů. Report uchová také `runStartUTC`, `inputSHA256` přesných
envelope bytes a validní `matrixDeclaration` včetně očekávaných/pozorovaných peer identit a oken. `partialLinkNeedsReview` znamená jen shodu dostupných
polí podle importovaných tvrzení; `conflictingOrIncompleteLink` hlásí rozpory/neúplnost.
Původ každého zdroje se zachová; mix fixture/imported/unknown se označí a nic se nepovýší
na measured. Existující `matrix` je výstup původního konzervativního classifieru beze změny
významu. Adapter jeho eventy nedoplňuje ani automaticky neodstraňuje integrační gap.

## Pevné meze a zbývající práce

Stdin ≤1 MiB / 2 s; ≤16 zdrojů, ≤512 KiB na source text, ≤256 raw záznamů na zdroj,
≤16 KiB na raw záznam, JSON depth <24 a collection ≤256. ≤84 bindingů/endpointů, ≤28 buněk
matice. Unsupported source format se označí bez interpretace. Counterpart flow 1…1 000 000,
bytes ≤1 GiB, ≤16 listenerů, ≤64 canary findings. Endpoint port 1…65535; neznámé numeric
rodiny, scoped/link-local, multicast a IPv4-mapped IPv6 jsou explicitně nepodporované.
Clock offset ±24 h, uncertainty 1…60 000 ms; projekce jen −1 h…+2 h kolem epochy. Tyto meze
jsou přístrojové limity, ne přijatá akceptační metodika L4.

Legacy C1 run/flow/tuple/canary/interval metadata a common identity v původních formátech
stále chybí; nový opt-in formát níže tuto část doplňuje. Nezávislá capture provenance stále chybí. UDP wildcard receiver loguje bind endpoint (`0.0.0.0`/`::`),
nikoli skutečnou cílovou interface adresu; takový raw log nelze vydat za exact local tuple.
V6-only/mapped/reuse, fixed-port squatting/owner/reclaim, autentizovaný same-zone roundtrip,
full LAB controls, opakování a L4 délky/failure modes, tři oblasti a ochranný mechanismus
zůstávají otevřené. Neproběhlo živé měření, pf read/write, změna uživatelů, TCC, signing,
settings, přístup ke Klíčence/tajemstvím/databázím ani LAN/wildcard/network probe.

Navazující krok je nezávislé review původu importovaných raw, skutečné testArea/L4 a bind policy; ruční nastavení signing booleanu či přejmenování fixture tyto důkazy nedoplní.
Původní laboratorní předpoklady a [LABPLAN](LABPLAN.md) zůstávají v platnosti.

## Explicitní consumer `sanjboxNetworkProvenanceV1`

Nová opt-in větev čte přesný schema-1 JSONL z C1/common na základním commitu
`dd058d3f4e758ed7fdef7dc64eba1c9a34a66967`. Převod do legacy formátů není povolený.
Starší [producer dokument](../NETWORK-PROVENANCE.md) popisuje stav před tímto consumerem;
producer ani jeho historické důkazy tento follow-up nemění.

`source.format` je přesně `sanjboxNetworkProvenanceV1`, `text` obsahuje původní JSONL.
Volitelné `artifacts` je pole nejvýše 18 objektů `{name, count, sha256, base64}`:

- `expect.json` a `probe.json`: přesné původní vstupní bajty, každý nejvýše 16 KiB.
- `sent.bin` a `received-1.bin`…`received-16.bin`: přesné application bytes, každý nejvýše 4096 B.
- Base64 musí být canonical RFC4648 bez whitespace; skutečný počet a SHA-256 se ověří.
  Duplicitní názvy, jiné názvy/cesty, chybná délka, hash nebo encoding jsou konflikty.
  Prázdný soubor má explicitně `count: 0`, `base64: ""` a hash prázdných bytes.
- Názvy jsou pouze klíče v envelope. **Žádný soubor se podle nich neotevře.** Chybějící
  artifact je neznámý, nikdy nula ani rekonstrukce z hashe nebo `payloadClaims`.
  Raw bez terminalu může mít ověřené vložené bytes, ale nedostane smyšlený terminal count.

Pro binding se použije pouze:

```json
"network": {"senderSourceID": "sender", "receiverSourceID": "receiver", "contactID": 1}
```

Stále platí explicitní ingress `flowID`, `scenarioID`, `stage`, `endpointID`; původní
`capture` zůstává oddělený packet import. `network` se nesmí míchat s `sender`,
`senderIdentity`, `counterpart` nebo legacy `canary`. Sender lze přiřadit jednomu bindingu,
receiver contact jednomu bindingu. `contactID` platí jen v konkrétním receiver source/instance.
Tentýž producer instance pod více source ID je replay/alias konflikt. Binding nevybírá
jen „povedené“ kontakty: všechny ostatní raw kontakty zůstávají v globálních findings.

Schéma odmítá duplicate/escaped duplicate keys, unknown keys a explicitní `null` v nových
source/envelope polích a novém wire. Optional pole se vynechává. Platí původní 1 MiB stdin,
16 zdrojů, 512 KiB text/source, 256 řádků/source, 16 KiB/řádek, 84 bindingů a depth <24.
Žádný limit legacy formátů se nezvyšuje. Syntakticky neinterpretovatelný řádek se uvede
jako možný další nález; dekódované kontakty se zachovají i při chybném lifecycle či metadatech.

Consumer ověřuje:

1. Přesné hashe vstupů z `registered`, obsah `probe.json` proti vložené registraci a
   names-free identitu/podpis proti `expect.json`. Common validace identity a policy je
   čistá; **neprobíhá OS membership dotaz, codesign, preflight ani sběr identity**.
   Tyto shody ověřují konzistenci dodaných tvrzení, ne autorství/podpis importu.
2. Stabilní run/flow/instance/PID/parentPID/role/scope/transport/family; posloupnost od 1
   bez duplicit/mezer; monotonic i UTC pořadí uvnitř procesu. Příprava flow se porovná
   s historickým `registered` (−1…600 s), nikdy s dnešním časem.
3. Sender intent v `sent.bin`, kumulativní `kernelAccepted`, `attemptEnded`, a skutečný
   `connected.local/remote` odděleně. Partial/error progress se zachová; accepted bytes
   nejsou potvrzení příjmu. Receiver má vlastní `receiverStarted` skutečný bind,
   kontakt před raw a přesný terminal/count/hash/tuple. Chybějící konce, limity,
   truncation a přerušené prefixy vždy znamenají neúplnost.
4. Receiver claims se znovu parsují z **vložených raw bytes**, včetně foreign zero UUID,
   malformed/partial bytes, cizího run/flow/nonce, nuly a opakovaného frame. Zero UUID je
   povolený jen v cizích payload claims, nikdy v lokální registraci/identitě běhu.
   Challenge je korelace; neposkytuje autentizaci peeru ani globální replay prevention.
5. Sender skutečný local tuple odpovídá receiver remote a sender remote/target receiver
   local. Matice dále ověřuje vlastní identitu/PID/instance/signature flags účastníků.
   Exact-bind producer **nepokrývá wildcard scénáře**; původní matice 28 scénářů se nemění.
6. `attempt`, `connected`, `accepted`, `closed`, `payload` a oddělené packet observations se párují
   s maticí jedna ku jedné v obou směrech. UTC projekce potřebuje externě dodané bounded
   `clock`; samotné monotonic časy nedokládají společnou doménu mezi procesy/stroji.
   Kontroly oken, drain/retry/RTT, capture gaps a jeho lifecycle zůstávají konzervativní.

`SourceReport.network` vrací dekódované producer záznamy, chyby každého řádku, receipts
artifactů a konkrétní kontroly. Raw observation `findings` přidává `networkFlowID`,
`networkContactID` a `payloadDisposition`; disposition je výslovně tvrzení z logu,
nikoli důvěryhodná klasifikace peeru. `source.problems` a record errors platí i při
zachovaném kontaktu. Žádný consumer výstup není isolation pass nebo capture completeness.
`hostDiagnostic` zůstává host diagnostikou, nikdy se nepovýší na `testArea`/L4.

### Reprodukce bez sítě

[Kompatibilitní vektory](Tests/IngressKitTests/Fixtures/network-producer-vectors.json)
obsahují přesné nezměněné bytes 61 souborů z devíti uložených producer případů: čtyři
signed C1 TCP/UDP v4/v6 positives, common receiver UDP/TCP adversarial, contact limit,
přerušený TCP prefix a odmítnutý connect. [Provenance](Tests/IngressKitTests/Fixtures/network-producer-provenance.json)
uvádí původní cesty a hashe, producer commit `ba339392df85f0798ba66b9f4842735558467646`
a hash původního manifestu. Adversarial provoz původně generovala syntetická Python fixture;
receiver logy pocházejí ze skutečného produceru. Vektory neobsahují vymyšlený matrix/capture/clock.

```sh
python3 spikes/s3-pf/ingress/tools/network-producer-vectors.py
python3 spikes/s3-pf/ingress/tools/check-network-adapter-cli.py "$C3_TMP/build/release/sanjbox-ingress"
python3 spikes/s3-pf/ingress/tools/check-offline-cli.py "$C3_TMP/build/release/sanjbox-ingress"
```

První příkaz ověřuje přesnou projekci proti původnímu manifestu; `--write` explicitně
přegeneruje pouze dva vlastní fixture soubory. Druhý provádí devět replays a syntetické
negativní vstupy pouze přes stdin; `--output NOVY_ADRESAR` uloží přesné vstupy/stdout/stderr
bez přepsání existujícího adresáře. Unit negativní mutace i matrix/clock overlays jsou
výslovně `fixture`/mock a nemění původní evidence. Žádný příkaz nepouští síťovou sondu.
