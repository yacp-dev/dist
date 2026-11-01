#!/usr/bin/env bash
# Summarizes a failed build-package run: which steps failed, the Recipe
# and Undefined macros sections of the workflow's Audit recipe report
# (a BUILD_REQUIRES package setup couldn't install, a macro whose .m4
# isn't installed -- both likely why the build failed; that
# step is continue-on-error, so it isn't in --log-failed), and the full
# failed-step log saved to a file. `gh run view --log-failed`
# labels every line "UNKNOWN STEP" and runs to thousands of lines, so it is
# saved for grepping rather than printed.
#
# Usage:
#   failure_summary.sh --run 123456789 --out /path/to/dir
# Output: failed step names, the diagnostics (if any), and the path of
# the saved log.

set -euo pipefail

repo="yacp-dev/dist"
run=""
out=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run) run="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$run" ]] || { echo "--run is required" >&2; exit 1; }
[[ -n "$out" ]] || { echo "--out is required" >&2; exit 1; }

mkdir -p "$out"

steps="$(gh run view "$run" -R "$repo" --json jobs \
  --jq '.jobs[].steps[] | .name + "\t" + .conclusion')"

echo "== Failed steps"
awk -F'\t' '$2 == "failure" { print "- " $1 }' <<<"$steps"

# Audit recipe runs whichever step failed. Cut its Recipe and
# Undefined macros sections out of `gh run view --log` (which, unlike
# --log-failed, keeps step names): the third tab-separated field is
# "<timestamp> <line>".
sections="$(gh run view "$run" -R "$repo" --log |
  perl -pe 's/\e\[[0-9;]*m//g' |
  awk -F'\t' '$2 == "Audit recipe" { sub(/^[^ ]+ /, "", $3); print $3 }' |
  awk '/^== (Recipe|Undefined macros) ==$/ { on = 1; print ""; print; next }
       on && (/^$/ || /^== .* ==$/ || /^##\[/) { on = 0 }
       on')" || true
if [[ -n "$sections" ]]; then
  echo "$sections"
fi

log="$out/run-$run-failed.log"
# perl rather than sed: BSD sed (macOS) doesn't understand \x1b.
gh run view "$run" -R "$repo" --log-failed | perl -pe 's/\e\[[0-9;]*m//g' > "$log"
echo
echo "== Log"
echo "$log ($(wc -l < "$log") lines)"
