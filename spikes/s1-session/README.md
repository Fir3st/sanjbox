# spikes/s1-session — S1 neviditelná relace (WP1.A1)

Příprava brány S1 z [PLAN.md](../../PLAN.md#s1--neviditelná-relace-brána-celého-gui-návrhu): ověřit, že
tři skrytí uživatelé mají každý vlastní GUI relaci souběžně s tvou konzolí, že relace přežije odpojení
klienta a že v ní aplikace skutečně akcelerovaně renderují. **Brána celého GUI návrhu:** když macOS
souběžné relace nebo akcelerované renderování nedovolí, vývoj se zastaví k novému rozhodnutí
(DECISIONS F0.6).

Pokrývá případy GUI-01 až GUI-13 v [COVERAGE.md](../../docs/COVERAGE.md#31-gui--relace-a-coherence-s1-s2).
Běh a verdikt jsou WP1.A2 (slot L1).
Metodika, navržené prahy a známé chybějící důkazy pro A2 jsou v [LAB.md](../../docs/LAB.md).
F0.8 je otevřené; tento návod dodává dílčí kroky, sám není úplnou akceptační sérií LAB-v1.

## Instrumentace připravená ve WP1.A2

Nový [runbook instrumentace](INSTRUMENTATION.md) popisuje `sanjbox-s1-instrument`: oddělenou lehkou
prezentaci, systémový RAM time-series recorder, strict identity/ASID, společný pevný harmonogram,
create-new per-UID výstupy a offline fixed-window výpočet. Výchozí režim je dry-run; nová cesta nevolá
TCC/preflight. A2/L1 zůstává **rozpracované**, LAB prahy jsou návrh a S1 zůstává Neověřeno.
Původní postupy níže jsou zachované pro kompatibilitu; samy nenahrazují nový časový recorder ani L1.

## Obsah

| Soubor | Kdo spouští | Co dělá |
|---|---|---|
| `create-users.sh` | uživatel, `sudo` | Vytvoří skryté uživatele `snjt1`–`snjt3` (UID 4501–4503), primární skupina `sanjbox` (GID 4500), mimo `staff`/`admin`. Náhodné heslo jde jen do tvé login Klíčenky. Přidá je do `com.apple.access_screensharing`. |
| `lan-guard.sh` | uživatel, `sudo` | pf anchor `com.apple/sanjbox-s1`: blokuje příchozí TCP/UDP na porty 22, 3283, 5900–5902 na všech rozhraních kromě `lo0` |
| `run-probe.sh` | uživatel, `sudo` | Spustí sondu jako testovací uživatel v jeho GUI relaci a uloží měření do protokolu běhu |
| `observe.sh` | kdokoli, `sudo` přidá launchd domény | Jen čtení: `who`, procesy testovacích UID, domény `gui/<uid>` a `user/<uid>`, listenery Sdílení obrazovky |
| `cleanup.sh` | uživatel, `sudo` | Odstraní testovací uživatele, položky Klíčenky, vlastní změny skupin a instalované binárky |
| `sanjbox-s1-probe` | `run-probe.sh`, nebo Terminal v relaci | Identita a relace, displeje, Metal, offscreen render s ověřením pixelů, prezentace snímků v okně, RAM procesů UID, Screen Recording |
| `sanjbox-s1-forward` | uživatel, bez `sudo` | Přeposílá `127.0.0.1:5901` na místní VNC server `127.0.0.1:5900`, aby se Screen Sharing.app připojil k vlastnímu Macu |
| `webgl-check.html` | v relaci oblasti | Lokální WebGL test pro Safari a Electron, bez sítě |
| `lib.sh` | — | Společná konfigurace a pomocné funkce skriptů |

Všechny měnící skripty mají výchozí **dry-run**: vypíšou, co by udělaly, a nic nezmění. Změny provedou jen
s `--apply`. Původní stav zapisují do `--state DIR` (adresář `state/` protokolu běhu).

### Proč forwarder místo SSH

PLAN počítá se SSH tunelem, protože Screen Sharing.app se k vlastnímu Macu přímo nepřipojí. Forwarder
dělá totéž na úrovni TCP, ale nechá Vzdálené přihlášení vypnuté, takže ubude jedna vstupní služba.
Poslouchá výhradně na `127.0.0.1` a jinou adresu neumí.

Pokud ho Screen Sharing.app odmítne, je to nález do protokolu. Pak platí postup z PLANu: Vzdálené
přihlášení jen pro tvůj účet a `ssh -L 5901:127.0.0.1:5900 <ty>@127.0.0.1`. Port 22 drží `lan-guard.sh`
mimo LAN.

## Sonda

```
sanjbox-s1-probe measure [--expect FILE] [--log FILE] [--case ID] [--render-seconds N] [--request-screen-capture]
sanjbox-s1-probe context
```

`measure` vypíše jeden řádek JSON (`S1Measurement`) a s `--log` ho připíše do souboru. Pořadí:

1. **Identita a relace** (`ProbeContext` ze `spikes/common`) proti očekávání. Nesoulad = neplatné měření,
   sonda nic dalšího neměří a skončí kódem 3 (GUI-11).
2. **RAM procesů UID**: `phys_footprint` z jádra, před vlastní zátěží sondy (GUI-12).
3. **Displeje** relace: body, pixely, škála (Retina = 2), obnovovací frekvence.
4. **Metal zařízení.** Sám výčet podle PLANu nic nedokazuje.
5. **Offscreen render:** 60 snímků 2048×2048, 512 iterací hashe na pixel přes render pipeline. Čas GPU
   (medián, p95) a ověření 4096 pixelů proti CPU referenci. Nulové neshody dokazují, že GPU práci opravdu
   provedl. Časy se porovnávají se stejnou sondou spuštěnou v host konzoli (GUI-05).
6. **Prezentace:** okno 960×600 v relaci, snímky přes `CAMetalLayer` po dobu `--render-seconds`. Počítá
   snímky, které window server **skutečně zobrazil** (`presentedTime > 0`), intervaly mezi nimi
   a viditelnost okna. Nula zobrazených snímků znamená, že relace nekomponuje (GUI-01, GUI-02, GUI-05).
7. **Screen Recording:** stav přístupu; s `--request-screen-capture` vyvolá prompt (GUI-10).

Sonda nic nehodnotí. Prošlo nebo neprošlo se rozhoduje až proti cílům zapsaným předem v `inputs.md`.
Selhání sekce (např. žádný Metal) je výsledek v `errors`, ne chyba sondy. Návratové kódy: 0 změřeno,
3 neplatné měření, 2 chyba použití.

Historická diagnostika v host konzoli (M5 Pro, macOS 27.2; původní záznam WP1.A1, bez přiloženého
neměnného protokolu běhu). Není to důkaz brány S1 ani měření M1 `LAB-janfiedler-01` z registru:
- offscreen 3,2 ms GPU na snímek, 0 neshod;
- prezentace 118 zobrazených snímků/s při 120 Hz;
- WebGL stránka v Electronu hlásí `ANGLE Metal Renderer: Apple M5 Pro` a akcelerovaný kontext.

Samostatná host diagnostika M1 (`LAB-janfiedler-01`, 2026-11-03) má vlastní
[protokol s raw a review](../../docs/evidence/s1/20261103T134131Z-janfiedler-LAB-janfiedler-01-r1-a8a26eeb/verdict.md).
Tři 5s pokusy: GPU medián přibližně 10,483 ms, pokaždé 0 neshod ze 4096 pixelů;
prezentace 96,6 / 99,0 / 99,8 fps na 100Hz hlavním externím displeji (1×). Tato série neměřila WebGL
ani tři izolované relace. M5 údaje výše zůstávají zachované, konfigurace nejsou přímo srovnatelný benchmark.

### Jak `run-probe.sh` sondu spouští

`launchctl asuser <uid>` převezme bootstrap namespace a audit session GUI relace uživatele; UID ani GID
nemění (launchctl(1)). `sudo -H -u <uživatel>` pak nastaví jeho credentials. Sonda ověří výsledek proti
očekávání, které skript zapíše **před** během do `inputs/expect-<uživatel>.json`:
- UID a GID 4501–4503 / 4500;
- členství v `sanjbox`, žádné `staff` ani `admin`;
- launchd doména `Aqua` daného UID;
- window server relace daného UID, mimo konzoli;
- audit session jiná než host konzole.

Binárka se instaluje do `/Library/Application Support/Sanjbox/s1/bin` (root, 0755): testovací uživatel
ji spustí, ale nevymění.

## Běh L1 (WP1.A2)

Kroky jsou označené **[uživatel]**, protože všechno, co mění systém, spouštíš ty. Před během musí být
stroj zapsaný v [LAB.md](../../docs/LAB.md), rezervovaný slot, čerstvou ověřenou zálohu a schválenou
předregistraci. [LAB §8](../../docs/LAB.md#8-připravenost-a2-a-mapování-s1) uvádí instrumentaci, která
pro úplný akceptační běh ještě chybí. Testovací relace smějí obsahovat jen sondy
a požadované aplikace s prázdnými profily; žádné skutečné projekty ani účty.

### 0. Příprava protokolu

1. **[uživatel]** Z kořene repozitáře nastav absolutní cesty, nové jedinečné run ID a sestav balík
   (jako ty, bez `sudo`). Alias a stroj nahraď svým veřejným záznamem z LAB:

   ```bash
   LAB_REPO_ROOT=$(git rev-parse --show-toplevel)
   LAB_AUTHOR=vas-verejny-alias
   LAB_MACHINE=LAB-vas-verejny-alias-01
   LAB_REVISION=r1
   LAB_RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-${LAB_AUTHOR}-${LAB_MACHINE}-${LAB_REVISION}-$(uuidgen | tr -d '-' | cut -c1-8)"
   RUN="$LAB_REPO_ROOT/docs/evidence/s1/$LAB_RUN_ID"
   mkdir -p "$LAB_REPO_ROOT/docs/evidence/s1"
   mkdir "$RUN" &&
     mkdir "$RUN/raw" "$RUN/state" "$RUN/inputs" &&
     cd "$LAB_REPO_ROOT/spikes/s1-session" &&
     swift build -c release
   ```

2. **[uživatel]** `mkdir "$RUN"` musí uspět jako vytvoření nového adresáře; existující běh nikdy
   nepoužij znovu. V dalších terminálech nastav stejnou absolutní hodnotu `RUN` pro tento běh.
3. **[uživatel]** **Před měřením** vyplň `environment.md` a `inputs.md` podle
   [šablony](../../docs/templates/lab/run.md) a LAB. Zafixuj commity, konfiguraci, workloads,
   credentials, oracle, délky, opakování a přijaté cíle F0.8. Chybějící cíle nebo recorder znamenají
   pouze dílčí diagnostický běh; bez nich nelze vyhodnotit kompletní S1.

### 1. Uživatelé a ochrana portů

1. **[uživatel]** Spusť dry-run a přečti si výstup:

   ```bash
   ./create-users.sh
   ```

2. **[uživatel]** Vytvoř uživatele:

   ```bash
   sudo ./create-users.sh --state "$RUN/state" --apply
   ```

   Hesla najdeš v aplikaci Klíčenka pod `sanjbox-s1` (účet `snjt1` …). Sondy je nikdy nečtou.
3. **[uživatel]** Zapni ochranu portů **dřív, než zapneš Sdílení obrazovky**:

   ```bash
   sudo ./lan-guard.sh --state "$RUN/state" --apply
   ```

4. **[uživatel]** Zapni Sdílení obrazovky: Nastavení › Obecné › Sdílení › Sdílení obrazovky. V (i)
   zkontroluj, že přístup mají jen testovací uživatelé. Vzdálená správa a Vzdálené přihlášení zůstanou
   vypnuté.
5. **[uživatel]** Z **jiného zařízení** v LAN ověř, že port je zavřený:

   ```bash
   nc -vz -w 3 <IP tohoto Macu> 5900
   ```

   Musí selhat; výstup ulož do `raw/lan-check.txt`. Test z tohoto Macu nic nedokazuje, protože vlastní IP
   jde přes `lo0`.
6. **[uživatel]** Ulož výchozí stav a spusť průběžné sledování:

   ```bash
   sudo ./observe.sh > "$RUN/raw/observe-before.txt"
   ```

   ```bash
   sudo ./observe.sh --watch 7200 > "$RUN/raw/observe-watch.tsv"
   ```

### 2. První relace

1. **[uživatel]** Spusť forwarder a nech ho běžet:

   ```bash
   .build/release/sanjbox-s1-forward --listen 5911
   ```

2. **[uživatel]** Připoj se a zapiš čas kliknutí do `raw/notes.md`:

   ```bash
   open vnc://127.0.0.1:5911
   ```

3. **[uživatel]** Přihlas se jako `snjt1`:
   - vyber přihlášení **do vlastní (virtuální) relace**, ne „požádat o sdílení“;
   - použij standardní režim, ne High Performance;
   - průvodce prvním spuštěním přeskoč bez přihlášení k Apple účtu.
4. **[uživatel]** Změř relaci (GUI-01, GUI-05, GUI-11):

   ```bash
   sudo ./run-probe.sh --user snjt1 --run "$RUN" --case GUI-05 --apply
   ```

   Pro srovnání změř i host konzoli. Předem zapiš `inputs/expect-host.json` se svým UID
   (`id -u`). Např. `{"effectiveUID": 501, "onConsole": true}` je **pouze minimální diagnostické
   očekávání**; pro akceptaci vyplň také skutečné/efektivní UID/GID, očekávané skupiny, bootstrap,
   window session a audit session podle LAB §3 a `ProbeExpectation` ze společné sady. Potom spusť:

   ```bash
   .build/release/sanjbox-s1-probe measure --expect "$RUN/inputs/expect-host.json" --case GUI-05 --log "$RUN/raw/s1-probe-host.jsonl"
   ```

### 3. Přežití bez klienta (GUI-02)

1. **[uživatel]** Zavři okno Sdílení obrazovky. Relaci neodhlašuj.
2. **[uživatel]** Počkej 10 minut a sleduj `observe-watch.tsv`: musí trvat `gui_domain=1` a procesy Dock
   i Finder. Pro kompletní GUI-02 podle LAB se ověřuje i kontinuita identit relací a prezentace během
   celého intervalu ve všech třech oblastech; jednorázová sonda na konci to nenahrazuje.
3. **[uživatel]** Změř relaci bez připojeného klienta:

   ```bash
   sudo ./run-probe.sh --user snjt1 --run "$RUN" --case GUI-02 --apply
   ```

   Zobrazené snímky > 0 dokládají kompozici v okamžiku sondy. O průběhu předchozích 10 minut nevypovídají.
4. **[uživatel]** Ověř, že tvá konzole zůstala funkční.

Keeper (GUI-13) se zkoumá, jen pokud relace bez klienta nepřežije.

### 4. Tři relace (GUI-03, GUI-04)

1. **[uživatel]** Pro `snjt2` a `snjt3` spusť vlastní forwardery (`--listen 5912`, `--listen 5913`) a
   přihlas se stejně jako v kroku 2.
2. **[uživatel]** Připrav instalaci binárky a očekávání pro všechny UID **sériově** přes `run-probe.sh`
   z kroku 2; tento launcher současně zapisuje do společné instalační cesty a společného JSONL.
   Nespouštěj jeho instalace souběžně. Pro samotné souběžné měření použij připravené Terminaly uvnitř
   jednotlivých relací a oddělené nové logy, např. v `snjt1`:

   V každém Terminalu nastav `LAB_RUN_ID` na přesné ID tohoto běhu z kroku 0 (bez založení nového ID).

   ```bash
   "/Library/Application Support/Sanjbox/s1/bin/sanjbox-s1-probe" measure --expect "/Library/Application Support/Sanjbox/s1/expect/snjt1.json" --render-seconds 60 --case GUI-03 --log "$HOME/${LAB_RUN_ID}-snjt1-concurrent-001.jsonl"
   ```

   V dalších relacích použij jejich vlastní očekávání; každý další pokus dostane nový název souboru.
   Souběžně běží host kontrola. Dolož skutečné společné okno jednotlivých fází podle LAB, nikoli pouze
   časy spuštění z terminálů. Výstupy pak uživatel přenese pod odlišnými názvy obsahujícími UID do
   `raw/` tohoto běhu. Tento příklad je diagnostika; chybějící časové řady pro akceptaci uvádí LAB §8.
3. **[uživatel]** Zkus režim High Performance pro druhou relaci a zapiš chování (GUI-04). Brána nesmí
   stát na více než jedné High Performance relaci.

### 5. Aplikace (GUI-06 až GUI-09)

V **každé ze tří současně aktivních relací**, podle profilů WX/WA/WE/WS/WM v LAB:

| Případ | Postup | Oracle |
|---|---|---|
| GUI-06 Xcode + Simulator | Nový projekt ze šablony, spuštění v Simulatoru | `sudo ./observe.sh`: `CoreSimulatorService` a `launchd_sim` pod UID odpovídající oblasti, Simulator skutečně vykresluje |
| GUI-07 Android Studio + emulátor | Vyžaduje stažení SDK a obrazu emulátoru do home testovacího uživatele; **jen s tvým schválením konkrétního stažení** | Emulátor skutečně vykresluje s hardwarovou akcelerací; proces emulátoru pod UID odpovídající oblasti |
| GUI-08 Electron | Předem určená nainstalovaná Electron appka; do DevTools konzole vlož obsah skriptu z `webgl-check.html`, nebo stránku otevři přímo | `acceleratedContext: true`, renderer s Apple GPU a viditelný měnící se výstup; počet rAF callbacků sám není počet prezentovaných snímků |
| GUI-09 Safari | Otevři soubor `webgl-check.html` (zkopíruj ho do `/Users/Shared` nebo k uživateli) | Totéž |

Safari a Electron v S1 běží bez síťové izolace (S3 ještě neprošla). Otevírej jen lokální soubory.

### 6. TCC (GUI-10)

1. **[uživatel]** V každé relaci otevři Terminal, nastav stejné `LAB_RUN_ID` a použij vlastní očekávání
   a jméno logu (příklad pro `snjt1`; všechna jeho opakování TCC v tomto běhu přibývají do tohoto logu):

   ```bash
   "/Library/Application Support/Sanjbox/s1/bin/sanjbox-s1-probe" measure --expect "/Library/Application Support/Sanjbox/s1/expect/snjt1.json" --request-screen-capture --case GUI-10 --log "$HOME/${LAB_RUN_ID}-snjt1-tcc.jsonl"
   ```

2. **[uživatel]** Prompt Screen Recording musí být v relaci vidět a potvrditelný. Povol Terminal.
3. **[uživatel]** Odpoj klienta, znovu se připoj a spusť stejný příkaz bez `--request-screen-capture`.
   Výsledek: `screenCapture.preflight: true`.
4. **[uživatel]** Zkopíruj protokol do běhu:

   ```bash
   sudo cp -n "/Users/snjt1/${LAB_RUN_ID}-snjt1-tcc.jsonl" "$RUN/raw/s1-tcc-snjt1.jsonl"
   ```

### 7. Čas přihlášení a RAM (GUI-12)

- **First-run** nového uživatele, **cold** připraveného profilu po restartu, **warm** opětovný login,
  reconnect a skutečné resume jsou rozdílné série ([LAB §5](../../docs/LAB.md#5-login-first-run-warm-a-resume-gui-12)).
- **Čas přihlášení:** od potvrzení přihlašovacího požadavku do první interaktivní plochy se správným
  kontextem. Dock/Finder jsou pouze mezníky. Sekundový watch nemá přesnost pro cíl < 2 s.
- **RAM:** systémový přírůstek celé konstrukce včetně WindowServerů/klientů podle
  [LAB §6](../../docs/LAB.md#6-ram-a-sdílené-služby-gui-12). Snapshot footprint UID je diagnostika a zahrnuje
  i sondu; nelze k němu přičíst RSS WindowServeru z `observe.sh` ani sdílený proces započítat vícekrát.

### 8. Úklid

1. **[uživatel]** V každé relaci se odhlas a zavři okna Sdílení obrazovky.
2. **[uživatel]** Zastav forwardery a sledování (`Ctrl-C`).
3. **[uživatel]** Vypni Sdílení obrazovky v Nastavení.
4. **[uživatel]** Spusť úklid:

   ```bash
   sudo ./cleanup.sh --state "$RUN/state" --apply
   ```

5. **[uživatel]** Odstraň ochranu portů:

   ```bash
   sudo ./lan-guard.sh --state "$RUN/state" --remove --apply
   ```

6. **[uživatel]** Ulož konečný stav:

   ```bash
   sudo ./observe.sh > "$RUN/raw/observe-after.txt"
   ```

   Účty musí být `absent`, skupina pro Sdílení obrazovky zpět ve stavu před během.

7. **[uživatel + reviewer]** Ověř i zbylé procesy testovacích UID, vlastní instalované objekty, listenery
   a obnovení vlastních změn služeb/pf. Konflikt nebo zbytek drží slot blokovaný. Po kontrole veřejných
   výstupů uzavři běh s manifestem hashů; přidej nový řádek do indexu S1 v [spikes.md](../../docs/spikes.md).
   Starší výsledky jiných vývojářů/strojů se nepřepisují; pravidla oprav a review stanoví LAB §3.

`cleanup.sh` odmítne běžet, dokud je Sdílení obrazovky zapnuté. Maže jen záznamy se značkou
`sanjbox-s1-test` a s očekávaným UID. Domovskou složku nemaže podle cesty; pokud ji `sysadminctl`
nesmaže, nahlásí to.

## Brána S1 (PLAN)

Body 1–5, 7 a 8 musí projít **ve třech souběžných oblastech** s funkční host konzolí; bod 6 proti předem
určeným cílům.

| Případ | Rozhodující důkaz |
|---|---|
| GUI-01 | Souběžně s tvou konzolí: `onConsole: false`, vlastní audit session, zobrazené snímky > 0 v relaci a zároveň funkční host konzole |
| GUI-02 | Kontinuita stejných session ID, domén/procesů a prezentace ve všech třech oblastech po celé 3×600 s bez klientů podle LAB; funkční host konzole |
| GUI-03 | Tři platná měření s doloženým souběhem relevantních fází, tři různé audit session, funkční host konzole |
| GUI-04 | Zapsané chování High Performance; tři relace bez spoléhání na něj |
| GUI-05 | Offscreen 0 neshod a párové GPU srovnání; prezentace a výpadky podle předem schválené LAB; WebGL jen podpůrně |
| GUI-06–09 | Tabulka v kroku 5 |
| GUI-10 | Prompt viditelný a potvrditelný, `preflight: true` po znovupřipojení |
| GUI-11 | Každé měření `valid: true`; neplatné měření se opakuje, nikdy se nebere jako důkaz |
| GUI-12 | Oddělené časové série a systémová RAM proti schváleným cílům F0.8/LAB; chybějící instrumentace není pass |
| GUI-13 | Jen pokud je keeper nutný: samostatně změřená konstrukce |

## Známá omezení přípravy

- **Části s `--apply` jsem nespouštěl**, protože vyžadují root a mění systém (GUIDE §3). Dry-runy, části
  bez rootu, sonda, forwarder a WebGL stránka jsou ověřené na vývojovém Macu; skripty projdou `bash -n`.
  První běh L1 je tedy zároveň prvním ověřením `--apply`. Selhání skriptu zapiš jako nález a běh nehodnoť.
- **Heslo v argumentech:** `sysadminctl` přijímá heslo jen jako argument, takže je během vytváření účtu
  krátce viditelné procesům na hostu. Threat model hostu důvěřuje a heslo odemyká jen prázdný testovací
  účet. Do Klíčenky jde heslo přes stdin `security -i`, ne jako argument.
- **Ochrana portů není trvalá:** po restartu Macu anchor zmizí. Před restartem vypni Sdílení obrazovky.
- **Credentials přes `sudo -u` v kontextu `launchctl asuser`:** když se audit session nebo bootstrap
  neshodují, sonda měření zneplatní (exit 3). Pak se měří přes Terminal v relaci jako v kroku 6.
- **Připojení přes forwarder** k vlastnímu Macu je hypotéza; záložní cesta je SSH tunel z PLANu.
