# `proto/export` — řízený export (WP1.H5, prototyp)

Izolovaný prototyp proudu H: data z oblasti ven jen řízeným exportem (PLAN F0.3, R5/R6 odloženo
do F3/F4). Balík **není** součást MVP, nesestavuje se do běžícího celku a **nedokazuje žádnou bránu**.
Ve F2 ho převezme WP2.11 a znovu ověří proti prošlým branám.

- Bez externích závislostí, žádné `.package(path:)`, Swift 6 / tools 6.0, `.macOS(.v15)`.
- Testy běží na vlastních dočasných stromech pod `/private/tmp/h5-export-*` a mažou jen svoje stromy.
- Neexistuje žádná root operace, žádný zápis mimo předaný cílový strom.

## Co prototyp dělá

| Fáze | Rozhraní | Chování |
|---|---|---|
| 1. selekce | `ExportPreparer` | Explicitní seznam relativních cest. Žádný průchod adresářem: co není vyjmenované, se neexportuje. |
| 2. preview | `ExportPlan` | Strukturovaný popis (cesta, velikost, mode, rozhodnutí, důvod). **Nikdy nezapisuje.** |
| 3. kopie | `ExportCopier` | `openat` + `O_NOFOLLOW` + `fstat` na fd, kontrola proti snapshotu z preview, nový cílový strom. |
| 4. karanténa | `QuarantineWriter` | `com.apple.quarantine` na fd výsledku, hned ověřená; selhání = **chyba**, žádný fallback. |
| 5. audit | `AuditSink` | Deterministický JSON, stabilní pořadí (fáze → `sequence` → UTF-8 bajty cesty). |

### Pravidla selekce (odmítnutí)

| `reason` | Kdy |
|---|---|
| `outsideRoot` | absolutní cesta nebo komponenta `..`; mimo kořen se nesahe |
| `invalidPath` | prázdná cesta nebo NUL bajt |
| `symlink` | cíl **nebo kterákoli komponenta** je symbolický odkaz |
| `hardlink` | `st_nlink > 1` — data nejsou jen v oblasti |
| `specialFile` | FIFO, socket, znakové nebo blokové zařízení |
| `notRegularFile` | adresář nebo jiný než regulérní soubor |
| `missing` | cesta neexistuje |
| `ioError` | práva nebo neklasifikovaný `errno` |

Typ souboru se zjišťuje `fstatat(AT_SYMLINK_NOFOLLOW)` **před** otevřením, takže FIFO nebo
zařízení se vůbec neotevře. Kopie navíc otevírá s `O_NOFOLLOW | O_NONBLOCK | O_NOCTTY`.

### TOCTOU

Preview uloží `device`, `inode`, `size`, `nlink` z `fstat`/`fstatat`. Kopie soubor znovu otevře
(`openat` relativně k fd rodiče, každá komponenta `O_NOFOLLOW`) a porovná `fstat` na fd:

- jiný `dev`/`inode`/`size`/`nlink` proti preview → `identityMismatch`, nic se nezkopíruje,
- soubor už nejde bezpečně otevřít (zmizel, přibyl mu hardlink, změnil se typ) →
  `sourceUnavailable` s důvodem ze selekce,
- jiný stav po dokončení kopie → `identityMismatch`,
- zapsaných bajtů méně než `size` → `identityMismatch`.

Cílový soubor vzniká `O_CREAT | O_EXCL`, takže existující cíl se nikdy nepřepíše. Cílový kořen
musí být **nový** adresář; existující cíl je `destinationExists` (i symbolický odkaz).

### Co prototyp nedělá

- Nekopíruje ACL, vlastníka, časové značky ani jiné xattr než karanténu. Práva (`mode & 0o7777`)
  se nastavují `fchmod` z `mode & 0o777` — setuid/setgid/sticky se na výsledek nepřenáší,
  aby export nevyráběl privilegovaný soubor.
- Neuklízí částečný cílový strom po chybě — volající ho smaže sám, protože je to jeho nový adresář.
- Neumí vybrat soubor, který se v průběhu kopie mění (to je záměrně chyba, ne částečná kopie).
- Neumí adresářový export ani rekurzi; strom se skládá z explicitních cest.
- Neobsahuje čas v auditu. Formát auditu z WP1.H1 ještě neexistuje, proto je zde **provizorní
  lokální záznam** za protokolem `AuditSink` (`sanjbox.export.audit.v0`). **Konsolidace s formátem
  auditu z H1 je navazující krok** (stejně jako napojení na manifest stavu z H3/H2).

## CLI `sanjbox-export`

```
sanjbox-export --root <dir> --file <relative path> [--file ...]
               [--dest <dir>] [--apply] [--audit <file>] [--dry-run] [--help]
```

