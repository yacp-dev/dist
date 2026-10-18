#!/usr/bin/env bash
# Dispatches yacp-dev/dist's build-package.yml and prints the id of the
# run it created, taken from the run URL `gh workflow run` prints (gh
# 2.102+). Every run's title is just "build-package", so the URL is the
# only reliable way to tell which run is ours.
#
# Usage:
#   dispatch_build.sh --package foo --version 1.2.3
#   dispatch_build.sh --package foo --branch dorgann/foo-1.2.3
#   dispatch_build.sh --package foo --branch dorgann/foo-1.2.3 -f cygwin_packages=bar-devel
# Output: "<run id> <run url>" on stdout.

set -euo pipefail

repo="yacp-dev/dist"
workflow="build-package.yml"
package=""
fields=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --package) package="$2"; fields+=(-f "package=$2"); shift 2 ;;
    --version) fields+=(-f "version=$2"); shift 2 ;;
    --branch) fields+=(-f "branch=$2"); shift 2 ;;
    -f) fields+=(-f "$2"); shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$package" ]] || { echo "--package is required" >&2; exit 1; }

url=$(gh workflow run "$workflow" -R "$repo" "${fields[@]}" 2>&1 | grep -o "https://github.com/$repo/actions/runs/[0-9]*" | head -1)
[[ -n "$url" ]] || { echo "Dispatched, but gh printed no run URL (gh older than 2.102?)" >&2; exit 1; }

echo "${url##*/} $url"
