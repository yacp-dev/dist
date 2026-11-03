#!/usr/bin/env bash
# Commits everything currently in --dir as a single, parentless commit and
# force-pushes it to replace gh-pages entirely (doc/spec.md 3.3: rebuild
# gh-pages down to one commit and force-push every time this manual
# publish step happens -- a deletion here is normal operation, not an
# exception, since devel packages keep only one generation, so there's no
# ongoing history worth preserving between publishes).
#
# Usage: publish_gh_pages.sh --dir gh-pages --message "..."

set -euo pipefail

dir=""
message=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) dir="$2"; shift 2 ;;
    --message) message="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$dir" ]] || { echo "--dir is required" >&2; exit 1; }
[[ -n "$message" ]] || { echo "--message is required" >&2; exit 1; }

cd "$dir"

git checkout --quiet --orphan gh-pages-new
git add -A
git commit --quiet -m "$message"
git branch -M gh-pages-new gh-pages
git push --force origin gh-pages
