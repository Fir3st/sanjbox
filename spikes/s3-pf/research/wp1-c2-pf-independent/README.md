# WP1.C2 — ochrana sítě nezávislá na pf

**Výsledek rešerše k 2026-11-03:** v prozkoumaných veřejných rozhraních a zdrojích nebyla doložena
konstrukce, která současně splní celý kontrakt Sanďboxu na obecném Apple Silicon Macu s macOS 27.x,
bez Network Extension a bez oprávnění vyloučených F0.5. **Blokátor R3 zůstává otevřený.**
To není důkaz neexistence všech možných konstrukcí ani empirický verdikt brány.

App Sandbox je skutečný kandidát ochrany nezávislé na pf pro procesy, které v něm běží. Chybí však
úplný návrh pokrývající všechny starty oblasti, běžné systémové služby, existující přenosy a požadované
nativní aplikace. Custom Seatbelt profil tuto mezeru zatím nedokládá; `sandbox-exec` je deprecated
a veřejný `sandbox_init` je označen jako nepodporovaný. Samotný druhý pf anchor, proxy či hlídač
požadovanou nezávislou hranici nezajišťují. Podklady a kvalifikace jsou v [rešerši](RESEARCH.md).

| Vrstva | Stav tohoto výstupu |
|---|---|
| WP1.C2 | Rešerše, technický návrh k dalšímu ověření a plán falsifikace dokončeny |
| S3, S3b, R3, NET | Beze změny, **Neověřeno** |
| Výpadek pf; resolver/mDNS/ICMP; ingress | Otevřené blokátory, tento balík je neuzavírá |
| Podporované buildy produktu | Žádný build tímto dokumentem nekvalifikován |
| Provedené experimenty s enforcementem | Žádné |

## Obsah a mapování

- [RESEARCH.md](RESEARCH.md): kontrakt, porovnání mechanismů, lifecycle a otevřený blokátor.
- [SOURCES.md](SOURCES.md): primární zdroje, konkrétní revize, sekce a omezení platnosti.
- [L4-PLAN.md](L4-PLAN.md): návrh uživatelských falsifikačních experimentů, oracle a podmínky úklidu.
- [static-inspection.json](static-inspection.json): datum, oznámená platforma a hashe přesně čtených
  systémových hlaviček/manuálů a Apple OSS souborů. Jde o statickou inspekci, ne protokol brány.

Hlavní mapování: R3 / S3 / NET-16…27. Vazby: R2 / S0 / lifecycle celého UID, R2–R3 / S3b /
NET-10…12, R1/R8 / kompatibilita nativních nástrojů. Kontrakt:
[PLAN](../../../../PLAN.md), [F0.5](../../../../docs/DECISIONS.md),
[WP1.C2](../../../../docs/IMPLEMENTATION.md), [coverage](../../../../docs/COVERAGE.md).

## Reprodukce a bezpečný rozsah

**[implementátor]** Čtení veřejných Apple dokumentů/OSS a pevných cest systémových man/SDK souborů;
kontrola relativních odkazů, hashů a diffu. Nejsou potřeba balíčky ani privilegované příkazy.
Nevznikl síťový filtr, systémový uživatel, sandboxovaný workload ani změna nastavení sítě.
Stažení veřejného zdrojového textu není měření síťové izolace. Surové zdroje jsou mimo repozitář;
pro audit jsou připnuté URL/revize/hash, nikoli kopie velkých Apple souborů.

**[uživatel]** Případné budoucí měření výhradně v L4, po jeho předpokladech a review konkrétního
harnessu s dry-runem, záznamem původního stavu a idempotentním úklidem. Tento balík neposkytuje
spustitelný skript měnící pf. Oracle musí zahrnout nezávislou protistranu a pozitivní kontrolu,
nikoli jen `EPERM`, log sandboxu či nepřítomnost procesu. Postup a očekávané výsledky: [L4-PLAN](L4-PLAN.md).

Úklid tohoto balíku nevyžaduje systémový zásah. Žádný LAB slot nebyl spuštěn; výstup nezávisí na
přijetí jiného PR ani budoucí metodiky WP0.5.
