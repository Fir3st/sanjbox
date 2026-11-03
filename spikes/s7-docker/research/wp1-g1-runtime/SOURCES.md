# Zdroje WP1.G1

Primární veřejné dokumenty a zdrojové texty, kontrolované **2026-11-03**, snapshot stažení
**17:21:15–17:25:15 UTC**. Browser ověřil release stránky a Apple/Docker dokumentaci; přes GitHub API
byly rozlišené stable tagy a přesné commity, raw texty staženy jen pro čtení a hashování.
Žádný balíček, image, archiv ani binárka nebyly staženy či spuštěny. API odpověď může uvádět release
assets, ty se nestahovaly. Podklad repozitáře: `547f3c1e630cdd95662b9a9f339a22f7a1c47026`.

[sources.tsv](sources.tsv) je manifest **46 použitých textů, 456 694 bytů**: ID, druh zdroje, jméno
dočasného souboru, velikost, SHA-256 celého původního response body, přesná URL a čas stažení.
Řádky níže ukazují permalink a konkrétní místo/scope; citace `[A01]` apod. v README/VALIDATION
znamenají právě tyto řádky. Značky ID nejsou naměřené výsledky testů.

## Verze a data

| Projekt | Tag / commit | Datum UTC | Kontrola |
|---|---|---|---|
| Apple container | `1.6.1` → `aa8d76b44a834eee3ebf6a0bc577e376f65f6361` | release `2026-10-23T23:26:12Z`; commit `2026-10-23T20:41:00Z` | M01, A01; stable podle `releases/latest` v čase rešerše |
| Containerization | `0.53.0` → `f79e412d7c31b00c65c8a6f80dd0b0bb55f6a4f7` | commit `2026-10-20T17:32:34Z` | A14 a M06; závislost, nikoli tvrzení o nejnovějším standalone release |
| Colima | `v0.10.3` → `00f6c297e92a82c04a4ab507db0a61435650d7e8` | release `2026-06-04T17:14:15Z`; commit `2026-06-04T16:11:28Z` | M02; stable podle `releases/latest` |
| Lima | `v2.2.1` → `27bc4c4b101e27994e01e36566a0f2091bbca507` | release `2026-10-03T13:04:02Z`; commit `2026-10-03T12:45:04Z` | M03; stable podle `releases/latest`; beta 2.3.0 není zaměněna za stable |
| Moby / Engine | `docker-v29.9.2` → `0367cbeb49b9d98cb0b4f51e95f7b54b4803e76c` | release `2026-10-20T20:51:17Z`; commit `2026-10-20T16:53:07Z` | M04; referenční současné vydání, neběží zde |
| Docker CLI | `v29.9.2` → `a82e528901260c8df6073311379eac65f92db204` | commit `2026-10-20T11:24:07Z` | M05, D04–D05; datum commitu, nikoli vymyšlený čas release |
| Docker docs | `1315bf2c3c390c6ffee0f3c9ddfcb04eb23df067` | commit `2026-11-03T16:12:27Z` | D01–D03, D06; snapshot main, dokumentace nemusí přesně odpovídat všem starším Engine verzím |
| Apple Virtualization.framework docs | V01–V03, datovaný SHA-256 snapshot | stažení dle manifestu | Veřejné stránky bez release tagu/SDK commitu; popis API, ne měření macOS 27.2 |

## Síla a limity citací

**`kind=commit`**: raw URL má plný commit, hash a velikost dovolují kontrolovat stejné textové byty.
To nedokazuje jejich vykonání, úplnost auditované implementace, podpis vydané binárky ani nastavení
uživatelova stroje. Vybrané větve kódu mohou mít jiné runtime podmínky; relevantní varianty se měří v L8.
Například Colima explicitně vytváří wildcard forwarding pravidla, jejich skutečnou dosažitelnost
v konkrétní síti musí testovat DK-07. Lima default template a built-in default nejsou totéž.

