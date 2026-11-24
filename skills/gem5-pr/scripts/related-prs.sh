#!/bin/bash
# Search gem5's GitHub repo for pull requests and issues that may overlap
# with a change, before writing or upstreaming a fix. Read-only.
# Usage: related-prs.sh [--repo gem5/gem5|gem5/gem5-resources] [--prs|--issues] TERM...
#   Terms are combined (all must match), e.g. vslidedown, "fault-only-first",
#   a file name like pagetable_walker.cc, or a function name.
# Set GITHUB_TOKEN to raise GitHub's rate limit (60 searches an hour without).

set -euo pipefail
repo=gem5/gem5 kind=""
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) repo="$2"; shift 2 ;;
        --prs) kind="is:pr"; shift ;;
        --issues) kind="is:issue"; shift ;;
        *) break ;;
    esac
done
[ $# -gt 0 ] || { sed -n '4,7p' "$0"; exit 2; }

query="repo:$repo $kind $*"
auth=()
[ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")

out=$(curl -sfG "https://api.github.com/search/issues" "${auth[@]}" \
    -H "Accept: application/vnd.github+json" \
    --data-urlencode "q=$query" --data-urlencode "per_page=30" \
    --data-urlencode "sort=updated") ||
    { echo "GitHub search failed (rate limit? try again later or set GITHUB_TOKEN)."; exit 1; }

show=$(cat <<'PY'
import json, os, sys
d = json.load(sys.stdin)
print(f"{d.get('total_count', 0)} results for: {os.environ['QUERY']}")
for i in d.get("items", []):
    kind = "PR   " if "pull_request" in i else "issue"
    merged = (i.get("pull_request") or {}).get("merged_at")
    state = "merged" if merged else i["state"]
    print(f"{kind} #{i['number']:<5} {state:<6} {i['updated_at'][:10]}  {i['title'][:80]}")
    print(f"      {i['html_url']}")
PY
)
QUERY="$query" python3 -I -c "$show" <<< "$out"
