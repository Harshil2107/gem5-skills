#!/bin/bash
# Copy files or directories out of a disk image without mounting it (no root
# needed), for example a guest binary to disassemble next to an Exec trace,
# or libraries for an SE-mode sysroot. Symlinks are kept as symlinks and their
# targets are copied too.
#
# Usage: extract-from-image.sh IMAGE ROOT_PARTITION OUT_DIR GUEST_PATH...
#   ROOT_PARTITION  x86 1, arm 2, riscv 1 for the gem5-resources Ubuntu images
# Example: extract-from-image.sh riscv-ubuntu.img 1 ./sysroot /usr/lib/riscv64-linux-gnu /lib/ld-linux-riscv64-lp64d.so.1
# Needs debugfs (e2fsprogs) and sfdisk; copies the partition to $TMPDIR first.

set -euo pipefail
image="${1:-}" part="${2:-}" out="${3:-}"
shift 3 2> /dev/null || true
[ -f "$image" ] && [ -n "$part" ] && [ -n "$out" ] && [ $# -gt 0 ] || { sed -n '7,10p' "$0"; exit 2; }
out=$(realpath -m "$out")

read -r start size < <(sfdisk -J "$image" | python3 -I -c "
import json, sys
p = json.load(sys.stdin)['partitiontable']['partitions'][$part - 1]
print(p['start'], p['size'])")

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fs="$tmp/root.img"
dd if="$image" of="$fs" bs=512 skip="$start" count="$size" conv=sparse status=none

# Type of a guest path (regular, directory, symlink) or nothing if missing.
gtype() { debugfs -R "stat \"$1\"" "$fs" 2>/dev/null | sed -n 's/.*Type: \([a-z]*\).*/\1/p' | head -1; }
# Target of a guest symlink.
glink() {
    local t
    t=$(debugfs -R "stat \"$1\"" "$fs" 2>/dev/null | sed -n 's/^Fast link dest: "\(.*\)"$/\1/p')
    [ -n "$t" ] || t=$(debugfs -R "cat \"$1\"" "$fs" 2>/dev/null)
    echo "$t"
}
# Resolve symlinks in the directories of a guest path (Ubuntu's /lib is a
# symlink to usr/lib); the last component is left as it is.
gdirs() {
    local p="$1" cur="" comp t n=0
    local IFS=/
    for comp in $(dirname "$p"); do
        [ -n "$comp" ] || continue
        cur="$cur/$comp"
        while [ "$(gtype "$cur")" = symlink ] && [ $n -lt 20 ]; do
            t=$(glink "$cur"); n=$((n + 1))
            # Recreate the directory link in the output too (for sysroots).
            mkdir -p "$out$(dirname "$cur")"
            [ -e "$out$cur" ] || [ -L "$out$cur" ] || ln -s "$t" "$out$cur"
            [[ "$t" = /* ]] && cur=$(realpath -ms "$t") || cur=$(realpath -ms "$(dirname "$cur")/$t")
        done
    done
    echo "${cur}/$(basename "$p")"
}

extract() {
    local p="$1" depth="$2" t target
    [ "$depth" -lt 10 ] || { echo "LOOP    $p"; return; }
    p=$(gdirs "$p")
    mkdir -p "$out$(dirname "$p")"
    case "$(gtype "$p")" in
        directory)
            debugfs -R "rdump \"$p\" \"$out$(dirname "$p")\"" "$fs" 2>/dev/null
            echo "ok      $p/" ;;
        regular)
            debugfs -R "dump -p \"$p\" \"$out$p\"" "$fs" 2>/dev/null
            echo "ok      $p" ;;
        symlink)
            t=$(glink "$p")
            ln -sfn "$t" "$out$p"
            [[ "$t" = /* ]] && target=$t || target=$(realpath -ms "$(dirname "$p")/$t")
            echo "link    $p -> $t"
            extract "$target" $((depth + 1)) ;;
        *) echo "MISSING $p" ;;
    esac
}

for p in "$@"; do extract "$p" 0; done
