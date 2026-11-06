# Primární podklady a jejich meze

Capture **2026-11-06 UTC**, macOS 27.2 (26B123), Xcode 27.2 (27B52), SDK `macosx27.2`.
Plné cesty/URL, počet bytes, SHA-256 původního souboru a locators jsou v [sources.json](sources.json).
Repo uchovává parafráze a hashe, nikoli zrcadlo Apple dokumentace. Manuály se hashují v původním
roff formátu; nehashuje se terminálový výstup `man`. Datum manuálu není verze běžící implementace.

`SDK/` níže je `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/`.
Změna tohoto symlinku nebo OS aktualizace vyžaduje nové čtení a hash; shoda jména SDK nestačí.

| ID | Zdroj / přesné místo | Podporované tvrzení a hranice |
|---|---|---|
| S01 | `SDK/usr/include/sys/snapshot.h`, deklarace a mount flags | Snapshot API je v SDK; deklarovaná macOS availability 10.12. Neprokazuje udělený entitlement ani úspěch syscallu. |
| S02 | `SDK/usr/share/man/man2/fs_snapshot_create.2`, DESCRIPTION / COMPATIBILITY / ERRORS / HISTORY; `.Dd July 4th, 2017` | Read-only snapshot/mount; destructive revert včetně novějších snapshotů; požadavek superuser + entitlement; capability `VOL_CAP_INT_SNAPSHOT`. HISTORY uvádí 10.13; rozdíl proti S01 zachován. Aliasové man stránky pro ostatní snapshot funkce nejsou další nezávislé zdroje. |
| S03 | `/usr/share/man/man8/asr.8`, snapshot/replication/ROSV sections; `.Dd December 10, 2020` | Root, `--toSnapshot`, target live state, zachované snapshot UUID, group live fallback; restore je destruktivní. Žádná z citovaných částí neslibuje naši host transakci či vícesvazkovou atomicitu. |
| S04 | `/usr/share/man/man8/diskutil.8`, APFS objects, `info`, `mount`, `listSnapshots`, `deleteSnapshot`, DISK IDENTIFIER; `.Dd 11 June 2024` | UUID/name/XID, rodičovský namespace, přejmenování; custom mountpoint; ownership disků pro delete; asynchronní deletion bez `-wait`. Pole konkrétního plist výstupu nebyla naměřena. |
| S05 | `/usr/share/man/man8/mount_apfs.8`, SYNOPSIS / DESCRIPTION / `-s`; `.Dd September 16, 2015` | Připojení jednoho APFS volume do globálního namespace; snapshot argument je name, base je mounted root. Nedokládá per-UID namespace ani atomic switch. |
| S06 | `SDK/usr/share/man/man2/clonefile.2`, DESCRIPTION / flags / EXDEV; `.Dd June 3, 2021` | Copy-on-write soubor, metadata výjimky, ACL dědičnost, stejný FS, directory clone nedoporučený. Ani deklarovaná atomicita volání nezaručuje B4 transakci nebo power-loss durability. |
| S07 | `SDK/usr/share/man/man3/copyfile.3`, flags / Recursive Copies / BUGS; `.Dd March 29, 2024` | ACL/stat/xattr/data; clone fallback; recursive copy není atomický; default crossing mountů; hardlinky se nezachovají. Přesná obnovitelnost celého svazku není tímto API hotová. |
| S08 | `SDK/usr/share/man/man2/rename.2`, RENAME_SWAP / EXDEV; `.Dd June 3, 2021` | Atomická záměna vhodných filesystem položek, nikoli výměna svazků či mountů. |
| S09 | `/usr/share/man/man1/launchctl.1`, domains / bootout / disable; `.Dd 1 October, 2014` | Oddělené user/GUI služby, user domain bez loginu; disable přežije reboot pro danou službu. Nedokládá zákaz všech startů UID. |
| S10 | `SDK/usr/include/sys/attr.h`, `ATTR_VOL_UUID`, `ATTR_VOL_CAPABILITIES`, `VOL_CAP_INT_SNAPSHOT` | Existují filesystem identity/capability atributy. Deklarace není dynamicky zjištěná hodnota a capability není oprávnění. |
| S11 | [Apple XNU VFS, připnutý commit](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/vfs/vfs_syscalls.c), funkce `vfs_context_can_snapshot`, `fs_snapshot`, `snapshot_revert` | Veřejný VFS kód má entitlement gate a deleguje revert do FS. Commit z 2025-10-16 neprokazuje implementaci kernelu/APFS 27.2 ani dostupnost entitlementu Personal Team. Hash je z raw URL v JSON. |
| S12 | [Apple Support — APFS snapshots](https://support.apple.com/en-ca/guide/disk-utility/dskuf82354dc/mac), popis snapshotu a metadata tabulky | Read-only kopie rodičovského volume; UI má XID/UUID a přejmenování. Žádný programový atomic/recovery kontrakt. |
| S13 | [Apple File System Guide — Features](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/APFS_Guide/Features/Features.html), Crash Protection / Atomic Safe-Save | Archivovaný dokument, sám označený Retired, updated 2018-06-04. Atomic safe-save popisuje rename, nikoli B4. Použit jen k omezení zavádějícího přenosu marketingového slova atomic. |

S11 byl vybrán přes veřejné GitHub metadata `commits/main` a pak stažen z neměnného commit URL;
žádné běžící chování se z data větve neodvozuje. Web fetch S12 přes vyhledávací nástroj uspěl ve
výsledku vyhledávání, přímé `open` dostalo HTTP 429; samostatný malý HTTPS fetch originu uspěl.
S13 i připnutý raw S11 byly otevřeny také web nástrojem. SHA-256 v manifestu jsou z bounded HTTPS
fetchů, nikoli z parsovaného zobrazení nástroje. Limit byl 1 500 000 bytes na soubor; síťové soubory
měly celkem méně než 2 MB včetně dočasného GitHub revision response, který není citovaným zdrojem.

HTML může obsahovat proměnlivé UI bytes: pozdější hash mismatch znamená jinou reprezentaci,
ne automaticky změněný APFS kontrakt. Studie nezaručuje dostupnost identických HTML bytes navždy.
Připnutý obsah nebyl nahrazen sekundárními blogy; neověřené tvrzení o zvláštním APFS revert
entitlementu se zde nevydává za fakt.

## Formát manifestu zdrojů

`schema` je přesně `sanjbox.b4-apfs.sources.v1`; `capture_kind` zakazuje interpretaci jako APFS
experiment. `environment` obsahuje pouze výše uvedené verze a base commit. `sources` má 13 unikátních
ID S01…S13. Každý záznam má `id`, `title`, `kind`, `location`, ISO-8601 `captured_at`, lowercase
64hex `sha256`, kladný `bytes`, neprázdný `locators`. `installed-primary` má navíc nullable
`document_date`, `web-primary` nullable `revision`; neprázdná revision je úplný Git SHA v URL.
Tento formát slouží ke kontrole provenance dokumentace; není produkčním schema recovery receipt.

Reprodukce místních hashů je read-only čtení deseti přesných cest z JSON, nikoli automatický scan
SDK nebo disků. Zdroj chybí / hash nesedí ⇒ nový podklad k posouzení, nikoli automatické přepsání
manifestu. Online re-fetch není součástí běžné offline kontroly dokumentů.
