# `proto/export` — řízený export (WP1.H5, prototyp)

Izolovaný prototyp proudu H: data z oblasti ven jen řízeným exportem (PLAN F0.3, R2/R7;
odklad R4/R6 do F3/F4 podle `docs/IMPLEMENTATION.md` §1.3). Balík **není** součást MVP,
nesestavuje se do běžícího celku a **nedokazuje žádnou bránu**. Ve F2 ho převezme WP2.11
a znovu ověří proti prošlým branám.

- Bez externích závislostí, žádné `.package(path:)`, Swift 6 / tools 6.0, `.macOS(.v15)`.
- SHA-256 používá systémový `CryptoKit`; žádná externí knihovna.
- Testy běží na vlastních dočasných stromech pod `/private/tmp/h5-export-*` a mažou jen svoje stromy.
- Neexistuje žádná root operace, žádný zápis mimo předaný cílový strom.

## Co prototyp dělá

| Fáze | Rozhraní | Chování |
|---|---|---|
| 1. selekce | `ExportPreparer` | Explicitní seznam relativních cest. Žádný průchod adresářem: co není vyjmenované, se neexportuje. Stejná identita `(dev, inode)` se sloučí; kolize cílových jmen se odmítne. |
| 2. preview | `ExportPlan` | Strukturovaný popis (cesta, velikost, SHA-256, mode, rozhodnutí, důvod). **Nikdy nezapisuje.** |
| 3. kopie | `ExportCopier` | `openat` + `O_NOFOLLOW` + `fstat` na fd, kontrola metadat i SHA-256 proti preview, nový cílový strom. |
| 4. karanténa | `QuarantineWriter` | `com.apple.quarantine` na fd **prázdného** výsledku hned po `O_CREAT|O_EXCL`, pak zápis obsahu, na konci jen re-verify. Selhání = **chyba**, žádný fallback. |
| 5. audit | `FileAuditSink` / `RecordingAuditSink` | Append-only JSON Lines: jeden záznam na řádek, `fsync` po každém. Přežije pád uprostřed kopie. |

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
| `ioError` | práva, neklasifikovaný `errno`, nebo zdroj nelze přečíst kvůli hashi |
| `destinationCollision` | dvě různé identity mají stejné cílové jméno (case/Unicode kolize) |

Typ souboru se zjišťuje `fstatat(AT_SYMLINK_NOFOLLOW)` **před** otevřením, takže FIFO nebo
zařízení se vůbec neotevře. Kopie navíc otevírá s `O_NOFOLLOW | O_NONBLOCK | O_NOCTTY`.
Meziadresář se po `openat` znovu ověří `fstat`: `dev`/`inode` otevřeného fd musí být stejné
jako inode klasifikovaný `fstatat`, jinak export skončí chybou.

### TOCTOU a identita obsahu

Preview uloží `device`, `inode`, `size`, `nlink`, `mode` a **SHA-256 obsahu**. Kopie soubor znovu
otevře (`openat` relativně k fd rodiče, každá komponenta `O_NOFOLLOW`) a porovná `fstat` na fd:

- jiný `dev`/`inode`/`size`/`nlink` proti preview → `identityMismatch`, nic se nezkopíruje,
- soubor už nejde bezpečně otevřít (zmizel, přibyl mu hardlink, změnil se typ) →
  `sourceUnavailable` s důvodem ze selekce,
- kopie počítá SHA-256 průběžně při čtení; jiný hash nebo počet bajtů než v preview →
  `identityMismatch`, částečný cíl se odstraní,
- jiný stav po dokončení kopie → `identityMismatch`.

Tím se zachytí i přepis na místě se stejnou velikostí a stejným inode. Preview proto musí zdroj
skutečně přečíst: soubor bez práva čtení se odmítne už v preview jako `ioError`.

### Duplicity a kolize cílových jmen

`CI.txt` a `ci.txt` mohou být na case-insensitive APFS stejný inode, stejně jako NFC a NFD zápis
téhož jména. Preview proto:

1. sloučí přijaté kandidáty se stejnou identitou `(dev, inode)`; ponechá první cestu v UTF-8
   pořadí, takže výsledek nezávisí na pořadí argumentů ani na jejich bajtech,
2. odmítne skutečné kolize **různých** identit podle cílového jména: case-insensitive
   (`lowercased`) + Unicode NFC normalizace. Odmítnou se všechny kolidující cesty s
   `destinationCollision`, takže `isClean == false` a apply se vůbec nespustí.

