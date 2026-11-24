---
name: gem5-debug
description: Find the cause of a gem5 simulator bug - a panic, a hang, a guest crash or wrong results in SE or full-system runs. Covers telling an image or workload problem from a gem5 bug, finding where a run is stuck, tracing only a short window of a long run by turning debug flags on mid-run, pulling guest binaries out of disk images, and reproducing in a small SE test run on every CPU model. Use when a gem5 run fails, hangs, crashes the guest, or gives different results on different CPU models.
---

# gem5-debug: find the cause of a simulator bug

Work in this order; each step is cheaper than the next. Write what you find
in the task's `notes.md` as you go: symptom, what you tried, what it showed.
`reference/case-studies.md` has real examples of each step.

## 1. Is it the image, the workload or gem5?

- Boot the same image and kernel in QEMU (the packer template's qemuargs,
  with the gem5 kernel). Works in QEMU but not gem5: gem5 bug. Fails in
  both: image or workload bug.
- Run the same workload on another CPU model and core count (ATOMIC vs
  TIMING, 1 vs 2 cores). A failure on only one model points at that model's
  path, for example TIMING's split translation or interrupt timing.
- Try the previous gem5 release or develop. A failure that's new in one
  version narrows the search to what changed in between (`git log` on the
  files involved).

## 2. Where is it?

- `gem5-run`'s `status.sh` gives crash lines and the last console line.
  Strip ANSI colours before grepping a console: `sed 's/\x1b\[[0-9;:]*m//g'`.
- A guest crash at an address exactly on a page boundary often means a
  memory access that should have stopped at the end of a page (like a
  fault-only-first vector load).
- Is it moving? From the gem5 dir:
  `python3 util/hypercall_external_signal/orchestrator_request.py --pid <gem5 pid> status`
  (the pid is in the run's `gem5.pid`). Instructions rising with no console
  output means a guest loop, not a gem5 deadlock.
- For a stuck boot, add `systemd.log_level=debug systemd.log_target=console`
  to the kernel arguments.

## 3. Trace only the window that matters

`scripts/trace-window.sh OUTDIR --flags Exec,Faults --on REGEX (--off REGEX | --for SECONDS) [--max-gb N]`

Turns debug flags on in the running gem5 when REGEX appears in the console or
simout, and off after the second marker, a time, or when the trace has grown
N GB (default 2). Start it in the background. Starting gem5 with
`--debug-flags` instead slows the whole run about 10x.

- Start runs you may want to trace with `gem5-run`'s
  `run.sh --debug-file trace.out`, so the trace doesn't mix with simout.
- An Exec trace grows by several GB a minute. Keep windows short, check free
  disk first, and remove big traces when done (ask the user first).
- `gdb -p` usually can't attach (ptrace_scope=1); the orchestrator is the way
  in.

Read the trace next to a disassembly of the guest code. Get the binary out of
the image without root:
`scripts/extract-from-image.sh IMAGE ROOT_PARTITION OUT_DIR /usr/bin/foo /usr/lib/.../libbar.so.1`
then `<arch>-linux-gnu-objdump -d`. Look for an instruction whose result is
impossible: a load from the right address returning garbage, a result of -1
where the inputs can't give it.

## 4. Reproduce it in a small SE test

Once you suspect an instruction or a pattern, write a small static C program
with inline asm that checks the result and prints ok/WRONG per case, and run
it on every CPU model at once:

`scripts/se-all-cpus.sh --gem5 DIR --binary build/RISCV/gem5.opt [--isa riscv] TEST_BINARY`

It shows each model's output and whether they differ. It finishes in seconds,
and it becomes the regression test for the fix. Build tests with the cross
compiler and `-static` (for riscv vectors: `-march=rv64gcv`). Include control
cases that must pass, so a broken test can't look like a bug.

- To run the image's own dynamically linked programs, extract a sysroot
  (`/lib`, `/usr/lib/<triple>` and the loader) with `extract-from-image.sh`
  and pass `-- --sysroot DIR` (the config is `scripts/se-test.py`).
- SE mode doesn't implement every syscall; stub missing ones in the test.
- SE mode has no page-table walker and no interrupts. If the bug only shows
  in full system, suspect translation (TLB and walker, timing vs atomic) or
  interrupts landing inside a multi-micro-op instruction. A temporary
  `warn()` at the failing check that prints pc, macro-op, micro-op, vaddr,
  paddr and request flags usually shows which. Remove it before upstreaming.

## 5. Before writing a fix

- Search gem5's open and closed PRs and issues for the instruction, file or
  symptom. Several of the 2026 riscv bugs already had open PRs. Tell the user
  about any overlap so they can choose between reviewing or testing the
  existing PR and writing their own fix.
- Write the fix on its own branch (`gem5-branch`, type `fix`), and test it
  with the SE repro on every CPU model plus the original failing run
  (`gem5-run`).
