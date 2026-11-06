# WP1.A2 — offline inspektor zachovaného procesního journalu

`inspect-process-journal` čte explicitně připravenou kopii `samples.jsonl` a vypíše omezený
inspekční JSON na stdout. **Každý výsledek je `incomplete-unverified`, `acquisitionComplete:false`,
`identityAuthenticated:false`, `provenanceArtifactsVerified:false`, `acceptanceVerdict:not-evaluated`.**
Ani všechny řádky bez strukturální chyby nejsou úplná acquisition, autentizace původu nebo S1/P4 pass.
Inspektor neobnovuje `recording.json`/`report.json`, neobnovuje sběr a neopravuje starý journal.

## Explicitní vstup a CLI

```text
sanjbox-s1-instrument inspect-process-journal --fixture NAME [--series-json JSON] [--apply]
```

Operátor připraví **sanitizovanou kopii**, nikoli původní historický soubor, pod přesným jménem
`/private/tmp/sanjbox-a2-journal-<aktuální-euid>-<NAME>.jsonl`. NAME má 8–96 ASCII písmen, číslic nebo
pomlček. Soubor musí být běžný, vlastněný aktuálním EUID, mode `0600`, jeden hardlink a 0–32 MiB.
Reader používá držené directory/file FD, `O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC`; ověřuje typ, owner,
mode, link count, velikost a stabilitu velikosti/mtime/ctime před a po čtení. Symlink, hardlink,
FIFO a adresář odmítne. Neprochází datasety ani adresáře a neotevírá žádné sidecary, PID, executable,
příkaz, cizí paměť nebo registr procesů. Původní důkazy zůstávají neměnné.

Bez `--apply` validuje pouze jméno, volby a případný inline plán; soubor neotevírá. S `--apply`
jen čte a píše stdout, nevytváří žádný dataset/soubor. Pevný self-only watchdog 30 s kryje čtení,
parsování, synchronní stdout i chybový stderr až do skutečného process exit; při přerušení nebo
SIGALRM může chybět výstup nebo být stdout neúplný. Takový
výstup není dokončený inspekční JSON. Žádná další instance se automaticky nespouští.

Volitelný `--series-json` je **explicitně dodaný `ProcessSeriesPlan`**, stejný formát jako vstup
`process-series`, nejvýše 16 KiB. Není to soubor `intent.json` ani `registry.json` a nepředstírá
jejich načtení. Plán vymezuje run ID, délku okna, jedinečné sloty/PID a úplné číselné identity
same-UID testovacích instancí. Jeho přesné vstupní byty váže `suppliedPlanSHA256`. Ověřují se
shody runu/délky/slotů a tvrzených identit, nikoli pravdivost plánu, role nebo provenance hashe.
Pevný plán odporuje `notRegistered`; pro historický dynamický owned-fixture journal s příchodem
slotu uvnitř okna použij samostatnou inspekci bez tohoto nepříslušného plánu. Inspektor nikdy
neodvodí plán ze sousedního souboru či z aktuálního stavu hosta.

Historické UID/session nemusí odpovídat současnému operátorovi. Inspekce je offline: nevolá
identity capture, sampling ani kontrolu podpisu současného procesu. Ověření vlastnictví staged
souboru není autentizace identity, která jej kdysi vytvořila.

| Exit | Význam |
|---|---|
| 0 | Pouze dry-run nebo help. |
| 3 | Inspekce dokončena bez strukturální chyby; stále neúplné/neověřené, včetně prázdného vstupu nebo nedokončeného konce. |
| 2 | Chybná volba/plán/I/O/limit nebo strukturální chyba. Po úspěšném bounded read má chybný journal inspekční JSON se zachovaným prefixem; při odmítnutém vstupu je jen stderr, bez inspekce/hashe. |

## Framing, schéma a konzistence

Aktuální writer v [Storage.swift](Sources/S1Instrumentation/Storage.swift) produkuje compact JSONL:
`schemaVersion:1`, `runID`, nulový počáteční `sequence`, `window:{start,end}`, `point`. Každý řádek
má LF a nejvýše 4096 bytů **včetně LF**. Inspektor vyžaduje přesně toto Codable schéma včetně
povinných polí a odmítá neznámá pole, null, duplicitní/escaped-ekvivalentní klíče, neplatné UTF-8/JSON,
trailing JSON a hloubku nad 24. UTF-8 a Unicode surrogate escape prefixy kontroluje inkrementálně
i bez closing quote: možné neúplné vícebytové znaky jsou přerušení, nemožné byty/escape jsou chyba. Celočíselná pole musí mít nezáporný integer token, nikoli bool,
zlomek či exponent; rozsahy určuje Swift typ a doménové kontroly. Časy jsou konečné, 0–1e9,
bez overflow/underflow čísla. Window má délku 1–600 s, metriky nejvýše 2^60. Platný řádek může
obsahovat whitespace nebo CR před LF; LF uvnitř pretty-printed objektu řádek přeruší a je chyba.

