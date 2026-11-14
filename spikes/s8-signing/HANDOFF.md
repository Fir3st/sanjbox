# WP1.A6 — předání podpisu nové kopie uživateli

Tento postup uzavírá mezeru mezi ad-hoc builderem a ručním podpisem **nové kopie**. Původní app ani
její `artifact-manifest.json` se nemění. Nástroj nikdy nevybírá identitu, nepodepisuje skutečnou
identitou, nehledá Keychain/certifikáty a nespouští app, helper ani ServiceManagement. Personal Team
je uživatelská varianta; self-signed je podmíněná doloženým neúspěchem Personal Team. Žádný zdejší
výsledek nedokazuje tento druh identity, funkční registraci, TCC ani splnění S8.

**Předem známá hranice úklidu:** před vydáním podpisových příkazů lze nezměněnou ad-hoc kopii
odstranit zdejším manifest cleanup. `handoff --apply` nejprve zapíše, že stav registrace je neznámý,
a teprve potom vypíše použitelné příkazy. Od této chvíle cleanup odmítá i dry-run a i případ, kdy
uživatel ještě nepodepsal nebo podpis selhal. Podepsanou ani potenciálně registrovanou aplikaci
neodstraňuje. Pokračování vyžaduje budoucí přezkoumanou L2 ownership/cleanup cestu. Není tu přepínač
„věř, že není registrovaná“, převzetí starého receipt ani unregister. Kdo nyní potřebuje automatický
úklid celé zkoušky, skončí u dry-run handoffu a podpisové příkazy zatím nevydá.

## 1. Nová kopie a její plán [implementátor nebo uživatel]

Nejprve sestav vlastní disposable ad-hoc fixture podle [SERVICES.md](SERVICES.md). `S8_SOURCE`
nastav na přesné vypsané `OWN_ROOT`. `S8_COPY` je **nové** jméno ve stanoveném prefixu; jedno UUID
použij pro dry-run i následný apply. Proměnné níže neobsahují identitu ani tajemství.

```sh
S8_SOURCE=/private/tmp/sanjbox-s8-services-REPLACE_WITH_OWN_UPPERCASE_UUID
S8_COPY="/private/tmp/sanjbox-s8-signing-$(/usr/bin/uuidgen)"
python3 spikes/s8-signing/tools/signing-handoff.py prepare \
  --source "$S8_SOURCE" --destination "$S8_COPY" --profile personal-team
python3 spikes/s8-signing/tools/signing-handoff.py prepare \
  --source "$S8_SOURCE" --destination "$S8_COPY" --profile personal-team --apply
```

Dry-run ověří původní přesný manifest a ad-hoc/runtime/empty-entitlement profil, vypíše konkrétní
cestu nové kopie, soubory záznamů a čtyři podpisové cíle. Nic nevytvoří. Apply odmítne existující
cíl, vytvoří `0700` root a před kopírováním zapíše `provenance.json`: původní nepřítomnost cíle,
zdrojový root/run ID, metadata a hash původního manifestu, přesnou inventuru app a zvolenou
uživatelskou variantu. Kopíruje pouze app, nikoli build cache. Ověří nezměněný zdroj i byte shodu
kopie, vytvoří prázdný entitlement plist a vlastní `prepared-inventory.json` s inode/hash inventurou.
Původní `service-fixtures.py verify/cleanup` zůstává beze změny a dále vyžaduje svůj ad-hoc artefakt.

Pro podmíněnou druhou variantu vytvoř **jinou novou kopii**. Po zaznamenaném neúspěchu Personal Team
v uživatelském protokolu nahraď v obou prepare příkazech profil za:

```text
--profile self-signed --personal-team-failed
```

Flag zaznamenává uživatelovo potvrzení podmínky, neověřuje jeho příčinu a není výsledkem SG-04/05.
Nástroj neposkytuje tvorbu/import certifikátu ani nastavení důvěry. Pokud uživatel nemá samostatně
připravenou vhodnou identitu, podpisový krok čeká na něj; agent ji nehledá ani nevytváří.

