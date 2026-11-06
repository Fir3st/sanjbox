# WP1.B4 — proveditelnost skutečné APFS obnovy

**Výsledek: dokumentovaný kandidát existuje, kompletní B4 mechanismus zatím doložen není.**
`asr` popisuje obnovu konkrétního APFS snapshotu do živého cílového svazku. To je kandidát pro
`prepare`, nikoli provedený experiment. Vytvoření snapshotu s povoleným podpisem, identita cíle
po obnově, crash/reboot recovery a nezávislý zákaz startu celého UID zůstávají blokátory.
Žádná část této studie nepovoluje skutečný start ani nemění S4/RB-02…08 z **Neověřeno**.

Rozsah odpovídá [PLAN — obnova](../../../../PLAN.md), [B3 schématu](../../SCHEMA.md) a
[B4 recovery modelu](../../RECOVERY.md). Nevznikl další mock, APFS adaptér, wrapper ani F2 kontrakt.
Četly se pouze primární dokumenty a metadata verzí; neproběhla ani inventura skutečných disků.
Žádný snapshot, mount, unmount, restore, změna uživatele/služby či privilegovaný příkaz nebyl spuštěn.

## Co je a není doložené

- **Pozorováno:** dostupné soubory SDK/man, jejich obsah a SHA-256; macOS 27.2 (26B123),
  Xcode 27.2 (27B52), SDK `macosx27.2`, capture 2026-11-06. Jde o měření dokumentů/verzí,
  **nikoli APFS chování**. Historická LAB metadata zůstávají beze změny.
- **Dokumentováno [D]:** vlastnost výslovně popsaná v primárním zdroji. Manuál přibalený k novému
  SDK může mít starý text; dostupná deklarace neprokazuje oprávnění ani runtime podporu.
- **Odvozeno [O]:** požadavek návrhu vyplývající z těchto omezení a PLAN, nikoli měřený invariant.
- **Hypotéza [H] / mezera [G]:** potřebuje uživatelský experiment nebo dosud chybějící mechanismus.
  Existující file-backed výsledek je **mock**, bez přenosu jeho výsledků na APFS.

Citace S01–S13 odkazují na [index zdrojů](SOURCES.md) a strojově čitelný
[manifest zdrojů](sources.json). Primární web byl ověřen při capture; XNU je připnuté na commit,
ostatní zdroje na hash konkrétních bytes. [Experimenty](EXPERIMENTS.md) jsou podmíněné karty pro
uživatele v pozdější laboratoři, [validace](VALIDATION.md) kontroluje dokumentační artefakty.

## Tři kandidátní cesty

| Cesta | Primární podklad a oprávnění | Výsledek pro B4 |
|---|---|---|
| **A — in-place revert** přes `fs_snapshot_revert` | [D S01/S02] Funkce existuje, mění původní FS a zahazuje změny i novější snapshoty. S02 požaduje superuser + další entitlement. | [O] Není implementací B3 `rebuild-writable-state-then-switch`: nevzniká oddělený připravený stav a ztrácí se starý stav dříve než je připravena celá jednotka. Nemůže být tiše dosazena za `prepare`. [G] Dostupnost, otevřené fd, okamžik účinku/durability a chování po rebootu nejsou tímto textem doloženy. |
| **B — snapshot → nový živý svazek pomocí `asr` replication** | [D S03] `restore`, `--toSnapshot` přijímá jméno nebo UUID snapshotu; snapshot restore je pouze pro replication. Výsledek má živý stav odpovídající zdroji ve snapshotu a také kopii snapshotu se stejným jménem/UUID. `asr` vyžaduje root; `--erase` je destruktivní. | **[H] Kandidát k prvnímu ověření `prepare`.** Pro obyčejné nesystémové, neseskupené testovací svazky, každý cíl samostatně. [G] Ověřit writable režim a metadata, skutečné identity před/po, target mutation scope, prostor, chybové/interrupt chování. Zdokumentovaná OS utilita není ověřená integrační cesta pro náš helper. |
| **C — read-only snapshot mount → kopie/klony souborů do nového svazku** | [D S02/S05] Snapshot mount je read-only. [D S06/S07] `clonefile`/`copyfile` jsou souborová API, ne API pro klon svazku. Oprávnění k mountu a kopírování úplných UID/ACL metadat je třeba ověřit; ordinary data copy automaticky nevytváří správné ownership. | [O] Pouhý recursive copy nesplňuje whole-volume obnovu: známá mezera hardlinků a metadata změny níže. [H] Vlastní rekonstrukce by vyžadovala úplnou specifikaci a samostatný důkaz. V tomto balíku se nestaví a není vydávána za hotový fallback. |

