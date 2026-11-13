# `proto/export` — řízený export (WP1.H5, prototyp)

Izolovaný prototyp proudu H: data z oblasti ven jen řízeným exportem (PLAN F0.3, R2/R7;
odklad R4/R6 do F3/F4 podle `docs/IMPLEMENTATION.md` §1.3). Balík **není** součást MVP,
nesestavuje se do běžícího celku a **nedokazuje žádnou bránu**. Ve F2 ho převezme WP2.11
a znovu ověří proti prošlým branám.

- Bez externích závislostí, žádné `.package(path:)`, Swift 6 / tools 6.0, `.macOS(.v15)`.
- SHA-256 používá systémový `CryptoKit`; žádná externí knihovna.
- Testy běží na vlastních dočasných stromech pod `/private/tmp/h5-export-*` a mažou jen svoje stromy.
- Neexistuje žádná root operace. Kopie zapisuje do nového cílového stromu; explicitní
  `--audit` navíc vytváří samostatný auditní soubor mimo zdroj.

## Co prototyp dělá

| Fáze | Rozhraní | Chování |
|---|---|---|
| 1. selekce | `ExportPreparer` | Explicitní seznam relativních cest. Žádný průchod adresářem: co není vyjmenované, se neexportuje. Stejná identita `(dev, inode)` se sloučí; kolize cílových jmen se odmítne. |
| 2. preview | `ExportPlan` | Strukturovaný popis (cesta, velikost, SHA-256, mode, rozhodnutí, důvod). Zdroj a cíl nemění; explicitně předaný auditní sink může zapisovat. CLI dry-run na disk nezapisuje. |
| 3. kopie | `ExportCopier` | `openat` + `O_NOFOLLOW` + `fstat` na fd, kontrola metadat i SHA-256 proti preview, nový cílový strom. |
| 4. karanténa | `QuarantineWriter` | `com.apple.quarantine` na fd **prázdného** výsledku hned po `O_CREAT|O_EXCL`, pak zápis obsahu, na konci jen re-verify. Selhání = **chyba**, žádný fallback. |
| 5. audit | `FileAuditSink` / `RecordingAuditSink` | Append-only JSON Lines: jeden záznam na řádek, `fsync` po každém. Dokončené záznamy zůstanou po pádu procesu; nejde o transakci celé kopie. |

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

Typ souboru se zjišťuje `fstatat(AT_SYMLINK_NOFOLLOW)` **před** otevřením, takže již
klasifikované FIFO nebo zařízení se neotevře. Při souběžné záměně mezi klasifikací a `openat`
se otevření může pokusit o jiný typ; následný `fstat` ho odmítne. Není to ochrana před
vedlejšími účinky otevření zařízení podstrčeného právě v tomto okně. Kopie navíc otevírá s `O_NOFOLLOW | O_NONBLOCK | O_NOCTTY`.
Meziadresář se po `openat` znovu ověří `fstat`: `dev`/`inode` otevřeného fd musí být stejné
jako inode klasifikovaný `fstatat`, jinak export skončí chybou.

### TOCTOU a identita obsahu

Preview uloží `device`, `inode`, `size`, `nlink`, `mode` a **SHA-256 obsahu**.
Plán navíc váže `dev`/`inode` zdrojového kořene: jeho náhrada před kopií nebo před
založením CLI auditu skončí `invalidRoot` s `ESTALE`, i kdyby původní soubor byl přesunut
do nového kořene. Relativní kořen se při preview zachytí jako absolutní cesta. Kopie soubor znovu
otevře (`openat` relativně k fd rodiče, každá komponenta `O_NOFOLLOW`) a porovná `fstat` na fd:

- jiný `dev`/`inode`/`size`/`nlink` proti preview → `identityMismatch`, nic se nezkopíruje,
- soubor už nejde bezpečně otevřít (zmizel, přibyl mu hardlink, změnil se typ) →
  `sourceUnavailable` s důvodem ze selekce,
- kopie počítá SHA-256 průběžně při čtení; jiný hash nebo počet bajtů než v preview →
  `identityMismatch`, částečný cíl se odstraní,
- jiný stav po dokončení kopie → `identityMismatch`,
- kopie přečte nejvýše velikost z preview a jeden kontrolní bajt; bajty přes schválenou
  velikost nezapisuje. Souběžný růst, včetně řídkého souboru, se odmítne bez čekání na EOF.
  Stejný limit (velikost z `fstat` + kontrolní bajt) platí pro hashování při preview.

Tím se zachytí i přepis na místě se stejnou velikostí a stejným inode. Preview proto musí zdroj
skutečně přečíst: soubor bez práva čtení se odmítne už v preview jako `ioError`.

### Duplicity a kolize cílových jmen

`CI.txt` a `ci.txt` mohou být na case-insensitive APFS stejný inode, stejně jako NFC a NFD zápis
téhož jména. Preview proto:

