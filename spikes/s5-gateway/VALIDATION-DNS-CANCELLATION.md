# D1 — regrese cancellation a timeoutu DNS, 2026-11-13

Oprava mění pouze testy. `boundedIO`, `IOResult`, `SystemDestinationResolver` i produkční
DNS timeout 5 s zůstávají beze změny. První dokončený výsledek je závazný: pozdější
cancellation nesmí přepsat skutečný timeout.

## Pozorovaný CI failure a příčina

[Main CI run 43465662284, Release job 132024057539](https://github.com/Fir3st/sanjbox/actions/runs/43465662284/job/132024057539)
testoval commit `99dc1da162eafe4b89eae8dd331d87182298f2a8`. Sada měla 104 testů a jednu
chybu: `cancelledDNSCallerDoesNotWaitForBlockingLookup` na `SystemAddressTests.swift:73`
očekával `CancellationError`, ale dostal `UpstreamFailure.timedOut`; test skončil za
2,320 s. `systemLookupAndSnapshotFailuresArePropagated` skončil za 2,319 s.

Cancellation fixture měla timeout 2 s. Po spuštění lookupu se test musel znovu naplánovat
z `AsyncStream.next()` a teprve potom volal `task.cancel()`. `IOResult.finish` pod zámkem
uchová první výsledek, takže pozorovaný timeout už při cancellation vyhrál. Log neurčuje,
kolik zdržení připadlo na spuštění workeru a kolik na obnovení testu. Obojí může porušit
původní předpoklad, že se test na zatíženém runneru dostane ke zrušení do 2 s.

## Změna a oracle

- Cancellation fixture používá 30s pojistný timeout, stejně jako existující test
  propagace lookup failure. Nadále čeká na skutečné spuštění lookupu a vyžaduje
  `CancellationError` před uvolněním blokujícího workeru.
- Obě DNS fixtures drží worker přes semaphore až do výslovného uvolnění testem;
  odstraněná automatická 5s propustka už nemůže závodit s kontrolou `.busy`.
  `defer` vždy uvolní worker; CI má navíc procesní watchdog 300 s.
- `dnsTimeoutRetainsBoundedWorkerUntilLibcReturns` zachovává skutečný timeout **100 ms**
  a vyžaduje `.timedOut`, potom `.busy` při stále zablokovaném workeru.
- Nový `boundedIOCancellationBeforeCompletionDiscardsLateSuccess` zruší aktuální
  task synchronně uvnitř start callbacku, po instalaci cancellation handleru, a potom
  dodá úspěch. Musí vyhrát `CancellationError`.
- Nový `boundedIOCommittedTimeoutIsNotReplacedByLaterCancellation` ve stejném callbacku
  nejprve potvrdí `.timedOut`, potom synchronně zruší task a dodá pozdní úspěch.
  Musí zůstat `.timedOut`. Tento test záměrně injektuje výsledek timeoutu; skutečný
  časovač pokrývá samostatná DNS regrese výše. Pořadí nových testů nezávisí na probuzení
  druhého tasku ani na krátkém sleepu.

## Lokální validace

Základ větve: `c334ef75c20067dc19405bf3b93fc991a6807595`. Prostředí: macOS 27.2.1
(`26B131`), arm64, Xcode 27.2 (`27B52`), Apple Swift 6.4.2 (`swiftlang-6.4.2.1.9`),
Swift Testing 2403. Přesné otisky testovaných souborů a výpis výsledků jsou v
[adresáři validace](validation/dns-cancellation/20261113/).

| Konfigurace | Cílené čtyři regrese | Celá sada |
|---|---|---|
| Debug | build + 25 opakování, pokaždé 4/4 | 3× 106/106; 2,048 / 2,053 / 2,174 s |
| Release | build + 25 opakování, pokaždé 4/4 | 3× 106/106; 2,042 / 2,046 / 2,047 s |

Všech **58 příkazů skončilo exit 0**, žádný test nebyl přeskočen. Časy jsou výpisem
Swift Testing, nezahrnují build ani obsluhu watchdogu. [summary.txt](validation/dns-cancellation/20261113/summary.txt)
obsahuje extrahovaný výsledek každého příkazu; plné neupravené lokální logy a skutečné
příkazy zůstaly v `/private/tmp/sanjbox-dns-cancellation.3WQifv/`. Před touto zaznamenanou
sekvencí prošel ještě jeden prvotní Debug build se stejnými čtyřmi cílenými testy.
`git diff --check` prošel. Závislé balíčky `proto/gateway` a `spikes/s5-fixtures`
nebyly lokálně opakovány; produkční zdroje ani jejich rozhraní se nemění.

Reprodukce z kořene repozitáře s novým vlastním scratch adresářem:

```sh
set -eu
DNS_CHECK_DIR=$(mktemp -d /private/tmp/sanjbox-dns-cancellation.XXXXXX)
export CLANG_MODULE_CACHE_PATH="$DNS_CHECK_DIR/modules"
for configuration in debug release; do
  .github/scripts/run-with-watchdog.sh 300 "$DNS_CHECK_DIR/watchdog" \
    swift test --package-path spikes/s5-gateway --configuration "$configuration" \
      --scratch-path "$DNS_CHECK_DIR/build" --cache-path "$DNS_CHECK_DIR/cache" \
      --disable-sandbox --filter 'boundedIO|cancelledDNS|dnsTimeout'
  for iteration in $(seq 1 25); do
    .github/scripts/run-with-watchdog.sh 300 "$DNS_CHECK_DIR/watchdog" \
      swift test --package-path spikes/s5-gateway --configuration "$configuration" \
      --scratch-path "$DNS_CHECK_DIR/build" --cache-path "$DNS_CHECK_DIR/cache" \
      --disable-sandbox --skip-build --filter 'boundedIO|cancelledDNS|dnsTimeout'
  done
  for iteration in $(seq 1 3); do
    .github/scripts/run-with-watchdog.sh 300 "$DNS_CHECK_DIR/watchdog" \
      swift test --package-path spikes/s5-gateway --configuration "$configuration" \
      --scratch-path "$DNS_CHECK_DIR/build" --cache-path "$DNS_CHECK_DIR/cache" \
      --disable-sandbox --skip-build
  done
done
```

Jde o lokální vývojové fixtures, nikoli nový CI výsledek nebo měření veřejného DNS.
Opakování nezaručuje plánování na libovolně přetíženém stroji. Přesné pořadí dvou nových
regresí je vynucené synchronními callbacky; DNS integrační test má nadále konečný pojistný
timeout. S5 a ostatní laboratorní brány touto změnou nezískávají nový verdikt.
