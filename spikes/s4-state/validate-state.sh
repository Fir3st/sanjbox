#!/bin/bash
set -euo pipefail

# Offline, read-only validator. No --apply mode, compilation, shell evaluation or deployment.
package_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
validator="${SANJBOX_STATE_MANIFEST_BIN:-$package_dir/.build/out/Products/Debug/sanjbox-state-manifest}"
if [[ "$validator" != /* || ! -f "$validator" || -L "$validator" || ! -x "$validator" ]]; then
    printf '%s\n' 'Build spikes/s4-state first; optionally set SANJBOX_STATE_MANIFEST_BIN to the exact built executable.' >&2
    exit 2
fi
exec "$validator" "$@"
