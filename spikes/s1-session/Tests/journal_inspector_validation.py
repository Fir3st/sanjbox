#!/usr/bin/env python3
"""Offline CLI regressions; native inputs are exact preserved copies, all mutations synthetic.
No process acquisition or dataset discovery. Outputs and failed results remain in a new directory.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import uuid


def sha(data):
    return hashlib.sha256(data).hexdigest()


def run(binary, output):
    output.mkdir(mode=0o700)
    fixture_root = Path(__file__).resolve().parents[1] / 'validation/journal-inspector-20261106/native-journals'
    provenance = json.loads((fixture_root / 'provenance.json').read_text())
    native = {item['file']: item for item in provenance['inputs']}
    for name, item in native.items():
        assert sha((fixture_root / name).read_bytes()) == item['sha256']
    namespace = 'journal-inspector-' + uuid.uuid4().hex[:16]
    results, staged = [], []

    def call(label, args, expected):
        result = subprocess.run([str(binary), *args], capture_output=True, timeout=40)
        record = dict(label=label, arguments=args, expectedExit=expected, exit=result.returncode,
                      stdout=result.stdout.decode(), stderr=result.stderr.decode())
        results.append(record)
        (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        assert result.returncode == expected, (label, record)
        return result

    def stage(label, raw):
        name = namespace + '-' + label
        path = Path(f'/private/tmp/sanjbox-a2-journal-{os.geteuid()}-{name}.jsonl')
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'wb') as stream:
            stream.write(raw)
        staged.append((path, path.lstat().st_ino))
        (output / (label + '.jsonl')).write_bytes(raw)
        return name, path

    def inspect(label, raw, expected=3, plan=None):
        name, path = stage(label, raw)
        before = path.lstat()
        args = ['inspect-process-journal', '--fixture', name, '--apply']
        if plan is not None:
            args += ['--series-json', plan.decode()]
        result = call(label, args, expected)
        after = path.lstat()
        assert (before.st_ino, before.st_mode, before.st_size, before.st_mtime_ns, before.st_ctime_ns) == (after.st_ino, after.st_mode, after.st_size, after.st_mtime_ns, after.st_ctime_ns)
        assert path.read_bytes() == raw
        report = json.loads(result.stdout)
        assert report['inputSHA256'] == sha(raw) and report['inputBytes'] == len(raw)
        assert report['status'] == 'incomplete-unverified'
        assert report['acquisitionComplete'] is False and report['identityAuthenticated'] is False
        assert report['provenanceArtifactsVerified'] is False and report['acceptanceVerdict'] == 'not-evaluated'
        if plan is None:
            assert 'suppliedPlanSHA256' not in report
        else:
            assert report['suppliedPlanSHA256'] == sha(plan)
        return report

    try:
        call('dry-missing', ['inspect-process-journal', '--fixture', namespace + '-missing'], 0)
        call('missing', ['inspect-process-journal', '--fixture', namespace + '-missing', '--apply'], 2)
        call('path', ['inspect-process-journal', '--fixture', '../escape', '--apply'], 2)
        call('no-pid', ['inspect-process-journal', '--fixture', namespace, '--pid', '1'], 2)
        call('no-output-dataset', ['inspect-process-journal', '--fixture', namespace, '--run-id', namespace], 2)
        call('duplicate-apply', ['inspect-process-journal', '--fixture', namespace, '--apply', '--apply'], 2)
        call('duplicate-fixture', ['inspect-process-journal', '--fixture', namespace, '--fixture', namespace], 2)
        call('invalid-plan-dry', ['inspect-process-journal', '--fixture', namespace, '--series-json', '{}'], 2)
        for name, item in native.items():
            if not name.endswith('.jsonl'):
                continue
            report = inspect('native-' + name.removesuffix('.jsonl'), (fixture_root / name).read_bytes())
            assert not report['structuralError'] and len(report['rows']) == item['rows']
            assert report['contiguousPrefixBytes'] == item['bytes'] and 'tail' not in report
            assert report['runID'] == item['sourceRun']
        for author in ['implementer', 'reviewer']:
            raw = (fixture_root / f'{author}-positive.jsonl').read_bytes()
            plan = (fixture_root / f'{author}-positive-plan.json').read_bytes()
            report = inspect(author + '-bound', raw, plan=plan)
            assert len(report['rows']) == 5 and not report['structuralError']
            other = 'reviewer' if author == 'implementer' else 'implementer'
            report = inspect(author + '-cross-run', raw, expected=2, plan=(fixture_root / f'{other}-positive-plan.json').read_bytes())
            assert not report['rows'] and report['structuralError']
        raw = (fixture_root / 'implementer-positive.jsonl').read_bytes()
        first, second, *rest = raw.splitlines(keepends=True)
        report = inspect('derived-truncated', raw[:-17])
        assert len(report['rows']) == 4 and report['tail']['kind'] == 'unterminated-final-bytes'
        report = inspect('derived-missing-LF', raw[:-1])
        assert len(report['rows']) == 4 and report['tail']['kind'] == 'complete-row-without-LF'
        report = inspect('derived-bad-middle', first + b'{}\n' + b''.join(rest), expected=2)
        assert len(report['rows']) == 1 and report['contiguousPrefixBytes'] == len(first)
        assert report['unexaminedBytes']['start'] == len(first) + 3
        for ending in [b'{}\n', b'{}', b'{"sequence":01}\n', b'\xff\n']:
            report = inspect('derived-bad-final-' + str(len(results)), first + ending, expected=2)
            assert len(report['rows']) == 1 and report['diagnostics'][-1]['line'] == 2
        for label, suffix, code in [
            ('invalid-utf8-tail', b'{"runID":"' + bytes([0xFF]), 2),
            ('invalid-surrogate-tail', b'{"runID":"' + b'\\uDC00', 2),
            ('possible-utf8-tail', b'{"runID":"' + bytes([0xC3]), 3),
        ]:
            report = inspect(label, first + suffix, expected=code)
            assert len(report['rows']) == 1 and report['contiguousPrefixBytes'] == len(first)
            assert report['tail']['kind'] == ('invalid-final-bytes' if code == 2 else 'unterminated-final-bytes')
        report = inspect('empty', b'')
        assert not report['rows'] and not report['structuralError']
        invalid_name, invalid_path = stage('dry-invalid', b'not JSON\n')
        call('dry-invalid-no-read', ['inspect-process-journal', '--fixture', invalid_name], 0)
        name, path = stage('wrong-mode', first)
        path.chmod(0o644)
        call('wrong-mode', ['inspect-process-journal', '--fixture', name, '--apply'], 2)
        for kind in ['symlink', 'hardlink', 'fifo', 'directory']:
            name = namespace + '-' + kind
            path = Path(f'/private/tmp/sanjbox-a2-journal-{os.geteuid()}-{name}.jsonl')
            if kind == 'symlink': path.symlink_to(invalid_path)
            elif kind == 'hardlink': os.link(invalid_path, path)
            elif kind == 'fifo': os.mkfifo(path, 0o600)
            else: path.mkdir(mode=0o700)
            staged.append((path, path.lstat().st_ino))
            call(kind, ['inspect-process-journal', '--fixture', name, '--apply'], 2)
        for name, item in native.items():
            assert sha((fixture_root / name).read_bytes()) == item['sha256']
        (output / 'passed.json').write_text(json.dumps(dict(checks=len(results), nativeJournals=12, nativeRows=54,
            scope='offline retained copies and explicitly derived mutations; no acquisition; no S1/P4 verdict'), indent=2) + '\n')
    finally:
        cleanup=[]
        for path, inode in reversed(staged):
            if path.lstat().st_ino != inode:
                raise RuntimeError('staging inode changed; preserved conflict')
            if stat.S_ISDIR(path.lstat().st_mode): path.rmdir()
            else: path.unlink()
            cleanup.append(dict(path=str(path), removed=True))
        (output / 'cleanup.json').write_text(json.dumps(cleanup, indent=2)+'\n')
        files={p.name:sha(p.read_bytes()) for p in output.iterdir() if p.is_file() and p.name!='manifest.json'}
        (output / 'manifest.json').write_text(json.dumps(files,indent=2)+'\n')
    print(f'{len(results)} offline CLI checks passed; preserved evidence: {output}')


if __name__ == '__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args=parser.parse_args()
    run(args.binary.resolve(), args.output.resolve())
