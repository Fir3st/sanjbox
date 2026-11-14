# WP1.A6 — vymezené pokračování 2026-11-14

Základ `main` `75f3b5da13dfd7fca3acd376e06f1cd4d0fe2786`, větev
`codex/wp1-a6-h1-fuzzer`. Původní vlastníci a autoři **janfiedler / Codex + Astra**
zůstávají zachovaní; navazující implementace Astra má výslovné uživatelské předání.

Konkrétní mezera: současný fuzzer testuje vlastní mock DTO, ačkoli H1 již poskytuje
helper/reply/broker v1. Tento follow-up skončí napojením na skutečné veřejné wire API,
deterministickým bounded corpus s pozitivními i negativními controls, cílenými Debug/Release
testy a zdokumentovanou hranicí syntetické autorizace/registration recovery.

Dále připraví host-only autorizační seam a dry-run/user workflow pro vlastnictví registrace
přes restart, pokud lze bezpečně využít stávající kontrakty. SG-06 runner se doplní jen při
prokazatelně srovnatelné pozitivní i negativní kontrole bez `get-task-allow`; jinak se přesný
blokátor zaznamená. Žádná skutečná registrace, restart, účet, signing identity, TCC, systémová
změna ani externí síťový experiment nejsou součástí implementace. Git publikace je autorizovaná.

**A6 zůstává částečné. S8/SG-01…11 a Personal Team zůstávají Neověřeno.**
