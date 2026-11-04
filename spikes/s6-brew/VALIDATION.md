# WP1.E1 — provedená verifikace přípravy

Datum: **2026-11-04**. Základ větve: `afae1ca7dfe78f03d5006c42b6b01093772eba0c`.
Claim commit: `3936f41`. Host pro offline parser tests: macOS **27.2 (26B123)**,
`/usr/bin/python3` **3.9.6**. Nejde o zaregistrovaný S6 laboratorní run ani důkaz macOS izolace.
Žádné skutečné instalační, privileged, root, APFS, síťové enforcement ani rollback měření neproběhlo.

## Přesné provedené příkazy

Z kořene této větve:

```bash
/usr/bin/python3 -I -B -m unittest discover -s spikes/s6-brew/tests -v
bash -n spikes/s6-brew/plan.sh spikes/s6-brew/prepare-prefix.sh spikes/s6-brew/cleanup-prefix.sh
git diff --check
```

Výsledek finálního testu: **46 tests, OK**, všechny úspěšné. Bash syntax: exit 0.
Whitespace kontrola: exit 0. Testy běží se standard library, bez Homebrew invokací, bez sítě,
bez package execution, bez `/opt` zápisů. Syntetické změny souborů jsou pouze vlastní
`TemporaryDirectory`, včetně testu metadata-only scaffold/cleanup helperů pod běžným UID.
`--apply` CLI s real root nebylo spuštěno. `-I -B` nepřidává cwd na import path a nevytváří bytecode;
test/skript přidává pouze svůj explicitní sibling module path.

Součástí stejné sady jsou **skutečné CLI a shell entrypointy**, nejen volání testovaných funkcí:

```bash
/usr/bin/python3 -I -B spikes/s6-brew/s6.py select
bash spikes/s6-brew/plan.sh
/usr/bin/python3 -I -B spikes/s6-brew/s6.py cooldown
/usr/bin/python3 -I -B spikes/s6-brew/s6.py report \
  --before spikes/s6-brew/examples/synthetic-before.json \
  --after spikes/s6-brew/examples/synthetic-after.json \
  --attempts spikes/s6-brew/examples/synthetic-attempts.json \
  --tests spikes/s6-brew/examples/synthetic-tests.json
bash spikes/s6-brew/prepare-prefix.sh --uid 450 --gid 701 --state-dir /synthetic-not-created/s6/state
bash spikes/s6-brew/cleanup-prefix.sh --uid 450 --gid 701 --state-dir /synthetic-not-created/s6/state
```

CLI testy tyto příkazy volají přes absolutní cesty na stejný checked-out soubor, zachycují stdout
a parsují jej jako JSON. Dry-run prefix wrappery ověřují `dry_run: true` a nevytvoření cesty.

| Kontrola | Pozorovaný výsledek (offline/synthetic) |
|---|---|
| Pinned analytics | 43 338 raw řádků, přesně 200 canonical core cílů; všechny uložené SHA ověřeny |
| Přepočet selection | Shodný s pinned `top-200.json`; digest `f5106e5e52ab41ef9729b16c8d730f8017a93f827cf1de274cdbed710ad9044d` |
| Plán | 200 install argv, 20 předem vybraných test argv, 2 app-only cask argv; `executable: false` |
| Bottle metadata | 198 cílů má požadovaný tag/`all`; **není měřené pour ratio** |
| Cooldown inventory | 398 bottle/source records; všech 398 `refuse_unknown_publication` |
| Report dodaných fixtures | 1 bottle, 1 source, 1 failed, 1 unknown, 1 version_drift, 195 unattempted |
| Report poměry | 1/2 mezi klasifikovanými = 0.5; 1/200 = 0.005; `cohort_complete: false` |
| Test sample fixtures | 18 passed, 1 failed, 1 missing; `test_sample_all_passed: false` |
| Úplná synthetic kohorta | 200 synthetic bottle receipts + všech 20 exit 0; **stále Neověřeno** |
| Prefix default | Přesný plán bez otevření host cest a bez změn |
| Úklid fixtures | Pouze vlastní stejný prázdný adresář; konflikty odmítnuty, opakovaný úklid idempotentní |

