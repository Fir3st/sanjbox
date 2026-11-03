# spikes/common — společná sada sond (WP0.3)

Swift balík `SanjboxProbeKit`, na kterém stojí všechny sondy Sanďboxu. Bez externích závislostí.

| Část | K čemu |
|---|---|
| `sanjbox-whoami` | Zjistí, pod jakou identitou a v jaké relaci proces skutečně běží, a s `--expect` rozhodne, zda je měření platné |
| `sanjbox-canary` | Vytváří syntetické kanárky, hledá je v zachycených datech a uklízí je |
| `ProbeContext` | Skutečné/efektivní UID a GID, skupiny (autoritativně přes `mbr_check_membership`), audit session, launchd doména (`launchctl managername`/`manageruid`), relace window serveru |
| `ProbeExpectation` | Očekávání sepsané **před** během (GUIDE §7); co nejde ověřit, je neshoda, ne pass |
| `RunRecord` + `JSONLines` | Formát protokolu běhu: jeden JSON na řádek, časy ISO 8601 s milisekundami |
| `ProbeArguments`, `ProbeExit` | Parser argumentů a společné návratové kódy pro všechny sondy |

Pokrývá případ GUI-11 (credentials sond odpovídají očekávání). Sondy dalších bran ho používají
jako první krok měření.

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

## Návratové kódy

| Kód | Význam |
|---|---|
| 0 | V pořádku; `scan` nic nenašel |
| 1 | `scan` našel kanárka |
| 2 | Chyba použití nebo I/O |
| 3 | Neplatné měření: identita nebo relace neodpovídá očekávání, běh je nutné opakovat |
| 4 | `cleanup` něco odmítl smazat; zkontroluj ručně |

## Bezpečnost

Sada dodržuje GUIDE §3: nástroje pracují jen se syntetickými kanárky a metadaty vlastního
procesu. Nic nečtou z chráněných kořenů kromě souborů, které samy vytvořily, a nepotřebují root.
