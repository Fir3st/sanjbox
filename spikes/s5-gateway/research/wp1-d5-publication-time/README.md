# WP1.D5 — čas publikace přesné Homebrew bottle

**Výsledek (2026-11-08): použitelný kontrakt důvěryhodného času publikace přesné bottle nebyl
v posouzených oficiálních rozhraních prokázán.** Nejde o tvrzení, že takový zdroj obecně neexistuje.
GitHub Packages má nadějného kandidáta (`created_at` registry version); v tomto veřejném průzkumu
chybí úspěšný záznam pro vybraný digest a doložená publikační sémantika. Commit date ani OCI
`created` tento nedostatek neřeší. Rešerše zde končí; D5 se tím automaticky neoznačuje za hotové.

[PLAN §4](../../../../PLAN.md) vyžaduje důvěryhodná metadata před každým vydáním artefaktu,
[S6](../../../../PLAN.md#s6--homebrew-per-oblast) ponechává změnu cooldownu uživateli.
[Starší D5](../wp1-d5/README.md) ponechalo GHCR neměřené;
[E1](../../../s6-brew/README.md#cooldown) našlo neznámý čas u 398 uložených záznamů, nikoli
univerzální neexistenci zdroje. Tato práce doplňuje pouze zdroje a jednu veřejnou metadata sondu.
Neimplementuje provider, nevydává bottle a nedokazuje S5, HB-04 ani S6.

## Rozlišení hodin a identity

| Kandidát | Kdo údaj vytváří a co znamená | Výsledek pro požadovaný kontrakt |
|---|---|---|
| Datum commitu formule obsahujícího digest | Autor/committer Git objektu; data lze zadat přes `GIT_AUTHOR_DATE` / `GIT_COMMITTER_DATE`. Vazba obsahu commitu na digest je užitečná, čas není receipt registru. | Nezaměnit s uploadem ani veřejným zpřístupněním bottle. Ani podepsaný commit sám tuto sémantiku nepřidává. |
| Packages REST `created_at` / `updated_at` | GitHub vrací pole záznamu **package version**, v container příkladu s `name: sha256:…` a seznamem tags. To je jiný údaj než anotace dodaná vydavatelem v OCI. | Kandidát na důvěru v hodiny registru. Je nutné zjistit, **čeho** je digest a co čas znamená při republish, obnovení nebo změně visibility; samotný název pole nestačí. |
| OCI index/manifest `org.opencontainers.image.created` | Podle OCI datum sestavení; Homebrew ho plní z lokálního mtime bottle souboru. Hodnota je součástí publisherem vytvořených bytes. | Hash ji sváže s metadaty, nikoli s pravdivým časem publikace. Může předcházet uploadu a může být zachována při změně indexu. |
| OCI config `created`, případně `history[].created` | Volitelný údaj tvůrce obrazu/vrstvy, nikoli registry receipt. | Vybraný config jej nemá; ani případná přítomnost by sama neprokázala publikaci. |
| HTTP `Date`, katalogové `Last-Modified`, lokální first-seen | Čas HTTP odpovědi/katalogu nebo pozorování bránou. | Neoznačovat za publikaci. Trvalá karanténa podle first-seen by byla samostatně schválený kontrakt, nikoli zjištěný datum publikace. |

Primární opora: [Git prostředí, pin v2.54.0](https://github.com/git/git/blob/94f057755b7941b321fd11fec1b2e3ca5313a4e0/Documentation/git.adoc#L615),
[Packages REST, verze 2026-03-10](https://docs.github.com/en/rest/packages/packages?apiVersion=2026-03-10#get-a-package-version-for-an-organization),
[OCI annotations v1.1.1](https://github.com/opencontainers/image-spec/blob/v1.1.1/annotations.md#L22),
[OCI config v1.1.1](https://github.com/opencontainers/image-spec/blob/v1.1.1/config.md#L95).
Piny, umístění, velikosti a SHA-256 přečtených zdrojů jsou v [sources.json](sources.json).
API version v URL nezmrazí HTML dokumentace; [review z 2026-11-13](VALIDATION.md#review-2026-11-13)
odděluje její změněné bytes od 11 přesně znovu ověřených zdrojů kódu/specifikací.

## Co přesně publikuje Homebrew

Posouzený `Homebrew/brew` je stejný pin jako v E1/D5: `8b0b7e44193854e22b84bcf2f58d65f21408d458`.
Workflow `Homebrew/homebrew-core` je připnutý k E1 tap snapshotu
`5c4fe351541e0aa5d426937c5badf6da8630c109`. Jde o čtení těchto verzí, ne důkaz všech historických
či budoucích uploadů ani o připsání tohoto workflow konkrétnímu zářijovému buildu.

1. [`bottle.rb`](https://github.com/Homebrew/brew/blob/8b0b7e44193854e22b84bcf2f58d65f21408d458/Library/Homebrew/dev-cmd/bottle.rb#L738)
   zapisuje do bottle JSON `date` z `Pathname(filename.to_s).mtime.utc.iso8601`.
   [`github_packages.rb`](https://github.com/Homebrew/brew/blob/8b0b7e44193854e22b84bcf2f58d65f21408d458/Library/Homebrew/github_packages.rb#L241)
   přenáší tento údaj do anotací. Hodiny vlastní build/publishing prostředí a souborový metadata stav;
   GHCR při uložení OCI obsahu nepotvrzuje jejich správnost.
2. [`pr-upload`](https://github.com/Homebrew/brew/blob/8b0b7e44193854e22b84bcf2f58d65f21408d458/Library/Homebrew/dev-cmd/pr-upload.rb#L58)
   nejdřív volá `bottle --merge --write` (které standardně vytvoří bottle commit), poté uploader.
   [Workflow](https://github.com/Homebrew/homebrew-core/blob/5c4fe351541e0aa5d426937c5badf6da8630c109/.github/workflows/publish-commit-bottles.yml#L389)
   provádí upload před pushnutím commitů. **Odvození:** i správný datum commitu s konkrétním hashem
   může předcházet úspěšné publikaci; čekání/opakování uploadu nemá doloženou maximální délku.
   Datum push/merge není totéž co datum uložené v Git objektu.
3. [`--keep-old`](https://github.com/Homebrew/brew/blob/8b0b7e44193854e22b84bcf2f58d65f21408d458/Library/Homebrew/github_packages.rb#L242)
   převezme anotace i manifesty dosavadního indexu a přidá nový platformní manifest.
   Tentýž version/rebuild tag tedy může dostat nový digest indexu a ponechat staré `created`.
   Nový platformní manifest dostane svůj `created`; staré vrstvy se znovu nestávají novými bytes.
   Běžný uploader odmítá již existující tag bez `keep_old` i duplicitní platformní ref v indexu;
   tato kontrola není registry záruka neměnnosti všech tagů nebo zákaz jiných publisherů.
4. [Rebuild](https://github.com/Homebrew/brew/blob/8b0b7e44193854e22b84bcf2f58d65f21408d458/docs/Bottles.md#L80)
   mění bottle bez nutné změny formula version/revision. Registry tag vzniká z `pkg_version`
   a rebuild; platformní ref přidává bottle tag. Samotné `hello 2.12.3`, tag registry nebo
   stáří jiné platformy proto není úplná identita.

[OCI Distribution v1.1.0](https://github.com/opencontainers/distribution-spec/blob/v1.1.0/spec.md#pulling-manifests)
rozlišuje index/manifest, config a blob; načtení a seznam tagů v posouzených sekcích nedefinují
povinné datum publikace jednotlivé bottle. Registry ukládá manifest jako bytes od klienta.
To nevylučuje vlastní metadata GitHubu mimo OCI Distribution.

## Jedna konkrétní metadata sonda

Východiskem je existující E1 snapshot: `homebrew/core/hello`, stable **2.12.3**, formula revision
**0**, bottle rebuild **1**, **arm64_golden_gate** (arm64 / darwin / macOS 27).
[Formule na připnutém tap commitu](https://github.com/Homebrew/homebrew-core/blob/5c4fe351541e0aa5d426937c5badf6da8630c109/Formula/h/hello.rb#L8)
obsahuje přesný bottle hash; SHA-256 jejího textu odpovídá E1 `ruby_source_checksum`.
Nevyhodnocovali jsme Ruby. Pětizáznamový dotaz na historii formule skončil HTTP 504, takže zde
netvrdíme nález prvního commitu, který hash zavedl, ani jeho času; výše uvedený problém s hodinami
commitu na tomto dotazu nezávisí.

| Úroveň | Identita a zjištění |
|---|---|
| Package version ID / `name` v Packages REST | **Nezískáno.** Dokumentační příklad není záznam pro `hello`. Digest z tohoto pole by bylo nutné porovnat s načtenými bytes a jejich media type; nelze předem zaměnit za bottle hash. |
| Tag `2.12.3-1` → OCI index | `sha256:c847599789efade500c448e8b302fc9a3f985e1e4370e91b339b839b2205d984`; 6 manifest descriptors, `created=2026-09-02T12:52:55Z`. Po zjištění tagu byl znovu načten přes digest. |
| Vybraný platformní manifest | `sha256:f332d571111252e2a27610a7cf85a2533fd5d4eee4217dfd63b34fbe74a7f190`; ref `2.12.3.arm64_golden_gate.1`, `created=2026-09-12T07:07:25Z`. |
| Config | `sha256:6b03147913bfa292b8f3366d1f19ae9cdb5e04c056ea2d864dad0f25438356f4`; 220 bytes, bez `created`; `rootfs.diff_ids` popisuje nekomprimovanou vrstvu, nikoli hash `.tar.gz`. |
| Bottle blob / jediná manifest layer | `sha256:4dd2596c2e897c81eae2dbf5030da37b43e797d217f0f0892d39343d0b8c2ca7`; deklarovaná velikost 54 641 bytes, shoda s E1, formulí a `sh.brew.bottle.digest`. **Payload nebyl stažen**, skutečný hash payloadu zde není přeměřen. |

Uložených [18 880 bytes metadat](metadata/) je původní index, vybraný manifest a config.
SHA-256 všech tří bytes odpovídá adresovanému digestu; descriptor sizes a platform/ref jsou
zkontrolované. V indexu je starší datum než ve vybraném manifestu. Navíc anotace `image.revision`
ukazuje na [`29209e1…`](https://github.com/Homebrew/homebrew-core/blob/29209e1690e20fc7ef2211d24e7d61ce27b087e3/Formula/h/hello.rb),
kde nový golden_gate digest ani rebuild 1 ještě není. Anotace source revision tedy zde není
commit obsahující vybranou bottle. Tento rozdíl je pozorování bytes, nikoli prokázaný log uploadu.

**Sémantický protipříklad:** při hypotetickém sedmidenním cooldownu dne 2026-09-15 by použití
indexového `created` dalo stáří přes 12 dní, přestože vybraný manifest uvádí 12. září.
Ani čas manifestu není schváleným časem publikace. Stejně tak metadata-only republish může změnit
manifest/index digest bez změny bottle bytes; při změně bytes naopak starý datum jiného digestu
nesmí autorizovat nový payload.

## GitHub Packages: kandidát a přesná mez zjištění

Oficiální REST dokumentace nabízí seznam a detail verzí s `created_at`, `updated_at`, numeric ID,
container digest name a tags. Pro classic/OAuth token uvádí `read:packages`; dokumentuje také
GitHub App tokeny. [Veřejné container images lze číst anonymně](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry#about-the-container-registry),
což ale samo nezaručuje anonymní čtení Packages REST. Sonda použila pouze veřejný anonymní GHCR
pull bearer vydaný bez účtu; token nebyl uložen. Žádný `gh` credential ani osobní token se nepoužil.

[requests.json](requests.json) zaznamenává dva GETy na správně escapovaný
`/orgs/Homebrew/packages/container/core%2Fhello/versions?per_page=1`: **500** s API verzí
2022-11-28 a **504** při jediném opakování s 2026-03-10. Nevrátily version data; tyto statusy
neprokazují požadavek autentizace, neexistenci timestampu ani dlouhodobou nedostupnost služby.
Obě posouzené URL veřejné package stránky pro `hello` skončily timeoutem. Veřejná oficiální
[UI jiného balíku ukazuje „Published“ a digest](https://github.com/Homebrew/homebrew-core/pkgs/container/core%2Fcurl/versions);
nesmíme ji přehlédnout ani její datum přenést na `hello`. Přesná vazba UI času na tento vzorek
proto také není prokázána.

**Co by kontrakt s registry časem musel určit:** důvěru v GitHub jako časovou autoritu; vazbu
registry version record → index nebo platformní manifest → přesnou bottle layer, vždy v namespace
Homebrew; zda `created_at` znamená první upload, veřejné zpřístupnění nebo událost jiné životní fáze;
a chování při republish/restore, znovupoužití tagu, přidání platformy a změně visibility.
`updated_at` nelze bez pravidla přejmenovat na publikaci. Pozdější čas nového indexu by mohl
konzervativně prodloužit karanténu staré bottle, **pokud** by jeho událost byla důvěryhodně určena;
takové pravidlo zde není přijato. Schéma a úspěšné ověření digestu samy tyto volby neřeší.

Autentizovaný Packages API provider by byl nové rozhodnutí o přístupu a scopes:
[F0.7](../../../../docs/DECISIONS.md#rozhodnuté-podotázky) povoluje stávající classic token v bráně
jen pro git smart HTTP projektu. Tento průzkum jeho působnost nerozšiřuje.

## Zbývající rozhodnutí a pokrytí

**Doporučení:** zachovat původní cooldown a Homebrew bottle s neprokázaným publication time
nadále odmítat. Bounded rozhodnutí uživatele je, zda toto omezení podpory Homebrew přijímá,
nebo výslovně mění kontrakt v DECISIONS (např. konkrétní first-seen karanténa či výjimka pro brew,
s výslovným dopadem na HB-04/S5). Žádná z těchto změn zde není schválena.

Pokud uživatel místo změny požadavku zvolí novou důvěryhodnou autoritu, další práce má být samostatně
vymezený provider kontrakt s výše uvedenou identitou/událostí a povoleným přístupem, nikoli další
neomezené pokračování této rešerše. Současný výsledek není důkaz neexistence všech možných zdrojů.

Vzorek nepokrývá všech 200 formulí, další platformy, staré/rebuild varianty, tapy, casky, source
archivy ani resources. Budoucí provider musí zachovat kontrolu při direct URL, redirect/CDN i cache
brány a odmítat neznámou či rozpornou vazbu/čas. Už existující klientská cache/importovaný kód
zůstává mimo důkaz síťového cooldownu. Žádné runtime ani bezpečnostní verdict řádky se touto
rešerší nemění. [VALIDATION.md](VALIDATION.md) obsahuje pouze lokální ověření tohoto výstupu.