Cílový soubor vzniká `O_CREAT | O_EXCL`, takže existující cíl se nikdy nepřepíše. Cílový kořen
musí být **nový** adresář; existující cíl je `destinationExists` (i symbolický odkaz).
Cílový kořen nesmí ležet uvnitř zdrojového kořene (`destinationInsideRoot`): export by zapisoval
do právě exportovaného stromu. CLI tento případ odmítne jako chybu příkazové řádky (exit 2).

### Co prototyp nedělá

- Nekopíruje ACL, vlastníka, časové značky ani jiné xattr než karanténu. Práva (`mode & 0o7777`)
  se nastavují `fchmod` z `mode & 0o777` — setuid/setgid/sticky se na výsledek nepřenáší,
  aby export nevyráběl privilegovaný soubor.
- Neuklízí částečný cílový **strom** po chybě — volající ho smaže sám, protože je to jeho nový
  adresář. Částečný **soubor** po selhání zápisu ale odstraní sám, aby v cíli nezůstal
  nekaranténovaný částečný soubor.
- Neumí adresářový export ani rekurzi; strom se skládá z explicitních cest.
- Neobsahuje čas v auditu. Formát auditu z WP1.H1 ještě neexistuje, proto je zde **provizorní
  lokální záznam** (`sanjbox.export.audit.v0`, JSON Lines). **Konsolidace s formátem auditu
  z H1 je navazující krok** (stejně jako napojení na manifest stavu z H3/H2).

## CLI `sanjbox-export`

```
sanjbox-export --root <dir> --file <relative path> [--file ...]
               [--dest <dir>] [--apply] [--audit <file>] [--dry-run] [--help]
```

`--dry-run` je **výchozí** režim; `--apply` ho vypne. Oba příznaky zároveň jsou chyba.
`--dest` je povinný jen s `--apply` a nesmí ležet uvnitř `--root`.

Audit:

- s `--apply`: `--audit <file>` zapíše append-only JSON Lines, jeden záznam na řádek, `fsync`
  po každém záznamu. Soubor vzniká `O_CREAT | O_EXCL`, takže se **nikdy nepřepíše** existující
  soubor; chyba zápisu nese skutečné `errno` (např. `EISDIR`, `ENOENT`, `EEXIST`).
- bez `--apply` (dry-run): `--audit` **nikdy nezapisuje na disk**. Auditní dokument jde jen na
  standardní výstup za plán; žádný soubor nevznikne. Dry-run tak nemá žádný vedlejší účinek.

Standardní výstup: JSON plánu (dry-run) a JSON výsledku (apply); v dry-runu s `--audit` navíc
auditní dokument. Standardní chyba: důvod odmítnutí nebo selhání.

| Exit | Význam |
|---|---|
| `0` | plán je čistý; u `--apply` všechny soubory zkopírované a zkaranténěné |
| `1` | I/O chyba, `identityMismatch`/`sourceUnavailable` (TOCTOU), `destinationExists`, karanténu nelze nastavit nebo ověřit, audit nelze zapsat |
| `2` | chybná příkazová řádka (neznámý přepínač, chybějící `--root`/`--file`, `--apply` bez `--dest`, `--dest` uvnitř `--root`) |
| `3` | selekce odmítla aspoň jednu cestu; `--apply` se v takovém případě **neprovede vůbec** |

Příklad (dry-run nic nezapíše, ani auditní soubor):

```bash
sanjbox-export --root /private/tmp/demo/root --file notes/a.txt --file notes/link.txt \
               --audit /private/tmp/demo/audit.jsonl
```

## Veřejné rozhraní

