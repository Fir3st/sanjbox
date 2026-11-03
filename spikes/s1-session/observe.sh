#!/bin/bash
# S1 (WP1.A1): read-only observation of the test users' sessions. Reads only metadata: who is
# logged in, processes of the test UIDs (executable path, never arguments or environment),
# launchd domains and Screen Sharing listeners. Changes nothing, so it has no --apply.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
source "$SCRIPT_DIR/lib.sh"

usage() {
    cat <<EOF
usage: [sudo] ./observe.sh [--watch SECONDS] [--interval N]

Without --watch: prints one snapshot. With --watch: prints a TSV line per test user every N
seconds (default 1) for SECONDS, for login time (GUI-12) and survival without a client (GUI-02).
Redirect stdout into the run's raw/ directory. As root it also reports the launchd GUI and user
domains of each test UID (handle = audit session); without root those columns show "?".
EOF
}

watch=0 interval=1
while (($#)); do
    case $1 in
    --watch | --interval)
        (($# >= 2)) && [[ $2 =~ ^[0-9]+$ && $2 -ge 1 ]] || die "$1 needs a positive number"
        if [[ $1 == --watch ]]; then watch=$2; else interval=$2; fi
        shift
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        usage
        exit 2
        ;;
    esac
    shift
done

# uid pid ppid rss_kb etime executable — executable is the last field and may contain spaces.
process_table() { ps -axo uid=,pid=,ppid=,rss=,etime=,comm=; }

# Domain state of one UID: "1" present, "0" absent, "?" unknown without root.
domain_present() {
    if [[ $EUID -ne 0 ]]; then printf '?'; elif launchctl print "$1/$2" >/dev/null 2>&1; then printf 1; else printf 0; fi
}

# Count, RSS sum and presence of session processes for one UID, from a process table on stdin.
summarize_uid() {
    awk -v uid="$1" '
        $1 == uid {
            count++; rss += $4
            path = $0; sub(/^ *[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+ +/, "", path)
            n = split(path, parts, "/"); name = parts[n]
            if (name == "Dock") dock = 1
            if (name == "Finder") finder = 1
            if (name == "loginwindow") loginwindow = 1
        }
        END { printf "%d\t%d\t%d\t%d\t%d", count, rss, dock, finder, loginwindow }'
}

window_servers() { process_table | awk '$NF ~ /\/WindowServer$/ { n++ } END { print n + 0 }'; }

if ((watch)); then
    printf 'timestamp\tuser\tuid\tgui_domain\tuser_domain\tprocesses\trss_kb\tdock\tfinder\tloginwindow\twindow_servers\n'
    end=$((SECONDS + watch))
    while ((SECONDS < end)); do
        now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        table=$(process_table)
        servers=$(awk '$NF ~ /\/WindowServer$/ { n++ } END { print n + 0 }' <<<"$table")
        for i in "${!SNJ_USERS[@]}"; do
            uid=${SNJ_UIDS[i]}
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$now" "${SNJ_USERS[i]}" "$uid" \
                "$(domain_present gui "$uid")" "$(domain_present user "$uid")" "$(summarize_uid "$uid" <<<"$table")" "$servers"
        done
        sleep "$interval"
    done
    exit 0
fi

echo "# S1 snapshot $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "macOS: $(sw_vers -productVersion) ($(sw_vers -buildVersion)); console user: $(stat -f %Su /dev/console)"
echo
echo "## who"
who
echo
echo "## Screen Sharing"
if screen_sharing_enabled; then echo "service: enabled"; else echo "service: not enabled"; fi
echo "listeners:"
netstat -anv -p tcp 2>/dev/null | awk '$4 ~ /[.:](5900|5901|5902)$/ && $6 == "LISTEN" { print "  " $1, $4 }'
echo "access group $SNJ_ACCESS_GROUP: $(group_members "$SNJ_ACCESS_GROUP")"
echo
echo "## WindowServer processes: $(window_servers)"
process_table | awk '$NF ~ /\/WindowServer$/ { print "  pid " $2 ", rss " $4 " kB, elapsed " $5 }'
for i in "${!SNJ_USERS[@]}"; do
    name=${SNJ_USERS[i]} uid=${SNJ_UIDS[i]}
    echo
    echo "## $name (UID $uid)"
    if ! record_exists "/Users/$name"; then
        echo "account: absent"
        continue
    fi
    echo "account: present, ours: $(is_our_user "$name" "$uid" && echo yes || echo NO)"
    if [[ $EUID -eq 0 ]]; then
        for domain in gui user; do
            if launchctl print "$domain/$uid" >/dev/null 2>&1; then
                echo "$domain/$uid: $(launchctl print "$domain/$uid" 2>/dev/null |
                    awk -F' = ' '/^\t(type|handle|active count|service count) = / { sub(/^\t/, "", $1); printf "%s=%s ", $1, $2 }')"
            else
                echo "$domain/$uid: absent"
            fi
        done
    else
        echo "launchd domains: run with sudo to read"
    fi
    IFS=$'\t' read -r count rss dock finder loginwindow < <(process_table | summarize_uid "$uid")
    echo "processes: $count, rss $((rss / 1024)) MB, Dock $dock, Finder $finder, loginwindow $loginwindow"
    process_table | awk -v uid="$uid" '$1 == uid { path = $0; sub(/^ *[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+ +/, "", path); printf "  %6s %6s %8s kB %12s %s\n", $2, $3, $4, $5, path }'
done
