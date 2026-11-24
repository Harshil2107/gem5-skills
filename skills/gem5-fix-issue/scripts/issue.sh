#!/bin/bash
# Show a GitHub issue: title, state, labels, the report, every comment, and
# the pull requests that mention or close it. Read-only.
# Usage: issue.sh NUMBER [--repo gem5/gem5]
# Set GITHUB_TOKEN to raise GitHub's rate limit (60 requests an hour without).

set -euo pipefail
num="" repo=gem5/gem5
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) repo="$2"; shift 2 ;;
        *) num="${1#\#}"; shift ;;
    esac
done
[[ "$num" =~ ^[0-9]+$ ]] || { sed -n '4,5p' "$0"; exit 2; }

auth=()
[ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
get() {
    curl -sf "${auth[@]}" -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/$repo/$1" > "$tmp/$2" ||
        { echo "GitHub request failed for $1 (rate limit, or no such issue)."; exit 1; }
}
get "issues/$num" issue.json
get "issues/$num/comments?per_page=100" comments.json
get "issues/$num/timeline?per_page=100" timeline.json

show=$(cat <<'PY'
import json, sys
tmp = sys.argv[1]
load = lambda n: json.load(open(f"{tmp}/{n}"))
i = load("issue.json")
if "pull_request" in i:
    print(f"#{i['number']} is a pull request; use gem5-pr's pr-comments.sh for it.")
labels = ", ".join(l["name"] for l in i.get("labels", [])) or "none"
print(f"#{i['number']} {i['title']}")
print(f"{i['state']}{' (' + i['state_reason'] + ')' if i.get('state_reason') else ''}, "
      f"opened {i['created_at'][:10]} by {i['user']['login']}, labels: {labels}, "
      f"{i['comments']} comments")
print(i["html_url"])
print("\n--- report")
for l in (i.get("body") or "(empty)").strip().splitlines():
    print(f"    {l}")

for c in load("comments.json"):
    print(f"\n--- {c['created_at'][:16].replace('T', ' ')}  {c['user']['login']}")
    for l in (c["body"] or "").strip().splitlines():
        print(f"    {l}")

prs = {}
for e in load("timeline.json"):
    src = (e.get("source") or {}).get("issue") or {}
    if e.get("event") == "cross-referenced" and "pull_request" in src:
        merged = (src["pull_request"] or {}).get("merged_at")
        prs[src["number"]] = (("merged" if merged else src["state"]), src["title"], src["html_url"])
    if e.get("event") == "closed" and e.get("commit_id"):
        prs.setdefault("commit " + e["commit_id"][:10], ("closed it", "", ""))
print("\n--- linked pull requests")
if not prs:
    print("    none")
for n, (state, title, url) in prs.items():
    print(f"    #{n} {state}: {title} {url}".rstrip())
PY
)
python3 -I -c "$show" "$tmp"
