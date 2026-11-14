# Sanďbox — coverage plán

Jedno místo, kde je vidět, co je hotovo a co ne. Vztah vrstev:

```
požadavek (R1–R8)  ←  brána (S0–S8, F2–F4)  ←  testové případy (T-…)  ←  protokoly v docs/evidence/
                                              ←  pracovní balíky (WP…) dodávají kód, sondy a skripty
```

- **Stav testu / brány / požadavku** (PLAN §Akceptační kontrakt): `Neověřeno` · `Prošlo` · `Neprošlo` · `Nejasné`.
  Prošlo vyžaduje odkaz na protokol. Nejasné = chybí mechanismus, platné měření nebo důkaz.
- **Stav balíku:** `⬜ nezahájeno` · `🟨 rozpracováno` · `✅ hotovo` · `⛔ blokováno` (s důvodem).
- Hotový balík neznamená prošlou bránu. Požadavek se odvozuje z bran, nikdy se nenastavuje přímo.
- Postup aktualizace: [GUIDE.md §10](GUIDE.md#10-jak-aktualizovat-coverage).

Poslední aktualizace: 2026-11-14 (podklad `main` `4ad05d9` po H4 [#79](https://github.com/Fir3st/sanjbox/pull/79),
částečném A3 [#78](https://github.com/Fir3st/sanjbox/pull/78) a dílčím A6 [#77](https://github.com/Fir3st/sanjbox/pull/77);
A6 dodává H1 wire fuzzer a syntetické service workflow. H1–H6 jsou hotové offline, A2/A3/A6 zůstávají
rozpracované; vlastníci, další kroky a podmínky jsou v [IMPLEMENTATION §0](IMPLEMENTATION.md#0-co-dál)). F0.7/C-003 a F0.8/LAB-v1 jsou rozhodnuté
podle [DECISIONS](DECISIONS.md); Docker start/stop zbývá před S7. Žádná brána ani akceptační případ neprošly.

**Rozsah MVP (F2):** CLI + jedno okno s plochou oblasti, bez Dockeru, data ven jen řízeným exportem.
R4 a R6 zůstávají požadavky produktu (F3, F4); MVP je nesplňuje.

## 0. Souhrn

| Oblast | Celkem | Prošlo | Neprošlo | Nejasné | Neověřeno |
|---|---|---|---|---|---|
| Požadavky R1–R8 | 8 | 0 | 0 | 0 | 8 |
| Brány F1 (S0–S8 vč. S3b) | 10 | 0 | 0 | 0 | 10 |
| Testové případy | 155 | 0 | 0 | 0 | 155 |
| Rozhodnutí F0 | 8 | — | — | — | 8 rozhodnuto; Docker start/stop (F0.8) otevřený do S7 |

| Balíky | Celkem | ✅ | 🟨 | ⬜ | ⛔ |
|---|---|---|---|---|---|
| F0 | 5 | 5 | 0 | 0 | 0 |
| F1 | 36 | 22 | 5 | 9 | 0 |
| F2 | 12 | 0 | 0 | 12 | 0 |
| F3 | 6 | 0 | 0 | 6 | 0 |
| F4 | 4 | 0 | 0 | 4 | 0 |

Souhrn počítá zdejší řádky §4 včetně dokončených offline H3/H4/H6. Jejich testy nepromítají
syntetické výsledky do akceptace; všech 10 bran a 155 případů zůstává Neověřeno. Zbývající
příprava A2/A3/A6 má původní vlastníky, D5 čeká na rozhodnutí a G2 zůstává zmrazené podle
IMPLEMENTATION §0; hotové H prototypy nejsou běžící oblast ani vstup do F2.

## 1. Požadavky

| Požadavek | Rozhodující brány | Testové skupiny | Stav |
|---|---|---|---|
| R1 X oblastí, agenti, nástroje, Xcode, Android, Docker | S1, S6, S7, F2 | GUI-01…13, HB, DK, POS | Neověřeno |
| R2 Žádný přístup k host datům, identitě, jiným oblastem; nepřežije vypnutí | S0, S4, S8, F2 | FS, ID, LC, RB, SG | Neověřeno; blokátory otevřené |
| R3 Žádný nekontrolovaný únik do sítě | S3, S3b, S5, F2 | NET, GW | Neověřeno; blokátory otevřené; oblasti s předplatným/OAuth omezeny změnou C-003 |
| R4 Docker bez únikové cesty | S7, F4 | DK | Neověřeno; mimo MVP (C-002) |
| R5 Nativní výkon, bez desktopové VM, rychlé zapnutí/vypnutí | S1, S2, F2 | GUI-12, GUI-17, PERF | Neověřeno |
| R6 Jednotlivá okna v Docku, rozlišitelná oblast | S2, F3 | GUI-14…24 | Neověřeno; mimo MVP (C-001), MVP: POS-08 |
| R7 Práce s projektem, řízený import, testování, obnova | S4, F2 | RB, FS-10…12, POS-09 | Neověřeno |
| R8 Agnostičnost bez bezpečnostního bypassu | S5, S6 | GW-12…19, HB | Neověřeno |

## 2. Brány

| Brána | Rozsah | Testy | Závisí na | Stav | Verdikt |
|---|---|---|---|---|---|
| F0 | Rozhodnutí 1–8 | — | — | 8 rozhodnuto; Docker start/stop do S7 | [DECISIONS.md](DECISIONS.md) |
| S1 | Neviditelné relace | GUI-01…13 | F0, WP0.3 | Neověřeno | — |
| S0 | Hranice a attack surface | FS-01…09, ID-01…11, LC-01…11 | S1 | Neověřeno | — |
| S8 | Signing, TCC, broker | SG-01…11 | S1 | Neověřeno | — |
| S4 | Zpevnění, mounty, rollback | FS-10…11, RB-01…10 | S0 | Neověřeno | — |
| S3 | pf a failure modes | NET-01…09, NET-13…27 | S0 | Neověřeno | — |
| S3b | Ingress a loopback | NET-10…12 | S0 | Neověřeno | — |
| S5 | Typované brány | GW-01…20 | S3 (integrace) | Neověřeno | — |
| S6 | Homebrew per oblast | HB-01…07 | S4 | Neověřeno | — |
| S2 | Coherence (mimo MVP, C-001) | GUI-14…24 | S0, S8 | Neověřeno | — |
| S7 | Docker (mimo MVP, C-002) | DK-01…10 | S5, budget F0.8 | Neověřeno | — |
| Vstup F2 | S0, S1, S3, S3b, S4, S5, S6, S8 prošly | — | — | Neověřeno | — |
| F2 | Jádro = MVP v rozsahu C-001/C-002 | Escape 1–4, 7–11; POS-08…09, FS-12 | Vstup F2 | Neověřeno | — |
| F3 | Coherence produkčně | Escape 2, 8; POS-06…07 | F2, S2 | Neověřeno | — |
| F4 | Docker, zařízení, git | Escape 5, 6 | F3, S7 | Neověřeno | — |

## 3. Testové případy

Sloupec **Esc** odkazuje na kapitolu PLAN §Verifikace. Případy jsou syntetické (kanárky, mocky);
reálné integrace se evidují zvlášť a mají ve sloupci poznámku „uživatelský důkaz“.

### 3.1 GUI — relace a Coherence (S1, S2)

| ID | Případ | R | Brána | Esc | Stav | Důkaz |
|---|---|---|---|---|---|---|
| GUI-01 | Relace oblasti vznikne souběžně s host konzolí (ne fast user switching) | R1, R5 | S1 | 7 | Neověřeno | |
| GUI-02 | Relace přežije 10 min bez klienta (bez keeperu / s keeperem zvlášť) | R1 | S1 | 7 | Neověřeno | |
| GUI-03 | Tři relace současně vedle funkční host konzole | R1 | S1 | 7 | Neověřeno | |
| GUI-04 | Ověření limitu High Performance Screen Sharing; tři relace bez spoléhání na HP | R1 | S1 | 7 | Neověřeno | |
| GUI-05 | Skutečně akcelerované renderování v každé relaci (ne jen výčet Metal zařízení) | R1, R5 | S1 | 7 | Neověřeno | |
| GUI-06 | Xcode + Simulator v relaci; CoreSimulatorService pod UID oblasti | R1 | S1 | 6 | Neověřeno | |
| GUI-07 | Android Studio + emulátor v relaci | R1 | S1 | 6 | Neověřeno | |
| GUI-08 | Electron appka v relaci | R1 | S1 | 6 | Neověřeno | |
| GUI-09 | Safari v relaci | R1 | S1 | 6 | Neověřeno | |
| GUI-10 | TCC prompt viditelný a potvrditelný; granty přetrvají po odpojení klienta | R1, R6 | S1 | 2 | Neověřeno | |
| GUI-11 | UID/GID, skupiny a session sond odpovídají očekávání ve všech měřeních | R2 | S1 | — | Neověřeno | |
| GUI-12 | Čas přihlášení cold/warm, RAM na relaci proti cílům design card | R5 | S1 | 7 | Neověřeno | |
| GUI-13 | Keeper (pokud je nutný): režie, souběh, chování po pádu klienta | R1 | S1 | 7 | Neověřeno | |
| GUI-14 | Samostatná proxy okna: více oken, překryvy, skrytá okna, přesun, resize | R6 | S2 | 6 | Neověřeno | |
| GUI-15 | Menu a popovery navázané na správné okno | R6 | S2 | 6 | Neověřeno | |
| GUI-16 | IME a routing klávesových zkratek | R6 | S2 | 6 | Neověřeno | |
| GUI-17 | Input-to-photon 30–50 ms při 60 fps ve třech souběžných oblastech | R5, R6 | S2 | 7 | Neověřeno | |
| GUI-18 | 3× stejná appka ze 3 oblastí jako 3 položky v Docku s odznakem | R6 | S2/F3 | 6 | Neověřeno | |
| GUI-19 | Secure input (samostatný test, ne gate) | R6 | S2 | 6 | Neověřeno | |
| GUI-20 | Notifikace (samostatný test, ne gate) | R6 | S2/F3 | 6 | Neověřeno | |
| GUI-21 | File open/save dialogy (samostatný test, ne gate) | R6 | S2/F3 | 6 | Neověřeno | |
| GUI-22 | Drag & drop (samostatný test, ne gate) | R6 | F3 | 6 | Neověřeno | |
| GUI-23 | Tisk a audio (samostatný test, ne gate) | R6 | F3 | 6 | Neověřeno | |
| GUI-24 | Retina a rozlišení podle host monitoru | R6 | S2 | 6 | Neověřeno | |

### 3.2 FS — soubory (S0, S4)

| ID | Případ | R | Brána | Esc | Stav | Důkaz |
|---|---|---|---|---|---|---|
| FS-01 | Kanárek v chráněném home nečitelný z oblasti | R2 | S0/S4 | 1 | Neověřeno | |
| FS-02 | Kanárek v pracovním kořeni (`~/Work` apod.) nečitelný | R2 | S0/S4 | 1 | Neověřeno | |
| FS-03 | Sdílené cesty (`/Users/Shared`, `/tmp`, `/Library/Caches`): kanárky a zákaz zápisu | R2 | S0/S4 | 1 | Neověřeno | |
| FS-04 | Testovací externí disk (APFS, exFAT/FAT) a Time Machine nedostupné, i odemčené | R2 | S4 | 1, 9 | Neověřeno | |
| FS-05 | Kanárek v jiné oblasti nečitelný | R2 | S0 | 1 | Neověřeno | |
| FS-06 | Zákaz zápisu do host nástrojů a startup kořenů (`/opt/homebrew`, LaunchAgents, …) | R2 | S0/S4 | 1 | Neověřeno | |
| FS-07 | Hardlink na chráněný kanárek nejde vytvořit/zneužít | R2 | S0/S4 | 1 | Neověřeno | |
| FS-08 | Symlink zpracovaný helperem nevede mimo ověřený kořen | R2 | S4/S8 | 1, 8 | Neověřeno | |
| FS-09 | Metadata služeb (`ps`, `mdfind`, `log show`, `netstat`, `system_profiler`/`ioreg`, `dscl`) nevydají testovací host data | R2 | S0 | 1 | Neověřeno | |
| FS-10 | Průběžná ochrana: vytvoření/přesun/obnova kanárku za běhu oblasti bez okna přístupu | R2, R7 | S4 | 9 | Neověřeno | |
| FS-11 | Nový install a nový/odemčený mount za běhu nezavedou přístupnou cestu | R2, R7 | S4 | 9 | Neověřeno | |
| FS-12 | Host nemá ACL ani jiný přímý přístup ke svazku oblasti; data ven jen exportem (F0.3) | R2, R7 | S4/F2 | 1 | Neověřeno | |

### 3.3 ID — identita, IPC, TCC (S0)

| ID | Případ | R | Brána | Esc | Stav | Důkaz |
|---|---|---|---|---|---|---|
| ID-01 | Klíčenka: mock + oddělení login keychainu (uživatelský důkaz pro reálné oddělení) | R2 | S0 | 2 | Neověřeno | |
| ID-02 | Host schránka s kanárkem nečitelná | R2 | S0 | 2 | Neověřeno | |
| ID-03 | Host obrazovka s kanárkem: SCK a `CGWindowListCopyWindowInfo` cross-session | R2 | S0 | 2 | Neověřeno | |
| ID-04 | Události do host relace: `CGEventPostToPid`, `AXUIElementCreateSystemWide` | R2 | S0 | 2 | Neověřeno | |
| ID-05 | `ptrace` / attach na host procesy a agenta | R2 | S0/S8 | 2 | Neověřeno | |
| ID-06 | `open -a Terminal` spustí jen v relaci oblasti | R2 | S0 | 2 | Neověřeno | |
| ID-07 | Inventura globálních XPC/Mach služeb; žádná známá neoprávněná operace | R2 | S0 | 2 | Neověřeno | |
| ID-08 | TCC Accessibility a Screen Recording působí jen v relaci oblasti | R2 | S0 | 2 | Neověřeno | |
| ID-09 | TCC Input Monitoring, mikrofon, kamera, Bluetooth: test + politika | R2 | S0 | 2 | Neověřeno | |
| ID-10 | AppleEvents a notifikace směrem do host relace | R2 | S0 | 2 | Neověřeno | |
| ID-11 | Testovací agent/socket hosta (ssh-agent styl) nedostupný | R2 | S0 | 2 | Neověřeno | |

### 3.4 LC — životní cyklus a perzistence (S0, F2)

| ID | Případ | R | Brána | Esc | Stav | Důkaz |
|---|---|---|---|---|---|---|
| LC-01 | LaunchAgent oblasti po vypnutí neběží | R2 | S0 | 3 | Neověřeno | |
| LC-02 | cron/at úlohy oblasti po vypnutí neběží (deny soubory s uživatelskými jmény) | R2 | S0 | 3 | Neověřeno | |
| LC-03 | Login item / SMAppService agent oblasti neobejde životní cyklus | R2 | S0/S8 | 3 | Neověřeno | |
| LC-04 | Job v `user/<uid>` doméně po vypnutí neběží | R2 | S0 | 3 | Neověřeno | |
| LC-05 | Odpojený CLI proces po vypnutí neběží; vypnuto = nula procesů UID | R2 | S0 | 3 | Neověřeno | |
| LC-06 | Start během vypínání i po něm neprojde | R2 | S0 | 3 | Neověřeno | |
| LC-07 | Fork/job race při pauze: stabilní quiescence celého UID | R2 | S0/S4 | 3 | Neověřeno | |
| LC-08 | Pád helperu/řídicí komponenty neobejde vypnutý stav | R2 | S0 | 3 | Neověřeno | |
| LC-09 | Přihlášení přes SSH/Screen Sharing do vypnuté oblasti neprojde | R2 | S0 | 3 | Neověřeno | |
| LC-10 | Privilegovaný LaunchDaemon nejde autorizovat z oblasti | R2 | S0/S8 | 3 | Neověřeno | |
| LC-11 | UID se nepřidělí znovu před dokončením úklidu | R2 | F2 | 3 | Neověřeno | |

### 3.5 NET — síť (S3, S3b)

| ID | Případ | R | Brána | Esc | Stav | Důkaz |
|---|---|---|---|---|---|---|
| NET-01 | LAN cíl: nula bajtů na protistraně | R3 | S3 | 4 | Neověřeno | |
| NET-02 | Host localhost služba nedosažitelná | R2, R3 | S3 | 4 | Neověřeno | |
| NET-03 | Jiná oblast nedosažitelná | R2, R3 | S3 | 4 | Neověřeno | |
| NET-04 | Nepovolená doména | R3 | S3 | 4 | Neověřeno | |
| NET-05 | Raw IP / IP literál | R3 | S3 | 4 | Neověřeno | |
| NET-06 | SNI s cizí IP | R3 | S3 | 4 | Neověřeno | |
| NET-07 | Přímé TLS na vázanou doménu mimo bránu | R3 | S3 | 4 | Neověřeno | |
| NET-08 | `route-to` + `tag` → `rdr tagged`; tag přežije `lo0` | R3 | S3 | 4 | Neověřeno | |
| NET-09 | `DIOCNATLOOK` přes úzkou službu helperu | R3 | S3 | 4 | Neověřeno | |
| NET-10 | Ingress na wildcard listener IPv4/IPv6 z hosta, LAN a jiné oblasti | R2, R3 | S3b | 4 | Neověřeno | |
| NET-11 | Port squatting na host port | R2, R3 | S3b | 4 | Neověřeno | |
| NET-12 | Pozitivní same-zone dev server bez přístupu k cizím listenerům | R3, R7 | S3b | 4 | Neověřeno | |
| NET-13 | SSRF / DNS rebinding na loopback, RFC1918, link-local | R3 | S3/S5 | 4 | Neověřeno | |
| NET-14 | ECH fail-closed | R3 | S3/S5 | 4 | Neověřeno | |
| NET-15 | Non-TLS provoz podle explicitní policy | R3 | S3/S5 | 4 | Neověřeno | |
| NET-16 | DNS přes systémový resolver a mDNS: žádný kanárek na protistraně | R3 | S3 | 4 | Neověřeno | |
| NET-17 | ICMP datový kanál | R3 | S3 | 4 | Neověřeno | |
| NET-18 | AirDrop / APNs kanály | R3 | S3 | 4 | Neověřeno | |
| NET-19 | QUIC / UDP 443 blokované | R3 | S3 | 4 | Neověřeno | |
| NET-20 | Flush anchoru/pravidel/states: nula zakázaných bajtů | R3 | S3 | 4 | Neověřeno | |
| NET-21 | `pfctl -F all`: nula zakázaných bajtů | R3 | S3 | 4 | Neověřeno | |
| NET-22 | Vypnutí pf: nula zakázaných bajtů (ochrana nezávislá na rulesetu) | R3 | S3 | 4 | Neověřeno | |
| NET-23 | Pád helperu / brány | R3 | S3 | 4 | Neověřeno | |
| NET-24 | Sleep/wake, VPN, změna sítě | R3 | S3 | 4 | Neověřeno | |
| NET-25 | Staré states, send buffery, tunely brány po odvolání | R3 | S3 | 4 | Neověřeno | |
| NET-26 | Revokace operace a opětovný start: starý průchod nepřežije | R3 | S3 | 4 | Neověřeno | |
| NET-27 | IPv6 link-local/ULA, `awdl0`/`llw0` | R3 | S3 | 4 | Neověřeno | |

### 3.6 GW — typované brány a artefakty (S5)

| ID | Případ | R | Brána | Esc | Stav | Důkaz |
|---|---|---|---|---|---|---|
| GW-01 | Cooldown filtru packumentu (verze před/po hranici) | R3 | S5 | 10 | Neověřeno | |
| GW-02 | Přímá tarball URL bez předchozího packumentu | R3 | S5 | 10 | Neověřeno | |
| GW-03 | Lockfile / `npm ci` s verzí v cooldownu | R3 | S5 | 10 | Neověřeno | |
| GW-04 | Redirect na CDN | R3 | S5 | 10 | Neověřeno | |
| GW-05 | Vydání z cache brány znovu kontrolované | R3 | S5 | 10 | Neověřeno | |
| GW-06 | Neznámé datum publikace = odmítnuto | R3 | S5 | 10 | Neověřeno | |
| GW-07 | Scoped packages | R3, R8 | S5 | 10 | Neověřeno | |
| GW-08 | `PUT`/`DELETE` (publish) → 403 | R3 | S5 | 4, 10 | Neověřeno | |
| GW-09 | Cizí `Authorization` u typed operací odmítnuta | R3 | S5 | 4, 10 | Neověřeno | |
| GW-10 | Vložení klíče a SSE; klíč nikdy v oblasti (mock upstream) | R2, R3 | S5 | 4 | Neověřeno | |
| GW-11 | Rate a budget limity | R3 | S5 | 4 | Neověřeno | |
| GW-12 | Typed vs passthrough na stejném hostname (OAuth/API) bez bypassu | R3, R8 | S5 | 10 | Neověřeno | |
| GW-13 | OAuth/API scopes: mocky + uživatelský důkaz před podporou integrace | R3, R8 | S5 | 10 | Neověřeno | |
| GW-14 | HTTP vs HTTPS base URL per SDK; per-zone CA a explicitní trust store | R8 | S5 | 6 | Neověřeno | |
| GW-15 | Audit stažení odděleně od neautoritativního přehledu instalací; hranice cooldownu u lokální cache/importu | R3, R7 | S5 | 10 | Neověřeno | |
| GW-16 | PyPI simple index + `upload-time` cooldown | R3, R8 | S5 | 10 | Neověřeno | |
| GW-17 | Homebrew API/bottles: cooldown metadata | R3, R8 | S5/S6 | 10 | Neověřeno | |
| GW-18 | Git: push jen do repa projektu (smart HTTP nebo deploy key) | R3 | S5 | 4 | Neověřeno | |
| GW-19 | Matice kompatibility nástroj × protokol × policy | R8 | S5 | 6 | Neověřeno | |
| GW-20 | Režie ≤ 1,1× nativně podle předem určeného měření | R5 | S5 | 7 | Neověřeno | |

### 3.7 RB — stav, rollback, zpevnění (S4)

| ID | Případ | R | Brána | Esc | Stav | Důkaz |
|---|---|---|---|---|---|---|
| RB-01 | Manifest vyjmenovává všechny zápisové kořeny; stav mimo ně neposkytuje perzistenci | R2, R7 | S4 | 11 | Neověřeno | |
| RB-02 | Snapshot až po ověřeném quiescence celého UID | R7 | S4 | 11 | Neověřeno | |
| RB-03 | Startup/job kanárek v home odstraněn plným rollbackem | R2, R7 | S4 | 11 | Neověřeno | |
| RB-04 | Změny projektu, prefixu a cache vráceny | R7 | S4 | 11 | Neověřeno | |
| RB-05 | Uzavřené fd/mappingy před obnovou | R7 | S4 | 11 | Neověřeno | |
| RB-06 | Pád v každé fázi obnovy | R7 | S4 | 11 | Neověřeno | |
| RB-07 | Neúplně obnovená oblast se nespustí | R2, R7 | S4 | 11 | Neověřeno | |
| RB-08 | Hostem vlastněná ochranná politika se ze snapshotu neobnovuje | R2 | S4 | 11 | Neověřeno | |
| RB-09 | Uninstall nepřepíše následnou legitimní změnu práv | R2 | S4 | 9 | Neověřeno | |
| RB-10 | Rollback zpevnění vrací jen vlastní změny; `chmod 700 ~` nerozbije host nástroje | R2, R7 | S4 | 9 | Neověřeno | |

### 3.8 SG — signing, TCC, broker (S8)

| ID | Případ | R | Brána | Esc | Stav | Důkaz |
|---|---|---|---|---|---|---|
| SG-01 | Hardened runtime u agenta, sond a helperu | R2 | S8 | 8 | Neověřeno | |
| SG-02 | Absence `get-task-allow` | R2 | S8 | 8 | Neověřeno | |
| SG-03 | Stabilní identita pro TCC přes rebuild | R6 | S8 | 8 | Neověřeno | |
| SG-04 | SMAppService s Personal Team (LoginItem, LaunchAgent, LaunchDaemon zvlášť) | R2 | S8 | 3, 8 | Neověřeno | |
| SG-05 | Self-signed varianta (jen pokud SG-04 neprojde) | R2 | S8 | 8 | Neověřeno | |
| SG-06 | Same-UID proces neattachne agenta a nezíská jeho TCC granty | R2 | S8 | 8 | Neověřeno | |
| SG-07 | Modifikace bundle neudrží TCC granty | R2 | S8 | 8 | Neověřeno | |
| SG-08 | Broker ověřuje audit token, code signature a session | R2 | S8 | 8 | Neověřeno | |
| SG-09 | Fuzzing XPC: neplatné zprávy a velikosti | R2 | S8 | 8 | Neověřeno | |
| SG-10 | IOSurface jen přes Mach port, ne globální ID | R2 | S8 | 8 | Neověřeno | |
| SG-11 | Path traversal a TOCTOU v helperu | R2 | S8 | 8 | Neověřeno | |

### 3.9 HB — Homebrew per oblast (S6)

| ID | Případ | R | Brána | Esc | Stav | Důkaz |
|---|---|---|---|---|---|---|
| HB-01 | Top 200 formulí: známý poměr bottle/kompilace v krátkém prefixu | R1, R8 | S6 | 6 | Neověřeno | |
| HB-02 | Vzorek `brew test` projde | R1 | S6 | 6 | Neověřeno | |
| HB-03 | Casky do `~/Applications` oblasti | R1 | S6 | 6 | Neověřeno | |
| HB-04 | Datum publikace v metadatech pro cooldown pokrývá vydávaný artefakt | R3 | S6 | 10 | Neověřeno | |
| HB-05 | Host `/opt/homebrew` beze změny po všech instalacích | R2 | S6 | 6 | Neověřeno | |
| HB-06 | Žádná podporovaná instalace nevyžaduje root z oblasti | R2 | S6 | 6 | Neověřeno | |
| HB-07 | Prefix je v APFS topologii a rollbacku | R7 | S6 | 11 | Neověřeno | |

### 3.10 DK — Docker (S7)

| ID | Případ | R | Brána | Esc | Stav | Důkaz |
|---|---|---|---|---|---|---|
| DK-01 | `docker run` a `docker build` | R1, R4 | S7 | 5 | Neověřeno | |
| DK-02 | `docker run -v /:/host` nezpřístupní Mac ani jinou oblast | R4 | S7 | 5 | Neověřeno | |
| DK-03 | Změna mount konfigurace runtime z oblasti nezpřístupní host | R4 | S7 | 5 | Neověřeno | |
| DK-04 | Vlastní daemon/socket per oblast | R4 | S7 | 5 | Neověřeno | |
| DK-05 | Síť kontejneru jen přes bránu oblasti | R3, R4 | S7 | 5 | Neověřeno | |
| DK-06 | Registry auth | R4, R8 | S7 | 5 | Neověřeno | |
| DK-07 | Published ports nevystaví kontejner do LAN/hosta mimo policy | R3, R4 | S7 | 5 | Neověřeno | |
| DK-08 | vsock proxy | R4 | S7 | 5 | Neověřeno | |
| DK-09 | Síťové failure modes jako NET-20…26 | R3, R4 | S7 | 5 | Neověřeno | |
| DK-10 | Start/stop v budgetu stanoveném před S7 | R5 | S7 | 7 | Neověřeno | |

### 3.11 POS — pozitivní a výkonové (napříč branami)

| ID | Případ | R | Brána | Esc | Stav | Důkaz |
|---|---|---|---|---|---|---|
| POS-01 | `npm`/`pip`/`brew install` v oblasti | R1 | S5/S6 | 6 | Neověřeno | |
| POS-02 | Cargo, Go, Gradle, NuGet v oblasti | R1, R8 | S5 | 6 | Neověřeno | |
| POS-03 | OpenCode CLI a alespoň jeden další agent v oblasti | R1, R8 | F2 | 6 | Neověřeno | |
| POS-04 | `sanjbox shell` v libovolném terminálu: UID a doména oblasti | R1 | F2 | 6 | Neověřeno | |
| POS-05 | Bezpečná pauza celého UID odděleně od pauzy aplikací | R5 | F2 | 7 | Neověřeno | |
| POS-06 | Most schránky: preview, potvrzení, karanténa | R2, R6 | F3 | 2 | Neověřeno | |
| POS-07 | Proxy okna: Xcode, Simulator, Electron, Safari použitelné | R6 | F3 | 6 | Neověřeno | |
| POS-08 | MVP okno plochy oblasti: jednoznačně označené, schránka jen řízeným mostem (C-001) | R2, R6 | F2 | 2, 6 | Neověřeno | |
| POS-09 | Řízený export: výběr, preview, karanténa, audit; jiná cesta ven neexistuje (F0.3) | R2, R7 | F2 | 1 | Neověřeno | |
| PERF-01 | `npm install`/build v oblasti vs. srovnatelně nativně | R5 | F2 | 7 | Neověřeno | |
| PERF-02 | Detekce a reakce hlídače (detektor, ne gate R3) | R3 | S3 | 7 | Neověřeno | |
| PERF-03 | Cold/warm login a resume proti cílům design card | R5 | F2 | 7 | Neověřeno | |

## 4. Pracovní balíky

Definice balíků: [IMPLEMENTATION.md §3](IMPLEMENTATION.md#3-fáze-a-pracovní-balíky).

Revize 2026-11-14 nad `main` `4ad05d9` po H4 #79, A3 #78 a dílčím A6 #77: F0 **5/5 hotovo**,
F1 **22 hotových / 5 rozpracovaných / 9 nezahájených**. Sloučené A3 přidalo S5 record kodeky a
fail-closed čtení SessionInfo; bez DH provideru, reviewované virtuální autorizace a integrovaného
command/result toku zůstává rozpracované. A6 má skutečný H1 wire fuzzer, ale stále chybí native
host-only approval, registration ownership/cleanup přes restart a kalibrovaná SG-06 pozitivní
attach kontrola; skutečné podpisy/TCC/L2 nebyly provedené. Vlastníci a podmínky jsou v
[IMPLEMENTATION §0](IMPLEMENTATION.md#0-co-dál). Všech **10 bran F1 a 155 akceptací zůstává Neověřeno**.

| ID | Balík | Vlastník | Stav | Poznámka |
|---|---|---|---|---|
| WP0.1 | Rozhodnutí F0 | uživatel | ✅ | 8/8 rozhodnuto 2026-11-07; F0.7 přináší změnu kontraktu C-003. Docker start/stop (F0.8) se rozhodne před S7 |
| WP0.2 | Repo, dokumentace, coverage | — | ✅ | Nezávisle ověřený [úklid vlastních procesů CI watchdogu](../.github/scripts/WATCHDOG.md) (2026-11-13, Codex / Astra) je sloučený v PR #68; zachovává timeout status a omezuje diagnostiku při selhání spuštění. [Operativní plán](IMPLEMENTATION.md#0-co-dál) rozlišuje obsazenou práci, závislosti a čekání na uživatele; brány beze změny. |
| WP0.3 | Společná sada sond | janfiedler / Codex + Astra | ✅ | Nezávisle ověřené opravy [výsledku diagnostického whoami](../spikes/common/WHOAMI-OUTCOME-VALIDATION.md) (bez očekávání `unclear`, shoda `passed`, neshoda `invalidMeasurement`) a [omezení launchctl a úklidu potomků](../spikes/common/VALIDATION-CONTEXT-BOUNDS.md); společné review po PR #66 ověřilo 95/95 testů a 18/18 nativních scénářů v Debug i Release (2026-11-13), starší validace zachované. Požadavek A4 na `--expect` a ruční porovnání dalších polí zůstává, veřejná schémata, brány a historické důkazy beze změny. |
| WP0.4 | Nezávislá protistrana | janfiedler / Codex + Astra | ✅ | Dokončené a nezávisle ověřené opravy [reportu](../spikes/common/VALIDATION-COUNTERPART.md) a [vlastnictví výstupů](../spikes/common/VALIDATION-COUNTERPART-OUTPUT.md) po integraci PR #64 společně prošly 70/70 testy a 14/14 dalšími CLI scénáři v Debug i Release a 3/3 kontrolami deskriptorů (2026-11-13). Kontrola práv pokrývá pouze POSIX mode bits bez rozšířených ACL; ICMP a TLS obsah jsou mimo rozsah, brány a historické logy beze změny. |
| WP0.5 | Metodika a laboratoř | janfiedler / Codex + Astra | ✅ | [LAB-v1](LAB.md): registr, sloty, předregistrace, návrhy prahů/statistik a šablony; neměnná historie běhů více autorů/strojů. Doplněn [M1 host protokol 3×5 s](evidence/s1/20261103T134131Z-janfiedler-LAB-janfiedler-01-r1-a8a26eeb/verdict.md). LAB-v1 přijato v F0.8 2026-11-07 (změny P4, P5). A2 vyžaduje další instrumentaci. S1 ani jiná brána tím neprošly. 2026-11-04: Codex/Astra dodal [read-only validátor publikovaných důkazů](../tools/lab_evidence/README.md) a syntetické testy bezpečného čtení, manifestů, odkazů a historie. Strukturální shoda není akceptace; metodika, historické běhy a F0.8 beze změny |
| WP1.A1 | S1 příprava | janfiedler / Codex + Astra (forwarder follow-up, 2026-11-08) | ✅ | `spikes/s1-session`: skripty s dry-runem a úklidem, sonda relace (credentials, displeje, Metal, offscreen render s ověřením, prezentace, RAM, Screen Recording), loopback forwarder místo SSH, WebGL stránka; 6 testů. Části s `--apply` (root) ověří až běh L1; samostatný follow-up 2026-11-08 opravil self-target a životní cyklus descriptorů, [validace](../spikes/s1-session/VALIDATION-FORWARDER.md): Debug/Release 6/6 + CLI 5/5 + audit 3/3, negativní kontrola původního zdroje; nezávislé Astra xhigh review bez nálezů P0–P2, sloučeno v PR #70 dne 2026-11-13, bez změny S1 |
| WP1.A2 | S1 běh (L1) | janfiedler / Codex + Astra (dynamický sběr potomků; review 2026-11-13) | 🟨 rozpracováno | Nezávislé review [dynamického sběru potomků](../spikes/s1-session/DESCENDANT-MEMORY.md) po integraci PR #61/#70: 97 testů instrumentace a 12 nativních CLI kontrol v Debug i Release, ověřený pozdní strom/úklid, neúplné SIGTERM/SIGALRM prefixy, 30 legacy a 41 offline kontrol. A2/L1 zůstává dílčí bez úplné atribuce UID/WindowServeru, kalibrovaného loginu a tří skutečných relací; [historie a validace](../spikes/s1-session/VALIDATION.md) zachované, žádný verdikt S1/P4. |
| WP1.A3 | Průzkum RFB výběru relace | janfiedler / Codex + Astra; navazující Astra (nezávislé review #78, výslovné předání) | 🟨 rozpracováno | [#78](https://github.com/Fir3st/sanjbox/pull/78) sloučeno jako `8faf648`. [S5 kodeky](../spikes/s1-rfb/README.md) nahrazují package-local protokol; klient po SessionInfo odmítne volbu i plochu. [Nové review](../spikes/s1-rfb/VALIDATION.md#nezávislé-integrační-review-po-h4--2026-11-14): 42/42 Debug/Release, 28/28 CLI, 94/94 repo testů; pátý připnutý zdroj testuje console bit, ale virtuální command 2 vrací bez mask check. Chybí reviewovaná virtuální autorizace, integrovaný command/result tok a DH provider; vlastník pokračuje podle [konkrétních podmínek](IMPLEMENTATION.md#0-co-dál). A3 není dokončené; všechny brány i Screen Sharing.app/L1-D zůstávají Neověřeno. |
| WP1.A4 | S0 příprava | janfiedler / Codex + Astra (postupy 31 případů; review 2026-11-13) | ✅ | [Postupy všech 31 FS/ID/LC případů](../spikes/s0-boundary/LAB-PLAN.md) splňují podmínku přípravy z IMPLEMENTATION §0: sondy nebo ruční kroky s controls/oracles, výstupy, úklidem a explicitními stop podmínkami; současné spustitelné sondy zůstávají omezené self fixtures. [Ověření přípravy](../spikes/s0-boundary/VALIDATION.md) nemění verdikty: cross-session/TCC čekají na uživatelský L2 po S1, FS-04/08/LC-11 na S4/S8/F2, žádný akceptační případ ani brána tím neprošly. |
| WP1.A5 | S0 běh (L2) | uživatel + impl. | ⬜ | |
| WP1.A6 | S8 příprava | janfiedler / Codex + Astra; navazující Astra (H1 fuzzer a nezávislé integrační review #77, 2026-11-14) | 🟨 rozpracováno | [H1 follow-up #77](../spikes/s8-signing/A6-H1-FOLLOWUP.md) dodává bounded fuzzer skutečných helper/reply/broker v1 wire API, syntetickou host-only daemon hranici a šest dry-run restart/cleanup workflow. [Nezávislá validace po H4/A3](../spikes/s8-signing/VALIDATION.md#nezávislé-integrační-review-po-h4-a-a3--2026-11-14): 53/53 Debug/Release, 30/30 CLI v každém sestavení, 60/60 S8 Python a 94/94 repo testů; mock není nativní autorita. Vlastník pokračuje podle [IMPLEMENTATION §0](IMPLEMENTATION.md#0-co-dál): nativní daemon approval, durable registration ownership/cleanup přes restart a SG-06 se srovnatelnou pozitivní attach kontrolou. [Podpisové předání](../spikes/s8-signing/HANDOFF.md) nadále odmítá post-handoff cleanup; skutečný Personal Team/podmíněný self-signed, XPC/Mach/TCC/L2 a S8/SG-01…11 zůstávají Neověřeno. |
| WP1.A7 | S8 běh (L2) | uživatel + impl. | ⬜ | |
| WP1.B1 | Audit hosta | janfiedler / Codex + Astra | ✅ | [metadata audit](../spikes/s4-host/README.md); 17 syntetických testů, S4/R2/R7 Neověřeno |
| WP1.B2 | Zpevnění a uninstall | janfiedler / Astra | ✅ | [Příprava mode/ACL hardeningu a uninstallu](../spikes/s4-host/HARDENING.md): explicitní dry-run, trvalý původní/výsledný ACL deník a obnova pouze nezměněných zásahů; [review/validace](../spikes/s4-host/VALIDATION-B2-ACL.md#review-pr-59--2026-11-13) opravuje APFS alias overlap před mutací, 55 native testů v Debug/Release. Omezený adresářový rozsah bez nového dědění; host kompatibilita čeká na L3, S4/RB-09/10 Neověřeno. |
| WP1.B3 | Manifest a topologie | janfiedler / Codex + Astra | ✅ | [návrhový manifest a validátor](../spikes/s4-state/README.md); 21 syntetických testů, skutečná topologie/kvóty/rollback a S4 Neověřeno |
| WP1.B4 | Snapshot/rollback prototyp | janfiedler / Codex + Astra | ✅ hotovo (příprava) | [Read-only APFS planner](../spikes/s4-state/TOOLING.md) má dry-run, záznam stavu, ruční hand-off a úklid; [validace](../spikes/s4-state/VALIDATION-B4.md) doplňuje recovery mock a feasibility studii. Native APFS, snapshot oprávnění a whole-UID admission/crash/reboot adaptér čekají na L3; S4/RB-02…08 zůstávají Neověřeno |
| WP1.B5 | S4 běh (L3) | uživatel + impl. | ⬜ | |
| WP1.C1 | S3 příprava | janfiedler / Codex + Astra | ✅ | [Příprava](../spikes/s3-pf/README.md) + [opt-in C1/common producer provenance](../spikes/s3-pf/NETWORK-PROVENANCE.md): předregistrované run/flow/challenge bytes, names-free identity/signature preflight, exact tuple, bounded raw a partial-error receipts. [Validace](../spikes/s3-pf/NETWORK-PROVENANCE-VALIDATION.md): common 32 + C1 11 + C3 50 Release, 25 legacy offline CLI, 11 signed host + 4 offline CLI; nezávislé review a vlastní 11+11 kontrol. Nový C3 adapter a skutečné testArea/L4 chybí; S3/S3b a případy Neověřeno. |
| WP1.C2 | Ochrana nezávislá na pf | janfiedler / Codex + Astra | ✅ | [Rešerše a návrh](../spikes/s3-pf/research/wp1-c2-pf-independent/README.md): primární zdroje, připnuté OSS/SDK podklady, 12 návrhů L4 experimentů; úplný mechanismus nedoložen, blokátor otevřený. Bez runtime testů; S3/NET/R3 zůstávají Neověřeno |
| WP1.C3 | S3b příprava | janfiedler / Codex + Astra | ✅ | [Návrh bind policy](../spikes/s3-pf/ingress/BIND-POLICY.md) a [L4 scénáře](../spikes/s3-pf/ingress/LABPLAN.md) splňují podmínku přípravy z IMPLEMENTATION §0; [offline C1/common adapter](../spikes/s3-pf/ingress/ADAPTER.md) zachovává exact bytes/run/flow/tuple/identity a partial/foreign/replayed/zero kontakty; [ověření](../spikes/s3-pf/ingress/NETWORK-ADAPTER-VALIDATION.md): 63/63 Release, 30/30 nových + 25/25 legacy offline CLI, 4/4 review regrese, 9 autentických producer případů / 61 hashovaných souborů; [historické ověření](../spikes/s3-pf/ingress/VALIDATION.md) zachováno. Autentizace peeru, nezávislý capture, vynucení politiky a skutečný běh patří do WP1.C4/L4; technický rozpor s formulací PLAN je veden jako C3-T1 v návrhu; S3b/NET-10…12/R2/R3 zůstávají Neověřeno. |
| WP1.C4 | S3/S3b běh (L4) | uživatel + impl. | ⬜ | |
| WP1.D1 | Jádro brány | janfiedler / Codex | ✅ | `spikes/s5-gateway`: HTTP/1.1 + SSE, typed router, systémové DNS/interface snapshot, SSRF policy a připnutý TLS upstream; 45 unit/mock/lokálních testů; kontrakt pro D2/D3/D4 a limity v README. S5 zůstává Neověřeno |
| WP1.D2 | npm typed | janfiedler / Codex + Astra | ✅ | `spikes/s5-gateway`: filtrované packumenty, přímé/scoped tarbally, čerstvá autorizace cache/redirectů, silné SRI a bounded audit transportu; 18 nových testů, celkem 63 debug prošlo bez skips včetně lokálního fixture `npm pack`; podmnožina a limity v NPM.md. Bez živých instalací; S5 zůstává Neověřeno |
| WP1.D3 | API modelů | janfiedler / Codex + Astra | ✅ | `spikes/s5-gateway`: úzký Anthropic text-SSE, pouze syntetický trusted klíč, rate/konečný lokální budget, bounded audit, lazy single-use producer, backpressure/cancellation a HTTPS s oddělenou test CA; 16 nových testů, celkem 61 debug prošlo bez skips. MODEL-API.md vymezuje podmnožinu; F0.7/SDK/live billing neověřené, S5 zůstává Neověřeno |
| WP1.D4 | Fixtures a mocky | janfiedler / Codex + Astra | ✅ | `spikes/s5-fixtures`: původní 8 artefaktů, 40 scénářů, 15 OAuth mocků a 6 redirect fixtures zachované. [Skutečný D2 adaptér](../spikes/s5-fixtures/HANDLER-INTEGRATION.md): handler/bytes/upstream/audit, cache reautorizace a opt-in npm ci/cache/import; Release 42/42, 0 skips. Matice 40: 28 matched / 12 incomplete (nepozorovatelný důvod generické 403) / 0 mismatched. [Validace](../spikes/s5-fixtures/VALIDATION-HANDLER.md); D3, živá upstream integrace a S5/L5 neověřené, žádný verdikt brány. Nový [redirect dodatek](../spikes/s5-fixtures/VALIDATION-REDIRECT.md): všech 6 původních HTTP fixtures přes skutečný handler, úplný DNS/interface/dial/bytes sled, reautorizace a digest/cache, smyčky/hop limit; 12 nových metod, finální Release 54/54, 0 skips. Původní matice 40 nadále 28 matched / 12 incomplete; generický důvod chyby nepozorovatelný, direct audit pouze prepared. |
| WP1.D5 | PyPI, Homebrew, git | janfiedler / Codex + Astra | 🟨 rozpracováno | [Typed prototyp](../spikes/s5-gateway/TYPED-REGISTRIES.md) zůstává částečný; [rešerše a review](../spikes/s5-gateway/research/wp1-d5-publication-time/VALIDATION.md#review-2026-11-13) ověřily vazbu metadat na konkrétní E1 bottle, nikoli důvěryhodný čas publikace. Homebrew zůstává fail-closed, GitHub Packages je nedoložený kandidát a další provider/změna kontraktu čeká na rozhodnutí uživatele; S5/S6/HB-04 zůstávají Neověřeno. |
| WP1.D6 | Matice kompatibility | janfiedler / Codex + Astra | ✅ | Původní [historická matice 50 řádků](../spikes/s5-compatibility/README.md#historical-inventory-2026-11-04) zůstává dokončená a beze změny. Nová [vrstva F0.7/C-003](../spikes/s5-compatibility/CURRENT-DECISIONS.md) je sloučená v PR #63 dne 2026-11-13: 19 testů na obou Pythonech, přijaté integrace oddělené od implementace a důkazů; S5/GW-19/R3/R8 Neověřeno. |
| WP1.D7 | S5 integrace (L5) | uživatel + impl. | ⬜ | |
| WP1.E1 | S6 příprava | janfiedler / Codex + Astra | ✅ | `spikes/s6-brew`: pinned top 200 + vzorek 20 testů, offline plán instalací/casků, receipt report, unknown-publication refusal, dry-run prefix scaffold a konzervativní úklid; 46 native Python tests. Příprava hotová, E2 měření neprovedeno; HB-01…07/S6 zůstávají Neověřeno. Viz [VALIDATION](../spikes/s6-brew/VALIDATION.md). |
| WP1.E2 | S6 běh (L6) | uživatel + impl. | ⬜ | |
| WP1.F1 | S2-A výzkumný prototyp | | ⬜ | TCC grant od uživatele |
| WP1.F2 | S2-B (L7) | uživatel + impl. | ⬜ | |
| WP1.G1 | Rešerše Docker runtime | Codex / Astra | ✅ | [Připnutá rešerše runtime](../spikes/s7-docker/research/wp1-g1-runtime/README.md), manifest primárních zdrojů a G2/L8 plán DK-01…10; žádný stock kandidát neprokazuje celý kontrakt. Bez runtime měření; S7/DK Neověřeno, F0.8 budget otevřený, mimo MVP (C-002) |
| WP1.G2 | S7 příprava | janfiedler / Codex + Astra | 🟨 | [Částečná offline příprava](../spikes/s7-docker/README.md): bounded manifest/planner, 64 scénářů × 3 oblasti, syntetické oracle, registry/toy-frame mocky a vlastní fixture cleanup; 63 native Python tests ([validace](../spikes/s7-docker/VALIDATION.md)). Zmrazeno podle [IMPLEMENTATION §0](IMPLEMENTATION.md#0-co-dál): runtime/VM/Engine/bridge a S5 integrace chybí; z F0.8 čeká Docker start/stop budget, S7/DK-01…10 Neověřeno, mimo MVP. |
| WP1.G3 | S7 běh (L8) | uživatel + impl. | ⬜ | |
| WP1.H1 | Kontrakty v0 (prototyp) | janfiedler / Pi (agent); předání Codex + Astra 2026-11-13 | ✅ | [Dokončené kontrakty](../proto/contracts/README.md): úzký broker v1, helper příkazy/odpovědi pro H3, úplná pravidla a report B3, lifecycle, síť a audit. [Validace](../proto/contracts/VALIDATION.md): 125 Swift testů v debug/release, source parity 140 případů / 48 B3 kódů i pro B3-only CI a 94 repo testů po opravách review; runtime integrace a všechny brány Neověřeno. |
| WP1.H2 | Životní cyklus (prototyp) | janfiedler / Codex + Astra | ✅ | [Lifecycle nad H1](../proto/lifecycle/README.md): mock uživatel/svazky/bootstrap/celé UID, trvalý globální deník, konzervativní obnova a přidělování UID mezi oblastmi. [Validace](../proto/lifecycle/VALIDATION.md): 37 testů v Debug i Release, v každém sestavení 116 procesních crash hranic přes 24 kroků, všechny H1 recovery body a LC-06/LC-11 v mocku; nativní OS admission, lifecycle a reboot čekají na WP2.2/lab, brány zůstávají Neověřeno. |
| WP1.H3 | CLI (prototyp) | janfiedler / Codex + Astra | ✅ | [CLI nad H1](../proto/cli/README.md): shell/run/pause/snapshot/rollback přes skutečné lokální NSXPC k same-process mock helperu, striktní zprávy a korelace odpovědí, pouze syntetická restore unit. [Validace](../proto/cli/VALIDATION.md): 34 testů v Debug i Release včetně 13 procesních CLI scénářů, doslovného argv, neplatných vstupů/odpovědí a přerušených spojení; accepted je jen execution handle, skutečný helper/UID/APFS/PTY a všechny brány Neověřeno. |
| WP1.H4 | Brána jako služba (prototyp) | janfiedler / Codex + Astra; navazující Astra (H1 adaptér, výslovné zadání uživatele) | ✅ hotovo | [H1 adaptér](../proto/gateway/H1-ADAPTER.md) řídí npm/PyPI/git/model v dispatchi i loopback listeneru; explicitní konfigurace, odmítnutí širších cílů/metod/limitů, mock klíče a [117/117 Debug/Release testů po opravě review P3](../proto/gateway/VALIDATION.md). Offline podmínka H4 splněna, původní autorství zachováno; CLI zůstává draft-only a identita klienta, produkční integrace i S5/GW zůstávají Neověřeno. |
| WP1.H5 | Řízený export (prototyp) | Codex | ✅ | [Prototyp](../proto/export/README.md): výběr, preview, kopie, karanténa a audit; [validace](../proto/export/VALIDATION.md) 80 testů v Debug i Release a 9 CLI scénářů v každém sestavení. Bez důkazu brány či izolace; reálné UID/ACL a konsolidace auditu čekají na WP2.11. |
| WP1.H6 | Harness únikových testů (prototyp) | janfiedler / Codex + Astra | ✅ hotovo | [Katalog a runner](../proto/escape/README.md) pokrývají všech 155 ID, osm syntetických sond a H1 audit; [validace po integraci H3](../proto/escape/VALIDATION.md#review-po-integraci-h3--2026-11-14) má 18/18 testů v Debug i Release včetně skutečné loopback protistrany, negativních/neúplných výsledků a úklidu. Ruční/nepodporované případy nikdy pass; všech 155 akceptací zůstává Neověřeno, skutečné UID a integrace čekají na WP2.8/lab. |
| WP2.0 | Kontrakty | | ⬜ | čeká na vstup F2 |
| WP2.1 | Helper | | ⬜ | |
| WP2.2 | Životní cyklus | | ⬜ | |
| WP2.3 | Stav a rollback | | ⬜ | |
| WP2.4 | Síť | | ⬜ | |
| WP2.5 | Typované brány | | ⬜ | |
| WP2.6 | Sanjbox.app | | ⬜ | |
| WP2.7 | CLI | | ⬜ | |
| WP2.8 | Únikový test suite | | ⬜ | |
| WP2.10 | Okno plochy oblasti (MVP displej) | | ⬜ | C-001 |
| WP2.11 | Řízený export | | ⬜ | F0.3 |
| WP2.9 | Integrace a brána F2 (MVP) | | ⬜ | |
| WP3.1 | Agent relace | | ⬜ | |
| WP3.2 | Broker | | ⬜ | |
| WP3.3 | Proxy appky v Docku | | ⬜ | |
| WP3.4 | Most schránky | | ⬜ | |
| WP3.5 | Rozšířené interakce | | ⬜ | |
| WP3.6 | Brána F3 | | ⬜ | |
| WP4.1 | Docker runtime | | ⬜ | |
| WP4.2 | Zařízení | | ⬜ | |
| WP4.3 | Git identita | | ⬜ | |
| WP4.4 | Brána F4 | | ⬜ | |

## 5. Otevřené blokátory (PLAN §Otevřené blokátory)

| Blokátor | Požadavek | Řeší | Stav |
|---|---|---|---|
| Ochrana nových dat, přesunů, obnov a mountů | R2 | S0, S4 (FS-04, FS-10, FS-11) | Otevřený |
| Zákaz nového spuštění a zánik všech procesů UID; rozsah rollbacku a crash recovery | R2 | S0, S4, S8 (LC, RB) | Otevřený |
| Resolver, mDNS, ICMP, AirDrop/APNs | R3 | S3 (NET-16…18); bez Network Extension (F0.5) | Otevřený |
| Výpadek pf: ochrana nezávislá na rulesetu, staré states | R3 | S3, WP1.C2 (NET-20…25) | Otevřený |
| Ingress a loopback, port squatting | R2, R3 | S3b (NET-10…12) | Otevřený |
| Autorizace, scopes a passthrough | R2, R3, R8 | S5, S8 (GW-12…13) | Otevřený |
| Cooldown jako kontrola artefaktů; metadata brew/tapů | R3 | S5, S6 (GW-01…06, HB-04) | Otevřený |
| Tři akcelerované relace vedle host konzole, HP limit, keeper | R1, R5, R6 | S1, S2 (GUI-01…05, GUI-13); fallback F0.6 nepokrývá nemožnost souběžných relací | Otevřený |
| Signing bez placeného účtu: S8 nemá náhradní cestu | R2 | S8 (SG-04…05); F0.5 | Otevřený |
