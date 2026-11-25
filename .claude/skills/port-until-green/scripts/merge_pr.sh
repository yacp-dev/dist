#!/usr/bin/env bash
# Merge a yacp-dev/ports PR via rebase & merge, delete the remote branch,
# fast-forward the local ports clone ($PORTS_DIR) to origin/master,
# verify that the commit at HEAD matches the local branch, and delete the local branch.
#
# Usage:
#   merge_pr.sh <pr-number | pr-url | pkg-ver | branch>
#   merge_pr.sh --package <pkg> [--version <ver>]
#
# Examples:
#   merge_pr.sh 1346
#   merge_pr.sh https://github.com/yacp-dev/ports/pull/1346
#   merge_pr.sh armadillo-15.8.0
#   merge_pr.sh dorgann/armadillo-15.8.0
#   merge_pr.sh --package armadillo --version 15.8.0

set -euo pipefail

target_script="$0"
while [[ -L "$target_script" ]]; do
  dir="$(cd "$(dirname "$target_script")" && pwd)"
  target_script="$(readlink "$target_script")"
  [[ "$target_script" != /* ]] && target_script="$dir/$target_script"
done
here="$(cd "$(dirname "$target_script")" && pwd)"
ports="$("$here/ports_dir.sh")"

target=""
pkg=""
ver=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --package) pkg="$2"; shift 2 ;;
    --version) ver="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^set/ { /^set/!p; }' "$target_script" | sed 's/^#[[:space:]]*//'
      exit 0
      ;;
    *)
      if [[ -z "$target" ]]; then
        target="$1"
        shift
      else
        echo "Unexpected argument: $1" >&2
        exit 1
      fi
      ;;
  esac
done

pr_number=""
branch=""

if [[ -n "$pkg" ]]; then
  if [[ -n "$ver" ]]; then
    target="dorgann/$pkg-$ver"
  else
    target="$pkg"
  fi
fi

if [[ -z "$target" ]]; then
  # Try to detect branch if current directory is ports
  current_git="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ "$current_git" == "$ports" ]]; then
    cur="$(git branch --show-current)"
    if [[ "$cur" =~ ^dorgann/ ]]; then
      target="$cur"
    fi
  fi
fi

if [[ -z "$target" ]]; then
  echo "Error: target PR number, URL, branch, or package must be specified." >&2
  echo "Usage: merge_pr.sh <pr-number | pr-url | pkg-ver | branch>" >&2
  exit 1
fi

# 1. Resolve PR number and branch name
if [[ "$target" =~ ^[0-9]+$ ]]; then
  pr_number="$target"
elif [[ "$target" =~ /pull/([0-9]+) ]]; then
  pr_number="${BASH_REMATCH[1]}"
elif [[ "$target" =~ ^dorgann/ ]]; then
  branch="$target"
elif [[ "$target" =~ -[0-9] ]]; then
  branch="dorgann/$target"
else
  # Treat as package name, find open PR
  json="$(gh pr list --repo yacp-dev/ports --state open --search "head:dorgann/$target" --json number,headRefName,title --limit 1)"
  count="$(echo "$json" | python3 -c "import sys, json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)"
  if [[ "$count" -eq 1 ]]; then
    pr_number="$(echo "$json" | python3 -c "import sys, json; print(json.load(sys.stdin)[0]['number'])")"
    branch="$(echo "$json" | python3 -c "import sys, json; print(json.load(sys.stdin)[0]['headRefName'])")"
  else
    echo "Error: Could not uniquely resolve open PR for package '$target'. Found $count PR(s)." >&2
    exit 1
  fi
fi

if [[ -z "$pr_number" && -n "$branch" ]]; then
  json="$(gh pr list --repo yacp-dev/ports --state open --head "$branch" --json number,title --limit 1)"
  count="$(echo "$json" | python3 -c "import sys, json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)"
  if [[ "$count" -eq 1 ]]; then
    pr_number="$(echo "$json" | python3 -c "import sys, json; print(json.load(sys.stdin)[0]['number'])")"
  else
    # Check if already merged
    json_merged="$(gh pr list --repo yacp-dev/ports --state merged --head "$branch" --json number,title --limit 1)"
    merged_count="$(echo "$json_merged" | python3 -c "import sys, json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)"
    if [[ "$merged_count" -eq 1 ]]; then
      pr_number="$(echo "$json_merged" | python3 -c "import sys, json; print(json.load(sys.stdin)[0]['number'])")"
    else
      echo "Error: No open PR found for branch '$branch'." >&2
      exit 1
    fi
  fi
fi

