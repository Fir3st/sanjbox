# Zbývající příprava a budoucí L2

Toto je plán, nikoli spustitelný runner. Současné CLI žádnou níže uvedenou operaci proti hostu,
cizí relaci, globální službě nebo celému UID neumí. Dodání plného WP1.A4 vyžaduje další kód a review;
samotný L2 je WP1.A5 a nemůže proběhnout před prošlým S1/WP1.A2. Nezávisí to na obsahu otevřených PR.

## Před každým případem

1. **[uživatel]** Vyhradit čistý laboratorní Mac a slot L2, zálohu, tři testovací oblasti a samostatnou
   host konzoli. Potvrdit potřebné otevřené části F0.8. Žádné skutečné projekty, účty, tajemství nebo
   živé databáze v testovacím rozsahu. Nepoužívat osobní host session jako náhradu testovací oblasti.
2. **[implementátor]** Do nového jedinečného předregistrovaného běhu podle GUIDE/LAB zapsat přesnou
   verzi kódu/macOS/build, stroj, role, case ID, povolené/zakázané operace, canary fixtures, trvání,
   timeout, oracle a úplné očekávání každé sondy. Exact real/effective UID/GID, skupiny, pozitivní
   auditSessionID/auditUID, bootstrap manager a window context; pouhý seznam zakázaných ASID nestačí.
3. **[implementátor + reviewer]** Dodat chybějící typed lab harness se schopností pracovat pouze s
   předregistrovanými vlastními fixtures. Budoucí capability musí svázat fixture origin, inode/PID
   ownership, UID/session, kód, run ID a konkrétní operaci. Nesmí z toho vzniknout libovolný path/PID/
   service/command runner. Bez této implementace a review se případ nespouští.
4. **[uživatel]** Provést případné privilegované/session/TCC kroky až po konkrétním review jejich
   připraveného dry-runu, záznamu původního stavu a cleanupu. Současný balík neobsahuje tyto příkazy.
5. **[implementátor]** Nejprve identitní a podpisová brána, pak pozitivní kontrola přes stejný relevantní
   mechanismus. Zakázaný pokus následuje až po úspěšné kontrole; následná pozitivní kontrola ověří,
   že příjemce/sonda mezitím nezanikly. Timeout, chybějící odpověď i nerozhodnutelný scope jsou
   neplatné/nejasné měření, ne důkaz odmítnutí. Známé chráněné bajty nebo schopnost znamenají fail.

## Sedm konkrétních navazujících karet

