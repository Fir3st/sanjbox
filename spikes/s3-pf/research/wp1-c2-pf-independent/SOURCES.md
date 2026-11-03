# Primární zdroje a meze platnosti

**Všechny níže uvedené zdroje byly čteny 2026-11-03.** U živých webových dokumentů je to datum
přístupu, ne slib jejich neměnnosti. Citujeme obsah Apple dokumentace nebo odpověď označeného
Apple DTS inženýra; tvrzení návštěvníků fóra nepoužíváme jako platformovou záruku.

## Platforma této statické inspekce

`sw_vers` oznámil macOS **27.2**, build **26B123**; `uname -m` oznámil **arm64**.
`xcrun --show-sdk-path` vrátil `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk`, symlink na
`MacOSX27.2.sdk`. `xcrun --show-sdk-version` selhal při lookupu SDK, takže nezapisujeme úspěšnou
validaci toolchainu. Přímé čtení `SDKSettings.json` a níže vyjmenovaných hlaviček fungovalo;
JSON uvádí Version 27.2. Nebyla kompilace ani spuštění síťové sondy. Konkrétní model/čip/RAM,
boot policy a konfigurace laboratoře nebyly zjišťovány; pro tento dokument nejsou důkazem chování.

**Podpora produktu:** žádná verze/build tímto balíkem není kvalifikována. Místní header/man dokládá
pouze obsah této instalace. Výsledek pro jeden budoucí L4 build se nesmí převést na všechny 27.x,
Intel nebo všechny Apple Silicon modely. Minimum ve F0.8 je nadále návrh.

**OSS omezení:** GitHub API v den přístupu vrátilo XNU commit
`f6217f891ac0bb64f3d375211650a4c1ff8ca1ea` a mDNSResponder commit
`d4658af3f5f291311c6aee4210aa6d39bda82bbe`, oba s commit datem **2025-10-16**.
Odkazy níže jsou na tyto konkrétní revize, ne proměnlivé `main`. Nebyla doložena shoda tohoto OSS
s binárním macOS 27.2/26B123. Ze zdroje odvozujeme mechanismus v dané revizi, nikoli chování
nepublikovaných částí ani úplnost resolverové autorizace na cílovém OS. Hashe přesných stažených
souborů i lokálních podkladů obsahuje [static-inspection.json](static-inspection.json).

## Webová dokumentace a zdrojový kód

### S1 — PF není podporované produktové API

