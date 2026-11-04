# S6 — Homebrew per oblast (WP1.E1)

**Příprava E1 je hotová; měření E2 neproběhlo.** Tento balík dodává zmrazený výběr 200 formulí,
offline plán konkrétních příkazů, předem vybraný vzorek 20 `brew test`, parser dodaných receipts,
inventář chybějících dat publikace a uživatelské skripty pro prázdný prefix. Žádný výstup tohoto
balíku neuzavírá S6, S5, S4 ani HB-01…07; `acceptance_status` je vždy **Neověřeno**.

Kód používá pouze Python 3.9+ standard library a Bash. `s6.py` nevolá síť, shell ani Homebrew.
`plan.sh` pouze vypisuje JSON s argumentovými poli; **příkazy z plánu nespouští**. `--apply` existuje
jen u prázdného prefixu a jeho úklidu. Příprava neinstaluje Homebrew ani žádnou formuli/cask,
nespouští `brew test`, nemění host `/opt`, nastavení systému ani Klíčenku.

| Případ | Příprava zde | Co chybí k důkazu |
|---|---|---|
| HB-01 / R1,R8 | Pinned top 200, verze/revize, bottle metadata, parser poměru | Skutečné instalace v krátkém prefixu, receipts/logy včetně neúspěchů |
| HB-02 / R1 | Deterministický předregistrovatelný vzorek 20 testů | Schválené spuštění všech 20, raw výstupy a exit codes |
| HB-03 / R1 | Rectangle a Itsycal: app-only kandidáti, explicitní appdir | Skutečný cílový bundle, práva, všechny vedlejší zápisy, žádné root kroky |
| HB-04 / R3; GW-17 / R3,R8 | Identita každého cílového bottle/source, unknown-time refusal | Důvěryhodný čas publikace přesného vydávaného artefaktu a enforcement D5/S5 |
| HB-05 / R2 | Postup nezávislého before/after oracle host prefixu | Metadata i byte-level canary důkaz v kontrolovaném labu |
| HB-06 / R2 | Zone-only příkazy, `HOMEBREW_NO_SUDO=1`, žádné privilegované cask kandidáty | Záznam skutečných operací a odmítnutí nepodporovaných instalací |
| HB-07 / R7; RB-01…08 | Vazba na B3 restore unit a všechny zápisové kořeny | Skutečná APFS identita, kvóty, inventář zápisů a B4 crash/rollback testy |

## Offline použití [implementátor]

Z kořene repozitáře, bez síťového přístupu a externích balíčků:

```bash
/usr/bin/python3 -I -B spikes/s6-brew/s6.py select
bash spikes/s6-brew/plan.sh
/usr/bin/python3 -I -B spikes/s6-brew/s6.py cooldown
/usr/bin/python3 -I -B -m unittest discover -s spikes/s6-brew/tests -v
bash -n spikes/s6-brew/plan.sh spikes/s6-brew/prepare-prefix.sh spikes/s6-brew/cleanup-prefix.sh
```

`plan --manifest /ABSOLUTE/MY.state-manifest.json --tag arm64_golden_gate` přijme návrhový B3
manifest. Adapter kontroluje potřebnou část kontraktu, **nenahrazuje plný validátor B3** a nečte
žádnou cestu z manifestu. Před reálným během musí uživatel použít plný B3 validátor s očekáváním
identity podle [B3 README](../s4-state/README.md). Soubor vzoru B3 se zde nemění.

`data/snapshot-lock.json` obsahuje SHA-256 všech uložených vstupů. CLI nejdříve ověří hashe,
raw analytics hash i shodu znovu vypočteného výběru s `data/top-200.json`; při driftu skončí 2.
Nový snapshot je nová reviewovatelná změna, nikoli automatický refresh při každém běhu.

## Reprodukovatelných top 200 a test sample

