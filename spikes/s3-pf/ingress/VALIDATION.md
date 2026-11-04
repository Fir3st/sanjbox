# Ověření WP1.C3 přípravy

Vývoj z čistého main `547f3c1e630cdd95662b9a9f339a22f7a1c47026`, claim `51fe877`.
Žádný C1/C2 kód, systémový zásah, pf read/load, wildcard/LAN/external test ani uzavřený gate důkaz
není součást ověření. Coverage mění pouze vlastní WP1.C3 řádek a F1 agregát 2 done / 1 partial / 27 todo;
155 testů a všechny brány zůstávají beze změny.

## Automatické fixtures

Release Swift Testing bez XCTest, bez externích závislostí, build/cache pod `/private/tmp/sanjbox-c3-*`.
Testy neotevírají sockety. Ověřují skutečný JSON parser/reducer a vlastní dočasné výstupy:

- unknown/duplicate/escaped keys, depth/size/count meze, role/flow/run/actor vazby;
- planned/mock/measured odlišení, všechny neprovedené buňky matice;
- nulové payloady při přijatém spojení, zachování findingu při částečném capture;
- nesprávné/chybějící identity, host vydávaný za same-zone, obrácené role;
- chybějící před/po controls, expected handshake, capture/drop/gap/retry/time coverage;
- časově nemožný handshake/close, odmítnutí reuse flow mezi nesouvisejícími stages, zachování
  opožděného kontaktu test → drain na původní flow, bind acquired také v drain;
- rozlišení ephemeral collision a pevné host-port rezervace;
- pure signature policy fixtures (runtime/forbidden entitlement/raw undecoded metadata), bez tvorby
  skutečných binárek s forbidden entitlementem;
- create-new/no overwrite, dry-run a idempotentní cleanup, změněné bajty a přidané entries,
  immutable flag souboru i adresáře, GID drift, symlink/hardlink a ACL souboru i adresáře zachované před
  prvním unlink, explicitní obnovení jen testovací fixture. Symlink fixture zachovává přejmenovaný
  report ve stejném adresáři, takže nejdřív narazí na extra-entry guard; samostatně neizoluje O_NOFOLLOW.
  Tento dílčí limit unit fixture pokrývá níže uvedená nezávislá CLI zkouška se zálohou reportu mimo dataset.

Dne 2026-11-03 prošlo **21/21** automatických fixtures (Swift 6.4, release native SwiftPM;
privátní build log `/private/tmp/sanjbox-c3-test.log`). GID perturbace byla na tomto hostu dostupná,
nepřeskočená. Před/po finální sérii byla množina `sanjbox-c3-run-*` a `sanjbox-c3-link-*` v `/private/tmp`
prázdná. První neúspěšný běh odhalil nesprávné zacházení s Darwin ACL ENOENT; oprava rozlišuje prokázanou
absenci ACL od jiné chyby. Čtyři prázdné vlastní adresáře z tohoto běhu byly identifikované přesnými UUID
+ inode/device/UID/GID/mode/flags a samostatně odstraněné ne-rekurzivním rmdir; žádný glob cleanup.

První nezávislý release build byl neplatný kvůli změně testovacího souboru za běhu kompilace
(`input file modified during build`); log je zachován v `/private/tmp/sanjbox-c3-root-release.log`.
Po zmrazení všech 21 testů a Sources prošel nový izolovaný release build **21/21, 0 failures, 0 skips**
(2026-11-03 19:27:03 CET, `/private/tmp/sanjbox-c3-root-release-final.log`). Obsahoval také skutečné
GID/ACL/flags fixtures. Varování o budoucím odstranění native SwiftPM backendu je očekávané;
první přerušený build se nepočítá jako validace. Čtyři původní prázdné adresáře (inode 280754171–174)
koordinátor následně nezávisle ověřil jako nepřítomné.

## Nezávislé ověření skutečného CLI