1. sloučí přijaté kandidáty se stejnou identitou `(dev, inode)`; ponechá první cestu v UTF-8
   pořadí, takže výsledek nezávisí na pořadí argumentů ani na jejich bajtech,
2. odmítne skutečné kolize **různých** identit podle cílového jména: case-insensitive
   (`lowercased`) + Unicode NFC normalizace. Odmítnou se všechny kolidující cesty s
   `destinationCollision`, takže `isClean == false` a apply se vůbec nespustí. Kontrola
   zahrnuje každou komponentu: `Dir` proti `dir/file` i `Dir/a` proti `dir/b` se odmítnou;
   shodně zapsaný společný adresář (`sub/a`, `sub/b`) je povolený.

Cílový soubor vzniká `O_CREAT | O_EXCL`, takže existující cíl se nikdy nepřepíše. Cílový kořen
musí být **nový** adresář; existující cíl je `destinationExists` (i symbolický odkaz).
Cílový kořen nesmí ležet uvnitř zdrojového kořene (`destinationInsideRoot`): export by zapisoval
do právě exportovaného stromu. CLI používá `realpath` pouze pro časnou diagnostiku
(exit 2), při které zachovává pořadí vyhodnocení symlinků a `..`. Autoritativní kontrola
kopie otevře rodiče cíle, projde jeho předky přes fd a porovná identity se zdrojovým
kořenem; teprve pak provede `mkdirat` a `openat` vůči stejnému fd. Změna rodičovského
symlinku po otevření nepřesměruje zápis. Změna zjištěná až při apply je chyba exit 1.

Cílové adresáře si kopie pamatuje jako otevřené fd. Existující neznámý adresář se odmítne;
opakovaně použitý adresář musí stále odpovídat původnímu inode. Nové adresáře mají
vlastníka procesu a mode `0700`. NUL v kořeni, cíli nebo auditu se odmítá bez zkrácení cesty.

### Předpoklad důvěryhodného cílového prostoru

Volající musí po celý export ovládat zdrojový kořen, cílového a auditního rodiče i jejich
rodiče tak, aby jiný proces nemohl tyto adresáře přesouvat nebo nahrazovat. Pin fd brání
přesměrování symlinku, **nezabrání přesunu připnutého adresáře dovnitř zdroje po kontrole
předků**. `mkdirat`/`fstatat`/`openat`, závěrečná kontrola jména a úklid přes `unlinkat`
jsou samostatné operace, nikoli atomická obrana proti souběžnému procesu se stejným UID
nebo jinému aktérovi s právem měnit rodičovský prostor. Kontroly zachytí testované záměny,
ne všechny možné proklady. Zděděné ACL cílového svazku se zde neodstraňují; volající musí
zvolit soukromý cílový prostor. WP2.11 musí tyto předpoklady zajistit oddělením UID/ACL a
ověřit v reálné oblasti. Prototyp takový bezpečnostní předěl neprokazuje.

### Co prototyp nedělá

- Nekopíruje ACL, vlastníka, časové značky ani jiné xattr než karanténu. Soubor vzniká s
  mode `0600`; schválená práva z preview se nastavují `fchmod` z `mode & 0o777`.
  Setuid/setgid/sticky se na výsledek nepřenáší ani při prvním vytvoření,
  aby export nevyráběl privilegovaný soubor.
- Neuklízí částečný cílový **strom** po chybě — volající ho smaže sám, protože je to jeho nový
  adresář. Aktuální **soubor** odstraní při selhání kteréhokoli kroku po vytvoření,
  včetně karantény a zápisu jeho copy auditu. Dříve dokončené a auditované soubory zůstávají.
  Úklid ověří identitu jména, aby nesmazal zjištěnou náhradu; přesunutý soubor ani neúspěšný
  `unlinkat` tímto prototypem nejsou zaručeně uklizeny. Platí výše uvedený předpoklad
  důvěryhodného cílového prostoru. Celý export není atomická transakce.
- Neumí adresářový export ani rekurzi; strom se skládá z explicitních cest.
- Neobsahuje čas v auditu. Používá **provizorní lokální záznam** (`sanjbox.export.audit.v0`, JSON Lines). **Konsolidace s formátem auditu
  z H1 je navazující krok** (stejně jako napojení na manifest stavu z H3/H2).
  Přítomný `proto/contracts` se tímto balíkem zatím neimportuje. Audit eviduje preview
  a dokončené kopie, nikoli samostatný záznam každého selhání či uzavření celého běhu.
- Neověřuje chování Gatekeeperu při spuštění exportovaného souboru ani obnovu po rebootu
  či výpadku napájení; ověřuje pouze skutečnou hodnotu `com.apple.quarantine` na fd.

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
  soubor. Existující objekty včetně FIFO a symlinků se pouze klasifikují přes `lstat`
  a odmítnou bez otevření pro zápis; chyba nese `errno` (např. `EISDIR`, `ENOENT`, `EEXIST`).
  Preview nejprve vznikne v paměti; neplatný zdrojový kořen nevytvoří audit. Poté se audit
  vytvoří i pro odmítnutou selekci nebo pozdější chybu kopie (například existující cíl),
  aby uchoval rozhodnutí. Chyba CLI auditu se hlásí jako neúspěch.
