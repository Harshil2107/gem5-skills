#!/bin/bash
# Make a task folder with a gem5 and/or gem5-resources worktree. Three ways
# to start:
#   new branch       from the main repo's develop/stable (never a fork),
#                    set to push to your fork
#   --pr N           an existing pull request on the main repo, to test or
#                    fix it (push target only if the PR is from your fork)
#   --existing NAME  a branch that's already on your fork, tracking it
#   --adopt DIR      a worktree you already have: the task folder links to
#                    it (nothing in it is moved or changed)
# Nothing is ever pushed.
#
# Usage:
#   new-task.sh --repo gem5|resources|both --type TYPE --topic TOPIC
#               [--issue N] [--base BRANCH] [--folder NAME] [--dry-run]
#   new-task.sh --repo gem5|resources --pr N [--folder NAME] [--dry-run]
#   new-task.sh --repo gem5|resources --existing BRANCH [--folder NAME] [--dry-run]
#   new-task.sh --adopt WORKTREE [--folder NAME] [--dry-run]
#   TYPE   fix | feature | resources | test | docs
#   TOPIC  lowercase words joined by dashes, e.g. riscv-interrupt-fix
# New branch: TYPE/[N-]TOPIC in $WORK_DIR/[N-]TOPIC. PR: pr/OWNER/N in $WORK_DIR/pr-N
# (your own PR: its branch name, so git push updates it).
# Existing: $WORK_DIR/<branch with / as ->. Running it again with the other
# --repo (and --folder) adds that repo to the same task folder.

set -euo pipefail

config=${GEM5_SKILLS_CONFIG:-$HOME/.config/gem5-skills/config}
if [ ! -f "$config" ]; then
    echo "No settings file at $config."
    echo "Copy config.example from the gem5-branch skill there and fill it in."
    exit 2
fi
# shellcheck source=/dev/null
source "$config"
: "${GITHUB_USER:?set GITHUB_USER in $config}"
: "${WORK_DIR:?set WORK_DIR in $config}"

repo="" type="" topic="" issue="" base="" folder="" pr="" existing="" adopt="" dry=0
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) repo="$2"; shift 2 ;;
        --type) type="$2"; shift 2 ;;
        --topic) topic="$2"; shift 2 ;;
        --issue) issue="${2#\#}"; shift 2 ;;
        --base) base="$2"; shift 2 ;;
        --folder) folder="$2"; shift 2 ;;
        --pr) pr="${2#\#}"; shift 2 ;;
        --existing) existing="$2"; shift 2 ;;
        --adopt) adopt="$2"; shift 2 ;;
        --dry-run) dry=1; shift ;;
        *) echo "Unknown option $1"; sed -n '11,20p' "$0"; exit 2 ;;
    esac
done

if [ -n "$pr" ] && [ -n "$existing" ]; then echo "Use --pr or --existing, not both."; exit 2; fi
if [ -n "$adopt" ]; then
    [ -z "$pr$existing$type$topic$issue$base" ] || { echo "--adopt only takes --folder and --dry-run."; exit 2; }
    git -C "$adopt" rev-parse --git-dir > /dev/null 2>&1 || { echo "$adopt is not a git worktree."; exit 2; }
    adopt=$(git -C "$adopt" rev-parse --show-toplevel)
    mode=adopt
    b=$(git -C "$adopt" rev-parse --abbrev-ref HEAD)
    slug="${b//\//-}"
    [ "$slug" != HEAD ] || slug=$(basename "$adopt")
elif [ -n "$pr" ] || [ -n "$existing" ]; then
    case "$repo" in gem5|resources) ;; *) echo "--repo must be gem5 or resources with --pr/--existing"; exit 2 ;; esac
    [ -z "$type$topic$issue$base" ] || { echo "--type/--topic/--issue/--base are only for new branches."; exit 2; }
    [ -z "$pr" ] || [[ "$pr" =~ ^[0-9]+$ ]] || { echo "--pr must be a number"; exit 2; }
    if [ -n "$existing" ]; then
        git check-ref-format --branch "$existing" > /dev/null 2>&1 || { echo "'$existing' is not a valid branch name"; exit 2; }
    fi
    mode=$([ -n "$pr" ] && echo pr || echo existing)
    slug=$([ -n "$pr" ] && echo "pr-$pr" || echo "${existing//\//-}")
