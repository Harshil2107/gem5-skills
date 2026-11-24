# asmtest resources (gem5-resources `src/asmtest`)

riscv-tests built for gem5. Each test has three IDs:
`<suite>-p-<test>`, `-ps-` and `-v-` (for example `rv64uzabha-ps-amoadd_b`).
Usually all three are published; ask if unsure.

## IDs

List every ID the Makefile can build (run in `src/asmtest`):

```sh
printf 'print-ids:\n\t@echo $(p_env_tests) $(ps_env_tests) $(v_env_tests)\n' > /tmp/print-ids.mk
make -s -f Makefile -f /tmp/print-ids.mk print-ids | tr ' ' '\n' > all-ids.txt
```

Then `resjson.py query --ids-file all-ids.txt` gives the new ones. Also check
the PR diff for edits to existing tests' `.S` files. In PR #85 that was
`rv64ua/amominu_w.S` and `amomaxu_w.S`, which the rv32 tests include too. Those
IDs exist already, so they need a version bump or no entry; ask.

## Template and URL

- Template: `rv32si-p-ma_fetch:1.0.0`. Its folder is
  `https://dist.gem5.org/dist/develop/test-progs/asmtest/bin` (version 1.0.0
  of the asmtests).
- Version `2.0.0` (the rv32 fixes) lives in `dist/v24-0/asmtest-v2/`.
- The file name is the id (`--file-pattern '{id}'`, the default).

## Build

The system toolchain (GCC 13 / binutils 2.42) can't assemble Zacas
`amocas.q`, Zabha or Zalasr. In 2026-11 the riscv-collab prebuilt
(`riscv64-elf-ubuntu-24.04-gcc`, release 2026.10.29: GCC 16.1, binutils 2.47)
worked. Ask before downloading a toolchain.

GCC 16.1 rejects `zalasr` in `-march` while binutils accepts it, so use
`sources/asmtest/gcc-wrap.sh`:

```sh
TC=<toolchain>/bin/riscv64-unknown-elf-
REAL_GCC=${TC}gcc make -j16 RISCV_PREFIX=$TC \
    RISCV_GCC=<skill>/sources/asmtest/gcc-wrap.sh bin_dir=<out> $(cat new.txt)
```

Building into a separate `bin_dir` keeps the repo's `bin/` as it was. Check
that each new binary really has the new instructions:
`${TC}objdump -d <out>/<id> | grep <mnemonic>`.

## Test in gem5

- Only `-ps-` tests run in gem5 SE mode; `-p-` and `-v-` can't be tested.
- Config: `tests/gem5/riscv-unittests/asmtest/configs/riscv_asmtest.py <id> <cpu> --num-cores 4`,
  plus `--riscv-32bits` for rv32. Exit code 0 means the test passed.
- `sources/asmtest/sweep.sh` runs all of them on atomic, timing, minor and o3.
- `panic: Unknown instruction` (exit 134) means gem5 doesn't implement the
  instruction yet. That's expected when the gem5 support is in an unmerged PR
  or doesn't exist; test with that PR merged on develop.
- `... not found locally. Downloading` in the log is normal.
- gem5's CI runs the IDs listed in
  `tests/gem5/riscv-unittests/asmtest/tests.py`. If a gem5 PR adds IDs there,
  they must all be published, and they must pass.
