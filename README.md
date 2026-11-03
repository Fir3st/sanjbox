# Ohrádka

Nativní izolované oblasti pro AI agenty na macOS, bez desktopové VM. Každá oblast je skrytý uživatel
macOS s vlastní neviditelnou GUI relací a vlastním APFS stavem. Okna jejích aplikací se zobrazují na ploše
hosta a síť jde jen přes řízenou bránu.

**Stav:** návrh k ověření. Žádná izolace zatím není prokázaná. Nic z tohoto repozitáře nepoužívej
se skutečnými projekty, účty nebo tajemstvími, dokud příslušné brány v COVERAGE.md neprojdou.

| Dokument | Obsah |
|---|---|
| [PLAN.md](PLAN.md) | Autoritativní kontrakt: požadavky R1–R8, threat model, architektura, brány S0–S8 |
| [docs/IMPLEMENTATION.md](docs/IMPLEMENTATION.md) | Fáze, pracovní balíky pro paralelní práci, laboratorní sloty |
| [docs/GUIDE.md](docs/GUIDE.md) | Pravidla práce, struktura repa, jak psát spiky a evidovat důkazy |
| [docs/COVERAGE.md](docs/COVERAGE.md) | Co je hotovo a co ne: požadavky, brány, testy, balíky, blokátory |
| [docs/DECISIONS.md](docs/DECISIONS.md) | Rozhodnutí F0 a změny kontraktu |
| [docs/spikes.md](docs/spikes.md) | Verdikty bran F1 |
