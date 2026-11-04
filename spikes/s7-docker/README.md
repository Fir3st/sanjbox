# S7 — offline příprava Dockeru (WP1.G2, částečně)

**64 scénářů × 3 oblasti, přísný návrhový manifest, offline plán a syntetické oracle.**
Skutečný Docker/VM runtime, důvěryhodný správce a integrační sondy chybí, proto **G2 zůstává
částečné**. S7, DK-01…10 i R4 zůstávají **Neověřeno**. Docker je mimo MVP podle C-002.
Žádný výstup tohoto balíku nemůže změnit stav brány, ani úplná shoda všech fixtures.

Pouze Python 3.9+ standard library. `s7.py` nevolá síť, subprocess, shell, Docker, Colimu, Limu,
Apple container, VM ani správce balíčků. Nemá `execute` ani `--apply`. Čte výslovně předané JSON
soubory, nikoli cesty deklarované v manifestu. `fixture_files.py --apply` vytváří/uklízí pouze
vlastní syntetický dočasný adresář pod běžným UID; ani tento program nic nespouští.

Východiska zůstávají neměnná: [G1 README](research/wp1-g1-runtime/README.md),
[primární zdroje G1](research/wp1-g1-runtime/SOURCES.md),
[úplná předregistrace a budoucí oracle L8](research/wp1-g1-runtime/VALIDATION.md),
[PLAN S7](../../PLAN.md#s7--docker), [GUIDE](../../docs/GUIDE.md).
Tento balík nepřezkoumává aktuální upstream verze ani nepovyšuje rešerši na runtime důkaz.
Provedené příkazy, výsledky a mezery: [VALIDATION.md](VALIDATION.md).

## Offline použití [implementátor]

Z kořene této větve:

```bash
/usr/bin/python3 -I -B spikes/s7-docker/s7.py inventory
/usr/bin/python3 -I -B spikes/s7-docker/s7.py validate
/usr/bin/python3 -I -B spikes/s7-docker/s7.py plan
/usr/bin/python3 -I -B spikes/s7-docker/s7.py oracle \
  --observations spikes/s7-docker/examples/observations.json
/usr/bin/python3 -I -B -m unittest discover -s spikes/s7-docker/tests -v
```

Všechny čtyři CLI vypisují JSON na stdout. Neplatný vstup skončí 2 bez tracebacku a bez částečného
reportu na stdout. Úspěšný exit 0 znamená úspěšné zpracování vstupu, **nikoli splněnou izolaci**.
`oracle` může vrátit mismatch/insufficient při exit 0; čti `counts`, `missing` a stav každé položky.

### Návrhový manifest

[examples/design.json](examples/design.json) je **synthetic-design-only**, ne produkční konfigurace
ani autorizační dokument. UID/GID 450–452/701–703, CID 1001–1003, `/S7-LAB-ONLY` a mock instance IDs
jsou ilustrační, nezjišťují místní uživatele. Přijímá přesně tři seřazené zóny t001/t002/t003:

- Různá UID/GID/CID, vlastní stav, projekt, prázdný klientský config a explicitní Unix socket.
  Builder musí mířit na vlastní daemon; žádný fallback ani cizí socket.
- Jen přesný vlastní projektový share. Host `/`, home, jiná oblast i read-only share jsou odmítnuty.
  Prázdné deklarované NIC a zakázaný obecný relay jsou požadavek tohoto návrhu, ne vlastnost Colimy.
- Oddělený host control root s deklarovaným root vlastníkem, zákazem zone write, launcher override
  a general relay. **Deklarace neověřuje skutečné vlastnictví, ACL, same-UID attach ani launcher.**
- Osm samostatných artifact pinů: runtime, CLI, Engine, BuildKit, kernel, initrd, guest image a probe
  image. Výchozí `null` je otevřený bod. Ani synteticky doplněný hash nedokazuje stažení či běh bytes.
- Budget je výchozí `unresolved`, všechny limity null. `synthetic-example` dovoluje jen modelový
  maximum-of-N výpočet (3–30 vzorků, ms); nemůže vyjádřit schválení F0.8. `approved` se odmítá.

Validator odmítá neznámá/duplicitní JSON pole, nekanonické/traversal cesty, sdílené identity a unsafe
mount/control deklarace. Úmyslně úzká schema není importér stock runtime YAML/TOML ani plný B3
APFS manifest. Symbolické cesty a deklarace nijak neskenuje. Soubor musí být regular, bez finálního
symlinku, ≤256 KiB; FIFO neblokuje čtení. JSON má limit hloubky 16, 24 000 uzlů, 512 prvků na pole,
2048 znaků na string, int64 čísla, bez floats/NaN/control znaků. Unix socket cesta má <104 bytů.

### Plán budoucích příkazů [uživatel, teprve L8]

`plan` vrací **15 argv polí**, pět pro každou oblast: `run`, offline `build`, přesné `-v /:/host`,
read-only varianta a `version`. Každý argument je samostatný string; není zde shell/eval ani runner.
Všechny položky mají `execute: false`, celý plán `executable: false` a seznam blokátorů.
Výchozí binárka `/S7-LAB-ONLY/bin/docker` a `sha256:UNRESOLVED` jsou **záměrně nepřipravené**.
Manifest SHA-256 svazuje plán a oracle. `candidate=apple-native` nedostane Docker argv;
`container run/build` nemůže být přejmenován na důkaz Engine API.

Plán není povolení spustit budoucí příkazy. Před L8 uživatel potřebuje prošlou S5, F0.8 s předem
schváleným budgetem/statistikou, LAB slot a zálohu, tři testovací relace a review runtime/topologie.
Každé živé sondě musí předcházet `sanjbox-whoami --expect` podle [common README](../common/README.md);
expectations se stanoví před během. Offline parser sám není sonda a credentials neměří.
Konkrétní image/binárky, jejich bytes/hashes a vlastní Linux `/s7-probe` musí být teprve připraveny
samostatnou reviewovanou změnou. Tento balík nemá download/install/provision/start/stop příkazy.

Budoucí spuštění používá čisté předregistrované prostředí, žádný zděděný Docker context/host/proxy,
SSH agent ani host auth helper. Prázdný per-zone config a explicitní socket jsou příprava,
nikoli enforcement proti útočícímu UID. `--network=none`/`--pull=never` v pozitivní offline variantě
neomezí zbytek daemon API a nenahrazuje DK-05/09. Build `RUN`, negotiation, attach/exec streamy,
registry a síťové adversarial případy zatím mají pouze inventář a oracle, nikoli živé sondy.

## Mapa připravených scénářů a mezer

`inventory` je autoritativní seznam přesných ID. Každé ID potřebuje jednu položku na každou ze tří
oblastí: **192 pozorování**. Counts v tabulce jsou scénáře, nikoli provedená runtime měření.

| DK / R | Počet | Offline příprava | K důkazu stále chybí |
|---|---:|---|---|
| DK-01 / R1,R4 | 5 | Run/build-copy/build-run/API hash + daemon oracle, remote-builder denial | Image/probe, skutečné run/build/streams a Engine/BuildKit negotiation |
| DK-02 / R4,R2 | 7 | Guest-root/project pozitivní model; host, cross-zone, RO, link a privileged negatives | Reálná host/guest topologie a nezávislé kanárky s read/write coverage |
| DK-03 / R4,R2 | 5 | Konfigurace, alternativní launcher, NIC, share-swap, guest-root control | Hostem chráněný správce; bypassy, TOCTOU a restart/crash enforcement |
| DK-04 / R4 | 6 | Vlastní/souběžný daemon, restart jedné oblasti; cizí/default/swapped socket | Tři skutečné UID/daemony/buildery, IPC peer identity, práva rodičů a globální služby |
| DK-05 / R3,R4 | 6 | Povolená gateway z kontejneru/buildu, direct/resolver/native-UID negatives | D1/S5 integrace, nezávislý packet capture, guest i nativní cesty |
| DK-06 / R4,R8 | 9 | Scoped registry mock + push/repo/realm/redirect/auth negatives, context/SSH/cache | Registry protokol, host auth boundary, symlink/TOCTOU, skutečné scopes jako uživatelský důkaz |
| DK-07 / R3,R4 | 6 | Povolený port, wildcard IPv4/IPv6, UDP, přímá guest IP, squatting | Vynucovaný ingress relay a měření host/LAN/B/C; loopback není autentizace |
| DK-08 / R4 | 5 | Typovaný toy frame, generic-connect/peer/size/replay negatives | AF_VSOCK/Unix transport, důvěryhodná peer identita, Docker HTTP streams a scan všech portů |
| DK-09 / R3,R4 | 11 | Flush anchor/all, disable pf, helper/gateway/manager/forwarder crash, sleep/wake, VPN, stale/revoke, recovery | Uživatelské systémové zásahy a nepřetržitý nezávislý záchyt NET-20…26 |
| DK-10 / R5 | 4 | Cold/warm/full-stop model, stop/restart denial, budget refusal | F0.8, skutečné časování/resources tří VM, zánik všech procesů/kanálů a lifecycle celého UID |

Guest `/` není automaticky macOS `/`. Kontrola host bytes musí vycházet ze skutečných shares.
Žádné NIC v návrhu není důkaz R3 nativní oblasti a neuzavírá otevřený C2 blokátor výpadku pf.
Původní G1 L8 plán navíc vyžaduje varianty a útoky mimo zjednodušená oracle pole tohoto balíku.

### Syntetické oracle

`oracle --manifest FILE --observations FILE` přijme pouze `synthetic-only` záznamy s přesným
manifest hashem. Chybějící/duplicitní/neznámé scenario+zone nemůže být vynechaný úspěch. `complete`
znamená pouze úplný seznam dodaných fixtures. Attempt, pozitivní kontroly před/po a úplné okno jsou
povinné bool hodnoty; numerické počty jsou nezáporné int, bool se za nulu nepřijme.

Pevná očekávání se neberou z dodaného reportu. Workload má očekávaný SHA-256 syntetického řádku
`S7_SYNTHETIC:ZONE:SCENARIO\n` a vlastní daemon ID; build-copy odpovídá vytvořenému `canary.txt`.
Files očekávají nulové chráněné bytes/writes a úplnou topologii. Control očekává nulové rozšíření
shares/NIC/endpointů a nezměněnou policy. Gateway očekává vlastní bránu/upstream, 32 modelových
bytů a žádnou direct cestu. Network očekává **nula zakázaných bytů i paketů**, úplný záchyt a ledger
IPv4/IPv6 TCP/UDP, DNS, mDNS, QUIC, ICMP. Žádné tyto hodnoty nejsou získané síťovým měřením.

Výsledky jsou `synthetic-match`, `synthetic-mismatch`, `insufficient`, nikdy Prošlo/Neprošlo brány.
Chybějící kontroly vedou na insufficient; dodaná pozitivní kontradikce (např. zakázaný byte nebo
živý proces po stopu) zůstane mismatch i při dalších mezerách. Neznámý F0.8 budget není úspěch.
Všechny reporty trvale obsahují `acceptance_status: Neověřeno` a totéž pro všech deset DK.
Vzor [observations.json](examples/observations.json) je záměrně smíšený/neúplný, nikoli důkaz stroje.

### Registry a vsock mocky

`registry_mock` je pure in-memory allow/deny model nad vyjmenovanými registry/repo/operation/realm/
redirect/client-auth poli. Povolen je pouze pull vlastního `zone/t00N/probe`, registry `.invalid`,
přesný mock auth realm, žádný redirect ani client auth. Neukládá ani negeneruje přihlašovací údaje.
[18 uložených případů](fixtures/registry-cases.json) zahrnuje tři oblasti a odmítnutí push, cizího
repa, auth realmu, redirectu a předaného auth. Nejde o HTTP server, OCI registry ani auth helper.

`MockVsockSession` je **toy protokol nad bytes v paměti**, ne skutečný vsock, Unix socket nebo
Docker API. Jediná operace `registry.pull`, pevná bound-zone/resource/generation, request ID,
limit frame 4096 B a 64 přijatých requestů, replay/revocation/unknown fields/truncation refusal.
`bound_zone` nastavuje test; není ověřeným peer credentialem. Testy generického connect/DNS/file
požadavku ukazují jen chování tohoto modelu. Half-close, stream multiplexing, reconnect, guest root
port scan, crash/queue draining a zabezpečená peer identita **nejsou implementované**.

## Vlastní fixtures a úklid [implementátor]

Výchozí příkazy nic nemění ani neotevírají cílové parent/root cesty:

```bash
/usr/bin/python3 -I -B spikes/s7-docker/fixture_files.py prepare --parent /private/tmp --zone t001
```

`--apply` pod běžným uživatelem vytvoří nový náhodný child `sanjbox-s7-fixtures-<32 hex>` s 0700.
V něm jsou pouze 0600 `Dockerfile` (`FROM scratch`, `COPY`), `canary.txt`, prázdný `config.json` a
vlastní `s7-state.json`. Před payloady zapíše původní stav „absent“ a identitu rootu, pak zaznamená
inode/device/UID/GID/mode každého svého souboru; fsync. **Dockerfile se nebuildí**. Není vytvořen
žádný home, socket, daemon, image ani cesta z návrhového manifestu. Root/setuid spuštění se odmítá.

Přesný vypsaný `root` předej jako jedinou cestu cleanupu (níže je záměrný placeholder):

```bash
/usr/bin/python3 -I -B spikes/s7-docker/fixture_files.py cleanup \
  --root /private/tmp/sanjbox-s7-fixtures-REPLACE-WITH-RETURNED-ID
```

Znovu výchozí dry-run; `--apply` provede jen vlastní cleanup. Skutečný ID musí být 32 hex znaků;
placeholder se odmítne. Není zde expanze globu ani rekursivní mazání. Cleanup ověří celý pevný
inventář před první změnou, bytes proti vlastnímu fixture, metadata, single link, regular typ a
no-follow čtení. Změna/extra soubor/poškozený journal/`planned` fáze = odmítnutí a ruční review.
Chybějící známý soubor dovolí dokončit přerušený cleanup. Nepřítomný root = idempotentní úspěch.

Ancestor traversal používá deskriptory a O_NOFOLLOW; každý předek musí být root/current-UID owned
bez group/other write, s výjimkou root-owned sticky tmp. Před mutation znovu kontroluje binding
parentu/rootu, při čtení obsluhuje short reads/EINTR a kontroluje metadata i pojmenovanou identitu.
**Podmínkou je vlastní exkluzivní namespace bez souběžných změn a bez rozšiřujících ACL.**
ACL tento nástroj nevyhodnocuje; mode bity nejsou důkaz absence ACL. Check+unlink/rmdir není CAS,
stejné UID může mezi kontrolami závodit. Nástroj není privilegovaný helper ani cleanup proti aktivnímu
útočníkovi. Pád po odstranění journalu může vyžadovat ruční review prázdného rootu; nic nedomýšlí.
Živé VM/pf/resolver/launchd a skutečný runtime stav tento cleanup vůbec neumí uklidit.

Testy používají vlastní `TemporaryDirectory` a po sobě je odstraní. `-I -B` nevytváří bytecode;
žádné `.build`, cache, archivy ani stažené runtime payloady nejsou potřeba.
