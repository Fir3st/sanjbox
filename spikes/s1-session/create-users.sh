#!/bin/bash
# S1 (WP1.A1): creates the three hidden test users whose sessions S1 measures.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
source "$SCRIPT_DIR/lib.sh"

usage() {
    cat <<EOF
usage: sudo ./create-users.sh --state DIR [--apply]

Creates hidden standard users ${SNJ_USERS[*]} (UID ${SNJ_UIDS[*]}) with primary group
$SNJ_GROUP ($SNJ_GID), outside staff and admin. Each gets a random password that is stored only in
your login keychain (service $SNJ_KEYCHAIN_SERVICE, account = user name) and never printed.
The users are added to $SNJ_ACCESS_GROUP, so Screen Sharing admits them.

Without --apply it checks the system and prints what it would do; nothing changes.
DIR is the run's state/ directory; the original state of what is changed is recorded there.
Undo with cleanup.sh.
EOF
}

parse_common_args "$@"
((${#REST[@]} == 0)) || {
    usage
    exit 2
}
host=$(host_user)

log "== preflight (read-only)"
problems=0
if record_exists "/Groups/$SNJ_GROUP"; then
    if is_our_group; then log "group $SNJ_GROUP: exists, created by these scripts"; else
        log "group $SNJ_GROUP: exists and was not created by these scripts"
        problems=1
    fi
else
    holder=$(dscl . -search /Groups PrimaryGroupID "$SNJ_GID" 2>/dev/null | awk 'NR == 1 { print $1 }')
    if [[ -n $holder ]]; then
        log "GID $SNJ_GID: already used by group $holder"
        problems=1
    fi
fi
for i in "${!SNJ_USERS[@]}"; do
    name=${SNJ_USERS[i]} uid=${SNJ_UIDS[i]}
    if record_exists "/Users/$name"; then
        if ! is_our_user "$name" "$uid"; then
            log "user $name: name taken by an account these scripts did not create"
            problems=1
        elif ! dscl . -read "/Users/$name" AuthenticationAuthority 2>/dev/null | grep -q ShadowHash; then
            log "user $name: ours but has no password (interrupted run); run cleanup.sh first"
            problems=1
        else
            log "user $name: exists, created by these scripts"
        fi
    else
        holder=$(dscl . -search /Users UniqueID "$uid" 2>/dev/null | awk 'NR == 1 { print $1 }')
        if [[ -n $holder ]]; then
            log "UID $uid: already used by $holder"
            problems=1
        fi
    fi
done
if record_exists "/Groups/$SNJ_ACCESS_GROUP"; then
    log "$SNJ_ACCESS_GROUP: exists, members: $(group_members "$SNJ_ACCESS_GROUP")"
else
    log "$SNJ_ACCESS_GROUP: does not exist (Screen Sharing currently admits all users)"
fi
screen_sharing_enabled && log "Screen Sharing: ENABLED; enable lan-guard.sh before any test login" || log "Screen Sharing: off"
((problems == 0)) || die "preflight found problems; nothing was changed"

if ((APPLY)); then
    require_state_dir
    if record_exists "/Groups/$SNJ_ACCESS_GROUP"; then
        state_set_once access_group_existed 1
        state_set_once access_group_members "$(group_members "$SNJ_ACCESS_GROUP")"
    else
        state_set_once access_group_existed 0
    fi
fi

log "== group $SNJ_GROUP"
if record_exists "/Groups/$SNJ_GROUP"; then log "exists, skipping"; else
    step dseditgroup -o create -i "$SNJ_GID" -r "Sanjbox S1 test zones" -c "$SNJ_MARKER" "$SNJ_GROUP"
fi

# The password leaves the shell only through stdin of `security -i` (keychain) and argv of
# sysadminctl. sysadminctl offers no non-interactive alternative; its argv is briefly visible
# to processes already running on the host, which the threat model trusts, and it unlocks
# only an empty test account.
create_user() {
    local name=$1 uid=$2 path=/Users/$1 password
    if ! ((APPLY)); then
        log "would generate a 32-character random password and store it in $host's login keychain"
        log "  (service $SNJ_KEYCHAIN_SERVICE, account $name), never printed"
        log "would run: sysadminctl -addUser $name -fullName 'Sanjbox test $name' -UID $uid -GID $SNJ_GID -shell /bin/zsh -home $path -password <generated>"
        log "would run: dscl . -create $path Comment $SNJ_MARKER; dscl . -create $path IsHidden 1"
        return
    fi
    password=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32 || true)
    ((${#password} == 32)) || die "cannot generate a password"

    log "+ store the password of $name in $host's login keychain (not printed)"
    printf 'add-generic-password -U -s %s -a %s -l %s -w %s\n' \
        "$SNJ_KEYCHAIN_SERVICE" "$name" "$SNJ_KEYCHAIN_SERVICE-$name" "$password" |
        sudo -H -u "$host" security -i >/dev/null 2>&1 || true
    sudo -H -u "$host" security find-generic-password -s "$SNJ_KEYCHAIN_SERVICE" -a "$name" >/dev/null 2>&1 ||
        die "the password of $name did not reach the keychain (is it unlocked?); no account was created"

    log "+ sysadminctl -addUser $name -fullName 'Sanjbox test $name' -UID $uid -GID $SNJ_GID -shell /bin/zsh -home $path -password <generated>"
    sysadminctl -addUser "$name" -fullName "Sanjbox test $name" -UID "$uid" -GID "$SNJ_GID" \
        -shell /bin/zsh -home "$path" -password "$password"
    password=""
    record_exists "$path" || die "sysadminctl did not create $name"
    [[ $(read_attr "$path" UniqueID) == "$uid" ]] ||
        die "$name was created with an unexpected UID; inspect it and remove it with: sudo sysadminctl -deleteUser $name"
    step dscl . -create "$path" Comment "$SNJ_MARKER"
    step dscl . -create "$path" IsHidden 1
}

for i in "${!SNJ_USERS[@]}"; do
    name=${SNJ_USERS[i]} uid=${SNJ_UIDS[i]}
    log "== user $name ($uid)"
    if record_exists "/Users/$name"; then log "exists, skipping"; else create_user "$name" "$uid"; fi
    [[ " $(group_members "$SNJ_GROUP") " == *" $name "* ]] || step dseditgroup -o edit -a "$name" -t user "$SNJ_GROUP"
done

log "== $SNJ_ACCESS_GROUP"
if ! record_exists "/Groups/$SNJ_ACCESS_GROUP"; then
    step dseditgroup -o create -r "Screen Sharing ACL" "$SNJ_ACCESS_GROUP"
fi
for name in "${SNJ_USERS[@]}"; do
    [[ " $(group_members "$SNJ_ACCESS_GROUP") " == *" $name "* ]] || step dseditgroup -o edit -a "$name" -t user "$SNJ_ACCESS_GROUP"
done

if ((APPLY)); then
    log "== result"
    for i in "${!SNJ_USERS[@]}"; do
        name=${SNJ_USERS[i]}
        log "$name: UID $(read_attr "/Users/$name" UniqueID), primary GID $(read_attr "/Users/$name" PrimaryGroupID)," \
            "hidden $(read_attr "/Users/$name" IsHidden), home $(stat -f '%Su %Lp' "/Users/$name" 2>/dev/null || echo missing)"
        log "  groups: $(id -Gn "$name")"
        log "  staff: $(dsmemberutil checkmembership -U "$name" -G staff); admin: $(dsmemberutil checkmembership -U "$name" -G admin)"
    done
    log "$SNJ_ACCESS_GROUP members: $(group_members "$SNJ_ACCESS_GROUP")"
    log "S1 measures membership authoritatively in the probe (GUI-11); the lines above are informational."
fi
