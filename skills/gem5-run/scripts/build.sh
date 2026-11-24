#!/bin/bash
# Build gem5, logging to the task folder's runs/. Default: build/ALL/gem5.opt.
# Runs in the foreground: start it in the background and wait for it to exit.
# Usage: build.sh [TARGET] [--gem5 DIR] [--variant opt|debug|fast] [-j N]
#                 [--keep-old] [--dry-run]
#   TARGET  ALL (default), an ISA like X86 or RISCV, or ISA/gem5.VARIANT
#           (e.g. X86/gem5.fast, build/RISCV/gem5.debug)
#   --keep-old  copy the current binary to gem5.<variant>.prev first, so the
#               old and new builds can be run side by side.
# Prints the binary path on success; exits non-zero on failure.

set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
source "$here/lib.sh"

isa=ALL variant=opt
if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then
    t="${1#build/}"; shift
    isa=$(echo "${t%%/*}" | tr 'a-z' 'A-Z')
    [[ "$t" == */* ]] && variant="${t#*/gem5.}"
fi
gem5="" jobs=$(( $(nproc) > 4 ? $(nproc) - 4 : 1 )) keep=0 dry=0
while [ $# -gt 0 ]; do
    case "$1" in
        --gem5) gem5="$2"; shift 2 ;;
        --variant) variant="$2"; shift 2 ;;
        -j) jobs="$2"; shift 2 ;;
        --keep-old) keep=1; shift ;;
        --dry-run) dry=1; shift ;;
        *) echo "Unknown option $1"; exit 2 ;;
    esac
done
[[ "$isa" =~ ^[A-Z0-9_]+$ ]] && [[ "$variant" =~ ^(opt|debug|fast|prof|perf)$ ]] ||
    { echo "Bad target: use ALL, an ISA (X86, ARM, RISCV, ...) or ISA/gem5.VARIANT (opt, debug, fast)."; exit 2; }
gem5=${gem5:-$(default_gem5)} || { echo "No gem5 dir: pass --gem5, run from a task folder, or set GEM5_CLONE."; exit 2; }
gem5=$(realpath "$gem5")
[ -f "$gem5/SConstruct" ] || { echo "$gem5 is not a gem5 checkout."; exit 2; }

target="build/$isa/gem5.$variant"
runs=$(runs_dir "$gem5")
log="$runs/build-$isa-$variant-$(date +%Y%m%d-%H%M).log"

if pgrep -f "scons.* $target" > /dev/null && \
   pgrep -af "scons.* $target" | grep -q "$gem5"; then
    echo "A build of $target is already running in $gem5."; exit 1
fi

echo "gem5    $gem5 ($(git -C "$gem5" describe --always --dirty 2>/dev/null))"
echo "target  $target, -j$jobs"
echo "log     $log"
[ $dry -eq 1 ] && { echo "Dry run: not building."; exit 0; }

mkdir -p "$runs"
if [ $keep -eq 1 ] && [ -f "$gem5/$target" ]; then
    cp -p "$gem5/$target" "$gem5/$target.prev"
    echo "kept    $gem5/$target.prev"
fi

start=$(date +%s)
( cd "$gem5" && nice -n 5 scons "$target" -j"$jobs" ) > "$log" 2>&1
status=$?
echo "took    $(fmt_secs $(( $(date +%s) - start )))"

if [ $status -eq 0 ] && [ -x "$gem5/$target" ]; then
    echo "ok      $gem5/$target"
else
    echo "FAILED  (scons exit $status). First errors:"
    grep -nE 'error:|Error [0-9]+|\*\*\*' "$log" | head -10
    exit 1
fi