`--dry-run` je **výchozí** režim; `--apply` ho vypne. Oba příznaky zároveň jsou chyba.
`--dest` je povinný jen s `--apply`. `--audit <file>` zapíše auditní JSON a **nikdy nepřepíše
existující soubor**.

Standardní výstup: JSON plánu (dry-run) a JSON výsledku (apply). Standardní chyba: důvod odmítnutí
nebo selhání.

| Exit | Význam |
|---|---|
| `0` | plán je čistý; u `--apply` všechny soubory zkopírované a zkaranténěné |
| `1` | I/O chyba, `identityMismatch`/`sourceUnavailable` (TOCTOU), `destinationExists`, karanténu nelze nastavit nebo ověřit |
| `2` | chybná příkazová řádka (neznámý přepínač, chybějící `--root`/`--file`, `--apply` bez `--dest`) |
| `3` | selekce odmítla aspoň jednu cestu; `--apply` se v takovém případě **neprovede vůbec** |

Příklad (dry-run nic nezapíše):

```bash
sanjbox-export --root /private/tmp/demo/root --file notes/a.txt --file notes/link.txt
```

## Veřejné rozhraní

```swift
// selekce + preview
ExportPreparer(rootPath: String)
  .prepare(relativePaths: [String]) throws -> ExportPlan
  .prepare(relativePaths: [String], audit: (any AuditSink)?) throws -> ExportPlan

ExportPlan     // root, candidates, accepted/rejected, isClean, rejectedPaths, jsonData()/jsonString()
Candidate      // relativePath, accepted, reason, detail, snapshot
SelectionReason, PathParseError, RelativePath, FileSnapshot, FileKind

// kopie + karanténa
ExportCopier(configuration: Configuration)   // quarantineValue, quarantineWriter, bufferSize
  .apply(_:destinationRoot:) throws -> ExportResult
  .apply(_:destinationRoot:audit:) throws -> ExportResult

ExportResult, CopiedFile
Quarantine (xattrName, defaultValue, read(fileDescriptor:))
QuarantineWriter (protocol: writeQuarantine/verifyQuarantine), SystemQuarantineWriter
QuarantineWriteError

// audit
AuditSink (protocol: append(_:)), RecordingAuditSink (records, document(), documentString())
AuditRecord, AuditPhase, AuditDecision, ExportAudit.scheme/.document(records:)

// chyby a CLI
ExportError                                              // Equatable, fail-closed
ExportCLI().run(arguments:stdout:stderr:) -> Int32       // knihovní runner, exit kódy výše
ExportArgumentParser.parse([String]) throws -> ExportArguments
ExportExitCode (ok=0, failure=1, usage=2, policyRejection=3)
```

`quarantineWriter` je jediná mockovatelná systémová operace; testy ji v dvou případech nahrazují
**mockem**, který zápis nebo ověření odmítne, a ověřují, že export skončí chybou.

## Testy

`swift test --package-path proto/export -c release`. Čtyřicet čtyři testů ve čtyřech sadách
(`SelectionTests`, `CopyTests`, `AuditTests`, `CLITests`) pokrývá:

- odmítnutí symlinku (cíl i komponenta), hardlinku (`nlink=2`), cesty mimo kořen, prázdné cesty,
  chybějící cesty, adresáře a FIFO,
- preview nic nezapíše (srovnání struktury i obsahu stromu před/po),
- kopie zachová bajty, práva a `nlink=1`, nastaví a **ověří** karanténu, zdroj zůstane bez karantény,
- odmítnutí existujícího cíle a odmítnutí celého apply, když plán není čistý,
- TOCTOU: výměna inode (přejmenováním souběžně existujícího souboru), změna velikosti, nově vzniklý
  hardlink a zmizení souboru mezi preview a kopií, včetně tvrzení, že se vyměněný soubor nezkopíroval,
- `setuid`/`setgid` se na výsledek nepřenáší a `bytesCopied` sedí na velikost,
- audit je bajtově identický napříč běhy a nezávislý na pořadí argumentů,
- CLI: dry-run nic nezapíše, exit 0/1/2/3, `--audit` nepřepíše existující soubor.

## Omezení a navazující kroky

1. Konsolidace auditu s formátem z WP1.H1 (a napojení na manifest z H2/H3) — samostatný balík.
2. WP2.11: skutečné systémové operace (skutečný zdroj v oblasti, ACL, vlastník, časové značky),
   kontrola proti reálné politice exportu a běh pod UID oblasti.
3. Prototyp neprokazuje, že export z oblasti nemůže obejít politiku: to je otázka WP1.H6 a akceptace S0.
