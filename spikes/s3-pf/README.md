# S3 — příprava pf experimentů (WP1.C1)

C1 dodává **přípravu**, nikoli výsledek S3/S3b: diagnostický deny anchor, transakční
`load.sh` / `unload.sh`, omezenou nativní sondu pod skutečným UID oblasti, transparentní
šablony a [laboratorní postup](L4-RUNBOOK.md). Žádné měření pf nebylo provedeno.
S3, S3b, NET-01…27, R3 a ochrana nezávislá na pf zůstávají **Neověřeno / Otevřený**.
Výpadek pf neřeší polling, SIGSTOP ani tento ruleset. C1 nezávisí na nepřijatých PR.

## Co lze spustit

| Součást | Rozsah |
|---|---|
| `templates/deny.pf.in`, `pf_lab.py`, `load.sh`, `unload.sh` | Pouze diagnostický zákaz TCP/UDP `in` i `out`, IPv4 i IPv6, pro 1–3 explicitní testovací UID. Žádný `pass`, redirect, global option, enable ani state flush. |
| `templates/transparent-v4.pf.in`, `transparent-v6.pf.in`, `renderer.py` | **Render-only hypotéza** `user → route-to → tag → rdr`, zúžená na jeden syntetický cíl/port. Loader ji odmítá; syntaxe i chování čekají na uživatelské L4. |
| `sanjbox-s3-probe` | Swift/POSIX TCP/UDP, doslovná IPv4/IPv6 adresa, syntetický kanárek, max. 32 odeslání / 20 s. Identita i přesná audit session se ověřují přímo v odesílajícím procesu před čtením cíle a otevřením socketu. |
| [NATLOOK-PLAN.md](NATLOOK-PLAN.md) | Návrh úzké autentizované služby, direction/tuple/original-target matice, fixtures a falsifikační experimenty. Žádný obecný privilegovaný ioctl endpoint. |
| [L4-RUNBOOK.md](L4-RUNBOOK.md) | Nezávislý oracle, start/restore, flush/disable, helper/gateway crash, sleep/wake/VPN, staré states/buffery/tunely, resolver a ingress. |
| `python-tests/`, `Tests/` | **Mockované PF/transport testy** a vlastní dočasné souborové fixtures. Nikdy skutečný pfctl, síťové sondy či změna UID. |

Diagnostický deny nepovoluje ani lokální bránu, ani same-zone dev server. Není náhradou
architektury PLAN, pouze malým kontrolním experimentem pro UID attribution. Povolit sdílený
port `127.0.0.1` by samo o sobě neautentizovalo oblast; případná brána musí samostatně
prokázat původ klienta a typed policy. Transparentní šablona takovou službu nedodává.

Lokální `pf.conf(5)` popisuje `user` také jako vlastníka příchozího listeneru a omezuje jej
na TCP/UDP. Historická hypotéza v PLAN o výhradně egress působnosti tedy není fakt, který
bychom zde předpokládali. Wildcard/loopback/socket-credentials chování se musí změřit.
Existující state může obejít nové hodnocení pravidel; reload není revokace. Podklady a
hranice každého tvrzení jsou v [SOURCES.md](SOURCES.md).

## [Implementátor] ověření bez sítě a bez pf

Z kořene repozitáře:

```bash
python3 -B -m unittest discover -s spikes/s3-pf/python-tests -v
bash -n spikes/s3-pf/load.sh spikes/s3-pf/unload.sh
spikes/s3-pf/load.sh --config spikes/s3-pf/fixtures/config.json --state /private/tmp/c1-example-state
spikes/s3-pf/unload.sh --config spikes/s3-pf/fixtures/config.json --state /private/tmp/c1-example-state
```

Oba dry-runy nevytvoří ani state adresář, nespustí příkaz, parser pf nebo přístup k `/dev/pf`.
Vypíší obsah zamýšlených pravidel a jediný měnící příkaz; nejsou preflight skutečného hosta.
`--dry-run` lze uvést výslovně, s `--apply` se vylučuje.

```bash
CLANG_MODULE_CACHE_PATH="$PWD/.build/c1-module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/c1-module-cache" \
swift test --package-path spikes/s3-pf --disable-sandbox \
  --scratch-path "$PWD/.build/c1-build" --cache-path "$PWD/.build/c1-cache"
```

Testy transport injektují; `sendCanary` nikdy nevolají. `--disable-sandbox` zde vypíná
SwiftPM sandbox sestavení v agentním prostředí, nikoli pf, macOS sandbox oblasti nebo systémovou ochranu.
Závislost je výhradně lokální [common](../common/README.md); common se nemění.

