# Ověření WP1.C3 přípravy

Vývoj z čistého main `547f3c1e630cdd95662b9a9f339a22f7a1c47026`, claim `51fe877`.
Žádný C1/C2 kód, systémový zásah, pf read/load, wildcard/LAN/external test ani uzavřený gate důkaz
není součást ověření. Coverage mění pouze vlastní WP1.C3 řádek a F1 agregát 2 done / 1 partial / 27 todo;
155 testů a všechny brány zůstávají beze změny.

## Automatické fixtures

Release Swift Testing bez XCTest, bez externích závislostí, build/cache pod `/private/tmp/sanjbox-c3-*`.
Testy neotevírají sockety. Ověřují skutečný JSON parser/reducer a vlastní dočasné výstupy:

- unknown/duplicate/escaped keys, depth/size/count meze, role/flow/run/actor vazby;
- planned/mock/measured odlišení, všechny neprovedené buňky matice;
- nulové payloady při přijatém spojení, zachování findingu při částečném capture;
- nesprávné/chybějící identity, host vydávaný za same-zone, obrácené role;
- chybějící před/po controls, expected handshake, capture/drop/gap/retry/time coverage;
- časově nemožný handshake/close, odmítnutí reuse flow mezi nesouvisejícími stages, zachování
  opožděného kontaktu test → drain na původní flow, bind acquired také v drain;
- rozlišení ephemeral collision a pevné host-port rezervace;
- pure signature policy fixtures (runtime/forbidden entitlement/raw undecoded metadata), bez tvorby
  skutečných binárek s forbidden entitlementem;
- create-new/no overwrite, dry-run a idempotentní cleanup, změněné bajty a přidané entries,
  immutable flag souboru i adresáře, GID drift, symlink/hardlink a ACL souboru i adresáře zachované před
  prvním unlink, explicitní obnovení jen testovací fixture. Symlink fixture zachovává přejmenovaný
  report ve stejném adresáři, takže nejdřív narazí na extra-entry guard; samostatně neizoluje O_NOFOLLOW.
  Tento dílčí limit unit fixture pokrývá níže uvedená nezávislá CLI zkouška se zálohou reportu mimo dataset.

Dne 2026-11-03 prošlo **21/21** automatických fixtures (Swift 6.4, release native SwiftPM;
privátní build log `/private/tmp/sanjbox-c3-test.log`). GID perturbace byla na tomto hostu dostupná,
nepřeskočená. Před/po finální sérii byla množina `sanjbox-c3-run-*` a `sanjbox-c3-link-*` v `/private/tmp`
prázdná. První neúspěšný běh odhalil nesprávné zacházení s Darwin ACL ENOENT; oprava rozlišuje prokázanou
absenci ACL od jiné chyby. Čtyři prázdné vlastní adresáře z tohoto běhu byly identifikované přesnými UUID
+ inode/device/UID/GID/mode/flags a samostatně odstraněné ne-rekurzivním rmdir; žádný glob cleanup.

První nezávislý release build byl neplatný kvůli změně testovacího souboru za běhu kompilace
(`input file modified during build`); log je zachován v `/private/tmp/sanjbox-c3-root-release.log`.
Po zmrazení všech 21 testů a Sources prošel nový izolovaný release build **21/21, 0 failures, 0 skips**
(2026-11-03 19:27:03 CET, `/private/tmp/sanjbox-c3-root-release-final.log`). Obsahoval také skutečné
GID/ACL/flags fixtures. Varování o budoucím odstranění native SwiftPM backendu je očekávané;
první přerušený build se nepočítá jako validace. Čtyři původní prázdné adresáře (inode 280754171–174)
koordinátor následně nezávisle ověřil jako nepřítomné.

## Nezávislé ověření skutečného CLI

Koordinátor/reviewer po finálním buildu znovu podepsal vlastní release CLI ad-hoc (`-s -`), s hardened
runtime, prázdnými entitlements a bez timestampu. Od tohoto resealu nebyl žádný rebuild. Exact identity
expectation porovnal s nezávislým pomocným sběračem ve stejném execution kontextu; do repozitáře se
nedávají soukromé identity ani raw výstupy. Žádný test nevytvořil binárku s forbidden entitlementem.

**24/24 samostatných CLI kontrol prošlo podle očekávaného výsledku**: původní série 21 kontrol + 3
navazující kontroly nového běhu s uchováním raw. Negativní případy záměrně vracejí nenulový exit.
Soukromý souhrn původní série je `/private/tmp/sanjbox-wave5-root-smoke-foz3zpy5/c3-summary.json`,
celkový souhrn `/private/tmp/sanjbox-wave5-root-smoke-foz3zpy5/c3-summary-all.json`; nejde o akceptační
protokol brány. Původních 21 kontrol zahrnovalo:

