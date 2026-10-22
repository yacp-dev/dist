#!/usr/bin/env bash
# Summarizes a failed build-package run: which steps failed, the
# workflow's own patch/macro diagnostics (the Diagnose patch failure/
# Diagnose undefined macro steps, which succeed and so aren't in
# --log-failed), and the full failed-step log saved to a file. `gh run view --log-failed`
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

# Each diagnose step only runs when its own step failed. Cut its output
# out of `gh run view --log` (which, unlike --log-failed, keeps step
# names): the third tab-separated field is "<timestamp> <line>"; drop the
# timestamp and the step's own ##[group] preamble.
diagnose_steps=()
for name in "Diagnose patch failure" "Diagnose undefined macro"; do
  if awk -F'\t' -v n="$name" '$1 == n && $2 == "success" { found = 1 } END { exit !found }' <<<"$steps"; then
    diagnose_steps+=("$name")
  fi
done
if (( ${#diagnose_steps[@]} > 0 )); then
  full_log="$(gh run view "$run" -R "$repo" --log | perl -pe 's/\e\[[0-9;]*m//g')"
  for name in "${diagnose_steps[@]}"; do
    echo
    echo "== $name"
    awk -F'\t' -v n="$name" '$2 == n { sub(/^[^ ]+ /, "", $3); print $3 }' <<<"$full_log" |
      sed '1,/^##\[endgroup\]/d'
  done
fi

log="$out/run-$run-failed.log"
# perl rather than sed: BSD sed (macOS) doesn't understand \x1b.
gh run view "$run" -R "$repo" --log-failed | perl -pe 's/\e\[[0-9;]*m//g' > "$log"
echo
echo "== Log"
echo "$log ($(wc -l < "$log") lines)"
