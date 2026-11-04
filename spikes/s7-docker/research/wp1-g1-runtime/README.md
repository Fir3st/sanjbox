# WP1.G1 — runtime pro Docker ve F4

**Výsledek rešerše k 2026-11-03: žádný z posouzených stock kandidátů nedokládá všechny podmínky S7.**
Colima/Lima s Docker Engine je nejbližší referenční varianta pro `docker run`/`build`. Apple `container`
má vlastní XPC API a OCI kompatibilitu, což nestačí jako důkaz Docker Engine API. Vlastní
Virtualization.framework Linux + initrd + `dockerd`, bez virtuální NIC, je podmíněný směr výzkumu
hranice host–guest, nikoli hotové řešení. [A01–A03, C01, L01–L02](SOURCES.md)

Balík je **dokumentační příprava**, nezávislá na otevřených PR. **S7 i DK-01…10 zůstávají Neověřeno.**
Docker je mimo MVP podle [C-002/F0.4](../../../../docs/DECISIONS.md); R4 se nemění. Linux VM uvnitř
kontejnerového runtime je již variantou [PLAN S7](../../../../PLAN.md), nikoli náhradou nativní
macOS oblasti za odmítnutou desktopovou VM. Start/stop budget, minimální konfiguraci a statistiky
stále rozhoduje uživatel ve F0.8; zde se žádné limity neschvalují.

Čti dále: [předregistrace G2/L8 a oracle DK-01…10](VALIDATION.md), [primární zdroje a jejich scope](SOURCES.md),
[URL/SHA-256/velikost/datum každého použitého textu](sources.tsv).

## Co je a není důkaz

- **Měřeno:** pouze stažení veřejných textů, jejich velikost a SHA-256; žádné runtime měření.
- **Dokumentace/zdroj:** upstream rozhraní nebo konkrétní větev kódu v připnutém commitu.
- **Odvozeno:** důsledek těchto vlastností pro threat model Sanďboxu; není verdikt živého stroje.
- **Hypotéza:** potřebná vlastní komponenta nebo dosud neověřená konstrukce.

Nebyly instalovány ani spuštěny Docker, Apple container, Colima či Lima; nebyla čtena jejich místní
konfigurace, auth, Klíčenka, databáze ani tajemství. Zdroje nedokazují chování na cílovém macOS 27.2,
konkrétní build macOS, podpis, oprávnění a relace doplní teprve L8.

## Připnutý rozsah

| Kandidát / reference | Připnutí | Datum vydání UTC | Hranice tvrzení |
|---|---|---|---|
| Apple `container` | `1.6.1`, `aa8d76b44a834eee3ebf6a0bc577e376f65f6361` | 2026-10-23 | Nejnovější stable zjištěný přes release API; závislost Containerization `0.53.0`, `f79e412d7c31b00c65c8a6f80dd0b0bb55f6a4f7` dle lockfile. |
| Colima | `v0.10.3`, `00f6c297e92a82c04a4ab507db0a61435650d7e8` | 2026-06-04 | Nejnovější stable zjištěný přes release API; verze bundled Dockeru není automaticky současná verze Engine. |
| Lima | `v2.2.1`, `27bc4c4b101e27994e01e36566a0f2091bbca507` | 2026-10-03 | Stable; dostupný `v2.3.0-beta.1` není podklad volby. Toto není měření kombinace Colima 0.10.3 + Lima 2.2.1. |
| Docker reference | Engine/Moby `docker-v29.9.2`, `0367cbeb49b9d98cb0b4f51e95f7b54b4803e76c`; CLI `v29.9.2`, `a82e528901260c8df6073311379eac65f92db204` | Engine 2026-10-20; CLI commit 2026-10-20 | Referenční rozhraní, nikoli zvolený/instalovaný guest image. Engine, BuildKit/buildx, kernel a initrd pro L8 musí mít vlastní pin. |

Datované metadata, přesné časy a Docker docs commit jsou v [SOURCES](SOURCES.md). Apple VZ dokumentace
nemá veřejný release tag; je poctivě označena jako datovaný hashovaný snapshot, ne jako macOS 27.2 SDK.

## Srovnání

