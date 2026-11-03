#!/bin/bash
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd -P)
exec /usr/bin/python3 -I -B "$SCRIPT_DIR/pf_lab.py" unload "$@"
