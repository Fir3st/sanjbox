#!/bin/bash
set -euo pipefail
a3_apply=false
if [[ ${1:-} == --apply ]]; then a3_apply=true; shift; fi
if [[ $# != 1 ]]; then echo 'Usage: cleanup-openssl.sh [--apply] ROOT (retains logs/state)'; exit 0; fi
/usr/bin/python3 -I -B - "$a3_apply" "$1" <<'PY'
import os, pathlib, shutil, stat, sys
apply, supplied = sys.argv[1:]
root = pathlib.Path(supplied)
if root.parent != pathlib.Path('/private/tmp') or not root.name.startswith('sanjbox-a3-openssl-3.5.9.'):
    raise SystemExit('refused unexpected root')
s = root.lstat()
if not stat.S_ISDIR(s.st_mode) or s.st_uid != os.geteuid() or stat.S_IMODE(s.st_mode) != 0o700:
    raise SystemExit('refused changed root type/owner/mode')
for marker in [root / 'state', root / 'state/owned-root.txt']:
    m = marker.lstat()
    if stat.S_ISLNK(m.st_mode) or m.st_uid != os.geteuid(): raise SystemExit('refused changed marker')
if (root / 'state/owned-root.txt').read_text() != str(root) + '\n': raise SystemExit('refused root marker mismatch')
names = ['download', 'source', 'build', 'swift-debug', 'swift-release', 'tmp', 'empty-modules', 'empty-engines']
for name in names:
    p = root / name
    if not p.exists() and not p.is_symlink(): continue
    s = p.lstat()
    if not stat.S_ISDIR(s.st_mode) or s.st_uid != os.geteuid(): raise SystemExit('refused changed child: ' + name)
    print(('remove ' if apply == 'true' else 'would remove ') + str(p))
    if apply == 'true': shutil.rmtree(p)
print('retained logs and state at ' + str(root))
PY
