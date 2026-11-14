# WP1.A6 — vymezené pokračování 2026-11-14

Základ `main` `75f3b5da13dfd7fca3acd376e06f1cd4d0fe2786`, větev
`codex/wp1-a6-h1-fuzzer`. Původní vlastníci a autoři **janfiedler / Codex + Astra**
zůstávají zachovaní; navazující implementace Astra má výslovné uživatelské předání.

Konkrétní mezera: současný fuzzer testuje vlastní mock DTO, ačkoli H1 již poskytuje
helper/reply/broker v1. Tento follow-up skončí napojením na skutečné veřejné wire API,
deterministickým bounded corpus s pozitivními i negativními controls, cílenými Debug/Release
testy a zdokumentovanou hranicí syntetické autorizace/registration recovery.

Dále připraví host-only autorizační seam a dry-run/user workflow pro vlastnictví registrace
přes restart, pokud lze bezpečně využít stávající kontrakty. SG-06 runner se doplní jen při
prokazatelně srovnatelné pozitivní i negativní kontrole bez `get-task-allow`; jinak se přesný
blokátor zaznamená. Žádná skutečná registrace, restart, účet, signing identity, TCC, systémová
změna ani externí síťový experiment nejsou součástí implementace. Git publikace je autorizovaná.

**A6 zůstává částečné. S8/SG-01…11 a Personal Team zůstávají Neověřeno.**

