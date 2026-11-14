# WP1.A3 — RFB research and offline client prototype

**Částečný výstup; A3 zůstává rozpracované.** Prototyp nyní integruje S5 SessionInfo,
74bajtový virtuální příkaz a SessionResult včetně pending/denial, společného message budgetu
a monotónního deadline. Výchozí výběrová politika stále odmítá všechny masky. Výslovné
`appleSelectionPolicy: .syntheticVirtualOnly` dovolí **jen generování offline fixture příkazu**,
pokud maska obsahuje bit 2 a žádné neznámé bity; nejde o důkaz oprávnění serveru.
Grant vždy skončí `unverifiedSessionIdentity` před inicializací/pixely: S2 připouští i sdílení
viditelné plochy, takže samotný virtuální příkaz a status neprokazují non-console UID/audit session.
Type-30 auth stále používá pouze injekční rozhraní a syntetický mock; DH/MD5/AES nejsou implementované.
[Průzkum backendu](AUTH-BACKEND.md) vymezuje konkrétní zbývající překážku.

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
| S5 SessionInfo | Délka, verze, maska, rezervované pole a jméno; místní opt-in politika | Serverové oprávnění nebo identita plochy |
| S5 SessionCommand | Přesně 74 bajtů, vždy command 2, nejvýš jednou | Živá autorizace; výchozí politika jej nevydá |
| S5 SessionResult | Integrované granted 0/4, pending 2/3, ostatní denied; rozpočty a deadline | Grant vždy skončí před chybějící nezávislou identitou, bez plochy |

`AppleSessionRecordCodec` je interní a nemá I/O. `RFBClient` s výchozí výběrovou politikou
`.rejectAll` po validním SessionInfo stále končí `unverifiedSelectionPolicy`. Explicitní
`.syntheticVirtualOnly` použije níže uvedenou místní podmínku, vydá jeden command 2 a čte výsledky.
Pending nepřeposílá příkaz ani neobnovuje deadline; denied je terminální. Grant nastaví
`session == .grantedUnverified` a terminální `unverifiedSessionIdentity`; nevydá SetPixelFormat,
SetEncodings ani `.initialized`. Žádná cesta nezpřístupní Apple framebuffer nebo konzolový fallback.

## Zdrojový kontrakt a místní politika

Úplné citace a hashe jsou v [SOURCES.md](SOURCES.md). S4/S5 jsou primární **klientské zdroje**,
ne Apple-published specifikace ani capture. Implementace použila čtyři hashově ověřené místní kopie;
předchozí nezávislé review je stáhlo a ověřilo znovu přes HTTPS a přidalo pátý soubor
`ard/session-select.js`. Tento follow-up znovu ověřil všech pět hashů v lokální cache bez nového fetch. Žádný stažený kód se nespouštěl, nelinkoval ani nekopíroval do implementace.

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
- Výchozí `.rejectAll` odmítá každou masku před výstupem příkazu.
- Opt-in `.syntheticVirtualOnly` vyžaduje `(mask & 4) != 0` a `(mask & ~7) == 0`: přijme jen
  `4/5/6/7`. Nula, console-only `1/2/3` a všechny neznámé bity včetně kombinace s virtual bitem se
  odmítnou. Známé alternativy console/request-console se nikdy nevolí. Jméno nerozhoduje o povolení.
  S5 popisuje jeden bit na příkaz a definuje command 2, ale tento check pro virtual neprovádí;
  zde jde o **přísnější místní podmínku**, ne nově objevený serverový kontrakt.
- Peer grant vždy končí před nezávislou identitou. Záznamy nemají kind discriminator; například
  další SessionInfo s maskou 4 může tvarem odpovídat SessionResult granted. Ani tak nevznikne plocha.

## Zbývající přesné mezery A3

1. **Kryptografie:** [AUTH-BACKEND](AUTH-BACKEND.md) dokládá SDK soubory a hashe: veřejné
   CommonCrypto/CryptoKit poskytují MD5/AES části, ale nebyl doložen vhodný podporovaný backend
   arbitrary-modulus finite-field DH. SecKey/CryptoKit EC agreement není S4; CDSA má staré DH
   deklarace, ale SDK jeho použití od macOS 10.7 výslovně nedoporučuje. Bez zvoleného a reviewovaného
   backendu nelze dodat celý provider ani pravdivé end-to-end known-answer testy. Žádná nová
   závislost, privátní API, vlastní bignum nebo náhradní crypto se nepřidává.
