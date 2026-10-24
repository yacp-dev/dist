#!/usr/bin/env bash
# Reports whether a build-package run's `cygport check` failed, and if so
# prints the workflow's own "Diagnose check failure" output (totals, the
# first failing tests, up to 3 distinct failing tests' log blocks,
# cygcheck and a direct run of the first failing executable).
#
# cygport check is continue-on-error, so the run and even the step's own
# conclusion stay green when tests fail; the only trace is whether the
# Diagnose check failure step ran (it's gated on steps.check.outcome)
# and, for a timeout, the check step's own log. `gh run view --log`
# keeps step names (unlike --log-failed), so the step can be cut out of
# it.
#
# Right after a run completes, the jobs API can still list its steps as
# they were mid-run (cygport check in_progress, the ones after it
# pending, no conclusions), so the step list is re-read until no step
# is left unfinished.
#
# A passing check that ran no tests leaves "check-empty: <reason>" in
# the Detect empty check step's log (detect_empty_check.sh); that's
# reported as "check: empty" rather than "check: passed".
#
# Usage:
#   check_summary.sh --run 123456789
# Output: "check: passed", "check: empty" plus the end of the check log,
# "check: FAILED" plus the diagnostic, or "check: unknown" when the run
# never reached check or predates the diagnose step.

set -euo pipefail

repo="yacp-dev/dist"
run=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run) run="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$run" ]] || { echo "--run is required" >&2; exit 1; }

# First line: "running", or how many steps are still unfinished.
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  out="$(gh run view "$run" -R "$repo" --json status,jobs \
    --jq '(if .status != "completed" then "running" else [.jobs[].steps[] | select(.status != "completed")] | length end),
          (.jobs[].steps[] | select(.name == "cygport check" or .name == "Diagnose check failure") | .name + "\t" + .conclusion)')"
  unfinished="${out%%$'\n'*}"
  [[ "$unfinished" == running || "$unfinished" == 0 ]] && break
  if [[ $attempt == 10 ]]; then
    echo "check: unknown (the run's step list is still unfinished; try again in a minute)"
    exit 0
  fi
  sleep 15
done
steps="$(tail -n +2 <<<"$out")"
check="$(awk -F'\t' '$1 == "cygport check" { print $2 }' <<<"$steps")"
diagnose="$(awk -F'\t' '$1 == "Diagnose check failure" { print $2 }' <<<"$steps")"

if [[ -z "$check" || "$check" == "skipped" ]]; then
  echo "check: unknown (cygport check didn't run)"
  exit 0
fi
if [[ -z "$diagnose" ]]; then
  echo "check: unknown (run predates the Diagnose check failure step; grep the cygport check step of 'gh run view $run --log' for Fail:/FAILED)"
  exit 0
fi
if [[ "$diagnose" == "skipped" ]]; then
  # Third tab-separated field is "<timestamp> <line>", as below.
  empty="$(gh run view "$run" -R "$repo" --log |
    perl -pe 's/\e\[[0-9;]*m//g' |
    awk -F'\t' '$2 == "Detect empty check" { sub(/^[^ ]+ /, "", $3); print $3 }' |
    sed -n '/^check-empty: /,$p')"
  if [[ -n "$empty" ]]; then
    first="${empty%%$'\n'*}"
    echo "check: empty (${first#check-empty: })"
    echo
    tail -n +2 <<<"$empty"
  else
    echo "check: passed"
  fi
  exit 0
fi

echo "check: FAILED"
echo
# Third tab-separated field is "<timestamp> <line>"; drop the timestamp
# and the step's own ##[group] preamble.
gh run view "$run" -R "$repo" --log |
  perl -pe 's/\e\[[0-9;]*m//g' |
  awk -F'\t' '$2 == "Diagnose check failure" { sub(/^[^ ]+ /, "", $3); print $3 }' |
  sed -n '/^cygport check failed/,$p'
