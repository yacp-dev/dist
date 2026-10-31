#!/usr/bin/env bash
# Dispatches yacp-dev/dist's build-package.yml and prints the id of the
# run it created, taken from the run URL `gh workflow run` prints (gh
# 2.102+). Every run's title is just "build-package", so the URL is the
# only reliable way to tell which run is ours.
#
# It also records what the run was built from, for run_decision.sh: the
# main SHA the dispatch used (the workflow and scripts/ come from it) and
# the inputs, in ~/.local/state/port-until-green/runs/<run id>.
#
# Usage:
#   dispatch_build.sh --target foo-1.2.3
#   dispatch_build.sh --target foo-1.2.3 -f cygwin_packages=bar-devel
# Output: "<run id> <run url>" on stdout.

set -euo pipefail

repo="yacp-dev/dist"
workflow="build-package.yml"
target=""
values=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) target="$2"; values+=("target=$2"); shift 2 ;;
    -f) values+=("$2"); shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$target" ]] || { echo "--target is required" >&2; exit 1; }

# The SHA the dispatch will run from: the default branch's HEAD right now.
main_sha=$(gh api "repos/$repo/commits/main" --jq .sha)

fields=()
for v in "${values[@]}"; do fields+=(-f "$v"); done
url=$(gh workflow run "$workflow" -R "$repo" "${fields[@]}" 2>&1 | grep -o "https://github.com/$repo/actions/runs/[0-9]*" | head -1)
[[ -n "$url" ]] || { echo "Dispatched, but gh printed no run URL (gh older than 2.102?)" >&2; exit 1; }
id="${url##*/}"

state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/port-until-green/runs"
mkdir -p "$state_dir"
{
  echo "main_sha=$main_sha"
  printf 'field=%s\n' "${values[@]}" | sort
} > "$state_dir/$id"

echo "$id $url"