else
    mode=new
    case "$repo" in gem5|resources|both) ;; *) echo "--repo must be gem5, resources or both"; exit 2 ;; esac
    case "$type" in fix|feature|resources|test|docs) ;; *) echo "--type must be fix, feature, resources, test or docs"; exit 2 ;; esac
    [[ "$topic" =~ ^[a-z0-9][a-z0-9.-]*$ ]] || { echo "--topic must be lowercase words joined by dashes"; exit 2; }
    [ -z "$issue" ] || [[ "$issue" =~ ^[0-9]+$ ]] || { echo "--issue must be a number"; exit 2; }
    slug="${issue:+$issue-}$topic"
fi
task="$WORK_DIR/${folder:-$slug}"

run() {
    echo "+ $*"
    [ $dry -eq 1 ] || "$@"
}

# github.com/OWNER/NAME, lowercase, for any https/ssh form of a GitHub URL.
normalize() {
    echo "$1" | tr 'A-Z' 'a-z' |
        sed -E 's#^(https?://|ssh://)?(git@)?##; s#^github\.com:#github.com/#; s#/+$##; s#\.git$##'
}

# Print the remote of $1 whose URL is exactly github.com/$2 (no forks).
find_upstream() {
    local clone="$1" want="github.com/$2" r
    for r in $(git -C "$clone" remote); do
        if [ "$(normalize "$(git -C "$clone" remote get-url "$r")")" = "$want" ]; then
            echo "$r"; return 0
        fi
    done
    return 1
}

