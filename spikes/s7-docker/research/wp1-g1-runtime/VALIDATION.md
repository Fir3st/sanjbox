# G2 / L8 — předem dané oracle pro DK-01…10

**Návrh testů, žádný provedený běh. Všech deset DK a S7: Neověřeno.**
Tento dokument připravuje WP1.G2, nemění [COVERAGE](../../../../docs/COVERAGE.md),
[F0.8](../../../../docs/DECISIONS.md) ani [LAB](../../../../docs/LAB.md).
Platí [PLAN S7](../../../../PLAN.md) a [GUIDE](../../../../docs/GUIDE.md).

## Před zahájením

**[implementátor, G2]** Připravit vlastní sondy/fixtures a skripty s výchozím dry-run, záznamem
původního stavu a idempotentním úklidem. Nepřebírat instalační/provisioning příkazy z upstream
šablon jako schválené: např. Lima Docker šablony obsahují stažení a spuštění instalačního skriptu.
Zdroj pro rešerši není oprávnění jej spustit. Připnout konkrétní runtime, CLI, Engine, BuildKit/buildx,
kernel config, initrd a guest image digests; nezaměnit poslední verzi upstreamu s verzí uvnitř VM.

**[uživatel, před L8]** Potvrdit F0.8 včetně Docker start/stop budgetu, konfigurace a statistik;
rezervovat L8 na zapsaném laboratorním stroji se zálohou a třemi testovacími oblastmi. S5 musí projít,
navazující souborová/lifecycle/IPC/síťová ochrana musí odpovídat této konfiguraci. Privilegované kroky,
konkrétní stažení balíčků a skutečnou integraci provádí/schvaluje uživatel podle GUIDE. Bez nich lze
pokračovat nezávislou přípravou, nikoli vyhlásit S7 pass. F0.5 nepovoluje Network Extension.

**[implementátor + uživatel]** Před každou variantou uložit neměnný run-id, commit kandidáta a vstupy:

- Tři různé macOS UID, skupiny, audit session a bootstrap domain; `sanjbox-whoami` na začátku každé
  sondy. Připnout i vlastníka VM/daemonu, host forwarderů, socketů a rodičovských adresářů.
- Manifest topologie: macOS host, oblast A/B/C, VM A/B/C a kontejnery jsou různé uzly. Vyjmenovat
  host shares, guest mounty, backing disks, config/runstate, image/build cache, Unix/XPC/vsock endpointy,
  všechny NIC a porty, registry/DNS cesty. Šifrovaný disk a read-only share nejsou vyloučení z testu.
- Předem přesné povolené operace: jen oblastí A autorizovaná S5 operace do mock upstreamu A a její
  testovací klient→dev server; žádné volné TCP/UDP, libovolný DNS dotaz, host/LAN/cross-zone přístupy.
  Guest root smí ovládat svůj Linux, nesmí rozšířit host datové a řídicí rozhraní.
- Syntetické unikátní kanárky: chráněný host home, další host kořen, jiná oblast, povolený projekt,
  guest root a build context mají rozdílné hodnoty. Nikdy skutečný obsah hosta/účtů. Souborové oracle
  porovnává fixture obsahy/hash a zápisové kanárky, nikoli výpis osobního stromu.
- Nezávislá protistrana a host laboratorní listenery pro IPv4/IPv6 TCP/UDP, autoritativní DNS fixture,
  packet capture pro ICMP a další kanály mimo rozsah `spikes/common`. Existující counterpart sám
  nedokazuje obsah TLS/ICMP; chybějící instrumentace znamená Nejasné.

U síťových negativních testů je oracle **nula zakázaných bajtů/paketů na protistraně**, včetně pokusu
o nepovolený DNS dotaz; samotná absence čitelného kanárku nestačí. Zaznamenat pokus i místo odmítnutí.
Pozitivní kontrola z kontrolovaného odesílatele před a po testu musí ověřit dosažitelnost protistrany
a záchyt; legitimní operace oblasti musí fungovat. Nefunkční síť nebo sonda není důkaz izolace.
UID mismatch, výpadek záchytu či chybějící kontrola zneplatní měření. Zjištěný průnik = Neprošlo;
chybějící mechanismus/důkaz = Nejasné. Žádný výsledek se nepovýší z dokumentace na runtime pass.

