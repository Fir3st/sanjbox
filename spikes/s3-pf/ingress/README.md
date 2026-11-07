# WP1.C3 — nezávislá příprava ingress/bind

**Offline příprava WP1.C3 je hotová: [návrh bind policy](BIND-POLICY.md) je zapsaný podle
[IMPLEMENTATION §0](../../../docs/IMPLEMENTATION.md). S3b, NET-10…12 a R2/R3 zůstávají Neověřeno.**
Tento samostatný Swift 6.4 balík dodává scénáře a přístroj; neimplementuje vynucovací mechanismus
ani nedokazuje izolaci. Dílčí offline C1/common adapter podporuje také explicitní
`sanjboxNetworkProvenanceV1` s přesnými vloženými raw bajty. Autentizace peeru, nezávislý capture,
vynucení bind policy a skutečný uživatelský běh patří do WP1.C4/L4 a zůstávají otevřené.
Nevychází z kódu neintegrovaných větví; jediná závislost je lokální veřejné API `../../common`
(`ProbeContext`, `ProbeExpectation` a Codable modely `SanjboxNetworkProvenance`). Offline `link`
nevolá jejich živé preflight/capture operace.

## Co lze provést nyní

- `plan` (i žádné argumenty): přesný dry-run, bez socketů, souborů a sběru identity.
- `identity`: pouze vlastní UID/GID, skupiny, audit/bootstrap/window session; žádná jména, cizí PID ani Keychain.
- `smoke --expect-json JSON`: validace syntaktického očekávání, stále dry-run. `--apply` navíc nejdřív
  ověří přesnou identitu/session a vlastní podpis, pak provede TCP transport control výhradně na
  `127.0.0.1:0` a `[::1]:0`. Port se bere ze skutečného `getsockname`; uživatel nemůže zadat port ani host.
- `evaluate`: čisté offline vyhodnocení JSON ze stdin. Neprovádí sběr identity, systémových metadat ani sítě.
- `link`: offline [C1/common raw adapter](ADAPTER.md), přesné dostupné vazby, explicitní mezery a zachované findings; bez sběru nebo automatického pass.
- `cleanup --run-id UUID`: dry-run ověření vlastních dvou souborů; `--apply` provede jejich ne-rekurzivní úklid.

Žádný režim neotevírá wildcard listener, LAN ani externí spojení. Není zde obecný runner příkazů,
PID, služeb nebo cest. Není zde čtení ani změna pf, capture, TCC, uživatelů či systémové konfigurace.
Wildcard/LAN scénáře jsou pouze položky offline matice a runbooku. Žádné skryté přepnutí je neaktivuje.

## Build a lokální použití

**[implementátor]** Bez externích balíčků, SDK a Swift 6.4; scratch/cache mimo repo. Používá se release
nativní SwiftPM build, aby se nevytvářely debug testovací binárky s `get-task-allow`.

```sh
export CLANG_MODULE_CACHE_PATH=/private/tmp/sanjbox-c3-clang-cache
export SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/sanjbox-c3-module-cache
swift test --package-path spikes/s3-pf/ingress \
  --scratch-path /private/tmp/sanjbox-c3-build-native --cache-path /private/tmp/sanjbox-c3-cache \
  --disable-sandbox --build-system native -c release --disable-xctest
swift build --package-path spikes/s3-pf/ingress \
  --scratch-path /private/tmp/sanjbox-c3-build-native --cache-path /private/tmp/sanjbox-c3-cache \
  --disable-sandbox --build-system native -c release
```

Po **posledním** buildu lokální CLI znovu podepsat ad-hoc s hardened runtime a prázdnými entitlements;
ad-hoc podpis je předpoklad syntetického přístroje, nikoli S8/Personal Team/TCC důkaz. Příklad s vlastním
souborem, který vytvoří shell create-new:

```sh
set -euo pipefail
( set -C; cat > /private/tmp/sanjbox-c3-empty-entitlements.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict/></plist>
PLIST
)
# Pokud soubor existuje, nejprve jej ručně ověřit; nepřepisovat slepě.
C3_BIN=/private/tmp/sanjbox-c3-build-native/release/sanjbox-ingress
/usr/bin/codesign --force --sign - --options runtime \
  --entitlements /private/tmp/sanjbox-c3-empty-entitlements.plist "$C3_BIN"
/usr/bin/codesign --verify --strict "$C3_BIN"
"$C3_BIN" plan
"$C3_BIN" identity
```

Výstup `identity` je pouze pozorování. **Před** spuštěním sítě operátor zkontroluje a explicitně zafixuje
celý JSON jako `--expect-json` (včetně přesného audit ID, audit UID/flags, real/effective UID/GID,
seřazené unikátní sady kernel groups, manager name/UID a všech window polí; žádná automatická akceptace
„vezmi právě zjištěné hodnoty“ v CLI). `requiredGroups` a `forbiddenGroups` jsou autoritativně ověřované
přes membership API, bez duplicit a průniku. Neexistující session se vyjadřuje čtyřmi `null`; částečná
window identita je odmítnuta. Po změně session je třeba nový zkontrolovaný předpoklad, nikoli zmírnit kontrolu.

