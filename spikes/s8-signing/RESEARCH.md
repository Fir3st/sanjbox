# S8 — primární opory a hranice tvrzení

Ověřeno 2026-11-03 v Apple dokumentaci a lokálním Apple SDK/man pages. Jde o podklady pro přípravu,
nikoli o verdikt brány. Výsledky příkazů na vlastních fixtures jsou oddělené ve [VALIDATION](VALIDATION.md).

| Zdroj | Co z něj používáme | Co nedokazuje |
|---|---|---|
| [Apple: Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime) | Runtime omezuje vybrané injekční a paměťové operace; jednotlivé exceptions ochrany oslabují. Pro fixture profil proto nejsou povolené žádné entitlementy. | Samotný runtime bit není důkaz nepřevzetí TCC ani celé R2 hranice. |
| [Apple: Resolving common notarization issues](https://developer.apple.com/documentation/security/resolving-common-notarization-issues) | Debug workflow může vložit `com.apple.security.get-task-allow`; důležitý je skutečný podpis výsledné binárky. Apple uvádí `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO` a runtime signing option. | Tato příprava nic neposílá k notarizaci a nevyžaduje placený účet. |
| [Apple: Debugging tool entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.debugger) | Získání task portu závisí i na debugger/target entitlements a autorizaci. Dokumentace popisuje možný admin dialog pro non-root debugger. | Pouhá odmítnutá attach operace bez srovnatelné pozitivní kontroly nedokazuje runtime ochranu. Z tohoto balíčku se attach ani autorizační dialog nevyvolává. |
| [Apple: SecStaticCodeCheckValidity](https://developer.apple.com/documentation/security/secstaticcodecheckvalidity(_:_:_:)) | Platnost je podmíněna neměnností kódu. All-architectures kontroluje všechny slices, ale nemusí mít stejného signera. | Statická validita není běžící peer identity ani atomická TOCTOU ochrana. Proto pouze vlastní quiescent thin arm64 fixtures. |
| [Apple: Static Code Validation Flags](https://developer.apple.com/documentation/security/static-code-validation-flags) | `CheckAllArchitectures`, `StrictValidate`; nepoužíváme vynechání executable/resources. | Strict validation nenahrazuje vlastní požadavek na runtime/entitlements ani běhový test. |
| [Apple: kSecCodeInfoEntitlementsDict](https://developer.apple.com/documentation/security/kseccodeinfoentitlementsdict) | Absence dictionary může znamenat absenci entitlements **nebo jiný formát**. Při přítomném raw blobu zůstává stav unknown. | Není dovoleno automaticky zaměnit chybějící dictionary za bezpečnou absenci. |
| [Apple: SecCSFlags](https://developer.apple.com/documentation/security/seccsflags) a SDK `CSCommon.h` | Používáme definovaný `noNetworkAccess`; lokální header vysvětluje vynechání online revocation/notarization práce. | Žádný výsledek zde není online trust/revocation/notarization hodnocení. |
| [Apple: SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice) | API rozlišuje LoginItems, LaunchAgents, LaunchDaemons v containing app. | Není zde záruka funkčnosti všech kombinací s Personal Team či self-signed. |
| [Apple: register()](https://developer.apple.com/documentation/servicemanagement/smappservice/register()) | LoginItem startuje ihned a při loginu, LaunchAgent se bootstrapuje a registruje per uživatel. LaunchDaemon čeká na admin approval a pak bootstrapuje při bootu. | Nesmíme přenést požadavek admin approval z daemonu na všechny služby. Registrace také nedokazuje bezpečný lifecycle vypnuté oblasti. |
| [Apple: TN3125 — Provisioning Profiles](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles) | Některé macOS entitlementy včetně get-task-allow/runtime nejsou vázané na provisioning profile. | Z toho nevyplývá dostatečnost Personal Team pro SMAppService, stabilní TCC ani bezpečnost libovolné entitlement kombinace. |

Lokální doplňující zdroje (Apple distribution, nikoli neoficiální mirror):

- `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/Security.framework/Headers/CSCommon.h`:
  `SecCodeSignatureFlags`, runtime `0x10000`, adhoc `0x2`, význam no-network flagu. Swift API používá
  `.runtime`, `.adhoc`, `.noNetworkAccess` místo C enumerator názvů.
- Stejný framework, `SecCode.h` a `SecStaticCode.h`: signing information, raw/dictionary entitlements,
  validace sealed components a omezení při souběžné modifikaci. Neměníme společný probe balíček.
- `man 3 acl_get_fd`, `man 3 acl_get_entry`, SDK `usr/include/sys/acl.h`: čtení extended ACL,
  návratové hodnoty a uvolnění alokace. Lokálně na macOS 27.2 ověřeno, že otevřený platný fd bez
  extended ACL vrací `ENOENT`; ostatní chyby se odmítají. Prázdný ACL objekt má neúspěšný první entry.
- `man 1 codesign`: `--sign -` je ad-hoc, `--timestamp=none` nepoptává timestamp službu.
  Žádný signing identity lookup, klíč či certifikát se při této přípravě nečte.

**Odvozené návrhové rozhodnutí:** ad-hoc je lokální syntetická kontrola integrity; není třetí cestou
splnění F0.5. Mock `.approvedFixture` je pouze vstup oracle, nikdy závěr z podpisu dodaného klientem.
Ani shoda bundle identifieru, UID nebo session jednotlivě nenahrazuje budoucí autentizaci brokeru.
Nejsou dostupné Contracts, Broker ani SessionAgent, a tedy zatím nelze připravit skutečný transportní
fuzzer proti definitivnímu schématu. Tyto mezery ponechávají A6 částečné a A7/L2 neprovedené.

## Doplnění service fixtures, 2026-11-04

Apple web stránky `SMAppService`/`register()` byly znovu otevřeny; automatický Markdown fetch
neposkytl tělo, takže přesná implementační kontrola používá lokální Apple SDK
`ServiceManagement.framework/Headers/SMAppService.h` (SDK přes `xcrun --show-sdk-path`).
Header rozlišuje `loginItem(identifier:)`, `agent(plistName:)`, `daemon(plistName:)`, relativní
`BundleProgram`, samostatné admin approval daemonu a stav `notRegistered/enabled/requiresApproval/notFound`.
Popis unregister výslovně nevydává návrat API za potvrzení zániku procesu. Pro daemon boot doporučuje
containing app dostupnou před loginem (`/Applications`). Nic z toho není lokální lifecycle měření.

Návrhové důsledky v [SERVICES.md](SERVICES.md): tři vlastní executable targets a dva samostatné plisty,
žádný obecný dispatch; žádná daemon mutace bez host-only approval konstrukce. Uživatelské UI omezuje
unregister na vlastní právě proběhlou registraci v téže session; běžný service status není vlastní
registration generation. Receipt po restartu není trust ani oprávnění k novému unregister.
Sealed run ID je korelace evidence, nikdy autorizace. Statické codesign kontroly nelze zaměnit za
TCC stabilitu, identitu živého XPC peeru nebo same-UID attach oracle.

## Native recovery feasibility, 2026-11-14

Aktuální Apple SDK macOS 27.2 (`xcrun --show-sdk-path`) byl znovu přečten; jde o primární
API kontrakt, nikoli živý výsledek služby. `ServiceManagement.framework/Headers/SMAppService.h`
má SHA-256 `859ec2a7c4471dc1ac1e36b4de67e76d0a62ce4e4d145c942fd80cc4c2d8f8ff` a
`Security.framework/Headers/SecCode.h`
`293ccef2de6c872a4f5a4862a74bf96a9ade0f897f898813cd33e8e1d00459c4`.

- [SMAppService status](https://developer.apple.com/documentation/servicemanagement/smappservice/3945414-status)
  a SDK poskytují čtyři registrační/autorizační stavy, ne registration generation. **Odvození:**
  shodný status a vlastní journal nestačí k doložení kontinuity konkrétní registrace. Native
  recovery proto nepovoluje unregister po zániku původní živé instance.
- [Apple helper migration](https://developer.apple.com/documentation/servicemanagement/updating-helper-executables-from-earlier-versions-of-macos)
  odděluje admin autorizaci daemonu. SDK navíc uvádí notarization pro containing app a dostupnost
  před loginem pro boot. Nejde o doklad funkčnosti Personal Team/self-signed ani o souhlas ke
  změně projektové politiky bez placeného účtu. Tato kompatibilita zůstává neověřená.
- [Guest attribute keys](https://developer.apple.com/documentation/security/guest-attribute-dictionary-keys)
  a [SecCodeCopyGuestWithAttributes](https://developer.apple.com/documentation/security/seccodecopyguestwithattributes(_:_:_:_:))
  podporují audit-token výběr živého kódu; header vystavuje `kSecGuestAttributeAudit`. Důvěryhodný
  token musí přijít z OS transportu a approval ze samostatné host/admin autority. Aktuální
  one-shot daemon nemá takový transport ani approval issuer, takže nativní mutace zůstává vypnutá.
- [Debugging tool entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.debugger)
  znovu ověřeno: debugger entitlement sám neznamená univerzální task-port přístup; non-root
  použití může vyžadovat admin dialog. Za současných omezení nemáme srovnatelnou povolenou
  pozitivní attach kontrolu bez `get-task-allow`. To je konkrétní chybějící důkaz, ne tvrzení,
  že žádná jiná podporovaná konfigurace nemůže existovat. Žádný attach ani dialog neběžel.

`sys/proc_info.h`/`libproc.h` definují `PROC_PIDTBSDINFO` a process start time; `sysctl.h` a
`bsm/audit.h` poskytují boot/audit identity. Native journal je čte jen pro vlastní proces.
`fsync` a `fcntl(F_FULLFSYNC)` jsou skutečné durability requests, ne zde měřená odolnost proti
výpadku napájení. Storage testy a omezení: [NATIVE-RECOVERY](NATIVE-RECOVERY.md).