- výchozí dry-run, `plan`, vlastní `identity` shodnou s nezávislým helperem a dry-run smoke;
- odmítnutí malformed/duplicate/unknown expectation, nesprávného audit session ID a zděděného
  SIGCHLD SIG_IGN před childem/sockety; parent signal disposition zůstala beze změny;
- odmítnutí vlastní kopie s prázdnými entitlements, ale **bez runtime**, před soubory a sockety;
- skutečný IPv4 **i** IPv6 nonce echo před/po, actual `EADDRINUSE` při kolizi vlastního drženého
  ephemeral endpointu, close/rebind/recovery a uzavření všech vlastních socketových fd;
- izolovanou negativní O_NOFOLLOW zkoušku: originální report byl držen **mimo** dataset (žádný extra
  entry uvnitř), symlink i původní state zůstaly při odmítnutí zachované; následovalo explicitní
  obnovení vlastní fixture, dry-run cleanup, skutečný úklid a idempotentní `alreadyAbsent`;
- offline prázdný vstup → 28 planned buněk; opožděný kontakt s nulovým payloadem na stejné flow
  test → drain zachovaný jako `observedViolationNeedsReview` i s capture drops; odlišený `mockFinding`,
  missing identity → `invalidMeasurement` a odmítnutí duplicate/unknown offline JSON.

Původní 21kontrolová série zůstává zachovaná ve svém souhrnu; raw prvního smoke bylo uklizeno spolu
s testovací fixture. Proto následovaly tři nové kontroly: druhý fresh smoke s úplným reportem i state
uchovanými mimo uklízený dataset, actual cleanup tohoto nového datasetu a kontrola idempotence.
Nový raw report/state zůstávají v soukromém validačním adresáři; do commitu nepatří. Nebyl proveden
rebuild ani další resign. Obě rodiny prošly také v tomto druhém běhu.

Obě rodiny mají výsledek `transportControlObserved`, IPv6 nebylo přeskočené. Před a po CLI sérii
byla množina vlastních `sanjbox-c3-run-*` adresářů stejná a prázdná. Jde výhradně o vlastní loopback
syntetický smoke bez systémových root privilegií. Nezávislé spuštění reviewera z něj nedělá nezávislý
síťový oracle: samotný přístroj stále používá stejný proces/UID/session. Ephemeral collision není
pevná host-port rezervace. **C3 zůstává částečné a S3b/NET-10…12 zůstávají Neověřeno.**

## Zbývající mezery

C1 integrace/raw endpoint-capture adapter; nezávislý oracle se zdrojovou atribucí; skutečné host/LAN/
other-zone směry a same-zone relace; pevná host-port rezervace během uzavřené služby; wildcard a
IPv6 dual-stack/reuse varianty; vynucovací mechanismus bind policy; přijatá metodika/slot L4;
plný souběh a opakování, failure modes a review původu důkazů. Ad-hoc podpis není S8 důkaz.
Offline transcript je neautentizované tvrzení: ani kompletní deklarované flags nedají pass; kvůli
chybějícímu endpoint adapteru vždy zůstává integrační gap explicitní. Lokální transport control má
stejný proces/UID/session a nemá nezávislý oracle.

## Navazující offline adapter — 2026-11-05 (nový záznam)

Výchozí čistý main `afae1ca7dfe78f03d5006c42b6b01093772eba0c`, vlastní claim `f326cd7`.
Tato sekce doplňuje novou validaci; výše uvedené historické protokoly 21/21 a 24/24 včetně
jejich limitů zůstávají beze změny. Scope: `ingress/` a vlastní C3 řádek COVERAGE; žádné změny
C1 produceru, common, Contracts, PLAN, bran nebo jednotlivých acceptance testů. C3 zůstává
partial, agregát F1 **10 done / 5 partial / 15 todo** se nemění.

Prostředí ověřeno: arm64, macOS **27.2 (26B123)**, Xcode **27.0 (27A266a)**,
Apple Swift **6.4 (swiftlang-6.4.0.34.1, clang 2100.3.34.1)**.
Finální native Release test začal **2026-11-05 00:03:40 CET**. Bez externích balíčků;
lokální závislost je pouze veřejný SanjboxProbeKit. Testy nevolají živou identitu, sender,
listener, capture, pf ani síť. Stávající owned-output fixtures používají vlastní dočasné
soubory/ACL/flags/GID, stejně jako historická suite.

