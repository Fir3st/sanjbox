# Připnuté primární podklady D5

Čteno 2026-11-04. [sources.json](sources.json) uvádí plné commit ID, cestu, veřejný URL,
čas stažení, velikost a SHA-256 přesných bytes. Zdrojové soubory nebyly spouštěny; lokální fixtures
jsou naše syntetická data, nikoli zachycená komunikace účtů. Hash pin je reprodukční evidence
rešerše, nikoli ověření živé integrace.

| Zdroj | Připnutí a relevantní fakt |
|---|---|
| [PyPA Simple repository API](https://github.com/pypa/packaging.python.org/blob/9d2c254c997d8355f4855fea715cca8000e64b30/source/specifications/simple-repository-api.rst) | `9d2c254…`: JSON 1.1 přidává volitelný per-file upload-time/size; UTC a max. 6 desetinných míst. Normativní 1.4 status je kořenový slovník; příklad ponechává starší meta tvar. |
| [PyPA wheel](https://github.com/pypa/packaging.python.org/blob/9d2c254c997d8355f4855fea715cca8000e64b30/source/specifications/binary-distribution-format.rst), [sdist](https://github.com/pypa/packaging.python.org/blob/9d2c254c997d8355f4855fea715cca8000e64b30/source/specifications/source-distribution-format.rst) | Jméno/verze v názvu archivu; D5 přijímá jen popsanou podmnožinu, ne celý PEP 440. |
| [Homebrew environment](https://github.com/Homebrew/brew/blob/8b0b7e44193854e22b84bcf2f58d65f21408d458/Library/Homebrew/env_config.rb#L61) | Stejný snapshot jako E1, `8b0b7e4…`: API a bottle domény mají fallback. Artifact no-fallback není úplná síťová politika. |
| [Homebrew Formula#bottle_hash](https://github.com/Homebrew/brew/blob/8b0b7e44193854e22b84bcf2f58d65f21408d458/Library/Homebrew/formula.rb#L3286) | V prohlédnuté serializaci bottle jsou URL/hash/cellar, chybí per-artifact publication-time. Netvrdíme tím neexistenci všech možných budoucích registry zdrojů času. |
| [Git smart HTTP](https://github.com/git/git/blob/94f057755b7941b321fd11fec1b2e3ca5313a4e0/Documentation/gitprotocol-http.adoc), [HTTP backend](https://github.com/git/git/blob/94f057755b7941b321fd11fec1b2e3ca5313a4e0/Documentation/git-http-backend.adoc) | Git v2.54.0, `94f0577…`: exact service discovery + POST upload/receive-pack; backend CGI a repo-local receivepack použité pouze ve fixture. |

Aktuální oficiální čitelné stránky konzultované spolu se zdroji:
[Simple API](https://packaging.python.org/en/latest/specifications/simple-repository-api/),
[Homebrew API](https://formulae.brew.sh/docs/api/),
[brew environment](https://docs.brew.sh/Manpage#environment),
[Git HTTP protocol](https://git-scm.com/docs/http-protocol/2.34.0).

**Fakt:** čas katalogu/commit formule není ve výše uvedeném schématu definovaný jako publikace
konkrétní bottle. **Odvození pro policy:** nelze jím automaticky povolit cooldown. **Mock:** test
se správným digestem a přidaným starým upload-time zůstává odmítnutý. **Neměřeno:** GHCR publish-time
jako nová autorita, JWS ověření, veřejný PyPI/GitHub a skutečné přihlašovací scopes.
