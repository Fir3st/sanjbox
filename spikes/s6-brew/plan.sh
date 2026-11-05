#!/bin/bash
set -euo pipefail
# Offline stdout only. There is deliberately no package-execution --apply mode.
exec /usr/bin/python3 -I -B "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/s6.py" plan "$@"