```sh
# EXPECTED_JSON obsahuje předem zkontrolovaný přesný JSON, ne příkaz k jeho automatickému odvození.
"$C3_BIN" smoke --expect-json "$EXPECTED_JSON"         # dry-run
"$C3_BIN" smoke --expect-json "$EXPECTED_JSON" --apply # vlastní loopback synthetic smoke
# stdout obsahuje nové runID a cestu; report.json obsahuje raw operace, errno, bajty, vlastní identitu.
"$C3_BIN" cleanup --run-id "$C3_RUN_ID"               # zkontrolovat
"$C3_BIN" cleanup --run-id "$C3_RUN_ID" --apply
```

Živá sonda odmítne nepřesnou identitu, neplatný podpis, absenci runtime nebo **přítomnost**
`com.apple.security.get-task-allow`/`get-task-allow` i s hodnotou false. Raw entitlement metadata bez
čitelného decoded dictionary jsou neplatná. Čte jen vlastní Security code metadata; validace má
`kSecCSNoNetworkAccess` podle lokálního SDK `Security/CSCommon.h`. Žádné dotazování Klíčenky.

## Co smoke měří a jeho meze

Jediný producent v `LoopbackSmoke` otevře vlastní nonblocking TCP listener s backlog 1, bez reuse
voleb. V každé rodině provede nonce echo před kolizí, pokus dalšího vlastního socketu na právě drženém
endpointu (vyžaduje skutečné `EADDRINUSE`), uzavření listeneru, rebind stejného přiděleného portu a druhé
nonce echo. Čerstvé payloady obsahují UUID běhu; příjem i echo se porovnají byte-for-byte. `accepted`
se zaznamená před čtením payloadu. Klient zahajuje FIN, obě strany musí doložit EOF, pak zavřou fd.

Všechny sockety jsou nonblocking, buffery mají nejvýše 128 B, dvě rodiny sdílejí 8s monotonic deadline.
Každý poll nejvýše 100 ms, žádné detached tasks, potom uzavření všech vlastních fd i při chybě.
IPv6 missing se vydá pouze při `socket` EAFNOSUPPORT/EPROTONOSUPPORT nebo `bind(::1)` EADDRNOTAVAIL;
EPERM, timeout či jiná chyba je failed transport control. Missing není pass a CLI vrátí 3.

Sběrač identity používá dvě pevná `launchctl managername/manageruid` volání přes `posix_spawn`,
nejvýše 128 B, deadline 2 s na child, TERM grace 200 ms + KILL/reap budget 500 ms. Vyžaduje SIGCHLD
SIG_DFL bez SA_NOCLDWAIT a vlastní výhradní `waitpid`; po ztrátě vlastnictví PID nikdy neposílá signál.
Nevyužívá neomezené subprocess I/O v common `capture()`. Systémové identity/Security/membership dotazy,
scheduling a filesystem fsync nemají realtime garanci; 8 s je rozpočet socketové fáze, ne tvrzení
pevné celkové wall-clock doby operačního systému.

**Same process, UID a session nejsou same-zone proof.** Smoke nemá nezávislý oracle a nezkouší
cross-UID/host/LAN hranici. Ephemeral collision není NET-11 s chráněným pevným host portem. Dvě
úspěšná echo nejsou výsledek NET-12. Nulu payloadu nelze zaměnit za nulu kontaktů ani packetů.

## Offline schema a výsledky

```sh
printf '%s\n' '{"schemaVersion":1,"runID":"11111111-1111-4111-8111-111111111111","cells":[]}' \
  | "$C3_BIN" evaluate
```

Úplný typovaný formát je v `Sources/IngressKit/Evidence.swift`, spustitelné adversarial fixtures v
`Tests/IngressKitTests/IngressTests.swift`. Decoder odmítá neznámé i duplicitní klíče (také escaped),
nesprávné typy, enumy, překryvy skupin, chybné UUID, duplicitní buňky/role, neexistující actor instance,
nesprávný run nonce, nereálné časové pořadí/stage, actor-kind spoofing a reuse flow ID mezi nesouvisejícími stages (pokračování test → drain je povolené).
Vstup ≤1 MiB, hloubka <24, ≤28 buněk, ≤3 participantů a ≤256 events/buňku, čísla mají pevné meze.
Stdin má 2s deadline. CLI nepřijímá cestu k evidence souboru; shell redirection je výslovná volba operátora.

