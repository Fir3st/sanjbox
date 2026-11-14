#!/bin/bash
set -euo pipefail
# Approved WP1.A3 dependency recipe; no installation or machine package lookup.
if [[ ${1:-} != --apply || $# != 1 ]]; then
  cat <<'PLAN'
Dry run: create one owner-only /private/tmp/sanjbox-a3-openssl-3.5.9.XXXXXX tree;
download the official 3.5.9 archive, verify the pinned SHA-256 before extraction;
Configure darwin64-arm64 no-shared no-module no-legacy (deployment target 27.0);
make -j2 build_libs; make -j2 test with DH/DH-param/EVP/RAND recipes.
No install. All source/build/cache/log writes stay in that new tree. Logs survive failure.
Run with --apply only within the explicitly approved offline dependency scope.
Cleanup: scripts/cleanup-openssl.sh [--apply] ROOT retains logs and state.
PLAN
  exit 0
fi
test "$(/usr/bin/uname -m)" = arm64
a3_root=$(/usr/bin/mktemp -d /private/tmp/sanjbox-a3-openssl-3.5.9.XXXXXX)
# First and only stdout record lets CI retain failed provisioning logs too.
printf '%s\n' "$a3_root"
/bin/mkdir "$a3_root/download" "$a3_root/source" "$a3_root/build" \
  "$a3_root/logs" "$a3_root/state" "$a3_root/tmp" \
  "$a3_root/empty-modules" "$a3_root/empty-engines"
printf '%s\n' "$a3_root" > "$a3_root/state/owned-root.txt"
/usr/bin/stat -f '%u %Lp %HT' "$a3_root" > "$a3_root/state/original.txt"
/bin/date -u '+%Y-%m-%dT%H:%M:%SZ' > "$a3_root/logs/start.txt"
a3_env() {
  /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin TMPDIR="$a3_root/tmp/" \
    MACOSX_DEPLOYMENT_TARGET=27.0 OPENSSL_CONF=/dev/null \
    OPENSSL_MODULES="$a3_root/empty-modules" OPENSSL_ENGINES="$a3_root/empty-engines" "$@"
}
a3_env /usr/bin/curl --disable --fail --silent --show-error --location \
  --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 180 \
  --output "$a3_root/download/openssl-3.5.9.tar.gz" \
  https://github.com/openssl/openssl/releases/download/openssl-3.5.9/openssl-3.5.9.tar.gz
cd "$a3_root/download"
printf '%s\n' '603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a  openssl-3.5.9.tar.gz' > SHA256.expected
/usr/bin/shasum -a 256 -c SHA256.expected > "$a3_root/logs/archive-verification.txt"
/usr/bin/tar -xzf openssl-3.5.9.tar.gz -C "$a3_root/source"
a3_source="$a3_root/source/openssl-3.5.9"
/bin/cp "$a3_source/VERSION.dat" "$a3_root/logs/VERSION.dat"
/bin/cp "$a3_source/LICENSE.txt" "$a3_root/logs/LICENSE.txt"
a3_env /usr/bin/xcodebuild -version > "$a3_root/logs/xcode.txt"
a3_env /usr/bin/xcrun swift --version > "$a3_root/logs/swift.txt"
a3_env /usr/bin/xcode-select -p > "$a3_root/logs/developer-directory.txt"
a3_env /usr/bin/sw_vers > "$a3_root/logs/macos.txt"
cd "$a3_root/build"
a3_env /usr/bin/perl "$a3_source/Configure" darwin64-arm64 \
  no-shared no-module no-legacy --prefix="$a3_root/prefix-not-installed" \
  --openssldir="$a3_root/config-not-used" > "$a3_root/logs/configure.log" 2>&1
a3_env /usr/bin/make -j2 build_libs > "$a3_root/logs/build.log" 2>&1
a3_env /usr/bin/make -j2 test \
  TESTS='test_dh test_dhparam test_dhparam_check test_evp test_rand' \
  VF=1 > "$a3_root/logs/upstream-tests.log" 2>&1
/usr/bin/shasum -a 256 libcrypto.a > "$a3_root/logs/libcrypto.sha256"
/bin/date -u '+%Y-%m-%dT%H:%M:%SZ' > "$a3_root/logs/end.txt"