**Snapshot není writable clone.** S01 nemá funkci „snapshot clone to writable volume“; read-only
mount není `prepare`. Nevyvozujeme z toho neexistenci jiné interní OS cesty. Ani diskutil manuál S04
není úplný seznam možných interních příkazů: v zachyceném textu jsou `listSnapshots` a
`deleteSnapshot`, nikoli doložená obecná create/revert CLI cesta pro B4.

### Oprávnění a hranice zdrojů

S02 (text s historií 10.13 a datem 2017) uvádí superuser a další entitlement pro snapshot funkce;
S01 deklaruje dostupnost od 10.12. Tento rozdíl se nepřepisuje na testovaný runtime fakt.
V publikovaném XNU S11 je entitlement kontrola před dispatch create/delete/rename/mount/revert;
obsahuje `com.apple.developer.vfs.snapshot` i privátní alternativy. Následující autorizační kontrola
pro změny připouští vedle superuser také oprávnění k zařízení/privátní výjimku. Tedy ani formulace
manuálu není úplnou specifikací všech cest v tomto zdrojovém stromu.

S11 je veřejná revize z 2025-10-16, **není doloženo, že odpovídá běžícímu kernelu/APFS 27.2**.
Revert předává řízení filesystemu; veřejný VFS kód nedokládá všechny kontroly APFS. Z těchto zdrojů
nelze určit dostupnost potřebného entitlementu pro Personal Team ani prohlásit, že root stačí.
Není doložen důvod doporučit privátní ioctl, zapsání entitlementu do plist, změnu SIP nebo placený
účet. D-002/F0.5 se nemění. Snapshot creation zůstává **G1**; systémové nástroje mohou mít jiná
oprávnění, ale jejich existence sama tuto mezeru neuzavírá.

### Proč souborový clone/copy není přesná obnova

[D S06] `clonefile` sdílí datové bloky copy-on-write, ale má vlastní atributy; může změnit ownership,
odstraní setuid/setgid a ACL dědí z cíle. `CLONE_ACL` přidá zdrojovou ACL k děděné, což není obecně
identická ACL. Volání vyžaduje stejný filesystem (`EXDEV`); stejný APFS kontejner z různých svazků
stejný filesystem nedělá. Snapshot mount → živý svazek proto nemá z této podmínky zaručený clone.
Directory clone je v manuálu výslovně nedoporučený. Atomický jednotlivý clone není transakce všech
rolí ani durability receipt.

[D S07] `COPYFILE_ALL` zahrnuje data, POSIX metadata, ACL a xattrs, ale recursive copies
**nezachovávají hardlinky**. `COPYFILE_CLONE` může přejít na běžnou kopii; ACL potřebuje samostatný
flag. Rekurzivní průchod není atomický a standardně překračuje mountpointy; zdroj měněný během
průchodu má nedefinovaný výsledek. Jen úspěšný návrat a shoda souborových SHA-256 tedy nestačí.

[O] Případný copy kandidát potřebuje syntetický oracle pro vlastnictví/mode/ACL pořadí a dědičnost,
xattrs/resource fork, symlinky bez následování, hardlink ekvivalenční třídy, řídké soubory, flags,
prázdné adresáře a nečekané speciální soubory. Musí zabránit průchodu do jiných mountů a vymezit
podporované typy; nepodporovaný stav znamená odmítnutí, nikoli tichou částečnou obnovu. Převod
všech těchto vlastností na production konstrukci zůstává mimo tento výzkum.

### Co skutečně říká `asr`

