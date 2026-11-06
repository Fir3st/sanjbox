# WP1.C1 — předregistrovaná síťová producer provenance v1

Samostatný opt-in režim C1 senderu a common receiveru přenáší skutečný syntetický frame
přes TCP nebo UDP. Zaznamenává vlastní identitu/podpis, předregistraci, pokus, skutečné
socket tuple a nezávislé přijaté raw. **Není to ochranný mechanismus ani verdikt S3/S3b/L4.**

Staré příkazy C1 a `sanjbox-counterpart listen/report`, jejich wire modely i globální
`printJSON` zůstávají beze změny. Nové JSONL mají `format: sanjboxNetworkProvenanceV1`
a `schemaVersion: 1`. Existující [C3 adapter](ingress/ADAPTER.md) je **nepodporuje**;
nesmějí se podstrčit pod legacy format. Nový explicitní adapter je navazující práce.

## Příkazy a předregistrace

Obě binárky podporují:

```text
provenance-identity
provenance-prepare --run-id UUID
provenance --expect /absolute/expect-NAME.json --input /absolute/probe-NAME.json [--apply]
```

Bez `--apply` se jen validuje plán, nevzniká socket, identitní měření ani output directory.
`provenance-identity` je výslovný names-free sběr metadat **volajícího procesu** pro přípravu
samostatné předregistrace. Nevyplňuje smyšlené ASID a neprohlašuje host za testovací oblast.
`provenance-prepare` vytvoří nový flow UUID a 256bit challenge pomocí OS randomness;
run UUID dodá předregistrant. Nepřistupuje k síti. Oba příkazy produkují jeden JSON řádek.

Nejdřív sestavit a ověřit podpis, teprve potom připravit očekávání a flow. Použít nové
vstupy pro každý běh. Flow má platnost nejvýše 10 minut od `preparedAtUTC` (nejvýše 1 s
budoucího času kvůli kvantizaci); změna či replay souboru po této době se odmítá.
Importovaná předregistrace není důkazem, že její autor opravdu použil OS generátor.

`expect-*.json` obsahuje `schemaVersion: 1`, `scope`, `identity`, `signature`,
`forbiddenAuditSessionIDs`. Výstup identity slouží jako návrh host očekávání, který je
nutné uložit **před** měřením. Kontroluje se přesný real/effective UID/GID, kernel groups,
audit UID/ASID/flags, launchd manager a číselná window session; required/forbidden groups
se navíc ověřují skutečným membership dotazem a common `ProbeExpectation` validátorem.
Záznamy neobsahují username, hostname, TeamID ani certifikáty; nástroj nevyhledává
Klíčenku ani credential stores. Z OS identity/signing odpovědí zpracovává jen uvedená pole.

- `hostDiagnostic` umožňuje výslovně předregistrovaný host kontext; není to S1 oblast.
- `testArea` navíc zachovává přísnou C1 politiku: UID 400…60000, shodné real/effective
  credentials, required groups, forbidden groups včetně 20/80, Aqua manager/window pod
  stejným UID, přihlášená non-console session a exact audit ASID. Neprázdný předem
  zakázaný seznam host ASID se nesmí překrývat se skutečným/požadovaným ASID.
- Vlastní běžící kód se ověřuje Security API bez síťového přístupu: validita, code hash,
  hardened runtime a nepřítomnost obou názvů `get-task-allow` (i hodnota `false` se odmítá).
  Nejde o Personal Team/S8 výsledek ani autentizaci síťového peeru.

Při `--apply` proběhne preflight **před čtením target souboru a před socketem**. Neplatná
identita/podpis skončí s chybou; target se neotevře. Vstupní soubory jsou ≤16 KiB, s přesně
vymezenými názvy, bez symlinků/hardlinků/ACL/FIFO/device, bez zápisu jiným uživatelem.
Strict JSON odmítá také unknown a escaped duplicate keys, hluboké a nadlimitní kolekce.