Příklad renderu hypotézy (jen stdout, žádný pfctl):

```bash
python3 -I -B spikes/s3-pf/renderer.py --family 4 --uid 4501 \
  --target 192.0.2.10 --target-port 18080 --gateway-port 18081 --run-id c1a00001
```

Adresy `192.0.2.10`, `2001:db8::10`, kanárek i audit IDs ve fixtures jsou ilustrativní.
Neoznačují běžící protistranu, živé účty ani platnou relaci.

## [Uživatel] předpoklady pro diagnostické `--apply`

Pouze rezervovaný L4 na laboratorním Macu se zálohou, hotovým S1/S0, syntetickými daty a
předem schváleným protokolem. Implementátor tuto část nespouští.

1. Přezkoumej zdroj a umísti skripty, `pf_lab.py`, `templates/deny.pf.in` a `config.json` do
   vlastní **root-owned** instalace, například `/Library/Application Support/Sanjbox/s3-c1`.
   Každá komponenta cesty musí být skutečný adresář, root-owned, bez group/world write a bez
   rozšířených ACL. Vstupy jsou regular single-link soubory; symlinky, hardlinky, FIFO,
   zařízení i rozšířené ACL se odmítají. Nepouštěj privilegovaně kopii zapisovatelnou oblastí.
   Skript nepřebírá autoritu hosta z `SUDO_UID` ani z proměnné prostředí.
2. `config.json` dovoluje schema 1, run ID 8–12 malých alfanumerických znaků a nejvýše tři
   různé účty `snjt1`…`snjt3` s různými číselnými UID 400…60000. Předem potvrď, že jde o
   vlastní syntetické účty S1; skript porovná jejich aktuální jmenné mapování. Názvy jiných
   účtů se nepřijímají. Run ID pro nový běh změň. Žádné vlastní command/template/path pole.
3. Vytvoř nový prázdný **root-owned 0700** adresář `state` u protokolu. Celá cesta splňuje
   stejné podmínky jako instalace. Použij skutečné cesty (`/private/var`, ne symlink `/var`;
   `/private/tmp` je pro apply nevhodné, protože je world-writable). Skript jej nevytváří.
4. Ručně deleguj pevný top-level filter anchor **`sanjbox_c1`**. Aktuální root filter display
   musí začínat přesně `anchor "sanjbox_c1" all`; call musí být jediný, nepodmíněný, bez
   wildcard. Vlastní anchor je původně prázdný: bez filter/NAT pravidel, tables i potomků.
   Nejde o `com.apple/*`. Umístění a případný zásah do host konfigurace jsou samostatný
   uživatelský plán s uloženým původním stavem, review a vlastním úklidem; loader je nedělá.
5. PF musí být již zapnutý. Žádný implicitní enable, reference token ani změna `/etc/pf.conf`.
   Uživatel ověří `set skip`, relevantní rozhraní, host pravidla/NAT a konflikt s VPN/system
   services. Pouhé nalezení anchor callu neprokazuje, že paket touto cestou projde.
6. Před **load i unload** zastav celé testovací relace/job domény, odvolej všechny start
   cesty a ukonči/drainuj práci brány a zprostředkujících služeb. Příznak `--lab-quiescent`
   je výslovné uživatelské potvrzení tohoto stavu a sériového slotu bez dalších PF writerů.
   Skript navíc odmítne jakýkoli proces s real/effective UID oblasti. Samotný snapshot `ps`
   není životní cyklus, bariéra proti novému startu ani důkaz prázdných kernelových bufferů.

Teprve potom **[uživatel]**, s vlastními absolutními cestami:

```bash
sudo '/Library/Application Support/Sanjbox/s3-c1/load.sh' \
  --config '/Library/Application Support/Sanjbox/s3-c1/config.json' \
  --state '/Library/Application Support/Sanjbox/c1-runs/c1a00001/state' \
  --apply --lab-quiescent
```

Před aplikací proběhne uživatelský `pfctl -n` parse pevné deny šablony. To je první reálný
parser check; testy jej mockují. Pouze `pfctl -a sanjbox_c1 -R -o none -f -` smí měnit systém.
Neznámá syntaxe, display formát, delegace nebo chyba skončí odmítnutím, nikoli fallbackem.

## [Uživatel] úklid, konflikt a přerušený běh

Po zastavení sond, oblastí, helperu/brány a odvolání startu spusť stejný příkaz s `unload.sh`.
Před úklidem znovu ověř identitu účtů, nezměněný parent a nepřítomnost cizích objektů.
Úklid nahraje **prázdný filter ruleset pouze do `sanjbox_c1`**, pouze pokud přesně odpovídá
vlastním pravidlům. Nikdy nevolá globální flush, disable, state kill, `-X`, přepis host
konfigurace ani zásah do parent/child anchors. Nemaže state soubory, instalaci ani testovací účty.