[D S03] Snapshot restore používá replication, nikoli legacy inverter. Nepoužívat představu, že
se APFS volume device dá běžným procesem blokově kopírovat. Manuál rozlišuje cílový svazek,
kontejner a partition; u některých variant maže/zakládá více objektů. Obsahuje také napětí mezi
obecným požadavkem `--erase` a historickou větví „Volume Restore with Creation“ bez `--erase`.
Studie proto tuto větev nepoužívá jako automatickou alokaci cíle. Laboratoř má explicitně předem
vytvořený prázdný cílový **svazek** a ověřuje rozsah operace. Podpora zdroje/cíle ve stejném
kontejneru není těmito citovanými částmi jednoznačně potvrzena; je součástí pilotu, nikoli předpoklad.
Selhání této topologie samo nevyvrací možnost odděleného cílového kontejneru.

[D S03] U ROSV volume-group restore se člen s požadovaným snapshotem obnoví z něj, ale člen bez
něj může být zkopírován z **živého** stavu. Shodná jména snapshotů mezi svazky nezaručují stejný
čas ani vztah. Skupina není řešením atomické snapshot sady B4. V experimentu jsou System/Data,
Preboot/Recovery role, volume groups a boot volume vyloučené; nic z toho se nepřekonfiguruje.

## Návrh receipt → skutečný objekt → operace → selhání → recovery

**[O] Následující tabulka je požadavek na budoucí adaptér, není nové schéma ani implementace.**
`RecoveryReceipt` dnes obsahuje metadata/sha syntetického JSON souboru. Nelze jej přímo považovat
za APFS receipt. B3 `declaredUUID` je návrhové pole; musí existovat oddělené pozorované přiřazení.

| B4 místo / receipt | Nutná skutečná identita a její zdroj | Operace / potvrzení | Selhání a bezpečný recovery výsledek |
|---|---|---|---|
| `begun`, `currentBindings` | Transaction UUID + digest neměnného manifestu/policy; pro každý logický volume ID **container UUID + parent volume UUID**, role/group membership, současné BSD jméno a mountpoint. S04 `info -plist`, cílený `apfs list -plist`; S10 `ATTR_VOL_UUID` nad skutečným kořenem jako křížová kontrola. Přesné plist klíče se musí připnout v labu. | Vyřešit pouze povolené objekty, ověřit mount root přes otevřený descriptor a skutečný FS, nikoli jen řetězec cesty. Zaznamenat boot a aktuální mount identity zvlášť. | Duplicita UUID, nesoulad kontejneru/role, jiný mount nebo jen návrhové UUID ⇒ deny, nic neopravovat automatickým hledáním podle názvu. |
| `snapshot-intent/done(V)` | Parent volume/container receipt + **snapshot UUID + lokální XID + aktuální name**. S04 `listSnapshots -plist` dává UUID/name/XID; S12 potvrzuje jejich existenci. UID/transaction není nativní vlastnost snapshotu. | [H G1] Vytvoření pod předregistrovaným jedinečným názvem přes prokázanou cestu; poté znovu načíst tuple a potvrdit přítomnost při stále platném quiescence. | Pád mezi mutací a completion: snapshot s očekávaným jménem je kandidát k posouzení, nikoli důkaz vlastního dokončeného intentu. Neopakovat create, nepřepsat/nesmazat kolizi. |
| `snapshot-ready` | Úplná množina všech parent+snapshot tuples, jedna host transaction a nepřerušený lifecycle generation. | [O] Snapshoty vznikají postupně. Konzistentní set plyne jedině z toho, že žádný relevantní writer nemění žádný člen po celou dobu; potřebné jsou i služby zapisující za UID. | Chybějící snapshot nebo writer race ⇒ celá sada neplatná. Timestamp, stejný název nebo podobné XID nejsou společný atomic checkpoint. |
| `prepare-intent/done(V)` | Zdrojový parent+snapshot tuple; **cílový container/volume tuple před i po `asr`**; destination allocation receipt; digest syntetického oracle a výsledků metadata kontrol. | [H] Asr snapshot replication do odděleného disposable cíle. Zaznamenat argv, verzi, exit status i pozorované postconditions; ověřit writable live root, snapshot provenance, všechny role a metadata před `prepare-done`. | `asr` smí target nahradit; zachování ani změna volume UUID není předem předpoklad. Novou identitu bez doložené vazby k vlastní alokaci nepřijmout. Exit 0, stejné snapshot UUID nebo neúplná kopie ⇒ samy nejsou completion. ENOSPC/timeout/exit/crash ⇒ target karanténa. |
| `switch-intent/done(V)` | Původní i nový volume tuple, přesný chráněný mountpoint a jeho parent/directory identity; aktuální mount flags/ownership; policy generation. | [H] Po přípravě **všech** členů při fully-off jednotlivě unmount původního a mount ověřeného nového svazku na požadovanou cestu (S04/S05). Postcondition ověřit nad nově otevřeným root descriptor, ne stale fd. | Mezi operacemi je prázdná cesta; mezi členy smíšená sada. Busy, náhradní mount, nesprávné flags, přerušení ⇒ zůstat deny; žádný force-unmount nebo rename svazků. |
| `verified`, start | Všechny konečné binding tuples + aktuální policy/manifest + **nový platný** witness celého UID, síť/admission stále blokované. | Ověřit všechny mounty a ochrany znovu, přesnou syntetickou obnovu včetně odstranění nového startup kanárku. Durable host completion až za splněnými postconditions. Start je další kontrolovaný přechod. | `verified` z minulého procesu/bootu není capability. Chybějící nebo nečitelný control, konfliktní identita, ztracený interlock ⇒ deny. |
| Cleanup receipt | Vlastní transaction → přesné alokované targety/mounty/snapshoty; poslední ověřená identita + informace zda jsou ještě referencované nebo slouží jako recovery podklad. | Uživatel odstraní pouze již prokazatelně nepotřebné vlastní objekty; S04 deleteSnapshot má i `-wait`, jinak může mazání pokračovat po návratu. Poté znovu ověřit stav. | Název prefixu, stale BSD číslo ani snapshot UUID samotné neopravňuje smazat. Konflikt nebo nevyřešený intent ⇒ zachovat, blokovaný lab slot. |

