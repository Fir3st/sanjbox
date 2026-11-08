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
- **Rozsah:** pouze nový `research/wp1-d5-publication-time/`; lokální odkazy a `git diff --check`
  ověřeny. Předchozí D5/E1 evidence, gateway kód/testy a společné dokumenty zůstaly byte-exact.

Opakovatelná kontrola uloženého řetězce ze začátku repozitáře (stdlib, bez sítě):

```sh
python3 - <<'PY'
import hashlib, json, pathlib
p = pathlib.Path('spikes/s5-gateway/research/wp1-d5-publication-time')
for r in json.loads((p/'requests.json').read_text())['requests']:
    if 'stored_path' in r:
        b = (p/r['stored_path']).read_bytes()
        assert len(b) == r['bytes'] and hashlib.sha256(b).hexdigest() == r['sha256']
i, m, c = [json.loads((p/'metadata'/f'hello-{n}.json').read_text()) for n in ('index', 'manifest', 'config')]
d = [x for x in i['manifests'] if x['annotations']['org.opencontainers.image.ref.name'] == '2.12.3.arm64_golden_gate.1']
assert len(d) == 1
for desc, name in ((d[0], 'manifest'), (m['config'], 'config')):
    b = (p/'metadata'/f'hello-{name}.json').read_bytes()
    assert desc['size'] == len(b) and desc['digest'] == 'sha256:' + hashlib.sha256(b).hexdigest()
assert m['layers'][0]['digest'] == 'sha256:' + d[0]['annotations']['sh.brew.bottle.digest']
assert 'created' not in c
assert i['annotations']['org.opencontainers.image.created'] < m['annotations']['org.opencontainers.image.created']
print('PASS: stored metadata chain; no publication-time assertion')
PY
```