Nejvýše 32×602 řádků, sloty 1–32, nejvýše 602 bodů slotu. Sequence je přesně 0,1,2,…; run ID
ani window se nesmějí změnit. Per-slot reads jsou striktně uspořádané/nepřekrývající a celý
journal zachovává sériovou chronologii writeru. Read nezačíná před window. Dlouhý read >1 s,
mezera >2 s, chybějící počáteční endpoint >100 ms a konec po `window.end+1` jsou zachované
časové diagnostiky; nevyhazují skutečně zaznamenaný bod ani nepřidávají nuly. Tyto hranice jsou
stávající diagnostika instrumentace, **ne změna LAB/F0.8**.

State invariants sledují skutečný `RegisteredProcessReader`: `sampled` má obě stejné identity,
obě metriky a nemá errno; failure nemá žádnou metriku. `notRegistered` nemá identity/errno ani
read duration a nemůže následovat po registrovaném stavu. `unreadableBefore` má errno bez
identit; `identityChangedBefore` má pouze odlišné before a žádné errno; `readFailed` má stejné
before/after a errno; `unreadableAfter` má before a errno; `identityChangedAfter` má odlišné
before/after, stejné PID a smí mít errno z neúspěšného rusage. Pozorované mismatch identity
smějí ukázat root, jiné UID nebo rozdíl real/effective UID: to je failure claim, nikoli
platná registrovaná identita. PID je pro slot stabilní a nesdílí jej jiný slot; nové matched-before
claim nesmí přepsat dřívější instanci ani odporovat dřívějšímu mismatch. Bez plánu zůstává první
mismatch vůči neznámému targetu neověřitelný. Žádná z těchto shod neautentizuje proces.

## Výstup a přerušený prefix

`inputSHA256` a `inputBytes` vždy označují **všechny přesně přečtené bounded byty**, včetně
chyby, nepřečtených řádků parserem a trailing bytes. `rows` obsahuje pouze souvislý přijatý
prefix, včetně validně tvarovaných failure bodů. `contiguousPrefixBytes` končí za jeho posledním
LF. `line` je od 1, všechny byte rozsahy jsou od 0 s exkluzivním `end`; `sequence` zůstává od 0.
Footprint a resident jsou uchované samostatně bez agregace přes procesy nebo přičítání k systému.
Chybějící failure metrika je vynechaná; skutečná číselná nula zůstává nulou.

- Chybný dokončený LF řádek: `structuralError:true`, diagnostika jeho celé byte range; předchozí
  řádky a jejich diagnostika zůstávají. Zbytek je `unexaminedBytes`; žádný skip/resync.
- EOF v možném nedokončeném JSON: `tail.kind:unterminated-final-bytes`; není přijatý řádek.
  Samotný neplatný dokončený JSON či schéma na konci se nezamění za neškodné přerušení.
- Úplný strukturálně/konzistentně platný objekt bez LF: `tail.kind:complete-row-without-LF`;
  stále není producer-committed řádek a nevstupuje do prefixu.
- Neplatný final suffix: `tail.kind:invalid-final-bytes` a strukturální chyba. Po první chybě
  na dokončeném řádku se zbytek, včetně případného suffixu, již neinterpretuje.

Byte hash je vazba na předložený obsah, ne podpis. Z obsahu nelze prokázat pravdivost acquisition,
credentials, boot/clock domain, registraci, skutečný fsync, úplnost běhu ani původní proces.
Stabilní metadata při čtení nejsou autentizovaný snapshot proti same-UID protivníkovi. Neexistuje
end marker a i journal s koncovými vzorky zůstává neúplný/neověřený. Každý autor/stroj/run se
kontroluje samostatně; inspektor nedělá společný verdikt.

Knihovní API `ProcessJournalInspector.inspect(Data,suppliedPlanJSON:)` přijímá bounded byty,
vrací inspekci a nic nečte/nepíše. Caller musí řídit dobu běhu; `readStaged(name:)` je samostatný
pevně omezený reader. Reprodukce a skutečné výsledky jsou v [VALIDATION](VALIDATION.md).

Veřejný source `b4e9cc247a69619faf074a96057ade89fa2152a6` má přesně stejné runtime/test/fixture/common bytes jako měřený `db6622ef2f0abeacd62e71a622579c0550e30253`; [mapa ekvivalence](validation/journal-inspector-public-source-equivalence.json) dokládá oddělení publikační historie. Původní uzavřená publikace zůstává v lokální archivní větvi a přesné soukromé kopii, veřejná větev obsahuje označenou odvozeninu a nový běh oprav.