**UUID snapshotu není identita jediné fyzické instance.** `asr` zachová UUID/name snapshotu na cíli
[S03]. Receipt proto vždy váže snapshot k rodičovskému svazku a kontejneru. Name je přejmenovatelné;
XID je používáno v namespace rodiče [S04]. BSD disk čísla a mountpoint jsou runtime lokátory,
ne přenositelné recovery identity. S04 popisuje i snapshot `f_mntfromname` ve tvaru
`name@/dev/disk…`; není to vždy cesta zařízení. Neparsovat z něj samotného autoritu.

[O] Tyto tuple jsou nutné, nikoli dostatečné: UUID není podpis ani důkaz kdo provedl mutaci.
Name-based snapshot syscall nedává compare-and-swap podle celého receipt a asr nedává potvrzení
naší host transaction. Vyžaduje se výlučné důvěryhodné řízení vlastních svazků a opakovaná kontrola;
pre/post check sám neřeší TOCTOU proti nezávislé správě disků. Při administrativním driftu se
pokračování odmítne. Kontrolní soubor nesmí být jediná autorita uložená uvnitř nedůvěryhodného cíle.

## Atomicita, crash a reboot

[D] Snapshot je jeden read-only filesystem stav [S02]; `RENAME_SWAP` zaměňuje vhodné položky
filesystemu [S08]; mount_apfs připojuje **jeden** svazek do **globálního** namespace [S05]. Retired
APFS Guide popisuje crash protection a atomic safe-save pro rename [S13], nikoli transakci
snapshot→rekonstrukce→mount více svazků. **Z těchto podkladů není doložena ani atomická sada
snapshotů, ani atomické vícesvazkové přepnutí, ani celá power-loss transakce B4.**

[O] I s jedním state svazkem zůstává prepare/unmount/mount/start více operací. Se dvěma svazky
existuje navíc smíšený stav. Bez platného whole-UID interlocku nelze z „nikdo to nemá vidět“
udělat atomicitu pro oblast. Pro hosta není ani při platném interlocku namespace atomicky přepnutý.