| Kontrola | Výsledek | Rozsah |
|---|---|---|
| Kompletní ingress native Release Swift Testing | **44/44 testů, 0 failures, 0 skips** | 21 původních a 23 nových testů, včetně parametrizovaných adversarial variant. ACL/GID/flags fixtures nebyly přeskočeny. |
| Skutečný Release CLI, [pevný offline harness](tools/check-offline-cli.py) | **17/17, 0 skips** | Plan/default, prázdná evaluate matice, deterministický link, skutečný C1 error wire, zero-byte contact při invalid matrix, neplatný packet sibling, unsupported format, duplicate/unknown/oversized envelope, odmítnutí file/PID/command/`--apply` argumentů, nezávisle vynucený 2s stdin timeout. |
| Nativní producer compatibility vektory | **9/9 vytvořeno a parsováno** | Čistý [generátor](tools/producer-vectors/main.swift) zkompilovaný s nezměněným common CounterpartEvent.swift a actual shared models/encoders; žádné sockety ani capture. C1 success/error/invalid identity, common TCP/UDP/zero-byte/IPv6/wildcard. C1 re-encode proti actual public RunRecord encoderu je součást suite. |
| `git diff --check`, relativní dokumentační odkazy | **pass** | Bez neplatných lokálních odkazů. |
| Vlastní výstupy a scratch | **uklizeno** | Po sérii žádné `sanjbox-c3-run-*`/`sanjbox-c3-link-*` zbytky. Vlastní build/cache/tmp a vývojové logy byly odstraněny z jediného přesně ověřeného nového scratch rootu; žádné cizí či historické důkazy. |

Reprodukce build/test a producer vektorů: [ADAPTER.md](ADAPTER.md). Po stejném buildu:

```bash
python3 -B spikes/s3-pf/ingress/tools/check-offline-cli.py \
  "$C3_TMP/build/release/sanjbox-ingress"
```

Nové fixture testy ověřují skutečný bounded parser a linker: multiline C1 stdout, exact
common JSONL, unknown/duplicate/escaped keys, vnořené formáty a meze, unbound nálezy i při
invalid matrix/identity/capture, duplicate/reused flows, obrácenou či změněnou tuple,
case/run/stage/canary/PID/audit/membership nesoulady, source hash a line provenance,
oddělení originů, wildcard/IPv6 literal canonicalization, explicitní mapped/scoped omezení,
capture ID/interface/oracle/clock/run/family podvrhy, chybějící lifecycle/packet binding,
loss/gap/clock jump/unknown bounds, příliš krátký drain a opožděný zero-byte close v drainu.

Vývojové neúspěchy se nezamlčují: první rozšířená kompilace odhalila omezení Swift Testing
makra s keypath predikátem (`allSatisfy`); nahrazeno ekvivalentní explicitní closure. Další
série odmítla validní fractional timestamps, protože reformatování parsed Date dokázalo
znovu useknout 1 ms. Oprava validuje celé UTC calendar seconds a zachová literal ms; samostatná
regrese pokrývá `.009`, `.010`, `.201`, `.999` a odmítá neplatná data/časové formáty. Doplněna
opačná kontrola matrix packet count → raw packet records, aby podvržený capture ID neskryl
chybějící odpovídající packet. Finální suite i CLI byly spuštěny po těchto opravách.

**Přesný dílčí závěr:** nyní existuje použitelný offline adapter skutečných producer wire
výstupů, dostupné receiver tuple/canary/časové a sender context vazby kontroluje a všechny
parsed contact findings zachovává. Chybějící C1 run/flow/target/canary/interval a common
identity/capture metadata nedoplňuje. Imported packet JSON není pcap důkaz; identity flags
ani hash nejsou atestace. Žádný výsledek není automatický pass a žádné S3b/NET/R2/R3 stavy
se nemění. Důvěryhodný peer handshake, capture provenance, bind policy, skutečný L4,
fixed-port squatting a plné controls/délky/opakování zůstávají otevřené. C1 se neměnilo,
proto nebyla znovu spouštěna jeho oddělená Swift/Python suite. Nezávislé review větve následuje
samostatně; tato sekce je validace implementátora, nikoli již provedené nezávislé review.

## Opravy po nezávislém review — 2026-11-05, 00:14 CET (nový záznam)

Čerstvé nezávislé review přesného HEAD `91733c7cd8f16482e9ecc1d776e08cb4effc3081`
reprodukovalo dvě P2 mezery, přestože výše uvedených 44 testů/17 CLI kontrol prošlo.
Předchozí výsledky a časové údaje jsou zachovány; tyto nové výsledky je nepřepisují.

1. Raw TCP `closed` s `bytes: 0`, prázdnými findings a bez rawFile mohl zůstat
   `partialLinkNeedsReview` bez problémů, zatímco matrix tvrdila payload 51 B. Kontrola
   běžela jen pro kladné raw bytes a chyběla opačná kontrola matrix claimu.
2. Dva raw packet records ve 1201 ms mohly oba použít stejný matrix packet ve 1201 ms,
   zatímco druhý matrix packet v 1800 ms zůstal nepokrytý. Shodný počet 2:2 tento konflikt
   nezjistil, protože každá raw kontrola používala samostatné `contains`.