# Print the remote of $1 owned by GITHUB_USER (your fork), unless the
# settings file names it ($2). Fails if there is none or more than one.
find_fork() {
    local clone="$1" override="$2" owner r found=()
    if [ -n "$override" ]; then echo "$override"; return 0; fi
    owner=$(echo "$GITHUB_USER" | tr 'A-Z' 'a-z')
    for r in $(git -C "$clone" remote); do
        case "$(normalize "$(git -C "$clone" remote get-url "$r")")" in
            "github.com/$owner/"*) found+=("$r") ;;
        esac
    done
    [ ${#found[@]} -eq 1 ] || return 1
    echo "${found[0]}"
}

# The worktree a local branch is checked out in, if any.
checked_out_at() {
    git -C "$1" worktree list --porcelain |
        awk -v b="refs/heads/$2" '/^worktree /{w=substr($0, 10)} $0 == "branch " b {print w}'
}

# PR details from GitHub: "<head owner> <head branch> <state> <title>".
pr_info() {
    local main_repo="$1" auth=()
    [ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
    curl -sf "${auth[@]}" -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/$main_repo/pulls/$pr" |
    python3 -I -c '
import json, sys
p = json.load(sys.stdin)
head = p["head"]
owner = (head.get("repo") or {}).get("owner", {}).get("login", "?")
state = "merged" if p.get("merged_at") else p["state"]
print(owner, head["ref"], state, p["title"])'
}

note() {
    # Append a line to the task's notes.md (creating it), unless dry run.
    [ $dry -eq 1 ] && return 0
    mkdir -p "$task/runs"
    [ -f "$task/notes.md" ] || printf '# %s\n\nCreated %s.\n\n## Branches\n\n' "$slug" "$(date +%F)" > "$task/notes.md"
    printf -- '%s\n' "$1" >> "$task/notes.md"
}

set_push() {
    # Make `git push` from branch $2 go to remote $3, branch $4.
    run git -C "$1" config "branch.$2.remote" "$3"
    run git -C "$1" config "branch.$2.merge" "refs/heads/$4"
}

make_worktree() {
    local name="$1" clone="$2" main_repo="$3" def_base="$4" fork_override="$5"
    local sub="$task/$name" up fork="" b="${base:-$def_base}" branch push="not set" where

    [ -n "$clone" ] && git -C "$clone" rev-parse --git-dir > /dev/null 2>&1 ||
        { echo "The $name clone '$clone' in $config is not a git repo."; exit 1; }
    [ ! -e "$sub" ] || { echo "$sub already exists."; exit 1; }
    if ! up=$(find_upstream "$clone" "$main_repo"); then
        echo "No remote in $clone points at github.com/$main_repo. Add it with:"
        echo "  git -C $clone remote add upstream https://github.com/$main_repo.git"
        exit 1
    fi
    fork=$(find_fork "$clone" "$fork_override") || fork=""

    case "$mode" in
    new)
        branch="$type/$slug"
        if git -C "$clone" show-ref --verify --quiet "refs/heads/$branch"; then
            echo "Branch $branch already exists in $clone (use --existing to work on it)."; exit 1
        fi
        echo "== $name: new branch $branch from $up/$b (github.com/$main_repo)"
        run git -C "$clone" fetch "$up" "+refs/heads/$b:refs/remotes/$up/$b"
        run git -C "$clone" worktree add --no-track -b "$branch" "$sub" "refs/remotes/$up/$b"
        if [ -n "$fork" ]; then
            set_push "$clone" "$branch" "$fork" "$branch"
            push="git push to $fork ($(git -C "$clone" remote get-url "$fork"))"
        fi
        start="from \`$up/$b\`"
        ;;
    pr)
        local info owner head state title mine=0
        info=$(pr_info "$main_repo") || info=""
        if [ -n "$info" ]; then
            read -r owner head state title <<< "$info"
            echo "== $name: PR #$pr ($state) \"$title\", from $owner:$head"
            [ "$state" = open ] || echo "Note: PR #$pr is $state."
            [ "$(echo "$owner" | tr 'A-Z' 'a-z')" = "$(echo "$GITHUB_USER" | tr 'A-Z' 'a-z')" ] && [ -n "$fork" ] && mine=1
        else
            echo "== $name: PR #$pr (couldn't get its details from GitHub; checking it out as pr/$pr)"
        fi
        if [ $mine -eq 1 ]; then
            # Your own PR: work on the same branch as your fork, so `git push`
            # updates the PR.
            branch="$head"
            where=$(checked_out_at "$clone" "$branch")
            [ -z "$where" ] || { echo "This is your PR, and its branch $branch is already checked out at $where. Work there."; exit 1; }
            run git -C "$clone" fetch "$fork" "+refs/heads/$branch:refs/remotes/$fork/$branch"
            if git -C "$clone" show-ref --verify --quiet "refs/heads/$branch"; then
                run git -C "$clone" worktree add "$sub" "$branch"
            else
                run git -C "$clone" worktree add --no-track -b "$branch" "$sub" "refs/remotes/$fork/$branch"
            fi
            set_push "$clone" "$branch" "$fork" "$branch"
            push="git push to $fork, which updates PR #$pr"
        else
            # Named pr/<owner>/<N> (pr/<N> if GitHub couldn't be asked).
            branch="pr/${owner:+$owner/}$pr"
            where=$(checked_out_at "$clone" "$branch")
            [ -z "$where" ] || { echo "Branch $branch is already checked out at $where. Work there."; exit 1; }
            run git -C "$clone" fetch "$up" "+refs/pull/$pr/head:refs/remotes/$up/pr/$pr"
            if git -C "$clone" show-ref --verify --quiet "refs/heads/$branch"; then
                # From an earlier checkout; keep it, it may have local commits.
                run git -C "$clone" worktree add "$sub" "$branch"
                if [ $dry -eq 0 ]; then
                    read -r ahead behind < <(git -C "$clone" rev-list --left-right --count "$branch...refs/remotes/$up/pr/$pr")
                    echo "Using your existing $branch: $ahead local commit(s), $behind newer commit(s) on the PR."
                    [ "$behind" -eq 0 ] || echo "  To get the PR's latest: git -C $sub merge --ff-only $up/pr/$pr (or reset, if you have no local work)"
                fi
            else
                run git -C "$clone" worktree add --no-track -b "$branch" "$sub" "refs/remotes/$up/pr/$pr"
            fi
            push="none: someone else's PR. To change it, suggest the change on the PR, or start your own branch"
        fi
        start="PR #$pr${title:+ ($title)}, https://github.com/$main_repo/pull/$pr"
        ;;
    existing)
        branch="$existing"
        [ -n "$fork" ] || { echo "No single remote for github.com/$GITHUB_USER/* in $clone; can't find your fork."; exit 1; }
        where=$(checked_out_at "$clone" "$branch")
        [ -z "$where" ] || { echo "Branch $branch is already checked out at $where. Work there."; exit 1; }
        echo "== $name: existing branch $branch from $fork"
        if ! run git -C "$clone" fetch "$fork" "+refs/heads/$branch:refs/remotes/$fork/$branch"; then
            echo "No branch $branch on $fork ($(git -C "$clone" remote get-url "$fork"))."; exit 1
        fi
        if git -C "$clone" show-ref --verify --quiet "refs/heads/$branch"; then
            # Keep the local branch as it is: it may have commits not pushed yet.
            run git -C "$clone" worktree add "$sub" "$branch"
            if [ $dry -eq 0 ]; then
                read -r ahead behind < <(git -C "$clone" rev-list --left-right --count "$branch...refs/remotes/$fork/$branch")
                echo "Using your local $branch: $ahead commit(s) not on $fork, $behind on $fork not here."
                [ "$behind" -eq 0 ] || echo "  To catch up: git -C $sub merge --ff-only $fork/$branch (or rebase)"
            fi
        else
            run git -C "$clone" worktree add --no-track -b "$branch" "$sub" "refs/remotes/$fork/$branch"
        fi
        set_push "$clone" "$branch" "$fork" "$branch"
        push="git push to $fork"
        start="existing branch on \`$fork\`"
        ;;
    esac

    if [ $dry -eq 0 ]; then
        note "- $name: \`$branch\`, $start, at \`$(git -C "$sub" rev-parse --short HEAD)\`"
    fi
    summary+=("$name  $sub  ($branch; push: $push)")
}