| Sonda / případy | Fixtures a pozitivní kontrola | Zakázaná operace / nezávislý oracle | Co ještě implementovat |
|---|---|---|---|
| `xpc-probe`, ID-07, ID-11 | Vlastní podepsaný host mock služby, testovací operation ID a kanárek; autorizovaný klient dostane přesnou odpověď a server doloží request. | Tentýž záznam očekává odmítnutí klienta jiné oblasti; server log rozlišuje lookup, connection a skutečnou operaci. Samotný lookup není únik. | Inventura relevantních globálních služeb podle jednotlivých API kontraktů; oddělit dosažitelnost od schopnosti číst/zapsat/spustit. Každý neprozkoumaný service/operation zůstává nejasný. Žádné sondování náhodných Mach jmen. |
| `tcc-probe`, ID-08…10 | Podepsané vlastní fixture aplikace/prázdné profily v každé session. Vlastní příjemce potvrdí povolený AX/AppleEvent/notification; hardware test v kontrolovaném prostoru jen s předem zadaným syntetickým signálem. | Stejné API nesmí dosáhnout syntetického host kanárku/operace mimo scope; nezávislý příjemce zaznamená i nečekanou událost. | Jednotlivé adaptéry pro AX, Screen Recording, Input Monitoring, mic, camera, Bluetooth, AppleEvents a notifikace, explicitní shared-hardware politika. Žádné API granty ani prompty v automatickém běhu; udělení uživatelem je oddělený důkaz. |
| `capture-probe`, ID-02…04 | Vlastní window/clipboard fixture v čisté host session a každé oblasti, rozdílné náhodné kanárky, vlastní event receiver/counter. Povolený lokální capture musí kanárek skutečně najít a příjemce potvrdit událost. | SCK/CGWindowList nesmějí vydat host/other-area kanárek či chráněná metadata; event/AX nesmí změnit vlastní host receiver. Negativní obraz bez pozitivního capture není důkaz. | Scope-aware enumerace pouze laboratorních fixtures, redakce ostatních položek, bounded capture a pixel/content oracle; procesově svázaný receiver pro event/AX, vlastní clipboard. Žádná osobní schránka ani obecný host window dump. |
| `host-read-probe`, FS-01…03,05…07,09; ID-01 | Vlastní syntetické kanárky v předregistrovaných chráněných kořenech a vlastních testovacích nástrojových/startup fixtures. Host autor čte/zapisuje, autorizovaná oblast čte své vstupy. Oddělený mock úložiště identity. | Oblast nesmí získat kanárek, změnit kontrolovaný soubor ani vytvořit využitelný hardlink. Pro metadata každé služby musí být definováno, které konkrétní syntetické pole nesmí vydat. Oracle sleduje obsah a stav fixture, ne jen exit utility. | Capability-based bezpečné I/O napříč skutečnou hranicí, independent host verification, ps/mdfind/log/netstat/system_profiler/ioreg/dscl adaptéry pouze na povolených datech. Mock Klíčenky ještě chybí; skutečné oddělení login keychainu pouze oddělený uživatelský integrační důkaz bez čtení položek. |
| `ingress-probe`, NET-10…12 (S3b návaznost) | Vlastní server oblasti a independent protistrany host/LAN/jiné oblasti; jednoznačné canary/run IDs, pozitivní povolené spojení před/po. | Zakázaný peer nesmí navázat ani předat bajty; server log a nezávislá protistrana rozliší spuštěný listener od chybného testu. Port squatting nesmí zachytit testovací host komunikaci. | Kontrolovaný wildcard listener, IPv4/IPv6, rozlišení peers/flows, předregistrované intervaly a porty. Běžný localhost jiných aplikací se nikdy netestuje. Navazuje na samostatné S3b, bez přebírání síťového enforcementu. |
| `signing-probe`, ID-05 + S8 | Vlastní finální agent/sondy/helper fixtures se zaznamenanou signaturou a verzí. Pozitivní kontrolní fixture navržená pro konkrétní signing/attach oracle. | Nepřítomnost obou spellings get-task-allow, hardened runtime a nezískání grantů z neautorizovaného procesu; persistence se musí prokázat přes rebuild na stejné kontrolované TCC fixture. | S8 integrace, stabilita identity, podpis po finálním rebuild, negativní modifikovaná fixture a user-owned TCC postup. Nevyužívat osobní podpisové identity ani Keychain; toto A4 nepředstírá úplný signing framework. |
| `lifecycle-probe`, LC-01…10 (LC-11 až F2) | Vlastní joby, child trees a heartbeat canaries pouze vyhrazeného testovacího UID. Před vypnutím každý trigger prokazatelně vytvoří marker/proces. | Nezávislý host observer musí potvrdit nula procesů UID a neúspěšný restart během/po stopu, po controller crash i přes login cesty; při pause stabilní quiescence navzdory souběžnému forku/job triggeru. | Vyhrazený supervisor, přechodový protokol, race hooks, přísné PID ownership, user/gui domény, cron/at, login items/SMAppService, detached CLI, helper crash a revokace loginu. Polling PID + SIGSTOP nebo pouhý bootout nejsou bezpečná pauza/vypnutí. Privilegovaný daemon se z oblasti nesmí autorizovat. |

## Závěr běhu

**[implementátor]** Zkontrolovat úklid všech vlastních fixtures a původní stav změn. Konflikty se
nepřepisují. Pro každý případ vést skutečnou pozitivní kontrolu, raw výstup, credential log, přesnou
interpretaci (měřeno/mock/hypotéza) a známé mezery. Všechny výsledky různých autorů/strojů zůstávají,
včetně failu a neplatného měření; uzavřený záznam se nikdy nepřepíše.

**[reviewer]** Teprve úplný protokol L2 posoudit proti PLAN. V této přípravě nejsou FS/ID/LC, S0,
S8, R2 ani R3 ověřené. Nedostatečné globální služby, lifecycle nebo TCC pokrytí bránu neuzavírá.
