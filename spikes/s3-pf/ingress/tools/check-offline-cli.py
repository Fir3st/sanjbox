#!/usr/bin/env python3
"""Fixed offline CLI checks against a caller-supplied build of this package; no live smoke."""
import json
from pathlib import Path
import subprocess
import sys

binary = str(Path(sys.argv[1]).resolve(strict=True))
fixtures = Path(__file__).resolve().parent.parent / 'Tests/IngressKitTests/Fixtures'
fixture = json.loads((fixtures / 'link-fixture.json').read_text())
vectors = json.loads((fixtures / 'producer-vectors.json').read_text())
count = 0

def invoke(args, data=b'', expected=0):
    global count
    result = subprocess.run([binary, *args], input=data, capture_output=True, timeout=5)
    assert result.returncode == expected, (args, result.returncode, result.stderr.decode())
    if expected:
        assert not result.stdout
        value = None
    else:
        value = json.loads(result.stdout)
    count += 1
    return value, result.stdout

def encoded(value):
    return json.dumps(value, separators=(',', ':')).encode()

def fresh():
    return json.loads(json.dumps(fixture))

for args in ([], ['plan']):
    value, _ = invoke(args)
    assert value['mode'] == 'dry-run'
value, _ = invoke(['evaluate'], encoded(dict(schemaVersion=1, runID=fixture['runID'], cells=[])))
assert len(value['cells']) == 28 and all(x['classification'] == 'notMeasured' for x in value['cells'])
value, first = invoke(['link'], encoded(fixture))
assert value['links'][0]['status'] == 'partialLinkNeedsReview'
assert len(value['findings']) == 3 and value['externalReviewRequired'] and not value['packetAbsenceProven']
_, second = invoke(['link'], encoded(fixture))
assert first == second
f = fresh(); f['sources'][0]['text'] = vectors['c1Error']
value, _ = invoke(['link'], encoded(f))
assert any('client error' in s for s in value['links'][0]['missingBindings'])
f = fresh(); f['sources'][1]['text'] = vectors['commonZeroTCP']; f['matrixJSON'] = '{bad'; f['bindings'] = []
value, _ = invoke(['link'], encoded(f))
assert any(x['kind'] == 'accepted' for x in value['findings'])
assert any(x.get('bytes') == 0 for x in value['findings']) and value['matrixProblems']
f = fresh(); f['sources'][2]['text'] = '{"kind":"packetContact","kind":"packetContact"}\n'
value, _ = invoke(['link'], encoded(f))
assert len([x for x in value['findings'] if x['sourceID'] == 'receiver']) == 2
f = fresh(); f['sources'][0]['format'] = 'unsupported'
value, _ = invoke(['link'], encoded(f))
assert next(x for x in value['sources'] if x['id'] == 'sender')['problems']
f = fresh(); f['unexpected'] = True
invoke(['link'], encoded(f), 2)
invoke(['link'], b'{"schemaVersion":1,"schema\\u0056ersion":1}', 2)
invoke(['link'], b' ' * 1_048_577, 2)
for args in (['link', '/private/tmp/unused.json'], ['link', '--apply'], ['link', '--pid', '1'], ['link', '--command', 'echo']):
    invoke(args, expected=2)
# Keep stdin open with no EOF. The CLI must time out independently of the harness.
process = subprocess.Popen([binary, 'link'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
try:
    assert process.wait(timeout=4) == 2
    assert not process.stdout.read()
    assert b'stdin deadline exceeded' in process.stderr.read()
    count += 1
finally:
    if process.poll() is None:
        process.kill(); process.wait()
    process.stdin.close(); process.stdout.close(); process.stderr.close()
# Fresh independent review counterexamples and valid ambiguity controls.
def rows_in(f, source):
    return [json.loads(line) for line in f['sources'][source]['text'].splitlines()]

def rows_out(f, source, rows):
    f['sources'][source]['text'] = ''.join(json.dumps(row, separators=(',', ':')) + '\n' for row in rows)

def matrix_out(f, matrix):
    matrix['cells'][0]['events'].sort(key=lambda event: event['timeMs'])
    f['matrixJSON'] = json.dumps(matrix, separators=(',', ':'))

def problems(value):
    return '\n'.join(value['links'][0]['problems'])

def zero_bytes(f):
    rows = rows_in(f, 1)
    rows[2]['bytes'] = 0; rows[2]['findings'] = []; rows[2].pop('rawFile', None)
    rows_out(f, 1, rows)

f = fresh(); zero_bytes(f)
value, _ = invoke(['link'], encoded(f))
assert value['links'][0]['status'] == 'conflictingOrIncompleteLink'
assert 'matrix payload' in problems(value) and 'lacks matching raw observation' in problems(value)
assert len(value['findings']) == 3 and any(x.get('bytes') == 0 for x in value['findings'])
print('P2 payload reproduction: conflicting matrix claim; zero-byte contact retained')

for raw_times, matrix_times, conflict in (
        ([1201, 1201], [1201, 1800], True),
        ([1201, 1800], [1201, 1800], False),
        ([1201, 1201], [1201, 1201], False),
        ([1201, 1202], [1200, 1203], False)):
    f = fresh(); rows = rows_in(f, 2)
    packet = rows[1]
    packets = [dict(packet, timestamp=f'2026-11-04T12:00:{t//1000:02d}.{t%1000:03d}Z') for t in raw_times]
    rows_out(f, 2, [rows[0], *packets, rows[2]])
    matrix = json.loads(f['matrixJSON'])
    event = next(e for e in matrix['cells'][0]['events'] if e['kind'] == 'packetContact')
    matrix['cells'][0]['events'] = [e for e in matrix['cells'][0]['events'] if e['kind'] != 'packetContact']
    matrix['cells'][0]['events'] += [dict(event, timeMs=t) for t in matrix_times]
    matrix_out(f, matrix)
    value, _ = invoke(['link'], encoded(f))
    assert value['links'][0]['status'] == ('conflictingOrIncompleteLink' if conflict else 'partialLinkNeedsReview'), value['links'][0]['problems']
    assert len(value['findings']) == 2 + len(raw_times)
    if conflict:
        assert 'raw packetContact time/value lacks matching matrix event' in problems(value)
        assert 'matrix packetContact' in problems(value) and 'lacks matching raw observation' in problems(value)
        print('P2 packet reproduction: unmatched raw and matrix occurrences reported; both packet records retained')

f = fresh(); zero_bytes(f); matrix = json.loads(f['matrixJSON'])
matrix['cells'][0]['events'] = [e for e in matrix['cells'][0]['events'] if e['kind'] != 'payload']
matrix_out(f, matrix)
value, _ = invoke(['link'], encoded(f))
assert value['links'][0]['status'] == 'partialLinkNeedsReview'
f = fresh(); rows = rows_in(f, 1); rows[2].pop('bytes'); rows_out(f, 1, rows)
matrix = json.loads(f['matrixJSON'])
next(e for e in matrix['cells'][0]['events'] if e['kind'] == 'payload')['value'] = 0
matrix_out(f, matrix)
value, _ = invoke(['link'], encoded(f))
assert 'matrix payload' in problems(value) and 'lacks matching raw observation' in problems(value)
f = fresh(); f['bindings'][0].pop('counterpart')
value, _ = invoke(['link'], encoded(f))
assert 'matrix payload' in problems(value) and len(value['findings']) == 3
print(f'{count}/{count} offline CLI checks passed; 0 skipped; no smoke/identity/network operations')
