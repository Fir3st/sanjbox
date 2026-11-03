#!/bin/bash
# S1 (WP1.A1): runs sanjbox-s1-probe as a test user inside that user's GUI session and stores
# the measurement in the run's evidence directory.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
source "$SCRIPT_DIR/lib.sh"

usage() {
    cat <<EOF
usage: sudo ./run-probe.sh --user NAME --run DIR [--case ID] [--render-seconds N] [--apply]

Runs the probe in the bootstrap and audit session of NAME's GUI session (launchctl asuser) with
NAME's credentials (sudo -u NAME), checked against an expectation written before the run:
UID/GID, primary group $SNJ_GROUP, not staff/admin, launchd domain Aqua of NAME, window
server session of NAME, not on console, and not the host console's audit session.

DIR is the run directory (docs/evidence/s1/<date>-<run>); written there:
  inputs/expect-NAME.json   the expectation
  raw/s1-probe.jsonl        one measurement line per run (appended)
  raw/s1-probe-<stamp>-NAME.stderr
Build first, as yourself: swift build -c release
Without --apply it prints what it would do; nothing changes.
Exit codes: 0 measured, 3 invalid measurement or no GUI session for NAME, 2 usage/setup error.
EOF
}

parse_common_args "$@"
user="" run="" case_id="" render_seconds=5
set -- "${REST[@]+"${REST[@]}"}"
while (($#)); do
    case $1 in
    --user | --run | --case | --render-seconds)
        (($# >= 2)) || die "$1 needs a value"
        case $1 in
        --user) user=$2 ;;
        --run) run=$2 ;;
        --case) case_id=$2 ;;
        --render-seconds) render_seconds=$2 ;;
        esac
        shift
        ;;
    *)
        usage
        exit 2
        ;;
    esac
    shift
done
[[ -n $user && -n $run ]] || {
    usage
    exit 2
}
[[ $render_seconds =~ ^[0-9]+$ && $render_seconds -ge 1 && $render_seconds -le 600 ]] || die "--render-seconds must be 1-600"
[[ -z $case_id || $case_id =~ ^[A-Z]+-[0-9]+$ ]] || die "--case must look like GUI-05"

uid=""
for i in "${!SNJ_USERS[@]}"; do [[ ${SNJ_USERS[i]} == "$user" ]] && uid=${SNJ_UIDS[i]}; done
[[ -n $uid ]] || die "$user is not one of the S1 test users (${SNJ_USERS[*]})"
is_our_user "$user" "$uid" || die "$user does not exist or was not created by create-users.sh"

host=$(host_user)
built="$SCRIPT_DIR/.build/release/sanjbox-s1-probe"
[[ -x $built ]] || die "missing $built; build it first as $host: swift build -c release"
[[ $(stat -f %Su "$built") == "$host" ]] || die "$built is not owned by $host"

bin_dir="$SNJ_INSTALL_DIR/bin"
probe="$bin_dir/sanjbox-s1-probe"
expect="$SNJ_INSTALL_DIR/expect/$user.json"
stamp=$(date -u +%Y%m%dT%H%M%SZ)

if ! ((APPLY)); then
    log "would install $built as $probe (root:wheel 0755) so the test user can run it but not replace it"
    log "would write $expect and $run/inputs/expect-$user.json from the host console audit session"
    log "would check that gui/$uid exists (a logged-in session of $user)"
    log "would run: launchctl asuser $uid sudo -H -u $user $probe measure --expect $expect --render-seconds $render_seconds${case_id:+ --case $case_id}"
    log "would append the measurement to $run/raw/s1-probe.jsonl"
    exit 0
fi

install -d -o root -g wheel -m 0755 "$bin_dir" "$SNJ_INSTALL_DIR/expect"
install -o root -g wheel -m 0755 "$built" "$probe"
mkdir -p "$run/inputs" "$run/raw"
chown "$host" "$run" "$run/inputs" "$run/raw"

# The host console session is whatever session this sudo was started from; it must be the
# console (Terminal on your desktop), or the expectation would forbid the wrong session.
host_context=$(sudo -H -u "$host" "$probe" context)
[[ $(plutil -extract windowSession.onConsole raw -o - - <<<"$host_context" 2>/dev/null) == true ]] ||
    die "run this from Terminal in your console session; the current session is not the console"
host_session=$(plutil -extract audit.sessionID raw -o - - <<<"$host_context")
[[ $host_session =~ ^[0-9]+$ ]] || die "cannot determine the host console audit session"

cat >"$expect" <<EOF
{
  "effectiveUID": $uid,
  "realUID": $uid,
  "effectiveGID": $SNJ_GID,
  "realGID": $SNJ_GID,
  "userName": "$user",
  "requiredGroups": [$SNJ_GID],
  "forbiddenGroups": [20, 80],
  "launchdManagerName": "Aqua",
  "launchdManagerUID": $uid,
  "windowSessionUID": $uid,
  "onConsole": false,
  "forbiddenAuditSessionIDs": [$host_session]
}
EOF
chmod 0644 "$expect"
cp "$expect" "$run/inputs/expect-$user.json"
chown "$host" "$run/inputs/expect-$user.json"

if ! launchctl print "gui/$uid" >/dev/null 2>&1; then
    log "no GUI session for $user (gui/$uid does not exist)"
    printf '%s\t%s\tno-gui-session\n' "$stamp" "$user" >>"$run/raw/s1-probe-missing.tsv"
    chown "$host" "$run/raw/s1-probe-missing.tsv"
    exit 3
fi

arguments=(measure --expect "$expect" --render-seconds "$render_seconds")
[[ -z $case_id ]] || arguments+=(--case "$case_id")
stderr_file="$run/raw/s1-probe-$stamp-$user.stderr"
log "+ launchctl asuser $uid sudo -H -u $user $probe ${arguments[*]}"
status=0
measurement=$(launchctl asuser "$uid" sudo -H -u "$user" "$probe" "${arguments[@]}" 2>"$stderr_file") || status=$?
chown "$host" "$stderr_file"
[[ -n $measurement ]] || die "the probe produced no measurement (exit $status); see $stderr_file"
printf '%s\n' "$measurement" >>"$run/raw/s1-probe.jsonl"
chown "$host" "$run/raw/s1-probe.jsonl"

case $status in
0) log "measured; valid: $(plutil -extract valid raw -o - - <<<"$measurement")" ;;
3) log "INVALID measurement: credentials or session differ from the expectation (see mismatches)" ;;
*) log "probe exited with $status; see $stderr_file" ;;
esac
exit "$status"
