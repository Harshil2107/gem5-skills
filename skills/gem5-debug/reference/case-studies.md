# Case studies

Real gem5 bugs found while booting Ubuntu 26.04 (RVA23) on RISC-V in 2026, and
how each was found. Ubuntu 26.04 builds ordinary programs with vector
instructions, which exposed them.

## Fault-only-first loads raise a fault on TIMING

- **Symptom:** right after the kernel booted, `init[1]: unhandled signal 11
  ... at 0x00007fffc0ab3000 in bash`, then a kernel panic. TIMING only.
- **Found by:** the fault address was exactly on a page boundary. glibc's
  `strlen` uses `vle8ff.v`, which may run into the next page and is supposed
  to shorten `vl` instead of faulting.
- **Cause:** in TimingSimpleCPU the translation finishes after
  `initiateAcc()` returns, so the page fault bypassed the fault-only-first
  handling. Fixed in develop by gem5#3553.

## Stale fault-only-first state on every CPU

- **Symptom:** later in the boot, `Data write ... failed: BadAddressError`
  from a bad guest pointer, on ATOMIC too.
- **Cause:** `trimVl`/`faultIdx` live on the decoded StaticInst, which gem5
  caches and reuses, and were never reset. After one trimmed load, every
  later run of that instruction was trimmed too. Still open as of Nov 2026:
  gem5#3403 (an O3-safe redesign); the simple reset in gem5#3362 failed O3
  tests.

## Hypercalls sent to memory after a TIMING page walk

- **Symptom:** `Data access ([0x10017100:...]) failed: BadAddressError` when
  the first hypercall ran.
- **Found by:** the address is in the m5op (gem5-bridge) range. TLB hits
  handled it; page-walk completions didn't.
- **Cause:** the timing walker's completion path skipped
  `TLB::finalizePhysical()`. Only shows when the m5 tools use address-mode
  m5ops, the riscv default since gem5 v26.0. Fixed in develop by gem5#3756.

## `vslidedown` with vd == vs2 returns -1

- **Symptom:** boot froze after `Started dbus.service`; the same image boots
  in QEMU.
- **Found by:** the orchestrator showed instructions still rising (a guest
  loop). `trace-window.sh --flags Exec --on 'Starting dbus'` and a
  disassembly of libdbus showed `vslidedown.vi v1, v1, 1` returning
  `0xffffffff`. An SE test (`vslidedown` with vd == vs2 under `ta, ma`)
  failed on Atomic, Timing and Minor and passed on O3.
- **Cause:** the tail-agnostic fill wrote the destination before the source
  was read; without register renaming they're the same register. Fixed in
  develop by gem5#3513.

## Interrupt taken in the middle of a vector instruction (TIMING)

- **Symptom:** GAPBS `bc` panicked while building its graph:
  `Data access ([0x7fff95a1bb90:...]) failed: BadAddressError`.
- **Found by:** a temporary `warn()` in
  `TimingSimpleCPU::completeDataAccess()` showed micro-op 0 of a user
  `vlseg2e32.v` running at an OpenSBI PC in M-mode with `PHYSICAL` set.
- **Cause:** some vector macro-ops didn't mark their micro-ops as delayed
  commit, so a timer interrupt was taken between micro-ops and the rest of
  the instruction ran in the trap handler. Fixed in develop by gem5#3757,
  which marks every micro-op except the last as delayed commit.
