# Návrhové schema `sanjbox.state-manifest.v1`

Schema je offline datový kontrakt B3, nikoli F2 `Contracts/`, deployment příkaz nebo důkaz brány.
Úplné vzory jsou [MVP](examples/mvp.state-manifest.json) a [F4](examples/f4.state-manifest.json).
Všechny objekty mají uzavřenou množinu klíčů; unknown fields a duplicate decoded keys jsou chyba.
Povinná pole se nesmějí vynechat. Jen `declaredUUID`, `planningBudgetBytes` a `limitBytes` jsou
volitelné/nullable podle pravidel níže. JSON čísla pro byty jsou `UInt64`, UID/GID `UInt32`, nikoli float.

| Pole / objekt | Pravidlo |
|---|---|
| `schema` | Přesně `sanjbox.state-manifest.v1` |
| `intent` | Pouze `design-only`; žádné `verified`/`observed` ani `apply` |
| `phase` | `mvp` nebo `f4-design` |
| `zone` | `id`: přesně 4 lowercase ASCII písmena/číslice; `uid`, `gid`: nenulové návrhové identifikátory. Žádné OS lookup. |
| `containers[]` | 1–8 objektů: `id`, optional `declaredUUID`, optional `planningBudgetBytes` (kladný, jinak null/omitted) |
| `volumes[]` | 1–16 objektů popsaných níže; každý má write root a je členem restore unit |
| `roots[]` | 1–64 objektů popsaných níže |
| `runtimePolicy` | MVP: `deferred-f4` a 0 runtime kořenů; F4: `declared-unverified` a přesně 1 runtime kořen |
| `rollback` | Jedna jednotka zahrnující každý deklarovaný zone volume právě jednou |
| `hostControl` | Návrh host-root-owned control directory, policy/recovery mimo restore unit |
| `readOnlyInputs[]` | 0–32 objektů `id`, `path`, `purpose` pro explicitní veřejné vstupy; vlastnost read-only není měřena |
| `outsideWrites` | Přesně `forbidden-unverified`; neznámé zápisy mimo manifest se nesmějí vydávat za vynuceně blokované |
| `hostAccess` | Přesně `controlled-export-only` podle F0.3 |

Všechny collection IDs a `rollback.unitID` mají 1–32 lowercase ASCII písmen/číslic/pomlček.
IDs jsou v každé kolekci unikátní. Reference musejí existovat; chybné/duplicitní IDs se nesmějí
zaměnit nebo způsobit trap v mapě. `declaredUUID` má 36 znaků, platný nonzero UUID; v celém modelu
se nesmí zopakovat u jiného kontejneru ani svazku (case-insensitive). Null znamená neznámé přiřazení.
Nikdy se tím neověřuje skutečná APFS identita, role ani disk device.

## Svazky a kapacitní plán

`VolumePlan`: `id`, `containerID`, optional `declaredUUID`, `mountPoint`, `filesystem`,
`caseSensitive` (bool), `ownership`, `quota`.

- `filesystem` je `apfs`; `ownership` je `required`. Deklarované `caseSensitive` není naměřený flag.
- `mountPoint` je normalizovaná absolutní návrhová cesta. Zakázané jsou `/`, známé aliasy,
  široké systémové parenty (`/Users`, `/Volumes`, `/opt`, `/opt/snj`, `/Applications`, `/Library`,
  `/System`, `/private`, `/usr`) a překrývající se/nested mountpointy. To není vyčerpávající seznam
  nebezpečných reálných cest; v1 nic nemountuje a neumí schválit deployment.
- Každý svazek patří do právě jednoho deklarovaného kontejneru. Žádný prázdný logický kontejner.
- `quota`: povinné `mode`, `reserveBytes`, volitelné `limitBytes`.
  `limited`: kladný limit a reserve ≤ limit. `unbounded` / `unresolved`: limit chybí nebo null,
  nikoli `0`. Reserve `0` znamená žádná rezervace. Unresolved/unbounded se propíše jako varování.
