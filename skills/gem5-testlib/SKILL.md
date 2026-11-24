---
name: gem5-testlib
description: Write and run gem5 regression tests in TestLib (tests/main.py, tests/gem5/) - choosing where a new test goes and its length (quick/long/very-long), writing a gem5_verify_config test with verifiers, running one suite against an existing build, and reading the results. Use when the user wants to add a test for a config, fix or feature to gem5's test suite, run a specific gem5 test or test directory, or find out why a gem5 CI test failed. For pyunit tests see tests/AGENTS.md.
---

# gem5-testlib: write and run TestLib tests

Read `tests/AGENTS.md` in the gem5 checkout first; it's gem5's own guide and
is kept up to date there. This skill adds how to write a test and the
helper script.

## Where a test goes and how long it may take

- Tests live in `tests/gem5/<area>/test_*.py`. Put a new one next to the
  tests most like it: `example_configs/<topic>/` for a config in
  `configs/example/`, `arm_boot_tests/` (and the other `*_boot_tests/`) for
  Linux boots on the stdlib boards, `se_mode/` for SE programs, and so on.
  Read one or two neighbours and copy their style.
- Length decides when CI runs it: `quick` on every PR (a few minutes at
  most), `long` daily, `very-long` weekly. A full-system boot to the end of
  `after_boot.sh` is `long` or `very-long`; to keep a quick version, stop at a
  fixed tick (see `arm_boot_tests/test_linux_boot.py`, `to_tick`).
- `valid_isas=(constants.all_compiled_tag,)` makes it use `build/ALL/gem5.opt`,
  which is what CI builds; use that unless the test needs a single-ISA build.

## Writing the test

```python
import re
from testlib import *

gem5_verify_config(
    name="test-<what>-<how>",                 # unique; becomes the SuiteUID
    config=joinpath(config.base_dir, "configs", "example", "...", "x.py"),
    config_args=["--option", "value"],        # args for the config script
    verifiers=(verifier.MatchRegex(re.compile(r"<line that means success>")),),
    fixtures=(),
    valid_isas=(constants.all_compiled_tag,),
    valid_hosts=constants.supported_hosts,
    length=constants.long_tag,
)
```

- Verify something that only a correct run prints: the stdlib exit messages,
  a benchmark's verification line, a hypercall. `MatchRegex` checks simout
  and simerr; `MatchFileRegex(regex, filenames)` checks other output files;
  `NoMatchRegex` fails if something (for example `panic:`) appears.
- A config used by a test must finish on its own (exit on the last
  hypercall or a tick limit) and must not need anything interactive.
- Resources: boot tests pass `--resource-directory` from `config.bin_path`
  (`tests/gem5/resources` by default) so CI can cache downloads; do the same
  if the config downloads disk images or kernels.
- Example configs that a test runs should also work when run by hand from
  the gem5 directory, since users copy them.

## Running tests

`scripts/testlib.sh` runs `tests/main.py` for you, with the log in the
task's `runs/`:

| Command | Does |
|---|---|
| `testlib.sh list [DIR] [filters]` | suites and their `SuiteUID`s |
| `testlib.sh run --uid SUITE_UID` | one suite (fastest way to check one test) |
| `testlib.sh run DIR... [filters]` | every matching suite in those directories |
| `testlib.sh rerun [DIR]` | only what failed last time |
| `testlib.sh summary` | pass/fail and time per test from the last run |

- **Filters** (same as `main.py`): `--length quick|long|very-long` (a
  directory alone selects only `quick`), `--isa ALL`, `--variant opt`,
  `--host x86_64`, `--include-tags T`, `--exclude-tags T` (for example
  `--exclude-tags kvm` on a host without KVM).
- **Speed:**
  - The build is skipped by default (`--skip-build`), using the existing
    `build/ALL/gem5.opt`. Pass `--build` (and `-j N`) only when the user
    wants TestLib to build. A test only counts if the binary was built after
    the last C++ change (the script prints the build time); Python config
    changes don't need a rebuild.
  - `-t N` runs N tests at once (default: cores - 4). Each FS boot test
    takes a core and a few GB of RAM.
  - `--bin-path DIR` (default `TESTLIB_BIN_PATH` from the settings file)
    reuses downloaded test resources across worktrees instead of
    downloading several GB per worktree. Suggest setting it if it's unset.
  - Use `--uid` for one test rather than a whole directory, and `rerun` after
    fixing a failure.
- `--dry-run` prints the `main.py` command; anything after `--` goes to
  `main.py` as is.
- Start long runs in the background and wait for them to exit.

Results are in `<gem5>/tests/testing-results/` (replaced by each run, and
gitignored): `results.xml`, and per test `SuiteUID-*/TestUID-*/` with
`simout.txt`, `simerr.txt` and `stats.txt`. For a failing test, read its
`simerr.txt` and `simout.txt` first, then rerun the config by hand with
`gem5-run` to debug it.

## Before the PR

Run the new test, the tests next to it, and anything else in the task's
testing bar (`gem5-pr`), and put the results in the PR description. Tell the
user how long the new test takes, since CI time matters to reviewers.