Integrační review 2026-11-14 zahrnulo normální merge aktuálního `main` `8faf648` (H4 #79 a
částečné A3 #78) do původní PR historie; výsledek a nezávislé testy jsou v
[VALIDATION](VALIDATION.md#nezávislé-integrační-review-po-h4-a-a3--2026-11-14). H1 wire část je
dodaná, ostatní níže uvedené výstupy A6 tím nezmizely. Dosavadní vlastník janfiedler / Codex + Astra
pokračuje podle [IMPLEMENTATION §0](../../docs/IMPLEMENTATION.md#0-co-dál): native host-only/admin
approval a durable ownership/cleanup, SG-06 kalibrace a runner; skutečné podpisy/TCC a A7/L2
provádí uživatel po S1 a přezkoumaném úklidu. Další obecný mock není podmínka dokončení.

## Dodaný výstup a konec tohoto follow-up

- `H1Fuzzer` je přímý klient lokálního `SanjboxContracts`, ne kopie schématu. Dvanáct request
  druhů, úspěšná i neúspěšná reply každého druhu a tři broker druhy přes **obě** veřejná
  admission API dávají 42 nezávislých pozitivních vstupů, před/po celkem 84 controls.
- Raw JSON controls jsou literály nezávislé na encoderu H1. Negativy mají pevně stanovený oracle:
  verze, neznámá/chybějící/duplicitní pole, base64, UTF-8, truncation/trailing, oba byte limity,
  záměna receiveru, UID rozsahy/zápis, traversal, argv NUL, policy zone, reply korelace a outcomes,
  broker role/stream/zone/attachment/replay/dimensions, global surface ID a input rozsahy.
  Každý negativ musí skončit známým `ContractError`; libovolná jiná výjimka je chyba harnessu.
- Pevná matice pokrývá všechny druhy i při `--iterations 1`; parametr přidá 1…10 000 seeded
  mutací. Corpus hash má délkově rámované bytes, receiver, expectation i trusted context.
  Streaming digest neuchovává celý corpus; jeden wire má nejvýše helper max + 1 byte.
  Report drží max. 16 diagnostik. Reprodukce používá stejnou revizi, corpusVersion, seed a počet.
  Nejde o coverage-guided fuzzing, transport fuzzing, Mach-right exhaustion nebo race test.
- Test oracle je ověřen také injekcí accept-all, reject-all a nesouvisející výjimky. Samostatný
  size test přijme přesně maximální envelope/body a odmítne +1 byte u všech čtyř decode cest.
- Builder nyní zahrnuje H1 Package/Sources do source manifestu i kontroly driftu během buildu.
  H1/common se nemění; žádný kontrakt ani schema se nerozšiřují.

```text
s8-probe h1-fuzz --expect OWN_EXPECTATION --iterations 10000 --seed 21304
s8-probe service-workflow --expect OWN_EXPECTATION
```

Stejný podpisový a úplný identity preflight jako [README](README.md); `--apply`, PID, služba,
URL, cizí soubor či příkaz nejsou argumenty těchto nových příkazů. Původní `mock` a jeho
historie se nemažou. CLI má společný 45s nouzový watchdog, timeout znamená neúplný výsledek.

## Host-only daemon seam — pouze syntetický

`SyntheticDaemonBoundary` váže důvěryhodný mock baseline na roli host controller, UID/audit UID,
audit session, PID **i process version**, platný mock signature result a code hash. Žádný z těchto
údajů se nedeserializuje z wire. H1 helper request se dekóduje až po host kontrole; validní message
sama není oprávnění. Daemon register/unregister v modelu navíc potřebuje jednorázovou approval
vázanou na host proces a konkrétní akci; replay, jiná akce a revokace odmítnou před mock efektem.

Approval vytváří pouze syntetická authority metoda. Není OS admin schválením ani možností
předložit boolean/UUID nativnímu daemonu. Veškeré efekty jsou čítač v paměti. S8LaunchDaemon,
SMAppService adaptér a UI se nemění; daemon nemá IPC ani mutace. Budoucí native adapter musí
získat identity z connection audit tokenu, svázat je s dynamickým podpisem a session, oddělit
trusted host approval od oblasti a prokázat zánik/revokaci oprávnění. To tento seam nedokazuje.

## Registrace přes restart — dry-run a uživatelské předání

`service-workflow` vypíše šest čistě syntetických průchodů: Personal Team a podmíněný self-signed,
každý pro LoginItem/Agent/Daemon. `SyntheticRegistrationWorkflow` rozlišuje původní absent stav,
register intent/result, povinný recovery review po restartu, unregister intent/result a nezávislý
stop/relaunch oracle. Chyba či nejasný výsledek přejde do konfliktu. Intent bez resultu se nikdy
neopakovaně nespouští ani neadoptuje; changed UID/run/service/inventory/status/boot/session odmítne.
Model nečte ani nezapisuje persistent receipts, nenahradí native ownership oracle a neodblokuje
žádný cleanup. `nativeRegistrationAllowed` a `nativeArtifactCleanupAllowed` jsou vždy `false`.

**Před skutečným L2 musí uživatel s implementátorem dokončit a přezkoumat následující workflow;
dnešní UI podle něj neumí provést cleanup přes restart. Dokud chybí native kroky, registraci pro
login/reboot/daemon scénář nezahajovat.**

| Fáze | Předepsaný uživatelský záznam / kontrola | Stop / úklid |
|---|---|---|
| Před registrací | S1 pass, rezervace L2, konkrétní signing profil a čtyři signed inventory hashe, run ID, host/owning UID, úplná identity expectation, přesná app cesta a originální service status | Existující/unknown registrace se nepřebírá; nevydávat nový baseline z nalezeného stavu |
| Register | Před API trvale uložit intent mimo dočasné `/private/tmp`, poté paired API result/status a startup marker; daemon navíc oddělený host-only/admin approval | Selhání či chybějící result = konflikt, ne opakování register; app zůstává na místě |
| Před restartem | Zajistit obnovitelné vlastní receipts/inventuru a review dostupné cleanup cesty pro stejnou app/service/UID; evidence musí přežít plánovaný restart | Pokud nástroj podporuje jen current-session ownership, nejprve cleanup v té session; restart experiment je blokovaný |
| Po restartu UI/login/reboot | Nová nezávisle schválená expectation, boot/session, podpis a inventura; porovnání run/service/owning UID a všech intent/result párů | Stejný status není důkaz stejné registrace; vyžaduje se uživatelské review sériového slotu bez dalších změn, žádná automatická adopce |
| Unregister | Nativní host-only cesta ze stejné app a owning UID, nový durable intent před API, paired result a status absent | Drift či nejistota blokuje cleanup; žádné globální reset/unregister/launchctl bootstrap |
| Ověření cleanup | Nezávisle potvrdit nulu vlastních helperů a žádný relaunch při předepsaném login/reboot; zaznamenat skutečnou časovou osu | Samotný API úspěch nestačí; aplikaci odstraňovat až po oracle, manifest/inode/ACL/hash kontrole a přezkoumané nativní cleanup cestě |

SMAppService status neobsahuje zde použitelnou registration generation. Same-status cizí
unregister/re-register tak zůstává nepozorovatelný; mock review není jeho detekce. Současný signing
handoff nadále odmítá post-handoff artifact cleanup, včetně signed inventory. Žádný receipt z této
simulace ani jeho `cleaned` stav nesmí posloužit jako výjimka. Durable ownership a native cleanup
přes restart jsou **konkrétní zbývající výstup A6**, nikoli „hotovo čekající jen na lab“.

## SG-06: proč tento PR nepřidává attach runner

Současná příprava nemá kalibrovanou pozitivní attach kontrolu ani skutečný SessionAgent.
Povolena je pouze vlastní syntetická ad-hoc fixture bez `get-task-allow`; nelze z jejího odmítnutí
rozlišit ochranu cíle od chybějícího debugger oprávnění/autorizace. Pozitivní self task port nebo
spolupracující child `PT_TRACE_ME` by ověřoval jiný mechanismus než attach z nezávislého same-UID
procesu a není náhradou. Žádná taková operace ani OS autorizační dialog zde neběžely.

Pro navazující runner je nutné předregistrovat **stejný attach mechanismus, caller signing a
UID/session** proti vlastní pozitivní i hardened negativní target fixture, doložit že pozitivní
kontrola projde bez zakázaného entitlementu či neautorizovaných systémových změn, a teprve pak
implementovat child PID/start-identity binding, deadline a ověřený terminate/reap. Bez pozitivní
kontroly je negativní attach Nejasné. [Dosavadní primární opory](RESEARCH.md) se nemění; tento PR
netvrdí, že kompatibilní pozitivní kontrola neexistuje. Její proveditelnost nebyla prokázána.

## Přesné zbývající blokátory

H1 wire fuzzer je tímto dodán. A6 jako celek zůstává rozpracované: chybí native host-only daemon
adapter/approval, durable registrační ownership a cleanup přes restart, srovnatelný SG-06 runner,
a uživatelské Personal Team/podmíněné self-signed experimenty. XPC transport/Mach rights,
audit-token/code/session autentizace, symlink/TOCTOU, TCC a živý L2 čekají na nativní implementaci,
uživatele a laboratorní závislosti. S8 ani žádný SG případ nemění stav.

## Navazující native recovery — 2026-11-14

Výše popsaný výstup a evidence #77 zůstávají historicky beze změny. [Další vymezená implementace](NATIVE-RECOVERY.md)
zapojuje skutečný durable filesystem journal a signed-app inventuru do nativního service hostu.
Zbývající ownership oracle a post-restart unregister/cleanup neodvozuje z receiptů; daemon ani
SG-06 neodblokovává. Podrobné nativní failure semantics a další podmínky jsou v novém dokumentu.
