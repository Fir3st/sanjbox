# spikes/common — společná sada sond a protistrana (WP0.3, WP0.4)

Swift balík `SanjboxProbeKit`, na kterém stojí všechny sondy Sanďboxu, a nezávislá protistrana
pro síťové testy. Bez externích závislostí.

| Část | K čemu |
|---|---|
| `sanjbox-whoami` | Zjistí, pod jakou identitou a v jaké relaci proces skutečně běží, a s `--expect` rozhodne, zda je měření platné |
| `sanjbox-canary` | Vytváří syntetické kanárky, hledá je v zachycených datech a uklízí je |
| `sanjbox-counterpart` | Nezávislá protistrana (WP0.4): přijímá na TCP/UDP portech řízeného hosta a zaznamenává každé spojení, datagram, bajty a kanárky |
| `ProbeContext` | Skutečné/efektivní UID a GID, skupiny (autoritativně přes `mbr_check_membership`), audit session, launchd doména (`launchctl managername`/`manageruid`), relace window serveru |
| `ProbeExpectation` | Očekávání sepsané **před** během (GUIDE §7); co nejde ověřit, je neshoda, ne pass |
| `RunRecord` + `JSONLines` | Formát protokolu běhu: jeden JSON na řádek, časy ISO 8601 s milisekundami |
| `CanaryScanner`, `CanaryStreamScanner` | Hledání kanárků v datech a v proudu po částech (token rozdělený mezi části se najde) |
| `ProbeArguments`, `ProbeExit` | Parser argumentů a společné návratové kódy pro všechny sondy |

Pokrývá případ GUI-11 (credentials sond odpovídají očekávání). Sondy dalších bran ho používají
jako první krok měření.

`ProbeContext.capture()` omezuje každý pevný dotaz `launchctl managername` / `manageruid` na
2 s monotónního času po spuštění a 8192 B stdout; úklid vlastního potomka má další dvě okna po 200 ms.
Chyba, timeout, neúspěšný exit nebo neplatná odpověď znamená `launchdManager == nil`.
Kolektor vyžaduje výchozí `SIGCHLD` bez automatického reapování a bez konkurenčního reaperu;
při nevyhovujícím zděděném handleru dotaz odmítne. Celé `capture()` časový limit nemá, protože
ostatní systémová API zůstávají synchronní. Podrobnosti a ověření: [VALIDATION-CONTEXT-BOUNDS.md](VALIDATION-CONTEXT-BOUNDS.md).

## Sestavení a testy

```bash
swift build
```

```bash
swift test
```

Binárky leží ve složce, kterou vypíše `swift build --show-bin-path`.

## sanjbox-whoami

```
sanjbox-whoami [--expect FILE] [--log FILE] [--case ID]
```

Vypíše JSON `{context, mismatches, valid}`. Bez `--expect` je `valid` `null` (kontext se jen zaznamená).

Příklad očekávání pro sondu v oblasti (hodnoty určí běh S1, tady jsou jen ilustrační):

```json
{
  "effectiveUID": 450,
  "realUID": 450,
  "requiredGroups": [701],
  "forbiddenGroups": [20, 80],
  "launchdManagerName": "Aqua",
  "launchdManagerUID": 450,
  "windowSessionUID": 450,
  "onConsole": false,
  "forbiddenAuditSessionIDs": [100015]
}
```

- `effectiveUID` je povinné, prázdné očekávání nikdy nic nepotvrdí.
- `forbiddenGroups` 20 = `staff`, 80 = `admin`.
- `forbiddenAuditSessionIDs` obsahuje audit session host konzole: zjistíš ji spuštěním `sanjbox-whoami`
  bez parametrů ve své relaci (`context.audit.sessionID`).
- Členství, které nejde rozhodnout, chybějící relace nebo audit session = neshoda.

## sanjbox-canary

```
sanjbox-canary create  --label LABEL --dir DIR --registry FILE
sanjbox-canary scan    --registry FILE [INPUT ...]
sanjbox-canary cleanup --registry FILE
```

- **create** zapíše `DIR/sanjbox-canary-LABEL.txt` s tokenem `SANJBOX-CANARY-<label>-<32 hex>` a přidá
  záznam do registru. Nepřepíše existující soubor a nenásleduje symlink. Soubor má záměrně běžná práva
  `0644`: test musí ukázat, že ho nečitelným dělá chráněný kořen, ne práva souboru.
- **scan** hledá tokeny z registru v souborech (bez vstupu čte stdin). Najde je v syrové podobě i jako
  hex v libovolné velikosti písmen, tedy i v DNS labelu. Jiná kódování (base64, komprese) nehledá.
- **cleanup** smaže jen soubor, který je stále běžným souborem, patří volajícímu a obsahuje přesně svůj token.
  Chybějící soubor bere jako smazaný, takže úklid lze pouštět opakovaně.

## sanjbox-counterpart

```
sanjbox-counterpart listen --log FILE --raw DIR [--tcp PORTS] [--udp PORTS] [--bind ADDR] [--registry FILE]
sanjbox-counterpart report --log FILE
```

