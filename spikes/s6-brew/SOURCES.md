# E1 — primární podklady, zmrazeno 2026-11-04

Všechny síťové operace implementace byly čtení veřejných oficiálních Homebrew API a zdrojových
textů Homebrew GitHub repozitářů. Žádný installer/recipe nebyl spuštěn, žádný bottle/source/cask
payload nebyl stažen. Následující dokumentace popisuje možnosti upstreamu, nikoli výsledek S6.

| Zdroj | Použitý kontrakt |
|---|---|
| [Formulae API](https://formulae.brew.sh/docs/api/) | JSON katalog, analytics, bottle URL/SHA, source checksum; API snapshot je metadata, nikoli doklad publikace payloadu |
| [Installation](https://docs.brew.sh/Installation) | Custom prefix, non-admin provoz, `HOMEBREW_NO_SUDO`, explicitní appdir; installer kontrolovaný zvlášť |
| [Support Tiers](https://docs.brew.sh/Support-Tiers#custom-prefixes) | Apple Silicon prefix nejvýše 13 bytes a Cellar nejvýše výchozí délky; nová podpora má caveat stability |
| [Bottles](https://docs.brew.sh/Bottles) | Tag, cellar, rebuild a checksum; metadata dovolující relokaci nejsou skutečný výsledek pour |
| [Manpage](https://docs.brew.sh/Manpage) | `info --json=v2 --installed`, `test`, `--appdir`, cache/temp/log env, no-sudo; bottle mirror fallback je nutné ošetřit mimo env |
| [Cask Cookbook](https://docs.brew.sh/Cask-Cookbook) | Rozdíl app, binary, pkg, installer a hooks; appdir nevynucuje všechny zápisové cesty |
| [Pinned Formula source](https://github.com/Homebrew/brew/blob/8b0b7e44193854e22b84bcf2f58d65f21408d458/Library/Homebrew/formula.rb) | Export installed receipts obsahuje `version`, `used_options`, `built_as_bottle`, `poured_from_bottle`, `time`; samotné built-as-bottle nedokládá pour |
| [Pinned Tab source](https://github.com/Homebrew/brew/blob/8b0b7e44193854e22b84bcf2f58d65f21408d458/Library/Homebrew/tab.rb) | Receipt čas vzniká lokálně při vytvoření tabu; nejedná se o publikaci artefaktu |
| [Pinned official installer](https://github.com/Homebrew/install/blob/959bdd728192d78c47287c177796c3d86d111f09/install.sh) | Podporuje `--path`; text byl přečten/hashován, nebyl vykonán |

Brew revize pro čtení kontraktů: `8b0b7e44193854e22b84bcf2f58d65f21408d458`, committer date
`2026-11-04T19:40:47Z`. Oficiální installer revize: `959bdd728192d78c47287c177796c3d86d111f09`,
committer date `2026-11-04T09:23:08Z`, text SHA-256
`5f333bbe53bc490e51e7ccb1df8779b3dd6ee73a1a7379efda216edb08ccb148`.
Přesné raw source URL, časy zachycení, byte lengths a hashe pro příslušné dokumenty/zdroje jsou
v `data/source-contracts.json`. Datum commitu není datum publikace bottle/cask.

## Datové snapshoty

- `analytics-install-90d.json.gz`: celý původní JSON response, pouze gzip s `mtime=0`. Raw SHA-256
  `c1b6bc4712995fe7625441a7b6e31aa066c8f73cc44cb714b69d90a672484b83`, 2 482 447 B.
  Metadata zachycení a HTTP hlavičky v `analytics-source.json`; tyto hlavičky nejsou publication evidence.
- `top-200.json`: reprodukovatelný výstup `selection` z celých analytics. SHA-256 kanonického JSON
  objektu (sort_keys a compact separators) je
  `f5106e5e52ab41ef9729b16c8d730f8017a93f827cf1de274cdbed710ad9044d`.
- `formulae-selected.json.gz`: **celé** objekty vybraných 200 formulí z oficiálního
  [formula.json](https://formulae.brew.sh/api/formula.json), nikoli ručně vymyšlené fields. Celý upstream
  katalog měl 32 246 765 B a SHA-256
  `39ae2a185b5063a04a634be4823f48399a15a4f8b0941b75a6734c6c1e5c041d`.
  Velký katalog zůstal jen v paměti; zachována kompaktní bezeztrátová projekce 200 úplných objektů.
  `formulae-source.json` má přesný původ a pravidlo projekce. Raw upstream katalog není součástí repa;
  selekci jmen lze reprodukovat plně offline, integritu zachovaných objektů garantuje jejich repo hash,
  nikoli nezávislý důkaz správnosti upstreamu nebo ověřený JWS.
- `cask-rectangle.json`, `cask-itsycal.json`: celé oficiální metadata pro app-only kandidáty.
  `cask-coteditor.json`: celý oficiální negativní příklad pro úzký app-only parser (`binary` navíc).
  Jejich URLs/časy/hashe jsou v `casks-source.json`. Není stažen žádný `.dmg`, `.zip` ani aplikace.
- `snapshot-lock.json`: SHA-256 uložených bytes všech vstupů včetně compressed souborů a provenance.
  Je to pin v reviewovaném repozitáři, ne trust root pro libovolnou upstream publikaci.

Vynechání nevybraných katalogových objektů šetří disk. Gzip komprese nic nemění na vstupních
analytics, celých vybraných objektech ani testovatelnosti. Aktualizace na nové upstream hodnoty
vyžaduje nový snapshot, novou selekci/sample a review; CLI neprovádí žádný tichý live refresh.
