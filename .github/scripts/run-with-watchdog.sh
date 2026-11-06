#!/bin/bash
# Run a command with a hard time limit. On timeout, record the thread stacks of the
# whole process tree (so a hung test is diagnosable from the uploaded logs), stop the
# tree and fail. Usage: run-with-watchdog.sh SECONDS LOG_DIR COMMAND [ARGS...]
set -uo pipefail

limit=$1 log_dir=$2
shift 2
mkdir -p "$log_dir"

"$@" &
child=$!

descendants() {
  local pid
  for pid in $(pgrep -P "$1"); do
    echo "$pid"
    descendants "$pid"
  done
}

deadline=$((SECONDS + limit))
while kill -0 "$child" 2>/dev/null; do
  if ((SECONDS >= deadline)); then
    tree=$(descendants "$child")
    echo "::error::Timed out after ${limit}s: $*. Thread stacks of the hung processes are in the uploaded logs."
    ps -o pid=,ppid=,etime=,command= -p "$(echo "$child" $tree | tr ' ' ',')" | tee "$log_dir/hung-processes.txt"
    for pid in $child $tree; do
      name=$(ps -o comm= -p "$pid" 2>/dev/null | xargs basename 2>/dev/null) || continue
      /usr/bin/sample "$pid" 3 -file "$log_dir/stack-$name-$pid.txt" >/dev/null 2>&1 || true
      if [[ -f "$log_dir/stack-$name-$pid.txt" ]]; then
        echo "::group::Thread stacks of $name ($pid)"
        sed -n '/^Call graph:/,/^Total number in stack/p' "$log_dir/stack-$name-$pid.txt" | head -400
        echo "::endgroup::"
      fi
    done
    kill -TERM $tree "$child" 2>/dev/null
    sleep 5
    kill -KILL $tree "$child" 2>/dev/null
    wait "$child" 2>/dev/null
    exit 124
  fi
  sleep 2
done
wait "$child"
