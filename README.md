# Sanďbox

Nativní izolované oblasti pro AI agenty na macOS, bez desktopové VM. Každá oblast je skrytý uživatel
macOS s vlastní neviditelnou GUI relací a vlastním APFS stavem. Okna jejích aplikací se zobrazují na ploše
hosta a síť jde jen přes řízenou bránu.

**Stav:** návrh k ověření. Žádná izolace zatím není prokázaná. Nic z tohoto repozitáře nepoužívej
se skutečnými projekty, účty nebo tajemstvími, dokud příslušné brány v COVERAGE.md neprojdou.

**[Status](https://fir3st.github.io/sanjbox/)**: stav ověřovacích bran, fáze a poslední změny,
generované automaticky z [COVERAGE.md](docs/COVERAGE.md) ([jak](docs/PROGRESS.md)).

**Další práce:** [IMPLEMENTATION §0](docs/IMPLEMENTATION.md#0-co-dál) uvádí aktuální priority,
podmínky dokončení, závislosti a čekání na uživatele. Před převzetím ověř vlastníka v COVERAGE
a postup v [GUIDE §5](docs/GUIDE.md#5-paralelní-práce).

[H3 CLI](proto/cli/README.md) je hotový offline prototyp pěti příkazů přes lokální NSXPC k mock
helperu. Nespouští workload ani skutečné oblasti; [validace](proto/cli/VALIDATION.md) není důkaz izolace.
[H4 brána](proto/gateway/H1-ADAPTER.md) je hotový offline prototyp: H1 politika řídí npm/PyPI/git/model
přes veřejné knihovní API a loopback listener, s explicitními doplňky a pouze mock klíči. Samostatné
CLI nadále přijímá draft; autentizace klienta a produkční integrace čekají na WP2.5/lab.
[H6 harness](proto/escape/README.md) má dokončený offline katalog všech 155 případů a osm syntetických
sond s lokální protistranou; [validace](proto/escape/VALIDATION.md) ponechává všechny akceptace
neověřené. [A3 RFB prototyp](spikes/s1-rfb/README.md) z [#78](https://github.com/Fir3st/sanjbox/pull/78)
je sloučený jako `8faf648`: přidává S5 record kodeky a odmítnutí před výběrem relace; DH provider,
reviewovaná virtuální autorizace a integrovaný výběr chybí, takže A3 zůstává rozpracované.
[A6 #77](spikes/s8-signing/A6-H1-FOLLOWUP.md) dodává fuzzer skutečných H1 helper/reply/broker wire
kontraktů a syntetické autorizační/restart workflow. A6 zůstává rozpracované: chybí kalibrovaná
SG-06 pozitivní attach kontrola, nativní daemon autorizace a registration ownership/cleanup přes
restart; skutečné Personal Team/podmíněné self-signed podpisy, XPC/Mach/TCC a L2 nejsou ověřené.
Zbývající A2/A3/A6 mají dosavadní vlastníky a konkrétní kroky i podmínky v IMPLEMENTATION.
F1 má 22 hotových, 5 rozpracovaných a 9 nezahájených balíků; všech 10 bran a 155 akceptací zůstává
Neověřeno. Vstup F2 nadále čeká na laboratorní brány.

| Dokument | Obsah |
|---|---|
| [PLAN.md](PLAN.md) | Autoritativní kontrakt: požadavky R1–R8, threat model, architektura, brány S0–S8 |
| [docs/IMPLEMENTATION.md](docs/IMPLEMENTATION.md) | Fáze, pracovní balíky pro paralelní práci, laboratorní sloty |
| [docs/GUIDE.md](docs/GUIDE.md) | Pravidla práce, struktura repa, jak psát spiky a evidovat důkazy |
| [docs/COVERAGE.md](docs/COVERAGE.md) | Co je hotovo a co ne: požadavky, brány, testy, balíky, blokátory |
| [docs/DECISIONS.md](docs/DECISIONS.md) | Rozhodnutí F0 a změny kontraktu |
| [docs/LAB.md](docs/LAB.md) | Registr strojů, rezervace slotů, přijatá metodika LAB-v1 a šablony běhů (F0.8; Docker start/stop zbývá před S7) |
| [docs/spikes.md](docs/spikes.md) | Verdikty bran F1 |
| [docs/PROGRESS.md](docs/PROGRESS.md) | Web se stavem vývoje, historie, pravidla počítání a nasazení na Pages |
| [docs/CI.md](docs/CI.md) | Automatické testy v GitHub Actions a povinné kontroly před sloučením PR |

## Zákaz atribuce v commitech

V commitech jsou zakázané řádky `Co-Authored-By`, „Generated with Claude Code“ a odkazy `claude.com/claude-code`. Platí tři vrstvy:

1. `.claude/settings.json`: `attribution.commit` a `attribution.pr` jsou prázdné, takže Claude Code nepřidává vlastní patičku.
2. `.claude/hooks/block-attribution.sh`: hook PreToolUse (matcher Bash), který zamítne `git commit` (i `git -C x commit`), jehož text obsahuje zakázaný řádek. Commit se vůbec nespustí.
3. `.githooks/commit-msg`: hook gitu, který zprávu odmítne (exit 1). Platí pro jakýkoli nástroj nebo agenta.

Claude hook vidí jen text příkazu, takže nezachytí zprávu načtenou ze souboru (`git commit -F soubor`). Tuto mezeru kryje vrstva 3.

Instalace (jednou po klonování; `core.hooksPath` se v gitu nepřenáší samo):

```bash
git config core.hooksPath .githooks
```

Vrstvy 1 a 2 se načtou samy s `.claude/settings.json`. Hooky vyžadují jen bash a grep.
