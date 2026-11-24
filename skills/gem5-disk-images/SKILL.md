---
name: gem5-disk-images
description: Build, register and validate gem5-resources Ubuntu disk images (base, npb, gapbs) for x86, arm and riscv - packer builds, resource JSON entries, and gem5 disk-image-validator runs. Use when adding a new Ubuntu version or ISA variant of a disk image, rebuilding one, writing its resources.json entries, or debugging a build or a validation that fails or hangs.
argument-hint: "<ubuntu-version> <isa: x86|arm|riscv|all> [base|npb|gapbs|all]"
---

# gem5 disk images: build, register, validate

Semi-automated workflow for gem5-resources disk images. The user drives the
decisions (versions, what to commit, what to upload); you run the builds, watch
them, check the output, write the JSON entries and run the validations.

Read `reference/gotchas.md` before starting a new Ubuntu version or ISA. Every
item in it cost hours the first time. When a validation fails inside gem5
(panic, hang, wrong output), use the `gem5-debug` skill.

## Task folder and settings

Work in a task folder made by the `gem5-branch` skill (type `resources`):
`gem5-resources/` is the repo to change, `gem5/` (if present) is the gem5 to
validate with, `runs/` holds build logs and m5out directories, and `notes.md`
is where findings and decisions go. If there's no task folder yet, offer to
make one with `gem5-branch` first.

Personal settings (GitHub user, main clones) are in
`~/.config/gem5-skills/config`; never write a user's own paths into this skill.

Confirm these with the user at the start (ask once, in one question) unless
they are already given in the request or in memory:

| Setting | Default |
|---|---|
| gem5 checkout | `gem5/` in the task folder, else `GEM5_CLONE` from the settings file (binary `build/ALL/gem5.opt`) |
| Resource JSON to write | `runs/<ubuntu>-resources.json` in the task folder (never committed: it has `file://` URLs) |
| Author | `git config user.name` |
| `gem5_versions` | `["25.0", "25.1"]` |
| Kernel per ISA | x86: extracted from the image; arm/riscv: ask (custom kernels are built separately) |
| Bootloader | arm `arm64-bootloader-foundation` 2.0.0; riscv `riscv-bootloader-opensbi-1.3.1` 1.0.0 |
| Commit | Never commit, push or open a PR until the user says so |

## Repo map

| What | Source dir | Build | Output (packer `output_directory`) |
|---|---|---|---|
| x86/arm base | `src/ubuntu-generic-diskimages` | `./build-x86.sh <ver>`, `./build-arm.sh <ver> [use_kvm]` | `x86-disk-image-<ver>/`, `arm-disk-image-<ver>/` |
| riscv base | `src/riscv-fs/riscv-ubuntu-22.04-24.04` | `./build.sh <ver>` (starts from Ubuntu's preinstalled server image) | `disk-image-<ver>/` |
| npb | `src/npb-24.04-imgs` | `./build-<isa>.sh <ver>` | `disk-image-<isa>-npb-<ver>/` |
| gapbs | `src/gapbs` | `./build-<isa>.sh <ver>` | `<isa>-disk-image-ubuntu-<ver>/` (x86 differs; check the `.pkr.hcl`) |

npb and gapbs images are built *on top of* the base image of the same ISA, and
each pins the base image by `iso_checksum` in its `.pkr.hcl`. Root partition:
x86 `1`, arm `2`, riscv `1`.

The validator is `util/disk-image-validator/disk-image-validate.py` in the gem5
checkout. It checks that hypercalls 1→2→(4→5)→3 arrive in order and, with
`--validate-npb`, that NPB verified.

## Workflow

### 1. Preflight

Run `scripts/preflight.sh <isa>`. It checks qemu, the UEFI firmware for arm,
KVM, free disk and RAM, and the gem5 binary. Fix anything missing before
starting; a build that dies 3 hours in from a missing package is the expensive
failure. Don't install system packages yourself; tell the user what's missing.

### 2. Add the new version to the scripts

For each source dir you'll build: allow the new version in the build script's
version check, add the version's branch to the `.pkr.hcl` (ISO or base image
URL + checksum, output dir, any version-specific boot command), and update any
`if ubuntu_version == ...` branches in the `scripts/*.sh`. Grep for the
previous version string to find every place:
`grep -rn '24\.04' src/<dir> --include='*.sh' --include='*.hcl'`.

Keep older versions working; the shared scripts in
`src/ubuntu-generic-diskimages/scripts/` are used by every version and ISA.