[Apple TN3165: Packet Filter is not API](https://developer.apple.com/documentation/technotes/tn3165-packet-filter-is-not-api),
sekce Overview, Packet Filter fundamentals, Test during the transition; revize 2024-02-27.
Platí pro produktové použití PF na macOS; uvádí riziko kolizí a doporučuje NE. Neříká, že příkaz
`pfctl` není dostupný administrátorovi nebo že každý PF produkt nutně propouští provoz.

### S2 — XNU PF datová cesta

[pf.c: `pf_socket_lookup`, ř. 4136–4235](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/net/pf.c#L4136-L4235),
[`pf_test`, ř. 9713–9740](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/net/pf.c#L9713-L9740),
[`pf_test6`, ř. 10338–10340](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/net/pf.c#L10338-L10340).
Statická evidence TCP/UDP PCB lookup včetně wildcard a bypassu vypnutého PF pro oba IP stacky.
Build omezení viz OSS výše; není to živý test macOS 27.

### S3 — XNU PF řídicí cesta

[pf_ioctl.c: default rule, ř. 508](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/net/pf_ioctl.c#L508),
[`DIOCSTOP` a `DIOCSTOPREF`, ř. 1659–1688](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/net/pf_ioctl.c#L1659-L1688).
Rozdíl unconditional stop a referenčního uvolnění; stejná OSS omezení jako S2.

### S4 — App Sandbox odchozí spojení

[com.apple.security.network.client](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.client),
Discussion včetně TCP/UDP poznámky. Veřejný macOS App Sandbox entitlement. Doloženo omezení TCP
iniciace, nikoli revokace již přenášených dat; dokument nepopisuje per-zone endpoint allowlist.

### S5 — App Sandbox příchozí spojení

[com.apple.security.network.server](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.server),
Discussion; také [Enabling App Sandbox — Enabling Network Access](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html).
Druhý dokument je archivovaný; používán pro vysvětlení entitlementů, ne jako certifikace macOS 27.

### S6 — Přímé dědění nezávisí na vlastním inherit entitlementu dítěte

[Apple DTS, On File System Permissions, thread 678819](https://developer.apple.com/forums/thread/678819),
sekce App Sandbox, odstavce začínající „Finally“, „IMPORTANT“ a „However“; poslední uvedená revize
2026-09-18. Konkrétní primární origin, nikoli agregovaný tag/search. Popisuje i `/bin/sh` a helpery
mimo Mac App Store. Neřeší všechny starty přes služby pod stejným UID.

### S7 — Praktická omezení inicializace sandboxu

[Apple DTS, Resolving App Sandbox Inheritance Problems, thread 706390](https://developer.apple.com/forums/thread/706390),
Nonheritable Entitlements, Changing Sandbox, Nothing to Inherit, původní příspěvek 2022-05.
Je to popis inicializačních chyb, nikoli důkaz potřeby přepodepsat všechny externí nástroje.

### S8 — Veřejný postup vloženého helperu

[Embedding a command-line tool in a sandboxed app](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app),
Create the helper tool target, Build and validate, Embed an externally built tool. Příklad má
macOS deployment 10.15 (arm64 11.0). Dva sandbox entitlements a absence `get-task-allow` patří k
uvedenému embedded-helper postupu; jeho App Store export není omezení všech přímých potomků.

### S9 — Network Extension, zde vyloučená varianta

[TN3134: Network Extension provider deployment](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment),
revize 2025-08-19; tabulky content filter, packet filter, DNS proxy, transparent proxy. Pro macOS
uvádí příslušné system extensions od 10.15 a rozdíl user/global lifecycle. Tabulka je deployment
podklad, nikoli důkaz R3. NE není součást povoleného řešení F0.5.

### S10 — Endpoint Security entitlement

[com.apple.developer.endpoint-security.client](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.endpoint-security.client),
availability macOS 10.15+, Discussion: nutná žádost Apple, `es_new_client` jinak NOT_ENTITLED.
Není zde tvrzení o konkrétním schválení/přidělení uživatelovu účtu.

### S11 — ES networking scope a jeho historická mez

[Build an Endpoint Security app — WWDC20, session 10159](https://developer.apple.com/videos/play/wwdc2020/10159/),
transcript odstavec o networking operations a Unix-domain sockets. Historický zdroj z roku 2020;
pro nové macOS 27 IPC události jej doplňují L5–L6, nelze z něj odvozovat jejich neexistenci.

### S12 — Nové ES descendants API

[es_new_descendants_client](https://developer.apple.com/documentation/endpointsecurity/es_new_descendants_client(_:_:)),
Discussion a Notes; dostupnost macOS 27.0 v L5. Popisuje subtree, notify pro volajícího, auth/notify
pro potomky, entitlement, absenci potřeby root/TCC. Web některé související nové API označuje Beta;
žádný produktový slib opřený jen o tuto rešerši nevzniká.

### S13 — MAC hooky nejsou userspace policy API

[XNU mac_socket.c, ř. 130–181](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/security/mac_socket.c#L130-L181),
[send, ř. 267–284](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/security/mac_socket.c#L267-L284),
[mac_policy.h, ř. 68–82](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/security/mac_policy.h#L68-L82).
Kernelové rozhraní a dispatch kontrol; neobsahuje tímto doložený kompletní Seatbelt profil pro náš
kontrakt. Stejné OSS/build omezení jako S2.

### S14 — KEXT a Apple Silicon boot policy

[Startup Disk security policy control for a Mac with Apple silicon](https://support.apple.com/en-gb/guide/security/sec7d92dc49f/web),
Reduced Security policy; Apple Platform Security, publikace 2021-02-18. Doložená nutnost Reduced
Security pro third-party KEXT a AuxKC/restart; netvrdíme ověřenou použitelnost konkrétního modulu
na macOS 27 ani neposkytujeme návod vypínat ochrany hosta.

### S15 — Interní NECP

[XNU necp.c, UID podmínka ř. 243](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/net/necp.c#L243),
[`necp_session_open`, ř. 1034–1053](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/net/necp.c#L1034-L1053).
Platformový podpis kontrolovaný před root/privilege podmínkou. Není důkaz, že neexistuje žádná jiná
budoucí API cesta; tuto konkrétní interní cestu nelze vydávat za běžné public API.

### S16 — Application Firewall

[Change Firewall settings on Mac, verze 27](https://support.apple.com/en-euro/guide/mac-help/mh11783/27/mac/27),
Firewall/Options a incoming výjimky; [Firewall security in macOS](https://support.apple.com/en-nz/guide/security/seca0e83763f/web),
publikace 2021-02-18. Dokumentovaný rozsah incoming/per-app/stealth, nikoli kompletní per-UID egress,
loopback a port-ownership policy. Místní CLI L9 odpovídá app/path nastavení.

### S17 — Kompatibilita a executable access

[Apple DTS, thread 807142](https://developer.apple.com/forums/thread/807142), odpověď DTS z 2025-11,
odstavce o static sandbox a spouštění CLI. Nevydáváme neúspěch jednotlivého tazatele za náš test;
používáme vysvětlení Apple a vyžadujeme vlastní pozitivní kompatibilitní matici.

### S18 — Služba spuštěná launchd není obyčejný spawn dítěte

[Apple DTS, thread 786363](https://developer.apple.com/forums/thread/786363), odpověď z 2025-06 o
XPC service/launchd agent a sandbox initialization. Důvod odlišit přímý fork/exec od požadavku na
novou službu. Konkrétní tamní Virtualization případ není měřením Sanďboxu.

### S19 — Resolver přenáší klientskou identitu; úplný deny není doložen

[mDNSResponder uds_daemon.c, ř. 3949–3952](https://github.com/apple-oss-distributions/mDNSResponder/blob/d4658af3f5f291311c6aee4210aa6d39bda82bbe/mDNSShared/uds_daemon.c#L3949-L3952),
[GetAddrInfo start, ř. 4389–4397](https://github.com/apple-oss-distributions/mDNSResponder/blob/d4658af3f5f291311c6aee4210aa6d39bda82bbe/mDNSShared/uds_daemon.c#L4389-L4397),
[ClientRequests.c, ř. 428–437](https://github.com/apple-oss-distributions/mDNSResponder/blob/d4658af3f5f291311c6aee4210aa6d39bda82bbe/mDNSShared/ClientRequests.c#L428-L437).
PID/UUID/UID se neztrácejí nutně na každém kroku IPC. Z jejich přítomnosti ani z nenalezení
`sandbox` v těchto souborech nevyvozujeme úplnou autorizaci, její absenci ani únik. OSS omezení výše.

## Lokální Apple manuály a SDK

Vše čteno z pevných veřejných systémových cest, bez `pfctl` dotazu na živou konfiguraci, bez čtení
živých socketů, DNS cache, logů nebo službových dat. Řádky jsou v surovém man/hlavičkovém souboru,
nikoli čísla stránek renderovaného `man`. Hash každé položky je v JSON.

| ID | Přesná cesta / sekce | Co je doloženo a limit |
|---|---|---|
| L1 | `/usr/share/man/man8/pfctl.8`, ř. 127–151, 211–242, 378–380 | Anchor scope; disable/enable reference; oddělené flush a stateful accounting; manuál instalovaný na oznámeném 27.2 buildu. |
| L2 | `/usr/share/man/man5/pf.conf.5`, ř. 1239–1243, 1296–1304, 1591–1609, 2433–2448 | Default pass, states před rules, TCP/UDP user včetně listeneru/creation credentials, anchor attachment. Neprokazuje skutečnou atribuci konkrétního listeneru. |
| L3 | `/usr/share/man/man1/sandbox-exec.1`, DESCRIPTION, datum v man 2017-03-09 | Nástroj deprecated, profil před command; nikoli úplná grammar nebo bezpečnostní garance. |
| L4 | `/Library/Developer/CommandLineTools/SDKs/MacOSX27.2.sdk/usr/include/sandbox.h`, ř. 6–9, 24–55 | Unsupported/deprecated od macOS10.8, profil aktuálního procesu, SANDBOX_NAMED, již sandboxovaný proces; žádný runtime test. |
| L5 | `/Library/Developer/CommandLineTools/SDKs/MacOSX27.2.sdk/usr/include/EndpointSecurity/ESClient.h`, ř. 798–830 | Descendants API od27.0 stále vyžaduje entitlement, ne root/TCC. |
| L6 | `/Library/Developer/CommandLineTools/SDKs/MacOSX27.2.sdk/usr/include/EndpointSecurity/ESTypes.h`, `es_event_type_t`, ř. 110–329 | UIPC auth, nová XPC/bootstrap auth od27.0; vyhrazené hodnoty27.2 nejsou dokumentované IP packet API. |
| L7 | `/usr/share/man/man8/route.8`, ř. 134–145, 217–225, 274–285, 343–349 | Destination/interface scoped route, reject/blackhole a root změny; ne per-UID síťový namespace. |
| L8 | `/usr/share/man/man8/ifconfig.8`, DESCRIPTION a parametry `up`/`down` | Konfiguruje síťová rozhraní; ne prokázanou izolaci provozu UID. |
| L9 | `/usr/share/man/man8/socketfilterfw.8`, SYNOPSIS/DESCRIPTION | Globální a app/path ovládání firewallu; bez dotazu na aktuální aplikace/policy. |
| L10 | `/usr/share/man/man8/mDNSResponder.8`, DESCRIPTION | Systémový unicast/multicast resolver, operace za klienty, cache; historický text není kompletní současná autorizační specifikace. |

## Kontrola závěru

Ověřené jsou existence textu, revize, odkazy, symboly/sekce a jejich uvedené meze. Neověřené jsou
runtime enforcement, signing konkrétního launcheru, všechny cílové aplikace, síťové kanály,
revokace a host continuity. Z žádného „nenalezeno v prohlédnutém souboru“ zde nevzniká univerzální
negativní platformové tvrzení. Archivovaný App Sandbox Design Guide nyní přesměrovává na novou
dokumentaci; nepoužíváme jej jako nedostupný údajný zdroj. Neplatná tipovaná cesta k DNS souboru
byla nahrazena skutečnou cestou `mDNSShared/ClientRequests.c` v připnuté revizi.

Self-review 2026-11-03: 13 relativních odkazů vyřešeno, 11 lokálních a 7 OSS SHA-256 ověřeno
proti čteným souborům; `git diff --check` bez nálezu. Ověřeno 23 unikátních externích URL:
19 vrací cílový dokument HTTP200; čtyři DTS odkazy při přímém HTTP fetch přesměrovaly na
Apple human-verification. Jejich obsah byl přečten browser/search nástrojem na konkrétních
thread URL, nikoli odvozen z HTTP200 challenge. Odkazy na řádky OSS byly zkontrolovány proti
stažené připnuté revizi. Tato validace je kontrola dokumentace, nikoli síťový test.
