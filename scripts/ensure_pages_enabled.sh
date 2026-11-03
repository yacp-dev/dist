#!/usr/bin/env bash
# Ensures GitHub Pages is configured to publish from the gh-pages branch
# (root path), creating that configuration if it doesn't exist yet.
# Idempotent -- safe to run on every publish, not just the first.
#
# Usage: ensure_pages_enabled.sh --repo yacp-dev/dist

set -euo pipefail

repo=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$repo" ]] || { echo "--repo is required" >&2; exit 1; }

if gh api "repos/$repo/pages" >/dev/null 2>&1; then
  echo "GitHub Pages already configured" >&2
else
  echo "Configuring GitHub Pages to publish from gh-pages" >&2
  gh api "repos/$repo/pages" -X POST -f 'source[branch]=gh-pages' -f 'source[path]=/'
fi