Oprava páruje jednotlivé raw a matrix occurrences jedna ku jedné, v obou směrech, podle
actor/stage, druhu, flow, časové nejistoty a dostupných tuple/provenance polí. Deterministické
maximum bipartitní párování s augmenting paths může přeuspořádat dřívější shody; nespoléhá
na první greedy volbu při překryvu oken. Horní mez je 256 vrcholů na každé straně pro druh/flow,
časová složitost O(V×E), hloubka nejvýše 256. Duplicitní timestampy se nededuplicují.

Payload vyžaduje přesnou známou hodnotu receiver bytes. Explicitní 0 může mít žádný payload
claim nebo odpovídající zero-valued claim; nepodpoří 51 B. Chybějící bytes jsou neznámé,
ne nula. Chybějící terminal nebo counterpart binding nepokryje existující matrix payload.
Všechny nepokryté matrix claims a povinné raw occurrences mají explicitní problém.
Globální raw finding ledger se nemění: zero-byte accept/datagram i každý packet zůstávají.

| Kontrola | Nový skutečný výsledek |
|---|---|
| Kompletní native Release Swift Testing | **50/50 testů, 0 failures, 0 skips**, start **2026-11-05 00:14:08 CET**; 44 předchozích + 6 nových named tests s parametrizovanými variantami. |
| Skutečný offline CLI harness | **25/25 kontrol, 0 skips**; původních 17 + 8 navazujících reprodukcí/controlů. Obě přesné P2 reprodukce nyní dávají `conflictingOrIncompleteLink`; první zachová zero-byte kontakt, druhá zachová oba packet records a hlásí nepřiřazený raw i matrix event. |
| Producer compatibility vectors | **9/9 v aktuální kompletní suite**; producer wire/model ani vektory se nemění. |
| Maximální matching | Všechny **512 grafy 3×3** porovnány s nezávislým vyčerpávajícím výčtem částečných přiřazení; explicitní greedy counterexample `[[0,1],[0]]` a plný **256×256** graf prošly. |
| Formát, scope, historie | `git diff --check` a relativní odkazy pass; původní VALIDATION obsah zůstává nezměněným prefixem. |
| Vlastní scratch a výstupy | Nový `/private/tmp/sanjbox-c3-reconcile-fGvnGW` po ověření přesné cesty/UID/módu/inode odstraněn včetně vlastní build/cache/tmp/logů; žádný C3 run/link zbytek, žádné cizí nebo uzavřené důkazy odstraněny. |

Nové regrese pokrývají TCP/UDP bytes **zero / missing / absent terminal**, zero-valued i
nepřítomný matrix payload, chybějící counterpart binding, duplicitní/nesprávné matrix payload
claims a pozitivní raw payload bez matrix eventu. Packet regrese mají původní 1201/1800 ms
counterexample, platné odlišné shody, duplicitní stejný čas na obou stranách, extra raw/matrix
occurrence, přesnou hranici uncertainty, bod vně hranice, překrývající se intervaly a tuple
nesoulad. Každý případ kontroluje zachování raw findings. Reprodukce používá stejné příkazy
v ADAPTER.md a rozšířený `tools/check-offline-cli.py`; žádný živý smoke ani producer se nespouští.

Změny: pouze C3 `EvidenceAdapter.swift`, jeho fixtures testy/offline CLI harness, aktuální
ADAPTER dokumentace, tento přidávací záznam a vlastní COVERAGE řádek. Žádné wire/schema změny,
C1/common/Contracts/PLAN změny, systémové zásahy, síť, capture ani pf. C3 zůstává partial;
S3b/NET-10…12 a F1 agregát beze změny. Finální commit čeká na opětovné nezávislé review;
tato sekce popisuje ověření oprav implementátorem, nikoli výsledek tohoto dalšího review.

## Navazující explicitní network provenance consumer

Nový samostatný [validační index](NETWORK-ADAPTER-VALIDATION.md) připíná source commit
`926e106f24f1366af103544b546ad10db58efdf0`: 60 Release testů, 30 nových + 25 legacy offline
CLI kontrol a přesné bytes 61 souborů z 9 skutečných producer případů. Předchozí validace
výše zůstávají historickými důkazy svých původních revizí; S3b/NET-10…12 zůstávají Neověřeno.

Samostatný [dodatek nezávislého review](NETWORK-ADAPTER-VALIDATION.md#opravy-nezávislého-review--source-608b41c) připíná opravený source `608b41cc308ffa6d6fb530f24bc3a899537e0411`: 63 Release testů, 30 + 25 offline CLI a čtyři přesné review regrese. Předchozí měření a manifesty se nepřepisují.
