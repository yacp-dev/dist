#!/usr/bin/env bash
# Publishes a green deploy run's dist artifact: finds its "*-dist"
# artifact and dispatches yacp-dev/dist's publish.yml with it.
#
# Usage:
#   publish_dist.sh --run 123456789 [--dry-run]
# Output: "<publish run id> <publish run url>", like dispatch_build.sh;
# with --dry-run, only "artifact <id> <name>".

set -euo pipefail

repo="yacp-dev/dist"
run="" dry=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run) run="$2"; shift 2 ;;
    --dry-run) dry=1; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done
[[ -n "$run" ]] || { echo "--run is required" >&2; exit 1; }

conclusion="$(gh run view "$run" -R "$repo" --json conclusion --jq .conclusion)"
[[ "$conclusion" == success ]] || { echo "run $run: ${conclusion:-not finished}; publish only a green run" >&2; exit 1; }

artifact="$(gh api "repos/$repo/actions/runs/$run/artifacts" \
  --jq '[.artifacts[] | select(.name | endswith("-dist"))] | .[0] | select(.) | "\(.id) \(.name) \(.expired)"')"
[[ -n "$artifact" ]] || { echo "run $run has no *-dist artifact" >&2; exit 1; }
read -r id name expired <<<"$artifact"
[[ "$expired" == false ]] || { echo "artifact $id ($name) has expired" >&2; exit 1; }

if (( dry )); then
  echo "artifact $id $name"
  exit 0
fi

url=$(gh workflow run publish.yml -R "$repo" -f artifact_id="$id" 2>&1 | grep -o "https://github.com/$repo/actions/runs/[0-9]*" | head -1)
[[ -n "$url" ]] || { echo "Dispatched, but gh printed no run URL (gh older than 2.102?)" >&2; exit 1; }
echo "${url##*/} $url"
