# WP1.H6 — syntetický harness únikových testů

Izolovaný Swift 6 prototyp bez externích balíčků. Obsahuje katalog **všech 155 akceptačních ID**
z [COVERAGE §3](../../docs/COVERAGE.md#3-testové-případy), osm automatických syntetických sond a
runner nad vlastními dočasnými stromy a skutečným procesem `sanjbox-counterpart` z WP0.4.
H1 dodává lifecycle, dekodéry a audit; WP0.3 dodává kontrolu kontextu a syntetické kanárky.

**Žádná akceptace ani brána tím neprochází.** Všechny výsledky mají
`acceptanceStatus: "unverified"`. Stejný uživatel může přečíst všechny fixtures mimo mock hranici;
pozitivní kontroly toho záměrně využívají. Žádný kód nezakládá skutečnou oblast ani nemění UID,
pf, TCC, launchd, systémová práva, svazky nebo účty.

## Katalog a rozsah

[Strojově čitelný katalog](Sources/SanjboxEscape/Resources/catalog.json) obsahuje u každého ID:
`title`, `requirements`, `gate`, `mode`, konkrétní `step`, `oracle`, `reference`, `limitation`
a u syntetického případu také `probe`. `step` popisuje cílový laboratorní postup nebo vymezenou
fixture; jeho přítomnost **neznamená oprávnění jej vykonat**. Runner vykonává pouze osm pevných
sond níže, nikdy nespouští text katalogu. Ruční kroky vyžadují samostatný příslušný lab workflow,
jeho závislosti, kontroly a uživatelské kroky podle GUIDE/PLAN; katalog je nenahrazuje.

| ID | Automatická sonda / oracle v H6 | Chybějící reálný důkaz |
|---|---|---|
| FS-01 | Vlastní kanárky `zone`/`host-home`; mock odmítne cizí root, přímé vlastní kontroly jej přečtou. | Ochrana skutečného host home a oddělení UID. |
| FS-07 | Vlastní hardlink na vlastní kanárek; descriptor kontrola odmítne více odkazů. | Zákaz tvorby/zneužití odkazu přes skutečnou bezpečnostní hranici. |
| FS-08 | Vlastní symlink na vlastní kanárek; `openat` + `O_NOFOLLOW` odmítne odkaz, běžný soubor funguje. | Produkční helper, celý root resolver, konkurence/TOCTOU. |
| LC-06 | H1 odmítne start ve `stopping` i `stopped`, stav/identita se nezmění. | Průběžný admission interlock a procesy celého UID. |
| LC-11 | H1 drží návrhové UID do `cleaned`, předčasné přiřazení odmítá. | Globální alokátor mezi oblastmi a skutečný úklid/reboot. |
| NET-02 | Mock gate nepustí send; samostatný receiver nemá kontakt ani bajty, před/po kontrola kanárka přijme. | Síťová izolace host localhostu, skutečná peer identita. |
| NET-12 | Povolená loopback fixture doručí přesný kanárek a bajty nezávislému procesu protistrany. | Rozlišení same-zone od hosta/jiné oblasti, IPv6, ingress policy. |
| SG-09 | H1 validní helper/broker controls a osm malformed/oversize/unknown-field/kind/ID fixtures. | Živý XPC transport, autentizace, fuzz coverage a Mach práva. |

Zbytek je **133 `manual` + 14 `unsupported`**. Unsupported zde znamená, že H6 nemá vhodný adaptér
(proxy drag/drop a print/audio, ICMP, AirDrop/APNs a deset Docker případů), nikoli rozhodnutí,
že je budoucí produkt nikdy nebude podporovat. Každý má přesto konkrétní krok a oracle.

## Spuštění [implementátor]

Z kořene repozitáře:

```sh
swift build --package-path spikes/common -c debug --product sanjbox-counterpart
swift build --package-path proto/escape -c debug
swift run --package-path proto/escape sanjbox-escape plan
```

Bez argumentů je rovněž `plan`: vypíše pouze katalog, nic nevytvoří a neotevře socket.
`run` vyžaduje výslovné `--apply`; používá pouze nově vytvořený soukromý adresář
`/private/tmp/sanjbox-h6-XXXXXX` a loopback. Cestu ke skutečnému, důvěryhodnému produktu WP0.4
získáš příkazem `--show-bin-path`; nespouštěj místo něj cizí binárku.

```sh
h6_counterpart_dir="$(swift build --package-path spikes/common -c debug --show-bin-path)"
swift run --package-path proto/escape sanjbox-escape run --apply \
  --counterpart "$h6_counterpart_dir/sanjbox-counterpart"
```

Úspěšné provedení osmi sond vrací **exit 3**, protože úplný katalog stále obsahuje neprovedené
případy. JSON na stdout uvádí `summary: "incomplete"`, počty po stavech a všech 155 výsledků.

| Exit / stav | Význam |
|---|---|
| `0` u `plan` | Katalog byl vypsán; není to test. |
| `1` u `run` | Alespoň jedna úplná syntetická sonda prokázala nesplnění svého oracle. |
| `2` | Chyba CLI nebo nezvládnutá infrastruktura. |
| `3` u `run` | Ruční/nepodporované/neúplné případy nebo nepotvrzený úklid. |
| `syntheticPassed` | Pouze úplná vyhodnocená fixture s platnou identitou a pozitivní kontrolou. |
| `syntheticFailed` | Úplná fixture nesplnila oracle. |
| `incomplete` | Chybí pokus, shodná identita, kontrola, úplné pozorování nebo doběhnutí. |
| `manualRequired` / `unsupported` | Nikdy se nezmění na pass ani při předané „úspěšné“ observation. |

H6 nemá import externích verdiktů ani API pro změnu COVERAGE. Souhrn se odvozuje z jednotlivých
stavů; úspěšné mocky nemohou zakrýt neprovedené řádky. Neplatný/neúplný receiver log zůstává
neúplným měřením i při diagnostických bajtech; ty se z výstupu neztrácejí.

## Identita, síť a audit

Před vytvořením fixtures a znovu před každou sondou se používají `ProbeContext.capture` a
`ProbeExpectation.mismatches`. Očekávání se připne před pokusem k původnímu stejnému uživateli:
real/effective UID/GID, kernel groups a autoritativní členství, audit session, launchd manager a
existující window session. Root/set-ID kontext, drift i nerozpoznaný audit/bootstrap znamenají
neúplnost, žádný automatický pass. Headless kontext bez window session je přípustný pouze pokud
byl už v baseline; **GUI-11 zůstává ruční**, nevydáváme tím důkaz cílové relace oblasti.
Baseline zjišťuje identitu volajícího, nikoli členství v registru skutečných oblastí; runner se
spouští jako běžný implementátor a neprovádí přepnutí ani autorizaci identity oblasti.
Podproces protistrany dědí identitu; executable nesmí být symlink ani mít set-ID bity.

Protistrana se vždy spouští s `--bind 127.0.0.1 --tcp 0`, bez UDP/wildcard/DNS/externí sítě.
Každý receiver má nový log, raw adresář a registry kanárka. Readiness se přijme jen pro přesně
jeden skutečný loopback TCP port. NET-02 má tři oddělené běhy: povolenou kontrolu, zamítnutý pokus,
povolenou kontrolu; kontrolní bajty nemohou kontaminovat zamítnutý běh. NET-12 má čtvrtý běh.

Po pokusu následuje předem pevně daných 100 ms ustálení, SIGTERM a bounded wait. `report` skutečně
vyhodnocuje log WP0.4; H6 kontroluje shodu exit kódu s úplností/kontaktem a u pozitivní cesty také
počet spojení, přesné bajty, registrovaný kanárek a raw obsah. Readiness/stop/report mají limit
5 s; lokální connect/send po 1 s. Vypršení limitu nebo selhání procesu je neúplnost. Po timeoutu
se ukončuje pouze vlastní potomek. Tyto krátké syntetické intervaly nejsou laboratorní metodika.

Výstup obsahuje úplné JSONL události a raw payloady vlastní protistrany, její report a case
observations. `auditJSON` je přímo výsledek **H1 `AuditLog.encode`**, nikoli jiné audit schéma.
Používá pouze skutečně modelované `zone.created`, `gate.request.denied` a `zone.cleaned`, se
sekvencí od 1, zone `h6zz` a skutečným actor UID. Detail vždy říká, že jde o fixture. H1 nemá
`escape.pass` ani obecné audit akce čtení souboru; jejich pozorování patří do case výsledků,
ne do vymyšlených H1 akcí. Audit není seznam laboratorních verdiktů.

## Úklid a omezení

Runner po převzetí výstupů ukončí vlastní potomky a odstraní pouze vlastní `mkdtemp` strom.
Před úklidem ověří typ, vlastníka a původní device/inode kořene; nahrazený kořen odmítne.
Úklid je idempotentní, vnitřní symlink neodstraňuje cíl. Výsledný JSON zachová syntetické kanárky
po odstranění fixtures; běžné testy neukládají laboratorní protokol a historické evidence nemění.
Pokud proces skončí SIGKILL nebo systém spadne, automatický úklid nemůže být garantovaný;
případný vlastní dočasný strom je potřeba zkontrolovat ručně. Není zde příkaz pro mazání cizí cesty.

Souborová bezpečnost a zápis reportu nejsou ochranou proti útočníkovi se stejným UID. Logy nejsou
autentizované ani durable laboratorní evidence. Receiver vidí aplikační TCP bajty, nikoli všechny
pakety; neověřuje ICMP, resolver, UDP/IPv6, pf nebo síťové failure modes. Celý výstup je příprava
pro WP2.8 až po příslušných branách. Nečte skutečné projekty, databáze, Klíčenku ani tajemství.

## Ověření

```sh
swift test --package-path proto/escape -c debug
swift test --package-path proto/escape -c release
```

Swift test target automaticky sestaví skutečný `sanjbox-counterpart` z lokálního `spikes/common`
ve vlastním novém scratch adresáři (stejná debug/release konfigurace), bez síťových závislostí.
Cílené integrační testy tedy běží i ve stávající CI matici; není nutný opt-in ani předem připravená
binárka. Změny H1/common vybírají tento balík přes existující lokální package dependencies.
Testy připínají **všech 155 ID samostatným literálem**, porovnávají s ním katalog i aktuální
COVERAGE §3 a kontrolují titul/požadavky/bránu. Odstranění stejného ID z katalogu i COVERAGE
proto nemůže tiše projít. Další výsledky jsou v [VALIDATION.md](VALIDATION.md).

## Předání do WP2.8

H6 je po review úplného katalogu, runneru a testů v #76 dokončený offline balík. Větev přebírá
sloučené H3 `e21c31d`; H6 nadále přímo používá H1/common, nepřidává runtime závislost na H2/H3.
Bez konkrétního nového nálezu se katalog ani mock sondy dále nerozšiřují. Aktuální práce a
původní vlastníci H4/A2/A3/A6 jsou v [IMPLEMENTATION §0](../../docs/IMPLEMENTATION.md#0-co-dál).

Po splnění vstupu F2 převezme WP2.8 katalog a konzervativní vyhodnocení; samostatně musí dodat:

1. Nativní adaptéry a běh pod předem určenou skutečnou identitou oblasti, s ověřením credentials
   před každou CLI/GUI sondou ve třech souběžných oblastech. Dnešní same-user baseline tuto roli nemá.
2. Pro každý podporovaný případ reálný pokus, pozitivní/negativní kontrolu a úplný oracle;
   ruční/nepodporované položky zůstávají explicitní. H3 `accepted` ani H1 model nedokazují OS efekt.
3. Nezávislé měření síťových cest a failure modes podle S3/S3b/S5; TCP loopback a pevný 100ms
   interval dnešních fixtures nenahrazují capture, IPv6/UDP/resolver ani post-revocation důkaz.
4. Předregistrované lab běhy, H1 audit, zachované raw, ověřený úklid a nezávislé review podle
   GUIDE/LAB. Protokol přijme skutečný výsledek; `syntheticPassed` nikdy nepovýší na akceptační pass.

Všechny brány a 155 případů zůstávají Neověřeno. H6 nedává oprávnění k systémovým změnám,
registraci účtů/podpisů/TCC, odemčení D5/G2 ani spojení prototypů do běžící oblasti před F2.
