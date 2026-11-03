# spikes/s1-session — S1 neviditelná relace (WP1.A1)

Příprava brány S1 z [PLAN.md](../../PLAN.md#s1--neviditelná-relace-brána-celého-gui-návrhu): ověřit, že
tři skrytí uživatelé mají každý vlastní GUI relaci souběžně s tvou konzolí, že relace přežije odpojení
klienta a že v ní aplikace skutečně akcelerovaně renderují. **Brána celého GUI návrhu:** když macOS
souběžné relace nebo akcelerované renderování nedovolí, vývoj se zastaví k novému rozhodnutí
(DECISIONS F0.6).

Pokrývá případy GUI-01 až GUI-13 v [COVERAGE.md](../../docs/COVERAGE.md#31-gui--relace-a-coherence-s1-s2).
Běh a verdikt jsou WP1.A2 (slot L1).

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

Ověřeno v host konzoli (M5 Pro, macOS 27.2):
- offscreen 3,2 ms GPU na snímek, 0 neshod;
- prezentace 118 zobrazených snímků/s při 120 Hz;
- WebGL stránka v Electronu hlásí `ANGLE Metal Renderer: Apple M5 Pro` a akcelerovaný kontext.

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
stroj zapsaný v `docs/LAB.md` (WP0.5) a mít čerstvou zálohu. Testovací relace smějí obsahovat jen sondy
a požadované aplikace s prázdnými profily; žádné skutečné projekty ani účty.

### 0. Příprava protokolu

1. **[uživatel]** Sestav balík (jako ty, bez `sudo`):

   ```bash
   cd spikes/s1-session && swift build -c release
   ```

2. **[uživatel]** Založ adresář běhu, např. `RUN=docs/evidence/s1/2026-11-10-l1` s podadresáři `raw` a
   `state`.
3. **[uživatel]** **Před měřením** vyplň `environment.md` a `inputs.md` (GUIDE §7). Do `inputs.md` patří
   případy, oracle a cíle: čas přihlášení a RAM na relaci (F0.8, zatím otevřené), poměr GPU času relace
   vůči host konzoli, minimální zobrazené snímky/s a délka sledování 10 min.

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
   (`id -u`), např. `{"effectiveUID": 501, "onConsole": true}`, pak spusť:

   ```bash
   .build/release/sanjbox-s1-probe measure --expect "$RUN/inputs/expect-host.json" --case GUI-05 --log "$RUN/raw/s1-probe-host.jsonl"
   ```

### 3. Přežití bez klienta (GUI-02)

1. **[uživatel]** Zavři okno Sdílení obrazovky. Relaci neodhlašuj.
2. **[uživatel]** Počkej 10 minut a sleduj `observe-watch.tsv`: musí trvat `gui_domain=1` a procesy Dock
   i Finder.
3. **[uživatel]** Změř relaci bez připojeného klienta:

   ```bash
   sudo ./run-probe.sh --user snjt1 --run "$RUN" --case GUI-02 --apply
   ```

   Zobrazené snímky > 0 znamenají, že relace komponuje i bez klienta.
4. **[uživatel]** Ověř, že tvá konzole zůstala funkční.

Keeper (GUI-13) se zkoumá, jen pokud relace bez klienta nepřežije.

### 4. Tři relace (GUI-03, GUI-04)

1. **[uživatel]** Pro `snjt2` a `snjt3` spusť vlastní forwardery (`--listen 5912`, `--listen 5913`) a
   přihlas se stejně jako v kroku 2.
2. **[uživatel]** Změř všechny tři relace najednou, každou v jiném terminálu:

   ```bash
   sudo ./run-probe.sh --user snjt1 --run "$RUN" --case GUI-03 --apply
   ```

   Stejně pro `snjt2` a `snjt3`. Souběžně spusť i host sondu.
3. **[uživatel]** Zkus režim High Performance pro druhou relaci a zapiš chování (GUI-04). Brána nesmí
   stát na více než jedné High Performance relaci.

### 5. Aplikace (GUI-06 až GUI-09)

V relaci `snjt1`:

| Případ | Postup | Oracle |
|---|---|---|
| GUI-06 Xcode + Simulator | Nový projekt ze šablony, spuštění v Simulatoru | `sudo ./observe.sh`: `CoreSimulatorService` a `launchd_sim` pod UID 4501, Simulator vykresluje |
| GUI-07 Android Studio + emulátor | Vyžaduje stažení SDK a obrazu emulátoru do home testovacího uživatele; **jen s tvým schválením konkrétního stažení** | Emulátor běží s hardwarovou akcelerací; `qemu-system-*` pod UID 4501 |
| GUI-08 Electron | Libovolná nainstalovaná Electron appka; do DevTools konzole vlož obsah skriptu z `webgl-check.html`, nebo stránku otevři přímo | `acceleratedContext: true`, renderer s Apple GPU, snímky/s blízko frekvence displeje |
| GUI-09 Safari | Otevři soubor `webgl-check.html` (zkopíruj ho do `/Users/Shared` nebo k uživateli) | Totéž |

Safari a Electron v S1 běží bez síťové izolace (S3 ještě neprošla). Otevírej jen lokální soubory.

### 6. TCC (GUI-10)

1. **[uživatel]** V relaci `snjt1` otevři Terminal a spusť:

   ```bash
   "/Library/Application Support/Sanjbox/s1/bin/sanjbox-s1-probe" measure --request-screen-capture --case GUI-10 --log ~/s1-tcc.jsonl
   ```

2. **[uživatel]** Prompt Screen Recording musí být v relaci vidět a potvrditelný. Povol Terminal.
3. **[uživatel]** Odpoj klienta, znovu se připoj a spusť stejný příkaz bez `--request-screen-capture`.
   Výsledek: `screenCapture.preflight: true`.
4. **[uživatel]** Zkopíruj protokol do běhu:

   ```bash
   sudo cp /Users/snjt1/s1-tcc.jsonl "$RUN/raw/"
   ```

### 7. Čas přihlášení a RAM (GUI-12)

- **Cold login:** první přihlášení nového uživatele. **Warm login:** po odhlášení (v relaci Apple menu ›
  Odhlásit) a novém přihlášení.
- **Čas přihlášení** = od zapsaného kliknutí do prvního řádku `observe-watch.tsv` s `dock=1` a `finder=1`.
- **RAM relace** = `uidProcesses.physicalFootprintBytes` ze sondy plus nový proces `WindowServer` relace.
  Ten běží pod `_windowserver`, ne pod UID oblasti; najdeš ho v `observe.sh` ve výpisu WindowServer.

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

`cleanup.sh` odmítne běžet, dokud je Sdílení obrazovky zapnuté. Maže jen záznamy se značkou
`sanjbox-s1-test` a s očekávaným UID. Domovskou složku nemaže podle cesty; pokud ji `sysadminctl`
nesmaže, nahlásí to.

## Brána S1 (PLAN)

Body 1–5, 7 a 8 musí projít **ve třech souběžných oblastech** s funkční host konzolí; bod 6 proti předem
určeným cílům.

| Případ | Rozhodující důkaz |
|---|---|
| GUI-01 | Souběžně s tvou konzolí: `onConsole: false`, vlastní audit session, zobrazené snímky > 0 v relaci a zároveň funkční host konzole |
| GUI-02 | Po 10 min bez klienta `gui_domain=1`, Dock/Finder běží, sonda zobrazí snímky |
| GUI-03 | Tři platná měření ve stejném okně, tři různé audit session, host sonda souběžně |
| GUI-04 | Zapsané chování High Performance; tři relace bez spoléhání na něj |
| GUI-05 | Offscreen 0 neshod a GPU čas srovnatelný s host konzolí; zobrazené snímky/s; WebGL `acceleratedContext: true` |
| GUI-06–09 | Tabulka v kroku 5 |
| GUI-10 | Prompt viditelný a potvrditelný, `preflight: true` po znovupřipojení |
| GUI-11 | Každé měření `valid: true`; neplatné měření se opakuje, nikdy se nebere jako důkaz |
| GUI-12 | Časy a RAM proti cílům F0.8 |
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