`roles` předregistruje host, zone, otherZone a případně LAN identitu. Tři target role vyžadují různé
UID a audit sessions. Participant expected/observed musí přesně souhlasit s daným směrem, nikoli jen
navzájem; oracle má samostatný proces. `onConsole` se nepoužívá jako univerzální identifikátor role.
Záznamy pozitivních kontrol před/po musí obsahovat konzistentní sequence attempt → connected → accepted
→ listener handshake → initiator handshake → closed pro tutéž flow a nonce, plus nezávislý packet contact.
Listener i capture musejí pokrývat celé okno včetně kontrol a drainu; neznámé losses/gaps/retry/RTT/clock
nebo krátký drain jsou chybějící důkaz. Skutečný 60s+600s L4 protokol zde není. Navazující dílčí offline adapter viz [ADAPTER.md](ADAPTER.md).

Stávající offline výstup obsahuje 28 kombinací IPv4/IPv6 × loopback/wildcard × 7 směrů/operací.
To není úplná L4 předregistrace: [bind policy §4](BIND-POLICY.md#4-mapování-na-net-10-net-11-net-12)
navíc požaduje samostatné TCP/UDP buňky a doložené umístění oracle vůči ochranné hranici.
Tento návrh nepřidává tato pole ani nové živé scénáře do CLI. Význam jeho výstupů:

| Výsledek | Význam |
|---|---|
| `notMeasured` | Chybějící buňka nebo planned; žádné měření. |
| `mockOnly` / `mockFinding` | Syntetická fixture; nic netvrdí o reálné hranici. |
| `invalidMeasurement` | Chybějící/nesprávné identity, podpis nebo preregistrované role. |
| `incomplete` | Chybí kontroly, časové/capture pokrytí, expected counterpart/handshake nebo integrační adapter. |
| `observedViolationNeedsReview` | Přijatý kontakt, payload či nabytí host portu při platné deklarované identitě; finding se neztratí kvůli neúplnému capture. |

**Žádný vstup nedá pass.** Samostatný `evaluate` nemá raw bindings. Nový příkaz
`link < adapter-input.json` propojuje skutečný C1 RunRecord stream, common counterpart JSONL,
ingress matrix a oddělený packet import; kontroluje dostupné tuple/canary/identity/time vazby
a vydává deterministický report. [Formát, příklady, producer zdroje a přesné mezery](ADAPTER.md).
Legacy C1/common wire formáty nemají úplná run/flow/tuple/identity metadata; nový opt-in
`sanjboxNetworkProvenanceV1` tuto část doplňuje podle ADAPTER. Nezávislý capture a atestaci
adapter nedopočítává. Dodaný JSON včetně signing booleans je tvrzení, nikoli atestace.
Findings v raw zůstávají i při neplatné/neúplné jiné evidence. Reviewer musí ověřit jejich
původ, identity, clock/capture topologii a mechanismus hranice. Raw packet finding ani
`observedViolationNeedsReview` není automatický verdikt porušení: odmítnutý pokus před hranicí
a skutečný průchod/doručení se rozlišují podle BIND-POLICY §4. Dokončená příprava C3 tyto
L4 důkazy nenahrazuje; S3b/NET-10…12 zůstávají Neověřeno.

## Vlastní výstupy a úklid

Každý smoke použije nový `/private/tmp/sanjbox-c3-run-<UUID>` (mkdir create-new), 0700, vlastní UID/GID;
uvnitř jen `report.json` a `state.json` (0600, O_EXCL/no-follow). Stav obsahuje UUID, inode/device/size a
SHA-256 reportu. Žádný overwrite, append, obecná cesta nebo rekurzivní mazání.

Cleanup nejprve ověří všechny položky, vlastníka/skupinu, typ, módy, nlink, nulové flags, absenci extended
ACL, inode, velikost a hash. Neznámá položka, symlink/hardlink, změna obsahu/ACL/GID/flags/módu nebo
neúplný manifest zachová všechny soubory. Nepřítomný celý adresář je idempotentní `alreadyAbsent`;
chybějící jeden soubor je konflikt, nikoli claim crash-resume. Selhání po prvním unlink se hlásí jako
neúplný úklid, zbytky se nevynucují. Operátor má při cleanup zastavit jiné zapisující procesy stejného UID:
descriptor-relative preflight není atomická compare-and-unlink operace proti úmyslnému souběžnému same-UID
útočníkovi. To není navrhovaná bezpečnostní hranice produktu. Raw výsledky před smazáním ručně zkontrolovat;
publikované gate důkazy se v tomto balíku nevytvářejí a nikdy se nepřepisují.

Návrh skutečné hranice a uživatelského L4: [LABPLAN.md](LABPLAN.md). Návrh bind policy (spec, nic neověřeno): [BIND-POLICY.md](BIND-POLICY.md). Stav ověření: [VALIDATION.md](VALIDATION.md).

Nový offline consumer má samostatný [validační index](NETWORK-ADAPTER-VALIDATION.md) s připnutým source commitem, přesnými raw/log hashi a zachovanými neúspěšnými vývojovými pokusy.
