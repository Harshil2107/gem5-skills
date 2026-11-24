#!/bin/bash
# Show a pull request and every comment on it in time order: general
# comments, review summaries, and inline code comments with the code they
# point at. Read-only; for drafting replies.
# Usage: pr-comments.sh NUMBER [--repo gem5/gem5] [--since YYYY-MM-DD] [--no-bots]
# Set GITHUB_TOKEN to raise GitHub's rate limit (60 requests an hour without).

set -euo pipefail
num="" repo=gem5/gem5 since="" nobots=0
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) repo="$2"; shift 2 ;;
        --since) since="$2"; shift 2 ;;
        --no-bots) nobots=1; shift ;;
        *) num="${1#\#}"; shift ;;
    esac
done
[[ "$num" =~ ^[0-9]+$ ]] || { sed -n '5,6p' "$0"; exit 2; }

auth=()
[ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
get() {
    curl -sf "${auth[@]}" -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/$repo/$1" > "$tmp/$2" ||
        { echo "GitHub request failed for $1 (rate limit, or no such PR)."; exit 1; }
}
get "pulls/$num" pr.json
get "issues/$num/comments?per_page=100" issue.json
get "pulls/$num/reviews?per_page=100" reviews.json
get "pulls/$num/comments?per_page=100" inline.json

python3 -I - "$tmp" "$since" "$nobots" <<'EOF'
import json, sys
tmp, since, nobots = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
load = lambda n: json.load(open(f"{tmp}/{n}"))
pr = load("pr.json")
state = "merged" if pr.get("merged_at") else pr["state"]
print(f"#{pr['number']} {pr['title']}")
print(f"{state}, by {pr['user']['login']}, {pr['head']['label']} -> {pr['base']['ref']}, "
      f"{pr['commits']} commits, updated {pr['updated_at'][:10]}")
print(pr["html_url"])

events = []
for c in load("issue.json"):
    events.append((c["created_at"], c["user"]["login"], "comment", "", c["body"] or "", c["html_url"]))
for r in load("reviews.json"):
    if r.get("body") or r["state"] in ("APPROVED", "CHANGES_REQUESTED"):
        events.append((r.get("submitted_at") or "", r["user"]["login"],
                       f"review: {r['state'].lower()}", "", r.get("body") or "", r["html_url"]))
for c in load("inline.json"):
    where = f"{c['path']}:{c.get('line') or c.get('original_line') or '?'}"
    hunk = "\n".join((c.get("diff_hunk") or "").splitlines()[-4:])
    reply = " (reply)" if c.get("in_reply_to_id") else ""
    events.append((c["created_at"], c["user"]["login"], f"inline{reply} {where}", hunk,
                   c["body"] or "", c["html_url"]))

for when, who, kind, hunk, body, url in sorted(events):
    if since and when[:10] < since:
        continue
    if nobots and who.endswith("[bot]"):
        continue
    print(f"\n--- {when[:16].replace('T', ' ')}  {who}  [{kind}]")
    print(f"    {url}")
    if hunk:
        print("    code:")
        for l in hunk.splitlines():
            print(f"      {l}")
    for l in body.strip().splitlines():
        print(f"    {l}")
EOF