## DK-01 — Docker CLI/Engine run a build · R1, R4

- **Pozitivní:** pod každým UID současně použít skutečné připnuté `docker run` a `docker build`,
  izolované context/`DOCKER_CONFIG`, explicitní socket; fixture OCI image ověřeného digestu, výstup,
  exit code, stdout/stderr, stop signal, attach/exec stream a soubor z `COPY`. Offline build z `scratch`
  doplnit buildem s kontrolovaným `RUN`; ověřit skutečně zvolený BuildKit/buildx driver a session.
- **Negativní:** nesprávný socket/UID, nepodporovaná API verze, vzdálený context a jiný builder endpoint
  se odmítnou; žádný fallback na host Docker. Zachytit `/version`, API minimum/maximum a negotiation.
  Síťový build patří také do DK-05/09. Přepis `docker` na `container` ani úspěšný OCI pull není kontrola.
- **Oracle:** všechny výstupy mají předem daný fixture hash/exit code a patří správnému daemonu;
  žádná cizí oblast nemá nový objekt. Apple native `container run/build` zapisovat zvlášť jako
  kompatibilitní informaci; bez prokázaného Engine rozhraní DK-01 není Prošlo. [A01–A03, D05](SOURCES.md)

## DK-02 — `docker run -v /:/host` · R4 (hranice R2)

- **Pozitivní:** povolený projektový fixture mount a guest-root kanárek mají očekávaný obsah/práva.
- **Negativní:** přesně `-v /:/host`, explicitní chráněné host/cross-zone cesty, read-only varianta,
  symlink/hardlink a rekurzivní mount; testovat i `--privileged`, guest host namespaces a volume driver
  možnosti, pokud je API nabízí. Vše výhradně na laboratorních syntetických datech.
- **Oracle:** kontejner nezíská ani byte chráněného host/jiné oblasti a nezmění jejich kanárky.
  Guest `/` sám není únik; předem zakreslené macOS shares pod ním ano. Apple native host-volume
  variantu evidovat samostatně, ne podle očekávaného Linux stromu. [A10–A11, D01–D02](SOURCES.md)

## DK-03 — změna mount/control-plane konfigurace · R4 (hranice R2)

- **Pozitivní:** schválený nový share z kořene A provedený důvěryhodným správcem funguje jen v A.
- **Negativní:** UID A upraví user YAML/TOML, daemon config, prostředí, override/template, app-root,
  image/kernel/initrd a provisioning; obejde wrapper přímým API/launcherem, restartuje nebo vytvoří
  další profil; zkusí vložit share `/`, host home, cizí disk a symlink swap během kontroly cesty.
  Totéž z guest rootu. Samostatně zkusit přidat NIC či všeobecný vsock relay.
- **Oracle:** odmítnutí nebo změna pouze uvnitř povoleného guest prostoru; žádné rozšíření host shares,
  NIC, peer identity či host endpointů, ani po restartu/crash recovery. Root-owned soubor bez ochrany
  launcheru nesplňuje oracle. Zachovat důkaz, co oblast skutečně mohla změnit. [A04–A07, C02–C07](SOURCES.md)

## DK-04 — daemon/socket/runstate per oblast · R4

- **Pozitivní:** A/B/C vytvoří současně stejně pojmenovaný kontejner, síť, volume a image tag;
  každý seznam/stav je vlastní, restart A nemění B/C. Totéž pro buildery a klientské contexts.
- **Negativní:** UID A volá socket/XPC/vsock B, mění `DOCKER_HOST`, hledá legacy/default socket,
  přepíše socket symlink/runstate/pidfile, zkusí sdílený socket_vmnet a bootstrap endpoint.
  Zahrnout oprávnění rodičů, cache/global config a Apple DNS 2053/1053 při třech službách.
