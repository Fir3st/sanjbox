# WP1.A3 — RFB research and offline client prototype

**Částečný výstup; A3 zůstává rozpracované.** Prototyp nyní čte skutečné délkově rámované
S5 SessionInfo a rozšířená ServerInit metadata podle připnuté klientské implementace.
Samostatné offline kodeky ověřují 74bajtový příkaz pro virtuální plochu a SessionResult.
Původní package-local výběrový protokol byl odstraněn. Integrovaný Apple tok ale **vždy skončí
před výběrem relace**: chybí reviewovaná politika povolení virtuálního příkazu. Nově prozkoumaný
S5 `session-select.js` testuje bit konzolového příkazu, ale virtuální command 2 vrací bez kontroly masky;
toto chování klienta není důkaz serverového oprávnění ani identity relace.
Type-30 auth stále používá pouze injekční rozhraní a syntetický mock; DH/MD5/AES nejsou implementované.

To není Apple klient, keeper ani důkaz S1. Není zde transport, socket, okno, načítání údajů,
Keychain ani přístup k systému. Všech 155 případů a všechny brány zůstávají **Neověřeno**.
Vazba: [PLAN §S1](../../PLAN.md#s1--neviditelná-relace-brána-celého-gui-návrhu),
[IMPLEMENTATION A3/WP2.10](../../docs/IMPLEMENTATION.md), C-001/F0.6; R1/R5, GUI-01…05,
GUI-10…13 a POS-08. Per-app R6 není součástí tohoto prototypu.

## Přesný rozsah

| Vrstva | Co je implementované | Co výsledek neznamená |
|---|---|---|
| Standardní RFB 3.8 | Bounded handshake s výslovným syntetickým None režimem, Raw framebuffer v paměti | Živá bezpečná autentizace nebo výběr macOS uživatele |
| S4 typ 30 | Generátor u16, délka u16, modulus a veřejný klíč stejné délky; odpověď provideru přesně `128 + keyLength` | DH/MD5/AES, identita serveru nebo šifrování transportu |
| S5 ServerInit | Marker, flags a 16bajtová bitmapa uvnitř jména | Význam bitmapy nebo identita plochy |
| S5 SessionInfo | Délka, verze, nezměněná maska, rezervované pole a jméno | Oprávnění provést jakýkoli příkaz |
| S5 SessionCommand | Samostatný interní kodek vytváří přesně 74 bajtů, pouze command 2 | Integrovaný klient jej nikdy neposílá; nemá potvrzenou autorizační politiku |
| S5 SessionResult | Samostatný interní kodek: granted 0/4, pending 2/3, ostatní denied | Klient výsledek nečeká ani jím neinicializuje plochu |

`AppleSessionRecordCodec` je interní a nemá I/O. Pozitivní testy příkazu a výsledku ověřují pouze
kodek. Integrovaný `RFBClient` ověřuje odmítnutí: po validním SessionInfo nastaví
`session == .unverified` a terminální `unverifiedSelectionPolicy`. Nevydá SessionCommand,
SetPixelFormat, SetEncodings ani `.initialized`. Konkrétní masku neoznačuje jako console-only nebo
virtual-ready, protože zde není ověřená politika virtuální autorizace. Žádný fallback na konzoli neexistuje.

## Zdrojový kontrakt a místní politika

Úplné citace a hashe jsou v [SOURCES.md](SOURCES.md). S4/S5 jsou primární **klientské zdroje**,
ne Apple-published specifikace ani capture. Implementace použila čtyři hashově ověřené místní kopie;
nové nezávislé review je stáhlo a ověřilo znovu přes HTTPS a přidalo inspekci a hash pátého souboru
`ard/session-select.js`. Žádný stažený kód se nespouštěl, nelinkoval ani nekopíroval do implementace.

| Záznam | S5 bajtový kontrakt (všechna vícebajtová čísla big-endian) |
|---|---|
| Extended ServerInit name | Nejméně 22 bajtů; byte 0 musí být NUL, byte 1 může být nenulový; flags na 2…5, bitmapa na 6…21, zbytek jména se nezveřejní |
| SessionInfo | `u16 bodySize`, `u16 version`, `u32 allowedCommands`, `u32 reserved`, zbývající bajty jména konzole; první NUL jméno ukončí |
| SessionCommand | `u16 72`, `u16 1`, čtyři nulové bajty, `u8 2`, nulový byte, 64bajtové pole jména; celkem 74 bajtů |
| SessionResult | `u16 bodySize`, `u16 version`, `u32 status`, libovolný zbývající rezervovaný obsah podle parseru S5 |

S5 čte jméno konzole jako jednotlivé Latin-1 code units a při zápisu je převádí do UTF-8, zkrátí na
63 **bajtů** a doplní nuly. Kodek reprodukuje i hranici uprostřed UTF-8 sekvence; nejde o doporučenou
politiku jmen. Username není přihlašovací údaj ani důkaz identity. Neuplatňuje se vlastní korekce UTF-8.
Komentář S5 u SessionResult uvádí 74 rezervovaných bajtů, ale jeho parser spotřebuje `bodySize - 6`;
zde se proto neprohlašuje jediná pevná délka 80 bajtů těla.

Místní konzervativní pravidla, nikoli tvrzení o serveru:

- Jen verze 1 (výstupní S5 encoder ji zapisuje; vstupní S5 parser verze neověřuje).
- Tělo SessionInfo 10…4096 bajtů, SessionResult 6…4096; přesná shoda celkové délky, žádný suffix.
- Pouze známé ServerInit flags `0x01/0x02/0x04/0x08`; neznámé bity se odmítnou.
- Chybějící session-select `0x04` nebo přítomné no-virtual-display `0x08` končí `sessionUnavailable`.
- Bitmapa a rezervované bajty jsou opaque; nejsou autorizačním důkazem a nemusí být nulové.
- Žádná hodnota allowed-command masky není autorizovaná, včetně nuly, všech jedniček a každého bitu zvlášť.

## Zbývající přesné mezery A3

1. **Kryptografie:** S4 vyžaduje finite-field DH s dodaným modulem, MD5 sdíleného výsledku a AES-ECB
   128bajtového bloku. V prohlédnutém veřejném SDK nebylo potvrzeno použitelné API pro toto DH.
   To není důkaz, že žádná varianta neexistuje. Vlastní bignum/crypto, privátní API ani nová závislost
   se nepřidává. Potřebný je zvlášť schválený a reviewovaný backend se syntetickými známými vektory.
2. **Výběrová politika:** připnutý `ard/session-select.js` je nyní přečtený a hashovaný. Popisuje
   jeden bit na příkaz a pro prázdné jméno konzole testuje `1 << sessionCmdConnectToConsole`;
   virtuální command 2 ale vrací bez ohledu na masku. Vlastník A3 musí doložit a reviewovat pravidla
   povolení virtuálního příkazu včetně nulových/neznámých masek a chybějící virtuální volby; samotné
   upstream obejití kontroly masky se nepřebírá. Pak zapojí command/result kodeky do klienta s testy
   pending, denial, deadline, společného message budgetu a zákazu konzolového fallbacku.
3. **Živý klient:** server identity, confidentialita, schválená správa údajů, transport/partial writes,
   monotónní deadlines, pixel/encoding interoperabilita a samostatná vazba na přesné UID/audit session.
   To patří do následného review a uživatelského [LAB-NEXT](LAB-NEXT.md), ne do těchto fixtures.

Není splněná celá offline podmínka A3. Screen Sharing.app/L1-D nadále může sloužit uživatelskému
průzkumu bez čekání na tento klient; žádná laboratorní závislost ani akceptace se tím nemění.

## Stav a rozpočty

Výchozí `rejectAll` odmítne autentizaci. `syntheticNoneOnly` přijme jen nabídku `[1]` a přesně
`RFB 003.008\n`; `syntheticAppleSubset` jen `[30]` a `RFB 003.889\n`. Smíšené nabídky, duplicity,
VNC/typ 33 a záměna bannerů se odmítnou. Bez provideru se Apple tok zastaví před auth odpovědí.
Prázdný, chybný nebo nesprávně dlouhý provider výsledek se nevydá. Mock obsah není kryptografie.

Apple tok končí `version → security → appleChallenge → securityResult → serverInit → session → failed`.
Standardní tok zůstává `version → security → securityResult → serverInit → ready → update → ready`.
Každá chyba zahodí vstup i pixely a je terminální. Události vrácené z dřívějších volání nelze odvolat;
chyba uvnitř jednoho `receive` nevrátí žádné události z daného volání. EOF během záznamu je `truncated`.
`expire()` pouze přijímá budoucí deadline; neobsahuje časovač. Neexistuje retry ani reconnect.

| Rozpočet | Mez |
|---|---:|
| Jeden chunk / celá instance | 64 KiB / 32 MiB |
| Šířka a výška / framebuffer / pixely jednoho update | 1…1024 / 4 MiB / 4 MiB |
| Jméno a důvod odmítnutí | 4096 bajtů |
| Obdélníky / standardní serverové zprávy / žádosti | 256 / 1024 / 64 |
| Nezpracovaný příjem | 4 MiB + 64 KiB |
| Apple DH šířka / provider odpověď | 1…512 / přesně 128 + šířka, navíc strop 4096 bajtů |
| Tělo S5 záznamu | 4096 bajtů |

S5 klient zmiňuje i inicializaci s rozměry 0×0; zdejší dřívější mez 1…1024 je nepřijme.
To je další omezení interoperability, nikoli tvrzení o neplatném serveru.

Standardní pixel format je 32bpp BGRX/depth24/little-endian/true-colour, pouze Raw.
Update je výslovně vyžádaný; nikdy dvě čekající žádosti. Bell nemá host efekt, clipboard ukončí parser.
Prázdný update může zpřístupnit nulový framebuffer; dokončení zprávy není důkaz úplného snímku,
identity plochy, GUI prezentace, GPU ani latence. Ostatní encodings, myš/klávesy, TLS a file transfer chybí.

## Offline ověření a úklid

**[implementátor]** Swift 6, bez externích balíčků. Z kořene repozitáře:

```bash
A3_CHECK_DIR=$(mktemp -d /private/tmp/sanjbox-a3-check.XXXXXX)
export CLANG_MODULE_CACHE_PATH="$A3_CHECK_DIR/modules"
export SWIFTPM_MODULECACHE_OVERRIDE="$A3_CHECK_DIR/modules"
swift test --disable-sandbox --package-path spikes/s1-rfb --configuration debug \
  --scratch-path "$A3_CHECK_DIR/build" --cache-path "$A3_CHECK_DIR/cache" \
  --config-path "$A3_CHECK_DIR/config" --security-path "$A3_CHECK_DIR/security" \
  -Xswiftc -module-cache-path -Xswiftc "$A3_CHECK_DIR/modules"
"$A3_CHECK_DIR/build/debug/sanjbox-rfb-fixture" --demo
```

Opakovat s `release` a samostatnými cestami. `--disable-sandbox` se týká pouze lokálního SwiftPM
manifestu, nikoli systémové ochrany. Demo provede standardní 2×2 Raw scénář a Apple odmítnutí politiky;
vypíše 52/150 vygenerovaných bajtů a `network bytes sent: 0`. Nemá argument hostu, portu nebo hesla.
Kryptografické hodnoty jsou konstantní mocky. `--help`/bez argumentů vrací 0, neplatné argumenty 2.

[SOURCES](SOURCES.md) eviduje provenance; [VALIDATION](VALIDATION.md) popisuje konkrétní testy/commit.
Není to systémová sonda: pro budoucí skutečné měření zůstává povinná kontrola identity podle GUIDE/LAB.
Úklid odstraňuje pouze vlastní ověřený scratch build/cache adresář. Žádné účty, listenery, TCC nebo
služby se nevytvářejí a není nutný jejich úklid. Historická validace zůstává zachovaná.
