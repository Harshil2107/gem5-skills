#!/bin/bash
# Check the host has what a disk-image build needs before starting it.
# Usage: preflight.sh <x86|arm|riscv> [gem5-dir]
# Default gem5-dir: gem5/ in the task folder you run it from, else GEM5_CLONE
# from ~/.config/gem5-skills/config.

isa="$1"
gem5_dir="$2"
if [ -z "$gem5_dir" ]; then
    d=$PWD
    while [ "$d" != / ] && [ ! -f "$d/notes.md" ]; do d=$(dirname "$d"); done
    if [ -d "$d/gem5" ]; then
        gem5_dir="$d/gem5"
    else
        config=${GEM5_SKILLS_CONFIG:-$HOME/.config/gem5-skills/config}
        # shellcheck source=/dev/null
        [ -f "$config" ] && source "$config"
        gem5_dir="${GEM5_CLONE:-}"
    fi
fi
[ -n "$gem5_dir" ] || { echo "No gem5 dir: pass one, run from a task folder, or set GEM5_CLONE."; exit 2; }
fail=0

need() {
    if command -v "$1" > /dev/null; then
        echo "ok      $1"
    else
        echo "MISSING $1 ($2)"; fail=1
    fi
}

case "$isa" in
    x86) need qemu-system-x86_64 "qemu-system-x86" ;;
    arm)
        need qemu-system-aarch64 "qemu-system-arm"
        if [ -f /usr/share/qemu-efi-aarch64/QEMU_EFI.fd ]; then
            echo "ok      QEMU_EFI.fd"
        else
            echo "MISSING /usr/share/qemu-efi-aarch64/QEMU_EFI.fd (qemu-efi-aarch64)"; fail=1
        fi ;;
    riscv)
        need qemu-system-riscv64 "qemu-system-misc"
        need unxz "xz-utils" ;;
    *) echo "Usage: $0 <x86|arm|riscv> [gem5-dir]"; exit 2 ;;
esac
need qemu-img "qemu-utils"
need wget "wget"
need unzip "unzip"
need debugfs "e2fsprogs, used by check-image.sh"
need sfdisk "fdisk, used by check-image.sh"

if [ -w /dev/kvm ]; then
    echo "ok      /dev/kvm (KVM only helps when the guest ISA matches $(uname -m))"
else
    echo "note    no writable /dev/kvm: builds are emulated and slow (hours)"
fi

free_gb=$(df -BG --output=avail . | tail -1 | tr -dc 0-9)
echo "disk    ${free_gb} GB free here (each image needs 5-10 GB, plus the old copy on a rebuild)"
[ "$free_gb" -lt 30 ] && { echo "LOW     free disk"; fail=1; }

mem_gb=$(awk '/MemAvailable/ {print int($2 / 1048576)}' /proc/meminfo)
echo "memory  ${mem_gb} GB available (each QEMU build uses about 8 GB)"

if ls "$gem5_dir"/build/*/gem5.opt > /dev/null 2>&1; then
    for b in "$gem5_dir"/build/*/gem5.opt; do echo "ok      $b"; done
else
    echo "MISSING gem5 build under $gem5_dir/build/"; fail=1
fi

exit $fail
