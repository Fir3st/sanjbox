# WP1.A3 — RFB research and offline client prototype

**Částečný výstup; A3 zůstává rozpracované.** Prototyp nyní integruje S5 SessionInfo,
74bajtový virtuální příkaz a SessionResult včetně pending/denial, společného message budgetu
a monotónního deadline. Výchozí výběrová politika stále odmítá všechny masky. Výslovné
`appleSelectionPolicy: .syntheticVirtualOnly` dovolí **jen generování offline fixture příkazu**,
pokud maska obsahuje bit 2 a žádné neznámé bity; nejde o důkaz oprávnění serveru.
Grant vždy skončí `unverifiedSessionIdentity` před inicializací/pixely: S2 připouští i sdílení
viditelné plochy, takže samotný virtuální příkaz a status neprokazují non-console UID/audit session.
Type-30 má nyní výslovně offline [syntetický provider](AUTH-PROVIDER.md): schválený připnutý
OpenSSL 3.5.9, vlastní jednorázový worker a nezávislé DH/MD5/AES/whole-response KATs.
Výchozí provider zůstává nil; starý CLI demo provider je nadále označený konstantní mock.

To není živý Apple klient, keeper ani důkaz S1. Není zde síťový transport, listener, okno,
načítání údajů nebo Keychain. Provider používá pouze lokální socketpair a vlastní child proces. Všech 155 případů a všechny brány zůstávají **Neověřeno**.
Vazba: [PLAN §S1](../../PLAN.md#s1--neviditelná-relace-brána-celého-gui-návrhu),
[IMPLEMENTATION A3/WP2.10](../../docs/IMPLEMENTATION.md), C-001/F0.6; R1/R5, GUI-01…05,
GUI-10…13 a POS-08. Per-app R6 není součástí tohoto prototypu.

## Přesný rozsah

| Vrstva | Co je implementované | Co výsledek neznamená |
|---|---|---|
| Standardní RFB 3.8 | Bounded handshake s výslovným syntetickým None režimem, Raw framebuffer v paměti | Živá bezpečná autentizace nebo výběr macOS uživatele |
| S4 typ 30 | Bounded framing a explicitní syntetický OpenSSL provider: safe-prime DH, MD5, AES-128-ECB, odpověď `128 + keyLength` | Identita serveru/relace, šifrování transportu nebo živá interoperabilita |
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
`ard/session-select.js`. Selection follow-up znovu ověřil všech pět hashů v lokální cache bez nového fetch; tehdy se žádný stažený kód nespouštěl ani nelinkoval. Následující explicitně schválený provider používá samostatně připnutý OpenSSL build podle [AUTH-PROVIDER](AUTH-PROVIDER.md).

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

1. **Dodaná offline část:** [AUTH-PROVIDER](AUTH-PROVIDER.md) implementuje schválený veřejný backend,
   safe-prime profil 1024–4096 efektivních bitů / nejvýš 512 wire bajtů, kontrolu rozsahu peer
   hodnoty bez obecného order-q tvrzení a nezávislé KATs. [Nezávislé integrační review #84](VALIDATION.md#independent-integration-review-of-pr-84-after-pr-83--2026-11-14)
   proběhlo po merge A6 #83 (`main` `b183737`) do větve. Koordinátor před merge #84 kontroluje CI
   přesného finálního headu; opakovaný výběr backendu ani další obecný crypto mock nejsou další úkol.
2. **Selection a identita:** [review #81](VALIDATION.md#integration-review-and-plan-handoff-for-pr-81--2026-11-14)
   platí pro lokální selection politiku a command/result tok. Provider neověřuje serverovou
   autorizaci ani non-console UID/audit identitu. Dosavadní vlastník nejprve vymezí trusted zdroj
   očekávané identity, vazbu na konkrétní spojení a nezávislé pozitivní/negativní kontroly včetně
   odmítnutí konzole a záměny relace; konkrétní živý postup předloží podle [LAB-NEXT](LAB-NEXT.md).
   Grant zůstává terminální refusal, dokud tyto důkazy chybí; A3 jako celek zůstává rozpracované.
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

**[implementátor]** Swift 6 / macOS 27 arm64 a explicitně schválený OpenSSL 3.5.9.
Přesné dry-run/provision/build/test/cleanup příkazy jsou v [AUTH-PROVIDER](AUTH-PROVIDER.md#reproduction-ci-and-cleanup).
Oba Swift příkazy potřebují připnuté include/archive flags; nepoužívat náhodný systémový OpenSSL.
Source/build/cache zůstávají ve vlastním temp stromu, license/provenance v tomto balíku.

`--disable-sandbox` se týká pouze lokálního SwiftPM manifestu. CLI `sanjbox-rfb-fixture --demo`
provádí původní standardní 2×2 Raw scénář a Apple command/pending/grant s odmítnutím identity;
vypíše 52/224 vygenerovaných bajtů a `network bytes sent: 0`. Nemá argument hostu, portu nebo hesla.
Jeho kryptografické hodnoty jsou stále výslovně konstantní mocky. Skutečný syntetický provider
ověřují `AppleCryptoTests` a `AppleProviderTests`, včetně fragmentovaných parser transcripts.
`--help`/bez argumentů vrací 0, neplatné argumenty 2.

[SOURCES](SOURCES.md) eviduje provenance; [VALIDATION](VALIDATION.md) popisuje konkrétní testy/commit.
Není to systémová sonda: pro budoucí skutečné měření zůstává povinná kontrola identity podle GUIDE/LAB.
Úklid odstraňuje pouze vlastní ověřený scratch build/cache adresář. Žádné účty, listenery, TCC nebo
služby se nevytvářejí a není nutný jejich úklid. Historická validace zůstává zachovaná.
