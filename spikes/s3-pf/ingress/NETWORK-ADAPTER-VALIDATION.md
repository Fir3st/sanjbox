# WP1.C3 — offline network provenance consumer validation

**Consumer je implementovaný; C3 zůstává partial a S3b/NET-10…12 zůstávají Neověřeno.**
Ověření neotevřelo sockety, nesbíralo identitu a neměnilo producer ani jeho původní důkazy.

Měřený opravený source je `608b41cc308ffa6d6fb530f24bc3a899537e0411`. Veřejný source `972a518c23cf91a18dacc61d9c98844b55495d5c` má přesně stejné runtime/test/fixture/tool a common bytes; [mapa ekvivalence](publication/public-source-equivalence.json) dokládá pouze oddělení publikační historie.

## Původní běh source 926e106

[Sanitizovaná publikace původního záznamu](validation/20261106T115551Z-network-adapter-926e106-publication/verdict.md)
ověřil source commit `926e106f24f1366af103544b546ad10db58efdf0` na čistém základu
`dd058d3f4e758ed7fdef7dc64eba1c9a34a66967`. Producer bytes pocházejí z commitu
`ba339392df85f0798ba66b9f4842735558467646` a starého 352souborového manifestu; zde se
znovu ověřilo přesně 61 vybraných souborů, původní publikace zůstává beze změny.

| Kontrola | Výsledek | Přesný protokol |
|---|---|---|
| Native Release Swift Testing, `--jobs 2 --disable-sandbox`, vlastní scratch/cache | 60/60 funkcí, včetně 50 původních a 10 nových s parametrizovanými případy | [stdout](validation/20261106T115551Z-network-adapter-926e106-publication/logs/release-tests.stdout.log), [stderr](validation/20261106T115551Z-network-adapter-926e106-publication/logs/release-tests.stderr.log) |
| Přesná fixture projekce z autentických producerů | 9 případů, 61/61 file hashes | [log](validation/20261106T115551Z-network-adapter-926e106-publication/logs/exact-vectors.stdout.log) |
| Nový `link` consumer přes skutečné CLI/stdin | 30/30 kontrol, všechna input/stdout/stderr zachována | [summary s hashi](validation/20261106T115551Z-network-adapter-926e106-publication/network-cli/summary.json) |
| Původní offline CLI regresní suite | 25/25 kontrol | [log](validation/20261106T115551Z-network-adapter-926e106-publication/logs/legacy-cli.stdout.log) |
| Source fingerprint a whitespace | 47 přesných source/test/fixture souborů; původní plain `git diff --check` exit 0 ověřoval jen pracovní strom | [source manifest](validation/20261106T115551Z-network-adapter-926e106-publication/source-manifest.json), [výsledky](validation/20261106T115551Z-network-adapter-926e106-publication/results.json) |

[Prostředí](validation/20261106T115551Z-network-adapter-926e106-publication/environment.json):
arm64, macOS 27.2/26B123, Xcode 27.2/27B52, Swift 6.4.2. Paralelní práce dalších workerů
znamená, že délky buildu/testu nejsou výkonovým měřením. [Předregistrace](validation/20261106T115551Z-network-adapter-926e106-publication/inputs.json)
obsahuje přesné příkazy a očekávání před závěrečným během.

- SHA-256 měřeného CLI: `c72e3708968549cb14b7de3ff0d4315f335aa2a0d76dd9030f14e18adb670dd4`.
- SHA-256 source manifestu: `5c3c0bcbf5511436a9ad8929c9de00e2b768f2f53cfa885ca5864ac45585cacf`.
- SHA-256 [původního manifestu 114 souborů](validation/20261106T115551Z-network-adapter-926e106-publication/original-manifest.sha256.json): `9d0cc24ef31fc7d247ef83b8fa6ff581547c9d145ce1553d18346fb988da142b`.

Čtyři skutečné TCP/UDP v4/v6 producer positives přijímá consumer bez source/record konfliktů.
Adversarial a interrupted záznamy zachovávají foreign/replayed/malformed/zero/partial/truncated
kontakty a odmítnutý connect. Chybějící terminal ani data se nepřekládají na nulu.
Negativní mutace, foreign zero-UUID regression a matrix/clock overlays jsou výslovně syntetické.