2. **Nezávislé review:** lokální výběrová politika a integrovaný command/result tok jsou dodané;
   vyžadují review. Původní podmínku A3 tato změna posouvá konkrétním integrovaným tokem, ale bez
   skutečného provideru ji celou nesplňuje. Další obecná příprava nenahrazuje rozhodnutí o backendu.
3. **Živý klient:** server identity, confidentialita, schválená správa údajů, transport/partial writes,
   naplánované monotónní idle/total wakeups, pixel/encoding interoperabilita a samostatná vazba na
   přesné UID/audit session. To patří do následného review a uživatelského [LAB-NEXT](LAB-NEXT.md).

Není splněná celá offline podmínka A3. Screen Sharing.app/L1-D nadále může sloužit uživatelskému
průzkumu bez čekání na tento klient; žádná laboratorní závislost ani akceptace se tím nemění.

## Stav a rozpočty

Výchozí `rejectAll` odmítne autentizaci. `syntheticNoneOnly` přijme jen nabídku `[1]` a přesně
`RFB 003.008\n`; `syntheticAppleSubset` jen `[30]` a `RFB 003.889\n`. Smíšené nabídky, duplicity,
VNC/typ 33 a záměna bannerů se odmítnou. Bez provideru se Apple tok zastaví před auth odpovědí.
Prázdný, chybný nebo nesprávně dlouhý provider výsledek se nevydá. Mock obsah není kryptografie.

Apple tok končí `version → security → appleChallenge → securityResult → serverInit → session → failed`;
uvnitř `session` může jen explicitní opt-in projít `requestedVirtual → pendingVirtual → grantedUnverified/denied`.
Standardní tok zůstává `version → security → securityResult → serverInit → ready → update → ready`.
Každá chyba zahodí vstup i pixely a je terminální. Události vrácené z dřívějších volání nelze odvolat;
chyba uvnitř jednoho `receive` nevrátí žádné události z daného volání. EOF během záznamu je `truncated`.
`receive(_:at:)` kontroluje pevný **30s celkový deadline od vytvoření příkazu** pomocí monotónního
`ContinuousClock`; explicitní instant je testovací seam. Čas se při pending/fragmentu/empty receive
neobnovuje, návrat času zpět je terminální `invalidClock`, přesná hranice už je `deadlineExceeded`.
Během ticha musí volající volat `receive([])` nebo `expire()`; žádný background časovač tu není.
Před vytvořením příkazu ani pro standardní tok tento specifický deadline neplatí. Budoucí transport
musí dodat časování celého handshake i idle/total wakeups. Neexistuje retry ani reconnect.

| Rozpočet | Mez |
|---|---:|
| Jeden chunk / celá instance | 64 KiB / 32 MiB |
| Šířka a výška / framebuffer / pixely jednoho update | 1…1024 / 4 MiB / 4 MiB |
| Jméno a důvod odmítnutí | 4096 bajtů |
| Obdélníky / společné serverové zprávy / žádosti | 256 / 1024 / 64 |
| Nezpracovaný příjem | 4 MiB + 64 KiB |
| Apple DH šířka / provider odpověď | 1…512 / přesně 128 + šířka, navíc strop 4096 bajtů |
| Tělo S5 záznamu | 4096 bajtů |
| S5 result wait | 30 sekund, pending limituje tentýž message budget |

SessionInfo i každý pending/final result spotřebuje jednu položku společného čítače používaného
i standardními serverovými zprávami. Fragmentace jej nenuluje ani nedebituje znovu; po jednom Info
zbývá 1023 výsledků, tedy nejvýš 1022 pending před posledním grant/denial. Hlavička dalšího výsledku
po vyčerpání končí `resourceLimit` ještě před čekáním na tělo.

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
manifestu, nikoli systémové ochrany. Demo provede standardní 2×2 Raw scénář a explicitně opt-in Apple command/pending/grant s odmítnutím identity;
vypíše 52/224 vygenerovaných bajtů a `network bytes sent: 0`. Nemá argument hostu, portu nebo hesla.
Kryptografické hodnoty jsou konstantní mocky. `--help`/bez argumentů vrací 0, neplatné argumenty 2.

[SOURCES](SOURCES.md) eviduje provenance; [VALIDATION](VALIDATION.md) popisuje konkrétní testy/commit.
Není to systémová sonda: pro budoucí skutečné měření zůstává povinná kontrola identity podle GUIDE/LAB.
Úklid odstraňuje pouze vlastní ověřený scratch build/cache adresář. Žádné účty, listenery, TCC nebo
služby se nevytvářejí a není nutný jejich úklid. Historická validace zůstává zachovaná.