`probe-*.json` má tento tvar (hodnotu `flow` vložit beze změny z prepare):

```json
{
  "schemaVersion": 1,
  "scope": "hostDiagnostic",
  "flow": {"runID": "UUID", "flowID": "UUID", "challenge": "64 lowercase hex", "preparedAtUTC": "UTC with milliseconds"},
  "transport": "tcp",
  "endpoint": {"host": "127.0.0.1", "port": 0},
  "controlledTarget": true,
  "durationMilliseconds": 1500,
  "maximumContacts": 16
}
```

Receiver může použít port 0. Oznámí přidělený numeric endpoint na stdout po durable
`receiverStarted`; před spuštěním senderu uložit nový sender input s tímto přesným portem.
Sender vyžaduje port 1024…65535. Obě strany mají tentýž run/flow/challenge; každý proces
si zachová přesné vlastní input bytes a jejich SHA-256. Před prvním socketem se synchronně
zapíše `registered`. Samotná existence souborů/hashů nedokazuje externí autorství.

Produkt přijme explicitně řízený canonical numeric unicast v4/v6 endpoint. Žádný DNS,
proxy, fallback, wildcard, scoped/link-local, multicast, IPv4-mapped/compatible v6;
IPv4 rozsahy 0/8 a 224/3 a adresy končící `.255` jsou také odmítnuté. Skutečný unicast
význam v dané síťové topologii a vlastnictví cíle musí určit předregistrant. IPv6 socket
má `IPV6_V6ONLY=1`; `SO_REUSEADDR` ani `SO_REUSEPORT` se nepoužívá. Přesný bind znamená,
že UDP local je konkrétní application destination, nikoli wildcard. Není to před-NAT
packet tuple nebo interface attribution. Zde se reálně testoval pouze vlastní loopback.

## Raw a význam událostí

Výstup vzniká výhradně v novém `/private/tmp/sanjbox-network-RUN-FLOW-ROLE/` (0700),
s descriptor-held exclusive soubory (0600), bez následování symlinků a bez append/reuse.
Adresář obsahuje `expect.json`, `probe.json`, `events.jsonl` a malé `*.bin`. Sonda nikdy
nemaže existující důkazy. Sender/receiver mají samostatné procesy, instance UUID a PID.
`runID`/`flowID` na každé události vždy patří **místní předregistraci**.

| Událost | Přesný význam |
|---|---|
| `registered` | Vlastní ověřená identita/podpis, přesná registrace a hashe obou vlastních inputů; před socketem. |
| `attemptStarted` | Sender zapsal `sent.bin` a zamýšlený `target`; socket ještě neotevřen. |
| `connected` | Kernel `getsockname`/`getpeername` poskytl skutečné `local`/`remote`. |
| `kernelAccepted` | Kumulativní bajty přijaté lokálním send syscall; **nikoli příjem protistranou**. |
| `attemptEnded` | Konec pokusu, důvod a zachované partial accepted bytes. Failed connect nemá smyšlený observed remote. |
| `receiverStarted` | Přesný skutečně bound endpoint; po bind/listen, před prvním accept/recv. |
| `accepted` | TCP kontakt zaznamenaný před čtením bytes; i zero-byte kontakt zůstává nálezem. |
| `datagramContact` | UDP kontakt/count/tuple/truncation před raw uložením a parsováním. |
| `closed` / `datagram` | Nezávislé raw bytes, count/hash, důvod konce, truncation a případná neautentizovaná payload claims. |
| `receiverStopped` | Listener/accepted sockety zavřené; důvod `windowElapsed`, limit nebo chyba. Žádný capture-completeness claim. |

