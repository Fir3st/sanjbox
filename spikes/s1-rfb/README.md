# WP1.A3 — RFB research and offline client prototype

**Částečný výstup.** Rešerše rozlišuje standardní RFB, Apple autentizaci a výběr uživatelské relace.
Swift 6 prototyp zpracuje syntetický RFB 3.8 handshake a Raw framebuffer v paměti a nově i **syntetickou
fixture podobu** Apple security handshaku (typ 30 podle S4), ClientInit `0xC1` a výběru relace (S5)
včetně konečných stavů pending / denied / unavailable. Kryptografie zůstává za injektovaným rozhraním
**bez implementace**, takže se bez ní handshake zastaví. Prototyp neumí Apple login, nemá transport,
socket ani okno plochy a **nedokazuje nic o reálném Apple auth**; není klientem pro MVP, keeperem ani
důkazem brány S1. WP1.A3 proto zůstává `🟨 rozpracováno`. Živé připojení a ověření rámování proti
skutečnému macOS serveru zůstává na uživateli v L1-D.

Vazba na kontrakt: [PLAN §S1](../../PLAN.md#s1--neviditelná-relace-brána-celého-gui-návrhu),
[IMPLEMENTATION WP1.A3 / WP2.10](../../docs/IMPLEMENTATION.md), C-001 a F0.6. Budoucí integrace se týká
R1/R5 a displeje MVP; nepřináší per-app R6. GUI-01…05, GUI-10…13 a POS-08 zůstávají **Neověřeno**.
Všech 155 případů, požadavků a bran v COVERAGE má nezměněný stav.

## Co je v balíku

| Soubor | Účel |
|---|---|
| `Sources/RFBProtocol/RFBClient.swift` | Čistý stavový automat, žádné I/O a závislosti. |
| `Sources/RFBProtocol/AppleSubset.swift` | Apple fixture rámování, `AppleSession`, seam `AppleCredentialProvider`; každá konstanta s citací nebo označením „package-local“. |
| `Sources/sanjbox-rfb-fixture/main.swift` | Vestavěný mock 2×2, Apple fixture scénář a odmítnutí konzole; vše v paměti. |
| `Tests/RFBProtocolTests/RFBClientTests.swift` | Standardní RFB 3.8: negativní případy, fragmentace, EOF a rozpočty (21 testů). |
| `Tests/RFBProtocolTests/AppleSubsetTests.swift` | Apple fixture transkripty a mock provider; 19 testů (celkem 40). |
| [SOURCES.md](SOURCES.md) | Primární zdroje, připnuté revize, hranice jejich tvrzení. |
| [LAB-NEXT.md](LAB-NEXT.md) | Budoucí uživatelský postup s cestou přes Screen Sharing.app a seznam toho, co zůstává na L1-D. |
| [VALIDATION.md](VALIDATION.md) | Výsledek místních mock testů a reprodukce. |

## Podporovaná podmnožina

Jde o záměrně úzký experiment podle [RFC 6143](https://www.rfc-editor.org/rfc/rfc6143.html), nikoli
obecný interoperabilní VNC klient. Neznámé varianty se nepřekládají odhadem.

| Vstup / operace | Chování prototypu |
|---|---|
| Verze | Standardně přesně `RFB 003.008\n`. Kandidát Apple banneru `RFB 003.889\n` se přijme **jen** pod fixture politikou `syntheticAppleSubset`; 3.3, 3.7, ostatní a záměna bannerů mezi politikami se odmítne bez odpovědi. |
| Autentizace | Výchozí `rejectAll` skončí před výběrem typu. `syntheticNoneOnly` přijme jen seznam přesně `[1]`, `syntheticAppleSubset` jen seznam přesně `[30]` (ARD, S4). |
| Smíšený seznam | `[30, 1]`, `[1, 30]`, `[33]`, duplicity, `[19]` i ostatní nabídky se odmítnou; žádný downgrade na None ani na konzoli. |
| Apple typ 30 (S4) | Po odpovědi `[30]` se čte u16 generátor, u16 délka klíče, pak modulus a veřejný klíč serveru téže délky. Délky a rozsahy se ověří **před** načtením payloadu. |
| Apple credential seam (S4) | `AppleCredentialProvider` je jediné místo, kde by žil DH/MD5/AES. Balík neobsahuje žádnou kryptografii. Bez provideru, s prázdnou odpovědí i s odpovědí nad rozpočet se handshake zastaví (fail-closed). |
| SecurityResult | Pro 3.8/None i pro Apple je povinný; 0 pokračuje, 1 čte omezený důvod a odmítne, ostatní hodnoty odmítne. |
| ClientInit | Standardně pouze shared=1; Apple cesta posílá `0xC1` (S5). Ani jedno nevybírá uživatelskou relaci. |
| ServerInit | Jen 32 bpp / depth 24 / little-endian / true-colour / RGB maxima 255 / posuny 16,8,0. Jméno se omezeně spotřebuje a zahodí. Rozšířená Apple metadata (S5) nejsou modelovaná. |
| SessionInfo (fixture) | kind 1, u16 počet, dvojice (příkaz, dostupnost); nejvýš 8 položek. Příkaz 1 = konzole, 2 = virtuální plocha (S5); dostupnost 0/1. |
| SessionInfoChoice (fixture) | Jediná možná volba je `[2, 2]` = virtuální plocha. API neumožňuje zvolit konzoli. |
| SessionResult (fixture) | kind 3 + výsledek: 0 granted, 1 denied (terminální), 2 pending (čeká na další výsledek, deadline vlastní transport). |
| Výběr relace | Nabídka jen **dostupné** konzole = `consoleFallbackForbidden`; nedostupná konzole bez virtuální plochy se hlásí jako `sessionUnavailable` (nedostupná položka nic nenabízí); virtuální plocha chybí nebo je nedostupná = `sessionUnavailable`. Automatický přechod na konzoli/host relaci **neexistuje**. |
| Zobrazení | BGRX bajty v paměti, Raw encoding 0; SetPixelFormat + SetEncodings se pošlou až po granted výběru. |
| Žádost | Volající výslovně požádá o celý rozměr; nejvýše jedna žádost čeká na odpověď. Incremental až po prvním dokončeném update. |
| Update | Obdélníky v hranicích framebufferu, aplikované v pořadí; prázdný update je platná dokončená zpráva. |
| Bell | Spotřebuje se bez zvuku či jiné akce na hostu. |
| Schránka | ServerCutText okamžitě ukončí parser; žádné přijímání/vysílání obsahu schránky. |
| Ostatní | CopyRect, komprese, resize, kurzory, barevná mapa, Apple typ 33 (RSA tunel), TLS, klávesy, myš a file transfer nepodporovány. |

`framebufferUpdated` znamená dokončenou **zprávu** FramebufferUpdate. Nedokazuje pokrytí všech pixelů,
správný UID/session, skutečnou prezentaci, GPU ani latenci. Neaktualizované pixely jsou nulové. Prázdný
první update tedy může zpřístupnit černý buffer, který není důkazem přijetí kompletní plochy.

`syntheticNoneOnly` neověřuje vlastnictví protistrany a není bezpečný režim živého serveru ani localhostu.
Totéž platí pro `syntheticAppleSubset`: je to fixture politika, ne autentizace. Balík nemá transport ani
parametr adresy, portu, jména či hesla. Všechny výstupní bajty zůstávají v paměti. Výchozí režim umí pouze
standardní verzi a odmítnutí na autentizační hranici; nenabízí skrytou cestu k neautentizovanému přístupu.

## Apple security a výběr relace — co je doložené a co ne

Tato část **nedokazuje interoperabilitu se serverem Apple**. V reviewed zdrojích nebyl nalezen
Apple-published byte-level kontrakt. Připnuté klientské zdroje ale obsahují konkrétní rámování;
[SOURCES.md §S5](SOURCES.md#s5--original-author-implementation-lead-for-apple-selection) uvádí přesné
řádky a hashe. Zdejší výběr relace je záměrně zjednodušený fixture model:

| Vrstva | Původ | Důsledek |
|---|---|---|
| Rámování typu 30: u16 generátor, u16 délka klíče, modulus, veřejný klíč serveru, odpověď = credential blok + veřejný klíč klienta, pak SecurityResult | **S4** (noVNC v1.6.0 `_negotiateARDAuth`, řádky 1798–1866) | Implementované jako parsování s pevnými mezemi. Je to tvrzení jednoho klienta, ne serverový kontrakt. |
| ClientInit `0xC1`, SessionInfo → volba → SessionResult, příkaz 1 = konzole, 2 = virtuální plocha, stavy pending/granted | **S5** (peetinc/noVNC-ARD `_ardSessionSelect`, řádky 776–875, `ard-constants.js`) | Implementované jen **sémanticky**: hodnoty příkazů a konečné stavy. |
| Bajtové rozložení SessionInfo / volby / SessionResult | **package-local fixture framing**; S5 má odlišné délkově rámované záznamy (`ard-patch.js` 779–797, 839–867, 2510–2523), které tento model záměrně neimplementuje | Dostupná klientská evidence není ověřený serverový kontrakt. Fixture zprávy se nikdy neposílají na reálný endpoint; prototyp žádný endpoint nemá. |
| Kandidát Apple banneru `RFB 003.889\n` | Přesný literál v připnutém S5 `ard-patch.js`, řádek 214; znovu ověřeno proti raw souboru a jeho SHA-256 | Přijímá se jen pod fixture politikou; výchozí politika ho odmítá. Ověření zdroje nedokazuje banner živého serveru. |
| Meze `appleKeyBytes` 512, `appleCredentialBytes` 4096, `appleSessionChoices` 8 | package-local výzkumné rozpočty | Nejsou z S4/S5; omezují práci před alokací. |

Konečné stavy výběru (`AppleSession`) a jejich význam:

| Stav | Význam | Následek |
|---|---|---|
| `notOffered` | Zatím žádné SessionInfo. | — |
| `virtualReady` | Virtuální plocha nabídnuta jako dostupná; klient poslal `[2, 2]`. | Čeká na SessionResult. |
| `pending` | S5 pending stav. | Fáze `sessionPending`; žádné pollování, retry ani konzole. Deadline vynutí transport přes `expire()`. |
| `granted` | SessionResult udělil virtuální plochu. | Teprve nyní SetPixelFormat/SetEncodings a `.initialized`. |
| `denied` | Server volbu odmítl. | Terminální `sessionDenied`; žádný další pokus. |
| `unavailable` | Virtuální plocha chybí nebo je nedostupná, nebo nabídka obsahuje jen nedostupnou konzoli. | Terminální `sessionUnavailable`; **žádný** přechod na konzoli. |
| `consoleOnly` | Nabídnuta byla jen **dostupná** konzole (příkaz 1, dostupnost 1). | Terminální `consoleFallbackForbidden`; zakázaný přechod je explicitně testovaný. |

## Stav, chyby a pevné limity

Standardní tok: `version → security → securityResult → serverInit → ready → update → ready`.
Apple fixture tok: `version(3.889) → security([30]) → appleChallenge → securityResult → serverInit →
sessionInfo → choice → sessionResult(granted) → ready`. Pending zůstává ve `sessionPending`.
Každá protokolová chyba přejde do terminálního `failed`; cancel / čisté EOF do `closed`.
Po chybě se zahodí buffer a pixely; další příjem či žádost skončí `terminal`. Nový pokus vyžaduje novou
instanci, ne automatické připojení, jiný auth typ ani jinou relaci. Chybné použití API žádosti vrací
`invalidState` bez změny stavu. Vyčerpaný rozpočet je terminální chyba.

| Rozpočet | Pevná mez |
|---|---:|
| Jeden předaný chunk | 64 KiB |
| Šířka i výška | 1…1024 |
| Framebuffer / Raw pixely jednoho update | 4 MiB / 4 MiB kumulativně i při překryvu |
| Jméno / důvod odmítnutí | 4096 bajtů |
| Obdélníky jednoho update | 256 |
| Přijaté bajty za život instance včetně hlaviček | 32 MiB |
| Zprávy serveru po inicializaci / žádosti klienta | 1024 / 64 |
| Nezpracovaný příjem | 4 MiB + 64 KiB |
| Apple délka klíče (package-local) | 1…512 bajtů |
| Apple credential odpověď (package-local) | 1…4096 bajtů |
| Položky SessionInfo (package-local) | 1…8 |

Hlavičky se validují před alokací podle délek. Rozměry se omezí před násobením, obdélníky před výpočtem
offsetů. Přístup po bajtech nevyžaduje zarovnané ukazatele. Fragmentace může končit na každém bajtu;
neúplná zpráva čeká, EOF při čekající žádosti či rozpracované zprávě je `truncated`.

Při zpracování jednoho `receive` se nepublikují mezivýsledky; pozdní chyba zahodí i události této dávky.
Dříve vrácené události ani kopie pole nelze odvolat. `framebuffer` během rozpracovaného update vrací nil;
volající může sám držet starý snímek. Veřejné snapshoty jsou kopírované hodnoty, jejich hromadění musí
omezit budoucí UI. Mez bufferu není tvrzení o přesném RSS: Swift alokace, capacity a kopie mají režii.

Žádný časovač tu neběží. `expire()` je pouze terminální vstup pro budoucí transport; není to měření
timeoutu. Transport by musel vynutit monotónní celkovou a idle deadline, omezenou write queue,
částečné zápisy, cancellation a identitu protistrany. Parser sám neprokazuje bezpečnost živé komunikace.

## Offline použití

**[implementátor]** Swift 6, bez externích balíčků. Z tohoto adresáře:

```bash
A3_CHECK_DIR=$(mktemp -d /private/tmp/sanjbox-a3-check.XXXXXX)
export CLANG_MODULE_CACHE_PATH="$A3_CHECK_DIR/modules"
export SWIFTPM_MODULECACHE_OVERRIDE="$A3_CHECK_DIR/modules"
swift test --scratch-path "$A3_CHECK_DIR/build" --cache-path "$A3_CHECK_DIR/cache" \
  --config-path "$A3_CHECK_DIR/config" --security-path "$A3_CHECK_DIR/security" \
  -Xswiftc -module-cache-path -Xswiftc "$A3_CHECK_DIR/modules"
"$A3_CHECK_DIR/build/debug/sanjbox-rfb-fixture" --demo
```

V prostředí, které nepovoluje vnořený `sandbox-exec`, se pro tento zkontrolovaný lokální manifest použije
`swift test --disable-sandbox` se stejnými ostatními argumenty. To mění pouze sandbox SwiftPM manifestu;
není to pokyn měnit systémovou ochranu ani pouštět cizí balíčky. Výsledek musí hlásit `MOCK ONLY`, shodu
16 bajtů, granted virtuální plochu z fixture transkriptu, odmítnutí konzole-only nabídky a
`network bytes sent: 0`. `--help` pouze popíše demo; neznámé argumenty skončí kódem 2.

Demo používá **mock** provider s konstantními bajty; neprovádí DH, MD5 ani AES. Tři scénáře jsou jen
řetězce bajtů v paměti: standardní 2×2 Raw rámec, Apple fixture tok do `granted` a odmítnutí nabídky,
která obsahuje pouze konzoli. Žádný scénář neotevírá socket ani nečte soubor.

Nejde o systémovou sondu: program nezjišťuje UID, audit session, displeje ani TCC a nic takového neměří.
Proto nezávisí na `spikes/common`. Požadavek GUIDE na kontrolu identity zůstává povinný pro budoucí
reálnou sondu, jak popisuje [LAB-NEXT.md](LAB-NEXT.md).

**Úklid:** program neukládá stav, nezakládá listenery a nemění služby. Sestavení vytváří pouze vlastní
adresář vypsaný v `A3_CHECK_DIR`; po kontrole přesné cesty jej lze uživatelsky odstranit. Žádný úklid
systému, účtů či služeb tento balík nepotřebuje.

## Co ještě brání klientu MVP

- Skutečná implementace S4 krypta (DH/MD5/AES) pod samostatným review; zde je jen prázdný seam a mock.
  Prototyp nedokazuje, že se reálný Apple auth dá takto provést, ani že by byl bezpečný.
- Implementace a interoperabilní ověření bajtového rámování SessionInfo / volby / SessionResult
  a rozšířených ServerInit metadat. S5 poskytuje konkrétní klientskou implementační evidenci; zdejší
  záměrně odlišné package-local fixture rámování ji nenahrazuje a nikdy se neposílá na server.
- Autentizovaná identita serveru, confidentialita transportu a schválená správa testovacích údajů.
- Vynucený výběr vlastní virtuální **uživatelské** relace bez tichého přechodu na host konzoli; fixtures
  dokazují jen to, že tento parser takový přechod neudělá.
- Připnutí plochy na předem známé UID, bootstrap a přesné kladné audit session ID přes nezávislou sondu.
- Transport, okno, značení oblasti, potřebné encodings a kontrolovaný vstup; žádná automatická schránka.
- Uživatelův L1 důkaz souběhu tří relací, přežití/keeperu, GPU a TCC dle LAB; všechny další brány před F2.

Do té doby je plánovanou bootstrap cestou **Screen Sharing.app v uživatelském L1**, nikoli tento mock.
Ani tato cesta není tímto balíkem změřená nebo automaticky schválená jako bezpečný produkt.