**`kind=mutable`**: Apple online docs a GitHub metadata lze později změnit. Hash zaznamenává původní
odpověď; neslibuje budoucí byteidentický download. Při nezávislém refetchi M03 se již během review
změnily pouze počty stažení dvou assets; tag/datum zůstaly stejné. Původní hash nebyl přepsán.
Změna hash takového zdroje znamená nový snapshot a kontrolu významu, nikoli automaticky chybnou verzi
runtime. Při zmizení zdroje se chybějící důkaz přizná, nenahradí tipem.

Zdroje jsou popisem upstreamu. Nejsou důkazem průchodu R4/R3/R5, bezpečnosti same-UID control plane,
funkčního vsock bridge, tří relací ani F0.8. Upstream benchmarky se nepřebírají jako naše měření.
Plné source snapshoty se necommitují; zůstaly v dočasném review adresáři
`/private/tmp/sanjbox-wp1-g1-sources-20261103`. Repozitář obsahuje vlastní rozbor, citace a manifest;
licence původních textů zůstávají u upstreamu. Není to vendor kopie ani závislost projektu.

## Reprodukce stažení a hash kontroly

**[implementátor, volitelné read-only ověření]** Spustit z tohoto adresáře. Používá pouze standardní
Python pro stažení veřejných textů do nového dočasného adresáře; žádný stažený obsah se neimportuje,
nekompiluje ani nespouští. Nejde o instalační postup. Síťová oprávnění se řídí prostředím.

```sh
python3 - <<'PY'
import csv, hashlib, pathlib, tempfile, urllib.parse, urllib.request

dst = pathlib.Path(tempfile.mkdtemp(prefix="sanjbox-g1-public-", dir="/private/tmp"))
allowed = {"raw.githubusercontent.com", "api.github.com", "developer.apple.com"}
with open("sources.tsv", newline="") as manifest:
    rows = list(csv.DictReader(manifest, delimiter="\t"))
for row in rows:
    url = urllib.parse.urlsplit(row["url"])
    assert url.scheme == "https" and url.hostname in allowed
    assert pathlib.Path(row["file"]).name == row["file"]
    request = urllib.request.Request(row["url"], headers={"User-Agent": "sanjbox-public-doc-research"})
    with urllib.request.urlopen(request, timeout=30) as response:
        assert urllib.parse.urlsplit(response.url).hostname in allowed
        body = response.read(1_000_001)
    assert len(body) <= 1_000_000
    body.decode("utf-8")
    (dst / row["file"]).write_bytes(body)
    same = len(body) == int(row["bytes"]) and hashlib.sha256(body).hexdigest() == row["sha256"]
    if not same and row["kind"] == "commit":
        raise SystemExit(f"{row['id']}: odlišný připnutý text, prověřit zdroj")
    print(row["id"], "SHA256 OK" if same else "MUTABLE CHANGED: zkontrolovat obsah nového snapshotu")
print(dst)
PY
```

Úklid znamená odstranit pouze nově vypsaný dočasný adresář po review; žádná konfigurace/runtime ani
existující uživatelský soubor nebyly tímto postupem změněny.

## Apple container

