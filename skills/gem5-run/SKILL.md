---
name: gem5-run
description: Build gem5 and run, watch and compare gem5 simulations (SE or full-system) - background builds with logs, detached runs recorded with their binary and commit, status and crash detection, waiting for a run to exit or hit a line like "Hypercall 1", and stage-by-stage comparison with a baseline run with a finish-time estimate. Use when the user wants to build gem5, start or check a simulation, know whether a run passed, crashed or is stuck, or compare a run against an earlier one.
argument-hint: "[build ISA | run CONFIG | status | compare BASELINE RUN]"
---

# gem5-run: build, run, watch, compare

Scripts are in `scripts/`. They use the task folder you're in (made by the
`gem5-branch` skill): `gem5/` is the gem5 to build and run, and build logs and
run output go in `runs/`. Outside a task folder they fall back to `GEM5_CLONE`
from `~/.config/gem5-skills/config` and its `m5out/`; pass `--gem5 DIR` to use
any other checkout.

## Build

`scripts/build.sh [TARGET] [--gem5 DIR] [-j N] [--keep-old]`

TARGET defaults to `ALL` (`build/ALL/gem5.opt`). Build something else only
when the user asks for it: an ISA (`X86`, `RISCV`, ...) or an ISA and variant
(`X86/gem5.fast`, `RISCV/gem5.debug`).

- Start it in the background and wait for it to exit; don't poll. A full
  build takes 30-90 minutes, a no-change rebuild about a minute.
- `--keep-old` saves the current binary as `gem5.<variant>.prev` first, for
  before/after runs of a change.
- One build per checkout at a time; the script refuses a second one.
- An ISA-only build can't run configs that import other ISAs' boards (the
  stock disk-image validator imports all of them): copy the config to the
  task folder and drop the other imports.

## Run

`scripts/run.sh [--gem5 DIR] [--binary PATH] [--name NAME] [--json FILE] [--env KEY=VALUE]... [--debug-flags F] [--debug-start TICK] [--debug-file NAME] -- CONFIG [ARGS...]`

- Starts gem5 detached (it survives the session) in `runs/<name>-<date>/` and
  prints the pid and output dir.
- `run-info.txt` records the command, the binary and when it was built, and
  the gem5 commit and number of modified files; `gem5.diff` holds the
  uncommitted changes. Quote these when reporting results.
- Several runs can go at once. Each uses one host core and about 1 GB of RAM
  (more for big guest memory); leave cores for builds.

### Local resources and environment variables

To use resources that aren't published yet (a disk image or kernel you just
built, listed in a local resources JSON with `file://` URLs), gem5 reads
these environment variables:

| Variable | Effect |
|---|---|
| `GEM5_RESOURCE_JSON_APPEND=/abs/path.json` | Adds the JSON's resources to the usual ones. The normal choice. |
| `GEM5_RESOURCE_JSON=/abs/path.json` | Uses only that JSON; nothing else is found. Can't be combined with `_APPEND`. |
| `GEM5_CONFIG=/abs/gem5-config.json` | A resources config file listing several sources. |
| `GEM5_RESOURCE_DIR=/abs/dir` | Where downloaded resources are cached (default `~/.cache/gem5`). |

With `run.sh`, `--json FILE` sets `GEM5_RESOURCE_JSON_APPEND`, and
`--env KEY=VALUE` sets any of the others. Both are recorded in
`run-info.txt`. Without `run.sh`, put the variable before the command:

```sh
cd <gem5> && GEM5_RESOURCE_JSON_APPEND=/abs/path/26.04-resources.json \
    build/ALL/gem5.opt -re configs/example/gem5_library/<config>.py ...
```

simout then says `Appending resources from <path>`. If a resource still
isn't found:

- gem5 only finds entries whose `gem5_versions` includes the running gem5's
  version (for example `"26.0"`). Add it to the JSON entry.
- The id or `resource_version` in the config doesn't match the JSON.
- After rebuilding an image (new md5), delete gem5's cached copy, or gem5 may
  keep using the old one: `rm -rf ~/.cache/gem5/<resource-id>*` (ask first).

## Watch

- `scripts/status.sh [OUTDIR...]` gives a one-shot status of each run: PASS,
  FAIL, RUNNING or EXITED with the reason, plus the hypercalls seen, any
  benchmark results, crash lines, and the last console line. With no
  arguments it shows the task's running runs and the 3 newest.
- To wait, start `scripts/watch.sh [--all] [--until REGEX] OUTDIR...` in the
  background. It returns when any run exits (or all, with `--all`), or when
  REGEX appears in a run's simout or console, and prints the status. When it
  returns, tell the user what happened, then start it again for the runs
  still going. Don't poll with sleep, and don't use short-lived watchers for
  runs that take hours.
- To stop a run (only when the user asks, for example "stop after hypercall
  1"): `watch.sh --until 'Hypercall 1' DIR`, then `kill -- -<pid>` (the pid
  `run.sh` printed; the minus stops the whole process group). gem5's own pid
  is in `gem5.pid`, its exit code in `exit-code`.

What the output means:

- Pass, for the disk-image workloads: `All exit events are called in expected
  order` in simout. Otherwise go by gem5's exit code (0 is a clean exit) and
  the program's own output; stdlib `Simulator` configs don't print an
  `Exiting @ tick` line.
- `N consecutive SC failures` warnings are not a problem: the counter never
  resets, so it's a running total. A passing riscv 26.04 boot has about 100.
- Long quiet periods on the console are normal. The console file is written
  in chunks, and parts of a boot print nothing for an hour of host time. Check
  that the run is alive and compare it with a baseline before calling it
  stuck. If it's really stuck, use the `gem5-debug` skill.
- A run with no exit line at all was killed or crashed hard; read the end of
  `simerr.txt`.

## Compare

`python3 -I scripts/compare.py BASELINE_OUTDIR RUN_OUTDIR`

Shows host time per stage (between stats dumps, which the disk-image
workloads take at each hypercall) for both runs and the ratio. If the run is
still going, it estimates the finish time from the baseline's remaining
stages. Use it to tell the user when to expect results, and to tell a
slowdown caused by host load (one stage slower, the rest the same) from one
caused by the change (every stage slower).

## Record

Add each finished run to the task's `notes.md`: what was run, binary and
commit (from `run-info.txt`), result, output dir. Results from a run whose
binary is older than the latest source change don't count as testing that
change; say so.
