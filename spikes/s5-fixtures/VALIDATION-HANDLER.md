# D4 skutečný handler — validační dodatek 2026-11-06

Finální native **Release: 42/42 testů prošlo, 0 failures, 0 skipped, 0 compiler warnings**,
včetně čtyř opt-in npm testů. Původních 33 testů zůstalo, přibylo devět integračních/regresních
metod. Výchozí běh bez npm selektorů: **38 passed + 4 výslovně skipped**, 0 failures.

Výsledek scénářů je samostatné počítadlo: **40 spuštěno, 28 matched, 12 incomplete,
0 mismatched**. Incomplete znamená, že skutečný D2 handler vrací generickou 403 bez
rozlišení důvodu. Ve všech 12 případech byl status 403, přesné chybové tělo, žádné artefaktové
bytes ani download audit. Konkrétní příčina cooldown/unknown-date nebyla měřením zjištěna.
Z 28 matched je 12 skutečných vydání přes handler a 16 lokálních instalací mimo síťovou
kontrolu (client cache/import). Celá matice není prohlášena za plně doloženou.

Popis seamů, cest, cache seed, negativních kontrol a limitů:
[HANDLER-INTEGRATION.md](HANDLER-INTEGRATION.md).

## Nový neměnný receipt

[validation/handler/20261106T070643Z](validation/handler/20261106T070643Z/):

- [environment.txt](validation/handler/20261106T070643Z/environment.txt): macOS 27.2 (26B123),
  arm64, Xcode 27.2 (27B52), Swift 6.4.2, existující Node v26.13.0 / npm 11.20.0;
- [commands.txt](validation/handler/20261106T070643Z/commands.txt): přesné izolované Release příkazy;
- [native-release.log](validation/handler/20261106T070643Z/native-release.log): výchozí běh;
- [npm-release.log](validation/handler/20261106T070643Z/npm-release.log): první plná opt-in sada;
- [final-release.log](validation/handler/20261106T070643Z/final-release.log): finální sada po
  doplnění regrese chybného explicitního důvodu odmítnutí;
- [scenarios.txt](validation/handler/20261106T070643Z/scenarios.txt): všech 40 skutečných výsledků;
- [tested-source.sha256](validation/handler/20261106T070643Z/tested-source.sha256): přesný finální
  Swift source snapshot, včetně nezměněného gateway dependency; base commit je
  `2a15fc2608a04b3cf06ba676810ffe69edae3982`, samostatný claim `b53be62`;
- [cleanup.txt](validation/handler/20261106T070643Z/cleanup.txt): odstranění přesných vlastních
  build/cache/module adresářů a kontrola nepřítomnosti, cleanup npm UUID adresářů testy;
- [manifest.sha256](validation/handler/20261106T070643Z/manifest.sha256): integrita těchto receipts.

42 XCTest metod nelze zaměňovat se závěrečným Swift Testing hlášením „0 tests“: tento balík
používá XCTest a jeho skutečné výsledky jsou v předchozí části logu. Debug zde nebyl znovu
měřen. Výchozí a první opt-in log předcházejí poslední regresní assertion; finální log
odpovídá publikovaným source hashům.

Původní [ověření 2026-11-03](README.md#závěrečné-ověření-2026-11-03) zůstává zachované.
Jde o lokální syntetické testy a npm kompatibilitu, ne laboratorní důkaz izolace. Bez živého
upstreamu, F0.7 identity, D3 adaptéru, nové redirect integrace, S5/D7/L5 či výkonového verdiktu.