- **Oracle:** žádná neoprávněná operace ani identifikující fixture data B/C; správce spolehlivě váže
  operaci na peer a instanci, ne klientem zaslané zone-id. Žádná povinná globální služba nemá
  nekontrolovaný socket; DNS kolize nesmí skrytě přepnout na službu jiné oblasti. [A07–A09, C03–C06, L07](SOURCES.md)

## DK-05 — pouze brána oblasti · R3, R4

- **Pozitivní:** pull a typovaná povolená operace z kontejneru i build `RUN` mají log správné S5 brány
  a mock upstreamu; same-zone testovací server funguje. Rozlišit stahování klientem, host helperem,
  daemonem, guest resolverem a builderem, včetně fáze bootstrapu.
- **Negativní:** Internet/LAN/host/jiná oblast přes raw IP a hostname, IPv4/IPv6 ULA/link-local,
  TCP/UDP/QUIC/ICMP, `host.lima.internal`, `host.docker.internal`, změna route/DNS/proxy a guest firewallu,
  `--network host`, DNS/mDNS label s kanárkem, nepovolený auth realm/redirect/remote build context.
- **Oracle:** nula nepovoleného přenosu na všech protistranách; žádný host resolver nepředá libovolný
  dotaz jménem oblasti. U custom varianty doložit `networkDevices=[]` i skutečná guest zařízení,
  pak stále testovat všechny vsock služby. **Zvlášť** sondovat nativní macOS UID; úspěch guest části
  se nesmí vydávat za uzavření S3/WP1.C2. [L05–L08, V01–V02](SOURCES.md)

## DK-06 — registry auth a build context · R4, R8 (R2/R3)

- **Pozitivní:** mock scoped registry účet A smí jen schválený pull; mock helper rozlišuje A/B/C,
  povolený lokální context se přenese správně. Test s daty pouze syntetickými, bez čtení skutečné Klíčenky.
- **Negativní:** široký push/delete, cizí repo/registry, podvržený `WWW-Authenticate` realm, redirect,
  změna klientského helperu/PATH/configu, host SSH forwarding, build context `..`, symlink/TOCTOU,
  remote Git/submodules, remote tarball, build output/cache export s kanárkem mimo povolený cíl.
- **Oracle:** mock údaj hosta/B/C se neobjeví v A, vrstvě image, logu ani zakázaném upstreamu; žádná
  nepovolená operace. Údaj vložený do oblasti je kompromitovatelný, to se nesmí vyvracet mockem.
  Skutečné účty/scopes/revokace zůstávají zvláštním uživatelským důkazem před podporou integrace.
  `.dockerignore` a `DOCKER_CONFIG` nastavené útočníkem nejsou enforcement. [A12, D03–D04](SOURCES.md)

## DK-07 — published ports · R3, R4

- **Pozitivní:** autorizovaný testovací klient A dosáhne svého serveru přes schválenou cestu.
- **Negativní:** `-p PORT:PORT`, `127.0.0.1`, `0.0.0.0`, `[::1]`, `[::]`, konkrétní LAN IP, TCP/UDP,
  přímá guest IP bez `-p`, IPv6-only a dual-stack. Testovat z hosta, LAN i B/C; stejný port ve třech
  oblastech, port squatting, dynamickou změnu forwarderu a opětovný start.
- **Oracle:** nikdo mimo předregistrovanou policy nepřečte/nezmění fixture službu; záchyt a pozitivní
  klient dokazují funkčnost. Rozlišit bind v guest Docker síti a bind host forwarderu. Host loopback
  není per-UID autentizace, nepřítomnost TCP forwardu není důkaz pro UDP/IPv6. [A08, C05, L09, D06](SOURCES.md)

## DK-08 — vsock proxy · R4 (hranice R2/R3)

