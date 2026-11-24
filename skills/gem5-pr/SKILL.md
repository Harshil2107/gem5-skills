---
name: gem5-pr
description: Get a gem5 or gem5-resources branch ready for a pull request, and handle review comments - search for overlapping upstream PRs and issues, check commits against gem5's commit message rules and style checks, check the agreed testing is done, draft commit messages and the PR description, and draft replies to reviewer comments. Drafts only - never commits, pushes, opens PRs or posts comments. Use when the user asks for a commit message, a PR description, whether a branch is ready, or what to do about review comments on a PR.
argument-hint: "[ready | describe | review <PR number>]"
---

# gem5-pr: get a branch ready, answer reviews

Everything here is a draft for the user. **Never** commit, push, open or
update a pull request, or post anything on GitHub, even if asked to "go
ahead"; give the user the text and the commands instead. Searching and
reading GitHub is fine.

Drafts go in the task folder (from `gem5-branch`): `pr-draft.md` for commit
messages and the PR description, `review-replies.md` for review replies.
Keep all text short and plain, and lead with what changed and why.

## 1. Check for overlap first

Before writing a fix, and again before the PR:
`scripts/related-prs.sh [--repo gem5/gem5-resources] TERM...`
with the instruction, function, file or symptom (try a few searches). For
each hit that overlaps, tell the user what it does, its state, and how it
differs from this change. Let the user decide whether to review or test the
existing PR, comment on it, or open their own.

## 2. Agree the testing bar

The testing needed depends on the change, so ask the user at the start of
the task and record it in `notes.md` under `## Testing bar`. Suggest a
starting point from what the change touches, for example:

- ISA or instruction change: a small SE test of the instruction on Atomic,
  Timing, Minor and O3 (`gem5-debug`'s `se-all-cpus.sh`), plus the workload
  that found the bug.
- CPU model or memory system change: the affected TestLib tests in
  `tests/gem5/` (run them with `gem5-testlib`), and one full-system boot.
- Python stdlib or config change: the pyunit tests and an example config.
- gem5-resources change: build and validate the affected resource
  (`gem5-disk-images`), and the JSON entries load in gem5.

A test counts only if it ran a binary built after the last source change
(`gem5-run`'s `run-info.txt` shows the build time).

## 3. Check the branch

`scripts/check-branch.sh [DIR] [--pre-commit]` (run in the worktree). It
reports commits on top of the main repo's base, how far behind the base the
branch is, commit message problems (gem5's own `util/git-commit-msg.py`
rules: tags from `MAINTAINERS.yaml`, header ≤ 65 characters, blank line),
local files in the diff, debug leftovers, whitespace errors, the recorded
testing bar, and with `--pre-commit`, gem5's style checks. pre-commit may
reformat files; tell the user which, and leave them uncommitted.

## 4. Draft the commit messages and PR description

Commit messages, gem5 style:

```
arch-riscv: Fix TIMING page walks skipping m5op handling

<2-5 lines: what was wrong, what the change does, why this way.>
```

- Tags come from `MAINTAINERS.yaml` (`arch-riscv`, `cpu-simple`, `mem`,
  `stdlib`, `tests`, ...; several are joined with commas). For gem5-resources
  use `resources:`.
- One logical change per commit. For changes after review, ask whether the
  user wants to amend the original commit (keeps history clean) or add a
  follow-up commit (easier for reviewers to see); amending is the usual
  choice in gem5.

PR description, from `reference/pr-template.md`: what was broken and how it
showed up, what the change does, how it was tested (the testing bar and the
results), and related PRs or issues. Put `Fixes #N` if it closes an issue.

## 5. Review comments

`scripts/pr-comments.sh NUMBER [--since DATE] [--no-bots]` lists every
comment in time order, inline ones with the code they refer to.

For each comment, in `review-replies.md`:

1. Explain it in plain words, and whether it's valid (check the code; don't
   take a reviewer's or a bot's claim on trust, and don't dismiss it either).
2. If a change is needed, make it in the worktree (uncommitted) and test it
   against the testing bar.
3. Draft a short reply: what was changed (and in which commit, once the user
   has committed it), or why not, with evidence.

Comments from AI review bots are worth checking too, but say which ones are
from bots.
