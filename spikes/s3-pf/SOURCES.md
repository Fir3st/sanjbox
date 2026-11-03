# Primární opory a omezení C1

Přístup **2026-11-03**. Lokální statická inspekce na arm64 macOS **27.2, build 26B123**.
Nebylo spuštěno ani read-only `pfctl`, parser `-n`, `/dev/pf` ioctl, síťová sonda nebo globální
inspekce živých spojení. Dokumentace není runtime důkaz. Produktový cíl macOS 27.x nelze
rozšířit na všechny buildy z výsledku kompilace či této rešerše.

| ID / primární zdroj | Přesné místo a použité tvrzení | Hranice |
|---|---|---|
| A1 [Apple TN3165](https://developer.apple.com/documentation/technotes/tn3165-packet-filter-is-not-api?changes=_1_8) | Overview, Packet Filter fundamentals, Test during the transition: PF není veřejné produktové API; konflikt s uživatelem, systémovými službami a jiným softwarem je třeba testovat. | Tato laboratorní příprava není doporučení distribuovat PF produkt. Apple navržená NE není v C1 schválená změna F0.5. |
| M1 lokální `/usr/share/man/man8/pfctl.8` | Raw ř. 127–151 `-a` scope/anchor path; 211–242 disable, reference a odlišné flush modifier; 319–335 parse-only `-n`, optimizer; 344–346 `-R` pouze filter rules; 355–429 `-s` rules/Anchors/nat/Tables/Interfaces. | Proto přesný anchor + filter-only load, žádné blanket state-cleanup. User `--apply` teprve ověří aktuální parser/display. |
| M2 lokální `/usr/share/man/man5/pf.conf.5` | Raw ř. 589–597 `set skip`; 1239–1243 default pass; 1296–1304 state bypass reevaluation; 1587–1609 `all` a socket `user`, incoming listener, TCP/UDP, effective credentials at socket creation. | UID deny je diagnostický kandidát. Nepředpokládáme egress-only `user`, nepřisuzujeme ICMP/sys-service traffic UID a netvrdíme revokaci states reloadem. |
| M3 stejný lokální `pf.conf.5` | Raw ř. 1815–1846 tag/sticky/one tag/tagged; 1856–1882 route-to; 2392+ rdr-anchor; 2433–2469 anchor evaluation a quick; 2810+ grammar. | Vysvětluje zvolenou hypotézu, neprokazuje recirkulaci/tag survival na lo0 nebo IPv6 rdr. Proto pouze render-only. |
| A2 [Apple Libc, acl_entry.c](https://github.com/apple-oss-distributions/Libc/blob/main/posix1e/acl_entry.c#L108) | `acl_get_entry`, zejména ř. 119–136: Darwin úspěch entry = 0, konec = -1/EINVAL. | Open-source implementace není binární shoda macOS 27.2. Hlavní opora je aktuální SDK M4 a native vlastní temp fixture. Odkaz main je pohyblivý. |
| M4 CLT SDK `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/share/man/man3/acl_get_entry.3` a `usr/include/sys/acl.h` | RETURN VALUES/ERRORS; constants `ACL_TYPE_EXTENDED`, `ACL_FIRST_ENTRY`, podpisy `acl_get_fd_np`, `acl_valid`, `acl_get_entry`. | Při neexistující ACL `acl_get_fd_np` může vrátit nil/ENOENT; jiný error odmítáme. Každá existující ACE se odmítá, včetně deny-only ACL. Otestováno na vlastním souboru, ne systémových roots. |

`pfctl -sr` normalizuje zdrojovou syntaxi; C1 se nespoléhá na hash původního textu jako důkaz
načtených rules. Přijímá pouze malou explicitní sémantickou formu: `block drop`, `in/out`,
`quick`, `inet/inet6`, TCP/UDP, `all` nebo `from any to any`, `user UID` nebo `user = UID`
(číselně či přesně konfigurované jméno), unikátní label. Pořadí a všechny prvky musí odpovídat.
Ekvivalence `all` a adresního zápisu je doložená M2; **jakou display variantu vydá konkrétní
macOS 27 pfctl, jsme neměřili**. Neznámý formát znamená odmítnutí a uchování journalu.
Při hledání aktuálního printeru neměl veřejný Apple `network_cmds` tree
[`97e27e6244c16d399bfeb254315ddc5828711c56`](https://github.com/apple-oss-distributions/network_cmds/tree/97e27e6244c16d399bfeb254315ddc5828711c56)
žádnou cestu `pfctl`. Nepřisuzujeme proto chování staršího BSD printeru současné binárce.

## Otisky lokálních podkladů (SHA-256)

```text
2708d9f123d88d445f4c15ef32d4f71f57921fc8cc3f12fad7cce4cd08b7b61f  /usr/share/man/man5/pf.conf.5
e8754dccfa5edaf93f3e1eb71339927da6901cd2b4290f2ecf062a42a552eaff  /usr/share/man/man8/pfctl.8
d99383df75ec5cc6213282be27adf61ee10f09f2e4d24bc00fbb5ba79d2c6486  CLT SDK/usr/share/man/man3/acl_get_entry.3
9511f84f0abe1e108e10979900d4fea8567534aef78f0984f7050c49f6c29ff7  CLT SDK/usr/include/sys/acl.h
```

CLT symlink v době čtení: `MacOSX.sdk → MacOSX27.2.sdk`. Aktivní sestavení Swift sondy
používá Xcode 27.0 (27A266a), Swift 6.4 a Xcode macOS 27.0 SDK. Tyto dvě SDK nejsou
zaměňována za runtime verzi hosta. V L4 musí environment zaznamenat přesné verze znovu.
