# Podmíněné uživatelské karty — dosud neprovedeno

**Všechny karty jsou [uživatel], ne spustitelné skripty ani souhlas se systémovým zásahem.**
První pilot má určit proveditelnost, ne vydat S4 pass. [G1–G4 a receipt mapa](README.md) určují,
co chybí. Připravit až po L1/S1 a S0/S8; provést v rezervovaném **L3** slotu se zálohou, lokálním
operátorem a schválenou předregistrací podle [LAB](../../../../docs/LAB.md). Slot nemůže začít,
pokud není dostupný skutečný admission interlock G2; bez něj se bezpečně skončí u read-only přípravy.
Tímto dokumentem se slot nerezervuje a žádná brána se neuzavírá.

## Společný rozsah a stop pravidla

Pilotní budget je **návrh k předregistraci**, nikoli nová gate metodika: dva samostatné source
svazky A/B a dva prázdné targety A′/B′ v jednom **samostatném disposable testovacím APFS kontejneru**,
max. 16 MiB syntetických dat na zdroj, max. 128 položek na zdroj, nejvýše jeden pilot každého řádku
karet a jeden opakovaný pokus po vysvětleném selhání. Nejde o boot/system/APFS volume group,
Time Machine, skutečný home nebo běžný projekt; dedikované médium připravuje uživatel samostatně.
Příprava kapacity zahrnuje všechny čtyři svazky, kopie a snapshot growth podle LAB, ne jen data.
Podpora této same-container topologie pro `asr` je otázka pilotu. Při odmítnutí se výsledek označí
pro tuto topologii; jiný disposable kontejner vyžaduje novou předregistraci, ne automatický fallback.

Předem zapsat konkrétní container/volume UUID, device locators, role, absence skupin, mountpointy,
kvóty, mount ownership/flags, ochranná práva parentů a mapping A/B na všechny B3 role
(home/project/prefix/cache/tmp). Target path nesmí být aktivní cesta jiné oblasti. Control/policy a
raw záznamy leží mimo restore unit, nepřístupné UID oblasti. Ve veřejném důkazu nahradit reálné
UUID stabilními aliasy; přesná provozní mapa zůstává v soukromém protokolu.

Žádné kopírování živé databáze/Keychain, runtime produkčního účtu, secrets ani instalace balíčků.
Data tvoří vlastní textové canaries; testovací startup položka je **inertní text**, nikoli aktivovaný
job. Aplikační konzistence se později ověřuje jen vlastními syntetickými soubory. Skutečné spuštění
rollbacknutých aplikací vyžaduje zvláštní předregistraci; tato karta nedodává S1 workload.

Před každým měnícím krokem operátor čte konkrétní argv a receipt; žádné `sudo` v tomto dokumentu,
žádné `--noprompt`, force-unmount, blanket delete, změna SIP, soukromý ioctl, placený entitlement
nebo fallback na systémový kontejner. Parent/device/UUID mismatch, nečekaná role/skupina, ztráta
interlocku, otevřený neplánovaný writer, nejasný výsledek, chybějící raw nebo změna okolí ⇒ **STOP,
deny-start, zachovat podklady a blokovaný slot**. Při timeoutu neprovádět další mutaci, dokud se
neprokáže ukončení původní operace a jejích OS účinků.

## P0 — metadata a oprávnění před první mutací

| Vstup / krok | Oracle a záznam | Stop / další krok |
|---|---|---|
| Zachytit OS/Xcode/SDK, hash metodiky a konkrétních binárek. Cílené `diskutil info -plist` a `apfs listSnapshots -plist` jen pro povolená volume devices; cílený seznam testovacího kontejneru. Křížově ověřit root FS UUID/capability přes ověřenou sondu, která nejprve kontroluje credentials. | Úplná jednoznačná mapa container/volume/snapshot tuple, konkrétní plist klíče, privátní plný stdout/stderr. Žádný host-wide log/disk scan. Ownership enabled, žádný boot/system/group objekt. | Nesoulad/nepodpora parseru = Nejasné; nepřepisovat mapping podle názvu. |
| Zvolit a doložit konkrétní cestu snapshot creation: podepsaná testovací sonda a její **skutečně přiznaná** oprávnění, nebo zvlášť doložený systémový nástroj. Nestačí header ani plist entitlement požadavek. | Zapsané signing/entitlement receipts a přesné primární API/command podklady; S02/S11 jsou důvod k otázce, ne runtime odpověď. Připravit zachycení return/errno v P1. | Nemáme oprávněnou cestu = G1 nevyřešené, žádná mutace; nepokoušet se o obejití ochrany. |
| Ověřit existenci G2 interlocku v S0 důkazu a jeho konkrétní generaci pro pilot, včetně práce host služeb za oblast. | Platné whole-UID quiescence a admission/síť deny; při restore fully-off a uzavřené fd/mappingy. | Chybí konstrukce nebo důkaz = G2; karty P1…P4 se neprovádějí. |

