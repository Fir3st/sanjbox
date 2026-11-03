# Šablona — stroj a laboratorní slot

Šablona není rezervace ani důkaz. Zkopírovat potřebné části do [LAB.md](../../LAB.md) a soukromého
provozního protokolu; nepublikovat hostname, sériová čísla, privátní cesty, účty nebo obsah zálohy.
Pravidla: [LAB §2](../../LAB.md#2-registr-strojů-a-rezervace).

## Stroj

| Pole | Hodnota |
|---|---|
| ID / revize / předchozí revize | `LAB-<alias>-…` / r… / … |
| Veřejný vlastník / datum ověření | … |
| Model identifier / čip / CPU / GPU | … |
| RAM v bajtech / GiB | … |
| macOS verze + build / Xcode + build / Swift | … |
| Host a virtuální displeje: body, pixely, škála, Hz | … |
| Napájení / režim výkonu / volné místo | … |
| Reference/minimum / odkaz na rozhodnutí F0.8 | … |
| Metoda sběru metadat / neověřená pole | … |
| Stav: nepřipraveno / připraveno / blokováno | … |

## Rezervace a readiness

| Pole | Hodnota |
|---|---|
| Rezervace / slot L… / run ID | … |
| Stroj a revize / commit kódu a LAB | … |
| Od–do včetně zóny / rozsah změn | … |
| Operátor / reviewer / potvrzení vlastníka stroje | … |
| Předchozí slot uzavřen (odkaz na úklid) | … |
| Závislé brány pro tuto konfiguraci | … |
| F0.8 schválení / předregistrace (hash/commit) | … |
| Záloha: dokončena kdy / stáří / soukromá reference | … |
| Ověření obnovy syntetického souboru / datum | … |
| Potřebné a volné místo včetně rezervy | … |
| Dry-run: příkaz, commit, výstup a kontrola uživatelem | … |
| Původní stav / manifest vlastních objektů a změn | … |
| Záložní lokální přístup / abort a recovery postup | … |
| Úklidový příkaz / způsob ověření / plán při konfliktu | … |
| Povolené granty a konkrétní download/install příkazy | … |
| Stav / časy změn stavu / důvod případné blokace | … |

## Uzavření slotu

- Skutečný začátek/konec měření a úklidu: …
- Srovnání s původním stavem a vlastními změnami: …
- Testovací procesy/účty/objekty/listenery odstraněny nebo explicitní schválené předání: …
- Skupiny, služby, pf, oprávnění a granty: co bylo obnoveno, co zůstává a proč: …
- Konflikty s pozdější změnou uživatele / vlastník nápravy: …
- Důkaz kontroly uživatelem + reviewer / uvolnění zámku stroje: …
- Odkaz na verdict běhu (úklid není pass brány): …
