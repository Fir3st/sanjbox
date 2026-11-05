#!/bin/bash
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
binary="${SANJBOX_HOST_HARDEN_BIN:-$script_dir/.build/out/Products/Release/sanjbox-host-harden}"
if [[ "$binary" != /* || ! -f "$binary" || -L "$binary" || ! -x "$binary" ]]; then
    printf '%s\n' 'Build first; set SANJBOX_HOST_HARDEN_BIN to the absolute Release binary path.' >&2
    exit 2
fi
if [[ "${1:-}" == --help && $# == 1 ]]; then exec "$binary" --help; fi
exec "$binary" uninstall "$@"
