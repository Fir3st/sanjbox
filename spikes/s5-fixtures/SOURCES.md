# Zdroje a původ fixtures (WP1.D4)

Primární zdroje ověřené 2026-11-03. Dokumentace protokolů je podklad návrhu, ne důkaz S5.
Žádný obsah cizího npm balíčku ani jeho kód nebyl stažen. Závislosti Swift jsou pouze lokální D1/common.

| Zdroj | Použití a hranice |
|---|---|
| [npm Registry — package metadata](https://github.com/npm/registry/blob/main/docs/responses/package-metadata.md) | `versions`, `time[version]`, `dist.tarball` a SRI integrity. Zde jsou všechna metadata syntetická a bez důkazu důvěryhodného produkčního původu. |
| [npm — package-lock.json v11](https://docs.npmjs.com/cli/v11/configuring-npm/package-lock-json/) | Lockfile v3, `packages`, `resolved`, `integrity`; konkrétní loopback URL vygenerovaná pro běh. |
| [npm — npm ci v11](https://docs.npmjs.com/cli/v11/commands/npm-ci/) | Práce s hotovým lockfilem, nesoulad manifestu, `--ignore-scripts` a vypnutí auditů. Podpora byla lokálně pozorovaná jen s npm 11.20.0. |
| [npm — config v11](https://docs.npmjs.com/cli/v11/using-npm/config/) | Oddělený user/global config, registry/cache a fetch limity. Testy nahrazují environment, nečtou host npmrc. |
| [npm — cache v11](https://docs.npmjs.com/cli/v11/commands/npm-cache/) | Explicitní vložení vlastního lokálního artefaktu; cache není autoritativní evidence instalací. |
| [RFC 6749 §3.3](https://www.rfc-editor.org/rfc/rfc6749.html#section-3.3) | Scopes jsou definované poskytovatelem; názvy zde jsou pouze testovací. Mock grant a principal nenahrazují autentizaci ani ověření vydaných oprávnění. |
| [RFC 1952](https://www.rfc-editor.org/rfc/rfc1952.html) a [RFC 1951 §3.2.4](https://www.rfc-editor.org/rfc/rfc1951.html#section-3.2.4) | Gzip hlavička/trailer, CRC32, ISIZE a uložený DEFLATE blok; vlastní malý generátor pouze pro pevné syntetické soubory. |
| [libarchive — ustar writer](https://github.com/libarchive/libarchive/blob/master/libarchive/archive_write_set_format_ustar.c) | Primární implementace potvrzuje offsets/typ pravidelného souboru formátu ustar; žádný kód nepřevzat. Open Group pax stránky při ověření vracely 403. |
| [D1 README](../s5-gateway/README.md) a veřejné zdroje v main `547f3c1e630cdd95662b9a9f339a22f7a1c47026` | HTTP/router/DestinationPolicy kontrakt; interní transport seam není použitý. D2/D3 návrhy/PR nejsou zdrojem API. |

## Nezávislý vektor tarballu

Swift generátor se porovnává s hashem odvozeným přes systémový Python stdlib `tarfile`
(ustar) a `zlib` (CRC32). Následující skript pouze sestaví data v paměti a vypíše hash;
nic nezapisuje, nestahuje ani nespouští obsah balíčku:

```python
import hashlib, io, json, struct, tarfile, zlib
manifest = json.dumps({"name": "fixture-bead", "version": "1.0.0"},
                      sort_keys=True, separators=(",", ":")).encode()
stream = io.BytesIO()
with tarfile.open(fileobj=stream, mode="w", format=tarfile.USTAR_FORMAT) as archive:
    for name, body in [("package/package.json", manifest),
                       ("package/README.txt", b"Synthetic Sanjbox fixture. No executable code.\n")]:
        entry = tarfile.TarInfo(name)
        entry.size = len(body)
        entry.mode = 0o644
        archive.addfile(entry, io.BytesIO(body))
# Two regular entries (4 blocks) plus two end blocks; omit tarfile's optional record padding.
tar = stream.getvalue()[:3072]
gzip = (bytes.fromhex("1f8b08000000000000ff01")
        + struct.pack("<HH", len(tar), len(tar) ^ 65535)
        + tar + struct.pack("<II", zlib.crc32(tar), len(tar)))
print(len(gzip), hashlib.sha256(gzip).hexdigest())
```

Výstup: `3095 dce3d65c3651022ed0e18156a097796099d5b5b88eeecb86f60271b21e2e1621`.
SHA-512 SRI ostatních fixtures se počítá z jejich konkrétních generovaných bajtů, nikoli z názvu nebo expected výsledku.
