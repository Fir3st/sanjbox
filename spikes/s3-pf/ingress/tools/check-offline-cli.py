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
print(f'{count}/{count} offline CLI checks passed; 0 skipped; no smoke/identity/network operations')