Zdroj je oficiální [90denní install analytics](https://formulae.brew.sh/api/analytics/install/90d.json),
okno **2026-08-05 až 2026-11-03**, zachycené 2026-11-04. Celých 43 338 vstupních řádků je bezeztrátově
uloženo v `data/analytics-install-90d.json.gz` (2 482 447 raw B, přibližně 444 KiB gzip).
Algoritmus sečte řádky stejného nequalifikovaného core názvu včetně variant s `--option`, vynechá
kvalifikované tapy, seřadí podle počtu sestupně a při shodě podle ASCII názvu. Verzionované formule
jsou samostatné. Duplicitní vstupní label, neplatné počty či méně než 200 jmen znamenají chybu.
Názvy se ověří proti 200 celým JSON objektům oficiálního katalogu (`tap=homebrew/core`, canonical
`full_name`). Aliasy se dodatečně neslučují. Install events zahrnují závislosti; nejsou počtem lidí
ani měřením úspěšných instalací v našem prefixu.

Výběr se nepřeskládá po selhání, chybějícím bottle ani disabled/deprecated metadatech. Všechny
problémy zůstávají u původního cíle. Zamrazené pořadí jmen **není instalační lockfile**: Homebrew
může stáhnout novější metadata, závislosti, resources, patche nebo fallback bottle. Před během
je nutné zaznamenat aktuální brew revision, zdrojové tap revisions/ruby checksums, verzi/revizi,
bottle rebuild/tag/digest a schválené přesné URL. Drift vyžaduje nový reviewovaný plán/běh.

Vzorek má **5 jmen z každé čtvrtiny pořadí (1–50, 51–100, 101–150, 151–200)**. Uvnitř čtvrtiny se
řadí SHA-256 řetězce `selection_sha256:name` a vezme prvních pět; pro zobrazení se vrátí pořadí
podle původního ranku. Není to statistický odhad všech testů. Vzorek se nenahrazuje podle výsledků.
`test_sample` a `test_commands` jsou součástí stejného plánu.

## Prefix a topologie [uživatel, host]

Laboratorní slot L6 vyžaduje prošlou S4, připravené relace S1 a předregistraci podle `docs/LAB.md`.
Práva/ACL, identita a nepřítomnost skutečných dat se řeší předem v host relaci. Root příkazy nikdy
nevznikají jako schopnost oblasti. `450:701` jsou **jen ilustrační B3 UID/GID**, ne zjištěná identita.

```bash
bash spikes/s6-brew/prepare-prefix.sh \
  --uid 450 --gid 701 --state-dir '/Library/Application Support/Sanjbox/lab/MY-RUN/state'
bash spikes/s6-brew/cleanup-prefix.sh \
  --uid 450 --gid 701 --state-dir '/Library/Application Support/Sanjbox/lab/MY-RUN/state'
```

Oba příkazy jsou standardně dry-run, ani neotevírají plánované systémové cesty. `--dry-run` je
výslovná alternativa; teprve `--apply` provede změny, **pokud jej uživatel spustí z důvěryhodné host
root relace**. Wrapper používá `/usr/bin/python3 -I -B`; nespouštěj ho pod rootem ze zone-owned
checkoutu nebo s oblastí upravitelným interpretem/kódem.

`prepare --apply` vyžaduje existující `/opt/snj` s root-owned, non-writable, nesymlinkovými předky
bez ACL a předem vytvořený host-root-owned `0700` state adresář mimo `/opt`. Vytvoří **pouze prázdný
`/opt/snj/t001`** s `0700`, předaným UID/GID. Jakýkoli existující prefix, včetně prázdného, je konflikt.
Před první změnou vytvoří `0600` journal s původním stavem „neexistoval“, identitou parentu a
plánovanou operací; fsync. Následně zapíše inode/device/owner/mode vytvořeného adresáře. Journal
je zamčený `flock`; zkrácené zápisy a EINTR se obsluhují, poškozený nebo pouze `planned` journal
vyžaduje ruční review. Nejde o produkční privilegovaný helper ani odolnost proti všem crash/TOCTOU
scénářům. Vyžaduje exkluzivní slot a důvěryhodný host/control state.

**Tento adresář je pouze scaffold mountpointu, nikoli APFS svazek.** Nevydává se za připravený
HB-07. Pokud už B3/B4 připravilo skutečný tools volume, tento scaffold krok přeskoč. Provisioning,
mount a ownership ověřeného APFS tools volume řeší B3/B4 pod uživatelem; tento skript jej
nemountuje, nepřepíná, neupravuje existující práva a nevytváří svazek na host Data volume jako náhradu.

| B3 role / volume | Plán E1 | Obnova |
|---|---|---|
| `prefix` / `tools` | `/opt/snj/t001`, včetně Cellar, Caskroom, repository, locks a bin symlinků | Celý tools volume |
| `home` / `state` | `/Volumes/Sanjbox/t001/state/home`, včetně `Applications`, nastavení a logů | Celý state volume |
| `project` / `state` | `/Volumes/Sanjbox/t001/state/project` | Celý state volume |
| `cache` / `state` | `…/state/cache/Homebrew` přes `HOMEBREW_CACHE` | Celý state volume |
| `tmp` / `state` | `…/state/tmp` přes `TMPDIR` a `HOMEBREW_TEMP` | Celý state volume |
| host control | `/Library/Application Support/Sanjbox/control/t001` | Mimo obnovovanou jednotku |

Jednotka `t001-full-state` zahrnuje **state + tools**. Nutné jsou whole-UID quiescence, uzavřená
fd/mappingy, rebuild-writable-state-then-switch, host recovery a deny-start-until-verified.
Nastavení environmentu neprokazuje, že všechny balíčky respektují cache/TMP/home; `/private/var`,
`/Library`, `/Applications`, mounty a jiné kořeny zůstávají v inventáři nezávislého oracle B3/B4.
Nevyřešený zápis mimo manifest blokuje HB-07/RB-01. Není implementován atomický snapshot více svazků.

## Instalace, sběr a casky [uživatel, oblast]

**Následující kroky jsou budoucí laboratorní návrh, zde nebyly provedeny.** Uživatel schvaluje
konkrétní příkazy a stahování. Před každým měřeným krokem nejdřív `sanjbox-whoami --expect` s
předem zapsanými real/effective UID/GID, skupinami a audit/bootstrap kontextem; nesoulad znamená
neplatné měření a další příkaz se nespouští. Očekávání se neodvozuje ze skutečnosti až po běhu.
Viz [společné sondy](../common/README.md). Offline planner/parser nejsou měřicí sondy a relaci neměří.

1. Host předem pořídí nezávislý before stav kontrolovaného `/opt/homebrew`, `/Applications` a dalších
   relevantních kořenů. Bez čtení skutečných tajemství: běh jen na syntetické laboratoři. Nestačí
   klientské „install succeeded“, log z oblasti ani prostý listing jmen. Ulož předregistrovaný
   metadata/ACL a byte-level canary oracle a evidence jeho úplnosti; chybějící pokrytí není pass.
2. V oblasti ověř reálný UID != 0, skupiny bez admina, správný home a APFS mount identities.
   Použij přesný environment z plánu (bez zděděných host proxy/credential proměnných a bez host
   Homebrew v PATH). Každý brew argv obsahuje `/opt/snj/t001/bin/brew`. Síťové policy a typed routing
   musí dodat S3/S5/D5; nastavení mirror domain samo nic nevynucuje a může mít fallback.
3. `bootstrap_commands` návrhu uvádějí stažení **pinned oficiálního installer scriptu**, výpočet
   SHA-256 a teprve následné `/bin/bash … --path=/opt/snj/t001`. Uživatel před spuštěním porovná hash
   s `bootstrap.sha256` a reviewne script. `HOMEBREW_NO_SUDO=1` zůstává zapnuté. Žádné `curl | bash`,
   `sudo brew`, cizí install script ani zásah do `/opt/homebrew`. Samotný installer může stáhnout
   další brew/runtime obsah; pin installeru **nepinuje** jím staženou revizi brew. Tu zaznamenej a
   porovnej s reviewovaným zdrojovým kontraktem; při změně nový review. Automatické bootstrap spuštění
   není součástí E1. Schválení přípravy E1 není schválení těchto budoucích instalací.
4. Z čerstvé instalační kohorty ulož `before.json`, po schválených 200 `formula_commands` pak
   `after.json`, příkaz je v obou případech přesně:

   ```bash
   /opt/snj/t001/bin/brew info --json=v2 --installed
   ```

   Každý příkaz se loguje samostatně: jméno, přesný argv/environment bez tajemství, UTC start/end,
   exit code, stdout/stderr, identity/provenance stažených artefaktů. Uchovej všechny neúspěchy.
   Do `attempts.json` exportuj pole `[{"name":"FORMULA","exit_code":0}, …]`; duplikáty/unknown
   targets jsou chyba. Jedna kohorta může nainstalovat cíl dříve jako závislost: jeho konečný receipt
   se počítá, pokud před začátkem kohorty neexistoval a jeho naplánovaný install příkaz skončil 0.
   Všechny dodatečné závislosti zůstávají odděleně v `other_installed_formulae`, ne ve jmenovateli 200.
5. Proveď všechny předem vybrané `test_commands` (např. `/opt/snj/t001/bin/brew test ca-certificates`)
   pouze po jejich schválení. Exit codes exportuj do stejně tvarovaného `tests.json`. Chybějící,
   neprovedený či selhaný test se nenahrazuje jiným. `brew test` spouští cizí kód a může mít síťové
   vedlejší efekty; patří do stejné omezené testovací relace a samostatného raw protokolu.
6. Předem vybrané cask kandidáty mají v pinned metadatech pouze install artifact `app`. Navržené
   příkazy jsou `/opt/snj/t001/bin/brew install --cask --appdir=ZONE_HOME/Applications rectangle`
   a totéž pro `itsycal`, s absolutním HOME rozvinutým v JSON plánu. `uninstall`/`zap` metadata se
   nespouštějí. CotEditor je záměrný negativní parser příklad (navíc `binary`); neprohlašujeme jej za
   nebezpečný, ale tento úzký app-only plán jej nepodporuje. Při změně cask artifactů nový review.
   Zaznamenej skutečný bundle path, UID/GID a writes oracle. Samotné `--appdir` neomezuje arbitrary
   installer code; žádné privilegované `pkg`/installer/hooks se nezahrnují jako podporované.
7. Host po běhu porovná nezávislé oracles a B3/B4 celý restore unit. Jakákoli změna host prefixu,
   potřebný root krok z oblasti nebo nepokrytý write root zůstává explicitní selhání/mezera.
   Nový neměnný run podle GUIDE má environment, inputs, credentials, raw, verdict a manifest hashů;
   verdikt E2 a review jsou samostatné. Tento adresář neobsahuje skutečný S6 evidence run.

## Receipt report a jeho hranice

```bash
/usr/bin/python3 -I -B spikes/s6-brew/s6.py report \
  --before spikes/s6-brew/examples/synthetic-before.json \
  --after spikes/s6-brew/examples/synthetic-after.json \
  --attempts spikes/s6-brew/examples/synthetic-attempts.json \
  --tests spikes/s6-brew/examples/synthetic-tests.json
```

Tento konkrétní příkaz zpracovává **syntetické fixtures**, ne lokální instalace. Pro uživatelský běh
nahraď čtyři vstupy exportovanými soubory z jeho raw adresáře. Parser nikdy sám nevolá `brew`.
Klasifikuje pouze nový, jediný receipt s očekávanou verzí/revizí, core původem, prázdnými options a
explicitním bool `poured_from_bottle`; `built_as_bottle` nestačí. `time` je lokální instalační čas,
není publication time. Neznámé příznaky, jiné verze, více kegů, missing receipt, preexisting,
unattempted a failed jsou oddělené výsledky.

Report uvádí podíl bottles mezi klasifikovanými a podíl ze **všech 200**; první je null, pokud není
co klasifikovat. `cohort_complete` pouze znamená 200 klasifikovatelných dodaných receipts. Ani všech
200 + prošlý sample neověřuje digest skutečného payloadu, nezměněný host, relaci, cooldown, rootless
provedení nebo rollback. Receipts z oblasti lze změnit a nejsou nezávislý bezpečnostní oracle.
Chybějící artifact hash/provenance se musí doložit zvlášť S5/download evidence, nikoli domyslet z verze.

## Cooldown

Oficiální API snapshot má u bottles URL + SHA-256 + tag + rebuild a u source stabilní URL + checksum.
V těchto uložených objektech **není artifact-bound publication timestamp**. Všech 398 cílových
bottle/source záznamů proto dostává `refuse_unknown_publication`. Snapshot obsahuje bottle metadata
pro 198 cílů na `arm64_golden_gate` (případně platform-independent `all`); **198/200 není výsledek
nalití bottles**. Starší tagy/fallbacky nejsou tímto odhadem klasifikovány.

`generated_date`, katalogový HTTP Last-Modified/Date, tap commit, upstream release datum, lokální
receipt `time`, první pozorování a build timestamp nejsou automaticky časem publikace přesných bytes.
Rebuild může změnit bottle při stejné formula verzi. Budoucí poskytovatel času musí provázat původ,
verzi/revizi/rebuild/tag, canonical URL a hash se skutečnou publikací; cache, direct URL, redirects,
resources a zdrojové buildy potřebují stejné pokrytí. E1 neimplementuje takový autoritativní provider.

`synthetic_cooldown` testuje pouze navržený kontrakt na mocks: přesná identita, hranice stáří,
neznámý/neplatný čas, budoucnost a mismatch. Jediný kladný výsledek zní `eligible_synthetic_only`;
žádná cesta neautorizuje živé stažení. Lokální cache/importovaný artefakt je mimo síťovou viditelnost.
**HB-04 není splněn; zrušení cooldownu vyžaduje výslovné rozhodnutí uživatele v DECISIONS.md.**
Tato metadata-rešerše nedokazuje, že žádný jiný zdroj času nemůže existovat; pouze jej nedodává.

## Úklid [uživatel, host]

`cleanup-prefix.sh --apply` čte pouze vlastní root-owned journal. Odstraní jen původně vytvořený,
stále prázdný adresář se stejným inode/device/UID/GID/mode, bez ACL, na stejném zařízení jako parent.
Chybějící cíl je idempotentní úspěch; znovu vytvořený po zapsaném úklidu je konflikt. Symlink,
mount, neznámý/poškozený journal, nový obsah či změna práv znamenají odmítnutí. Nic nepřepisuje,
neprovádí `rm -rf`, rekursivní `chown`, `brew uninstall` ani cask `zap`. Journal zůstává jako evidence.

**Nainstalovaný nebo namountovaný prefix tento cleanup neuklidí.** Po měření musí uživatel v B4
zastavit celé UID a obnovit/uklidit ověřený APFS restore unit; pak případný prázdný vlastní scaffold.
Neověřený B4 cleanup je důvod slot neuzavřít, nikoli důvod přidat agresivní mazání. Postup ani reálný
privilegovaný cleanup zde nebyly provedeny. Syntetické testy používají jen `TemporaryDirectory` a po
sobě jej odstraní. Nejsou zde `.build`, `__pycache__` ani stažené package payloads.

Zdroje a jejich hashe: [SOURCES.md](SOURCES.md). Přesné provedené kontroly a mezery:
[VALIDATION.md](VALIDATION.md).
