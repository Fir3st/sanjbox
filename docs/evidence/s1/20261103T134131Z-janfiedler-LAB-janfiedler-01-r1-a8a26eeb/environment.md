# M1 host diagnostika — prostředí

- Run ID: `20261103T134131Z-janfiedler-LAB-janfiedler-01-r1-a8a26eeb`; vlastník/operátor: veřejný alias `janfiedler`, sběr řídil Codex; reviewer: Astra (`xhigh`).
- Stroj: `LAB-janfiedler-01 / r1`, MacBookPro17,1, Apple M1, CPU 8/8, RAM 17179869184 B = 16 GiB.
- macOS 27.2 (26B123), Xcode 27.0 (27A266a), Swift 6.4 (`swiftlang-6.4.0.34.1`), arm64. Cílená metadata a zdrojové hashe: [předregistrace](inputs/preregistration.json).
- Commit sondy a metodiky: `9462158e1072eaf36d6dc8662ed33d0b3a3bdcf6`. Vlastní release sestavení `sanjbox-s1-probe`, pouze lokální balík common, bez externích závislostí; SHA-256 binárky `df8f94244b21fa54374d1fb967a1ba137cedfb0f5f32d40dd26c8d9458366674`.
- Hlavní aktivní externí displej: 3440×1440 bodů/pixelů, škála 1×, 100 Hz. Druhý aktivní interní: 1680×1050 bodů, 3360×2100 pixelů, 2×, 60 Hz. Okno sondy: 960×600 pixelů, 1×, reportované maximum 100 fps. Pozorováno shodně ve všech pokusech, monitory se nepřenastavovaly.
- Napájení podle `pmset`: AC Power. Výkonový režim, thermal/memory pressure, swap a volné místo nebyly měřeny.
- Běžný pracovní host, souběžný Codex/terminál; úplná inventura pozadí ani řízení cache/zátěže nebyly provedeny. Výsledky jsou orientační host diagnostika.
- Jedna existující host GUI relace: Aqua, `onConsole=true`, UID/GID 501/20; audit i window audit session 100002 před i během všech pokusů. Konzistentní anonymní role uživatele: `host-user`.
- Bez laboratorního systémového zásahu a bez slotu L1: žádní testovací uživatelé, změna pf/služeb, přihlášení ani granty. Spuštěny pouze `context` a tři `measure --expect … --render-seconds 5`, vlastní syntetická okna po měření skončila. Žádný `--request-screen-capture`; `preflight=true` je již existující stav, obsah obrazovky se nezachytával.
- Publikované JSON jsou sanitizované kopie, nikoli bajtově původní stdout: viz [publication.json](raw/publication.json). Jména nahrazena aliasem a vynechán seznam největších host procesů; číselná měření beze změny. Původní výstupy zůstávají soukromé, jejich hashe jsou uvedené.
- M5 Pro souhrn v README A1 zůstává samostatný historický údaj jiné konfigurace. Tento běh neměří WebGL ani tři izolované relace.
