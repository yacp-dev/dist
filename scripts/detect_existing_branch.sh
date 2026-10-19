#!/usr/bin/env bash
# Auto-detects branch-rebuild mode (doc/spec.md 4.6) from package+version
# alone. If a
# dorgann/<package>-<version> branch already exists in yacp -- most
# commonly left over from an earlier failed run's own draft PR (doc/spec.md
# 4.6) -- a plain workflow_dispatch with the same target now
# transparently rebuilds against it instead of running into
# bump_version.sh's own "already at this version" refusal.
#
# Usage:
#   detect_existing_branch.sh --repo yacp-dev/ports --package foo --version 1.2.3
# Output: prints the branch name if it exists, and if GITHUB_OUTPUT is
# set, appends `branch=<name>` there; prints nothing (exit 0) if not.

set -euo pipefail

repo=""
package=""
version=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --package) package="$2"; shift 2 ;;
    --version) version="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$repo" ]] || { echo "--repo is required" >&2; exit 1; }
[[ -n "$package" ]] || { echo "--package is required" >&2; exit 1; }
[[ -n "$version" ]] || { echo "--version is required" >&2; exit 1; }

branch="dorgann/${package}-${version}"

if gh api "repos/$repo/branches/$branch" >/dev/null 2>&1; then
  echo "Found existing branch $branch -- switching to branch-rebuild mode" >&2
  echo "$branch"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "branch=$branch" >> "$GITHUB_OUTPUT"
  fi
else
  echo "No existing branch $branch -- proceeding with a fresh bump" >&2
fi
