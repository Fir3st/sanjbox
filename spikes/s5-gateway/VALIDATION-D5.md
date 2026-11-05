# D5 — vývojová validace 2026-11-04

**Release: 101 testů prošlo, 0 skipped, 0 failures.** Z toho 20 nových D5 testů a 2 regrese
opravy zděděného deadline race. Testovaný kód je připnutý v
[tested-source.sha256](validation/wp1-d5/20261104T214435Z/tested-source.sha256);
[finální raw log](validation/wp1-d5/20261104T214435Z/raw/final-release.log).

Jde o vývojové fixtures, ne o laboratorní bránu. Žádné credentials/session měření oblasti,
F0.7 scopes/revokace ani veřejná integrace se neuskutečnily. D5 je **částečný** kvůli chybějícímu
Homebrew artifact publication-time; S5/S6, GW-16…18 a HB-04 zůstávají **Neověřeno**.

## Konfigurace a příkaz

- macOS 27.2 (26B123), arm64.
- Xcode 27.0 (27A266a), Apple Swift 6.4 (`swiftlang-6.4.0.34.1`).
- Skutečný lokální Git: `2.54.0 (Apple Git-157)`.
- Skutečný lokální Python/pip: Python 3.15 / pip 26.2.2; existující nástroje, bez instalace.
- Baseline `main afae1ca`, claim `2490d1c`, samostatná deadline oprava `ca4e50d`;
  finální D5 obsah při testu určuje source manifest, nikoli pozdější commit dokumentace.

Příkaz z kořene vyhrazeného worktree:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/sanjbox-d5-3coxyxk2/module-cache \
  swift test --package-path spikes/s5-gateway -c release \
  --scratch-path /private/tmp/sanjbox-d5-3coxyxk2/build \
  --cache-path /private/tmp/sanjbox-d5-3coxyxk2/cache --disable-sandbox
```

Hostitelský sandbox povolil kompilaci a lokální listenery. Žádné sudo, změny systému, skutečné
klíče/certifikáty, Keychain ani živé databáze. Stávající D1/D3 testy používají jen syntetické TLS
identity stejně jako před D5. D5 nevytváří žádnou TLS identitu.

## Co výsledek prokazuje

| Skupina | Testy / oracle | Druh |
|---|---|---|
| PyPI policy | 11: per-file hranice včetně mikrosekund, chybějící/invalid/future čas, projekt/verze/filename, SHA-256/size, status/yanked, duplicate JSON, přímé requests, metadata mutation, DNS rebinding, cizí auth/URL, redirect/304/HTML odmítnutí, deadline/cancel/capacity/audit | Syntetická metadata a bytes, D1 policy se scripted transportem |
| Homebrew | 3: správný digest a staré generated/published/upload datum stále nepovolí vydání; bottle/catalog/JWS/cask/tap bez upstreamu; vadná metadata/redirect/content-type odmítnuty | Mock schématu a deny handler |
| Git policy | 4: přesný projekt, dvě služby a metoda/media type/body limit; percent/traversal/extra query, cizí repo/auth/v2; redirect/401/dumb a velká odpověď odmítnuté | Mock smart HTTP response |
| pip klient | 1: stáhne pouze vytvořený metadata-only wheel přes skutečný GatewayServer; bytes/hash a transport audit odpovídají | Skutečný loopback klient/server; upstream mock |
| Git klient | 1: clone a push vlastního fixture repa, kontrola obsahu/commit ID; jiné repo se nedostane k backendu | Skutečný loopback klient/server; interní D1 transport spouští lokální git-http-backend |
| Deadline oprava | 2 nové přímé regrese plus existující npm orphan-audit test | Absolutní monotónní deadline a cancellation |
| D1–D3 baseline | Všech 79 stávajících testů včetně npm pack, TLS a model SSE | Beze změny akceptačních závěrů |

Git/pip mají explicitní cwd, nové prázdné profily a allowlist prostředí bez ambient auth/proxy.
Git hooks, podpisy, credential helper a v2 jsou vypnuté. Inicializační lokální file push zapisuje
jen vlastní bare fixture; síťové operace používají jen loopback. pip pouze `download --no-deps
--only-binary=:all:` — žádný install, sdist build ani package skript. Tyto testy nic nestahují z
veřejných registrů. Pip test je volitelně přeskočený jen při chybějícím `/opt/homebrew/bin/python3`;
v tomto běhu skutečně proběhl. Obsah Git repo a wheel nevychází ze skutečného projektu.

## Zděděná chyba deadline

Na `main afae1ca` koordinátor doložil CI failure testu
`npmDiscardedTimeoutOrCancelledChildCannotOrphanAuditCapacity`. Původní `boundedOperation`
přijímala první výsledek závodu task/timer, což dovolovalo pozdní úspěch při zpožděném naplánování
časovače. Samostatný commit `ca4e50d` používá společný absolutní ContinuousClock deadline,
kontroluje ho po child operaci i po dokončení task group a zachovává cancellation. Timer čeká do
téhož absolutního okamžiku. Pozdní výsledek se nevydá a nevytvoří orphan audit záznam. Test se
neskipuje, časový práh se touto opravou nezvyšuje; původní NPM regrese prošla i v plné sadě.

## Historie, úklid a reprodukce

[Adresář validace](validation/wp1-d5/20261104T214435Z/) zachovává i mezikroky: PyPI 10/10,
policy subset 20/20, první neúspěšný build client helperu (opravena Swift overload signatura),
klienty 2/2 a předchozí full Release 101/101. Autoritativní pro finální zdroje je pouze
`raw/final-release.log` spolu s `tested-source.sha256`. Žádný starší log nebyl přepsán výsledkem
nového běhu. [commands.txt](validation/wp1-d5/20261104T214435Z/commands.txt) obsahuje přesné příkazy.

Vlastní `/private/tmp/sanjbox-d5-3coxyxk2` byl ověřen jako adresář správného vlastníka bez symlinku
a odstraněn po zkopírování protokolů. Uvolněno **106 420 KiB** podle `du -sk`.
[Cleanup](validation/wp1-d5/20261104T214435Z/cleanup.txt) zůstává uložený. D5 klientské testy explicitně
hlásí chybu při neúspěšném úklidu vlastních fixture adresářů. V worktree nevznikla `.build` cache.
Při opakování použij nový unikátní scratch adresář; původní validační soubory se nemění.

Zbývající mezery a přesná kompatibilní podmnožina: [TYPED-REGISTRIES.md](TYPED-REGISTRIES.md).

`git diff --check` pro zdroje/dokumentaci prošel. Raw logy zůstaly byte-for-byte: obsahují CRLF
HTTP test vectors a původní mezery compiler diagnostics, proto jsou z whitespace kontroly vyjmuté.
