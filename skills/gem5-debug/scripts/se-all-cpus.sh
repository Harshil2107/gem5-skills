#!/bin/bash
# Run one small SE test on every CPU model (atomic, timing, minor, o3) at the
# same time and compare what the program printed. A result that differs
# between CPU models, or a crash on only some of them, points at that model.
#
# Usage: se-all-cpus.sh --gem5 DIR --binary GEM5_BINARY [--isa riscv]
#                       [--cpus atomic,timing,minor,o3] [--out DIR]
#                       [-- se-test.py options] TEST_BINARY
# Example: se-all-cpus.sh --gem5 ~/gem5 --binary build/RISCV/gem5.opt ./slide
# Output per CPU is in --out (default: a new folder under the task's runs/).

set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
gem5="" binary="" isa=riscv cpus=atomic,timing,minor,o3 out="" extra=()
while [ $# -gt 0 ]; do
    case "$1" in
        --gem5) gem5=$(realpath "$2"); shift 2 ;;
        --binary) binary="$2"; shift 2 ;;
        --isa) isa="$2"; shift 2 ;;
        --cpus) cpus="$2"; shift 2 ;;
        --out) out="$2"; shift 2 ;;
        --) shift; while [ $# -gt 1 ]; do extra+=("$1"); shift; done ;;
        *) break ;;
    esac
done
test_bin="${1:-}"
[ -n "$gem5" ] && [ -n "$binary" ] && [ -f "$test_bin" ] || { sed -n '6,10p' "$0"; exit 2; }
test_bin=$(realpath "$test_bin")
[ -x "$binary" ] || binary="$gem5/$binary"
[ -x "$binary" ] || { echo "gem5 binary $binary not found."; exit 2; }

if [ -z "$out" ]; then
    d=$PWD; while [ "$d" != / ] && [ ! -f "$d/notes.md" ]; do d=$(dirname "$d"); done
    base=$([ -f "$d/notes.md" ] && echo "$d/runs" || echo "$PWD")
    out="$base/se-$(basename "$test_bin")-$(date +%Y%m%d-%H%M%S)"
fi
mkdir -p "$out"

IFS=, read -ra list <<< "$cpus"
for cpu in "${list[@]}"; do
    ( cd "$gem5" && "$binary" -d "$out/$cpu" -re "$here/se-test.py" "$test_bin" \
        --isa "$isa" --cpu "$cpu" "${extra[@]}" > /dev/null 2>&1
      echo $? > "$out/$cpu/exit-code" ) &
done
wait

# Program output: what simout has after gem5's banner, minus gem5's own lines.
prog_out() {
    sed -n '/^command line:/,$p' "$1" | sed '1d' |
        grep -avE '^$|^(info|warn): |^src/|^\*\*\*\* REAL SIMULATION|^Exiting @ tick|^Global frequency'
}
first=""
same=1
for cpu in "${list[@]}"; do
    s="$out/$cpu/simout.txt"; e="$out/$cpu/simerr.txt"
    code=$(cat "$out/$cpu/exit-code" 2>/dev/null || echo "?")
    reason=$(grep -a 'Exiting @ tick' "$s" 2>/dev/null | tail -1 | sed 's/.*because //')
    reason="gem5 exit code $code${reason:+, $reason}"
    crash=$(grep -aE '^[A-Za-z]*Error: |panic:|fatal:|Assertion .* failed|Segmentation fault' "$e" "$s" 2>/dev/null | head -1 | cut -c1-160)
    prog_out "$s" > "$out/$cpu/program-output.txt" 2>/dev/null
    echo "== $cpu: ${crash:+CRASH: }${crash:-$reason}"
    tail -5 "$out/$cpu/program-output.txt" | sed 's/^/   /'
    if [ -z "$first" ]; then first=$cpu
    elif ! cmp -s "$out/$first/program-output.txt" "$out/$cpu/program-output.txt"; then same=0; fi
done
echo
if [ ! -s "$out/$first/program-output.txt" ]; then
    echo "No program output on $first; check $out/$first/simerr.txt."
elif [ $same -eq 1 ]; then echo "Program output is the same on: $cpus"; else
    echo "Program output DIFFERS between CPU models (diff $out/<cpu>/program-output.txt)."; fi
echo "Output: $out"