| Hranice pádu | Co lze po restartu pozorovat | Co z toho neplyne / požadavek |
|---|---|---|
| Intent je durable, operace ještě neproběhla nebo jen chybí odpověď | Původní objekt, nový snapshot/target, částečný target, jiný mount | Není přesně-once receipt. Pending intent v současném B4 zůstává v karanténě; studie nemění tuto politiku. |
| `asr` skončilo, completion nebyl durable | Target může vypadat úplně, obsahovat zdrojový snapshot UUID | Neprokazuje durable completion, autorství ani nepřerušený interlock. Žádné automatické přijetí jen podle hashů/canary. |
| Po unmount nebo prvním z několika mountů | Prázdný mountpoint, stará/nová/smíšená sada, případně připojení na jiné místo | Zachovat deny; nejdřív znovu sestavit úplnou mapu identit. Žádná slepá replay operace nad starým `/dev/diskN`. |
| Po `verified`, při helper crash / reboot | Deník lze načíst; původní witness a deskriptory již nejsou platné | Boot-time interlock musí existovat před loginem/jobem. Obnovit ochrany a nové identifikace, žádný implicitní start. Současný mock přes reboot odmítá vše; nový cross-boot recovery není implementován. |
| Chyba flush, I/O, ENOSPC, selhání úklidu | Data mohou být viditelná, zpracování/deletion může pokračovat | Nezaměňovat viditelnost za garantovanou durability. Documentace nedává completion oracle pro power loss. Protokol musí uchovat stav a nedovolit start. |

Fsync/reflush JSON deníku nemůže dodat durability garanci pro dřívější APFS restore/mount, ani
obnovit ztracený admission interlock. Kill jednoho řídicího procesu nemusí zastavit externě spuštěný
nástroj; recovery musí rozlišit „operace stále běží“ a „skončila“, než vůbec uvažuje o dalším zásahu.
Power-loss se v této studii ani v navrženém prvním pilotu neprovádí.

## Whole-UID admission je samostatný nevyřešený mechanismus

[D S09] `launchctl bootout` odstraňuje doménu/služby; user doména může existovat bez loginu, GUI a
user mají odlišné služby. `disable` je per-service a přežívá boot. Žádná z těchto citovaných
operací nedokládá trvalý zákaz všech budoucích procesů UID. Proto se nepředkládá recept „bootout +
kill + scan = gate“. Nula PID je pozorování; bez zákazu nového startu není stabilní quiescence.

[O] S0 musí prokázat: uzavření všech vstupů (GUI/login, user/gui launchd jobs, detached/fork,
cron/at, SSH/Screen Sharing a služby jednající za oblast); blokování nového admission a sítě před
quiescence; stabilitu při helper crash/reboot a fully-off včetně fd/mappingů před obnovou.
Mount policy není per-UID namespace, `nobrowse` je jen doporučení pro prohlížení [S04/S05].
Root-owned recovery záznam mimo rollback musí být chráněn před UID oblasti, ale samotný soubor
procesy nezastaví. **G2: tuto konstrukci aktuální B4 ani tato studie nemá.**

## Závěr pro další práci

- **G1:** Prokázat konkrétní povolenou cestu vytvoření/mountu snapshotu na daném buildu s podpisem
  slučitelným s F0.5; žádné předpokládané udělení entitlementu.
- **G2:** Nezávislý whole-UID admission/lifecycle mechanismus, přežívající helper death a reboot;
  bez něj není možné bezpečné skutečné B4 přepnutí.
- **G3:** Změřit candidate `asr` pro samostatný nesystémový svazek: identity, metadata, writable
  stav, místo, úplnost, přerušení; potom teprve více svazků.
- **G4:** Navrhnout a ověřit completion/reconciliation pro nejednoznačný OS zásah a reboot.
  Konzervativní karanténa je bezpečný neúspěch, nikoli automatické zotavení z každého pádu.

První další výstup je předregistrovaný uživatelský pilot podle [karet](EXPERIMENTS.md), až budou
splněny L1 → S0/S8 a připraven L3 slot. Tato studie nepřepisuje implementační ani gate verdikty.
