# PR description template

Keep it short. A reviewer should know in 30 seconds what broke, what changed
and how it was tested.

```markdown
<One or two sentences: what was broken, on which CPU/ISA/config, and how it
showed up (the error message or symptom).>

<What caused it, in one or two sentences.>

<What this change does. If there was another way to fix it, one sentence on
why this way.>

### Testing

- <test>: <result> (e.g. "vslidedown SE test on Atomic, Timing, Minor, O3:
  all pass; fails on Atomic/Timing/Minor without this change")
- <workload>: <result> (e.g. "Ubuntu 26.04 riscv boot, 2-core TIMING: reaches
  all hypercalls")

Related: #<PR or issue>. Fixes #<issue, if this closes one>.
```

Example (from a real fix):

```markdown
On TimingSimpleCPU, an m5op (hypercall) made through the gem5-bridge mmap
page panics with `Data access ([0x10017100:...]) failed: BadAddressError`
when the first access to that page misses in the TLB.

When a timing page walk finishes, the walker runs the PMP and PMA checks but
never calls `TLB::finalizePhysical()`, so m5op accesses are sent to memory
instead of being handled as pseudo instructions. TLB hits and atomic walks
already call it.

This calls `finalizePhysical()` when a timing walk completes, before the
PMP/PMA checks, the same order `TLB::translate()` uses.

### Testing

- Ubuntu 26.04 riscv boot, 2-core TIMING: passes all hypercalls; panics at
  the first hypercall without this change.
- Ubuntu 24.04 riscv boot (published image): still passes.
```
