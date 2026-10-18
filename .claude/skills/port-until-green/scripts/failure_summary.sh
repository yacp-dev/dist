#!/usr/bin/env bash
# Summarizes a failed build-package run: which steps failed, the
# build-failed Issue's diagnostics (patch/macro diagnostics end up there),
# and the full failed-step log saved to a file. `gh run view --log-failed`
# labels every line "UNKNOWN STEP" and runs to thousands of lines, so it is
# saved for grepping rather than printed.
#
# Usage:
#   failure_summary.sh --run 123456789 --package foo --out /path/to/dir
# Output: failed step names, the matching open Issue (if any), and the
# path of the saved log.

set -euo pipefail

repo="yacp-dev/dist"
run=""
package=""
out=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run) run="$2"; shift 2 ;;
    --package) package="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$run" ]] || { echo "--run is required" >&2; exit 1; }
[[ -n "$package" ]] || { echo "--package is required" >&2; exit 1; }
[[ -n "$out" ]] || { echo "--out is required" >&2; exit 1; }

mkdir -p "$out"

echo "== Failed steps"
gh run view "$run" -R "$repo" --json jobs \
  --jq '.jobs[].steps[] | select(.conclusion == "failure") | "- " + .name'

echo
echo "== build-failed Issue"
# Matched on the dorgann-meta comment (doc/spec.md 4.5) rather than a
# title prefix, which would also match e.g. foo-bar for foo.
issue=$(gh issue list -R "$repo" -l build-failed -s open -L 100 --json number,body \
  --jq "map(select(.body | contains(\"\\\"package\\\":\\\"$package\\\"\"))) | .[0].number // empty")
if [[ -n "$issue" ]]; then
  gh issue view "$issue" -R "$repo" --json url,body --jq '.url, .body'
else
  echo "(none open)"
fi

log="$out/run-$run-failed.log"
# perl rather than sed: BSD sed (macOS) doesn't understand \x1b.
gh run view "$run" -R "$repo" --log-failed | perl -pe 's/\e\[[0-9;]*m//g' > "$log"
echo
echo "== Log"
echo "$log ($(wc -l < "$log") lines)"
