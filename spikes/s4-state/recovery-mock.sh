#!/bin/bash
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
recovery_bin="${SANJBOX_STATE_RECOVERY_BIN:-$script_dir/.build/out/Products/Release/sanjbox-state-recovery}"
exec "$recovery_bin" "$@"
