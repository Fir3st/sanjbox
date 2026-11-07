#!/usr/bin/env python3
"""Bounded offline link checks. No live probe, identity capture or external file references.
Optional --output creates a NEW immutable result directory; existing output is refused.
"""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('binary', type=Path)
parser.add_argument('--output', type=Path)
args = parser.parse_args()
binary = args.binary.resolve(strict=True)
if args.output:
    args.output.mkdir(parents=False, exist_ok=False)
fixtures = Path(__file__).resolve().parents[1] / 'Tests/IngressKitTests/Fixtures'
vectors = json.loads((fixtures / 'network-producer-vectors.json').read_bytes())
results = []

def run(name, value, reject=False):
    raw = value if isinstance(value, bytes) else (json.dumps(value, sort_keys=True) + '\n').encode()
    result = subprocess.run([str(binary), 'link'], input=raw, capture_output=True, timeout=5)
    if args.output:
        for suffix, data in [('input.json', raw), ('stdout.json', result.stdout), ('stderr.txt', result.stderr)]:
            (args.output / f'{name}.{suffix}').write_bytes(data)
    assert result.returncode == (2 if reject else 0), (name, result.returncode, result.stderr)
    report = None if reject else json.loads(result.stdout)
    if reject:
        assert not result.stdout
    else:
        assert report['externalReviewRequired'] and not report['packetAbsenceProven']
        assert all(cell['classification'] != 'passed' for cell in report['matrix']['cells'])
    results.append(dict(name=name, returncode=result.returncode, inputSHA256=hashlib.sha256(raw).hexdigest(), stdoutSHA256=hashlib.sha256(result.stdout).hexdigest(), stderrSHA256=hashlib.sha256(result.stderr).hexdigest()))
    return report

for name, value in sorted(vectors.items()):
    r = run(name, value)
    expected = {'contact-limit': 4, 'interrupted-prefix': 1, 'refused-connect': 0, 'tcp-adversarial': 6, 'udp-adversarial': 14}.get(name, 2)
    assert len(r['findings']) == expected, name
    if name in ('tcp-v4', 'tcp-v6', 'udp-v4', 'udp-v6'):
        assert all(not s['problems'] and all(not row['problems'] for row in s['network']['records']) for s in r['sources']), name
        assert any('exact independently supplied receiver bytes' in c for c in r['links'][0]['checks'])
        assert any('hostDiagnostic' in c for c in r['links'][0]['missingBindings'])
    else:
        assert any(s['problems'] for s in r['sources']), name
    if name == 'interrupted-prefix':
        assert 'bytes' not in r['findings'][0]
    if name == 'udp-adversarial':
        assert any('repeated' in f.get('payloadDisposition', '') for f in r['findings'])
        assert any('foreign' in f.get('payloadDisposition', '') for f in r['findings'])

for mutation in ('missing-ending', 'missing-stop', 'gap', 'duplicate-sequence', 'unknown', 'null', 'malformed', 'tuple', 'count', 'raw-missing', 'raw-hash', 'raw-path', 'input-hash', 'replay', 'cross-run', 'instance-alias', 'legacy-mix'):
    value = copy.deepcopy(vectors['tcp-v4'])
    for source in value['sources']:
        source['origin'] = 'fixture'
    receiver = next(s for s in value['sources'] if s['id'] == 'receiver')
    rows = [json.loads(line) for line in receiver['text'].splitlines()]
    if mutation == 'missing-ending': rows.pop(3)
    elif mutation == 'missing-stop': rows.pop()
    elif mutation == 'gap': rows[3]['sequence'] = 99
    elif mutation == 'duplicate-sequence': rows[3]['sequence'] = 3
    elif mutation == 'unknown': rows[3]['newUnknownKey'] = True
    elif mutation == 'null': rows[3]['payloadClaims'] = None
    elif mutation == 'tuple': rows[3]['remote']['port'] = 12345
    elif mutation == 'count': rows[3]['bytes'] = 0
    elif mutation == 'raw-missing': receiver['artifacts'] = [a for a in receiver['artifacts'] if a['name'] != 'received-1.bin']
    elif mutation in ('raw-hash', 'raw-path'):
        artifact = next(a for a in receiver['artifacts'] if a['name'] == 'received-1.bin')
        artifact['sha256' if mutation == 'raw-hash' else 'name'] = '0' * 64 if mutation == 'raw-hash' else '/private/tmp/never-open.bin'
    elif mutation == 'input-hash': rows[0]['expectationSHA256'] = '0' * 64
    elif mutation == 'replay': rows[3]['repeatedRegisteredPayload'] = True
    elif mutation == 'cross-run': value['runID'] = '11111111-1111-4111-8111-111111111111'
    elif mutation == 'instance-alias':
        alias = copy.deepcopy(receiver); alias['id'] = 'receiver-alias'; value['sources'].append(alias)
    elif mutation == 'legacy-mix': value['bindings'][0]['sender'] = dict(sourceID='sender', line=1)
    receiver['text'] = ''.join(json.dumps(row, sort_keys=True) + '\n' for row in rows)
    if mutation == 'malformed':
        lines = receiver['text'].splitlines(); lines[3] = '{broken'; receiver['text'] = '\n'.join(lines) + '\n'
    r = run('synthetic-' + mutation, value)
    assert any(f['kind'] == 'accepted' for f in r['findings']), mutation
    assert r['links'][0]['status'] == 'conflictingOrIncompleteLink'
    if mutation not in ('cross-run', 'legacy-mix'):
        assert any(s['problems'] or any(row['problems'] for row in s['network']['records']) for s in r['sources']), mutation

for mutation in ('null-binding', 'unknown-binding', 'legacy-artifacts', 'outer-duplicate'):
    value = copy.deepcopy(vectors['tcp-v4'])
    if mutation == 'null-binding': value['bindings'][0]['network'] = None
    elif mutation == 'unknown-binding': value['bindings'][0]['network']['path'] = '/never-open'
    elif mutation == 'legacy-artifacts': value['sources'][0]['format'] = 'commonCounterpartJSONL'
    else: value = json.dumps(value).replace('"schemaVersion": 1', '"schemaVersion": 1, "schemaVersion": 1', 1).encode()
    run('synthetic-' + mutation, value, reject=True)

summary = dict(kind='offline consumer replay and synthetic negatives; not new network or isolation measurement', checks=len(results), passed=len(results), results=results)
if args.output:
    (args.output / 'summary.json').write_text(json.dumps(summary, indent=2, sort_keys=True) + '\n')
print(f'{len(results)}/{len(results)} offline network adapter CLI checks passed; no sockets/identity/pf/capture')
