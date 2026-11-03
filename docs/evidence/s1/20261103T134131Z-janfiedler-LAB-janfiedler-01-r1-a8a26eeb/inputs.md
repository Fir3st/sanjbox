# M1 host diagnostika — předregistrace

- Run ID: `20261103T134131Z-janfiedler-LAB-janfiedler-01-r1-a8a26eeb`
- Čas zafixování: 2026-11-03T13:41:32.164211+00:00
- Commit: `9462158e1072eaf36d6dc8662ed33d0b3a3bdcf6`
- Účel: dílčí diagnostika stejné hostitelské Metal sondy jako historický souhrn M5 Pro; žádné ověření izolovaných relací ani brány S1.
- Pevný plán: 3 po sobě jdoucí pokusy, každý `measure --expect expect-host.json --render-seconds 5`; bez vyřazeného warmupu a bez dodatečných pokusů podle výsledků.
- Zátěž: existující sonda, 2048×2048, 512 iterací/pixel, 60 offscreen snímků, 4096 ověřených pixelů posledního snímku; prezentace 960×600 bodů po 5 s.
- Kontext: real/effective UID/GID, primární skupina, Aqua manager a windowSessionUID hosta, onConsole=true; audit session musí zůstat rovna předběžnému kontextu.
- Diagnostická integrita: valid=true, mismatches=[], errors={}, kladné konečné GPU časy, odpovídající rozměry/počty a 0 neshod pixelů. Všechny hodnoty prezentace se zveřejní, P5 limity se neuplatní.
- Neshoda identity/session zneplatní pokus; chyba nebo neschopnost renderovat zůstává výsledkem. Při změně session se další měření zastaví a žádný pokus se nenahradí.
- Zachovat samostatné stdout/stderr, exit code, UTC a monotónní začátek/konec každého pokusu.
- Běžný pracovní host není vyhrazená laboratoř; pozadí ani cache nejsou řízené. Žádné porovnání výkonu s M5 bez jeho raw a stejné konfigurace.
- Bez --request-screen-capture, bez sítě, bez změn účtů, pf, služeb či TCC. Sonda otevírá vlastní syntetické okno. WebGL není součást této sondy ani této série.
- Publikace: uživatelské jméno v očekávání/kontextu nahradit konzistentním aliasem `host-user`, vynechat diagnostický seznam největších host procesů; původní data zůstávají soukromá.
