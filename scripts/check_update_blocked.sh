#!/usr/bin/env bash
# Refuses a package update while an open `update-blocked` Issue
# (doc/spec.md 4.7) names the package -- e.g. libgovirt, whose every
# release after 0.3.8 needs a librest no Cygwin package provides. Without
# this, each dispatch would rediscover the same blocker the slow way: a
# windows-latest build, a draft PR and a build-failed Issue, all for
# something a human already decided isn't buildable yet.
#
# The Issue is matched the same way as build-failed ones (by the package
# field in its dorgann-meta comment, via find_failure_issue.sh), so the
# body only needs `<!-- dorgann-meta: {"package":"foo"} -->`; closing the
# Issue is what unblocks the package.
#
# Usage: check_update_blocked.sh --repo yacp-dev/dist --package foo
# Output: if blocked, prints the Issue URL, appends `blocked=true` and
# `issue_url=<url>` to GITHUB_OUTPUT and a note to GITHUB_STEP_SUMMARY
# (when set); prints nothing (exit 0) if not.

set -euo pipefail

repo=""
package=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --package) package="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$repo" ]] || { echo "--repo is required" >&2; exit 1; }
[[ -n "$package" ]] || { echo "--package is required" >&2; exit 1; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
number="$(bash -- "$script_dir/find_failure_issue.sh" --repo "$repo" --package "$package" --label update-blocked)"

if [[ -z "$number" ]]; then
  echo "No open update-blocked Issue for $package -- proceeding" >&2
  exit 0
fi

issue_url="https://github.com/$repo/issues/$number"
title="$(gh issue view "$number" --repo "$repo" --json title --jq .title | tr -d '\r')"

echo "::notice::$package updates are blocked by $issue_url ($title) -- skipping the build. Close that Issue to unblock."
echo "$issue_url"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "blocked=true" >> "$GITHUB_OUTPUT"
  echo "issue_url=$issue_url" >> "$GITHUB_OUTPUT"
fi

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "## $package: update blocked"
    echo
    echo "Skipped without building: [$title]($issue_url) is open."
    echo "Close it once the blocker is resolved, then dispatch again."
  } >> "$GITHUB_STEP_SUMMARY"
fi
