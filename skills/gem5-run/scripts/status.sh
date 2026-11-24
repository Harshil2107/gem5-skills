#!/bin/bash
# One-shot status of gem5 runs: running or exited, hypercalls seen, results,
# crash signs and the last console line.
# Usage: status.sh [OUTDIR...]   (default: every run in runs/ that is still
#                                 running, plus the 3 most recent)

set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
source "$here/lib.sh"

dirs=("$@")
if [ ${#dirs[@]} -eq 0 ]; then
    gem5=$(default_gem5 2>/dev/null) || gem5=.
    runs=$(runs_dir "$gem5")
    mapfile -t all < <(ls -dt "$runs"/*/ 2>/dev/null | sed 's#/$##')
    for i in "${!all[@]}"; do
        d=${all[$i]}
        [ -f "$d/pid" ] || [ -f "$d/simout.txt" ] || [ -f "$d/simout" ] || continue
        if run_pid "$d" > /dev/null || [ "$i" -lt 3 ]; then dirs+=("$d"); fi
    done
    [ ${#dirs[@]} -gt 0 ] || { echo "No runs found in $runs."; exit 0; }
fi

# Crash signs. "consecutive SC failures" warnings are a running total that
# never resets, so they are not a sign of trouble.
crash_re='Kernel panic|unhandled signal|panic:|fatal:|Assertion .* failed|Program aborted|Segmentation fault|Validation failed|Exit events are not called in expected order'
result_re='Verification +=|Mop/s total|Build Time|Trial Time|Average Time|TEST (PASSED|FAILED)|PASSED|FAILED'

for d in "${dirs[@]}"; do
    d=${d%/}
    [ -d "$d" ] || { echo "== $d: not found"; continue; }
    simout=$d/simout.txt; [ -f "$simout" ] || simout=$d/simout
    simerr=$d/simerr.txt; [ -f "$simerr" ] || simerr=$d/simerr
    console=$(console_file "$d") || console=""

    if pid=$(run_pid "$d"); then
        state="running $(fmt_secs "$(ps -o etimes= -p "$pid" | tr -d ' ')") (pid $pid)"
    else
        pid=""; state="exited"
    fi

    hyper=$(grep -aioE 'hypercall [0-9]+' "$simout" 2>/dev/null | awk '{printf "%s ", $2}')
    passed=$(grep -ac 'All exit events are called in expected order' "$simout" 2>/dev/null)
    crash=$(cat "$simerr" "$simout" ${console:+"$console"} 2>/dev/null | grep -aE "$crash_re" | grep -v 'consecutive SC failures' | head -3)
    exitline=$(grep -a 'Exiting @ tick' "$simout" 2>/dev/null | tail -1)

    if [ "${passed:-0}" -gt 0 ]; then verdict=PASS
    elif [ -n "$crash" ]; then verdict=FAIL
    elif [ -n "$pid" ]; then verdict=RUNNING
    else
        code=$(cat "$d/exit-code" 2>/dev/null)
        case "$code" in
            0) verdict="EXITED OK (exit code 0)" ;;
            "") verdict="EXITED, exit code not recorded" ;;
            *) verdict="EXITED with code $code (check simerr)" ;;
        esac
        [ -n "$exitline" ] && verdict="$verdict: ${exitline#*because }"
    fi

    echo "== $(basename "$d"): $verdict, $state"
    [ -n "$hyper" ] && echo "   hypercalls: $hyper"
    [ -n "$crash" ] && sed 's/^/   ! /' <<< "$crash" | cut -c1-200
    if [ -n "$console" ]; then
        grep -aE "$result_re" "$console" | tail -4 | sed 's/^/   /' | cut -c1-160
        last=$(tail -c 4000 "$console" | tr -d '\r' | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\x1b\][^\\]*\\//g' | grep -av '^\s*$' | tail -1 | cut -c1-140)
        [ -n "$last" ] && echo "   console: $last"
    fi
done