Předem určený sample pro tento snapshot:

```text
ca-certificates ffmpeg libpng libffi pipx
gnupg z3 certifi libgit2 mpg123
mole libedit fzf libxcrypt libyaml
uvwasi openjdk@21 shellcheck aws-c-io llama.cpp
```

## Negativní pokrytí implementace

- Analytics: duplicate label/JSON key, neplatný count, shell-like label, nedostatečný počet cílů;
  agregace options, odstranění taps, deterministické tie-break a 5 vzorků na každých 50 ranků.
- Plán: chybějící/duplicitní katalog, nesprávný host prefix, traversal a overlap rootů, chybějící
  restore volume, neznámý bottle tag; žádné odvození skutečné kompilace z absence bottle metadat.
- Cask: další install artifact (`binary`), custom target/path/override a disabled cask se nenabízí
  jako app-only kandidát. `--appdir` zůstává jen argument, nikoli enforcement všech zápisů.
- Cooldown mocks: přesná hranice, příliš mladý artefakt, budoucí timestamp, chybějící/naive/invalid
  timestamp, cizí/missing identita, hash/URL/tag/verze/rebuild mismatch, katalogové a commitové
  údaje nezaměněné za publication. Kladný mock výsledek je jen `eligible_synthetic_only`.
- Receipts: oddělené neúspěchy a missing, bool vs string, neznámý poured flag není source,
  built-as-bottle nestačí, preexisting stav, více kegů, verze/revize drift, jiný tap, duplicate
  outcomes/receipts, neplánovaný test, nečíselný exit code, prázdný jmenovatel.
- Prefix: non-root apply odmítnutí před FS přístupem, nevhodný state path/identity, short writes/EINTR,
  partial invalid journal, ACL conflict, inode/mode drift, nový obsah, symlink, opakovaný cleanup,
  recreated target a interrupted/planned journal. Žádný root apply ani reálný mount není v testu.

První vývojový běh nalezl neošetřený `None` timestamp v mock checkeru. Oprava přidala explicitní
kontrolu typu před parsováním; výše uvedený finální nativní běh ověřuje odmítnutí namísto výjimky.

## Neprovedeno a mezery

**S6/HB-01…07, GW-17, POS-01, S4 a RB zůstávají Neověřeno.** Nebylo spuštěno `brew`, jeho installer,
formule, source build, `brew test` ani cask. Nebyl použit `sudo`, měněn `/opt`, root UID/GID, ACL,
mount, APFS, systémové nastavení nebo Keychain. Nebyly čteny skutečné credential stores/tajemství.
Čteny byly veřejné oficiální API a source texty jako data; zdroje/hash/date uvádí SOURCES.md.

Chybí reálná topologie, ownership/kvóty, validní credentials/session každé sondy, před/po host oracle,
instalační logy/receipts skutečné kohorty, skutečné rootless cask cíle, per-artifact publish-time
provider, D5/S5 route/cache/redirect enforcement, úplný write inventory a B4 rollback/crash cleanup.
Parser výstup není nezávislý důkaz původu stažených bytes. Ani všechny zelené unit testy tyto mezery
neuzavírají. Případný konflikt s novějšími Homebrew metadaty vyžaduje nový reviewovaný snapshot.

Disk: zachovány pouze potřebné compressed analytics a 200 metadata objektů, malé provenance/cask
JSON a fixtures. Celý 32 MB katalog byl zpracován v paměti a nebyl uložen. Zdrojové texty nebyly
uchovány jako execution payload; zachovány jejich pinned URL a hashe. Žádný externí dependency,
`.build`, `__pycache__`, `.pyc`, package payload nebo dočasný generovaný plán/report nezůstal.
