# WP1.H6 — ověření offline přípravy

Ověřeno 2026-11-14 na Apple Silicon / macOS 27.2.1 (26B131), Apple Swift 6.4.2.
Testované zdroje: **`7d960069c1f19fa11007bf798dc2788a2b66b333`**,
základ `main` **`5d2005a6398249bcdbcebba0fd98928c29d193c0`**.
Claim **`6446a7996c6f42c11a5fbce4ae99eb64f422f585`** byl zveřejněn před implementací
na `origin/codex/wp1-h6-escape`; v době kontroly nebyl konkurenční claim ani otevřené PR.

## Spuštěné kontroly

| Příkaz | Výsledek |
|---|---|
| `swift test --package-path proto/escape --scratch-path /private/tmp/h6-swift-build -c debug` | **18 testů, 4 suites, 0 selhání**, test run 18,916 s. |
| `swift test --package-path proto/escape --scratch-path /private/tmp/h6-swift-release -c release` | **18 testů, 4 suites, 0 selhání**, test run 24,766 s. |
| `git diff --cached --check` před implementačním commitem | Bez chyby whitespace. |

Oba běhy sestavily a spustily skutečný lokální `sanjbox-counterpart` ve stejné debug/release
konfiguraci. Testy používají nové soukromé stromy a ephemeral IPv4 loopback TCP porty; jejich
scratch stromy se uklidily. Nebyl potřeba přepínač pro opt-in síťových testů, zařízení, účet,
privilegovaná operace, změna systémové konfigurace, TCC grant ani skutečná oblast.

## Co testy skutečně prokázaly

- **155 přesných a unikátních ID:** ručně připnutý nezávislý literál se porovnává s katalogem
  i aktuální COVERAGE §3; shodují se také titul, požadavky a brána. Chybějící/duplicitní řádek,
  neúplný oracle nebo nesprávné svázání sondy jsou odmítnuty. Odstranění ID z obou zdrojů
  nezmění očekávání testu.
- **Osm syntetických úspěchů**, 133 ručních a 14 nepodporovaných případů. Kompletní report
  i skutečné CLI vracejí `incomplete` / exit **3** a všech 155 `acceptanceStatus` je `unverified`.
  Ruční a nepodporovaný případ odmítají stát se pass i s vloženou dokonale úspěšnou observation.
- **Vlastní souborové stromy:** pozitivní kontroly přečtou vlastní kanárky; mock odmítá cizí root,
  symlink, hardlink, traversal a zvláštní soubor. Chybějící soubor je chyba, nikoli důkaz zamítnutí.
  Záměrně propustná fixture dá FS-01 `syntheticFailed` a souhrnný exit **1**.
- **H1 modely:** start ve `stopping`/`stopped` je odmítnut bez změny stavu/identity; návrhové UID
  se uvolní až při `cleaned`. Helper i broker dekodéry přijmou validní controls a odmítnou osm
  konkrétních neplatných wire fixtures. Návrhová UID se nikdy nepoužívají k OS operacím.
- **Skutečná protistrana:** samostatné listen/report procesy přijmou před/po kontrolní kanárky
  a povolenou NET-12 fixture s přesnými raw bajty; izolovaný NET-02 běh má nula kontaktů/bajtů.
  Záměrný bypass opravdu otevře TCP a odešle kanárek: NET-02 se změní na `syntheticFailed`, exit **1**.
  Odebrání závěrečného `stopped` z vlastního logu opravdu vrátí report exit **3** a NET-02 `incomplete`.
  Nulabajtové TCP spojení nevyhoví oracle „žádný kontakt“; nesprávné raw bajty, kanárek, počty,
  neúplný report nebo nesouhlas exit kódu nemohou potvrdit pozitivní kontrolu.
- **Neúplnost a identita:** chybějící pokus, kontrola, úplnost nebo shodná identita nemohou projít.
  Injektovaný identity mismatch ukončí runner před fixture/protistranou a nevytvoří audit akcí.
- **H1 audit:** `AuditLog.decode` přečte výstup runneru s akcemi `zone.created`,
  `gate.request.denied`, `zone.cleaned`, sekvencí 1–3, stejnou oblastí a skutečným actor UID.
  Neplatná sekvence i vymyšlená akce jsou odmítnuty původním H1 kontraktem.
- **Úklid a CLI:** úklid je idempotentní, symlink nesmaže cíl mimo vlastní strom a výměna kořene
  je odmítnuta. Timeout ukončí vlastní testovací proces. CLI bez argumentů vypíše přesný katalog;
  `run` bez `--apply` vrátí **2**; platný úplný syntetický běh vrátí **3**.

## Hranice a předání

Toto je ověření **přípravného balíku**, žádný laboratorní důkaz. Stejné UID, mock rozhodnutí,
krátké loopback intervaly, H1 model a wire validace neprokazují izolaci procesů/sítě/souborů,
konkrétní systémovou identitu klienta, globální UID allocator, APFS, whole-UID admission,
TCC/podpisy, XPC transport/Mach práva, fyzická zařízení nebo skutečné integrační účty.
Katalog popisuje cílové kroky, ne potvrzení jejich provedení. Skutečný běh pod UID oblasti
patří až do WP2.8/laboratoře s příslušnými branami, přeregistrací a nezávislým review.

COVERAGE se mění pouze v řádku **WP1.H6**. Jeho ✅ znamená dokončený katalog, runner a testy;
všech 155 akceptací, brány a R1–R8 zůstávají beze změny. Sdílené kontrakty/WP0.3/WP0.4 ani
historické protokoly nebyly upraveny. Podrobné bezpečné spuštění a omezení: [README](README.md).