Oracle pro S3, S3b, S5 a S7: zaznamenává, co skutečně dorazilo na druhou stranu hranice. Na pf, bráně
ani hlídači nezávisí; s kandidátem sdílí jen formát kanárků a protokolu. Spouští se na **řízeném hostu**
podle případu: jiný stroj v LAN (NET-01), tvoje relace na `127.0.0.1` (NET-02), uživatel jiné oblasti
(NET-03), veřejný server pod tvou kontrolou (nepovolená doména, raw IP).

- **listen** naváže všechny listenery, vypíše je jako JSON (port `0` = volný port) a zapíše událost `started`.
  Pak zapisuje do logu:
  - `accepted` hned po přijetí TCP spojení, ještě před prvním bajtem;
  - `closed` s počtem bajtů, kanárky a důvodem konce;
  - `datagram` pro každý UDP datagram.
- **Zastavení** (`SIGINT`/`SIGTERM`) dočte, co už jádro přijalo, uzavře všechny toky a zapíše `stopped`.
  Spojení, která jádro dokončilo, ale ještě nebyla přijata, se také zaznamenají.
- **Log a raw adresář** musí být nové (adresář smí být prázdný). Jeden log tak vždy popisuje právě jeden běh.
- **Surová data** každého toku jdou do `DIR/<tok>-<tcp|udp>-<port>.bin`, nejvýš 1 MiB na tok. Počty bajtů
  a hledání kanárků pokrývají i zbytek.
- **Kanárky** se hledají v syrové podobě i jako hex. Registrované se hlásí tokenem, jakýkoli jiný prefixem
  `SANJBOX-CANARY-`. Kanárek vytvořený po startu tedy nezapadne.
- **DNS:** v UDP dotazech se navíc spojí labely jména (`dns-qname-hex`). Hex kanárka rozdělený do více labelů
  se tak najde i při náhodné velikosti písmen (0x20).
- **Výchozí adresa** `::` přijímá IPv6 i IPv4. IPv4 zdroj se zapíše jako `::ffff:a.b.c.d`.
- **Porty pod 1024** (např. 53 pro autoritativní DNS) vyžadují root; spouští je uživatel.

**report** spočítá výsledek jen z logu a vrátí:

| Kód | Význam |
|---|---|
| 0 | Úplný běh, nic nepřišlo |
| 1 | Něco přišlo; i TCP spojení bez jediného bajtu je kontakt |
| 3 | Neúplný log: chybí `started`/`stopped`, více běhů nebo nezavřený tok. Protistrana možná neposlouchala, takže měření je neplatné. |
| 2 | Chyba použití nebo čtení logu |

Postup jednoho negativního případu:

1. Spusť `listen`.
2. **Kontrolní cestou** ověř, že protistrana poslouchá a kanárka zaznamená, např. z místa, odkud je spojení
   povolené: `printf TOKEN | nc HOST PORT`. Bez toho je nula bajtů neplatné měření, ne důkaz.
3. Proveď testovaný pokus z oblasti.
4. **Počkej dobu ustálení** stanovenou předem v `inputs.md`. Tok, který je v okamžiku zastavení
   ještě na cestě, se nezaznamená.
5. Zastav protistranu `SIGTERM`.
6. Spusť `report`.

Kontrolní tok se v reportu objeví. Proto je kontrolní a testovaný běh oddělený, nebo verdikt posuzuje toky
podle `remote` a času v logu.

Co protistrana nevidí, a čím to doplnit:

- Vidí jen to, co dostane aplikační vrstva. ICMP (NET-17), zahozené handshaky a pakety mimo její porty
  zachytí `tcpdump -w` na řízeném hostu; `sanjbox-canary scan` pak prohledá i pcap soubor (kanárka v rámci jednoho paketu).
- TLS neterminuje. U šifrovaného provozu dokládá bajty a kontakt, kanárka jen v nešifrovaných datech.
- DNS přes TCP a mDNS (multicast) neparsuje; syrový obsah se prohledává.
- U UDP zapisuje jako `local` adresu listeneru, ne cílovou adresu datagramu.

## Návratové kódy

| Kód | Význam |
|---|---|
| 0 | V pořádku; `scan` nic nenašel; `report`: úplný běh bez kontaktu |
| 1 | `scan` našel kanárka; `report`: protistrana něco přijala |
| 2 | Chyba použití nebo I/O |
| 3 | Neplatné měření: identita nebo relace neodpovídá očekávání, nebo log protistrany je neúplný; běh je nutné opakovat |
| 4 | `cleanup` něco odmítl smazat; zkontroluj ručně |

## Bezpečnost

Sada dodržuje GUIDE §3: nástroje pracují jen se syntetickými kanárky a metadaty vlastního
procesu. Nic nečtou z chráněných kořenů kromě souborů, které samy vytvořily, a nepotřebují root.
Protistrana ukládá vše, co na její porty přijde. Spouštěj ji jen na portech a hostech vyhrazených pro test
a před commitem do `docs/evidence` zkontroluj, že `raw/` obsahuje jen testovací data.

## Opt-in network provenance

Nový oddělený `provenance` režim counterpartu: [C1/common formát, preflight a bounded receiver](../s3-pf/NETWORK-PROVENANCE.md). Legacy `listen/report` a jejich wire zůstávají beze změny.