### 3. Build, in dependency order

Base first. Then npb and gapbs, which can run in parallel.

- Run every build in the background with a log:
  `cd <dir> && ./build-<isa>.sh <ver> > <task>/runs/<kind>-<isa>-<ver>.log 2>&1`.
- Emulated builds (arm/riscv on an x86 host) take 3–8 hours. Watch the log
  with a Monitor/until-loop on a final line (`Builds finished` or `errored`),
  not by polling with sleep.
- At most two 8 GB QEMU builds at once, and fewer when gem5 sims are running.
- Packer refuses an existing output directory. Before a rebuild, move the old
  output aside (for example `<dir>-old/`), add it to the dir's `.gitignore`,
  and repoint any JSON entry or running sim that uses it. Never delete an
  image the user hasn't said to delete.
- After a base build, compute its sha256 and put it in the npb and gapbs
  `.pkr.hcl` `iso_checksum` for that version before building them:
  `sha256sum <image> | tee <task>/runs/<isa>-base-<ver>.sha256`.

### 4. Check every build: a "successful" packer run is not enough

The provisioning scripts don't stop on errors, so packer can finish while the
image is broken. For each finished build:

1. `scripts/check-build-log.sh <log>`: greps for disk-full, dpkg/apt lock
   errors, failed git clones, compile errors, shutdown inhibitors. Any hit
   means investigate before going on.
2. `scripts/check-image.sh <image> <root-partition> <kind>`: extracts the
   root filesystem (no root needed) and checks that gem5-bridge, libm5,
   `/sbin/init → gem5_init.sh`, `after_boot.sh` and the benchmark binaries
   exist.

### 5. Register the resources

`python3 -I scripts/add_resource.py --json <json> --isa <isa> --kind <base|npb|gapbs> --ubuntu <ver> --image <path> --kernel <id>[:<ver>]`

It adds the disk-image entry and its workload (`<isa>-ubuntu-<ver>-boot*`,
`-npb-bt-s` or `-gapbs-bc-test`) with md5, size and a `file://` URL. It
replaces earlier entries with the same id and version, and locks the file so
parallel builds can register safely. Run `--help` for the overrides (ids,
resource version, author, gem5 versions). x86 kernel entries are extracted from
the base image (`scripts/extract-x86-kernel.sh` in the source dir) and added by
hand from an existing kernel entry.

After any rebuild that changes the md5, delete gem5's cached copy:
`rm -rf ~/.cache/gem5/<disk-id>*`. Otherwise gem5 may use the stale one.

### 6. Validate in gem5

`scripts/validate.sh <gem5-dir> <json> <isa> <workload-id> [version] [--validate-npb]`

It starts the run detached under `<task>/runs/<workload>-<date>/` (or the
gem5 dir's `m5out/` outside a task folder) and prints the PID
and the output dir. Run the workloads for all ISAs at once if the host has the
cores. Expected wall times: x86/arm boot about 1 h; riscv TIMING with systemd
2–5 h; npb and gapbs add 1–3 h. When a run exits, a pass is
`All exit events are called in expected order` in `simout.txt` (and, for npb,
`Verification    =               SUCCESSFUL` in the board's terminal output and
no `Validation failed.`).

- Check progress on a long run:
  `python3 util/hypercall_external_signal/orchestrator_request.py --pid <pid> status`
  (current tick and instruction count). Use the console output
  (`board.pc.com_1.device` / `board.terminal` / `board.platform.terminal`) to
  see where the boot is.
- A RISCV-only or ARM-only gem5 build can't run the stock validator (it
  imports every demo board). Copy it to a scratch dir and drop the other
  imports.
- When watching a run, match hypercalls case-insensitively (simout prints
  `Hypercall 1`), and watch for the process exiting, not only for success
  lines, so a crash is noticed.
- `N consecutive SC failures` warnings in simerr are a false alarm: the
  counter never resets, so it's a running total.
- If a run fails or stops making progress, use the `gem5-debug` skill.

### 7. Record

Keep a running issues list in the task folder's `notes.md` (never in the
repo): symptom, cause, fix, verified-by. Update it as each issue
is solved, not at the end. If an issue is general (would hit any future
version), also add it to this skill's `reference/gotchas.md`.

### 8. Hand off

Report a table: resource id, md5, validation result, output dir. List any
changed shared scripts. Shared-script changes mean the older versions should be
rebuilt and rechecked, so say so; don't skip it silently. Leave committing and
uploading to the user.
