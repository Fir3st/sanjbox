#!/bin/bash
set -euo pipefail

# Read-only audit: no --apply mode and no automatic compilation or output writes.
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
binary="${SANJBOX_HOST_AUDIT_BIN:-$script_dir/.build/out/Products/Debug/sanjbox-host-audit}"
if [[ "$binary" != /* || ! -f "$binary" || -L "$binary" || ! -x "$binary" ]]; then
    printf '%s\n' 'Build first: swift build --package-path spikes/s4-host' >&2
    exit 2
fi
exec "$binary" "$@"
