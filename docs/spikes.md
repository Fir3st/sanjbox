# Ohrádka — verdikty bran F1

Výstup F1 podle [PLAN.md §Výstup F1](../PLAN.md). Každá brána má jeden záznam, který odkazuje na protokoly
v `docs/evidence/`. Postup: [GUIDE.md §7](GUIDE.md#7-důkazy-a-verdikty). Souhrnný stav: [COVERAGE.md §2](COVERAGE.md#2-brány).

Verdikt: **Prošlo** · **Neprošlo** · **Nejasné** · **Neověřeno**. „Nevyřešeno“ není pass;
bezpečnostní fail se neopravuje přejmenováním na reziduum.

## Šablona záznamu

```markdown
## S<n> — <název>

- Verdikt: Neověřeno
- Datum a běh: YYYY-MM-DD, docs/evidence/S<n>/YYYY-MM-DD-<běh>/
- Prostředí: model Macu, RAM, macOS + build, displeje, commit
- Credentials sond: odkaz na credentials.log; soulad s očekáváním ano/ne
- Mapování na požadavky: R…
- Případy: tabulka ID → Prošlo/Neprošlo/Nejasné → odkaz na raw
- Měřeno / odvozeno / mock / hypotéza: rozlišit u každého závěru
- Blokátory v rozsahu brány: …
- Rezidua mimo threat model: …
- Review: kdo, datum, závěr
```

## S1 — Neviditelná relace

- Verdikt: Neověřeno

## S0 — Hranice a attack surface

- Verdikt: Neověřeno

## S8 — Signing, TCC a broker

- Verdikt: Neověřeno

## S4 — Zpevnění hosta

- Verdikt: Neověřeno

## S3 — pf podle uživatele

- Verdikt: Neověřeno

## S3b — Ingress a loopback

- Verdikt: Neověřeno

## S5 — Typované brány

- Verdikt: Neověřeno

## S6 — Homebrew per oblast

- Verdikt: Neověřeno

## S2 — Coherence

- Verdikt: Neověřeno

## S7 — Docker

- Verdikt: Neověřeno
