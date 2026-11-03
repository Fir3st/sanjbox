# Ohrádka — rozhodnutí

Rozhodnutí F0 z [PLAN.md §Postup F1](../PLAN.md) a záznamy o změnách kontraktu. Rozhoduje výhradně uživatel.
Dokud je položka **Otevřeno**, platí původní požadavek a příslušné brány nelze vyhodnotit jako prošlé.
Označení „snížené riziko“ není souhlas se změnou (PLAN §Akceptační kontrakt).

## Již přijatá rozhodnutí (2026-10-31)

| ID | Rozhodnutí | Zdroj |
|---|---|---|
| D-001 | GUI izolace: každá oblast = vlastní neviditelná macOS relace, okna zobrazovaná na ploše hosta | PLAN §Rozhodnutí uživatele |
| D-002 | Bez placeného Apple Developer Programu: žádná Network Extension, Endpoint Security, MDM PPPC | PLAN §Rozhodnutí uživatele |
| D-003 | Lokální podpis bez `get-task-allow`; SMAppService s Personal Team ověřit v S8 | PLAN §Rozhodnutí uživatele |

## F0 — rozhodnutí před F1

| ID | Otázka | Možnosti | Rozhodnutí | Datum |
|---|---|---|---|---|
| F0.1 | Kontrakt: potvrdit threat model; další výjimky z R2/R3? | potvrdit beze změny / doplnit výjimky (vyžaduje záznam změny níže) | Otevřeno | |
| F0.2 | R6: je per-app Coherence podmínkou MVP, nebo stačí jedna VNC plocha na oblast? | Coherence podmínkou / VNC plocha přípustná pro MVP | Otevřeno | |
| F0.3 | Host access: smí host číst svazek projektu (backup/export), nebo jen řízený export? | čtení pro backup/export / jen řízený export | Otevřeno | |
| F0.4 | Docker: v MVP, nebo až F4? | MVP / F4 | Otevřeno | |
| F0.5 | Signing: je přípustný placený Developer ID / NE, pokud free Personal Team nestačí? | ano / ne (platí D-002) | Otevřeno | |
| F0.6 | Fallback při neúspěchu S1/S2 | jedna aktivní oblast / VNC plocha / CLI only / VM (odmítnutí VM platí, dokud nerozhodneš jinak) | Otevřeno | |
| F0.7 | Externí identity: které integrace s oddělenými a omezenými účty? | seznam integrací + účty a scopes | Otevřeno | |
| F0.8 | Měření: cílový Mac, displeje, tři aktivní oblasti, acceptance statistiky; Docker start/stop budget (nejpozději před S7) | hodnoty zapsat do `docs/LAB.md` | Otevřeno | |

## Změny kontraktu

Každá změna požadavku nebo fallbacku musí mít záznam. Bez tvého výslovného rozhodnutí platí původní požadavek.

| ID | Datum | Původní požadavek | Navržená změna | Dopad | Nová akceptace | Rozhodnutí |
|---|---|---|---|---|---|---|
| — | | | | | | |