## P1 — vytvoření přesné sady (RB-02)

Při drženém interlocku vytvořit nejvýše jeden snapshot každého A/B pod unikátním
transaction-derived názvem pro tento pilot. Pro `fs_snapshot_create` je zdroj root descriptor
konkrétního ověřeného FS a flags 0; skutečný podpis/oprávnění a příkaz musí být rozhodnuty v P0.
Po každém kroku načíst parent+snapshot tuple včetně UUID/name/XID; zaznamenat syscall return/errno
nebo tool exit, čas, ledger intent/done a stále platný witness. Capture timestamp sám není oracle.

Pozitivní kontrola: po uzavření sady a znovupovolení pouze předregistrovaného syntetického workloadu
změnit canaries A/B a přidat inertní startup text. Následně opět plně vypnout a držet interlock.
Snapshot mount musí být read-only a zachovat staré canaries; live root má nové canaries. Mount
provádí jen operátor na vlastním chráněném místě, přes schválenou snapshot mount cestu P0.
Pozorovaná změna snapshotu, writer během capture nebo neúplný set znamenají Neprošlo/Nejasné;
nezachraňovat sadu opakováním jednoho členu v jiném čase.

**Úklid:** snapshoty ponechat pro P2; pokud se končí, nejprve identity-checked unmount vlastního
snapshot mountu, pak pouze vlastní nepoužívané snapshoty. Neúspěšný create může zanechat objekt;
absence completion sama neopravňuje delete. S02 zakazuje deletion mounted snapshotu.

## P2 — `asr` připraví nový writable stav (RB-03/04/08)

Zdroje a cíle jsou výslovně **neseskupené nesystémové svazky**. Návrh argv pro review, nikoli hotový
spustitelný příkaz: `asr restore` s `--source <ověřený-source-volume-device>`,
`--target <ověřený-prázdný-target-volume-device>`, `--toSnapshot <source-snapshot-UUID>`,
`--useReplication`, `--erase`. Nikdy zde target container/partition, `restoreexact`, inverter,
`--fromSnapshot`, `--noprompt` ani live-copy fallback. Než uživatel potvrdí erase prompt, znovu
ověří přesný target. Podmínky mount/unmountability a oprávnění pro konkrétní build patří do P0.

| Ověření | Požadovaný výsledek |
|---|---|
| Před a po každém A→A′ / B→B′ uložit target/source/container receipts, tool exit/stdout/stderr a mapu mountů. | Zdroj a ostatní testovací svazky nezměněné, změna jen vlastního targetu; skutečný nový/původní volume UUID svázaný s intentem, nikoli předpokládaný. |
| Cílový live root obsahuje snapshot canaries všech rolí a neobsahuje pozdější inertní startup text. | Úplná shoda předregistrovaného inventory (včetně absence nových položek). Target má snapshot se zdrojovým UUID, ale jiný parent receipt se nesmí zaměnit se zdrojem. |
| Syntetický metadata corpus: ACL s dědičností, různá očekávaná UID/GID, mode, xattr/resource fork, symlink na vlastní canary, dva hardlinky stejného souboru, sparse file, prázdný adresář a povolené flags. | Shoda hodnot a hardlink ekvivalenčních tříd; numerické inode nemusí být stejné. Metadata zapisuje/čte pouze uživatel na disposable targetech; chybějící typ není implicitní pass. |
| Nový jedinečný writable canary vytvořit a odstranit na **target live root**, pak znovu ověřit obsah a metadata. | Target je skutečně writable, source snapshot/source canaries beze změny. Tato pozitivní kontrola sama nedokazuje durability. |
| Control/policy hash + ownership zůstanou stejné a nepřístupné UID oblasti. | RB-08 podklad, nikoli pass bez skutečného adversarial testu přístupu. |

