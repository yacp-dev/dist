#!/usr/bin/env bash
# Step 1's look at what already exists for <pkg>-<ver>, and what to do
# with it: the dorgann/<pkg>-<ver> branch (and other dorgann/<pkg>-*
# branches), its PR, the newest build-package run of that target (runs
# are titled "build-package <target>"; a <pkg>-<ver>-<rel> gcc-rebuild
# target counts too), and commits that aren't on origin in the worktree
# on this machine that has the branch checked out (any session's).
#
# A green run is reused only when it built the branch as it stands: the
# head is the bot's commit (it force-pushes the branch at the end of every
# run) and not newer than the run's end, and no local-only commits wait.
#
# Usage:
#   branch_state.sh --package knot --version 3.6.2
# Output: one "key: value" line each for branch, other-branches, pr, run,
# local, then the last line, one of:
#   verdict: new-branch                no branch: Step 1b, then dispatch
#   verdict: wait <id>                 a run is queued or in progress
#   verdict: reuse <id>                green and built the current head:
#                                      Step 2's Success checks, no build
#   verdict: investigate <id>          red and built the current head: Step 3
#   verdict: build <reason>            Step 2's run_decision.sh
#   verdict: push <reason>             local-only commits: push them first

set -euo pipefail

dist="yacp-dev/dist"
ports="yacp-dev/ports"
pkg="" ver=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --package) pkg="$2"; shift 2 ;;
    --version) ver="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done
[[ -n "$pkg" && -n "$ver" ]] || { echo "--package and --version are required" >&2; exit 1; }

branch="dorgann/$pkg-$ver"
target="$pkg-$ver"
# Whichever session's worktree has the branch checked out.
wt="$(git -C "${PORTS_DIR:-.}" worktree list --porcelain 2>/dev/null |
  awk -v b="branch refs/heads/$branch" '/^worktree /{w=substr($0, 10)} $0 == b {print w}')"

others="$(gh api "repos/$ports/branches?per_page=100" --paginate --jq '.[].name' |
  grep -F "dorgann/$pkg-" | grep -vxF "$branch" | tr '\n' ' ' || true)"

head=""
if head="$(gh api "repos/$ports/commits/$branch" --jq '.commit.committer.date + " " + (.author.login // "?") + " " + .sha' 2>/dev/null)"; then
  read -r head_date head_login head_sha <<<"$head"
  echo "branch: $branch (head ${head_sha:0:10} by $head_login at $head_date)"
else
  head=""   # gh api prints the 404's JSON on stdout
  echo "branch: none"
fi
echo "other-branches: ${others:-none}"

if [[ -z "$head" ]]; then
  echo "pr: none"
  echo "run: n/a"
  echo "local: n/a"
  echo "verdict: new-branch"
  exit 0
fi

pr="$(gh pr list -R "$ports" --head "$branch" --state open --json url,isDraft \
  --jq '.[0] | select(.) | .url + (if .isDraft then " DRAFT" else " ready" end)')"
echo "pr: ${pr:-none}"

# Newest first; gh's --jq takes no --arg, so the title is matched in awk.
run="$(gh run list -R "$dist" --workflow build-package.yml --limit 100 \
  --json databaseId,displayTitle,status,conclusion,updatedAt,url \
  --jq '.[] | "\(.databaseId)\t\(.displayTitle)\t\(.status) \(.conclusion // "-") \(.updatedAt) \(.url)"' |
  awk -F'\t' -v t="build-package $target" '
    $2 == t || (index($2, t "-") == 1 && substr($2, length(t) + 2) ~ /^[0-9]+bl[0-9]+$/) { print $1 " " $3; exit }')"

# The bot squashes the branch on every run, so a pushed commit is no
# longer on origin/<branch> -- but it is in that ref's reflog, which a
# push records. Local-only = in HEAD, reachable from no value the ref
# has had.
local_n=0
if [[ -d "$wt" ]]; then
  git -C "$wt" fetch -q origin "$branch" 2>/dev/null || true
  # shellcheck disable=SC2046
  local_n="$(git -C "$wt" rev-list --count HEAD --not $(git -C "$wt" reflog --format=%H "origin/$branch" 2>/dev/null) 2>/dev/null || echo 0)"
  echo "local: $local_n commit(s) in $wt not on origin"
else
  echo "local: no worktree"
fi

if [[ -z "$run" ]]; then
  echo "run: none"
  if (( local_n > 0 )); then echo "verdict: push $local_n local-only commit(s), then build"; exit 0; fi
  echo "verdict: build no run of $target found"
  exit 0
fi
read -r run_id run_status run_conclusion run_end run_url <<<"$run"
echo "run: $run_id $run_status $run_conclusion (updated $run_end) $run_url"

if [[ "$run_status" != completed ]]; then
  echo "verdict: wait $run_id"; exit 0
fi
if (( local_n > 0 )); then
  echo "verdict: push $local_n local-only commit(s) in $wt, then build"; exit 0
fi
# ISO 8601 UTC timestamps compare as strings.
if [[ "$head_login" != *"[bot]" || "$head_date" > "$run_end" ]]; then
  echo "verdict: build the head (${head_sha:0:10}, $head_login, $head_date) is newer than run $run_id"; exit 0
fi
if [[ "$run_conclusion" == success ]]; then
  echo "verdict: reuse $run_id"
else
  echo "verdict: investigate $run_id"
fi