## 2. Předání konkrétních příkazů [výhradně uživatel]

Před apply zachovej `provenance.json`, `prepared-inventory.json` a původní ad-hoc manifest ve svém
protokolu. Do inventarizovaných rootů nepřidávej logy ani skripty. Předem přijmi, že se kopie po
handoffu zachová a registrace/login/reboot/daemon experimenty jsou blokované.

```sh
python3 spikes/s8-signing/tools/signing-handoff.py handoff --root "$S8_COPY"
# Další příkaz jen po výše uvedeném review uživatelem:
python3 spikes/s8-signing/tools/signing-handoff.py handoff --root "$S8_COPY" --apply
```

První příkaz vypíše konkrétní cíle a flags bez podpisových příkazů a bez zápisu. Druhý znovu ověří
nezměněnou ad-hoc kopii, **před výstupem** vytvoří `handoff.json` a vypíše shell snippet. Uživatel si
mimo agenta sám nastaví `S8_USER_SIGNING_IDENTITY` ve svém terminálu a sám provede vypsaný snippet;
identitu neposílá agentovi. Hodnota je v každém příkazu jeden uvozovaný argument, ne shell program.
Snippet má `set -euo pipefail` a `umask 077` pro zachování privátních módů, odmítne prázdnou proměnnou a postupuje bez `--deep` zevnitř ven:

1. `S8ServiceFixture.app/Contents/MacOS/S8LaunchAgent`
2. `S8ServiceFixture.app/Contents/MacOS/S8LaunchDaemon`
3. `S8ServiceFixture.app/Contents/Library/LoginItems/S8LoginItem.app`
4. `S8ServiceFixture.app` (host jako poslední)

Každý příkaz má `--force --sign "$S8_USER_SIGNING_IDENTITY" --timestamp=none --options runtime
--entitlements EXACT_COPY/empty-entitlements.plist`. Podepisuje jen tuto novou kopii. Nepřidávej
entitlements, nepoužívej původní root ani Xcode Debug podpis s `get-task-allow`. Samotné vydání
snippet není jeho spuštění; automatika žádný `codesign --sign` nevolá. Nepřeposílej agentovi raw
výstup obsahující osobní signing údaje. Neúspěch zachová přesnou kopii, handoff i původní inventuru;
nevytvářej nový baseline a nemaž marker kvůli obejití cleanup refusal.

## 3. Statický preflight a samostatná podepsaná inventura [uživatel]

```sh
python3 spikes/s8-signing/tools/signing-handoff.py record-signed --root "$S8_COPY"
python3 spikes/s8-signing/tools/signing-handoff.py record-signed --root "$S8_COPY" --apply
```

Oba příkazy ověří každé ze čtyř míst pomocí `codesign --verify --strict --all-architectures` a
metadata `codesign -dvv --entitlements :-`. Vyžadují numerický runtime flag, nepřítomný ad-hoc flag
a prázdný entitlement dictionary. Obě jména `get-task-allow` jsou zakázaná i s hodnotou `false`;
chybějící či nečitelná metadata jsou odmítnutí. Výstup nezahrnuje Authority/TeamIdentifier ani obsah
certifikátů. Žádné extrahování certifikátů nebo čtení Keychain. Druh účtu ani důvěra k self-signed
certifikátu se tímto neověřují: report má výslovně `profileVerified=false`.

Přípustný podpisový rozdíl je omezen na čtyři Mach-O signatures a dvě `CodeResources`. Ostatní
obsah/názvy/metadata zůstávají přesně shodné; žádné přidané embedded profile nebo jiné soubory se
nepřebírají. Pro thin arm64 se porovná celý payload před koncovou `LC_CODE_SIGNATURE`, s vynulováním
jen velikosti podpisu a `__LINKEDIT` vmsize/filesize. Dataoff a všechny ostatní bytes musí zůstat.
Vmsize musí odpovídat filesize zaokrouhlené na 16 KiB. Neznámý layout je refusal, nikoli důvod rozšířit povolené změny. Tento úzký formát se musí při prvním
skutečném uživatelském podpisu ověřit; tool-stub test není důkaz kompatibility skutečné identity.