# Fetch PR details
pr_json="$(gh pr view "$pr_number" --repo yacp-dev/ports --json number,title,state,headRefName,baseRefName,mergeable,url)"
pr_state="$(echo "$pr_json" | python3 -c "import sys, json; print(json.load(sys.stdin).get('state', ''))")"
pr_title="$(echo "$pr_json" | python3 -c "import sys, json; print(json.load(sys.stdin).get('title', ''))")"
pr_url="$(echo "$pr_json" | python3 -c "import sys, json; print(json.load(sys.stdin).get('url', ''))")"
branch="$(echo "$pr_json" | python3 -c "import sys, json; print(json.load(sys.stdin).get('headRefName', ''))")"
mergeable="$(echo "$pr_json" | python3 -c "import sys, json; print(json.load(sys.stdin).get('mergeable', ''))")"

echo "Target PR: #$pr_number ($pr_title)"
echo "Branch: $branch"
echo "Status: $pr_state"
echo "URL: $pr_url"

# 2. Check mergeability and perform Rebase & Merge
if [[ "$pr_state" == "OPEN" ]]; then
  if [[ "$mergeable" == "CONFLICTING" ]]; then
    echo "Error: PR #$pr_number has merge conflicts and cannot be merged." >&2
    exit 1
  fi

  echo "==> Merging PR #$pr_number via rebase and deleting remote branch..."
  gh pr merge "$pr_number" --repo yacp-dev/ports --rebase --delete-branch
  echo "PR #$pr_number successfully merged."
elif [[ "$pr_state" == "MERGED" ]]; then
  echo "PR #$pr_number is already merged. Proceeding to local pull and branch cleanup."
else
  echo "Error: PR #$pr_number is $pr_state (not merged or open)." >&2
  exit 1
fi

# 3. Pull ~/src/ports master
echo "==> Updating local repository at $ports..."
current_branch="$(git -C "$ports" branch --show-current)"
git_status="$(git -C "$ports" status --porcelain)"

if [[ "$current_branch" != "master" ]]; then
  if [[ -n "$git_status" ]]; then
    echo "Error: $ports is on branch '$current_branch' with uncommitted changes. Stash or commit before merging." >&2
    exit 1
  fi
  echo "Switching $ports to master branch..."
  git -C "$ports" checkout master
else
  if [[ -n "$git_status" ]]; then
    echo "Error: $ports has uncommitted changes on master. Stash or commit before merging." >&2
    exit 1
  fi
fi

echo "Fetching and fast-forwarding master..."
# No `git pull`: it merges FETCH_HEAD, which a concurrent session's fetch into
# this shared clone can fill with several branches ("Cannot fast-forward to
# multiple branches"). Fetch without touching FETCH_HEAD, then fast-forward to
# the remote-tracking ref.
git -C "$ports" fetch --no-write-fetch-head --prune origin
git -C "$ports" merge --ff-only refs/remotes/origin/master

# 4. Remove associated worktree if exists
wt="$(git -C "$ports" worktree list --porcelain | awk -v b="branch refs/heads/$branch" '/^worktree /{w=substr($0, 10)} $0 == b {print w}')"
if [[ -n "$wt" ]]; then
  echo "==> Removing worktree for $branch at $wt..."
  git -C "$ports" worktree remove "$wt" 2>/dev/null || {
    rm -rf "$wt"
    git -C "$ports" worktree prune
  }
fi

# 5. Check differences between HEAD and local branch, then delete local branch
if git -C "$ports" show-ref --verify --quiet "refs/heads/$branch"; then
  echo "==> Verifying differences between HEAD and local branch '$branch'..."

  # Complete tree diff
  diff_all="$(git -C "$ports" diff HEAD "$branch")"

  # Specific files modified in the branch
  branch_files="$(git -C "$ports" diff-tree --no-commit-id --name-only -r "$branch" 2>/dev/null || true)"
  diff_files=""
  if [[ -n "$branch_files" ]]; then
    diff_files="$(git -C "$ports" diff HEAD "$branch" -- $branch_files)"
  fi

  if [[ -z "$diff_all" ]]; then
    echo "Confirmation passed: HEAD and $branch are completely identical."
  elif [[ -z "$diff_files" ]]; then
    echo "Confirmation passed: All files modified in $branch match HEAD (master has additional CI/subsequent commits)."
  else
    # Check if differences are solely patch timestamp headers (--- / +++) regenerated by CI cygport diff
    diff_substantive="$(git -C "$ports" diff -I '^--- ' -I '^\+\+\+ ' HEAD "$branch" -- $branch_files)"
    if [[ -z "$diff_substantive" ]]; then
      echo "Confirmation passed: All recipe changes and patch contents in $branch match HEAD (ignoring CI-regenerated patch header timestamps)."
    else
      echo "Error: Found substantive diff between HEAD and $branch on modified files:" >&2
      echo "$diff_substantive" >&2
      echo "Local branch '$branch' will NOT be deleted." >&2
      exit 1
    fi
  fi

  git -C "$ports" branch -D "$branch"
  echo "==> Successfully deleted local branch '$branch'."
else
  echo "Local branch '$branch' does not exist."
fi

echo "All done! Master is at $(git -C "$ports" rev-parse --short HEAD)."