| Otázka | Apple container 1.6.1 | Colima / Lima, vlastní instance každé oblasti | Vlastní VZ Linux + initrd/dockerd, bez NIC |
|---|---|---|---|
| `docker run` / `docker build` | Vlastní `container run` a BuildKit `container build`; OCI/Dockerfile nejsou Docker HTTP API. Zkoumaná reference popisuje XPC API. Adaptér by byl vlastní kód. [A01–A03] | Colima Docker runtime a Lima Docker šablony mají skutečný `dockerd` a forwardovaný Unix socket. Rootless a rootful Lima jsou odlišné varianty. [C01, C05–C06, L01–L02] | Skutečný `dockerd` uvnitř VM je hypotéza kompatibilní cesty. Unix socket → vsock transport musí zachovat API, streamy a builder session; pouhý wrapper příkazů nestačí. [D01, D05, V01–V02] |
| Vlastní stav / daemon | Per-user app-root a launchd/XPC služby; standardní app-root `~/Library/Application Support/com.apple.container`, config `~/.config/container/config.toml`. Není to Docker socket. [A04–A07] | Colima profil má `colima.yaml`, `docker.sock`, vlastní VM; `$COLIMA_HOME/_lima` a cache mohou být společné mezi profily jednoho UID. Lima socket `{{.Dir}}/sock/docker.sock`. [C03–C06, L01–L02] | Per-oblast disk/runstate/socket, lifecycle a rollback je nutné navrhnout; chráněná host policy nesmí být uvnitř vratného guest stavu. |
| Co ovládá UID oblasti | CLI přijímá mounty, sítě, vlastní init/kernel, SSH/socket forward; start bere user config, `--app-root` a `--install-root`. Read-only kopie configu není policy vlastněná rootem. [A03–A07, A10–A11] | Vlastník profilu mění mounty, daemon config, DNS, sítě, provisioning a restartuje VM. Jiný profil stejného UID není bezpečnostní hranice. [C02–C05, C07] | Požadována hostem vlastněná policy a důvěryhodný správce, kterého oblast nepřesměruje ani nenahradí. Samotné root-owned YAML vedle uživatelsky řízeného launcheru nestačí. **Hypotéza**, nikoli vlastnost VZ API. |
| Mounty a `-v /:/host` | `container --volume` explicitně sdílí macOS cestu přes bind/virtiofs. `container machine` je jiný režim: home RW, SSH agent, guest sudo a plné capabilities. [A10–A11] | Docker binduje kořen **Linux daemon hostu**. V něm však mohou být macOS shares: Colima default home RW; Lima Docker šablony home RO. [C02, C05, L01–L04, D02] | Guest `/` může být přístupný, chráněný macOS/jiná oblast nesmí. Žádný home share; případný explicitní share pouze schválený kořen oblasti. VZ shared directory je skutečná host datová cesta. [V03] |
| Síť / DNS | Stock vmnet a virtuální NIC, host má cestu na IP kontejneru; izolovaná vmnet síť neznamená bránu S5. Host DNS používá pevné localhost porty 2053/1053 a `/etc/resolver`. [A02, A08–A09] | Colima generuje `user-v2`; Lima user-mode má host loopback alias a hostResolver přes nativní resolver včetně mDNS. `vzNAT`/socket_vmnet jsou další cesty. [C05, L05–L08] | `networkDevices=[]` umožňuje VM bez virtuální NIC; vsock poskytuje host služby. Jen typované S5 operace, žádný obecný TCP/UDP/DNS relay. **Neprokázáno.** [V01–V02] |
| Published ports | TCP/UDP, IPv4/IPv6; ani bind na loopback neautentizuje oblast. Vedle publish existuje přímá host→guest IP cesta. [A03, A08] | Colima generátor mapuje guest `0.0.0.0` na host `0.0.0.0` pro TCP/UDP; loopback má samostatná pravidla. Lima má automatické forwardování. [C05, L09] | Explicitní autorizovaný per-oblast relay pro testovacího klienta; Docker `-p` uvnitř guestu sám nevystaví host port. Překlad port mappingu je vlastní kód a kompatibilitní omezení do ověření. |
| Sdílené služby | launchd, XPC, vmnet, Keychain; DNS resolver soubory jsou globální host stav. Kolize pevných DNS portů při třech UID vyžaduje test. [A02, A07–A09, A12] | hostagent, forwardery, usernet; volitelný privileged socket_vmnet a sudoers. `vzNAT` sudoers nepotřebuje, přesto má síť. [L05–L09] | Malý broker je stále host attack surface: peer identita, oprávnění, path handling, revokace, limity a S8. VZ/vsock samo žádnou aplikační autorizaci nedodává. |
| Tři oblasti / zdroje | VM na kontejner + builder VM; defaulty a nevracení uvolněných guest stránek hostu jsou důvod měřit skutečný footprint. [A02, A13] | Nejméně tři VM + jejich buildery/forwardery; Colima default 2 CPU/2 GiB, Lima default min(4 CPU, host) a min(4 GiB, půl RAM). Nejsou to přijaté budgety. [C02, L04] | Tři per-oblast VM a broker; náklady bootu, RAM, disků a buildů neznámé. Žádná latence ani úspora není slíbena. |