Koordinátor/reviewer po finálním buildu znovu podepsal vlastní release CLI ad-hoc (`-s -`), s hardened
runtime, prázdnými entitlements a bez timestampu. Od tohoto resealu nebyl žádný rebuild. Exact identity
expectation porovnal s nezávislým pomocným sběračem ve stejném execution kontextu; do repozitáře se
nedávají soukromé identity ani raw výstupy. Žádný test nevytvořil binárku s forbidden entitlementem.

**24/24 samostatných CLI kontrol prošlo podle očekávaného výsledku**: původní série 21 kontrol + 3
navazující kontroly nového běhu s uchováním raw. Negativní případy záměrně vracejí nenulový exit.
Soukromý souhrn původní série je `/private/tmp/sanjbox-wave5-root-smoke-foz3zpy5/c3-summary.json`,
celkový souhrn `/private/tmp/sanjbox-wave5-root-smoke-foz3zpy5/c3-summary-all.json`; nejde o akceptační
protokol brány. Původních 21 kontrol zahrnovalo:

- výchozí dry-run, `plan`, vlastní `identity` shodnou s nezávislým helperem a dry-run smoke;
- odmítnutí malformed/duplicate/unknown expectation, nesprávného audit session ID a zděděného
  SIGCHLD SIG_IGN před childem/sockety; parent signal disposition zůstala beze změny;
- odmítnutí vlastní kopie s prázdnými entitlements, ale **bez runtime**, před soubory a sockety;
- skutečný IPv4 **i** IPv6 nonce echo před/po, actual `EADDRINUSE` při kolizi vlastního drženého
  ephemeral endpointu, close/rebind/recovery a uzavření všech vlastních socketových fd;
- izolovanou negativní O_NOFOLLOW zkoušku: originální report byl držen **mimo** dataset (žádný extra
  entry uvnitř), symlink i původní state zůstaly při odmítnutí zachované; následovalo explicitní
  obnovení vlastní fixture, dry-run cleanup, skutečný úklid a idempotentní `alreadyAbsent`;
- offline prázdný vstup → 28 planned buněk; opožděný kontakt s nulovým payloadem na stejné flow
  test → drain zachovaný jako `observedViolationNeedsReview` i s capture drops; odlišený `mockFinding`,
  missing identity → `invalidMeasurement` a odmítnutí duplicate/unknown offline JSON.

Původní 21kontrolová série zůstává zachovaná ve svém souhrnu; raw prvního smoke bylo uklizeno spolu
s testovací fixture. Proto následovaly tři nové kontroly: druhý fresh smoke s úplným reportem i state
uchovanými mimo uklízený dataset, actual cleanup tohoto nového datasetu a kontrola idempotence.
Nový raw report/state zůstávají v soukromém validačním adresáři; do commitu nepatří. Nebyl proveden
rebuild ani další resign. Obě rodiny prošly také v tomto druhém běhu.

Obě rodiny mají výsledek `transportControlObserved`, IPv6 nebylo přeskočené. Před a po CLI sérii
byla množina vlastních `sanjbox-c3-run-*` adresářů stejná a prázdná. Jde výhradně o vlastní loopback
syntetický smoke bez systémových root privilegií. Nezávislé spuštění reviewera z něj nedělá nezávislý
síťový oracle: samotný přístroj stále používá stejný proces/UID/session. Ephemeral collision není
pevná host-port rezervace. **C3 zůstává částečné a S3b/NET-10…12 zůstávají Neověřeno.**

## Zbývající mezery

C1 integrace/raw endpoint-capture adapter; nezávislý oracle se zdrojovou atribucí; skutečné host/LAN/
other-zone směry a same-zone relace; pevná host-port rezervace během uzavřené služby; wildcard a
IPv6 dual-stack/reuse varianty; vynucovací mechanismus bind policy; přijatá metodika/slot L4;
plný souběh a opakování, failure modes a review původu důkazů. Ad-hoc podpis není S8 důkaz.
Offline transcript je neautentizované tvrzení: ani kompletní deklarované flags nedají pass; kvůli
chybějícímu endpoint adapteru vždy zůstává integrační gap explicitní. Lokální transport control má
stejný proces/UID/session a nemá nezávislý oracle.
