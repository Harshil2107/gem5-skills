#!/bin/bash
# Check a gem5 or gem5-resources branch before it goes up as a pull request:
# commits on top of the main repo's base branch, commit message style, files
# that shouldn't be in a PR, debug leftovers, whitespace, and (optionally)
# gem5's pre-commit style checks. Changes nothing except with --pre-commit
# (whose hooks may reformat files; those changes are left for you to review).
# Usage: check-branch.sh [DIR] [--base BRANCH] [--pre-commit]
#   DIR   the worktree (default: current dir, or gem5/ in the task folder)

set -uo pipefail
dir="" base="" precommit=0
while [ $# -gt 0 ]; do
    case "$1" in
        --base) base="$2"; shift 2 ;;
        --pre-commit) precommit=1; shift ;;
        *) dir="$1"; shift ;;
    esac
done
config=${GEM5_SKILLS_CONFIG:-$HOME/.config/gem5-skills/config}
# shellcheck source=/dev/null
[ -f "$config" ] && source "$config"

if [ -z "$dir" ]; then
    if git rev-parse --git-dir > /dev/null 2>&1; then dir=.
    else
        d=$PWD; while [ "$d" != / ] && [ ! -f "$d/notes.md" ]; do d=$(dirname "$d"); done
        dir="$d/gem5"
    fi
fi
cd "$dir" 2>/dev/null && git rev-parse --git-dir > /dev/null 2>&1 || { echo "$dir is not a git worktree."; exit 2; }
top=$(git rev-parse --show-toplevel); cd "$top"

normalize() {
    echo "$1" | tr 'A-Z' 'a-z' |
        sed -E 's#^(https?://|ssh://)?(git@)?##; s#^github\.com:#github.com/#; s#/+$##; s#\.git$##'
}
main="" up=""
for r in $(git remote); do
    case "$(normalize "$(git remote get-url "$r")")" in
        github.com/gem5/gem5) main=gem5/gem5; up=$r ;;
        github.com/gem5/gem5-resources) main=gem5/gem5-resources; up=$r ;;
    esac
done
[ -n "$up" ] || { echo "No remote points at github.com/gem5/gem5 or gem5-resources."; exit 2; }
if [ -z "$base" ]; then
    [ $main = gem5/gem5 ] && base=${GEM5_BASE:-develop} || base=${RESOURCES_BASE:-stable}
fi

problems=0
flag() { echo "  ! $*"; problems=$((problems + 1)); }

git fetch -q "$up" "+refs/heads/$base:refs/remotes/$up/$base" 2>/dev/null ||
    echo "(couldn't fetch $up/$base; using the local copy)"
ref="$up/$base"
mb=$(git merge-base "$ref" HEAD) || { echo "No common history with $ref."; exit 2; }
branch=$(git rev-parse --abbrev-ref HEAD)
mapfile -t commits < <(git rev-list --reverse "$mb..HEAD")
behind=$(git rev-list --count "HEAD..$ref")

echo "== $main: $branch, ${#commits[@]} commit(s) on top of $ref"
# Already upstream? (a) a commit on the base with the same subject, as
# GitHub's squash merge leaves it ("subject (#1234)"); (b) the branch's whole
# change already applies in reverse on the base.
merged=0
for c in "${commits[@]}"; do
    subj=$(git log -1 --format=%s "$c")
    hit=$(git log --format='%h %s' "$mb..$ref" | grep -F -- "$subj" | head -1)
    if [ -n "$hit" ]; then
        echo "  $(git log -1 --format=%h "$c") is upstream as: $hit"
        merged=$((merged + 1))
    fi
