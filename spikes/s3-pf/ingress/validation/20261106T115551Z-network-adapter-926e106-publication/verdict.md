# WP1.C3 offline consumer validation

Source: `926e106f24f1366af103544b546ad10db58efdf0`, independent base `dd058d3f4e758ed7fdef7dc64eba1c9a34a66967`.
Historical producer source: `ba339392df85f0798ba66b9f4842735558467646`.
This is instrument validation on host arm64/macOS 27.2 (26B123), Xcode27.2 (27B52), Swift6.4.2.
No new network, identity capture, signing, pf, packet capture, system settings or user changes occurred.
Concurrent independent workers mean elapsed test/build times are not performance measurements.

- **Passed:** 60 Swift Testing functions, including unchanged50 legacy functions and10 new parameterized/standalone functions. Exact raw log is `logs/release-tests.stdout.log`.
- **Passed:** fixed projection of9 authentic producer cases and61 exact file hashes against old immutable manifest (`logs/exact-vectors.stdout.log`). Original files/manifests were not modified.
- **Passed:** 30 new offline CLI checks; exact supplied envelope, stdout and stderr for every invocation are in `network-cli/`; `summary.json` includes hashes and exit codes.
- **Passed:** 25 unchanged legacy CLI checks (`logs/legacy-cli.stdout.log`), plus diff whitespace check.
- **S3b/NET-10…12/R2/R3/L4: Neověřeno.** No gate, capture completeness, packet absence, peer authentication, bind policy or isolation pass is inferred. Host diagnostics do not become testArea evidence.

## Provenance and limitations

`inputs.json` was written before final validation. `source-manifest.json` fingerprints 47 exact source/test/fixture files used by the consumer and local common dependency.
`binary.json` fingerprints the tested Release CLI: `c72e3708968549cb14b7de3ff0d4315f335aa2a0d76dd9030f14e18adb670dd4`.
`environment.json` records versions; `results.json` records exit codes. `cleanup.json` records exclusive owned build/cache cleanup and the retained small offline binary.
The manifest covers every published file except itself. Input hashes establish consistency, not authority; identity/signature/preregistration remain externally reviewable claims.

Four signed historical C1/common positives parse without source/record problems and correlate exact169B frames and reversed tuples. Authentic adversarial journals preserve zero bytes, foreign run/nonce, malformed/partial/truncated data, repeat frames, contact limits, refused connect, and interrupted accepted contact with unknown terminal count. Exact producer paths/hashes and origin are in the committed fixture provenance.
Synthetic negative mutations are named `synthetic-*` and source origin `fixture`. Matrix/clock overlays exist only in tests and are not measured evidence. Matching raw-to-matrix occurrences remains bidirectional; unsupported wildcard/L4 prerequisites remain explicit.

## Failed development attempts retained

`development/initial-build.log`: first implementation compiled and all50 legacy tests passed.
`development/development-tests.log`: new test source failed compilation due to an ambiguous imported encoder name and Swift Testing key-path macro; qualified the encoder and used an explicit closure.
`development/development-tests-2.log`:58 functions passed, including the independently identified foreign-zero payload regression.
`development/development-tests-3.log`:59 functions ran, one synthetic wrongActor assertion failed because the existing strict matrix decoder correctly rejected the entire invalid actor/kind declaration before reconciliation. The expectation was corrected; the matrix decoder was not weakened.
`development/development-tests-4.log`:60 passed.
`development/development-tests-5.log`:60 passed after adding actual attemptStarted-to-matrix attempt matching and its missing-attempt regression.
An initial git-branch write attempt was denied by the sandbox; explicit scoped escalation then created the authorized branch and first claim commit. No auto-review action rejection or unresolved validation failure remains.

No raw/log file from a previous completed measurement was changed. Any later source correction requires a new validation record.