Označení zdrojů v tabulce odkazují do [SOURCES.md](SOURCES.md).

## Rozhodující hranice a podmíněná volba

**Nezaměňovat tři útočníky:** proces kontejneru, root v guest Linuxu a user-level proces macOS oblasti.
Plný rootful Docker socket umožňuje ovládat guest host včetně mountů/capabilities; guest root proto
není správce bezpečnostní policy vůči oblasti. Guest firewall, `HTTP_PROXY`, `--network none` zadané
uživatelem ani read-only user config nejsou neobejitelná hranice. Oddělené UID je potřebné pro
oddělení stavu, ne důkaz R2/R3. [D01](SOURCES.md#docker)

`docker run -v /:/host` se vyhodnotí proti skutečné topologii: u Linux daemonu je `/` guest kořen,
u Apple bind mountu je zdroj host macOS cesta. Žádná varianta nesmí číst **ani RO** chráněné host
kanárky. Colima `mounts: []` znamená home RW, nikoli vypnutí mountů; v připnutém generátoru je
rozdíl mezi prázdným seznamem a `nil`. Lima `_default/mounts` dědí home a od v2.0 už nedědí
`/tmp/lima`. Home spouštějícího UID oblasti není automaticky osobní home hosta; rozhoduje skutečný
vlastník/share a obsah. Virtiofs neuděluje automaticky macOS root, ale zpřístupňuje to, co host
proces smí otevřít. [A10–A11, C02, C05, L03–L04, L10, D02, V03](SOURCES.md)

**Doporučení pro G2:** předregistrovat (1) Colima/Lima s Docker Engine jako kompatibilitní referenci
a adversarial kontrolu stock konfigurace; (2) Apple native CLI jako samostatnou srovnávací variantu,
bez přejmenování jejího výsledku na průchod DK-01; (3) teprve při nevyhovění stock variant vlastní
VZ transport bez NIC. Pro třetí variantu nejprve review důvěryhodné řídicí vrstvy, ne integrace F4.
Pokud by potřebovala jiné vlastnictví/procesovou topologii než proces oblasti v PLAN, je to
neověřený návrh k architektonickému review, nikoli již přijatá změna kontraktu.

Root-managed vnitřní Linux VM a Docker compatibility bridge zatím **neexistují jako ověřený výstup**.
Oblast smí řídit své workloady a guest stav; nesmí rozšířit host shares, přidat NIC, přesměrovat
vsock na libovolný host socket/službu, vybrat cizí daemon nebo získat nový login/restart po vypnutí.
Předpoklad ochrany vlastního runneru zahrnuje same-UID attach, náhradní launcher a přímé volání API.
Bez uzavření těchto cest není chráněná policy prokázána.

**VM bez NIC neuzavírá R3 celé oblasti.** Odstraní jednu guest datovou cestu; nativní procesy oblasti,
hostem zprostředkované DNS a existující helpery stále podléhají S0/S3/S3b/S5/S8. Otevřený WP1.C2
(výpadek pf bez Network Extension, F0.5) trvá. Vsock služba `connect(host, port)` či libovolný resolver
by přes důvěryhodný proces znovu otevřely LAN, host localhost i DNS exfiltraci. Ani NAT, izolovaná
virtuální síť, systémový resolver nebo předání provozu procesu s jiným UID nedokazují gateway-only egress.

Registry a build mají samostatnou hranici: Apple login ukládá údaj přes Keychain helper; Docker CLI
používá klientský config a může spouštět native helper z PATH. Profil VM neodděluje automaticky
klientský auth ani builder. V G2 pouze syntetické účty, prázdný per-oblast `DOCKER_CONFIG`, mock helper
a mock registry; žádný host SSH agent. Údaj dostupný UID oblasti je kompromitovatelný. Důvěryhodná
brána musí omezit registry repo, operace, redirect a auth realm; povolené stažení není obecný push.
Lokální build context čte klient, remote Git/URL může stahovat builder; obě cesty včetně symlink/TOCTOU,
SSH forwarding a exportu cache patří do testu. `.dockerignore` není ochrana proti nedůvěryhodnému UID.
[A03, A12, D03–D04](SOURCES.md)

G1 tím dodává podklad pro volbu a konkrétní [G2/L8 postup](VALIDATION.md). Chybějící enforcement,
runtime měření a rozhodnutí F0.8 se nepřevádějí na úspěšný gate.
