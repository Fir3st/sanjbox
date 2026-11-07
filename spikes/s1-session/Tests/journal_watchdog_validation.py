#!/usr/bin/env python3
"""Prove the real 30-second CLI watchdog covers a naturally blocked owned stdout pipe.
Uses one bounded synthetic journal, no acquisition, no manually injected SIGALRM.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import time
import uuid


def run(binary, output):
    output.mkdir(mode=0o700)
    identity = dict(pid=4242, uid=4501, realUID=4501, startSeconds=1800000000, startMicroseconds=7)
    raw = b''.join((json.dumps(dict(schemaVersion=1, runID='review-journal-natural-stdout', sequence=i,
        window=dict(start=100, end=103), point=dict(slot=1, readStarted=100+i*.01, time=100+i*.01+.001,
        state='sampled', before=identity, after=identity, physicalFootprintBytes=0, residentBytes=99)),
        separators=(',', ':')) + '\n').encode() for i in range(94))
    (output / 'synthetic-input.jsonl').write_bytes(raw)
    name = 'journal-watchdog-' + uuid.uuid4().hex[:16]
    path = Path(f'/private/tmp/sanjbox-a2-journal-{os.geteuid()}-{name}.jsonl')
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'wb') as stream:
        stream.write(raw)
    before = path.lstat()
    args = [str(binary), 'inspect-process-journal', '--fixture', name, '--apply']
    result = {}
    try:
        reference = subprocess.run(args, capture_output=True, timeout=35)
        (output / 'reference.json').write_bytes(reference.stdout)
        (output / 'reference-stderr.txt').write_bytes(reference.stderr)
        assert reference.returncode == 3
        assert len(json.loads(reference.stdout)['rows']) == 94
        assert 65536 < len(reference.stdout) < 69632, 'focused libc/pipe boundary fixture changed'
        reader, writer = os.pipe()  # Initially empty, no prefilling; read end is held open but unread.
        child = None
        try:
            started = time.monotonic()
            child = subprocess.Popen(args, stdout=writer, stderr=subprocess.PIPE)
            os.close(writer); writer = None
            survived = False
            try:
                child.wait(timeout=34)
            except subprocess.TimeoutExpired:
                survived = True
                child.terminate()  # Cleanup only the Popen we own, after recording deadline failure.
                try: child.wait(timeout=5)
                except subprocess.TimeoutExpired: child.kill(); child.wait(timeout=5)
            elapsed = time.monotonic() - started
            partial = bytearray()
            while True:
                chunk = os.read(reader, 65536)
                if not chunk: break
                partial.extend(chunk)
            stderr = child.stderr.read()
            (output / 'blocked-stdout.partial.json').write_bytes(partial)
            (output / 'blocked-stderr.txt').write_bytes(stderr)
            result = dict(rows=94, inputBytes=len(raw), inputSHA256=hashlib.sha256(raw).hexdigest(),
                referenceExit=reference.returncode, referenceOutputBytes=len(reference.stdout),
                unreadInitiallyEmptyPipe=True, injectedSIGALRM=False, survivedDeadline=survived,
                exit=child.returncode, elapsedSeconds=elapsed, partialOutputBytes=len(partial),
                scope='synthetic offline stdout regression; partial stdout is not a completed inspection')
            (output / 'result.json').write_text(json.dumps(result, indent=2)+'\n')
            assert not survived and child.returncode == -signal.SIGALRM, result
            assert 25 <= elapsed < 34 and len(partial) < len(reference.stdout), result
        finally:
            if writer is not None: os.close(writer)
            os.close(reader)
            if child is not None:
                if child.poll() is None: child.kill(); child.wait(timeout=5)
                child.stderr.close()
        after = path.lstat()
        assert (before.st_ino, before.st_mode, before.st_mtime_ns, before.st_ctime_ns) == (after.st_ino, after.st_mode, after.st_mtime_ns, after.st_ctime_ns)
        assert path.read_bytes() == raw
    finally:
        info = path.lstat()
        assert info.st_ino == before.st_ino and info.st_uid == os.geteuid() and stat.S_ISREG(info.st_mode)
        path.unlink()
        (output / 'cleanup.json').write_text(json.dumps(dict(stagedPath=str(path), removed=True, originalJournalUsed=False), indent=2)+'\n')
        manifest = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in output.iterdir() if p.is_file() and p.name != 'manifest.json'}
        (output / 'manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
    print(f'Natural blocking-pipe watchdog passed: exit {result["exit"]}, {result["elapsedSeconds"]:.3f} seconds')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    run(args.binary.resolve(strict=True), args.output.resolve())
