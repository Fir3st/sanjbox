# D4 redirect → skutečný handler — validační dodatek 2026-11-06

Finální nativní **Release: 54/54 testů prošlo, 0 failures, 0 skipped, 0 compiler warnings**,
včetně čtyř původních opt-in npm testů. Přibylo **12 testových metod** pro integraci redirectů;
původních 42 testů a jejich [historický důkaz](VALIDATION-HANDLER.md) zůstává zachováno.

Původní matice 40 artefaktových scénářů znovu dala **28 matched / 12 incomplete / 0 mismatched**.
Není označena jako plná akceptace. Korpus šesti redirectů je samostatný: CDN 200, same-host
rebinding 502 bez čtvrtého dialu, loopback/downgrade/userinfo/unapproved-origin 403 bez dialu
na odmítnutý cíl. Žádná chybová odpověď nevydala archive bytes ani nový download audit.
Důvod generické 403/502 zůstává nepozorovatelný.

Adaptér, přesné hraniční kontroly a audit `prepared` proti původnímu loopback
`transportAccepted`: [HANDLER-INTEGRATION.md](HANDLER-INTEGRATION.md#doplněk-původní-redirect-korpus-přes-d2).
Testy používají skutečné `NPMGateway` a `UpstreamClient` se stávajícími testovými seamy.
Zdroj `s5-gateway` ani `common` se nemění; produkční API/SSRF/TLS politika nejsou rozšířeny.

## Původní záznam a publikovaná diagnostická kopie

Autor: janfiedler / Codex + Astra, implementační worker D4. Stroj `LAB-janfiedler-01 / r1`:
MacBookPro17,1, Apple M1, 16 GiB, arm64; aktuálně macOS 27.2 (26B123), Xcode 27.2 (27B52),
Swift 6.4.2, existující Node v26.13.0 a npm 11.20.0. Záznam aktuálního toolchainu nenahrazuje
historické prostředí jiného běhu. Toto není L5 ani výkonové měření; ostatní pracovníci na
stroji pracovali nezávisle.

[Adresář záznamu](validation/redirect/20261106T114745Z-janfiedler-LAB-janfiedler-01-r1-4d98e62b/)
obsahuje:

- [receipt.json](validation/redirect/20261106T114745Z-janfiedler-LAB-janfiedler-01-r1-4d98e62b/receipt.json),
  [environment.txt](validation/redirect/20261106T114745Z-janfiedler-LAB-janfiedler-01-r1-4d98e62b/environment.txt)
  a [commands.txt](validation/redirect/20261106T114745Z-janfiedler-LAB-janfiedler-01-r1-4d98e62b/commands.txt);
- [finální raw Release log](validation/redirect/20261106T114745Z-janfiedler-LAB-janfiedler-01-r1-4d98e62b/04-final-release.log),
  [šest pozorovaných výsledků](validation/redirect/20261106T114745Z-janfiedler-LAB-janfiedler-01-r1-4d98e62b/observed-corpus.txt),
  [152 pozorovaných událostí](validation/redirect/20261106T114745Z-janfiedler-LAB-janfiedler-01-r1-4d98e62b/observed-trace.txt)
  a [původní matici 40](validation/redirect/20261106T114745Z-janfiedler-LAB-janfiedler-01-r1-4d98e62b/original-forty-scenarios.txt);
- [tested-source.sha256](validation/redirect/20261106T114745Z-janfiedler-LAB-janfiedler-01-r1-4d98e62b/tested-source.sha256)
  pro všechny D4 Swift zdroje/testy a lokální manifesty/zdroje gateway/common; každý soubor byl
  porovnán s testovaným commitem před hashováním. Cesty jsou relativní ke kořeni repozitáře;
- [cleanup.txt](validation/redirect/20261106T114745Z-janfiedler-LAB-janfiedler-01-r1-4d98e62b/cleanup.txt)
  a [manifest.sha256](validation/redirect/20261106T114745Z-janfiedler-LAB-janfiedler-01-r1-4d98e62b/manifest.sha256)
  všech souborů aktuální publikované kopie kromě manifestu samotného.

### Normalizace jediné pracovní cesty (publikační metadata)

Původní publikace commitu `a8fe29c5451ecc866c73a51f88fe2146504b6693` je zachována
**přesně beze změny** v soukromém adresáři
`/private/tmp/sanjbox-d4-publication-original-c6us1ldj/original-publication`:
všech 16 souborů původního manifestu i původní manifest, ověřené původními hashi.
Adresáře mají režim 0700 a soubory 0600. Tato kopie vznikla před změnou veřejných bajtů.

Veřejný `commands.txt` je nyní výslovně **diagnostická odvozená kopie**: jediná absolutní
pracovní cesta na prvním řádku byla nahrazena přenositelným `<REPO_ROOT>`. Ostatní bajty
souboru jsou stejné. [publication.json](validation/redirect/20261106T114745Z-janfiedler-LAB-janfiedler-01-r1-4d98e62b/publication.json)
uvádí původní i publikovaný SHA-256 příkazového záznamu, SHA-256 původního manifestu,
přesné místo a počet nahrazení, hash původní hodnoty i cestu k soukromému přesnému mapování.
Původní osobní cesta se tímto mapováním znovu nezveřejňuje.

Aktuální veřejný manifest má **17 položek**: 16 původních souborů (z nich pouze
`commands.txt` je odvozená kopie) a nový publikační záznam. Původní 16položkový manifest
zůstává v soukromém archivu. Všech dalších 15 původních souborů, včetně `receipt.json`,
raw výsledků, 152 trace událostí a všech 61 zdrojových hashů, má původní bajty. Historické
počty a testovaný zdroj `649f45325b4d91700a9928549a331c0c3d548333` zůstávají stejné.
Tato změna je pouze publikační: neproběhl nový test, měření ani změna runtime zdrojů.

Čistý základ byl `dd058d3f4e758ed7fdef7dc64eba1c9a34a66967`; první commit `e875fb8` převzal
pouze vlastní řádek D4. Finální měřený zdroj je
**`649f45325b4d91700a9928549a331c0c3d548333`**. Následující commit obsahuje jen dokumentaci,
coverage a tento nový důkaz. Build používal `--jobs 2` a vlastní izolované `/private/tmp`
adresáře; žádné nástroje se neinstalovaly. Výhradně původní npm regrese otevírají vlastní
exact-loopback listener, nové redirect testy nevytvářejí žádné sockety.

## Zachované běhy a opravné kroky

| Raw záznam | Zdroj | Výsledek |
|---|---|---|
| `01-targeted-release.log` | `7ccf0bbc12853a1ddb778da18ca165d87cdb6bc8` | 12/12 nových metod, bez skips |
| `02-full-release.log` | `464bb25974b946e711974784bfa24e51ac43c4b3` | 54/54, bez skips |
| `03-targeted-observed.stdout.log` + `.stderr.log` | `464bb25974b946e711974784bfa24e51ac43c4b3` | 12/12; pokus o oddělení diagnostického výstupu |
| `04-final-release.log` | `649f45325b4d91700a9928549a331c0c3d548333` | 54/54, bez skips; 152 souvislých trace událostí |

Běhy 02/03 prošly, ale `print` buffering promíchal jeden trace řádek s XCTest diagnostikou.
Oba raw logy jsou zachované. Zdroj byl opraven na jeden přímý zápis krátkého řádku; finální
běh byl znovu proveden a úplnost indexů i formát všech trace událostí ověřeny z logu.
Nejde o odstraněné selhání testu ani doplnění očekávaného výsledku do pozorování.

Zachovány jsou také dva neúspěšné preflight záznamy `00-…-failed.txt`: npm verze odmítla
stejnou cestu `/dev/null` pro user/global config; oprava použila dva vlastní prázdné soubory.
První read-only hardware dotaz blokoval tool sandbox a první cesta k `date` byla chybná;
metadata byla následně přečtena s explicitní eskalací a správnou cestou. Tyto chyby nejsou
počítány jako prošlé testy. Žádný build ani test v tomto dodatku neselhal.

Před úklidem nezbyl žádný vlastní npm fixture adresář. Odstraněny byly pouze přesně ověřené
vlastní build/cache/module/tmp/config/home adresáře a dva prázdné npmrc soubory; malé logy
zůstaly. Žádné systémové služby, pf, TCC, uživatelé, certifikáty ani cizí worktree se neměnily.

S5/D7/L5, živé registry/DNS/TLS, identita oblasti, OAuth/F0.7 a výkon zůstávají neověřené.
Nový důkaz nepřepisuje žádný předchozí běh ani akceptační stav.
