#!/bin/bash
# GCC wrapper for building asmtests whose -march has an extension the
# assembler knows but GCC doesn't (GCC 16.1 rejects 'zalasr', binutils 2.47
# accepts it). It removes the extensions in WRAP_DROP from the -march GCC
# sees and passes the full -march to the assembler with -Wa,.
#
# Usage (from gem5-resources/src/asmtest):
#   REAL_GCC=<toolchain>/bin/riscv64-unknown-elf-gcc [WRAP_DROP=zalasr,...] \
#   make RISCV_PREFIX=<toolchain>/bin/riscv64-unknown-elf- \
#        RISCV_GCC=<this script> bin_dir=<out> <ids...>

: "${REAL_GCC:?set REAL_GCC to the real riscv gcc}"
IFS=, read -ra drop <<< "${WRAP_DROP:-zalasr}"
args=() asm=()
for a in "$@"; do
    if [[ $a == -march=* ]]; then
        b=$a
        for x in "${drop[@]}"; do b=${b//_$x/}; done
        [[ $b != "$a" ]] && asm=("-Wa,$a")
        args+=("$b")
    else
        args+=("$a")
    fi
done
exec "$REAL_GCC" "${args[@]}" "${asm[@]}"
