#!/usr/bin/env bash
# Downloads and extracts a dist artifact produced by build-package.yml,
# given its artifact ID (doc/spec.md 4.4.2 -- the ID visible in the URL
# when opening the artifact's download link on the Actions run page).
#
# Looks up the artifact's own workflow run via the Actions API first,
# rather than hitting the artifact zip-download endpoint directly, so
# `gh run download` (well-tested, handles auth/retries itself) can do the
# actual fetch.
#
# Refuses an expired artifact outright: dist artifacts expire under the
# default 90-day retention (doc/spec.md 4.4), so running this more than
# 90 days after the build means the artifact is already gone and the
# package needs to be rebuilt instead.
#
# Usage:
#   download_dist_artifact.sh --repo yacp-dev/dist --artifact-id 12345 --dest artifact

set -euo pipefail

repo=""
artifact_id=""
dest=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --artifact-id) artifact_id="$2"; shift 2 ;;
    --dest) dest="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$repo" ]] || { echo "--repo is required" >&2; exit 1; }
[[ -n "$artifact_id" ]] || { echo "--artifact-id is required" >&2; exit 1; }
[[ -n "$dest" ]] || { echo "--dest is required" >&2; exit 1; }

meta="$(gh api "repos/$repo/actions/artifacts/$artifact_id")"

expired="$(jq -r '.expired' <<<"$meta")"
if [[ "$expired" == "true" ]]; then
  echo "Artifact $artifact_id has expired (90-day retention) -- rebuild the package instead" >&2
  exit 1
fi

name="$(jq -r '.name' <<<"$meta")"
run_id="$(jq -r '.workflow_run.id' <<<"$meta")"

echo "Artifact $artifact_id: name=$name, from run $run_id" >&2

mkdir -p "$dest"
gh run download "$run_id" --repo "$repo" -n "$name" -D "$dest"
