# Nezávislé review — host diagnostika M1

- Reviewer: GPT-6 Astra (`xhigh`), 2026-11-03; kontrola podkladů a zdrojů, bez spouštění sond či změn systému.
- Závěr: **diagnostická integrita doložena pro všechny 3 plánované pokusy; S1 zůstává Neověřeno.**
  Souhlasím s rozsahem a omezeními [verdiktu](../verdict.md); žádný případ GUI ani F0.8 tím neprošel.

Porovnala jsem soukromé originály se zveřejněnými kopiemi. [Předregistrace](../inputs.md) i její
[JSON](../inputs/preregistration.json) jsou bajtově zachované. U očekávání a kontextů se změnily pouze
hodnoty `userName` na `host-user`; v pokusech se navíc vynechal `uidProcesses.largest` a normalizoval
formát JSON. Všechny ostatní hodnoty jsou totožné. Časové obálky a prázdné stderr zůstaly bajtově
stejné; [credentials.log](../credentials.log) odpovídá kontextům všech tří pokusů. Ověřila jsem všechny
uvedené hashe originálů a publikovaných kopií v [publication.json](../raw/publication.json).

Všechny starty následovaly po předregistraci; žádný pokus nechybí ani nebyl nahrazen. Každý skončil
exit 0 s `valid=true`, bez neshod a chyb. Skutečné/efektivní UID/GID, členství v primární skupině,
seznam kernel groups, Aqua manager a host konzole souhlasí; audit i window audit session zůstaly
100002. Binárka a všech 15 evidovaných zdrojových souborů odpovídají hashům a zaznamenanému commitu.
Ověřen je také hash původního sběrného skriptu v [provenanci](../raw/collector-provenance.json).
Jeho 60s timeout byl pevný před během; dodatečná anotace správně nepřepisuje předregistraci.

Offscreen zátěž ve všech pokusech odpovídá 60 snímkům 2048×2048 a 512 iteracím na pixel; poslední
snímek má 0 neshod z 4096 ověřených pixelů. GPU mediány 10,481500 / 10,483625 / 10,483042 ms
a prezentace 96,6 / 99,0 / 99,8 fps jsou ve verdiktu správně. Údaje o displejích odpovídají raw:
prezentace proběhla v okně 960×600 pixelů, 1×, na hlavním externím 100Hz displeji. Viditelnost je
jen jednorázový vzorek; souhrny nedokládají maximální mezeru, input-to-photon ani přenos přes RFB.

`screenCapture.preflight=true` je již existující oprávnění; příkaz neobsahoval žádost o grant a sonda
nezachytávala obsah obrazovky. Součet footprintů 527–529 host procesů není RAM izolované oblasti
ani unikátní systémová RAM. Pozadí/cache nebyly řízené. Historický M5 Pro má jiný displej/konfiguraci
a chybí jeho původní protokol, proto z těchto souhrnů nelze odvodit rychlostní poměr M1/M5. WebGL,
tři izolované relace, jejich souběh, login a bezpečnostní hranice nebyly tímto během testovány.