done
idx=$(mktemp)
GIT_INDEX_FILE=$idx git read-tree "$ref"
if [ ${#commits[@]} -gt 0 ] && git diff "$mb" HEAD | GIT_INDEX_FILE=$idx git apply --cached --check -R - 2> /dev/null; then
    echo "  All of this branch's changes are already in $ref."
    merged=${#commits[@]}
fi
rm -f "$idx"
if [ ${#commits[@]} -gt 0 ] && [ $merged -ge ${#commits[@]} ]; then
    echo "  This branch looks merged already; nothing to open a PR for."
    exit 0
elif [ $merged -gt 0 ]; then
    echo "  Some commits are upstream. A squash merge folds all of a PR's commits into"
    echo "  one, so the others may be in it too: compare the code before opening a PR."
fi
if [ "$behind" -gt 0 ]; then
    overlap=$(comm -12 <(git diff --name-only "$mb" "$ref" | sort) <(git diff --name-only "$mb" HEAD | sort))
    if [ -n "$overlap" ]; then
        flag "$ref has $behind newer commit(s), and some change the same files; rebase and retest:"
        echo "$overlap" | sed 's/^/      /'
    else
        echo "  $ref has $behind newer commit(s), none touching this branch's files (rebase optional)."
    fi
fi
[ ${#commits[@]} -gt 0 ] || { echo "  No commits yet."; }
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    echo "  Note: uncommitted changes (not in the PR unless committed):"
    git status --short --untracked-files=no | sed 's/^/      /'
fi

echo "== Commit messages"
msgfile=$(mktemp); trap 'rm -f "$msgfile"' EXIT
for c in "${commits[@]}"; do
    git log -1 --format=%B "$c" > "$msgfile"
    subj=$(head -1 "$msgfile")
    echo "  $(git log -1 --format=%h "$c") $subj"
    if [ $main = gem5/gem5 ] && [ -f util/git-commit-msg.py ]; then
        out=$(python3 util/git-commit-msg.py "$msgfile" 2>&1) ||
            flag "$(echo "$out" | grep -m1 -E 'Invalid|too long|empty line' || echo "fails util/git-commit-msg.py")"
    else
        [[ "$subj" =~ ^[a-z0-9,-]+:\ .+[^\ ]$ ]] || flag "header should be 'tag: Title'"
        [ ${#subj} -le 65 ] || flag "header is ${#subj} characters (max 65)"
        [ "$(sed -n 2p "$msgfile")" = "" ] || flag "no blank line after the header"
    fi
    [ "$(sed -n '3,$p' "$msgfile" | grep -cv '^\s*$')" -gt 0 ] || echo "      (no description; recommended)"
    long=$(sed -n '3,$p' "$msgfile" | grep -vE '^\s*(https?://|[A-Za-z-]+: )' | awk 'length > 72' | wc -l)
    [ "$long" -eq 0 ] || echo "      ($long body line(s) over 72 characters)"
done

echo "== Files changed"
git diff --stat "$mb..HEAD" | tail -1 | sed 's/^/  /'
while read -r f; do
    [ -n "$f" ] || continue
    case "$f" in
        .vscode/*|*.log|m5out/*|build/*|*.img|*.qcow2|*.o|*.pyc|*/__pycache__/*|*.orig|*.rej|*~)
            flag "$f looks like a local file, not part of the change" ;;
    esac
    size=$(git cat-file -s "HEAD:$f" 2>/dev/null || echo 0)
    [ "$size" -gt 1048576 ] && flag "$f is $((size / 1048576)) MB"
done < <(git diff --name-only --diff-filter=AM "$mb..HEAD")

echo "== Debug leftovers in added lines"
left=$(git diff -U0 "$mb..HEAD" -- ':!*.md' ':!*.txt' |
    grep -nE '^\+.*(\bwarn\(|\bprintf\(|std::(cout|cerr)|DPRINTF\(Temp|\bXXX\b|\bHACK\b|FIXME|\bTODO\b|print\(.*debug)' |
    grep -v '^+++' | head -20)
if [ -n "$left" ]; then
    echo "$left" | sed 's/^/  ? /' | cut -c1-160
    echo "  (? = check these are meant to stay; temporary diagnostics must go before upstreaming)"
else
    echo "  none found"
fi

echo "== Whitespace"
ws=$(git diff --check "$mb..HEAD" 2>&1 | head -10)
[ -z "$ws" ] && echo "  ok" || { echo "$ws" | sed 's/^/  /'; flag "whitespace errors"; }

if [ $precommit -eq 1 ]; then
    echo "== pre-commit"
    if ! command -v pre-commit > /dev/null || [ ! -f .pre-commit-config.yaml ]; then
        echo "  pre-commit or .pre-commit-config.yaml not available; skipped"
    elif [ -n "$(git status --porcelain --untracked-files=no)" ]; then
        flag "pre-commit skipped: commit or stash your changes first, so its fixes are easy to review"
    else
        if pre-commit run --from-ref "$mb" --to-ref HEAD > "$msgfile.pc" 2>&1; then
            echo "  all checks passed"
        else
            grep -E 'Failed|- files were modified' "$msgfile.pc" | sed 's/^/  /' | head -15
            flag "pre-commit checks failed"
            changed=$(git status --short --untracked-files=no)
            [ -n "$changed" ] && echo "  pre-commit changed these files (not committed):" && echo "$changed" | sed 's/^/      /'
        fi
        rm -f "$msgfile.pc"
    fi
fi

t=$(d=$PWD; while [ "$d" != / ] && [ ! -f "$d/notes.md" ]; do d=$(dirname "$d"); done; echo "$d")
echo "== Testing bar"
if [ -f "$t/notes.md" ] && grep -q '^## Testing bar' "$t/notes.md"; then
    sed -n '/^## Testing bar/,/^## /p' "$t/notes.md" | sed '1d;/^## /d;s/^/  /'
else
    echo "  Not set. Agree it with the user and add a '## Testing bar' section to notes.md."
fi

echo
[ $problems -eq 0 ] && echo "No problems found." || echo "$problems problem(s) to look at."
