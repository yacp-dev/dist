#!/usr/bin/env bash
# This session's worktree of dorgann/<pkg>-<ver>,
# <session scratchpad>/worktrees/<pkg>-<ver> (see worktree_root.sh),
# brought up to date with origin. The ports clone itself (ports_dir.sh)
# is shared by other sessions, so nothing is checked out there. A branch
# can be checked out in one worktree only: if another session's worktree
# still has it, this refuses and names it (one whose folder is gone is
# pruned first).
#
# The bot squashes and force-pushes the branch at the end of every run,
# so an existing worktree is reset to origin/<branch> -- but only when
# that loses nothing: no uncommitted changes, and no commit that was
# never pushed (a pushed one is in origin/<branch>'s reflog even after
# the squash). Otherwise it refuses and lists what would be lost.
#
# Usage:
#   worktree.sh --package knot --version 3.6.2            # create or refresh
#   worktree.sh --package knot --version 3.6.2 --remove   # once all is pushed
# Output: the worktree's path (stdout); exit 1 with the reason on stderr
# when it refuses.

set -euo pipefail

ports="$("$(dirname "$0")/ports_dir.sh")"
pkg="" ver="" remove=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --package) pkg="$2"; shift 2 ;;
    --version) ver="$2"; shift 2 ;;
    --remove) remove=1; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done
[[ -n "$pkg" && -n "$ver" ]] || { echo "--package and --version are required" >&2; exit 1; }

branch="dorgann/$pkg-$ver"
worktrees="$("$(dirname "$0")/worktree_root.sh")"
wt="$worktrees/$pkg-$ver"

git -C "$ports" fetch -q origin "$branch" 2>/dev/null || {
  echo "$branch is not on origin" >&2; exit 1; }

if [[ ! -d "$wt" ]]; then
  (( remove )) && { echo "no worktree at $wt" >&2; exit 0; }
  git -C "$ports" worktree prune
  other="$(git -C "$ports" worktree list --porcelain |
    awk -v b="branch refs/heads/$branch" '/^worktree /{w=substr($0, 10)} $0 == b {print w}')"
  if [[ -n "$other" ]]; then
    echo "$branch is checked out in $other (another session's worktree?); finish or remove it there first" >&2
    exit 1
  fi
  mkdir -p "$worktrees"
  git -C "$ports" worktree add -q -B "$branch" "$wt" "origin/$branch"
  echo "$wt"
  exit 0
fi

dirty="$(git -C "$wt" status --porcelain)"
# shellcheck disable=SC2046
unpushed="$(git -C "$wt" log --oneline HEAD --not $(git -C "$wt" reflog --format=%H "origin/$branch"))"
if [[ -n "$dirty" || -n "$unpushed" ]]; then
  {
    echo "$wt has work that isn't on origin; push or drop it first:"
    [[ -n "$dirty" ]] && printf 'uncommitted:\n%s\n' "$dirty"
    [[ -n "$unpushed" ]] && printf 'not pushed:\n%s\n' "$unpushed"
  } >&2
  exit 1
fi

if (( remove )); then
  git -C "$ports" worktree remove "$wt"
  echo "removed $wt"
  exit 0
fi

git -C "$wt" reset -q --hard "origin/$branch"
echo "$wt"
