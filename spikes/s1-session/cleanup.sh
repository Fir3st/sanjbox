#!/bin/bash
# S1 (WP1.A1): removes what create-users.sh and run-probe.sh added. Idempotent; touches only
# records carrying the marker of these scripts and restores the Screen Sharing access group
# to its recorded state without removing members added by someone else.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
source "$SCRIPT_DIR/lib.sh"

usage() {
    cat <<EOF
usage: sudo ./cleanup.sh --state DIR [--apply]

For each S1 test user created by these scripts: ends its GUI and user launchd domains, kills
its remaining processes, verifies that none remain, deletes the account with its home and
deletes its keychain item. Removes the test users from $SNJ_ACCESS_GROUP and deletes that
group only if create-users.sh created it and it is now empty. Deletes group $SNJ_GROUP if
ours and empty, and $SNJ_INSTALL_DIR.

Turn Screen Sharing off first: with it on, a new login could start during cleanup.
Remove the LAN guard separately (lan-guard.sh --remove) after Screen Sharing is off.
Without --apply it prints what it would do; nothing changes.
EOF
}

parse_common_args "$@"
((${#REST[@]} == 0)) || {
    usage
    exit 2
}
host=$(host_user)

if screen_sharing_enabled; then
    ((APPLY)) && die "Screen Sharing is still enabled; turn it off in System Settings first"
    log "warning: Screen Sharing is enabled; --apply will refuse until it is off"
fi

for i in "${!SNJ_USERS[@]}"; do
    name=${SNJ_USERS[i]} uid=${SNJ_UIDS[i]}
    log "== user $name ($uid)"
    if ! record_exists "/Users/$name"; then
        log "absent"
    elif ! is_our_user "$name" "$uid"; then
        log "exists but was not created by these scripts; left untouched"
        continue
    else
        if [[ " $(group_members "$SNJ_ACCESS_GROUP") " == *" $name "* ]]; then
            step dseditgroup -o edit -d "$name" -t user "$SNJ_ACCESS_GROUP"
        fi
        step_tolerant launchctl bootout "gui/$uid"
        step_tolerant launchctl bootout "user/$uid"
        step_tolerant pkill -KILL -u "$uid"
        if ((APPLY)); then
            for _ in {1..20}; do
                pgrep -u "$uid" >/dev/null || break
                sleep 0.5
            done
            if pgrep -u "$uid" >/dev/null; then
                die "processes of $name remain: $(pgrep -u "$uid" | tr '\n' ' '); the account was not deleted"
            fi
            log "no processes of UID $uid remain"
        fi
        step sysadminctl -deleteUser "$name"
        if ((APPLY)); then
            record_exists "/Users/$name" && die "sysadminctl did not delete $name"
            [[ ! -e /Users/$name ]] || log "warning: /Users/$name still exists; inspect it manually (not deleted by path)"
        fi
    fi
    # A dry run never queries the keychain; --apply deletes the item if it is there.
    if ! ((APPLY)); then
        log "would delete keychain item $SNJ_KEYCHAIN_SERVICE/$name of $host if present"
    elif sudo -H -u "$host" security find-generic-password -s "$SNJ_KEYCHAIN_SERVICE" -a "$name" >/dev/null 2>&1; then
        step sudo -H -u "$host" security delete-generic-password -s "$SNJ_KEYCHAIN_SERVICE" -a "$name" >/dev/null
    fi
done

log "== $SNJ_ACCESS_GROUP"
if record_exists "/Groups/$SNJ_ACCESS_GROUP"; then
    members=$(group_members "$SNJ_ACCESS_GROUP")
    existed=$(state_get access_group_existed || true)
    if [[ $existed == 0 && -z $members ]]; then
        step dseditgroup -o delete "$SNJ_ACCESS_GROUP"
    elif [[ $existed == 0 ]]; then
        log "created by create-users.sh but now has other members ($members); left in place"
    elif [[ -z $existed ]]; then
        log "no recorded state; left in place with members: ${members:-none}"
    else
        log "existed before S1; members now: ${members:-none} (before: $(state_get access_group_members || true))"
    fi
else
    log "absent"
fi

log "== group $SNJ_GROUP"
if ! record_exists "/Groups/$SNJ_GROUP"; then
    log "absent"
elif ! is_our_group; then
    log "exists but was not created by these scripts; left untouched"
elif [[ -n $(group_members "$SNJ_GROUP") ]] && ((APPLY)); then
    log "still has members ($(group_members "$SNJ_GROUP")); left in place"
else
    step dseditgroup -o delete "$SNJ_GROUP"
fi

log "== $SNJ_INSTALL_DIR"
if [[ -L $SNJ_INSTALL_DIR ]]; then
    log "is a symlink; not following it, inspect manually"
elif [[ -d $SNJ_INSTALL_DIR ]]; then
    [[ $(stat -f %Su "$SNJ_INSTALL_DIR") == root ]] || die "$SNJ_INSTALL_DIR is not owned by root; inspect manually"
    step rm -rf "$SNJ_INSTALL_DIR"
    parent=$(dirname "$SNJ_INSTALL_DIR")
    step_tolerant rmdir "$parent"
else
    log "absent"
fi

if [[ $EUID -eq 0 && -n $(pfctl -a "$SNJ_PF_ANCHOR" -sr 2>/dev/null) ]]; then
    log "note: LAN guard anchor $SNJ_PF_ANCHOR is still loaded; remove it with lan-guard.sh --remove --apply"
fi
