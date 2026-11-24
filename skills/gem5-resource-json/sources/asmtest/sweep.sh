#!/bin/bash
# Run asmtest resources in gem5 SE mode on several CPU models, in parallel,
# with gem5's own asmtest config. Only -ps- tests can run in SE mode; other
# IDs in the list are skipped.
#
# Usage: sweep.sh --gem5 DIR --ids-file FILE --out DIR
#            [--json LOCAL_JSON] [--cpus atomic,timing,minor,o3] [-j N]
#            [--binary build/ALL/gem5.opt]
# --json sets GEM5_RESOURCE_JSON_APPEND (a file:// JSON from `resjson.py local`).
# Without it the resources come from the public database.
# Writes OUT/results.txt ("<id> <cpu> <exit-code> [first panic/fatal line]",
# 0 = pass) and a gem5
# output dir per run in OUT/all/. Resources are downloaded into OUT/resources,
# so an older cached copy in ~/.cache/gem5 is never used.

set -uo pipefail
gem5="" ids="" out="" json="" cpus=atomic,timing,minor,o3 jobs=$(( $(nproc) / 2 ))
binary=build/ALL/gem5.opt
while [ $# -gt 0 ]; do
    case "$1" in
        --gem5) gem5=$(realpath "$2"); shift 2 ;;
        --ids-file) ids=$(realpath "$2"); shift 2 ;;
        --out) out=$(realpath -m "$2"); shift 2 ;;
        --json) json=$(realpath "$2"); shift 2 ;;
        --cpus) cpus=$2; shift 2 ;;
        -j) jobs=$2; shift 2 ;;
        --binary) binary=$2; shift 2 ;;
        *) sed -n '6,14p' "$0"; exit 2 ;;
    esac
done
[ -n "$gem5" ] && [ -f "$ids" ] && [ -n "$out" ] || { sed -n '6,14p' "$0"; exit 2; }
[ -x "$binary" ] || binary="$gem5/$binary"
[ -x "$binary" ] || { echo "gem5 binary $binary not found."; exit 2; }
config="$gem5/tests/gem5/riscv-unittests/asmtest/configs/riscv_asmtest.py"
[ -f "$config" ] || { echo "$config not found."; exit 2; }
mkdir -p "$out/all" "$out/resources"
[ -n "$json" ] && export GEM5_RESOURCE_JSON_APPEND="$json"

run_one() {  # id cpu
    local id=$1 cpu=$2 d="$out/all/$1-$2" extra=()
    [[ $id == rv32* ]] && extra=(--riscv-32bits)
    mkdir -p "$d"
    timeout 600 "$binary" -re --outdir="$d" "$config" "$id" "$cpu" \
        --num-cores 4 "${extra[@]}" --resource-directory "$out/resources" \
        > /dev/null 2>&1
    local rc=$? why=""
    [ $rc -ne 0 ] && why=$(grep -m1 -hE 'panic:|fatal:|Exception:' "$d"/simerr* 2>/dev/null | cut -c1-120)
    echo "$id $cpu $rc $why"
}
export -f run_one
export binary config out

grep -q -- '-ps-' "$ids" || { echo "No -ps- IDs in $ids."; exit 2; }
# One CPU model at a time, IDs in parallel: the first pass downloads each
# resource, so two runs never download the same one at once.
for cpu in ${cpus//,/ }; do
    grep -- '-ps-' "$ids" | xargs -P "$jobs" -I{} bash -c 'run_one "$0" "$1" 2>/dev/null' {} "$cpu"
done | sort > "$out/results.txt"

total=$(wc -l < "$out/results.txt")
pass=$(awk '$3 == 0' "$out/results.txt" | wc -l)
echo "$pass of $total runs passed. Results: $out/results.txt"
awk '$3 != 0 {print "  FAIL", $0}' "$out/results.txt" | head -n 40
