#!/bin/bash
# Turn gem5 debug flags on in a running simulation when a marker appears, and
# off again after a second marker or a number of seconds. Tracing a whole run
# slows it about 10x (even with --debug-start); this traces only the window
# that matters. Uses gem5's hypercall orchestrator (gem5 v25.0 or later, with
# the stdlib Simulator), so no restart is needed.
#
# Usage: trace-window.sh OUTDIR --flags Exec,Faults --on REGEX
#                        (--off REGEX | --for SECONDS) [--max-gb N] [--gem5 DIR]
#   OUTDIR    the run's output dir (has pid, and run-info.txt from gem5-run)
#   --on      start tracing when REGEX appears in the console or simout
#             (--on now starts right away)
#   --off     stop when REGEX appears;  --for  stop after SECONDS
#   --max-gb  stop anyway once the trace has grown by N GB (default 2)
# The trace goes to the run's --debug-file if it was started with one
# (gem5-run: run.sh --debug-file trace.out), else into simout. An Exec trace
# grows by gigabytes per minute, so keep the window short.

set -uo pipefail
outdir="" flags="" on="" off="" secs="" gem5="" max_gb=2
while [ $# -gt 0 ]; do
    case "$1" in
        --flags) flags="$2"; shift 2 ;;
        --on) on="$2"; shift 2 ;;
        --off) off="$2"; shift 2 ;;
        --for) secs="$2"; shift 2 ;;
        --max-gb) max_gb="$2"; shift 2 ;;
        --gem5) gem5="$2"; shift 2 ;;
        *) outdir=$(realpath "$1"); shift ;;
    esac
done
[ -n "$outdir" ] && [ -n "$flags" ] && [ -n "$on" ] && { [ -n "$off" ] || [ -n "$secs" ]; } ||
    { sed -n '8,17p' "$0"; exit 2; }

# gem5's own pid (gem5.pid from gem5-run), else the pid file.
pid=$(cat "$outdir/gem5.pid" 2>/dev/null || cat "$outdir/pid" 2>/dev/null) ||
    { echo "No pid file in $outdir."; exit 1; }
kill -0 "$pid" 2>/dev/null || { echo "Run $pid is not running."; exit 1; }
if [ -z "$gem5" ]; then
    gem5=$(sed -n 's/^gem5 *\([^ ]*\).*/\1/p' "$outdir/run-info.txt" 2>/dev/null)
fi
orch="$gem5/util/hypercall_external_signal/orchestrator_request.py"
[ -f "$orch" ] || { echo "No orchestrator at $orch (pass --gem5; needs gem5 v25.0+)."; exit 1; }

# Where the trace is written, to enforce --max-gb.
dfile=$(grep -o -- '--debug-file=[^ ]*' "$outdir/run-info.txt" 2>/dev/null | head -1 | cut -d= -f2)
trace="$outdir/${dfile:-simout.txt}"
max_bytes=$(( max_gb * 1024 * 1024 * 1024 ))

# Look for REGEX only in what was written since the last check, so the cost
# per check stays small even while a trace makes the file huge. Files that
# don't exist yet (gem5 creates simout and the console later) start at 0.
names=(board.pc.com_1.device board.platform.terminal board.terminal
       system.pc.com_1.device system.terminal simout.txt simout)
declare -A done_to
mark() {
    local f
    for f in "${names[@]}"; do
        done_to[$f]=$(stat -c %s "$outdir/$f" 2>/dev/null || echo 0)
    done
}
seen() {
    local f size from hit=1
    for f in "${names[@]}"; do
        [ -f "$outdir/$f" ] || continue
        size=$(stat -c %s "$outdir/$f")
        from=${done_to[$f]:-0}
        [ "$size" -gt "$from" ] || continue
        # Re-read the last 200 bytes too, in case the marker was cut in half.
        [ "$from" -gt 200 ] && from=$((from - 200)) || from=0
        tail -c +"$((from + 1))" "$outdir/$f" | head -c "$((size - from))" | grep -aqE -- "$1" && hit=0
        done_to[$f]=$size
    done
    return $hit
}
set_flags() {
    ( cd "$(dirname "$orch")" && python3 orchestrator_request.py --pid "$pid" \
        update_debug_flags --debug-flags-to-update="$1" )
}
alive() { kill -0 "$pid" 2>/dev/null; }
too_big() { [ $(( $(stat -c %s "$trace" 2>/dev/null || echo 0) - trace_start )) -gt "$max_bytes" ]; }

mark
if [ "$on" != now ]; then
    echo "Waiting for /$on/ ..."
    until seen "$on"; do alive || { echo "Run exited before /$on/."; exit 1; }; sleep 1; done
fi
trace_start=$(stat -c %s "$trace" 2>/dev/null || echo 0)
echo "$(date +%T) /$on/ seen: turning on $flags (trace: $trace, cap ${max_gb} GB)"
set_flags "$flags"

why=""
start=$(date +%s)
while alive; do
    if too_big; then why="trace grew past ${max_gb} GB"; break; fi
    if [ -n "$secs" ]; then
        [ $(( $(date +%s) - start )) -ge "$secs" ] && { why="${secs}s passed"; break; }
    elif seen "$off"; then
        why="/$off/ seen"; break
    fi
    sleep 1
done
alive || { echo "Run exited while tracing."; exit 0; }

echo "$(date +%T) $why: turning off $flags"
set_flags "$(echo "$flags" | sed 's/\([^,]\+\)/-\1/g')"
echo "trace size: $(( ($(stat -c %s "$trace") - trace_start) / 1024 / 1024 )) MB in $trace"