Záznamy `0001.json`… jsou append-only, fsync souboru i adresáře proběhne **před každou PF
mutací**. Fáze `prepared_load → loaded → prepared_unload → unloaded` uchovávají původní
status/root/leaf pravidla, NAT, children, tables, konfiguraci a hash renderu. Trvalý `lock`
chrání souběh těchto skriptů. Maximum 32 záznamů / 64 KiB na záznam; při limitu nebo chybě
zápisu před změnou se další mutace odmítne. Před mutací jsou vyžadovány dva volné sloty;
selhání I/O následného potvrzení ale může nastat i po úspěšné změně, proto zůstává prepared
záznam a následuje kontrolované zotavení, nikoli automatický rollback. Nedokončený/poškozený záznam je důvod k ručnímu review.

Pád po úspěšném loadu, ale před `loaded`, lze vyřešit stejným loadem (jen potvrzení) nebo
unloadem: vlastnictví se dokládá **předem** uloženou konfigurací, run-specific labely a
přesnými normalizovanými pravidly. Nečeká se na hash získaný teprve po mutaci. Pád po
prázdném reloadu je opakovatelný bez další PF změny. Již vyprázdněný anchor se zaznamená jako
prázdný, nikoli jako důkaz funkční ochrany; ztracená pravidla v `loaded` se automaticky nevracejí.

Cizí pravidlo, odlišné pořadí/label/UID, změněný parent, table/NAT/child, znovu objevená pravidla
po dokončeném úklidu, běžící UID nebo chybějící journal znamenají **REFUSED**. Ruční inspekce
není pokyn k plošnému flushi. Externí root writer může měnit PF mezi kontrolou a loadem:
CLI nemá compare-and-swap transakci s ostatními správci. Kontroly a lock tento fakt neřeší;
proto je sériový laboratorní slot skutečný předpoklad, nikoli záruka provozní bezpečnosti.

## Podklad měření pod UID

Sestavenou sondu a `common` nástroje podepisuje a nasazuje uživatel podle GUIDE/S8, bez
`get-task-allow`. Do relace oblasti patří jen přezkoumané binárky a syntetické fixtures.
`expect.json` je C1 envelope s `identity` (common `ProbeExpectation`) a **přesným**
`auditSessionID` z předem zapsané relace S1. Příklad má neplatná ilustrativní session IDs.
`--expect` přijme pouze `expect[-label].json`, `--input` pouze `probe[-label].json`, absolutní
cesty bez skrytých/credential složek, symlinků/hardlinků, special files, writable permissions
či ACL. V aktivním běhu se probe input/cíl čte až po úspěšné identitě. Připrav je root-owned
0644 v bezpečně průchozí laboratorní cestě; state journal zůstává root-only.

```text
[uživatel, v již ověřené Aqua relaci testovacího UID]
sanjbox-s3-probe --expect /ABS/expect.json --input /ABS/probe.json
sanjbox-s3-probe --expect /ABS/expect.json --input /ABS/probe.json --apply
```

Bez `--apply` neprobíhá capture ani socket. V aktivním běhu chyba identity = exit 3 a žádný
pokus o síť. Úspěšné přijetí dat lokálním kernelem i chyba socketu mají výsledek `unclear`:
verdikt dodává **nezávislá protistrana**, ne sender. Na rozdíl od prázdného očekávání jsou
povinné real/effective UID/GID, skupiny, zákaz staff/admin, Aqua manager, window UID,
nekonzolová relace, zakázaná host audit IDs a konkrétní audit session. Common se nemění.

Sonda je přípravný podklad pro nové i krátce existující TCP spojení/UDP, nikoli generátor
TLS/ECH/DNS/ICMP, plných send bufferů či tunelů. Tyto cesty mají zvláštní postup a doplnění
měřicího nástroje v L4. Nejsou automaticky pokryty ani vyhodnoceny pozitivním TCP testem.

## Stav ověření

Lokální vývoj: Apple Silicon arm64, macOS **27.2 (26B123)**; Swift build používá aktivní
Xcode/SDK, přesná verze je v [VALIDATION.md](VALIDATION.md). Runtime podpora není prokázána
na žádném buildu. Testy prokazují pouze níže uvedené mockované a souborové vlastnosti,
nikoli Darwin PF syntaxi, účinnost anchoru, NATLOOK, síťovou izolaci nebo kompatibilitu.
