---
name: gem5-fix-issue
description: Take a gem5 GitHub issue (or a bug the user describes) from report to a PR-ready branch - read the issue, check whether it's already fixed or being worked on, agree the testing bar, make a fix branch from upstream develop, reproduce the bug, find the cause, fix it with a regression test, test it, and draft the commit message and PR description. Uses the gem5-branch, gem5-run, gem5-debug and gem5-pr skills. Drafts only - never commits, pushes, opens PRs or comments on the issue. Use when the user says "fix issue N", "look at this gem5 issue", or "someone reported X, can you write a patch".
argument-hint: "<issue number or URL>"
---

# gem5-fix-issue: from issue to PR-ready branch

This ties the other gem5 skills together. Follow each one's own rules; in
particular **never** commit, push, open a PR, or post on the issue. Stop and
check in with the user at the points marked **Ask**. Keep everything you
learn in the task's `notes.md` as you go, so the work can be picked up again
in a new session.

## 1. Read the issue

`scripts/issue.sh N [--repo gem5/gem5-resources]` shows the report, comments,
labels and linked PRs. Summarise for the user in a few lines: what fails,
on which ISA, CPU model, config and gem5 version, how to reproduce it, and
what's unclear.

## 2. Is it already fixed, or being worked on?

- A linked PR that's **merged** may already fix it, even if the issue is
  still open (issues aren't always closed by their fix). Check whether the
  fix is in `develop`.
- A linked PR that's **open**, or a comment like "I'm working on this":
  someone else has it.
- Search for more: `gem5-pr`'s `related-prs.sh` with the function, file and
  symptom.

**Ask:** if it looks fixed or taken, tell the user what you found and let
them decide: verify the existing fix, review or test the open PR (check it
out with `gem5-branch --pr N`), or carry on with their own.

## 3. Agree the plan

**Ask** the user, in one message:

- the testing bar (suggest one from what the bug touches; see `gem5-pr`),
  recorded in `notes.md` under `## Testing bar`
- the branch: `fix/<N>-<topic>` from upstream `develop` (`gem5-branch`,
  `--issue N`), plus gem5-resources only if the fix needs it

Then make the task folder with `gem5-branch` and put the issue summary at
the top of `notes.md` (number, link, one-paragraph summary).

## 4. Reproduce it first

Build the branch as it is, before changing anything (`gem5-run`'s
`build.sh`), and run the reporter's steps (`run.sh`). Write down the exact
command and the result.

- Reproduced: keep that run as the "before" result.
- Not reproduced: try the reporter's gem5 version, ISA build and CPU model.
  If it still doesn't fail, stop and tell the user; it may already be fixed
  or depend on something not in the report. A draft comment asking the
  reporter for details can go in `notes.md`.

## 5. Find the cause

Use `gem5-debug`. Make the reproduction as small as you can (ideally a short
SE test that fails in seconds), and explain the cause to the user in plain
words before fixing it.

## 6. Fix it, with a regression test

- Keep the fix small and in the style of the surrounding code. If there are
  several possible fixes, say which you chose and why in one sentence.
- Add a regression test where gem5 has a place for it (TestLib tests in
  `tests/gem5/`, written and run with `gem5-testlib`; pyunit tests; or the
  asm and bare-metal tests for ISA work). If there's
  no good place, keep the small test program in the task folder and mention
  it in the PR description.
- Rebuild with `build.sh --keep-old`, so the old and new binaries can run the
  same test side by side.

## 7. Test against the bar

Run everything in the testing bar with the new binary (`gem5-run`), plus the
original reproduction: it must fail on the old binary and pass on the new
one. Record each result in `notes.md` with the output dir. Don't count a run
from a binary built before the last source change.

## 8. Get it ready

Run `gem5-pr`'s `check-branch.sh`, then draft the commit message and PR
description in `pr-draft.md` (with `Fixes #N`). Give the user:

- a few lines on the cause and the fix
- the test results table
- the files changed (uncommitted), and the commit message to use
- anything left open

The user reviews, commits, pushes and opens the PR.
