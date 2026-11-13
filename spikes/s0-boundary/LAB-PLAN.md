# WP1.A4 — příprava 31 případů FS / ID / LC

Podmínka přípravy v [IMPLEMENTATION §0](../../docs/IMPLEMENTATION.md#podmínky-dokončení-ostatních-rozpracovaných-balíků)
je **sonda nebo ruční krok s oraclem pro každý z 31 případů**. Tento rozcestník a tři runbooky ji
rozepisují po jednotlivých případech; nejsou runner, nový obecný harness ani výsledek laboratoře.
Tím je přípravná podmínka A4 splněná podle GUIDE §11; zbývající implementace a skutečné důkazy
mají níže vlastní stop podmínky a patří do navazujících balíků/slotů.
Současné CLI nadále umí jen vlastní `synthetic-self-fixture` podle [README](README.md).
**Všech 31 případů zůstává Neověřeno.** Chybějící komponenta je u konkrétního kroku stop podmínka,
nikoli pokyn vykonat nepodporovanou operaci přes obecný path/PID/service/command runner.

F0.7 i F0.8 jsou [rozhodnuté od 2026-11-07](../../docs/DECISIONS.md#rozhodnuté-podotázky).
C-003 nemění zdejší R2 oracle. Další skutečný běh S0/S8 je **uživatelský L2 / WP1.A5 a A7 až po
prošlém S1 na dané konfiguraci**; samotný L1-D tuto závislost neuzavírá. FS-04 potřebuje S4/L3,
FS-08 konkrétní helper S4/S8 a LC-11 přidělování UID ve F2. Jejich postup je připraven zde,
ale přesun do L2 ani prohlášení těchto komponent za existující by byly nesprávné.

## Index přesného rozsahu

| Případ | Ruční postup / oracle | Hranice skutečného běhu |
|---|---|---|
| [FS-01](CASES-FS.md#fs-01) | Chráněný home | L2 + ochrana S4 |
| [FS-02](CASES-FS.md#fs-02) | Pracovní kořen | L2 + ochrana S4 |
| [FS-03](CASES-FS.md#fs-03) | Sdílené cesty: čtení i zápis | L2 + ochrana S4 |
| [FS-04](CASES-FS.md#fs-04) | APFS, exFAT/FAT, odemčená záloha | S4/L3; mount enforcement chybí |
| [FS-05](CASES-FS.md#fs-05) | Jiná oblast | L2 |
| [FS-06](CASES-FS.md#fs-06) | Host nástroje a startup kořeny | L2 + ochrana S4 |
| [FS-07](CASES-FS.md#fs-07) | Vytvoření i zneužití hardlinku | L2/S4 |
| [FS-08](CASES-FS.md#fs-08) | Helper a symlink / výměna cesty | S4/S8; resolver chybí |
| [FS-09](CASES-FS.md#fs-09) | Sedm povrchů metadat | L2; bezpečné selektory částečně chybí |
| [ID-01](CASES-ID.md#id-01) | Mock úložiště + uživatelské oddělení | L2; skutečná integrace zvlášť |
| [ID-02](CASES-ID.md#id-02) | Syntetická schránka | L2; jen čisté testovací relace |
| [ID-03](CASES-ID.md#id-03) | SCK a CGWindowList | L2; bounded capture adapter chybí |
| [ID-04](CASES-ID.md#id-04) | CGEvent a AX | L2; receiver/adapter chybí |
| [ID-05](CASES-ID.md#id-05) | Attach host / same-UID agent | L2/S8; attach control chybí |
| [ID-06](CASES-ID.md#id-06) | LaunchServices / Terminal | Ruční L2 s prázdnými profily |
| [ID-07](CASES-ID.md#id-07) | Konkrétní globální XPC/Mach operace | L2; inventura a adaptéry chybí |
| [ID-08](CASES-ID.md#id-08) | Scope AX / Screen Recording grantů | Uživatelský L2/S8 |
| [ID-09](CASES-ID.md#id-09) | Vstup a sdílený hardware | Uživatelský L2, politika samostatně |
| [ID-10](CASES-ID.md#id-10) | AppleEvents a notifikace | Uživatelský L2; přijímače chybí |
| [ID-11](CASES-ID.md#id-11) | Syntetický host agent/socket | L2; AF_UNIX receiver chybí |
| [LC-01](CASES-LC.md#lc-01) | GUI LaunchAgent | L2; vypnutí celého UID chybí |
| [LC-02](CASES-LC.md#lc-02) | cron a at | Uživatelský L2; revokace chybí |
| [LC-03](CASES-LC.md#lc-03) | LoginItem a SMAppService agent | L2/S8; restart cleanup chybí |
| [LC-04](CASES-LC.md#lc-04) | user doména bez GUI | L2; vypnutí celého UID chybí |
| [LC-05](CASES-LC.md#lc-05) | Odpojený CLI a nula procesů | L2; úplný observer chybí |
| [LC-06](CASES-LC.md#lc-06) | Start při vypínání a po něm | L2; přechodový controller chybí |
| [LC-07](CASES-LC.md#lc-07) | Fork/job race při pauze | L2/S4; quiescence chybí |
| [LC-08](CASES-LC.md#lc-08) | Pád controlleru | L2; recovery/fault hooks chybí |
| [LC-09](CASES-LC.md#lc-09) | SSH / Screen Sharing | Uživatelský L2; revokace loginu chybí |
| [LC-10](CASES-LC.md#lc-10) | Privilegovaný daemon | L2/S8; host-only autorizační cesta chybí |
| [LC-11](CASES-LC.md#lc-11) | Reuse UID až po úklidu | F2; allocator/recovery chybí |

## Společný předpis pro každou kartu

**Role:** U = uživatel, I = implementátor, O = nezávislý pozorovatel na čisté host konzoli,
R = reviewer. Host H je vyhrazený laboratorní účet, A/B/C jsou tři oblasti. Nejde o osobní relaci.
„Nezávislý“ oracle znamená vlastní záznam cíle/pozorovatele, nikoli jen exit útočícího klienta.
O nesmí výsledky odvodit pouze ze souboru, který může A přepsat. Karty dědí následující kroky;
jejich zvláštní kontext, ovládání, výstupy a úklid je zpřesňují.

1. **U + I před slotem:** rezervace stroje, prošlý S1, záloha, čisté profily, přesný commit/macOS/build,
   původní stav a inventář všech nových syntetických objektů. Jen vlastní soubory do 1024 B s novými
   rozdílnými kanárky H/A/B/C; žádné skutečné účty, tajemství, obsah Keychain, osobní schránka,
   globální window dump nebo scan procesních argumentů. Pro nové kanárky zafixovat např.
   ASCII `SANJBOX-A4:<run-UUID>:<case>:<role>:<sequence>` a přesný hash před pokusem; žádné pole
   se nepřebírá od útočícího klienta jako důkaz původu. Změny účtů, práv systému, TCC, registrací,
   mountů a nastavení dělá pouze U po konkrétním dry-runu a připraveném úklidu podle GUIDE §6.
2. **I + R před operací:** do `inputs.md` zapsat u **každého** klienta, cíle a O přesné real/effective
   UID/GID, úplnou množinu kernel groups, požadovaná/zakázaná členství (A/B/C bez staff/admin),
   pozitivní auditSessionID a auditUID, launchd manager name/UID a všechna pole window session
   (`userID`, `auditSessionID`, `onConsole`, `loginDone`) nebo výslovné `null`. Číselné hodnoty se
   získají z přidělených účtů a nezávislého S1 záznamu, nejsou univerzální konstanty runbooku.
   H: vlastní Aqua, console=true; A/B/C: vlastní různé Aqua/ASID, console=false. Background job:
   předem zjištěný vlastní manager/ASID/window profil, ne domněnka odvozená z labelu `user/<uid>`.
   Systémový helper má samostatný očekávaný profil; root expectation současné A4 CLI nepřijme.
3. **I ověří skutečný kontext před i po každém bloku.** Existující `sanjbox-whoami --expect
   <vlastní-role-expect.json>` dostane předregistrovaný common `ProbeExpectation` s konkrétními
   UID/GID a `requiredGroups`/`forbiddenGroups`; pro A/B/C zahrnout staff/admin mezi zakázané.
   Jen tak collector vyplní autoritativní `groupMembership` pro všechny požadované skupiny;
   `false` znamená nečlenství, `null`/chybějící položka je neplatné měření. Bez argumentů má
   nevyhodnocené `valid` (klíč se v JSON vynechá) a prázdné `groupMembership`, takže samotný
   výpis není tento preflight; případný common log má outcome `unclear`.
   Common `--expect` nekontroluje přesnou množinu kernel groups, pozitivní ASID ani auditUID;
   O proto navíc ručně porovná **všechna** pole s předregistrací a uchová původní výstup.
   Nestačí `valid:true`, jiné ASID než host nebo úspěšné `id`. Důvěryhodná systémová
   utilita se spouští přímo ve stejném ověřeném testovacím shellu bez změny UID/bootstrap; její
   spuštění a kontext zaznamená O. Vlastní budoucí adapter/cíl musí mít self gate v témže procesu
   před API. Chybějící údaje, změna relace nebo možnost nedoloženého přepnutí = neplatné měření.
4. **Podpis:** připnout hash finální vlastní binárky a bundle ID/cdhash, strict validitu, hardened
   runtime, nepřítomnost obou `get-task-allow` klíčů i s false. Po každém rebuildu znovu ověřit.
   Ad-hoc self-fixture není stabilní TCC identita. U OS utilit zapsat cestu, OS build a ověřený
   systémový podpis; nepřepodepisovat je. Přesný postup vlastní sondy je v [README](README.md#identita-a-explicitní-aktivace).
   A4 `--expect-json` má vždy scope `synthetic-self-fixture`; nesmí se použít jako autorizace L2.
5. **Kontrola → pokus → kontrola:** autorizovaný vlastník skutečně provede stejnou relevantní
   operaci na cílové fixture před/po; A navíc ověří stejný mechanismus na své lokální fixture.
   Poté A provede pouze zakázanou operaci karty. Při úniku se blok zastaví, nález zůstává fail;
   pokud je bezpečné dokončit kontrolu/úklid, zaznamenají se odděleně. Neschopnost negativní pokus
   vykonat, timeout, mrtvý příjemce, ENOENT nebo chybějící pozitivní kontrola nejsou denial.
6. **U + R předregistrují opakování a čas:** pro deterministické přechody návrh LAB §9 nejméně 3×;
   races 10 minut nepřetržité sondy a ≥100 vyvolaných přechodů. Zapsat počet, deadline každé operace,
   recovery/observation interval a mez nejdelšího triggeru. Neznámá mez u cron/login/retry = mezera,
   žádný konečný polling sám nedokazuje absenci restartu. Měření doplnit review mechanismu.

## Výsledek a úklid jednotlivého případu

I uloží pod novým ID běhu dle [LAB §3](../../docs/LAB.md#3-předregistrace-a-platnost-důkazu)
`inputs.md`, `credentials.log`, před/po kontroly, `raw/<case>/attempt`, nezávislý `oracle`, chyby a
`cleanup`; karty níže uvádějí potřebná pole navíc. Formát může být ruční tabulka + původní stdout/stderr,
nejde o nový machine-readable evidence kontrakt. Výstup obsahuje skutečné API/operaci, čas, role a
fixture ID, výsledek/errno, identitu a podpis, ne pouze „permission denied“ opsané operátorem.

R rozliší **Neprošlo** (jakýkoli chráněný bajt, nepovolená změna/schopnost nebo porušení lifecycle),
**Nejasné** (měřilo se, ale chybí platný oracle/část mechanismu) a **Neověřeno** (krok nebyl proveden,
například kvůli zde popsanému blokátoru). Doložené selhání se nikdy nevymaže sekundární chybou
pozitivní kontroly či cleanupu. Samotný denial, dry-run nebo lokální mock není Prošlo případu.

U/O ověří ukončení vlastních procesů, zrušení vlastních registrací a jen původní konkrétní změny.
Odstraní pouze jednotlivé inventarizované nezměněné fixtures po kontrole identity/obsahu; žádné
mazání podle prefixu, cizí PID kill, reset TCC nebo přepsání pozdější změny. Konflikt se zachová
s vlastníkem dalšího kroku a slot se neuzavře jako uklizený. Sealed historické záznamy se nemění.

## Co lze ověřit bez laboratoře

Z kořene repo jsou bezpečné existující příkazy:

```sh
python3 spikes/s0-boundary/validate-xpc.py
python3 -B -m unittest discover -s spikes/s0-boundary/Tests/RunnerTests -v
python3 -B -m unittest discover -s tools/tests -v
```

První je dry-run (nemá přepínač `--dry-run`); ostatní jsou lokální syntetické testy.
Pro sestavené vlastní CLI je `--dry-run` skutečně podporovaný. [XPC runner](XPC-FIXTURE.md)
a [README](README.md) popisují samostatné self-fixture `--apply` a jejich limity; jejich opakování
není potřeba pro změnu těchto dokumentů. Neprovádět zde `tcc-probe`/`capture-probe --apply` s cílem
získat chybějící měření: vracejí `notImplemented`/5. NET-10…12 zůstávají samostatným S3b postupem,
nikoli dalšími případy této 31řádkové podmínky. Další offline framework není podmínka ukončení A4.