- **Pozitivní:** povolené Docker API streamy a typované operace fungují přes právě svou VM instanci.
- **Negativní:** guest root skenuje všechny dostupné vsock porty, mění peer/zone-id, žádá obecné
  `connect`/DNS/file open, host Unix socket a cizí VM; traversal, oversized/truncated frame,
  replay po revokaci, half-close/reconnect a pád peeru. Testovat i port/socket forwarding Lima/Apple,
  pokud je součástí kandidáta; existence vsock sama neznamená použití bezpečné proxy.
- **Oracle:** žádná operace mimo pevné schéma, autorizace navázaná na důvěryhodnou VM instanci,
  limitovaná data a zdroje, nepoškozené Docker streamy a nulový host/cross-zone přístup. Chybějící
  broker/bridge = Nejasné, nikoli přeskočený test; podporovanou alternativu musí posoudit review. [V02, L09](SOURCES.md)

## DK-09 — failure modes · R3, R4; NET-20…26

- **Pozitivní:** před i po každém zásahu autorizované operace A fungují; B/C a host drží očekávaný stav.
- **Negativní [uživatel provádí systémové zásahy]:** flush anchoru/rules/states, `pfctl -F all`, vypnutí
  pf, pád helperu, S5, VM manageru a DNS/port forwarderu, sleep/wake, VPN a změna sítě; po každém též
  revokace, restart a crash recovery. Nepřetržitě odesílat zakázané sondy; zahrnout již otevřená spojení,
  TLS tunely, send buffery, rozpracovaný pull/build, DNS požadavky a stará vsock spojení.
- **Oracle:** nula zakázaných bajtů/paketů v celém intervalu, včetně prvního paketu po zásahu a starých
  spojení; návrat provozu až po obnovení ověřené policy. Zastavení watchdogem po úniku není pass.
  Délku záchytu, časování zásahů a počet opakování předregistrovat; oddělit guest a nativní UID výsledky.

## DK-10 — start/stop a tři oblasti · R5, F0.8

- **Pozitivní:** současný start A/B/C vedle host konzole, předepsaný workload `run`/build v každé,
  cold boot i warm start odděleně; stop všech VM/daemonů/builderů/forwarderů, vyprázdnění front.
- **Negativní:** start/reconnect během stop, nový job/alternativní launcher po vypnutí, zastavený či
  odpojený proces, pád správce v každé fázi. Přepnutí z jedné na tři oblasti nesmí tiše sdílet daemon.
- **Oracle:** od uživatelova požadavku na start po úspěšný fixture run **přes vynucenou policy**;
  stop končí až po zániku runtime procesů/kanálů a neúspěšném opětovném spuštění. Měřit i celý UID
  lifecycle dle S0, ne pouze návrat `docker stop`. Zapsat rozdělení časů, RSS/phys_footprint VM a
  helperů, memory pressure/swap, vCPU, disk/cache a host odezvu; žádné sčítání nakonfigurované RAM
  vydávané za skutečnou spotřebu. Práh/statistiky určí **uživatel F0.8 před L8**. Bez nich lze vydat
  popisné výsledky, nikoli DK-10/S7 Prošlo.

## Uzavření běhu a úklid

**[uživatel + implementátor]** Vrátit jen změny konkrétního běhu podle uloženého původního stavu:
odstranit vlastní fixture uživatele/stav až po ověření zániku procesů, portů, socketů, VM a síťových
front; odvolat mock auth; vrátit vlastní resolver/pf/launchd zásahy, obnovit host síť a ověřit B/C.
Nekonfliktní úklid nesmí přepsat pozdější legitimní změnu. Neobnovený stav je viditelný blokátor úklidu.
G2 dodá konkrétní inventory a cleanup skript, tento text žádný systém nyní nemění.

Pro každý run-id uložit environment, předregistrované inputs/oracle, credentials sond, raw výstupy
včetně neúspěchů, logs protistran a topologii, verdict s R mapou a SHA-256 manifest. Zapsat novou
neměnnou evidenci dle GUIDE, nikdy nepřepisovat starý běh. S7 lze uzavřít teprve review všech DK,
platného F0.8 a neotevřených blokátorů příslušné konstrukce; hotová rešerše G1 to nenahrazuje.
