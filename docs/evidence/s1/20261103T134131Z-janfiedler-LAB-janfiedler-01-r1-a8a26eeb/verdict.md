# M1 host diagnostika — výsledek

**Diagnostická integrita: v pořádku ve všech 3 předem plánovaných pokusech. Brána S1: Neověřeno.**

Nejde o akceptační běh LAB-v1 ani o rozhodnutí F0.8/P1–P6. Žádný případ GUI-01…13 se tím neoznačuje Prošlo.

| Pokus | GPU medián ms | GPU p95 ms | Neshody / ověřené pixely | Prezentováno / odesláno | Prezentace fps | Interval p95 ms | Drawable timeouty | Podklad |
|---|---|---|---|---|---|---|---|---|
| 1 | 10.481500 | 10.535375 | 0/4096 | 483/489 | 96.6 | 10.001875 | 0 | [JSON](raw/attempt-01.json), [čas/exit](raw/attempt-01.envelope.json) |
| 2 | 10.483625 | 11.125958 | 0/4096 | 495/498 | 99.0 | 10.001875 | 0 | [JSON](raw/attempt-02.json), [čas/exit](raw/attempt-02.envelope.json) |
| 3 | 10.483042 | 11.100250 | 0/4096 | 499/502 | 99.8 | 10.001875 | 0 | [JSON](raw/attempt-03.json), [čas/exit](raw/attempt-03.envelope.json) |

- **Měřeno:** každý pokus exit 0, `valid=true`, prázdné `mismatches` i `errors`, stderr prázdné. Shodná předem určená identita, skupiny, Aqua a audit/window audit session; žádný vyřazený nebo náhradní pokus. Viz [credentials.log](credentials.log).
- **Měřeno:** každá offscreen úloha provedla 60 snímků 2048×2048, 512 iterací/pixel; ověřeno 4096 pixelů posledního snímku proti CPU referenci, neshody 0. GPU mediány 10,481500 / 10,483625 / 10,483042 ms. Nejde o p95 z nezávislých běhů: každý p95 v tabulce je statistikou 60 snímků příslušného pokusu.
- **Měřeno:** syntetické okno bylo v jednorázovém vzorku viditelné; pětisekundové souhrny reportují 483/495/499 prezentací na 100Hz hlavním monitoru. Individuální frame timestampy ani nejdelší mezera nejsou ve výstupu sondy dostupné. Nejde o input-to-photon nebo měření RFB.
- **Odvozeno:** na tomto M1 lze v host GUI relaci provést ověřovaný Metal výpočet a prezentovat syntetické okno. Není tím doložena kapacita, izolace ani akcelerace tří dalších relací.
- **Omezení:** background/cache nebyly řízené. Snapshot footprintu zahrnuje 527–529 procesů host UID; jejich součet není RAM oblasti ani unikátní systémová RAM. P5/RAM/login/performance brány se nevyhodnocují.
- **Omezení:** s M5 Pro nelze z rozdílných souhrnů a monitorů odvodit rychlostní poměr ani splnění stejné akceptace. Jeho původní hodnoty zůstávají zachované. WebGL se zde neměřilo.
- **Provenance:** předregistrace vznikla před prvním pokusem a zůstala beze změny. [Provozní anotace](raw/collector-provenance.json) zaznamenává 60s timeout již existujícího sběrače; nebyl výkonnostním prahem ani nově zpětně přidanou akceptací. Ani jeden pokus timeout neměl. Sanitizace je popsaná samostatně.
- **Review:** Astra (`xhigh`), 2026-11-03; nezávisle ověřila všechny 3 původní výstupy, identitu/session/skupiny, hashe i návaznost na předregistraci. Následuje samostatný [review záznam](reviews/astra-review.md).
- **Úklid:** procesy sond po 3 pokusech ukončeny exit 0; žádné účty, služby, pf ani TCC změny k obnově nevznikly. Build/protokoly zůstávají soubory pracovního prostoru, soukromé originály jsou mimo Git.
