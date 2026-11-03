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

| ID | Otázka | Rozhodnutí | Důsledek | Datum |
|---|---|---|---|---|
| F0.1 | Kontrakt: potvrdit threat model; další výjimky z R2/R3? | **Potvrzeno beze změny.** Žádné další výjimky. | R2/R3 platí v plném rozsahu PLAN §Threat model. | 2026-11-03 |
| F0.2 | R6 v první verzi: per-app Coherence, nebo jedna plocha na oblast? | **V první verzi stačí jedno okno s plochou oblasti.** | Změna rozsahu MVP C-001. R6 zůstává požadavkem celého produktu (F3). | 2026-11-03 |
| F0.3 | Host access ke svazku projektu | **Jen řízený export.** | Host nedostane dědičnou ACL ke svazku oblasti; data ven jen přes export Ohrádky. | 2026-11-03 |
| F0.4 | Docker: MVP, nebo F4? | **Ve fázi F4.** | Změna rozsahu MVP C-002. R4 zůstává požadavkem celého produktu. S7 není podmínkou F2. | 2026-11-03 |
| F0.5 | Placený Developer ID / NE, pokud Personal Team nestačí? | **Žádný placený účet.** | Pokud S8 neprojde s Personal Team ani self-signed variantou, není náhradní cesta a vývoj se zastaví k novému rozhodnutí. Blokátor resolveru/ICMP (R3) se musí vyřešit bez Network Extension, jinak S3 neprošel. | 2026-11-03 |
| F0.6 | Fallback při neúspěchu S1/S2 | **Každá oblast jako samostatná plocha** (okno Sdílení obrazovky / vlastní RFB klient). | Pokrývá selhání S2 a selhání přežití relace bez klienta (klient zůstává připojený). **Nepokrývá** případ, kdy macOS vůbec nedovolí souběžné relace více uživatelů vedle konzole nebo v nich nejde akcelerované renderování; pak je nutné nové rozhodnutí. VM zůstává odmítnutá. | 2026-11-03 |
| F0.7 | Externí identity | **Částečně:** OpenCode, GitHub, Claude, Codex, Xcode (seznam není uzavřený). | Pro každou integraci zbývá určit typ údaje a rozsah oprávnění (viz otevřené podotázky níže). Do té doby jsou tyto integrace v testech jen mocky a v oblastech nepodporované. | 2026-11-03 |
| F0.8 | Měření | **Částečně: obecný Mac, vývoj na více strojích.** | Měření není vázané na jeden stroj. Každý běh brány zaznamená konfiguraci stroje; brána platí jen pro konfigurace, na kterých prošla. Zbývá určit minimální podporovanou konfiguraci a potvrdit výkonové cíle (níže). | 2026-11-03 |

### Otevřené podotázky

**F0.7 — rozsah integrací.** Přihlašovací údaj uvnitř oblasti se považuje za kompromitovatelný
(PLAN §5). Pro každou integraci je potřeba rozhodnout:

| Integrace | Otázka | Doporučení |
|---|---|---|
| OpenCode | Kteří poskytovatelé modelů a jakým údajem? | API klíč vložený bránou (do oblasti se nedostane). |
| Claude | API klíč přes bránu, nebo přihlášení předplatným (OAuth token žije v oblasti a otevírá celý účet)? | API klíč přes bránu; OAuth jen s výslovným souhlasem jako změna kontraktu. |
| Codex | API klíč přes bránu, nebo přihlášení účtem ChatGPT (OAuth token v oblasti)? | API klíč přes bránu. |
| GitHub | Per-repo deploy key v oblasti, fine-grained token na jedno repo, nebo push přes bránu? | Per-repo deploy key nebo fine-grained token omezený na repo projektu. |
| Xcode | Apple ID v oblasti, nebo App Store Connect API klíč (týmový klíč má přístup ke všem appkám týmu)? Je potřeba podepisování pro zařízení? | Simulator bez podpisu; podpis pro zařízení až po samostatném rozhodnutí. |
| „…“ | Další integrace (npm publish, cloud, databáze…)? | Doplnit seznam; neuvedené integrace jsou nepodporované. |

**F0.8 — parametry měření.**

| Parametr | Návrh k potvrzení |
|---|---|
| Minimální podporovaná konfigurace | Apple Silicon (M1 a novější), macOS 27.x, 16 GB RAM |
| Referenční konfigurace pro brány | Každý stroj, na kterém se brána měří, zapsaný v `docs/LAB.md`; výkonové brány měřit i na minimální konfiguraci |
| Souběh | Tři aktivní oblasti vedle host konzole |
| Výkonové cíle | Dle PLAN design card: cold login 10–30 s, warm/resume < 2 s, input-to-photon 30–50 ms při 60 fps, `npm install` přes bránu ≤ 1,1× nativně |
| Docker start/stop | Rozhodnout nejpozději před S7 (F4) |

## Změny kontraktu

Každá změna požadavku nebo fallbacku musí mít záznam. Bez tvého výslovného rozhodnutí platí původní požadavek.

| ID | Datum | Původní požadavek | Změna | Dopad | Nová akceptace | Rozhodnutí |
|---|---|---|---|---|---|---|
| C-001 | 2026-11-03 | R6: jednotlivá okna v Docku, rozlišitelná oblast | První verze (MVP) zobrazí každou oblast jako jedno okno s její plochou; per-app Coherence přechází do F3 | MVP nesplňuje R6; R6 zůstává požadavkem produktu. S2 není podmínkou F2. | MVP: plocha oblasti v okně hosta, okno jednoznačně označené oblastí; schránka jen řízeným mostem. Produkt: S2 + F3 beze změny. | Uživatel, F0.2 |
| C-002 | 2026-11-03 | R4: Docker funguje bez únikové cesty | Docker až ve F4 | MVP nesplňuje R4; R4 zůstává požadavkem produktu. S7 není podmínkou F2. | Produkt: S7 + F4 beze změny. | Uživatel, F0.4 |