- CLI audit nesmí být uvnitř zdroje (časná diagnostika exit 2, kontrola přes fd při zápisu
  exit 1). Rodič se připne před `openat(O_EXCL)` a má stejný předpoklad důvěry jako cíl.
  Knihovní uživatel zvolí `FileAuditSink(path:excluding:)` s připraveným plánem;
  samostatné `FileAuditSink(path:)` žádný zdrojový kořen nezná a nevylučuje ho.
- Generovaný audit neukládá absolutní zdrojový ani cílový kořen. Odmítnutý absolutní vstup
  má místo cesty značku `<absolute-path>`; úplný vstup je nadále v plánu na stdout.
- bez `--apply` (dry-run): `--audit` **nikdy nezapisuje na disk**. Auditní dokument jde jen na
  standardní výstup za plán; žádný soubor nevznikne. Dry-run tak nemá žádný vedlejší účinek.

Standardní výstup: JSON plánu (dry-run) a JSON výsledku (apply); v dry-runu s `--audit` navíc
auditní dokument. Standardní chyba: důvod odmítnutí nebo selhání.

| Exit | Význam |
|---|---|
| `0` | plán je čistý; u `--apply` všechny soubory zkopírované a zkaranténěné |
| `1` | I/O chyba, `identityMismatch`/`sourceUnavailable` (TOCTOU), `destinationExists`, karanténu nelze nastavit nebo ověřit, audit nelze zapsat |
| `2` | chybná příkazová řádka (neznámý přepínač, chybějící `--root`/`--file`, `--apply` bez `--dest`, `--dest` nebo apply `--audit` uvnitř `--root`) |
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
FileAuditSink(path:excluding: ExportPlan)    // navíc ověří identitu a vyloučí zdrojový kořen
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

Selektory a kopie pracují se skutečnými POSIX operacemi nad syntetickými dočasnými stromy.
`quarantineWriter`, `contentWriter` a `AuditSink` umožňují injektovat selhání či řízenou
souběžnou změnu. Tyto případy jsou **mock/injekce**, nikoli důkaz selhání skutečného disku,
ACL nebo izolace oblasti. Ostatní testy zapisují a čtou skutečný xattr.

## Testy

`swift test --package-path proto/export -c debug` a totéž s `-c release`. Osmdesát testů
v pěti sadách (`SelectionTests`, `CopyTests`, `AuditTests`, `CLITests`, `ReviewRegressionTests`)
pokrývá následující případy; konkrétní běh a případná přeskočení uvádí [VALIDATION.md](VALIDATION.md):

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
- připnutého cílového rodiče při změně aliasu oběma směry, náhradu zdrojového kořene,
  odmítnutí vloženého/vyměněného cílového adresáře i kořene, kolize soubor/adresář,
- omezené čtení hashe při růstu, NUL v cestách, audit uvnitř zdroje a jeho absolutní vstupy,
- selhání copy auditu: odstranění aktuálního souboru a zachování dříve auditované kopie,
- JSON round-trip plánu se pro apply odmítne (`planNotPrepared`),
- injektované selhání zápisu uprostřed kopie: v cíli nezůstane nekaranténovaný částečný soubor
  a append-only audit existuje,
- `setuid` a sticky bit se na výsledek nepřenášejí a `bytesCopied` sedí na velikost;
  test konkrétního speciálního bitu se přeskočí pouze tehdy, když ho prostředí nedovolí
  vytvořit už na zdrojové fixture (obyčejná práva a další testy kopie běží dál),
- audit je bajtově identický napříč běhy, nezávislý na pořadí argumentů a **neobsahuje absolutní
  cesty** ani v preview, ani v copy záznamech,
- CLI: dry-run nic nezapíše (ani `--audit`), exit 0/1/2/3, `--audit` nepřepíše existující soubor,
  chyba auditu hlásí skutečné `errno` pro adresář i chybějícího rodiče, `--dest` uvnitř `--root`
  je exit 2, včetně cesty `alias/../out`; existující auditní FIFO a symlink na FIFO
  se odmítnou v samostatných procesech s časovým limitem.

## Omezení a navazující kroky

1. Konsolidace auditu s formátem z WP1.H1 (a napojení na manifest z H2/H3) — samostatný balík.
2. WP2.11: skutečný zdroj v oblasti, zajištění důvěryhodných rodičů, ACL, vlastník, časové značky,
   kontrola proti reálné politice exportu a běh pod UID oblasti.
3. Prototyp neprokazuje, že export z oblasti nemůže obejít politiku: to je otázka WP1.H6 a akceptace S0.
