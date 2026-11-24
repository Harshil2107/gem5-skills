#!/bin/bash
# Look for failures in a packer build log. The provisioning scripts don't stop
# on errors, so a build that "finished" can still have a broken image.
# Usage: check-build-log.sh <log>

log="$1"
[ -f "$log" ] || { echo "Usage: $0 <packer-log>"; exit 2; }

# Strip ANSI colours and packer's "==> qemu.x: " prefixes so the patterns match.
clean=$(sed 's/\x1b\[[0-9;:]*m//g' "$log")

patterns=(
    'No space left on device'
    'dpkg: error|unrecoverable fatal error|dpkg was interrupted'
    'Could not get lock|Unable to acquire the dpkg'
    'Unable to locate package|Errors were encountered while processing'
    '^E: |: E: '
    'fatal: '
    'make(\[[0-9]+\])?: \*\*\*'
    ': error: '
    'Segmentation fault'
    'active block inhibitor'
    'command not found'
)

status=0
for p in "${patterns[@]}"; do
    hits=$(grep -nE -- "$p" <<< "$clean")
    if [ -n "$hits" ]; then
        status=1
        echo "=== $p ($(wc -l <<< "$hits") lines)"
        head -5 <<< "$hits" | cut -c1-200
    fi
done

if grep -q "Builds finished. The artifacts" <<< "$clean"; then
    echo "packer: build finished"
elif grep -qE "Build '.*' errored|Build '.*' finished" <<< "$clean"; then
    echo "packer: build FAILED"; status=1
else
    echo "packer: no final status (still running or killed)"; status=1
fi

[ $status -eq 0 ] && echo "No problems found."
exit $status