- Součet rezerv nesmí přesáhnout `planningBudgetBytes`, pokud je plánovací budget zadaný.
  Součet finite quota limitů nad budget je jen varování: limity nejsou rezervy.
  Overflow `UInt64` je chyba, nikoli saturace či wrap. Budget nezahrnuje žádné automaticky zjištěné
  host volumes, snapshoty nebo dostupnou kapacitu; není potvrzený filesystemem.

## Kořeny a obnova

`RootPlan`: `id`, `role`, `volumeID`, `relativePath`, `ownerUID`, `rollback`, `purpose`.

Povinné role jsou právě po jedné `home`, `project`, `prefix`, `cache`, `tmp`; ve F4 také `runtime`.
Další výslovné zápisové kořeny mají roli `additional`. `purpose` je neprázdný popis do 256 UTF-8 B.
`ownerUID` musí být deklarovaný zone UID, `rollback` přesně `whole-volume`.
`relativePath` je normalizovaná relativní cesta nebo `.` pro samotný volume root. Absolutní
cesta se jen sestaví jako mountpoint + relativePath; neposílá se do `stat`, `realpath` ani `open`.
Prefix této konkrétní varianty musí vyjít přesně `/opt/snj/<zone.id>` (13 UTF-8 B).

Kořeny jsou vzájemně disjunktní podle component boundaries a konzervativního textového porovnání.
Např. `home` a `home/Library/Caches` se nesmějí vykázat jako dva oddělené kořeny. Ve vzoru home
zahrnuje všechny vlastní vnořené cesty; dedicated cache je jeho sourozenec. `whole-volume` znamená,
že obnova svazku zahrnuje také jeho další položky: seznam root rolí není filtr snapshotu.
Žádný per-directory exclude ze snapshotu se nepodporuje. Reálné zápisy mimo svazek zůstávají otevřený RB-01.

`RollbackPlan` povinně obsahuje:

```json
{
  "unitID": "t001-full-state",
  "volumeIDs": ["state", "tools"],
  "strategy": "rebuild-writable-state-then-switch",
  "quiescence": "whole-uid-required",
  "recoveryRequired": true,
  "startPolicy": "deny-until-verified"
}
```

`volumeIDs` je přesná množina všech deklarovaných svazků, bez duplicit a unknown references.
Každý jiný strategy/quiescence/startPolicy nebo vypnutí recovery je chyba. Text strategie je
**požadavek na B4**, ne existující implementace. `rename-swap`, přímý writable snapshot mount,
částečná obnova projektu a atomická vícesvazková obnova nejsou podporované konstrukce.

## Host control a veřejné vstupy

`HostControlPlan`: `directoryPath`, `ownerUID: 0`, `directoryMode: "0700"`, `policyFile`,
`recoveryFile`, `rollback: "excluded"`. Oba soubory jsou rozdílné single filenames do 128 B,
bez `/` a `.`/`..`, pod control directory. Directory nesmí ležet uvnitř ani nad žádným zone mountpointem.
Je to deklarace desired properties, nikoli čtení/kontrola skutečného vlastníka/mode nebo recovery protokolu.

`ReadOnlyInput`: `id`, normalizovaný absolutní `path`, neprázdný `purpose` do 256 B.
Nesmí překrývat zone volume, host control ani jiný read-only input. Symbolické linky a skutečné
aliases se offline nerozhodují. Deklarace nevydává implicitní oprávnění ani příslib read-only enforcementu.

Všechny textové cesty jsou nejvýše 1024 UTF-8 B, bez prázdných komponent, `.`/`..`, trailing `/`,
control znaků a backslash. Známé aliases se odmítají i po lowercase/canonical normalization.
Shell-like znaky zůstávají doslovná data; validátor nikdy nevolá shell ani generovaný příkaz.
Nižší filesystemové limity jmen, Unicode folding konkrétního FS, symlinky, mount substituce a
TOCTOU musejí samostatně ověřit budoucí native helper a laboratorní sondy.
