# NET-08/09 — transparentní cesta a původní cíl

**Příprava / neověřená hypotéza.** Tento soubor není implementovaná privilegovaná služba ani
souhlas s jejím vystavením oblasti. Čtení `DIOCNATLOOK` bez vazby na klienta/oblast a konkrétní
živé spojení by zpřístupnilo sdílenou tabulku; obecný `/dev/pf` nebo „proveď ioctl“ endpoint
se nenavrhuje. Identitu nelze brát z UID pole dodaného klientem, ze zdrojového loopbacku,
z libovolného PID ani ze samotného interního pf tagu.

## Připravená traffic path

```text
sonda v UID oblasti, socket A:a -> kontrolovaný C:c
  -> outbound filter: user UID, přesný C:c, tag C1_run_UID, route-to lo0
  -> hypotetický opětovný vstup na lo0 se zachovaným tagem
  -> rdr: pouze tagged paket C:c -> loopback G:g
  -> brána přijme flow; dostane překládaný socket tuple, nikoli automaticky původní cíl
  -> úzký helper dotaz, ověřená identita brány + oblast + její aktuální flow
  -> kontrola NATLOOK a původního C:c proti zaregistrované operaci
  -> typed policy; vlastní upstream připojení brány ke kontrolovanému C:c
```

V4 a V6 mají oddělené [šablony](templates/transparent-v4.pf.in). Obě jsou render-only;
`load.sh` do nich nesmí přepnout. Manuální překladová delegace by potřebovala také
`rdr-anchor`, ve správné translation sekci před filteringem; samotný filter anchor
nestačí [SOURCES, M1/M2]. Nikdy nepřidávat širokou `rdr pass` výjimku jen proto, aby sonda
začala fungovat. Inbound tagged pass může změnit původní atribuci; to se měří.

## Pozdější uživatelský experiment

1. Použij jediný syntetický cíl a rozlišitelné porty C:c, G:g. Před startem zapiš původní
   čtyřici, family/protocol, UID, přesnou audit session, generaci policy, run ID a identitu
   brány. Capture na lo0 i na kontrolované protistraně; tag není běžné wire pole, takže
   přežití se dokazuje kombinací unikátního tagged pravidla, jeho counteru a cíle přijetí.
2. Parse každé šablony na konkrétním macOS buildu jako samostatný user-only krok. Syntax
   fail = neověřená konstrukce k opravě, nikoli důkaz sítě. Následný load smí uživatel
   zařadit až s vlastním záznamem předchozího stavu a přesně omezeným úklidem; automatický
   loader tuto variantu úmyslně nepřijímá. Uložit skutečný normalizovaný display, nic neodhadovat.
3. Samostatně pro v4/v6 ověř direct-deny baseline, netagged negativní pokus, tag jiného
   UID/runu, a průchod pouze správně tagovaného tuple. Host/ostatní UID mají kontrolní
   provoz beze změny. Dokumentuj, zda `lo0` není skipped a zda packet re-entry skutečně nastane.
4. Na syntetickém přijatém socketu zaznamenej `getsockname` / `getpeername`; nespojuj
   tuple z klientského JSON s libovolným socketem. Laboratorní helper musí pracovat s
   autentizovanou bránou a ověřit spojení jejího konkrétního flow s aktivní oblastí.
5. Ověř `DIOCNATLOOK` pro oba směry dotazu a obě rodiny; porovnej s **předem známým**
   C:c. Nesprávný direction, protokol, prohozené endpointy nebo neexistující state musí
   odmítnout, nikdy vrátit „alespoň nějaký“ cíl. Neprovádět brute-force přes živé host flows.
6. Po revokaci/uzavření/reuse portu nesmí starý dotaz autorizovat nový flow. Helper musí
   revalidovat generaci, stav oblasti i aktuální flow po každém async kroku. Timeout,
   ENOENT nebo neurčitý výsledek = deny a zavření obou stran, bez raw fallbacku.
7. Žádný klient oblasti nesmí přímo volat helper nebo se vydávat za bránu; test stejného
   UID/PID reuse, podvrženého UID, jiné audit session, jiného gateway procesu a replay
   lease. Code identity/audit-token/IPC konstrukce je vstup S0/S8, nikoli hotová součást C1.

## Fixture specifikace (syntetická, žádný skutečný výsledek)

[fixtures/natlook-cases.json](fixtures/natlook-cases.json) předepisuje pozitivní známý cíl,
wrong-direction, missing-state, stale-generation a forged-zone. Pole `expected` jsou
**požadavky** na budoucí měření, nejsou jeho pozorování. Byte order, verze private ABI,
struktury a dostupnost hlaviček se musí určit na cílovém buildu podle primárního zdroje a
SDK. Není zde vyrobená údajně funkční hodnota ioctl ani kopie staré struktury XNU.

Otevřené otázky: zachování tagu přes lo0; rozhodnutí `rdr` u lokálního provozu; IPv6
translation; přesná socket-owner atribuce při re-entry; NATLOOK směr/tuple/životnost;
atomická vazba na generaci flow; návratová cesta a zachování hosta; brána se samostatným
UID a autentizací. Bez doložení není NET-08/09 prošlé. I pozitivní výsledek této cesty
neřeší resolver, ICMP, ingress, staré states nebo vypnutý pf.
