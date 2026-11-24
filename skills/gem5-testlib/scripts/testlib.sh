#!/bin/bash
# Run gem5 TestLib tests (tests/main.py) and summarise the results.
# Runs in the foreground: start long runs in the background.
#
# Usage:
#   testlib.sh list    [DIR] [filters]               suites and their UIDs
#   testlib.sh run     (--uid SUITE_UID | DIR...) [filters] [options]
#   testlib.sh rerun   [DIR] [options]               rerun the last failures
#   testlib.sh summary [RESULTS_DIR]                 pass/fail and times
#
#   DIR            a test directory relative to tests/, e.g. gem5/arm_boot_tests
#   filters:  --length quick|long|very-long (a DIR alone selects only quick)
#             --isa ALL|X86|ARM|...  --variant opt|debug|fast  --host x86_64
#             --include-tags T  --exclude-tags T
#   options:  --build          let TestLib build gem5 first (default: skip the
#                              build and use the existing binaries)
#             -j N             build threads (with --build)
#             -t N             tests to run at once (default: cores - 4)
#             --bin-path DIR   where test resources (disk images, kernels)
#                              are downloaded and reused; default
#                              TESTLIB_BIN_PATH from the settings file, else
#                              TestLib's own tests/gem5/resources
#             --dry-run        print the command only
#             -- ARGS          pass anything else to main.py
# gem5 is gem5/ in the task folder (or --gem5 DIR, or GEM5_CLONE). The log
# goes to the task's runs/; TestLib's results go to
# <gem5>/tests/testing-results/ (replaced by each run).

set -uo pipefail
config=${GEM5_SKILLS_CONFIG:-$HOME/.config/gem5-skills/config}
# shellcheck source=/dev/null
[ -f "$config" ] && source "$config"

cmd="${1:-}"; shift || true
gem5="" uid="" build=0 dry=0 jobs="" bin_path="${TESTLIB_BIN_PATH:-}"
threads=$(( $(nproc) > 4 ? $(nproc) - 4 : 1 ))
dirs=() filters=() extra=()
while [ $# -gt 0 ]; do
    case "$1" in
        --gem5) gem5="$2"; shift 2 ;;
        --uid) uid="$2"; shift 2 ;;
        --length|--isa|--variant|--host|--include-tags|--exclude-tags)
            filters+=("$1=$2"); shift 2 ;;
        --build) build=1; shift ;;
        -j) jobs="$2"; shift 2 ;;
        -t) threads="$2"; shift 2 ;;
        --bin-path) bin_path="$2"; shift 2 ;;
        --dry-run) dry=1; shift ;;
        --) shift; extra=("$@"); break ;;
        -*) echo "Unknown option $1 (pass main.py options after --)"; exit 2 ;;
        *) dirs+=("$1"); shift ;;
    esac
done

task=$PWD; while [ "$task" != / ] && [ ! -f "$task/notes.md" ]; do task=$(dirname "$task"); done
if [ -z "$gem5" ]; then
    if [ -d "$task/gem5" ]; then gem5="$task/gem5"; else gem5="${GEM5_CLONE:-}"; fi
fi
[ -n "$gem5" ] && [ -f "$gem5/tests/main.py" ] || { echo "No gem5 with tests/main.py: pass --gem5 or run from a task folder."; exit 2; }
gem5=$(realpath "$gem5")
tests="$gem5/tests"

summary() {
    local res="${1:-$tests/testing-results}"
    [ -f "$res/results.xml" ] || { echo "No results.xml in $res."; return 1; }
    python3 -I - "$res" <<'EOF'
import sys
import xml.etree.ElementTree as ET
res = sys.argv[1]
root = ET.parse(f"{res}/results.xml").getroot()
counts = {}
for case in root.iter("testcase"):
    state = "passed"
    for tag in ("failure", "error", "skipped"):
        if case.find(tag) is not None:
            state = {"failure": "FAILED", "error": "ERROR", "skipped": "skipped"}[tag]
    counts[state] = counts.get(state, 0) + 1
    t = float(case.get("time") or 0)
    print(f"{state:<8} {t/60:7.1f} min  {case.get('name', '?')}")
print("\n" + ", ".join(f"{n} {s}" for s, n in sorted(counts.items())))
print(f"Per-test output (simout.txt, simerr.txt, stats.txt): {res}/SuiteUID-*/TestUID-*/")
EOF
}

common() {
    # Options shared by run and rerun.
    [ $build -eq 1 ] || args+=(--skip-build)
    [ -n "$jobs" ] && args+=(-j "$jobs")
    args+=(-t "$threads")
    if [ -n "$bin_path" ]; then
        mkdir -p "$bin_path" 2>/dev/null
        args+=(--bin-path "$(realpath "$bin_path")")
    fi
    args+=(-vv "${filters[@]}" "${extra[@]}")
}

launch() {
    if [ $build -eq 0 ] && [ ! -x "$gem5/build/ALL/gem5.opt" ]; then
        echo "Warning: no build/ALL/gem5.opt; most tests need it (build it, or pass --build)."
    fi
    local runs log status start
    runs="$([ -f "$task/notes.md" ] && echo "$task/runs" || echo "$gem5/m5out")"
    log="$runs/testlib-$(date +%Y%m%d-%H%M).log"
    echo "gem5    $gem5 ($(git -C "$gem5" describe --always --dirty 2>/dev/null))"
    echo "binary  $gem5/build/ALL/gem5.opt (built $(date -r "$gem5/build/ALL/gem5.opt" '+%F %T' 2>/dev/null || echo never))"
    printf 'run     cd %s && ./main.py' "$tests"; printf ' %q' "${args[@]}"; echo
    [ $dry -eq 1 ] && { echo "Dry run: not running."; exit 0; }
    echo "log     $log"
    mkdir -p "$runs"
    start=$(date +%s)
    ( cd "$tests" && ./main.py "${args[@]}" ) > "$log" 2>&1
    status=$?
    echo "took    $(( ($(date +%s) - start) / 60 )) min, exit $status"
    summary "$tests/testing-results"
    exit $status
}

case "$cmd" in
    list)
        args=(list "${dirs[@]:-gem5}" "${filters[@]}" -q --suites "${extra[@]}")
        [ -n "$bin_path" ] && args+=(--bin-path "$bin_path")
        cd "$tests" && ./main.py "${args[@]}" ;;
    run)
        [ -n "$uid" ] || [ ${#dirs[@]} -gt 0 ] || { echo "Give --uid SUITE_UID or a test directory."; exit 2; }
        args=(run)
        [ -n "$uid" ] && args+=(--uid "$uid")
        args+=("${dirs[@]}")
        common
        launch ;;
    rerun)
        [ -f "$tests/testing-results/results.pickle" ] || { echo "No previous results to rerun."; exit 2; }
        if ! grep -qE '<(failure|error)' "$tests/testing-results/results.xml" 2>/dev/null; then
            echo "The last run had no failures; nothing to rerun."; exit 0
        fi
        args=(rerun "${dirs[@]}")
        common
        launch ;;
    summary)
        summary "${dirs[0]:-}" ;;
    *)
        sed -n '5,27p' "$0"; exit 2 ;;
esac
