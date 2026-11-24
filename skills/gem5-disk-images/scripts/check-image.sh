#!/bin/bash
# Check that a built disk image has the files gem5 needs, without mounting it
# (no root needed). The root partition is copied out to a temporary file
# (sparse), so this needs that much free space in $TMPDIR for a moment.
# Usage: check-image.sh <image> <root-partition-number> <base|npb|gapbs> [extra-path...]

image="$1"; part="$2"; kind="$3"; shift 3 || true
[ -f "$image" ] && [ -n "$part" ] && [ -n "$kind" ] ||
    { echo "Usage: $0 <image> <root-partition> <base|npb|gapbs> [extra-path...]"; exit 2; }

read -r start size < <(sfdisk -J "$image" | python3 -I -c "
import json, sys
p = json.load(sys.stdin)['partitiontable']['partitions'][$part - 1]
print(p['start'], p['size'])")

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
rootfs="$tmp/rootfs.img"
dd if="$image" of="$rootfs" bs=512 skip="$start" count="$size" conv=sparse status=none

paths=(
    /usr/local/bin/gem5-bridge
    /usr/local/lib/libm5.a
    /sbin/gem5_init.sh
    /home/gem5/after_boot.sh
)
case "$kind" in
    npb) paths+=(/home/gem5/NPB3.4-OMP/bin/bt.S.x /home/gem5/NPB3.4-OMP/bin/is.S.x) ;;
    gapbs) paths+=(/home/gem5/gapbs/bin/bc /home/gem5/gapbs/bin/bfs) ;;
esac
paths+=("$@")

status=0
for p in "${paths[@]}"; do
    if debugfs -R "stat $p" "$rootfs" 2>/dev/null | grep -q '^Inode:'; then
        echo "ok      $p"
    else
        echo "MISSING $p"; status=1
    fi
done

init=$(debugfs -R "stat /sbin/init" "$rootfs" 2>/dev/null | grep -o 'Fast link dest: .*')
echo "/sbin/init -> ${init#Fast link dest: }"
[[ "$init" == *gem5_init.sh* ]] || { echo "BAD     /sbin/init is not gem5_init.sh"; status=1; }

# A half-configured package means dpkg failed part-way (for example disk full).
if debugfs -R "dump /var/lib/dpkg/status $tmp/status" "$rootfs" 2>/dev/null &&
        grep -E '^Status: .* (half-configured|half-installed|unpacked)' "$tmp/status" > /dev/null; then
    echo "BAD     dpkg has half-configured packages:"
    grep -B6 -E '^Status: .* (half-configured|half-installed|unpacked)' "$tmp/status" | grep '^Package:'
    status=1
fi

[ $status -eq 0 ] && echo "Image looks complete."
exit $status
