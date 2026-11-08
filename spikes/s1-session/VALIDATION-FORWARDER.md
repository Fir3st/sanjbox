# WP1.A1 — oprava životního cyklu forwarderu (2026-11-08)

Samostatný bugfix follow-up z nezávislého review, nikoli nový běh A2/L1 nebo verdikt S1.
Testovaný source/test commit: `b0439c9a1746cea071a94198e62fc8d46c6ab64e`.
Host: macOS 27.2 (`26B123`), arm64, Xcode 27.2 (`27B52`), Swift 6.4.2
(`swiftlang-6.4.2.1.9`). Žádné instalace, účty, nastavení, TCC ani skutečné VNC spojení.

## Změna a výsledky

Listener má vlastněný životní cyklus včetně chyb inicializace a `deinit`. Self-target se kontroluje
po `getsockname`, tedy i pro `--listen 0`. Kontrolují se výsledky `socket`, `SO_REUSEADDR`, `bind`,
`getsockname`, `listen` a přípravy target socketu / `SO_NOSIGPIPE`; chyba přípravy relay uvolní oba
vlastněné sockety. Interní initializer přijímá vlastněný bound socket, což umožňuje deterministický
test skutečného ephemeral self-targetu bez hádání portu; veřejné parametry a CLI defaults se nemění.

| Sada | Debug | Release | Oracle |
|---|---|---|---|
| `ForwarderLifecycleTests` | 6/6 | 6/6 | explicitní a skutečný ephemeral self-target; úklid po `getsockname` / `listen` chybě; deinit a 16 opakovaných uvolnění; opětovný bind původního portu, u pipe identita descriptoru odolná proti recyklaci čísla |
| `Tests/forwarder_lifecycle_cli.py` | 5/5 | 5/5 | CLI odmítne self-target před bannerem; duplex 204 800 B každým směrem; oba směry half-close s odpovědí až po EOF; čtyři odmítnutá spojení na port 0; dětské procesy ukončené a reapované |
| `Tests/forwarder_descriptor_audit.swift` | 3/3 | 3/3 (`-O`) | 16 zaniklých instancí: přírůstek FD 0; 16 odmítnutých bindů: přírůstek FD 0; explicitní self-target odmítnut |

**Negativní kontrola:** stejný standalone audit používající jen původní veřejné API byl zkompilován
s nezměněným `Forwarder.swift` z base `7b20c41496f9a8d2a8e49604e31c7598a4943adb`.
Zaznamenal **+16 FD po 16 zaniklých instancích**, self-target přijal a skončil kódem 1; chybné bindy
měly přírůstek 0 již před opravou. Nikdy nevolal `serve()` ani `connect()`, takže rekurzivní relay nevzniklo.

## Opakování na macOS

Z kořene checkoutu testovaného commitu (všechny build/module cache jsou vlastní dočasné soubory):

```bash
FORWARDER_SCRATCH=$(mktemp -d /private/tmp/sanjbox-forwarder-check-XXXXXX)
export CLANG_MODULE_CACHE_PATH="$FORWARDER_SCRATCH/modules"
export SWIFTPM_MODULECACHE_OVERRIDE="$FORWARDER_SCRATCH/modules"
for configuration in debug release; do
  swift test --package-path spikes/s1-session --scratch-path "$FORWARDER_SCRATCH/build" \
    --cache-path "$FORWARDER_SCRATCH/cache" --disable-sandbox -c "$configuration" -j 2 \
    --filter ForwarderLifecycleTests
  python3 spikes/s1-session/Tests/forwarder_lifecycle_cli.py \
    "$FORWARDER_SCRATCH/build/$configuration/sanjbox-s1-forward"
done
swiftc -module-cache-path "$FORWARDER_SCRATCH/modules" \
  spikes/s1-session/Sources/S1Forward/Forwarder.swift \
  spikes/s1-session/Tests/forwarder_descriptor_audit.swift -o "$FORWARDER_SCRATCH/audit"
"$FORWARDER_SCRATCH/audit"
# Pro optimalizovaný audit přidej swiftc přepínače -O -whole-module-optimization.
```

Audit běží v odděleném procesu a kontroluje pouze čísla vlastních FD v rozsahu 0..<4096; nové testovací
sockety musí ležet pod tímto stropem. Není to inventář procesů nebo souborů uživatele. CLI harness má
socketové/output/subprocess timeouty, omezené payloady a vždy ukončí a reapuje své děti.

První sandboxový běh odmítl `bind` (`Operation not permitted`); nativní běhy výše prošly. První CLI
fixture s bound-but-unlistening TCP cílem narazila na macOS čekající `connect`; nahradila ji portem 0,
na němž nemůže poslouchat živá služba. Tyto neúspěšné pokusy jsou zachované v lokálních malých logách
spolu s finálními výsledky a hashi v `/private/tmp/sanjbox-forwarder-lifecycle-BNMepQ`.

Spouštěla se pouze uvedená lokální podmnožina; celá S1 sada zahrnuje jiné GUI/Metal a same-UID procesní
sondy. `serve() -> Never`, páry copy vláken a procesové ukončení zůstávají původním modelem; `deinit`
není nový mechanismus zastavení běžícího serveru. Syscall allocation/setsockopt selhání nejsou uměle
vyvolávána. Skutečné Screen Sharing, tři relace, L1 a brána S1 zůstávají neověřené.