Připravit oba targety před prvním skutečným switch. Pilot žádné mount přepnutí do oblasti neprovede,
pokud P2 není kompletní. Samostatný copy/clone experiment je volitelný a předregistrovaný zvlášť;
známou ztrátu hardlinků `copyfile` nelze uzavřít vynecháním corpus položky. Neúplný target zůstává
v karanténě, cleanup až po ověření identit a ukončení všech činností `asr`.

## P3 — sekvenční přepnutí a crash/reboot (RB-05/06/07)

Vyžaduje skutečný native lifecycle/switch adaptér, který nyní chybí. Bez něj se karta označí
**neprovedeno**, nenahradí se spouštěním file-backed mocku. Předregistrace vybere níže uvedené
hranice, přesný způsob řízeného ukončení vlastního test controlleru a nezávislého pozorovatele;
power cut, kernel panic a zabíjení systémových procesů jsou mimo pilot.

| Jeden samostatný pokus / hranice | Oracle po novém controller procesu |
|---|---|
| Snapshot mutace skončila, completion chybí. | Pending intent zůstane deny; existující snapshot se automaticky nepřijme ani nesmaže. |
| Uprostřed `asr`, a zvlášť po jeho úspěchu před durable completion. | Rozlišen běžící nástroj/ukončený nástroj/nejistota; žádný nový restore přes něj. Target bez doložené completion zůstává v karanténě. |
| Všechny prepare hotové, před prvním unmount; po unmount A; po mount A′ před B; po všech mount před `verified`. | Zaznamenané původní/prázdné/smíšené/nové bindingy. Ve všech neuzavřených stavech odmítnutí všech testovaných start cest, nepřerušovaný deny a uzavřené fd/mappingy. |
| Po `verified`, controller ztracen; jeden uživatelem řízený reboot s neúplným switch v samostatném pokusu. | Nový proces/boot nesmí převzít starý witness. Boot-time deny musí platit před první možností loginu/jobu; aktuální mount mapa se zjišťuje znovu. Chybí důkaz kontinuity ⇒ Nejasné/Neprošlo. |

Při P3 pozorovatel zkouší pouze předregistrované **syntetické** canary starty cestami pokrytými S0
(vedle přímého startu i jobs/login/detached/race); snapshot fáze nesmí obejít gate. Jeden okamžitý
PID scan nemůže být oracle. Počet/opakování/race budget skutečného gate běhu určuje LAB, ne tento
malý pilot. Inertní startup text z P1 sám nedokazuje zamezení skutečné perzistence.

Automatická reconciliation pending intentu není implementovaná. Zachovaná karanténa prokazuje
bezpečné odmítnutí, ale nepokrývá recovery liveness ani „úspěšná obnova po každém pádu“.

## P4 — uzavření a úklid

Před odstraněním čehokoli zkontrolovat, že žádná operace neběží, oblast je fully-off, snapshoty
nejsou mounted a starý/new volume není aktuální potřebný binding nebo jediný recovery podklad.
Po úspěšném pilotu obnovit pouze předem zapsaný bezpečný testovací stav; potom může uživatel
odstranit přesně vlastní testovací snapshoty/targety/mounty v opačném pořadí závislostí.

Každý objekt musí odpovídat privátnímu allocation/identity receipt. Kolize, administrativní změna
nebo nejasná vazba znamená stop, nikoli smazání podle jména či obsahu. U `deleteSnapshot` zohlednit
`-wait` a dodatečně ověřit výsledek; neodvozovat uvolněné místo jen z exit 0. Ponechat neměnný
host journal, raw a manifest důkazu; nesmazat je jako součást restore unit.

Závěrečný oracle: žádný vlastní testovací proces, mount, aktivní nástroj nebo listener nezůstal;
žádná změna mimo explicitní testovací objekty; navrácené vlastní změny mají shodu s původními
receipts; případný konflikt je zapsaný a slot zůstává blokovaný. Publikovat nový run podle GUIDE,
nikoli doplňovat/přepisovat staré raw nebo VALIDATION-B4. Každý výsledek nese measured/derived/mock/
hypothesis a přesnou konfiguraci; gate uzavírá až nezávislé review.