Dry-run nic nezapíše. Apply zapíše nový `signed-inventory.json` s plnými aktuálními hashi/inodes,
původním manifestem/handoffem v inventuře a čtyřmi statickými pozorováními. Staré záznamy nepřepisuje.
Opakování pouze ověří **přesně** tutéž inventuru; jakýkoli pozdější drift odmítne. Zachovej všechny
čtyři záznamy i report mimo root v uživatelském protokolu. Statický úspěch neznamená povolení ke
spuštění UI, registraci, attach, TCC ani přechod na L2.

## 4. Úklid a konflikty

`handoff`, `record-signed` a `cleanup` drží od doby před první inventurou až do dokončení operace
výhradní neblokující `flock` na otevřeném directory fd konkrétního root inode. Souběžný příkaz skončí
s `signing root busy` ještě před inventurou; po skončení prvního příkazu jej lze znovu spustit a
ověří aktuální stav pod novým zámkem. Totéž platí pro dry-run, který nevytváří žádný lockfile ani
nemění inventuru. `prepare --apply` zamkne svůj nově vytvořený root před kopírováním a drží jej až
po zápis prepared inventury. Pád procesu uvolní zámek, ale neudělá z částečné přípravy platný artefakt.
Jde o serializaci spolupracujících příkazů tohoto nástroje; ruční podpis ani cizí změny tento advisory
zámek neomezí. Uživatel proto dokončí své podpisové příkazy před `record-signed`.

**Pouze před `handoff --apply`:**

```sh
python3 spikes/s8-signing/tools/signing-handoff.py cleanup --root "$S8_COPY"
python3 spikes/s8-signing/tools/signing-handoff.py cleanup --root "$S8_COPY" --apply
python3 spikes/s8-signing/tools/signing-handoff.py cleanup --root "$S8_COPY" --apply
```

Dry-run ověří celé připravené app i manifest a vypíše přesné položky. Apply odstraní jen tuto
nezměněnou vlastní ad-hoc kopii; třetí příkaz je no-op. Původní source root má nezávislý cleanup
podle SERVICES a zůstává nedotčený. Nástroj nikdy neodvozuje `notRegistered` ze souborů či statusu.

**Po handoffu:** automatický úklid odmítne, i po přerušeném či neúspěšném podpisu. Uchovej root,
původní i nové inventury a soukromý uživatelský záznam provedených kroků. L2 musí dodat přezkoumaný
oracle vlastnictví konkrétní registrace a bezpečný unregister/process-exit/no-relaunch postup před
odstraněním app; tento balík jej nedodává. Žádný globální reset, `rm -rf`, status-based adoption,
mazání registrované app ani zařazení „ručně potvrzeno unregistered“ do manifestu.

Stejně se zachová částečná příprava bez manifestu, poškozené záznamy, změna obsahu/módu/ACL/flags,
cizí owner, hardlink/symlink, nový soubor či vyměněný inode. Zbytek po přerušeném cleanup se automaticky
nepřebírá. Vyžaduje ruční kontrolu přesných vlastních záznamů; není zde crash-atomicity ani ochrana
proti plně kompromitovanému témuž UID. Vývojové testy smějí odstranit své právě vytvořené syntetické
fixtures ve vlastním teardownu; to není uživatelská výjimka z post-handoff cleanup politiky.

H1 fuzzer a syntetický host-only/restart workflow jsou v [navazujícím A6 balíku](A6-H1-FOLLOWUP.md)
mimo tento podpisový postup; skutečná host-only autorizace, service ownership, unregister přes
restart UI, login/reboot a všechny daemon mutace zůstávají blokované. A6 jako celek zůstává částečné; A7/L2 ani S8 se
neuzavírají. Testy a CI rozsah jsou v [VALIDATION.md](VALIDATION.md).
