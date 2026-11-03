# WP1.A3 — RFB research and offline client prototype

**Částečný výstup.** Rešerše rozlišuje standardní RFB, Apple autentizaci a výběr uživatelské relace.
Swift 6 prototyp zpracuje syntetický RFB 3.8 handshake a Raw framebuffer v paměti. Neumí Apple login,
výběr relace, síťové spojení ani okno plochy; není klientem pro MVP, keeperem ani důkazem brány S1.
WP1.A3 proto zůstává `🟨 rozpracováno`. Apple cesta má konkrétní výzkumné podklady, ale nebyla zde
implementovaná ani ověřená na serveru.

Vazba na kontrakt: [PLAN §S1](../../PLAN.md#s1--neviditelná-relace-brána-celého-gui-návrhu),
[IMPLEMENTATION WP1.A3 / WP2.10](../../docs/IMPLEMENTATION.md), C-001 a F0.6. Budoucí integrace se týká
R1/R5 a displeje MVP; nepřináší per-app R6. GUI-01…05, GUI-10…13 a POS-08 zůstávají **Neověřeno**.
Všech 155 případů, požadavky a brány v COVERAGE mají nezměněný stav.

## Co je v balíku

| Soubor | Účel |
|---|---|
| `Sources/RFBProtocol/RFBClient.swift` | Čistý stavový automat, žádné I/O a závislosti. |
| `Sources/sanjbox-rfb-fixture/main.swift` | Vestavěný mock 2×2; kontrola všech 16 pixelových bajtů. |
| `Tests/RFBProtocolTests/RFBClientTests.swift` | Negativní případy, fragmentace, EOF a rozpočty. |
| [SOURCES.md](SOURCES.md) | Primární zdroje, připnuté revize, hranice jejich tvrzení. |
| [LAB-NEXT.md](LAB-NEXT.md) | Budoucí uživatelský postup s cestou přes Screen Sharing.app. |
| [VALIDATION.md](VALIDATION.md) | Výsledek místních mock testů a reprodukce. |

## Podporovaná podmnožina

Jde o záměrně úzký experiment podle [RFC 6143](https://www.rfc-editor.org/rfc/rfc6143.html), nikoli
obecný interoperabilní VNC klient. Neznámé varianty se nepřekládají odhadem.

| Vstup / operace | Chování prototypu |
|---|---|
| Verze | Přesně `RFB 003.008\n`; 3.3, 3.7, Apple 3.889 a ostatní se odmítnou bez odpovědi. |
| Autentizace | Výchozí `rejectAll` skončí před výběrem typu. Jen explicitní `syntheticNoneOnly` přijme seznam přesně `[1]`. |
| Smíšený seznam | `[30, 1]`, `[2, 1]`, duplicity i ostatní nabídky se odmítnou; žádný downgrade na None. |
| SecurityResult | Pro 3.8/None je povinný; 0 pokračuje, 1 čte omezený důvod a odmítne, ostatní hodnoty odmítne. |
| ClientInit | Pouze shared=1; žádný exclusive přístup. Shared flag nevybírá uživatelskou relaci. |
| ServerInit | Jen 32 bpp / depth 24 / little-endian / true-colour / RGB maxima 255 / posuny 16,8,0. Jméno se omezeně spotřebuje a zahodí. |
| Zobrazení | BGRX bajty v paměti, Raw encoding 0; před žádostí explicitní SetPixelFormat + SetEncodings. |
| Žádost | Volající výslovně požádá o celý rozměr; nejvýše jedna žádost čeká na odpověď. Incremental až po prvním dokončeném update. |
| Update | Obdélníky v hranicích framebufferu, aplikované v pořadí; prázdný update je platná dokončená zpráva. |
| Bell | Spotřebuje se bez zvuku či jiné akce na hostu. |
| Schránka | ServerCutText okamžitě ukončí parser; žádné přijímání/vysílání obsahu schránky. |
| Ostatní | CopyRect, komprese, resize, kurzory, barevná mapa, Apple rozšíření, TLS, klávesy, myš a file transfer nepodporovány. |

`framebufferUpdated` znamená dokončenou **zprávu** FramebufferUpdate. Nedokazuje pokrytí všech pixelů,
správné UID/session, skutečnou prezentaci, GPU ani latenci. Neaktualizované pixely jsou nulové. Prázdný
první update tedy může zpřístupnit černý buffer, který není důkazem přijetí kompletní plochy.

`syntheticNoneOnly` neověřuje vlastnictví protistrany a není bezpečný režim živého serveru ani localhostu.
Balík nemá transport ani parametr adresy, portu, jména či hesla. Všechny výstupní bajty zůstávají v paměti.
K Apple cíli se tento mock režim nikdy nepřipojuje. Výchozí režim umí pouze standardní verzi a odmítnutí
na autentizační hranici; nenabízí skrytou cestu k neautentizovanému přístupu.

## Stav, chyby a pevné limity

Tok: `version → security → securityResult → serverInit → ready → update → ready`.
Každá protokolová chyba přejde do terminálního `failed`; cancel / čisté EOF do `closed`.
Po chybě se zahodí buffer a pixely; další příjem či žádost skončí `terminal`. Nový pokus vyžaduje novou
instanci, ne automatické připojení nebo jiný auth typ. Chybné použití API žádosti vrací `invalidState`
bez změny stavu. Vyčerpaný rozpočet je terminální chyba.

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
16 bajtů a `network bytes sent: 0`. `--help` pouze popíše demo; neznámé argumenty skončí kódem 2.

Nejde o systémovou sondu: program nezjišťuje UID, audit session, displeje ani TCC a nic takového neměří.
Proto nezávisí na `spikes/common`. Požadavek GUIDE na kontrolu identity zůstává povinný pro budoucí
reálnou sondu, jak popisuje [LAB-NEXT.md](LAB-NEXT.md).

**Úklid:** program neukládá stav, nezakládá listenery a nemění služby. Sestavení vytváří pouze vlastní
adresář vypsaný v `A3_CHECK_DIR`; po kontrole přesné cesty jej lze uživatelsky odstranit. Žádný úklid
systému, účtů či služeb tento balík nepotřebuje.

## Co ještě brání klientu MVP

- Ověřený a reviewovaný Apple auth mechanismus s autentizací serveru a schválenou správou testovacích údajů.
- Vynucený výběr vlastní virtuální **uživatelské** relace bez tichého přechodu na host konzoli.
- Připnutí plochy na předem známé UID, bootstrap a přesné kladné audit session ID přes nezávislou sondu.
- Transport, okno, značení oblasti, potřebné encodings a kontrolovaný vstup; žádná automatická schránka.
- Uživatelův L1 důkaz souběhu tří relací, přežití/keeperu, GPU a TCC dle LAB; všechny další brány před F2.

Do té doby je plánovanou bootstrap cestou **Screen Sharing.app v uživatelském L1**, nikoli tento mock.
Ani tato cesta není tímto balíkem změřená nebo automaticky schválená jako bezpečný produkt.
