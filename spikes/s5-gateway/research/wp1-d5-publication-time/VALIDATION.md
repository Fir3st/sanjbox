# WP1.D5 — ověření zdrojové rešerše

2026-11-08; základ repozitáře `7b20c41496f9a8d2a8e49604e31c7598a4943adb`, claim/parent
`af89f119b40028a9cc20a5ff49e304e4969ce776`. Ověřen pracovní výstup v tomto adresáři před commitem;
identifikátorem výstupu je commit, který tyto soubory přidává. Bez buildů a runtime testů.

- **Prošlo:** 12 stažených primárních zdrojů odpovídá velikostí/SHA-256 mapě `sources.json`;
  upstream kód byl pouze čten, celý se do repozitáře nekopíruje. OCI specifikace mají version/hash pin;
  ostatní kód commit pin, živá REST dokumentace API version + hash + čas čtení. Dvě informativní webové
  stránky jsou výslovně oddělené od těchto byte pinů.
- **Prošlo:** 3 uložené metadata objekty (18 880 bytes), SHA-256/size a obě descriptor hrany;
  přesný platformní ref, platform/config, jediná layer a anotace digest/size odpovídají E1 bottle.
  E1 version 2.12.3 / revision 0 / rebuild 1 i `ruby_source_checksum` souhlasí s připnutou formulí.
  Hash bottle payloadu se nestahoval a není přeměřen.
- **Prošlo:** index/manifest mají odlišné `created`; config ho nemá; komprimovaná bottle není
  `rootfs.diff_ids`; source-revision formule z anotace neobsahuje vybraný bottle digest.
- **Mez výsledku:** Packages REST 500/504, historie formule 504 a package UI timeout nejsou
  důkaz autentizačního požadavku ani neexistence času. Žádný registry publication timestamp
  pro tento vzorek nebyl získán; sémantika republish/restore/visibility zůstává nedoložená.
- **Rozsah:** nový `research/wp1-d5-publication-time/` a řádek D5 v `docs/COVERAGE.md`;
  lokální odkazy a `git diff --check` ověřeny. Předchozí D5/E1 evidence a gateway kód/testy zůstaly
  byte-exact.

## Review 2026-11-13

