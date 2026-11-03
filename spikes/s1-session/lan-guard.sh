#!/bin/bash
# S1 (WP1.A1): keeps Screen Sharing reachable only from this Mac while S1 runs (PLAN S1:
# "port 5900 nevystavovat do LAN"). Blocks inbound traffic to the guarded ports on every
# interface except lo0, in a pf anchor of its own.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
source "$SCRIPT_DIR/lib.sh"

usage() {
    cat <<EOF
usage: sudo ./lan-guard.sh --state DIR [--remove] [--apply]

Loads pf anchor $SNJ_PF_ANCHOR blocking inbound TCP/UDP to ports $SNJ_GUARDED_PORTS on all
interfaces except lo0, and enables pf with a reference token (pfctl -E). --remove flushes the
anchor and releases only that token, so pf stays as other users of it left it.

Load it before turning Screen Sharing on, remove it after turning Screen Sharing off.
The anchor is not persistent: after a reboot it is gone, so turn Screen Sharing off before rebooting.
Without --apply it prints what it would do; nothing changes.
EOF
}

parse_common_args "$@"
remove=0
for argument in "${REST[@]+"${REST[@]}"}"; do
    case $argument in
    --remove) remove=1 ;;
    *)
        usage
        exit 2
        ;;
    esac
done

rules="block drop in quick on ! lo0 proto { tcp udp } from any to any port { $SNJ_GUARDED_PORTS }"

if [[ $EUID -ne 0 ]]; then
    log "not root: pf state cannot be read; showing the plan only"
    if ((remove)); then
        log "would run: pfctl -a $SNJ_PF_ANCHOR -F rules; pfctl -X <token recorded in state>"
    else
        log "would load into $SNJ_PF_ANCHOR: $rules"
        log "would run: pfctl -E (and record its token)"
    fi
    exit 0
fi

if ((remove)); then
    step pfctl -a "$SNJ_PF_ANCHOR" -F rules
    if token=$(state_get pf_token) && [[ -n $token ]]; then
        step_tolerant pfctl -X "$token"
    else
        log "no pf token recorded in state; pf enable reference left as is"
    fi
    if ((APPLY)); then
        [[ -z $(pfctl -a "$SNJ_PF_ANCHOR" -sr 2>/dev/null) ]] || die "anchor $SNJ_PF_ANCHOR still has rules"
        log "anchor $SNJ_PF_ANCHOR is empty; pf: $(pfctl -si 2>/dev/null | sed -n 's/^Status: //p')"
    fi
    exit 0
fi

# pf evaluates our anchor only if the main ruleset calls Apple's anchor point, as the stock
# /etc/pf.conf does. Without it the guard would load and silently not apply.
pfctl -sr 2>/dev/null | grep -Fq 'anchor "com.apple/*"' ||
    die 'the loaded main pf ruleset has no anchor "com.apple/*"; the guard would not apply. Nothing changed.'

if ((APPLY)); then
    require_state_dir
    rules_file="$STATE_DIR/lan-guard.pf"
    printf '%s\n' "$rules" >"$rules_file"
    step pfctl -a "$SNJ_PF_ANCHOR" -f "$rules_file"
    # The token is recorded once; a repeated load must not leak a second reference.
    if state_get pf_token >/dev/null; then
        log "pf token already recorded; not taking another reference"
    else
        token=$(pfctl -E 2>&1 | sed -n 's/^Token : //p')
        [[ -n $token ]] || die "pfctl -E returned no token"
        state_set_once pf_token "$token"
    fi
    pfctl -a "$SNJ_PF_ANCHOR" -sr 2>/dev/null | grep -q 'block drop in quick' || die "anchor rules did not load"
    pfctl -si 2>/dev/null | grep -q '^Status: Enabled' || die "pf is not enabled"
    log "guard active: $(pfctl -a "$SNJ_PF_ANCHOR" -sr 2>/dev/null | tr '\n' ' ')"
    log "verify from another device on the LAN: nc -vz -w 3 <this Mac's IP> 5900 must fail"
else
    log "would load into $SNJ_PF_ANCHOR: $rules"
    log "would run: pfctl -E (and record its token in state)"
fi
