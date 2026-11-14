#!/bin/bash
set -euo pipefail
a3_apply=false
if [[ ${1:-} == --apply ]]; then a3_apply=true; shift; fi
if [[ $# -lt 3 ]]; then
  echo 'Usage: swift-with-openssl.sh [--apply] ROOT debug|release build|test [Swift arguments]'
  exit 0
fi
a3_root=$1; a3_mode=$2; a3_command=$3; shift 3
[[ $a3_root == /private/tmp/sanjbox-a3-openssl-3.5.9.* && -d $a3_root && ! -L $a3_root ]]
[[ $(/usr/bin/stat -f '%u %Lp' "$a3_root") == "$(/usr/bin/id -u) 700" ]]
[[ $a3_mode == debug || $a3_mode == release ]]
[[ $a3_command == build || $a3_command == test ]]
a3_repo=$(cd "$(dirname "$0")/.." && pwd -P)
a3_source="$a3_root/source/openssl-3.5.9"
a3_args=(/usr/bin/xcrun swift "$a3_command" --disable-sandbox
  --package-path "$a3_repo" --configuration "$a3_mode"
  --scratch-path "$a3_root/swift-$a3_mode/build"
  --cache-path "$a3_root/swift-$a3_mode/cache"
  --config-path "$a3_root/swift-$a3_mode/config"
  --security-path "$a3_root/swift-$a3_mode/security"
  -Xcc "-I$a3_root/build/include" -Xcc "-I$a3_source/include"
  -Xlinker "$a3_root/build/libcrypto.a" "$@")
if ! $a3_apply; then
  printf 'Dry run (sanitized environment, deployment target 27.0):'; printf ' %q' "${a3_args[@]}"; printf '\n'
  exit 0
fi
# Validate the exact local archive recorded by provisioning, never a system library.
(cd "$a3_root/build" && /usr/bin/shasum -a 256 -c "$a3_root/logs/libcrypto.sha256")
/bin/mkdir -p "$a3_root/swift-$a3_mode/module" "$a3_root/swift-$a3_mode/cache" \
  "$a3_root/swift-$a3_mode/config" "$a3_root/swift-$a3_mode/security"
exec /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin TMPDIR="$a3_root/tmp/" \
  MACOSX_DEPLOYMENT_TARGET=27.0 OPENSSL_CONF=/dev/null \
  OPENSSL_MODULES="$a3_root/empty-modules" OPENSSL_ENGINES="$a3_root/empty-engines" \
  CLANG_MODULE_CACHE_PATH="$a3_root/swift-$a3_mode/module" \
  SWIFTPM_MODULECACHE_OVERRIDE="$a3_root/swift-$a3_mode/module" "${a3_args[@]}"
