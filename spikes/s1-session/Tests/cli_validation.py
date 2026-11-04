#!/usr/bin/env python3
"""A2 CLI regression checks; own synthetic inputs and intentional identity rejection only.
Requires an already built, verified hardened Release CLI. Never launches a real app/session.
All results/raw are retained in a new --output directory; only exact staged input files are removed.
"""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import uuid


def run(binary, output):
    output.mkdir(mode=0o700)  # exclusive directory; never reuse a run
    namespace = 'a2-cli-' + uuid.uuid4().hex[:16]
    results, staged, datasets = [], [], []
    sha = 'a' * 64
    expected = dict(uid=4501, gid=4500, kernelGroups=[4500], requiredGroups=[4500], forbiddenGroups=[20, 80], auditSessionID=123, onConsole=False)
    assert os.geteuid() != 4501, 'synthetic negative identity unexpectedly matches operator UID'
    identity = dict(uid=4501, gid=4500, realUID=4501, realGID=4500, kernelGroups=[4500], auditSessionID=123,
                    windowAuditSessionID=123, onConsole=False, auditUID=4501, managerName='Aqua', managerUID=4501,
                    windowUID=4501, loginDone=True, groupMembership=[dict(gid=4500, isMember=True), dict(gid=20, isMember=False), dict(gid=80, isMember=False)], mismatches=[])
    signature = dict(hardenedRuntime=True, forbiddenEntitlementPresent=False)
    def stamp(t):
        return dict(monotonic=t, utc=1800000000+t, bootIDHash=sha, uncertainty=0)
    def call(label, args, code=0):
        result = subprocess.run([str(binary), *args], capture_output=True, text=True, timeout=20)
        results.append(dict(label=label, arguments=args, expectedExit=code, exit=result.returncode, stdout=result.stdout, stderr=result.stderr))
        (output / 'results.json').write_text(json.dumps(results, indent=2))
        assert result.returncode == code, (label, result.returncode, result.stdout, result.stderr)
        text = result.stdout.strip()
        if re.fullmatch(r'/private/tmp/sanjbox-a2-[A-Za-z0-9-]+-uid\d+-(report|process-memory|login-marker|ram|offscreen)', text):
            path = Path(text)
            if path not in datasets:
                datasets.append(path)
        return result
    def evaluate(label, data, code=0):
        name = namespace + '-' + label
        path = Path(f'/private/tmp/sanjbox-a2-fixture-{os.geteuid()}-{name}.json')
        raw = data.encode() if isinstance(data, str) else json.dumps(data).encode()
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'wb') as stream:
            stream.write(raw)
        staged.append((path, path.lstat().st_ino))
        (output / (label + '-input.json')).write_bytes(raw)
        result = call(label, ['evaluate-supplement', '--fixture', name, '--run-id', name, '--apply'], code)
        if code != 2:
            return json.loads((Path(result.stdout.strip()) / 'report.json').read_text())
        return None
    try:
        call('help', ['--help'])
        call('extra-help', ['--help', '--apply'], 2)
        call('no-command', [])
        call('dry-evaluate', ['evaluate-supplement', '--fixture', namespace+'-missing', '--run-id', namespace])
        call('path-fixture', ['evaluate-supplement', '--fixture', '../escape', '--run-id', namespace], 2)
        call('missing-fixture', ['evaluate-supplement', '--fixture', namespace+'-missing', '--run-id', namespace, '--apply'], 2)
        plan = dict(runID=namespace+'-memory', seconds=1, fixtureMiB=4)
        args = ['process-memory', '--memory-json', json.dumps(plan), '--expect-json', json.dumps(expected)]
        call('dry-memory', args)
        assert not Path(f'/private/tmp/sanjbox-a2-{plan["runID"]}-uid{os.geteuid()}-process-memory').exists()
        call('no-target-pid', args+['--pid', str(os.getpid())], 2)
        call('duplicate-option', args+['--memory-json', '{}'], 2)
        call('duplicate-apply', args+['--apply', '--apply'], 2)
        call('unknown-memory-field', ['process-memory', '--memory-json', json.dumps(dict(plan, pid=os.getpid())), '--expect-json', json.dumps(expected)], 2)
        call('oversized-allocation', ['process-memory', '--memory-json', json.dumps(dict(plan, fixtureMiB=65)), '--expect-json', json.dumps(expected)], 2)
        call('invalid-identity', args+['--apply'], 3)
        raw = json.loads((datasets[-1] / 'recording.json').read_text())['memory'][0]
        assert not raw['samples'] and 'registration' not in raw and raw['errors'], 'identity rejection must precede process probe/allocation'
        original = hashlib.sha256((datasets[-1] / 'recording.json').read_bytes()).hexdigest()
        call('preserve-conflict', args+['--apply'], 2)
        assert hashlib.sha256((datasets[-1] / 'recording.json').read_bytes()).hexdigest() == original
        marker = dict(runID=namespace+'-marker', attemptID=namespace+'-attempt', configurationSHA256=sha, mode='warm', event='start', targetUID=4501, order=1, activeOtherZones=2)
        margs = ['login-marker', '--marker-json', json.dumps(marker), '--expect-json', json.dumps(expected)]
        call('dry-marker', margs)
        call('marker-identity-rejection', margs+['--apply'], 3)
        evaluate('empty-payload', dict(schemaVersion=1), 2)
        evaluate('duplicate-json', '{"schemaVersion":1,"schemaVersion":1,"memory":[]}', 2)
        memory = dict(schemaVersion=1, source='fixture', plan=dict(runID='fixture-memory-cli', seconds=3, fixtureMiB=4), expected=expected,
                      initialIdentity=identity, finalIdentity=identity, signature=signature, registration=dict(pid=42, uid=4501, startSeconds=1800000000, startMicroseconds=1, role='owned-recorder-fixture'),
                      started=stamp(99), finished=stamp(104), window=dict(start=100, end=103),
                      samples=[dict(time=t, physicalFootprintBytes=1234, residentBytes=5678) for t in range(100, 104)], errors=[])
        report = evaluate('valid-memory', dict(schemaVersion=1, memory=[memory]))
        assert report['evidenceComplete'] and not report['memory']['fullSessionAttributionComplete']
        bad = copy.deepcopy(memory); bad['samples'][1] = dict(time=101, error='unavailable')
        report = evaluate('unreadable-memory', dict(schemaVersion=1, memory=[bad]), 3)
        assert report['memory']['processes'][0]['physicalFootprintBytes']['count'] == 3
        bad = copy.deepcopy(memory); bad['samples'][0]['pid'] = 99
        evaluate('unknown-nested', dict(schemaVersion=1, memory=[bad]), 2)
        bad = copy.deepcopy(memory); bad['plan']['runID'] = 'second-record'
        evaluate('duplicate-process', dict(schemaVersion=1, memory=[memory, bad]), 2)
        bad = copy.deepcopy(memory); bad['finished']['bootIDHash'] = 'b'*64
        evaluate('clock-domain', dict(schemaVersion=1, memory=[bad]), 3)
        bad = copy.deepcopy(memory); bad['samples'] = []
        evaluate('empty-samples', dict(schemaVersion=1, memory=[bad]), 3)
        external = dict(schemaVersion=1, runID='fixture-workload-cli', source='external-synthetic', profile='diagnostic', workload='WE', application='electron',
                        applicationVersion='synthetic-1', runtimeVersion='synthetic-1', fixtureSHA256=sha, preregistrationSHA256=sha,
                        widthPixels=1920, heightPixels=1200, scale=2, expected=expected, initialIdentity=identity, finalIdentity=identity,
                        started=stamp(90), finished=stamp(104), window=dict(start=100, end=103),
                        cycles=[dict(index=i, start=90+i, end=90.5+i, launch='success', run='success', artifactSHA256=sha) for i in range(1,4)],
                        processes=[dict(pid=42, uid=4501, startSeconds=1800000000, startMicroseconds=1, role='application', artifactSHA256=sha)],
                        observations=[dict(kind=k, time=t, outcome='success', artifactSHA256=sha) for t in range(100,104) for k in ['changingOutput','inputResponse','presentedOutput','acceleratedBackend','webglCheck','processContinuity']])
        report = evaluate('external-synthetic', dict(schemaVersion=1, workloads=[external]))
        assert report['evidenceComplete'] and not report['workloads'][0]['artifactsVerified']
        bad = copy.deepcopy(external); bad['source'] = 'measured'
        evaluate('forged-measured', dict(schemaVersion=1, workloads=[bad]), 2)
        bad = copy.deepcopy(external); bad['cycles'][1]['run'] = 'failure'
        report = evaluate('retained-app-failure', dict(schemaVersion=1, workloads=[bad]))
        assert report['workloads'][0]['reportedFailures'] == ['cycle 2 run']
        bad = copy.deepcopy(external); bad['observations'] = [o for o in bad['observations'] if o['kind'] != 'presentedOutput']
        evaluate('missing-app-output', dict(schemaVersion=1, workloads=[bad]), 3)
        host = copy.deepcopy(expected); host.update(uid=4502, auditSessionID=124, onConsole=True)
        host_identity = copy.deepcopy(identity)
        for k in ['uid','realUID','auditUID','managerUID','windowUID']: host_identity[k] = 4502
        host_identity.update(auditSessionID=124, windowAuditSessionID=124, onConsole=True)
        markers = []
        for i, event in enumerate(['start','ready']):
            request = dict(marker, runID=f'fixture-login-marker-{i}', event=event)
            markers.append(dict(schemaVersion=1, request=request, source='fixture', expected=host if i==0 else expected, identity=host_identity if i==0 else identity,
                                signature=signature, clock=stamp(100+i), eventDelayBoundSeconds=0.001, calibrationSHA256=sha, observationSHA256=sha))
        report = evaluate('synthetic-login', dict(schemaVersion=1, login=[dict(markers=markers)]))
        assert report['login']['attempts'][0]['eventDurationUpperSeconds'] == 1.002
        for m in markers:
            m['source'] = 'measured-marker'
            for k in ['eventDelayBoundSeconds','calibrationSHA256','observationSHA256']: del m[k]
        report = evaluate('uncalibrated-markers', dict(schemaVersion=1, login=[dict(markers=markers)]), 3)
        assert 'eventDurationUpperSeconds' not in report['login']['attempts'][0]
        print(f'{len(results)}/{len(results)} CLI checks passed; synthetic/negative only; raw retained in {output}')
    finally:
        for path, inode in staged:
            info = path.lstat()
            assert stat.S_ISREG(info.st_mode) and info.st_uid == os.geteuid() and info.st_ino == inode
            path.unlink()
        (output / 'datasets.json').write_text(json.dumps([str(p) for p in datasets], indent=2))

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    if args.apply:
        run(args.binary.resolve(strict=True), args.output)
    else:
        print('dry-run: run synthetic CLI checks and intentional identity rejection; create new output; no tests performed')
