# Validace výzkumného artefaktu — 2026-11-06

**Dokumentační kontrola, žádný runtime APFS experiment ani gate verdict.** Base:
`2a15fc2608a04b3cf06ba676810ffe69edae3982`; claim commit `9df6b73`.
Konfigurace a plné primární hashe jsou v [sources.json](sources.json).

| Kontrola | Výsledek a praktická mez |
|---|---|
| Source manifest | Uzavřený tvar podle [SOURCES](SOURCES.md), 13 unikátních S01…S13, UTC capture datum, kladné délky, SHA-256 a připnutý 40hex XNU commit. Bez recovery/production schema změn. |
| Origin bytes | Shoda SHA-256 a velikosti všech 10 instalovaných souborů a 3 vlastních malých HTTPS captures. SHA pin dokládá čtenou reprezentaci, nikoli pravdivost či runtime podporu. Žádné celé origin soubory nejsou commitnuté. |
| Odkazy a citace | Místní cíle nových dokumentů a nových odkazů RECOVERY/COVERAGE existují; všechny citované Sxx jsou v manifestu, každý zdroj je použit. HTTP zdroje viz způsob capture v SOURCES. |
| Kontrakt / logická kontrola | In-place revert odlišen od B3 rebuild; asr duplicate snapshot UUID a group live fallback; copy/clone metadata/hardlink limity; sequential switch a pending-intent deny zachovány. Whole-UID a cross-boot recovery zůstávají mezerami. |
| Rozsah diffu | Jen nový výzkumný adresář, additive RECOVERY odstavec a vlastní B4 řádek COVERAGE. Původní raw/evidence, VALIDATION-B4, kód, Contracts, PLAN, LAB, DECISIONS a stavy bran/testů nezměněny. |
| Whitespace a obsah | `git diff --check`; [manifest.sha256](manifest.sha256) pokrývá všechny ostatní soubory tohoto výzkumného adresáře. |

Neproběhl Swift rebuild/test: nevznikl kód ani změna runtime chování; opakování mock testů by
neověřilo žádné nové APFS tvrzení. Neexistuje nové „APFS prošlo“ číslo. Logická kontrola autora
nenahrazuje nezávislé review, které následuje před případnou integrací.

## Reprodukce bez diskových operací

Z tohoto výzkumného adresáře lze ověřit vlastní content manifest:

```bash
shasum -a 256 -c manifest.sha256
```

Následující standard-library kontrola čte jen deset přesných SDK/man cest; nevolá správu disků,
síť ani privileged API. Na jiné instalaci očekáváme možnost mismatch — původní manifest se
nesmí přegenerovat tak, aby se tím skryla změna podkladů.

```python
import hashlib, json
from pathlib import Path
manifest = json.loads(Path("sources.json").read_text())
assert manifest["schema"] == "sanjbox.b4-apfs.sources.v1"
assert len({s["id"] for s in manifest["sources"]}) == 13
for source in manifest["sources"]:
    if source["kind"] != "installed-primary":
        continue
    data = Path(source["location"]).read_bytes()
    assert len(data) == source["bytes"], source["id"]
    assert hashlib.sha256(data).hexdigest() == source["sha256"], source["id"]
print("10 installed source hashes match")
```

Plná kontrola při přípravě navíc ověřila množiny klíčů jednotlivých druhů source záznamů,
formát hash/revision/date a velikosti origin captures; výše je kratší kontrola pro reviewerův SDK.
Tři HTTPS captures byly ověřeny přímo při tvorbě; standardní kontrola je znovu nestahuje. Repo
záměrně nepřikládá proměnlivé celé HTML ani velký XNU soubor. Obsahové námitky je nutné posoudit
proti konkrétním locators, nestačí zelený checksum.
