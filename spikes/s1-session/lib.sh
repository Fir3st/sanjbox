# Shared configuration and helpers of the S1 scripts. Sourced, never executed directly.
# shellcheck shell=bash

readonly SNJ_GROUP=sanjbox
readonly SNJ_GID=4500
readonly SNJ_USERS=(snjt1 snjt2 snjt3)
readonly SNJ_UIDS=(4501 4502 4503)
# Comment attribute on every directory record these scripts create; cleanup touches only those.
readonly SNJ_MARKER=sanjbox-s1-test
readonly SNJ_KEYCHAIN_SERVICE=sanjbox-s1
readonly SNJ_ACCESS_GROUP=com.apple.access_screensharing
readonly SNJ_INSTALL_DIR="/Library/Application Support/Sanjbox/s1"
readonly SNJ_PF_ANCHOR=com.apple/sanjbox-s1
# Screen Sharing (5900, 5901-5902 for additional displays), Apple Remote Desktop (3283), SSH (22).
readonly SNJ_GUARDED_PORTS="22 3283 5900 5901 5902"

APPLY=0
STATE_DIR=""

log() { printf '%s\n' "$*" >&2; }
die() {
    log "error: $*"
    exit 2
}

# With --apply runs the command, otherwise prints it. Never pass a secret as an argument:
# arguments are visible to other processes and are printed here.
step() {
    if ((APPLY)); then
        log "+ $*"
        "$@"
    else
        log "would run: $*"
    fi
}

# Like step, but a failure is reported and tolerated (cleanup of something that may be gone).
step_tolerant() {
    if ((APPLY)); then
        log "+ $*"
        "$@" || log "  (failed with $?, continuing)"
    else
        log "would run: $*"
    fi
}

# Parses --apply, --state DIR and --help; leaves other arguments in REST.
parse_common_args() {
    REST=()
    while (($#)); do
        case $1 in
        --apply) APPLY=1 ;;
        --state)
            (($# >= 2)) || die "--state needs a directory"
            STATE_DIR=$2
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *) REST+=("$1") ;;
        esac
        shift
    done
    if ((APPLY)); then
        [[ $EUID -eq 0 ]] || die "--apply needs root: run it with sudo from your own account"
        [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]] || die "run --apply via sudo from your own account, not as root directly"
    fi
    return 0
}

# The account that ran sudo; in a dry run without sudo, the current user.
host_user() {
    if [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then printf '%s' "$SUDO_USER"; else id -un; fi
}

require_state_dir() {
    [[ -n $STATE_DIR ]] || die "--state DIR is required with --apply (the run's state/ directory, GUIDE §6)"
    if ((APPLY)); then
        mkdir -p "$STATE_DIR"
        chown "$(host_user)" "$STATE_DIR"
    fi
}

# Original state is recorded once: a repeated run must not overwrite what was there before the
# first change, or cleanup would restore an intermediate state.
state_file() { printf '%s/s1-state.env' "$STATE_DIR"; }

state_set_once() {
    local key=$1 value=$2 file
    file=$(state_file)
    [[ -f $file ]] && grep -q "^$key=" "$file" && return 0
    printf '%s=%s\n' "$key" "$value" >>"$file"
    chown "$(host_user)" "$file"
}

state_get() {
    local file
    file=$(state_file)
    [[ -n $STATE_DIR && -f $file ]] || return 1
    grep "^$1=" "$file" | head -n 1 | cut -d= -f2-
}

# First value of a directory attribute, or nothing when the record or attribute is missing.
read_attr() {
    local path=$1 attr=$2
    dscl -plist . -read "$path" "$attr" 2>/dev/null |
        plutil -extract "dsAttrTypeStandard:$attr.0" raw -o - - 2>/dev/null || true
}

record_exists() { dscl . -read "$1" RecordName >/dev/null 2>&1; }

# Space-separated GroupMembership of a group (names cannot contain spaces).
group_members() {
    dscl . -read "/Groups/$1" GroupMembership 2>/dev/null | sed -n 's/^GroupMembership: //p'
}

# A test user these scripts created: marker comment and the expected UID.
is_our_user() {
    local name=$1 uid=$2
    [[ $(read_attr "/Users/$name" Comment) == "$SNJ_MARKER" && $(read_attr "/Users/$name" UniqueID) == "$uid" ]]
}

is_our_group() {
    [[ $(read_attr "/Groups/$SNJ_GROUP" Comment) == "$SNJ_MARKER" && $(read_attr "/Groups/$SNJ_GROUP" PrimaryGroupID) == "$SNJ_GID" ]]
}

screen_sharing_enabled() {
    launchctl print-disabled system 2>/dev/null | grep -q '"com.apple.screensharing" => enabled'
}
