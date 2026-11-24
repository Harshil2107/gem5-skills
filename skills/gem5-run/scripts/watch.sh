#!/bin/bash
# Wait on gem5 runs and return as soon as something happens, then print their
# status. Meant to be started in the background; its exit is the notification.
# Usage: watch.sh [--all] [--until REGEX] OUTDIR...
#   default    return when any of the runs exits (passed or crashed)
#   --all      return only when all of them have exited
#   --until    also return when REGEX shows up in a run's simout or console
#              (for example 'Hypercall 1' or 'Build Time')

set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
source "$here/lib.sh"

mode=any until=""
dirs=()
while [ $# -gt 0 ]; do
    case "$1" in
        --all) mode=all; shift ;;
        --until) until="$2"; shift 2 ;;
        *) dirs+=("$(realpath "$1")"); shift ;;
    esac
done
[ ${#dirs[@]} -gt 0 ] || { echo "Usage: $0 [--all] [--until REGEX] OUTDIR..."; exit 2; }

# Only runs that are alive now count; a run that already exited won't trigger.
alive=()
for d in "${dirs[@]}"; do run_pid "$d" > /dev/null && alive+=("$d"); done

matched() {
    local d f
    [ -n "$until" ] || return 1
    for d in "${alive[@]}"; do
        for f in "$d/simout.txt" "$d/simout" "$(console_file "$d")"; do
            [ -f "$f" ] && grep -aqE -- "$until" "$f" && { echo "matched '$until' in $(basename "$d")"; return 0; }
        done
    done
    return 1
}

if [ ${#alive[@]} -gt 0 ] && ! matched; then
    while true; do
        sleep 30
        left=0
        for d in "${alive[@]}"; do run_pid "$d" > /dev/null && left=$((left + 1)); done
        if [ $mode = any ] && [ $left -lt ${#alive[@]} ]; then break; fi
        if [ $left -eq 0 ]; then break; fi
        matched && break
    done
fi

"$here/status.sh" "${dirs[@]}"
