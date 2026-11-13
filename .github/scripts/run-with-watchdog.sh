#!/bin/bash
# Usage: run-with-watchdog.sh SECONDS LOG_DIR COMMAND [ARGS...]
# exec preserves cancellation signals and the helper's exit status on Bash 3.2.
set -euo pipefail
exec /usr/bin/python3 -I -B "$(dirname "$0")/watchdog.py" "$@"
