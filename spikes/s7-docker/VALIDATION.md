# WP1.G2 — validace částečné offline přípravy

Datum **2026-11-04**, macOS **27.2 (26B123)**, nativní `/usr/bin/python3` **3.9.6**.
Base `afae1ca7dfe78f03d5006c42b6b01093772eba0c`, claim `5ec50bc`.
Toto není L8 laboratorní run ani důkaz izolace macOS/VM. **G2 zůstává částečné;
S7/DK-01…10/R4 a všechny navazující brány zůstávají Neověřeno.** Docker mimo MVP (C-002).

## Provedené příkazy

Z kořene G2 worktree, bez instalací nebo síťového přístupu:

```bash
/usr/bin/python3 -I -B -m unittest discover -s spikes/s7-docker/tests -v
git diff --check
git diff --cached --check
```

Finální výsledek: **60 tests, OK**, bez skips. Whitespace kontrola exit 0.
První vývojový import zachytil chybějící uzavírací závorku v budget lookupu; opraveno před prvním
substantivním během (53/53). Následující běh rozšířených cleanup testů 58/58; finální 60/60 navíc
ověřuje, že neúplné evidence neschová dodaný únik a záporný počet se odmítne.

Součástí testů jsou skutečné CLI přes absolutní cestu na stejný checkout:

```bash
/usr/bin/python3 -I -B spikes/s7-docker/s7.py validate
/usr/bin/python3 -I -B spikes/s7-docker/s7.py plan
/usr/bin/python3 -I -B spikes/s7-docker/s7.py inventory
/usr/bin/python3 -I -B spikes/s7-docker/s7.py oracle \
  --observations spikes/s7-docker/examples/observations.json
/usr/bin/python3 -I -B spikes/s7-docker/fixture_files.py prepare --parent /synthetic-not-created
```

CLI test také vytvoří vlastní `TemporaryDirectory`, provede `fixture_files.py prepare --apply`
s jejím canonical parentem, ověří t003 syntetický canary, pak cleanup dry-run, cleanup apply a
opakovaný cleanup apply. Při konfliktních fixtures následný testovací úklid odstraní jen adresář
vytvořený tímto konkrétním `TemporaryDirectory`; nejde o obecný runtime cleanup.

| Kontrola | Pozorovaný offline výsledek |
|---|---|
| Návrhový manifest | 3 zóny, vlastní sockety; SHA-256 `414a2c15d2c4b520fb978b9d8d2a8f181358c157c10949b24d0e966515d54516` |
| Inventář | 64 scénářů DK-01…10 × 3 zóny = 192 povinných synthetic observations |
| Plán | 15 user-only argv, žádný spuštěný příkaz; `executable: false`; 8 unresolved artifact pinů |
| Negativní manifesty | 24 uložených mutací: každá odmítnuta |
| Registry | 18 uložených případů; 3 modelové allow, 15 deny; žádné auth údaje/síť |
| Smíšený observations příklad | 1 synthetic-match, 2 synthetic-mismatch, 2 insufficient, 187 missing |
| Úplný model s unresolved budgetem | 192 dodaných položek, 9 insufficient (3 časy × 3 zóny), žádný gate pass |
| Úplný model se synthetic-example budgetem | 192 synthetic-match; všechny DK i acceptance stále Neověřeno |
| Toy frames | Type/bounds/peer/generation/resource/replay/revocation kontrola pouze bytes v paměti |
| Own fixture cleanup | Stejný obsah/identita se odstraní, druhé volání idempotentní; změny/cizí entries se zachovají |

## Negativní pokrytí

- Parser: duplicate fields, unknown fields, NaN/float, velikost, hloubka, array/string/node limit,
  regular file vs symlink/FIFO, nekanonická cesta a kontrolní znaky. CLI error = exit 2, stdout
  prázdný, bez tracebacku. `s7.py execute` i `plan --apply` neexistují.
- Manifest: host share i RO, cizí project/socket/builder, shared UID/GID/CID, root/bool UID,
  reserved CID, cizí daemon, NIC, control vlastnictví/write/launcher/relay, traversal a shell-like
  path, unknown pin a neplatný/částečný budget. Apple native nenabízí Docker argv.
- Oracle: jiné manifest binding/kind, duplicitní/neznámý pár, chybějící zóna, chybějící pokus či
  pozitivní kontrola, bool za count a záporné count; 1 zakázaný byte nebo packet, read/write leak,
  neúplná topologie/capture/channel ledger, cizí daemon/gateway/upstream, output hash drift,
  přidaná NIC/share a cizí socket operace. Dodané expectations se nepřijímají.
- Budget: unresolved, přesná hranice, překročení, špatný počet vzorků, policy není ready, zbylé
  procesy/kanály; úplná syntetická shoda nic neschvaluje. F0.8 se žádným manifestem nemění.
- Registry: vlastní pull vs cizí repository, push, auth realm/redirect, client auth, cross-zone
  request. Model nemá důvěryhodnou skutečnou peer autentizaci ani registry HTTP implementaci.
- Toy framing: size prefix, truncated/trailing/oversized, duplicate JSON, spoofed peer/generation,
  bool version, libovolný connect/DNS/path, replay, revocation a 64-request bound. Žádný transport.
- Fixtures: default dry-run neotevře parent, root/setuid odmítnuto před FS přístupem, symlink a
  writable non-sticky ancestor, parent/root rename před mutation, změna identity/bytes/mode,
  payload/journal hardlink, neznámý soubor, forged inventory/planned journal; short read/write
  a EINTR; opakovaný cleanup a chybějící známý soubor po přerušeném cleanupu. ACL a aktivní same-UID
  souběh nejsou chráněné: výslovná exkluzivní mock namespace podmínka v README.

## Co nebylo provedeno

Žádné Docker/Colima/Lima/Apple container, VM/Engine/BuildKit/kernel/initrd/image spuštění,
provisioning ani download. Žádný `sudo`, systémová změna, pf, resolver, síťový listener/socket,
AF_VSOCK, Keychain/credential store nebo skutečné tajemství. Testy spouštěly pouze vlastní
Python CLI přes nativní interpreter; žádné cizí balíčky, shell payload nebo instalační script.

Chybí vlastní Linux probe/image, runtime integrace `run`/`build`/attach/exec/API negotiation,
chráněný manager, skutečné per-zone daemon/socket/builder identity a mount topology; D1/S5
adaptér, registry auth bridge, port relay a vsock/Docker stream transport. Chybí credentials/session
ověření živých sond, nezávislé file/packet oracles včetně DNS/mDNS/ICMP/QUIC a NET-20…26 zásahy,
start/stop/resource měření tří VM a lifecycle celého UID, F0.8 schválení a skutečný runtime cleanup.
Původní [G1 plán L8](research/wp1-g1-runtime/VALIDATION.md) zůstává úplným budoucím postupem.

Stav přijatých manifest deklarací ani dodaná pozorování nejsou nezávislý důkaz. Část fieldů jsou
záměrně jednoduché fixture hodnoty; plně zelený report lze sestrojit bez runtime, což test výslovně
ověřuje. `kind: synthetic-only-no-independent-oracle` a trvalé Neověřeno chrání proti tomuto omylu,
nikoli proti útočníkovi. Neexistuje zde produkční policy enforcement.

## Disk a zachování historie

Původní `research/wp1-g1-runtime` zůstal beze změny. Jen malé textové JSON fixtures, dva Python
moduly, testy a dokumentace. Vlastní temp test adresáře uklizeny; žádná `.build`, `__pycache__`,
`.pyc`, venv, stažená image, dependency nebo archiv. Žádný starý evidence run nebyl přepsán.
