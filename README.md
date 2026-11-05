# Sanďbox

Nativní izolované oblasti pro AI agenty na macOS, bez desktopové VM. Každá oblast je skrytý uživatel
macOS s vlastní neviditelnou GUI relací a vlastním APFS stavem. Okna jejích aplikací se zobrazují na ploše
hosta a síť jde jen přes řízenou bránu.

**Stav:** návrh k ověření. Žádná izolace zatím není prokázaná. Nic z tohoto repozitáře nepoužívej
se skutečnými projekty, účty nebo tajemstvími, dokud příslušné brány v COVERAGE.md neprojdou.

**[Status](https://fir3st.github.io/sanjbox/)**: stav ověřovacích bran, fáze a poslední změny,
generované automaticky z [COVERAGE.md](docs/COVERAGE.md) ([jak](docs/PROGRESS.md)).

| Dokument | Obsah |
|---|---|
| [PLAN.md](PLAN.md) | Autoritativní kontrakt: požadavky R1–R8, threat model, architektura, brány S0–S8 |
| [docs/IMPLEMENTATION.md](docs/IMPLEMENTATION.md) | Fáze, pracovní balíky pro paralelní práci, laboratorní sloty |
| [docs/GUIDE.md](docs/GUIDE.md) | Pravidla práce, struktura repa, jak psát spiky a evidovat důkazy |
| [docs/COVERAGE.md](docs/COVERAGE.md) | Co je hotovo a co ne: požadavky, brány, testy, balíky, blokátory |
| [docs/DECISIONS.md](docs/DECISIONS.md) | Rozhodnutí F0 a změny kontraktu |
| [docs/LAB.md](docs/LAB.md) | Registr strojů, rezervace slotů, návrh metodiky a šablony běhů (F0.8 otevřené) |
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
