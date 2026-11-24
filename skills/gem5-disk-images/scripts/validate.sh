#!/bin/bash
# Start a gem5 disk-image validation run, detached, and print how to follow it.
# Usage: validate.sh <gem5-dir> <resource-json> <x86|arm|riscv> <workload-id> [version] [--validate-npb] [--binary build/X/gem5.opt] [--script path]
# Pass:  grep "All exit events are called in expected order" <outdir>/simout.txt

gem5_dir="$1"; json="$2"; isa="$3"; workload="$4"; shift 4 ||
    { echo "Usage: $0 <gem5-dir> <json> <isa> <workload-id> [version] [--validate-npb] [--binary B] [--script S]"; exit 2; }
version="1.0.0"
if [ -n "$1" ] && [ "${1#--}" = "$1" ]; then version="$1"; shift; fi

binary="build/ALL/gem5.opt"
script="util/disk-image-validator/disk-image-validate.py"
extra=()
while [ -n "$1" ]; do
    case "$1" in
        --binary) binary="$2"; shift 2 ;;
        --script) script="$2"; shift 2 ;;
        *) extra+=("$1"); shift ;;
    esac
done

cd "$gem5_dir" || exit 1
json=$(realpath "$json")
# m5out goes in the task folder's runs/ when there is one.
runs="$gem5_dir/m5out"
[ -f "$gem5_dir/../notes.md" ] && runs=$(realpath "$gem5_dir/../runs")
outdir="$runs/${workload}-$(date +%m-%d-%Y-%H%M)"

GEM5_RESOURCE_JSON_APPEND="$json" setsid nohup "./$binary" -d "$outdir" -re \
    "$script" --isa="$isa" --workload="$workload" --resource_version="$version" \
    "${extra[@]}" > /dev/null 2>&1 < /dev/null &
pid=$!

echo "pid     $pid"
echo "outdir  $outdir"
echo "status  python3 $gem5_dir/util/hypercall_external_signal/orchestrator_request.py --pid $pid status"
echo "pass    grep 'All exit events are called in expected order' $outdir/simout.txt"