Frame je přesně ASCII `SANJBOX-NETWORK-PROVENANCE-V1|RUN-UUID|FLOW-UUID|64hex\n` (169 B).
UUID jsou canonical uppercase. Hash v senderu váže zamýšlený `sent.bin`; hash receiveru
váže jeho vlastní `received-N.bin`. `payloadClaims` vznikne jen z přesných canonical
bytes. `matchesRegisteredPayload` porovnává celý frame s lokální předregistrací;
`repeatedRegisteredPayload` označuje další stejný frame v témže receiver běhu. Cizí run,
špatný nonce, neúplné/malformed bytes i nula zůstávají v raw. Challenge je korelace,
**nikoli peer credentials, MAC, autentizace nebo globální replay prevention**.

UTC má milisekundové rozlišení, každá událost také vlastní monotonic nanoseconds a
sekvenční číslo. `attemptStarted`…`attemptEnded` je interval pokusu zahrnující socket,
connect a send; explicitní accepted progress je uvnitř. Monotonic časy jsou srovnatelné
jen v příslušné clock doméně. Cross-host synchronizace/uncertainty se tím nedokládá.

## Meze, chyby a nedokončený prefix

Jeden sender socket/frame bez reconnectu; jeden receiver listener, nejvýše 16 kontaktů,
4 KiB raw na kontakt a 100…10000 ms běhu. TCP reader je sekvenční a má nejvýše 500 ms
na kontakt, vždy omezené koncem celého běhu. UDP používá `recvmsg`/`MSG_TRUNC`. Dosažení
4 KiB TCP je konzervativně incomplete i kdyby následovalo EOF; UDP truncation uvádí
pouze zachovaných 4096 B, nikoli odhad celé délky. Žádný neomezený drain ani background worker.

TCP raw se uloží/fsync po každém observed chunk před dalším wait. Chyba raw zápisu
nevytvoří terminal s vymyšleným hash/count. Mezera mezi kernel read a prvním zápisem
není atomická; arbitrární crash může ztratit poslední chunk. Chybějící terminal nebo
malformed poslední řádek znamená neúplný běh, nikoli nulový provoz. Chyba pozdějšího
sendu/journalu nezahodí dřívější kernel accepted count. Fixed 30 s SIGALRM watchdog
pokrývá i identity/signature/filesystem calls; nejde o realtime či power-loss garanci.

Exit 0 = operace skončila v přístrojových mezích, **ne verdikt izolace**. Exit 3 =
přístrojová neúplnost (limit kontaktů, read deadline, truncation, connect/send failure).
Exit 2 = odmítnutí vstupu/preflight/output nebo write error; signál = přerušený proces.
Žádný terminal, `operationFinished` ani ticho receiveru nedokazuje úplnost capture,
absenci SYN/ICMP/paketů či ochranu dalších listenerů. L4 controls, retry/drain metodika,
v6/mapped/reuse/squatting policy a tři skutečné oblasti zůstávají k ověření.

## Reprodukce vlastní host diagnostiky

Použít čerstvé vlastní build/cache adresáře jako ve [VALIDATION](NETWORK-PROVENANCE-VALIDATION.md).
Obě postavené binárky zkopírovat do vlastního dočasného adresáře, podepsat ad-hoc
`codesign --force --sign - --options runtime --timestamp=none` a ověřit `--verify --strict`.
Nejsou potřeba certifikáty, Klíčenka, TCC, root ani síťový capture.

```bash
python3 spikes/s3-pf/tools/check-network-provenance.py \
  --sender /private/tmp/OWN/sanjbox-s3-probe \
  --counterpart /private/tmp/OWN/sanjbox-counterpart
# Po kontrole dry-runu stejný příkaz s --apply.
```

Runner nejdřív uloží names-free identities, všechny flow/nonce a pevné kontroly,
pak použije pouze vlastní ephemeral `127.0.0.1`/`::1`. Čtyři pozitivní flows odesílá
skutečná C1 binárka; adversarial injekce jsou výslovně Python fixtures. Procesy má
pod vlastními Popen handles s timeouty; po testu je reapne a zavře vlastní sockety.
Raw/preregistrace/manifest zůstávají. Cleanup build/cache provádět jen nad přesně
vytvořenými vlastními adresáři, nikoli nad globálním prefixem nebo raw důkazy.
