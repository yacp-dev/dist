#!/usr/bin/env bash
# Checks out dorgann's own gh-pages branch into --dir, creating it fresh
# as an empty orphan branch if it doesn't exist yet (the very first
# publish). gh-pages is a generated artifact with no history worth
# preserving beyond "the currently published tree" (doc/spec.md 3.3), so
# there's nothing to lose by starting from nothing.
#
# Embeds GH_TOKEN directly in the remote URL rather than relying on
# actions/checkout's credential setup, since this may need to `git init`
# a fresh repository rather than checking out an existing ref (and either
# way, publish_gh_pages.sh needs push credentials in this same directory
# later).
#
# Usage: checkout_gh_pages.sh --repo yacp-dev/dist --dir gh-pages

set -euo pipefail

repo=""
dir=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --dir) dir="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$repo" ]] || { echo "--repo is required" >&2; exit 1; }
[[ -n "$dir" ]] || { echo "--dir is required" >&2; exit 1; }
[[ -n "${GH_TOKEN:-}" ]] || { echo "GH_TOKEN must be set" >&2; exit 1; }

remote_url="https://x-access-token:${GH_TOKEN}@github.com/${repo}.git"

# Decide "doesn't exist yet" only from ls-remote's own answer (exit status 2:
# no matching ref). Any other failure (network, auth, rate limit) must stop
# the run: treating it as a missing branch bootstraps an empty gh-pages that
# the publish then force-pushes over the real one.
ls_status=0
git ls-remote --exit-code --heads "$remote_url" gh-pages >/dev/null 2>&1 || ls_status=$?

if [[ $ls_status -eq 0 ]]; then
  git clone --quiet --branch gh-pages --single-branch --depth 1 "$remote_url" "$dir"
  echo "Checked out existing gh-pages branch" >&2
elif [[ $ls_status -eq 2 ]]; then
  echo "gh-pages branch doesn't exist yet -- starting fresh" >&2
  mkdir -p "$dir"
  git -C "$dir" init --quiet -b gh-pages
  git -C "$dir" remote add origin "$remote_url"
else
  echo "Could not query gh-pages on ${repo} (git ls-remote exit status ${ls_status}); refusing to bootstrap a fresh branch" >&2
  exit 1
fi

git -C "$dir" config user.name "github-actions[bot]"
git -C "$dir" config user.email "41898282+github-actions[bot]@users.noreply.github.com"