Dvě neúspěšné vývojové iterace jsou zachovány v `development/` a vysvětleny ve verdictu:
kolize názvu encoderu/makro kompilace nových testů a nesprávné očekávání testu, které už
odmítl striktní actor/kind decoder matice. Oprava nezmírnila původní decoder. Následující
běhy i finální připnutý běh prošly. [Úklid](validation/20261106T115551Z-network-adapter-926e106-publication/cleanup.json)
odstranil pouze vlastní build/modules/cache/tmp; důkazy a malá offline binárka zůstaly.

Hash ani shoda importovaných podpisových flags neověřují autorství. Chybí nezávislé peer
credentials/roundtrip, capture completeness, externí kalibrace, bind policy, wildcard/LAN
metodika, L4 délky/retry/failure modes a tři testovací oblasti. Žádný výstup není isolation
pass. [Původní validace](VALIDATION.md) a historické raw/logs zůstávají zachované.


## Opravy nezávislého review — source 608b41c

[Nový záznam](validation/20261106T120955Z-network-review-fix-608b41c/verdict.md) ověřil
`608b41cc308ffa6d6fb530f24bc3a899537e0411`: **63/63 Release testů**, **30/30 network CLI**,
**25/25 legacy CLI**, **4/4 přesných review reprodukcí** a **61/61 původních producer hashů**.
Původní source `926e106` a jeho 114souborový záznam zůstávají byte-identické; nové výsledky
se nepřipisují původnímu běhu.

Tři P2 opravy odpovídají skutečné common implementaci: dosažení maximálního počtu kontaktů
je incomplete již při rovnosti; TCP při 4096 B končí před další kontrolou EOF; validátor
omezí sequence před sčítáním, takže `Int.max` nesrazí report. Přesné původní reviewer vstupy,
stdout/stderr včetně dřívějšího SIGTRAP jsou v `review-counterexamples/`; opravené výsledky
jsou v [review-fixed/summary.json](validation/20261106T120955Z-network-review-fix-608b41c/review-fixed/summary.json).
Všechny kontakty zůstávají zachované a označené jako incomplete. Pozitivní syntetické kontroly
potvrzují počet kontaktů pod limitem, TCP 4095 B a UDP přesně 4096 B bez truncation.

[Source manifest](validation/20261106T120955Z-network-review-fix-608b41c/source-manifest.json)
a [příkazy](validation/20261106T120955Z-network-review-fix-608b41c/commands.json) připínají přesné
vstupy. [Manifest 137 souborů](validation/20261106T120955Z-network-review-fix-608b41c/manifest.sha256.json)
má SHA-256 `f2ea55f4477f47036cdfc22440fc2246bbff80426b73181fd5ca3214e068f75a`;
měřená binárka má SHA-256 `48de990ee1c5e0f5c6860cf37e756975f4fa0cdd06cceb653c7b8d394f9b9090`.

Kontrola whitespace proti základnímu commitu prošla pro source/test/tool soubory. Kontrola
celé větve vrací očekávaný exit 2 pro pět zachovaných whitespace řádků původního compiler
logu; obě kontroly mají samostatné logy. Původní `git diff --check` ověřoval čistý pracovní
strom, nikoli celý diff větve. Diagnostické whitespace se neupravovalo.

Nová publikovaná diagnostika má [mapu odvozenin](validation/20261106T120955Z-network-review-fix-608b41c/publication.json)
a přesné soukromé originály. Pro dvě původní diagnostiky s home cestou jsou vytvořené
[oddělené sanitizované publikační kopie](publication/20261106-review-diagnostic-derivatives-926e106/README.md)
s original/published SHA-256 a mapou náhrady prefixu. Automatická kontrola odmítla přepsání
souborů ve starém zapečetěném záznamu, protože by přestal odpovídat původní manifest;
starý záznam proto zůstává nedotčený v lokální archivní větvi a přesné soukromé kopii.
Veřejná větev obsahuje samostatnou úplnou publikační projekci: 112 původních payload souborů
beze změny a dvě označené diagnostické odvozeniny. Nový manifest pokrývá 116 souborů včetně
původního manifestu a mapy publikace; původní 114položkový manifest se porovnává s archivním
originálem, nikoli s redigovanými kopiemi. Původní záznam ani jeho historie se nepřepisovaly.

Vlastní nové build/cache/modules/tmp jsou uklizené; malé offline CLI a přesné soukromé
originály zůstávají pro audit. Žádné živé sondy, uživatelé, signing, TCC, pf ani capture
neproběhly. Brány a původní meze důkazu se nemění.