if [ "$mode" = adopt ]; then
    # Which repo is it? Decided by its remotes, as everywhere else.
    name=""
    for r in $(git -C "$adopt" remote); do
        case "$(normalize "$(git -C "$adopt" remote get-url "$r")")" in
            github.com/gem5/gem5) name=gem5 ;;
            github.com/gem5/gem5-resources) name=gem5-resources ;;
        esac
    done
    [ -n "$name" ] || { echo "$adopt has no remote for github.com/gem5/gem5 or gem5-resources."; exit 1; }
    [ ! -e "$task/$name" ] || { echo "$task/$name already exists."; exit 1; }
    b=$(git -C "$adopt" rev-parse --abbrev-ref HEAD)
    up=$(git -C "$adopt" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || echo "no upstream set")
    dirty=$(git -C "$adopt" status --porcelain | wc -l)
    echo "== $name: adopting $adopt (branch $b, tracking $up, $dirty uncommitted/untracked files)"
    run mkdir -p "$task/runs"
    run ln -s "$adopt" "$task/$name"
    if [ $dry -eq 0 ]; then
        [ -f "$task/notes.md" ] || printf '# %s\n\nCreated %s.\n\n## Branches\n\n' "$slug" "$(date +%F)" > "$task/notes.md"
        printf -- '- %s: `%s` (tracking `%s`), existing worktree %s, at `%s`\n' \
            "$name" "$b" "$up" "$adopt" "$(git -C "$adopt" rev-parse --short HEAD)" >> "$task/notes.md"
    fi
    echo
    echo "Task folder: $task"
    echo "  $name -> $adopt (left as it is)"
    echo "Nothing was pushed."
    exit 0
fi

summary=()
[ $dry -eq 1 ] && echo "Dry run: nothing will be changed."
case "$repo" in
    gem5|both) make_worktree gem5 "${GEM5_CLONE:-}" gem5/gem5 "${GEM5_BASE:-develop}" "${GEM5_FORK_REMOTE:-}" ;;
esac
case "$repo" in
    resources|both) make_worktree gem5-resources "${RESOURCES_CLONE:-}" gem5/gem5-resources "${RESOURCES_BASE:-stable}" "${RESOURCES_FORK_REMOTE:-}" ;;
esac

echo
echo "Task folder: $task"
for s in "${summary[@]}"; do echo "  $s"; done
echo "Nothing was pushed."
