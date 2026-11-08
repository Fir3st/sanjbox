#!/usr/bin/env python3
"""Owned native fixture, normal descendant-memory CLI, posthoc truth. Default dry-run.
Never enumerates host processes or supplies descendant PIDs to the collector.
"""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import select
import stat
import subprocess
import time
import uuid


def line(child, timeout=5):
    data, end = bytearray(), time.monotonic() + timeout
    while time.monotonic() < end:
        ready, _, _ = select.select([child.stdout], [], [], max(0, end - time.monotonic()))
        assert ready, 'fixture protocol timeout'
        byte = os.read(child.stdout.fileno(), 1)
        assert byte, 'fixture protocol ended'
        if byte == b'\n':
            return json.loads(data)
        data += byte
        assert len(data) <= 16384
    raise AssertionError('fixture protocol timeout')


def run(binary, expectation, output, unsafe_binary=None):
    fd = os.open(expectation, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as stream:
        info = os.fstat(stream.fileno())
        assert stat.S_ISREG(info.st_mode) and info.st_uid == os.geteuid() and info.st_nlink == 1 and 0 < info.st_size <= 16384
        expected_bytes = stream.read(16385)
    expected = json.loads(expected_bytes)
    output.mkdir(mode=0o700)
    (output / 'expectation-preregistered.json').write_bytes(expected_bytes)
    ns = 'descendants-' + uuid.uuid4().hex[:12]
    results, datasets, children = [], [], []

    def keep(name, value):
        with (output / name).open('x') as f:
            json.dump(value, f, indent=2)

    def path_for(plan):
        return Path(f'/private/tmp/sanjbox-a2-{plan["runID"]}-uid{os.geteuid()}-descendant-memory')

    def arguments(plan, context=expected):
        return ['descendant-memory', '--descendant-json', json.dumps(plan), '--expect-json', json.dumps(context)]

    def check(label, plan, code, apply=True, context=expected, executable=binary):
        args = arguments(plan, context) + (['--apply'] if apply else [])
        r = subprocess.run([str(executable), *args], capture_output=True, text=True, env={}, timeout=8)
        results.append(dict(label=label, exit=r.returncode, expectedExit=code, stdout=r.stdout, stderr=r.stderr))
        keep(label + '.json', results[-1])
        assert r.returncode == code, results[-1]
        path = path_for(plan)
        if path.exists() and str(path) not in datasets:
            datasets.append(str(path))
        return path

    def fixture():
        request = dict(level=0, parentPID=os.getpid(), expected=expected)
        child = subprocess.Popen([str(binary), 'owned-descendant-fixture', '--fixture-json', json.dumps(request), '--apply'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env={}, bufsize=0)
        children.append(child)
        hello = line(child)
        assert hello['process']['identity']['pid'] == child.pid and hello['process']['parentPID'] == os.getpid()
        assert hello['identity']['mismatches'] == [] and hello['signature']['hardenedRuntime'] and not hello['signature']['forbiddenEntitlementPresent']
        return child, hello

    try:
        # Only root is known to the harness before collection; no descendant hello is read here.
        root, hello = fixture()
        plan = dict(runID=ns+'-positive', seconds=10, root=hello['process'], provenanceSHA256=hashlib.sha256(json.dumps(hello, sort_keys=True).encode()).hexdigest(), maxProcesses=8, maxDepth=3)
        keep('root-registration.json', dict(plan=plan, hello=hello))
        check('dry-run', plan, 0, apply=False); assert not path_for(plan).exists()
        unknown = copy.deepcopy(plan); unknown['pid'] = root.pid
        check('unknown-option-schema', unknown, 2, apply=False)
        cross = copy.deepcopy(plan); cross['root']['identity']['uid'] += 1; cross['root']['identity']['realUID'] += 1
        check('cross-uid', cross, 2); assert not path_for(plan).exists()
        # Start normal public acquisition first; arm fixture only after its first durable poll.
        collector = subprocess.Popen([str(binary), *arguments(plan), '--apply'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, env={})
        children.append(collector)
        journal = path_for(plan) / 'descendants.jsonl'
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            if journal.exists() and journal.read_bytes().endswith(b'\n'):
                break
            assert collector.poll() is None
            time.sleep(0.01)
        else:
            raise AssertionError('collector did not start')
        root.stdin.write(b'G'); root.stdin.flush()
        stdout, stderr = collector.communicate(timeout=14)
        results.append(dict(label='native-late-tree', exit=collector.returncode, stdout=stdout.decode(), stderr=stderr.decode()))
        keep('native-cli.json', results[-1]); assert collector.returncode == 3, results[-1]
        datasets.append(str(path_for(plan)))
        raw = json.loads((path_for(plan) / 'recording.json').read_text())
        report = json.loads((path_for(plan) / 'report.json').read_text())
        # The truth channel is read ONLY now, after collector exit. Cleanup uses pipe EOF, no PID kill.
        root.stdin.close(); truth = line(root); assert root.wait(timeout=5) == 0
        keep('posthoc-fixture-truth.json', truth)
        flat = [truth, truth['child'][0], truth['child'][0]['child'][0]]
        bindings = raw['bindings']; points = raw['observations']
        assert truth['childCleanupComplete']
        for item in flat:
            matches = [b for b in bindings if b['process'] == item['process']]
            assert len(matches) == 1, ('missing unique discovery', item, bindings)
            binding = matches[0]
            samples = [p for p in points if p['operation'] == 'poll' and p['index'] == binding['index'] and p['state'] == 'sampled']
            assert samples and all(p['before'] == p['afterMemory'] == p['after'] for p in samples)
            summary = next(p for p in report['processes'] if p['binding']['index'] == binding['index'])
            for metric in ['physicalFootprintBytes', 'residentBytes']:
                assert summary[metric]['minimum'] == min(p[metric] for p in samples)
                assert summary[metric]['maximum'] == max(p[metric] for p in samples)
            allocated = [p for p in samples if p['readStarted'] >= item['allocatedAt'] and p['time'] < item['finished']]
            assert allocated and max(p['physicalFootprintBytes'] for p in allocated) >= item['fixtureMiB'] * 1024 * 1024
            assert max(p['residentBytes'] for p in allocated) >= item['fixtureMiB'] * 1024 * 1024
            if item['level']:
                assert binding['discoveredAt'] > raw['window']['start'] and binding['depth'] == item['level']
                assert any(p['index'] == binding['index'] and p['state'] in ['unreadableBefore', 'scopeChangedBefore'] for p in points)
        root_samples = [p for p in points if p['operation'] == 'poll' and p['index'] == 0 and p['state'] == 'sampled']
        assert max(p['physicalFootprintBytes'] for p in root_samples) - min(p['physicalFootprintBytes'] for p in root_samples) >= 3 * 1024 * 1024
        assert report['pollingWindowCompleted'] and report['quickProcessesMayBeMissed'] and not report['fullTreeAttributionComplete'] and not report['fullSessionAttributionComplete']
        assert all('physicalFootprintBytes' not in p and 'residentBytes' not in p for p in points if p['state'] != 'sampled')
        rows = [json.loads(row) for row in journal.read_bytes().splitlines()]
        assert [row['sequence'] for row in rows] == list(range(len(rows))) and [row['observation'] for row in rows] == points
        keep('positive-assertions.json', dict(discovered=len(bindings), observations=len(points), truthProcesses=len(flat), posthocOnly=True, cleanupComplete=True))
        # Dead/wrong instance and credential gates use the same normal acquisition route.
        dead = copy.deepcopy(plan); dead.update(runID=ns+'-dead', seconds=1)
        path = check('exited-root', dead, 3)
        assert all(p['state'] in ['unreadableBefore', 'scopeChangedBefore'] and 'physicalFootprintBytes' not in p for p in json.loads((path/'recording.json').read_text())['observations'])
        mismatch = copy.deepcopy(expected); mismatch['auditSessionID'] += 1
        invalid = copy.deepcopy(dead); invalid['runID'] = ns+'-identity'
        path = check('wrong-self-identity', invalid, 3, context=mismatch)
        assert json.loads((path/'recording.json').read_text())['observations'] == [] and not (path/'descendants.jsonl').exists()
        if unsafe_binary:
            unsafe = copy.deepcopy(dead); unsafe['runID'] = ns+'-unsafe'
            check('unsafe-self-signature', unsafe, 2, executable=unsafe_binary); assert not path_for(unsafe).exists()
        # A second alive root remains unarmed while the wrong start and native process cap are tested.
        root2, hello2 = fixture()
        wrong = copy.deepcopy(plan); wrong.update(runID=ns+'-wrong-start', seconds=1, root=hello2['process'])
        wrong['root'] = copy.deepcopy(wrong['root']); wrong['root']['identity']['startMicroseconds'] = (wrong['root']['identity']['startMicroseconds'] + 1) % 1000000
        path = check('wrong-start', wrong, 3)
        assert all(p['state'] == 'scopeChangedBefore' for p in json.loads((path/'recording.json').read_text())['observations'])
        root2.stdin.write(b'G'); root2.stdin.flush()
        limited = copy.deepcopy(plan); limited.update(runID=ns+'-limited', seconds=5, root=hello2['process'], maxProcesses=1)
        path = check('native-process-limit', limited, 3)
        value = json.loads((path/'recording.json').read_text())
        assert len(value['bindings']) == 1 and any(p['state'] == 'processLimit' for p in value['observations'])
        root2.stdin.close(); truth2 = line(root2); assert root2.wait(timeout=5) == 0 and truth2['childCleanupComplete']
        keep('limited-posthoc-truth.json', truth2)
        keep('passed.json', dict(checks=len(results), datasets=datasets, nativeNormalCLI=True))
        print(json.dumps(dict(checks=len(results), output=str(output), datasets=datasets)))
    finally:
        # Every process is our direct Popen child. EOF cascades through owned fixture pipes.
        cleanup = []
        for child in children:
            if child.stdin and not child.stdin.closed:
                child.stdin.close()
            try:
                child.wait(timeout=22)
                cleanup.append(dict(pid=child.pid, exited=True, code=child.returncode, stderr=(child.stderr.read(65536).decode(errors='replace') if child.stderr and not child.stderr.closed else '')))
            except subprocess.TimeoutExpired:
                cleanup.append(dict(pid=child.pid, exited=False))
        keep('cleanup.json', cleanup)
        keep('results.json', results); keep('datasets.json', datasets)
        assert all(item['exited'] for item in cleanup), cleanup


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--expect-file', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--unsafe-binary', type=Path)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    if args.apply:
        run(args.binary.resolve(), args.expect_file, args.output, args.unsafe_binary)
    else:
        print('dry-run: owned signed root/late-child/grandchild, normal CLI, posthoc truth; no reads or launches')