```swift
// selekce + preview
ExportPreparer(rootPath: String)
  .prepare(relativePaths: [String]) throws -> ExportPlan
  .prepare(relativePaths: [String], audit: (any AuditSink)?) throws -> ExportPlan

ExportPlan     // root, candidates, accepted/rejected, isClean, isAuthorizedForCopy,
               // rejectedPaths, jsonData()/jsonString()
Candidate      // relativePath, accepted, reason, detail, snapshot
SelectionReason, PathParseError, RelativePath, FileKind
FileSnapshot   // device, inode, size, mode, linkCount, contentHash (hex SHA-256)
               // matchesMetadata(_:), matchesIdentity(_:) (včetně hashe)

// kopie + karanténa
ExportCopier(configuration: Configuration)   // quarantineValue, quarantineWriter,
                                             // contentWriter, bufferSize
  .apply(_:destinationRoot:) throws -> ExportResult
  .apply(_:destinationRoot:audit:) throws -> ExportResult

ExportResult, CopiedFile
ContentWriter (protocol: write(fileDescriptor:buffer:)), SystemContentWriter, POSIXWriteError
Quarantine (xattrName, defaultValue, read(fileDescriptor:))
QuarantineWriter (protocol: writeQuarantine/verifyQuarantine), SystemQuarantineWriter
QuarantineWriteError

// umístění cíle
ExportPathPolicy.canonicalPath(_:) -> String
ExportPathPolicy.isDestination(_:insideRoot:) -> Bool

// audit
AuditSink (protocol: append(_:))
FileAuditSink(path:)                        // append-only JSONL, O_EXCL, fsync
RecordingAuditSink (records, document(), documentString())
AuditRecord, AuditPhase, AuditDecision, ExportAudit.scheme/.line(for:)/.document(records:)

// chyby a CLI
ExportError                                              // Equatable, fail-closed
ExportCLI().run(arguments:stdout:stderr:) -> Int32       // knihovní runner, exit kódy výše
ExportArgumentParser.parse([String]) throws -> ExportArguments
ExportExitCode (ok=0, failure=1, usage=2, policyRejection=3)
```

Plán je pro kopii autorizovaný jen tehdy, když ho v tomto procesu vytvořil `ExportPreparer`.
JSON round-trip (`Codable`) autorizaci ztratí a `apply` ho odmítne jako `planNotPrepared`;
snapshoty z cizího souboru se nikdy nepřebírají důvěřivě.

`quarantineWriter` a `contentWriter` jsou jediné mockovatelné systémové operace. Testy je
nahrazují **mockem** jen pro injektované selhání (odmítnutý xattr, ENOSPC uprostřed zápisu),
ne pro mock celé kopie.

## Testy

`swift test --package-path proto/export -c release`. Šedesát testů ve čtyřech sadách
(`SelectionTests`, `CopyTests`, `AuditTests`, `CLITests`) pokrývá:

- odmítnutí symlinku (cíl i komponenta), hardlinku (`nlink=2`), cesty mimo kořen, prázdné cesty,
  chybějící cesty, adresáře a FIFO,
- preview nic nezapíše (srovnání struktury i obsahu stromu před/po) a nese SHA-256 obsahu,
- kopie zachová bajty, práva a `nlink=1`, nastaví a **ověří** karanténu, zdroj zůstane bez karantény,
- karanténa je na fd dřív než první bajt obsahu (probe zapisovač to ověří),
- odmítnutí existujícího cíle, cíle uvnitř kořene a odmítnutí celého apply, když plán není čistý,
- TOCTOU: výměna inode, změna velikosti, **stejně velký přepis na místě** (SHA-256), nově vzniklý
  hardlink a zmizení souboru mezi preview a kopií, včetně tvrzení, že se vyměněný soubor nezkopíroval,
- dedup podle identity pro case varianty i NFC/NFD a determinismus plánu i bajtů nezávisle na
  pořadí argumentů; odmítnutí case i Unicode kolize cílových jmen,
- guard `dev`/`inode` mezi klasifikací meziadresáře a jeho otevřením,
- JSON round-trip plánu se pro apply odmítne (`planNotPrepared`),
- injektované selhání zápisu uprostřed kopie: v cíli nezůstane nekaranténovaný částečný soubor
  a append-only audit existuje,
- `setuid`/`setgid` se na výsledek nepřenáší a `bytesCopied` sedí na velikost,
- audit je bajtově identický napříč běhy, nezávislý na pořadí argumentů a **neobsahuje absolutní
  cesty** ani v preview, ani v copy záznamech,
- CLI: dry-run nic nezapíše (ani `--audit`), exit 0/1/2/3, `--audit` nepřepíše existující soubor,
  chyba auditu hlásí skutečné `errno` pro adresář i chybějícího rodiče, `--dest` uvnitř `--root`
  je exit 2.

## Omezení a navazující kroky

1. Konsolidace auditu s formátem z WP1.H1 (a napojení na manifest z H2/H3) — samostatný balík.
2. WP2.11: skutečné systémové operace (skutečný zdroj v oblasti, ACL, vlastník, časové značky),
   kontrola proti reálné politice exportu a běh pod UID oblasti.
3. Prototyp neprokazuje, že export z oblasti nemůže obejít politiku: to je otázka WP1.H6 a akceptace S0.