| ID | Přesný text / místo | Použitý rozsah |
|---|---|---|
| A01 | [README.md:106](https://github.com/apple/container/blob/aa8d76b44a834eee3ebf6a0bc577e376f65f6361/README.md#L106) | OCI a garantované XPC API, nikoli Docker Engine API |
| A02 | [docs/technical-overview.md:22](https://github.com/apple/container/blob/aa8d76b44a834eee3ebf6a0bc577e376f65f6361/docs/technical-overview.md#L22) | VM per kontejner; služby, Keychain, vmnet; memory ballooning limit |
| A03 | [docs/command-reference.md:118](https://github.com/apple/container/blob/aa8d76b44a834eee3ebf6a0bc577e376f65f6361/docs/command-reference.md#L118) | CLI run/build, BuildKit, mounts, socket/SSH forwarding |
| A04 | [Sources/ContainerPlugin/ApplicationRoot.swift:21](https://github.com/apple/container/blob/aa8d76b44a834eee3ebf6a0bc577e376f65f6361/Sources/ContainerPlugin/ApplicationRoot.swift#L21) | User app-root a CONTAINER_APP_ROOT |
| A05 | [Sources/ContainerCommands/System/SystemStart.swift:39](https://github.com/apple/container/blob/aa8d76b44a834eee3ebf6a0bc577e376f65f6361/Sources/ContainerCommands/System/SystemStart.swift#L39) | User override a registrace launchd služby |
| A06 | [Sources/ContainerPersistence/ConfigurationLoader.swift:37](https://github.com/apple/container/blob/aa8d76b44a834eee3ebf6a0bc577e376f65f6361/Sources/ContainerPersistence/ConfigurationLoader.swift#L37) | Config precedence; read-only kopie není host policy |
| A07 | [Sources/ContainerPlugin/ServiceManager.swift:41](https://github.com/apple/container/blob/aa8d76b44a834eee3ebf6a0bc577e376f65f6361/Sources/ContainerPlugin/ServiceManager.swift#L41) | launchctl bootstrap; getDomainString user/gui UID |
| A08 | [docs/networking.md:6](https://github.com/apple/container/blob/aa8d76b44a834eee3ebf6a0bc577e376f65f6361/docs/networking.md#L6) | Host/guest IP cesta, publish IPv4/IPv6 TCP/UDP, vmnet sítě |
| A09 | [docs/architecture/dns.md:13](https://github.com/apple/container/blob/aa8d76b44a834eee3ebf6a0bc577e376f65f6361/docs/architecture/dns.md#L13) | Pevné DNS localhost porty, globální resolver soubory, scope odpovědí |
| A10 | [docs/volumes.md:7](https://github.com/apple/container/blob/aa8d76b44a834eee3ebf6a0bc577e376f65f6361/docs/volumes.md#L7) | Host-path mount a bind/virtiofs; RO; odlišení guest daemon mountu |
| A11 | [docs/container-machine.md:5](https://github.com/apple/container/blob/aa8d76b44a834eee3ebf6a0bc577e376f65f6361/docs/container-machine.md#L5) | Machine režim: home RW, SSH agent, guest root; není regular container |
| A12 | [Sources/ContainerCommands/Registry/RegistryLogin.swift:63](https://github.com/apple/container/blob/aa8d76b44a834eee3ebf6a0bc577e376f65f6361/Sources/ContainerCommands/Registry/RegistryLogin.swift#L63) | Registry login a Keychain helper; nikoli důkaz izolace přihlášení |
| A13 | [Sources/ContainerPersistence/ContainerSystemConfig.swift:26](https://github.com/apple/container/blob/aa8d76b44a834eee3ebf6a0bc577e376f65f6361/Sources/ContainerPersistence/ContainerSystemConfig.swift#L26) | Skutečné resource defaults a konfigurovatelný kernel/init image |
| A14 | [Package.resolved:14](https://github.com/apple/container/blob/aa8d76b44a834eee3ebf6a0bc577e376f65f6361/Package.resolved#L14) | Containerization 0.53.0 a přesný revision |

## Colima

| ID | Přesný text / místo | Použitý rozsah |
|---|---|---|
| C01 | [README.md:22](https://github.com/abiosoft/colima/blob/00f6c297e92a82c04a4ab507db0a61435650d7e8/README.md#L22) | Docker runtime a standardní klient; nikoli bezpečnostní garance |
| C02 | [embedded/defaults/colima.yaml:3](https://github.com/abiosoft/colima/blob/00f6c297e92a82c04a4ab507db0a61435650d7e8/embedded/defaults/colima.yaml#L3) | Default CPU/RAM, DNS, SSH, daemon config, home RW, forwarding |
| C03 | [config/files.go:50](https://github.com/abiosoft/colima/blob/00f6c297e92a82c04a4ab507db0a61435650d7e8/config/files.go#L50) | COLIMA_HOME, cache, LIMA_HOME, společné _lima a _store |
| C04 | [config/profile.go:13](https://github.com/abiosoft/colima/blob/00f6c297e92a82c04a4ab507db0a61435650d7e8/config/profile.go#L13) | Profil a jeho adresář; instance není jiné UID |
| C05 | [environment/vm/lima/yaml.go:24](https://github.com/abiosoft/colima/blob/00f6c297e92a82c04a4ab507db0a61435650d7e8/environment/vm/lima/yaml.go#L24) | HostResolver ř. 82+, user-v2 ř. 140+, sockets/ports ř. 226–339, mounts ř. 380–405 |
| C06 | [environment/container/docker/context.go:12](https://github.com/abiosoft/colima/blob/00f6c297e92a82c04a4ab507db0a61435650d7e8/environment/container/docker/context.go#L12) | Per-profile docker.sock, legacy socket a aktivace contextu |
| C07 | [environment/container/docker/daemon.go:10](https://github.com/abiosoft/colima/blob/00f6c297e92a82c04a4ab507db0a61435650d7e8/environment/container/docker/daemon.go#L10) | Daemon config, host-gateway a dockerd systemd command |

## Lima

| ID | Přesný text / místo | Použitý rozsah |
|---|---|---|
| L01 | [templates/docker.yaml:9](https://github.com/lima-vm/lima/blob/27bc4c4b101e27994e01e36566a0f2091bbca507/templates/docker.yaml#L9) | Rootless Docker; zděděné mounty, installer, host socket a host alias |
| L02 | [templates/docker-rootful.yaml:9](https://github.com/lima-vm/lima/blob/27bc4c4b101e27994e01e36566a0f2091bbca507/templates/docker-rootful.yaml#L9) | Rootful Docker; guest /var/run/docker.sock a socket user |
| L03 | [templates/_default/mounts.yaml:1](https://github.com/lima-vm/lima/blob/27bc4c4b101e27994e01e36566a0f2091bbca507/templates/_default/mounts.yaml#L1) | Home; /tmp/lima odstraněno z defaultu od v2.0 |
| L04 | [templates/default.yaml:39](https://github.com/lima-vm/lima/blob/27bc4c4b101e27994e01e36566a0f2091bbca507/templates/default.yaml#L39) | Resource defaults, home RO/writable=false, hostResolver, SSH defaults |
| L05 | [website/content/en/docs/config/network/user.md:20](https://github.com/lima-vm/lima/blob/27bc4c4b101e27994e01e36566a0f2091bbca507/website/content/en/docs/config/network/user.md#L20) | Host loopback alias; host resolver, mDNS a fallback DNS cesty |
| L06 | [website/content/en/docs/config/network/user-v2.md:9](https://github.com/lima-vm/lima/blob/27bc4c4b101e27994e01e36566a0f2091bbca507/website/content/en/docs/config/network/user-v2.md#L9) | User-v2 VM→VM komunikace a limactl tunnel |
| L07 | [website/content/en/docs/config/network/vmnet.md:16](https://github.com/lima-vm/lima/blob/27bc4c4b101e27994e01e36566a0f2091bbca507/website/content/en/docs/config/network/vmnet.md#L16) | vzNAT; privileged socket_vmnet, root-owned paths/runstate, skupiny a sdílený daemon |
| L08 | [website/content/en/docs/config/sudo.md:9](https://github.com/lima-vm/lima/blob/27bc4c4b101e27994e01e36566a0f2091bbca507/website/content/en/docs/config/sudo.md#L9) | Guest passwordless sudo a limit socket tunneling při jeho vypnutí |
| L09 | [website/content/en/docs/config/port.md:6](https://github.com/lima-vm/lima/blob/27bc4c4b101e27994e01e36566a0f2091bbca507/website/content/en/docs/config/port.md#L6) | Automatické forwardování; SSH/gRPC/vsock rozdíly, nepřenositelnost benchmarku |
| L10 | [website/content/en/docs/config/mount.md:109](https://github.com/lima-vm/lima/blob/27bc4c4b101e27994e01e36566a0f2091bbca507/website/content/en/docs/config/mount.md#L109) | VZ virtiofs; jiné drivery a reverse-sshfs caveat |

## Docker

| ID | Přesný text / místo | Použitý rozsah |
|---|---|---|
| D01 | [content/manuals/engine/security/_index.md:82](https://github.com/docker/docs/blob/1315bf2c3c390c6ffee0f3c9ddfcb04eb23df067/content/manuals/engine/security/_index.md#L82) | Rootful Docker API dává kontrolu nad daemon hostem |
| D02 | [content/manuals/engine/storage/bind-mounts.md:46](https://github.com/docker/docs/blob/1315bf2c3c390c6ffee0f3c9ddfcb04eb23df067/content/manuals/engine/storage/bind-mounts.md#L46) | Bind zdroj na daemon hostu, default zápis, odlišení klienta/VM |
| D03 | [content/manuals/build/concepts/context.md:13](https://github.com/docker/docs/blob/1315bf2c3c390c6ffee0f3c9ddfcb04eb23df067/content/manuals/build/concepts/context.md#L13) | Lokální/remote context, rekurze, Git/submodules a builder stahování |
| D04 | [docs/reference/commandline/login.md:50](https://github.com/docker/cli/blob/a82e528901260c8df6073311379eac65f92db204/docs/reference/commandline/login.md#L50) | Klientský config, native helper z PATH, fallback a login flow |
| D05 | [vendor/github.com/moby/moby/client/version.go:15](https://github.com/docker/cli/blob/a82e528901260c8df6073311379eac65f92db204/vendor/github.com/moby/moby/client/version.go#L15) | /version; API maximum/minimum, ne důkaz testované kombinace |
| D06 | [content/manuals/engine/network/port-publishing.md:18](https://github.com/docker/docs/blob/1315bf2c3c390c6ffee0f3c9ddfcb04eb23df067/content/manuals/engine/network/port-publishing.md#L18) | Docker guest publish, IPv4/IPv6/bind a host přístup |

## Virtualization.framework

| ID | Přesný text / místo | Použitý rozsah |
|---|---|---|
| V01 | [developer.apple.com/documentation/virtualization/vzvirtualmachineconfiguration/networkdevices.md](https://developer.apple.com/documentation/virtualization/vzvirtualmachineconfiguration/networkdevices.md) | networkDevices default prázdné; volitelná virtuální NIC |
| V02 | [developer.apple.com/documentation/virtualization/vzvirtiosocketdevice.md](https://developer.apple.com/documentation/virtualization/vzvirtiosocketdevice.md) | Host/guest porty a listenery; žádná deklarovaná policy Sanďboxu |
| V03 | [developer.apple.com/documentation/virtualization/vzshareddirectory.md](https://developer.apple.com/documentation/virtualization/vzshareddirectory.md) | Host directory share a read-only vlastnost |

## Metadata vydání

| ID | Přesný text / místo | Použitý rozsah |
|---|---|---|
| M01 | [api.github.com/repos/apple/container/releases/tags/1.6.1](https://api.github.com/repos/apple/container/releases/tags/1.6.1) | Apple container tag a published_at |
| M02 | [api.github.com/repos/abiosoft/colima/releases/tags/v0.10.3](https://api.github.com/repos/abiosoft/colima/releases/tags/v0.10.3) | Colima tag a published_at |
| M03 | [api.github.com/repos/lima-vm/lima/releases/tags/v2.2.1](https://api.github.com/repos/lima-vm/lima/releases/tags/v2.2.1) | Lima tag a published_at; dynamické asset download_count |
| M04 | [api.github.com/repos/moby/moby/releases/tags/docker-v29.9.2](https://api.github.com/repos/moby/moby/releases/tags/docker-v29.9.2) | Engine/Moby tag a published_at |
| M05 | [api.github.com/repos/docker/cli/commits/v29.9.2](https://api.github.com/repos/docker/cli/commits/v29.9.2) | CLI tag dereference na commit a committer.date |
| M06 | [api.github.com/repos/apple/containerization/commits/0.53.0](https://api.github.com/repos/apple/containerization/commits/0.53.0) | Containerization tag dereference na commit a committer.date |
