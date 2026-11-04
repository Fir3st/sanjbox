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
