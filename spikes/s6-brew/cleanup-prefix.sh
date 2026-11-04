#!/bin/bash
set -euo pipefail
exec /usr/bin/python3 -I -B "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/prefix.py" cleanup "$@"