Ověřeno nad PR head `b705cfcf3cc3de5f7a2fcd95c13bc2bedce8a992` a review `b927a30`
po lokálním sloučení `main` `f301bf398720d8cae78e6e124d4b2a7225aec0e2` (včetně PR #59);
následující zjištění se vztahují k obsahu integračního commitu, který je zapisuje.

- Přímý anonymní HTTPS GET všech 12 URL ze `sources.json`: 11 zdrojů kódu/specifikací znovu
  souhlasí velikostí i SHA-256. Živá REST dokumentace má nyní **842 791 bytes**, SHA-256
  `109e69a3ad69430fa8c012a700786ad8c4e131641b2709fc21b1ac467ed34c73`, tedy **nesouhlasí**
  s historickým HTML pinem; původní bytes nebyly uloženy, takže jejich shodu nelze tímto opakovaným
  čtením doložit. Aktuální sekce list/detail/restore nadále podporují popsané schéma/scopes a
  omezení obnovy, nikoli publikační sémantiku `created_at` pro vybranou bottle; původní záznam
  v `sources.json` se nepřepisuje.
- Všechny tři GHCR objekty byly znovu načteny přes **digest**, pouze s anonymním public-pull bearerem
  v paměti: 15 260 + 3 400 + 220 bytes přesně odpovídají uloženému indexu/manifestu/configu.
  Níže uvedená offline kontrola ověřila obě descriptor hrany, platform/ref, jedinou layer,
  digest/size anotace a vazbu E1 version/revision/rebuild/tap/formula checksum; připnuté formule
  byly navíc přečteny jako text a jejich hash/digest ověřen proti E1. Bez bottle payloadu,
  vyhodnocení Ruby, účtů či osobních credentials; tag nebyl při review znovu mapován.
- Offline kontrola níže prošla na Pythonu 3.9.6 i 3.11.4; `tools/tests` **63/63**,
  všech 12 lokálních Markdown cílů/kotev, E1 cooldown report (398× unknown-time refusal) a
  `git diff --check` prošly. Coverage ponechává B2 ✅ a F1 **17/7/12** (hotovo/rozpracováno/nezahájeno).
  Nové Packages REST/UI dotazy pro `hello`
  ani historii formule se neopakovaly; původní chyby z 2026-11-08 zůstávají jen historickým
  pozorováním. Rešerše neprokazuje registry publication time, nemění runtime a ponechává
  D5 🟨 i S5/S6/HB-04 Neověřeno.

Opakovatelná kontrola uloženého řetězce ze začátku repozitáře (stdlib, bez sítě):

```sh
python3 - <<'PY'
import gzip, hashlib, json, pathlib
p = pathlib.Path('spikes/s5-gateway/research/wp1-d5-publication-time')
sha = lambda b: hashlib.sha256(b).hexdigest()
records = [r for r in json.loads((p/'requests.json').read_text())['requests'] if 'stored_path' in r]
assert {r['id'] for r in records} == {'hello-index', 'hello-manifest', 'hello-config'} and len(records) == 3
for r in records:
    b = (p/r['stored_path']).read_bytes()
    assert len(b) == r['bytes'] and sha(b) == r['sha256']
    route = 'blobs' if r['id'] == 'hello-config' else 'manifests'
    assert r['url'] == 'https://ghcr.io/v2/homebrew/core/hello/' + route + '/sha256:' + sha(b)
assert sum(r['bytes'] for r in records) == 18880
i, m, c = [json.loads((p/'metadata'/f'hello-{n}.json').read_text()) for n in ('index', 'manifest', 'config')]
assert i['schemaVersion'] == m['schemaVersion'] == 2 and len(i['manifests']) == 6
ref = '2.12.3.arm64_golden_gate.1'
key = 'org.opencontainers.image.'
d = [x for x in i['manifests'] if x['annotations'][key+'ref.name'] == ref]
assert len(d) == 1
for desc, name in ((d[0], 'manifest'), (m['config'], 'config')):
    b = (p/'metadata'/f'hello-{name}.json').read_bytes()
    assert desc['size'] == len(b) and desc['digest'] == 'sha256:' + sha(b)
    assert desc['mediaType'] == f'application/vnd.oci.image.{name}.v1+json'
platform = {'architecture': 'arm64', 'os': 'darwin', 'os.version': 'macOS 27'}
assert d[0]['platform'] == platform and all(c[k] == v for k, v in platform.items())
assert m['annotations'][key+'ref.name'] == ref and len(m['layers']) == 1
layer = m['layers'][0]
assert layer['mediaType'] == 'application/vnd.oci.image.layer.v1.tar+gzip' and layer['size'] == 54641
for annotations in (d[0]['annotations'], m['annotations']):
    assert layer['digest'] == 'sha256:' + annotations['sh.brew.bottle.digest']
    assert layer['size'] == int(annotations['sh.brew.bottle.size'])
e = pathlib.Path('spikes/s6-brew/data')
for name, digest in json.loads((e/'snapshot-lock.json').read_text())['files'].items():
    assert sha((e/name).read_bytes()) == digest
hello = next(f for f in json.loads(gzip.decompress((e/'formulae-selected.json.gz').read_bytes())) if f['name'] == 'hello')
assert hello['tap'] == 'homebrew/core' and hello['versions']['stable'] == '2.12.3' and hello['revision'] == 0
assert hello['bottle']['stable']['rebuild'] == 1
bottle = hello['bottle']['stable']['files']['arm64_golden_gate']
assert layer['digest'] == 'sha256:' + bottle['sha256']
assert bottle['url'] == 'https://ghcr.io/v2/homebrew/core/hello/blobs/' + layer['digest']
sources = {s['id']: s for s in json.loads((p/'sources.json').read_text())['sources']}
assert hello['tap_git_head'] == sources['core-hello']['commit']
assert hello['ruby_source_path'] == sources['core-hello']['path']
assert hello['ruby_source_checksum']['sha256'] == sources['core-hello']['sha256']
assert m['annotations'][key+'revision'] == sources['hello-build-formula']['commit']
assert c['rootfs']['type'] == 'layers' and len(c['rootfs']['diff_ids']) == 1
assert c['rootfs']['diff_ids'][0] != layer['digest'] and 'created' not in c and 'history' not in c
assert i['annotations'][key+'created'] == '2026-09-02T12:52:55Z'
assert m['annotations'][key+'created'] == '2026-09-12T07:07:25Z'
print('PASS: stored metadata chain and E1 binding; no payload or publication-time assertion')
PY
```
