#!/bin/bash
# Start a gem5 run detached, with its output in the task folder's runs/.
# Usage: run.sh [--gem5 DIR] [--binary PATH] [--name NAME] [--json FILE]
#               [--env KEY=VALUE]... [--debug-flags FLAGS] [--debug-start TICK]
#               [--debug-file NAME] -- CONFIG [ARGS...]
#   --binary  default: build/ALL/gem5.opt, else the only build/*/gem5.opt
#   --json    local resources JSON added to the usual ones
#             (sets GEM5_RESOURCE_JSON_APPEND)
#   --env     any other environment variable for gem5, e.g.
#             GEM5_RESOURCE_JSON=/path.json (use only this JSON),
#             GEM5_CONFIG=/path/gem5-config.json, GEM5_RESOURCE_DIR=/path/cache
#   CONFIG    path from the current dir or from the gem5 dir
# Writes <outdir>/run-info.txt (command, binary, gem5 commit) and <outdir>/pid.

set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
source "$here/lib.sh"

gem5="" binary="" name="" json="" dflags="" dstart="" dfile=""
envs=()
while [ $# -gt 0 ]; do
    case "$1" in
        --gem5) gem5="$2"; shift 2 ;;
        --binary) binary="$2"; shift 2 ;;
        --name) name="$2"; shift 2 ;;
        --json) json=$(realpath "$2"); shift 2 ;;
        --env) [[ "$2" == [A-Za-z_]*=* ]] || { echo "--env needs KEY=VALUE"; exit 2; }; envs+=("$2"); shift 2 ;;
        --debug-flags) dflags="$2"; shift 2 ;;
        --debug-start) dstart="$2"; shift 2 ;;
        --debug-file) dfile="$2"; shift 2 ;;
        --) shift; break ;;
        *) echo "Unknown option $1 (put the config after --)"; exit 2 ;;
    esac
done
[ $# -ge 1 ] || { echo "Usage: $0 [options] -- CONFIG [ARGS...]"; exit 2; }
config="$1"; shift

gem5=${gem5:-$(default_gem5)} || { echo "No gem5 dir: pass --gem5, run from a task folder, or set GEM5_CLONE."; exit 2; }
gem5=$(realpath "$gem5")

if [ -f "$config" ]; then config=$(realpath "$config")
elif [ -f "$gem5/$config" ]; then config="$gem5/$config"
else echo "Config $config not found here or in $gem5."; exit 2; fi

if [ -z "$binary" ]; then
    if [ -x "$gem5/build/ALL/gem5.opt" ]; then
        binary="$gem5/build/ALL/gem5.opt"
    else
        mapfile -t found < <(ls "$gem5"/build/*/gem5.opt 2>/dev/null)
        [ ${#found[@]} -eq 1 ] || { echo "Pick a binary with --binary: found ${#found[@]} under $gem5/build/."; exit 2; }
        binary="${found[0]}"
    fi
elif [ -x "$gem5/$binary" ]; then
    binary="$gem5/$binary"
fi
[ -x "$binary" ] || { echo "Binary $binary not found."; exit 2; }
binary=$(realpath "$binary")

[ -n "$json" ] && envs=("GEM5_RESOURCE_JSON_APPEND=$json" "${envs[@]}")
if printf '%s\n' "${envs[@]}" | grep -q '^GEM5_RESOURCE_JSON=' &&
   printf '%s\n' "${envs[@]}" | grep -q '^GEM5_RESOURCE_JSON_APPEND='; then
    echo "gem5 refuses GEM5_RESOURCE_JSON and GEM5_RESOURCE_JSON_APPEND together; use one."; exit 2
fi
for e in "${envs[@]}"; do
    case "${e%%=*}" in
        GEM5_RESOURCE_JSON|GEM5_RESOURCE_JSON_APPEND|GEM5_CONFIG|GEM5_RESOURCE_DIR)
            v="${e#*=}"
            [[ "$v" == http* ]] || [ -e "$v" ] || echo "Warning: ${e%%=*} points at $v, which doesn't exist." ;;
    esac
done

name=${name:-$(basename "$config" .py)}
runs=$(runs_dir "$gem5")
outdir="$runs/$name-$(date +%Y%m%d-%H%M)"
[ ! -e "$outdir" ] || { echo "$outdir already exists; pick another --name."; exit 1; }
mkdir -p "$outdir"

cmd=("$binary" -d "$outdir" -re)
[ -n "$dflags" ] && cmd+=(--debug-flags="$dflags")
[ -n "$dstart" ] && cmd+=(--debug-start="$dstart")
[ -n "$dfile" ] && cmd+=(--debug-file="$dfile")
cmd+=("$config" "$@")

{
    echo "started   $(date '+%F %T') on $(hostname)"
    echo "gem5      $gem5 ($(git -C "$gem5" describe --always --dirty 2>/dev/null))"
    echo "branch    $(git -C "$gem5" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    echo "changes   $(git -C "$gem5" status --short --untracked-files=no 2>/dev/null | wc -l) modified files"
    echo "binary    $binary (built $(date -r "$binary" '+%F %T'))"
    for e in "${envs[@]}"; do echo "env       $e"; done
    printf 'command   cd %q &&' "$gem5"
    for e in "${envs[@]}"; do printf ' %s=%q' "${e%%=*}" "${e#*=}"; done
    printf ' %q' "${cmd[@]}"; echo
} > "$outdir/run-info.txt"
git -C "$gem5" diff > "$outdir/gem5.diff" 2>/dev/null || true
[ -s "$outdir/gem5.diff" ] || rm -f "$outdir/gem5.diff"

# A small shell runs gem5 and records its pid (gem5.pid) and exit code
# (exit-code). It leads its own process group, so `kill -- -<pid>` stops both.
cd "$gem5"
for e in "${envs[@]}"; do export "${e?}"; done
setsid nohup bash -c 'out=$1; shift; "$@" & echo $! > "$out/gem5.pid"; wait $!; echo $? > "$out/exit-code"' \
    _ "$outdir" "${cmd[@]}" > "$outdir/launch.log" 2>&1 < /dev/null &
echo $! > "$outdir/pid"

# Wait until gem5 itself is running (not the shell that starts it), so status
# and watch see the run right away.
for _ in $(seq 20); do
    run_pid "$outdir" > /dev/null && break
    kill -0 "$(cat "$outdir/pid")" 2>/dev/null || break
    sleep 0.25
done

echo "pid     $(cat "$outdir/pid")  (stop with: kill -- -$(cat "$outdir/pid"))"
echo "outdir  $outdir"
