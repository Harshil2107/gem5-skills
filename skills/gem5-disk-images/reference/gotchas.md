# Gotchas

Problems hit while building Ubuntu 26.04 images (Nov 2026, x86 host, QEMU
9.0.2).

## Before you build

- **New Ubuntu riscv needs RVA23.** From 25.10, Ubuntu's riscv64 userspace is
  built for RVA23 (vector, Zvbb, Zicond, Zfa...). QEMU needs `-cpu max` (9.0
  has no `rva23s64` model). gem5 has to run vector code correctly. A kernel
  built without V doesn't help, because glibc, bash and libdbus all use vector
  instructions.
- **OpenSBI ≥ 1.6 `fw_jump.elf` loads at `0x0`** and overlaps QEMU's reset
  ROM (`Some ROM regions are overlapping`). Use `fw_jump.bin`.
- **arm without KVM:** the templates have a `use_kvm` variable, and
  `build-arm.sh` picks the packer arch from `uname -m`. On QEMU 9.0.2 TCG,
  `-cpu max` crashed booting 26.04 (`regime_is_user: code should not be
  reached`), so use `-cpu cortex-a57`. Under emulation the GRUB menu shows
  10–40 s after start, so `boot_wait = 20s` and `ssh_wait_timeout = 300m`.
- **riscv base starts from the *preinstalled server* image**, not a minimal
  autoinstall. It runs snapd, lxd-installer, multipathd, udisks2, chrony,
  rsyslog, unattended-upgrades and more, which makes the simulated boot slow.
  `post-installation.sh` disables or masks them and sets `multi-user.target`.
  Check the list again on each new version.
- **Emulated typing loses keys.** Password prompts are slow under emulation
  and throw away typed-ahead keys. Use long `<waitN>`s in `boot_command`
  (`<wait300>` for the first boot of riscv/arm).

## During the build

- **dpkg lock on first boot.** cloud-init or unattended-upgrades runs
  `apt-get` in the background on a slow first boot. Every `apt-get install`
  then fails at once, and the scripts carry on. The image is missing
  gem5-bridge, git and scons, and the build still "passes".
  `install-common-packages.sh` now waits for cloud-init and apt.
  - Don't match the process name `unattended-upgr`: that's also
    `unattended-upgrade-shutdown --wait-for-signal`, which runs for the whole
    uptime. Match `/usr/bin/unattended-upgrade( |$)` with `pgrep -f`, and cap
    the wait.
- **Disk full.** The riscv root partition is `vda1` at the *end* of the disk,
  so it doesn't grow with the disk. npb and gapbs `growpart /dev/vda 1 &&
  resize2fs`. Install packages *after* the resize: installing boost first
  filled the disk and left dpkg half-configured (`unrecoverable fatal error`)
  while the benchmarks still built. Sizes that worked: npb 7000 MB, gapbs
  8000 MB.
- **Shutdown blocked:** `Operation denied due to active block inhibitor`
  (unattended-upgrades), and then packer deletes the image. The npb
  `shutdown_command` waits up to 20 min for block inhibitors, then
  `poweroff -i`. Disabling unattended-upgrades in the base is the real fix.
- **The netplan file name differs by install method:** autoinstall gives
  `00-installer-config.yaml`, preinstalled/cloud images give
  `50-cloud-init.yaml`. Scripts that move it must handle both, and fail if
  neither is there.

## After the build

- Always run `check-build-log.sh` and `check-image.sh`. Every silent failure
  above showed up in the log or as a missing file long before gem5 would have
  shown it.
- Packer won't overwrite its output dir. Move the old one aside and update
  `.gitignore`, the JSON URL and the `iso_checksum` in dependent templates.
- New md5 → clear `~/.cache/gem5/<id>*`.

## In gem5

- `disk-image-validate.py` imports all three demo boards, so a single-ISA
  gem5 build fails at once. Use a copy without the other imports.
- `N consecutive SC failures` warnings on riscv: the counter is never reset,
  so it's a running total, not a livelock. It's harmless.
- The arm 26.04 image prints `Segmentation fault (core dumped)` right after
  the auto-login (on both the KVM and no-KVM builds). It's harmless; the
  validations pass.
- riscv login to `after_boot.sh` is slow in TIMING (about 2 h of wall time).
  That's normal; check progress with the orchestrator before calling it a
  hang.
- gem5 riscv bugs found with 26.04. As of Nov 2026, fixes for 1, 3, 4 and 5
  are in gem5 develop (#3553, #3756, #3513, #3757), after the v26.0 release;
  2 is still open (#3403). Validate riscv 26.04 on a gem5 that has all of
  them:
  1. TIMING fault-only-first loads raised the page fault instead of trimming
     `vl`. Overlaps gem5#3553.
  2. Stale `trimVl`/`faultIdx` on the cached StaticInst, on every CPU.
     Overlaps gem5#3403.
  3. The timing page walk skipped `finalizePhysical()`, so m5ops went to
     memory. No PR.
  4. `vslidedown` with vd == vs2 clobbered vs2; dbus hung after
     `Started dbus.service`. gem5#3513.
  5. Interrupts taken in the middle of a vector macro-op (no delayed-commit),
     so the micro-ops ran in M-mode untranslated. No PR.
