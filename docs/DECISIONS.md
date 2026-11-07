# Sanďbox — rozhodnutí

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
| F0.3 | Host access ke svazku projektu | **Jen řízený export.** | Host nedostane dědičnou ACL ke svazku oblasti; data ven jen přes export Sanďboxu. | 2026-11-03 |
| F0.4 | Docker: MVP, nebo F4? | **Ve fázi F4.** | Změna rozsahu MVP C-002. R4 zůstává požadavkem celého produktu. S7 není podmínkou F2. | 2026-11-03 |
| F0.5 | Placený Developer ID / NE, pokud Personal Team nestačí? | **Žádný placený účet.** | Pokud S8 neprojde s Personal Team ani self-signed variantou, není náhradní cesta a vývoj se zastaví k novému rozhodnutí. Blokátor resolveru/ICMP (R3) se musí vyřešit bez Network Extension, jinak S3 neprošel. | 2026-11-03 |
| F0.6 | Fallback při neúspěchu S1/S2 | **Každá oblast jako samostatná plocha** (okno Sdílení obrazovky / vlastní RFB klient). | Pokrývá selhání S2 a selhání přežití relace bez klienta (klient zůstává připojený). **Nepokrývá** případ, kdy macOS vůbec nedovolí souběžné relace více uživatelů vedle konzole nebo v nich nejde akcelerované renderování; pak je nutné nové rozhodnutí. VM zůstává odmítnutá. | 2026-11-03 |
| F0.7 | Externí identity | **Rozhodnuto:** Claude a Codex přes předplatné, OpenCode přes OAuth i API klíče, GitHub classic token, Xcode jen Simulator. Další integrace zatím žádné. | Přihlášení předplatným/OAuth žije v oblasti: změna kontraktu C-003. GitHub classic token drží brána (podrobnosti níže). Neuvedené integrace jsou nepodporované. | 2026-11-07 |
| F0.8 | Měření | **Rozhodnuto:** LAB-v1 P1–P6 přijato se změnami P4 a P5 (níže). | Minimum a referenční stroj M1 / 16 GiB / macOS 27.x. Brána platí jen pro konfigurace, na kterých prošla. Docker start/stop zůstává otevřený do S7. | 2026-11-07 |

### Rozhodnuté podotázky

**F0.7 — rozsah integrací (2026-11-07).** Přihlašovací údaj uvnitř oblasti se považuje za kompromitovatelný
(PLAN §5).

| Integrace | Rozhodnutí | Důsledek |
|---|---|---|
| Claude | Přihlášení předplatným (OAuth token v oblasti) | C-003 |
| Codex | Přihlášení účtem ChatGPT (OAuth token v oblasti) | C-003 |
| OpenCode | OAuth přihlášení i API klíče | OAuth: C-003. API klíče drží brána a vkládá je; do oblasti se nedostanou. Podporovaní poskytovatelé s klíčem jsou ti, pro které existuje typovaná brána. |
| GitHub | Classic personal access token | Classic token nejde omezit na jedno repo, otevírá vše, k čemu má účet přístup. Proto ho drží brána v Klíčence hosta, vkládá ho jen do git smart HTTP a pustí jen fetch/push repa projektu (GW testy S5). Oblast ho nevidí. `gh` CLI a GitHub API s tokenem v oblasti by byly další změnou kontraktu. |
| Xcode | Jen Simulator, bez podpisu | Apple ID ani App Store Connect klíč do oblasti nepatří. Podpis pro zařízení je samostatné budoucí rozhodnutí. |
| Další | Zatím žádné | Neuvedené integrace (npm publish, cloud, databáze…) jsou nepodporované. |

**F0.8 — parametry měření (2026-11-07).** Přijatá verze: [LAB-v1 P1–P6](LAB.md#1-návrh-rozhodnutí-f08)
podle commitu `a1d64f5` s těmito změnami (LAB.md je už upravený):

| Návrh | Rozhodnutí |
|---|---|
| P1 | Přijato. Referenční stroj M1 / 16 GiB je k dispozici. |
| P2 | Přijato. |
| P3 | Přijato. |
| P4 | Změněno: holé tři relace p95 systémového přírůstku RAM **≤ 7,5 GiB** (místo 4,5 GiB). Podmínky zátěže (memory pressure, swap) beze změny. |
| P5 | Změněno: GPU medián poměrů vůči host referenci **≤ 2,0** a p95 **≤ 2,4** (místo 1,25 a 1,50). Podmínky prezentace beze změny. |
| P6 | Přijato. |
| Docker start/stop | Otevřené, rozhodnout nejpozději před S7 (F4). |

## Změny kontraktu

Každá změna požadavku nebo fallbacku musí mít záznam. Bez tvého výslovného rozhodnutí platí původní požadavek.

| ID | Datum | Původní požadavek | Změna | Dopad | Nová akceptace | Rozhodnutí |
|---|---|---|---|---|---|---|
| C-001 | 2026-11-03 | R6: jednotlivá okna v Docku, rozlišitelná oblast | První verze (MVP) zobrazí každou oblast jako jedno okno s její plochou; per-app Coherence přechází do F3 | MVP nesplňuje R6; R6 zůstává požadavkem produktu. S2 není podmínkou F2. | MVP: plocha oblasti v okně hosta, okno jednoznačně označené oblastí; schránka jen řízeným mostem. Produkt: S2 + F3 beze změny. | Uživatel, F0.2 |
| C-002 | 2026-11-03 | R4: Docker funguje bez únikové cesty | Docker až ve F4 | MVP nesplňuje R4; R4 zůstává požadavkem produktu. S7 není podmínkou F2. | Produkt: S7 + F4 beze změny. | Uživatel, F0.4 |
| C-003 | 2026-11-07 | PLAN §5: klíče jen v Klíčence hosta, vkládá je typovaná brána; brána odmítá cizí autorizační hlavičky (R3); neomezitelná integrace je nepodporovaná | Claude (předplatné), Codex (účet ChatGPT) a OAuth přihlášení v OpenCode drží OAuth token v oblasti. Brána pro jejich domény povolí TLS passthrough bez vkládání klíče. | Kompromitovaná oblast může token vynést nebo zneužít v rozsahu celého účtu (konverzace, kvóta, organizace). Bez TLS MITM brána nerozliší cizí token, takže přes povolené domény poskytovatele lze vynést data oblasti včetně projektu. R3 tím pro oblasti s touto integrací neplatí v plném rozsahu. Varianty s API klíčem se nemění. | Integrace je opt-in per oblast. Passthrough jen na uzavřený seznam domén dané integrace a jen v oblastech s opt-in. Ostatní testy R3 beze změny. Únik přes domény poskytovatele S5 změří a zapíše jako důsledek C-003, ne jako Prošlo R3. Vypnutí a smazání oblasti má zdokumentovanou revokaci tokenu. | Uživatel, F0.7 |
