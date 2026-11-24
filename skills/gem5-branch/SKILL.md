---
name: gem5-branch
description: Start a piece of gem5 or gem5-resources work in its own task folder - a new branch from the main gem5 repo's develop or stable (never a fork), an existing pull request on gem5/gem5 or gem5/gem5-resources checked out to test or fix it, a branch already on the user's fork, or a worktree the user already has. Use when the user wants a new branch, worktree or task folder, wants to test, review or fix someone's PR or their own PR, wants to continue work on a branch they pushed earlier, or is starting work on a bug, issue, feature, test or new resource.
---

# gem5-branch

Each piece of work gets its own task folder, with the repos it needs side by
side:

```
$WORK_DIR/<folder>/
├── gem5/             worktree of the gem5 clone
├── gem5-resources/   worktree of the gem5-resources clone
├── notes.md          the branches and where they came from, then findings
└── runs/             build logs and m5out directories for this task
```

Other gem5 skills work inside the task folder they are run from.

## Settings

`~/.config/gem5-skills/config` holds the user's GitHub username, their two
main clones, `WORK_DIR` and the default base branches. If it's missing, copy
`config.example` from this skill there and ask the user for the values.

## Ways to start

| The user wants to | Run `scripts/new-task.sh` with | Gets |
|---|---|---|
| start new work | `--repo gem5\|resources\|both --type TYPE --topic TOPIC [--issue N] [--base B]` | branch `TYPE/[N-]TOPIC` from upstream `develop` (gem5) or `stable` (resources), pushing to their fork |
| test, review or fix a PR on gem5/gem5 or gem5/gem5-resources | `--repo gem5\|resources --pr N` | the PR's current code. Their own PR: its real branch name, so `git push` updates the PR. Someone else's: `pr/<owner>/<N>`, no push target |
| continue a branch already on their fork | `--repo gem5\|resources --existing BRANCH` | that branch, tracking the fork. If they already have it locally, their local copy is used as is (with how far ahead or behind the fork it is) |
| use a worktree they already have (for example one made before these skills) | `--adopt DIR` | a task folder whose `gem5/` (or `gem5-resources/`) links to that worktree; nothing in it is moved or changed |

- **type**: `fix`, `feature`, `resources`, `test` or `docs`; **topic**: a few
  lowercase words joined by dashes (`riscv-fof-timing`).
- Folders: `[N-]TOPIC` for new work, `pr-N` for PRs, the branch name (with
  `/` as `-`) for existing branches; `--folder NAME` overrides.

## Steps

1. Work out the mode and options from the request; ask only for what's
   missing.
2. Run the script with `--dry-run` and show the user what it will make.
3. Run it again without `--dry-run`.
4. Tell the user the task folder, the branch, where it came from (upstream
   commit, PR and its state, or fork branch), where `git push` would go, and
   that nothing was pushed.

To add the second repo to a task later, run the script again with the other
`--repo` and `--folder` set to that task's folder name.

For someone else's PR, changes can't be pushed to it. To propose a change,
draft a review comment with the diff (`gem5-pr`), or start a new branch.

## Rules

- New work always starts from the main repo (`github.com/gem5/gem5` or
  `github.com/gem5/gem5-resources`), found by URL, not by remote name,
  because names differ between clones. Never base work on a fork or a lab
  mate's remote, even if it's called `upstream`.
- Never push, and never delete or reset branches, worktrees or task folders,
  unless the user asks. An existing local branch is reused as it is; tell the
  user how to update it rather than updating it.
- If the script stops (folder exists, branch already checked out somewhere,
  no such branch on the fork, no remote for the main repo), tell the user
  what it said; don't work around it.
