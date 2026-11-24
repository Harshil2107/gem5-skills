# gem5-skills

[Claude Code](https://claude.com/claude-code) skills for working on
[gem5](https://github.com/gem5/gem5) and
[gem5-resources](https://github.com/gem5/gem5-resources).

A skill is a folder with a `SKILL.md` file of instructions, plus any scripts it
uses. Claude Code always sees each skill's one-line description and loads the
full instructions only when your request matches it, or when you type
`/<skill-name>`. You don't need to remember the skill names: ask in plain
words and Claude picks the right one.

## Skills

| Skill | What it does |
|---|---|
| [`gem5-branch`](skills/gem5-branch/SKILL.md) | Starts a piece of work in its own task folder: a new branch from the main gem5 repos (`develop` for gem5, `stable` for gem5-resources), an existing gem5 PR to test or fix, a branch already on your fork, or a worktree you already have. |
| [`gem5-run`](skills/gem5-run/SKILL.md) | Builds gem5 (`build/ALL/gem5.opt` unless you ask for another), starts SE or full-system runs detached, reports pass/crash/running, waits for a run to exit or hit a line like `Hypercall 1`, and compares a run with a baseline, with a finish-time estimate. |
| [`gem5-debug`](skills/gem5-debug/SKILL.md) | Finds the cause of a simulator bug: image vs gem5, where a run is stuck, tracing only a short window of a long run, pulling binaries out of disk images, and small SE tests run on every CPU model at once. Includes case studies of real gem5 bugs. |
| [`gem5-testlib`](skills/gem5-testlib/SKILL.md) | Writes and runs gem5 TestLib regression tests: where a new test goes, quick/long/very-long, `gem5_verify_config` with verifiers, running one suite against an existing build, and reading the results. |
| [`gem5-pr`](skills/gem5-pr/SKILL.md) | Gets a branch ready for a pull request: overlapping PRs and issues upstream, gem5's commit rules and style checks, whether it's already merged, the agreed testing, drafts of the commit messages and PR description, and drafts of replies to review comments. |
| [`gem5-fix-issue`](skills/gem5-fix-issue/SKILL.md) | Takes a gem5 issue (or a bug you describe) to a PR-ready branch: is it already fixed or taken, reproduce, find the cause, fix with a regression test, test, draft the PR. Uses the skills above. |
| [`gem5-disk-images`](skills/gem5-disk-images/SKILL.md) | Builds, checks, registers and validates gem5-resources Ubuntu disk images (base, npb, gapbs) for x86, arm and riscv. |
| [`gem5-resource-json`](skills/gem5-resource-json/SKILL.md) | Makes and checks resources JSON entries for any category (binaries, kernels, disk images, directories, workloads, suites): finds what's new or changed against the database, copies an existing entry's format, computes md5s with gem5's code, writes the upload JSON plus a `file://` copy for testing, and optionally builds and tests the resources. Per-source notes and helpers in `sources/` (asmtest so far). |

**The skills never commit, push, open pull requests, post on GitHub, or
delete branches, worktrees, images or task folders.** Claude makes the
changes, tests them and writes drafts; you review, commit and push.

They also never publish resources. Uploading to Azure and inserting into
the resources MongoDB is done by [`tools/publish-resources.py`](tools/README.md),
which you run yourself from a terminal (Claude can only run its dry run).

## Setup

You need Claude Code, git, and your own forks of gem5 and gem5-resources on
GitHub.

1. **Clone gem5 and gem5-resources once each**, if you haven't already. Each
   clone needs a remote for the main repo and one for your fork. The remote
   names don't matter; the skills find them by URL.

   ```sh
   git clone https://github.com/gem5/gem5.git ~/gem5
   git -C ~/gem5 remote add fork https://github.com/<you>/gem5.git

   git clone https://github.com/gem5/gem5-resources.git ~/gem5-resources
   git -C ~/gem5-resources remote add fork https://github.com/<you>/gem5-resources.git
   ```

2. **Install the skills:**

   ```sh
   git clone https://github.com/Harshil2107/gem5-skills.git ~/gem5-skills
   ~/gem5-skills/install.sh
   ```

   This links each skill into `~/.claude/skills/`, so a `git pull` in
   `~/gem5-skills` updates them. It also creates your settings file,
   `~/.config/gem5-skills/config`, from the template. If a skill with the
   same name is already in `~/.claude/skills/`, it's skipped; move that one
   away and run `install.sh` again.

3. **Fill in the settings file** (`~/.config/gem5-skills/config`):

   ```sh
   GITHUB_USER=<you>                 # your fork is the remote owned by this user
   GEM5_CLONE=$HOME/gem5             # the clones from step 1
   RESOURCES_CLONE=$HOME/gem5-resources
   WORK_DIR=$HOME/gem5-work          # task folders go here
   GEM5_BASE=develop                 # what new branches start from
   RESOURCES_BASE=stable
   TESTLIB_BIN_PATH=$HOME/gem5-test-resources   # optional, see below
   ```

   Everything personal lives here, so the skills stay the same for everyone.
   `TESTLIB_BIN_PATH` is a folder for the disk images and kernels that gem5's
   tests download; with it, they're downloaded once for all your worktrees
   instead of once per worktree (several GB each).

4. **Check it:** start Claude Code and ask *"what gem5 skills do you have?"*.
   Then try a dry run:

   ```sh
   ~/.claude/skills/gem5-branch/scripts/new-task.sh --repo both --type test --topic try-it --dry-run
   ```

   It should show both worktrees starting from `github.com/gem5/...` and
   pushing to your fork.

## How it works: task folders

Each piece of work gets its own folder under `WORK_DIR`, and you start Claude
Code inside it. The skills find everything from there.

```
~/gem5-work/<task>/
├── gem5/             a git worktree (or a link to one you already have)
├── gem5-resources/   only if the task needs it
├── notes.md          where each branch came from, then findings, decisions,
│                     the testing bar and results; read by later sessions
└── runs/             build logs, simulation output, test logs
```

`notes.md` is what lets you stop and continue later: a new Claude session in
the folder reads it and picks up where the last one left off. Ask Claude to
keep it up to date.

## Where to start Claude

Start Claude Code **inside the task folder**, not in your home directory.
Claude Code's file access and its memory are scoped to the folder it starts
in, so a task folder limits it to what the task needs:

- it reads and edits files in the task folder freely (including its gem5
  worktree), and asks before touching files anywhere else;
- it asks before running commands, unless you've allowed them;
- the skills (in `~/.claude/skills/`) and your settings file still work from
  any folder.

You can start in `WORK_DIR` (for example `~/gem5-work`) to have Claude make the
task folder, but move into the task folder for the actual work.

### Example: fixing a gem5 issue

Say you want to fix [gem5 issue 3777](https://github.com/gem5/gem5/issues/3777)
("[RISC-V/SE] sysinfo leaves guest output fields untouched"):

1. Make the task folder, from your terminal (no Claude needed):

   ```sh
   ~/.claude/skills/gem5-branch/scripts/new-task.sh --repo gem5 --type fix --topic riscv-sysinfo --issue 3777
   ```

   This makes `~/gem5-work/3777-riscv-sysinfo/` with `gem5/` on a new branch
   `fix/3777-riscv-sysinfo` from upstream `develop`.

2. Start Claude there:

   ```sh
   cd ~/gem5-work/3777-riscv-sysinfo && claude
   ```

3. Ask: *"Fix gem5 issue 3777."* Claude reads the issue, checks whether it's
   already fixed or someone is on it, asks you for the testing bar, then
   reproduces the bug, fixes it, tests it, and drafts the PR. You review,
   commit and push.

To come back later, start Claude in the same folder again; it picks up from
`notes.md`.

## How to use

### Start a task

Ask Claude in plain words, for example:

- *"Start a fix branch for the riscv fault-only-first bug, issue 3408."*
- *"Make a resources task for Ubuntu 26.04 disk images, gem5-resources only."*

Claude asks for anything missing, shows a dry run, then creates the folder.
New branches are named `TYPE/[ISSUE-]TOPIC` (`TYPE` is `fix`, `feature`,
`resources`, `test` or `docs`) and start from upstream `develop` (gem5) or
`stable` (gem5-resources), never from a fork. `git push` is set to go to your
fork, but nothing is pushed.

You can also start from something that already exists:

| Ask | You get |
|---|---|
| *"Check out gem5 PR 3746 so I can test it."* | someone else's PR as `pr/<owner>/3746` in `~/gem5-work/pr-3746/` (you can't push to it); your own PR as its real branch, so `git push` updates the PR |
| *"Continue my branch riscv-fof-fix from my fork."* | that branch, tracking your fork; if you have it locally already, your local copy is used as it is |
| *"Make a task folder for my worktree ~/worktrees/my-branch."* | a task folder whose `gem5/` is a **link** to that worktree: nothing is copied or moved, both paths are the same files, and you can keep working in either |

To add the other repo to a task later: *"add gem5-resources to this task"*.

### Build gem5 and run simulations

Ask for example *"build gem5"* (builds `build/ALL/gem5.opt`; ask for
`X86/gem5.fast` or similar if you want another), *"run the riscv boot on
TIMING and tell me when it reaches hypercall 1"*, *"what's the status of my
runs?"* or *"compare this run with last week's"*.

- Runs keep going if Claude Code exits; ask for their status in a new
  session.
- Each run records its binary, build time, gem5 commit and uncommitted
  changes in `runs/<run>/run-info.txt`.
- To use resources you built yourself (a local resources JSON with
  `file://` URLs), ask Claude to run with that JSON. It sets
  `GEM5_RESOURCE_JSON_APPEND`; by hand that's
  `GEM5_RESOURCE_JSON_APPEND=/abs/path/resources.json build/ALL/gem5.opt ...`.
  The [`gem5-run` skill](skills/gem5-run/SKILL.md) lists the other resource
  variables and what to check when a resource isn't found.

### Debug a failing run

Ask for example *"the boot hangs after dbus starts, find out why"* or *"this
test gives different results on TIMING and O3"*. Claude works through the
steps in [`gem5-debug`](skills/gem5-debug/SKILL.md) and writes findings to
`notes.md`. Two of its scripts are useful on their own:

- `se-all-cpus.sh --gem5 DIR --binary build/RISCV/gem5.opt TEST` runs a small
  static test program on Atomic, Timing, Minor and O3 at once and says
  whether the output differs.
- `extract-from-image.sh IMAGE PART OUT /path/in/guest ...` copies files out
  of a disk image without root.

### Write and run gem5 tests

Ask *"add a testlib test for this config"*, *"run the arm boot tests"* or
*"rerun what failed"*. Tests run against your existing `build/ALL/gem5.opt`
(no rebuild) unless you ask for a build, several at once, with shared test
resources if `TESTLIB_BIN_PATH` is set. You can also use the script directly:

```sh
cd ~/gem5-work/<task>
~/.claude/skills/gem5-testlib/scripts/testlib.sh list gem5/arm_boot_tests --length long
~/.claude/skills/gem5-testlib/scripts/testlib.sh run --uid <SuiteUID>
~/.claude/skills/gem5-testlib/scripts/testlib.sh rerun
```

### Fix a gem5 issue

Ask *"fix gem5 issue 3408"* (or paste the link), or type
`/gem5-fix-issue 3408`. Claude reads the issue, checks whether it's already
fixed or someone is on it, and asks you for the testing bar and the branch
before starting. Then it reproduces the bug, finds the cause, fixes and tests
it, and leaves you a branch with uncommitted changes and a drafted PR. It
stops to ask if it can't reproduce the bug.

### Prepare a pull request

Ask *"is this branch ready for a PR?"*, *"draft the commit message and PR
description"*, *"is anyone already working on this upstream?"* or *"what do
the review comments on PR 1234 want?"*. Drafts go to `pr-draft.md` and
`review-replies.md` in the task folder. The testing a PR needs differs per
task: Claude asks you and records it in `notes.md` under `## Testing bar`.

### Build disk images

From a task folder with `gem5-resources/` (and `gem5/` to validate with), ask
for example *"build and validate the Ubuntu 26.04 riscv npb image"*, or type
`/gem5-disk-images 26.04 riscv npb`. Read
[`gotchas.md`](skills/gem5-disk-images/reference/gotchas.md) first if you're
adding a new Ubuntu version.

### Add resources to gem5 resources

From a task folder with the gem5-resources PR (and `gem5/`), ask for example
*"make the resources JSON for the new binaries in this PR"*, or
*"build the new asmtests in PR 85, test them in gem5, and make the JSON"*.
Claude lists what's new or changed, asks for the template entry, versions
and URL folder, writes `resources/<name>.json` and its manifest, and checks
them. Then you publish:

```sh
~/gem5-skills/tools/publish-resources.py <task>/resources/<name>.json --gem5 <task>/gem5             # dry run
~/gem5-skills/tools/publish-resources.py <task>/resources/<name>.json --gem5 <task>/gem5 --publish
```

See [`tools/README.md`](tools/README.md) for its one-time setup (`az login`,
pymongo, the MongoDB URI file).

### Tips

- Give Claude the whole picture in your first message: the goal, the branch,
  what you've tried, where earlier output is, and what to start with.
- For anything big, ask for a plan first ("write what we know into notes.md
  and propose a plan; don't change code yet").
- Long builds and simulations run in the background; Claude reports when
  they finish. You can keep talking to it meanwhile.

## Updating

```sh
git -C ~/gem5-skills pull
```

Because the skills are links, there's nothing else to do. Run `install.sh`
again only when a new skill has been added. Settings files are never
overwritten.

## What's in this repo, and what isn't

This repo holds only the skills (`skills/`), tools you run by hand (`tools/`),
`install.sh` and this README.
Nothing personal goes in it:

| Not in the repo | Where it lives |
|---|---|
| your settings | `~/.config/gem5-skills/config` |
| the MongoDB write URI | a file only you can read, named by `RESOURCES_MONGO_URI_FILE` |
| task folders, notes, run output | `WORK_DIR` (for example `~/gem5-work/`) |
| Claude's memory of your projects | `~/.claude/` |

## Adding or changing a skill

- One skill per folder under `skills/`, with a `SKILL.md` that starts with
  `name` (the folder name) and `description` front matter. The description
  decides when Claude uses the skill, so say what it does and when to use it.
- Keep `SKILL.md` short; put long reference material in `reference/` and
  scripts in `scripts/`, and say in `SKILL.md` when to read or run them.
- No personal paths or usernames in a skill. Read them from
  `~/.config/gem5-skills/config`, and add new settings to
  `skills/gem5-branch/config.example`.
- Scripts must never commit, push or delete anything, and should have a
  `--dry-run` where they change things.
- Test scripts with a dry run or in a throwaway folder before pushing.
- Run `./install.sh` after adding a new skill folder.
