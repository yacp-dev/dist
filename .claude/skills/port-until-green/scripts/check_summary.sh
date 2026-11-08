#!/usr/bin/env bash
# Reports what a build-package run's `cygport check` did, from the Check
# section of the workflow's Audit recipe report (scripts/audit/check.sh):
# its verdict line -- "check: FAILED" with the diagnostic (totals, the
# first failing tests, up to 3 distinct failing tests' log blocks,
# cygcheck and a direct run of the first failing executable), "check:
# empty (<reason>)" with the end of the check log, "check: passed" --
# then "check-skipped: N test(s)" and the skipped tests, if any.
#
# cygport check is continue-on-error, so the run and even the step's own
# conclusion stay green when tests fail; only the report says so.
# `gh run view --log` keeps step names (unlike --log-failed), so the
# step's output can be cut out of it; when it prints "UNKNOWN STEP"
# instead, the Check section is found by its "== Check ==" header.
#
# Right after a run completes, the jobs API can still list its steps as
# they were mid-run (cygport check in_progress, the ones after it
# pending, no conclusions), so the step list is re-read until no step
# is left unfinished.
#
# Usage:
#   check_summary.sh --run 123456789
# Output: the Check section as above, or "check: unknown (...)" when the
# run never reached check or predates the Check section.

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
          (.jobs[].steps[] | select(.name == "cygport check" or .name == "Audit recipe") | .name + "\t" + .conclusion)')"
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
audit="$(awk -F'\t' '$1 == "Audit recipe" { print $2 }' <<<"$steps")"

if [[ -z "$check" || "$check" == "skipped" ]]; then
  echo "check: unknown (cygport check didn't run)"
  exit 0
fi
if [[ -z "$audit" || "$audit" == "skipped" ]]; then
  echo "check: unknown (Audit recipe didn't run; grep the cygport check step of 'gh run view $run --log' for Fail:/FAILED)"
  exit 0
fi

# Third tab-separated field is "<timestamp> <line>"; drop the timestamp.
# The section runs from its "== Check ==" header to the next header, or
# to the report's closing "N warning(s)." line.
# GitHub's log endpoint sometimes loses the step names ("UNKNOWN STEP"),
# so when no line is attributed to Audit recipe, look for the section
# marker in every line of the job instead.
log="$(gh run view "$run" -R "$repo" --log | perl -pe 's/\e\[[0-9;]*m//g')"
if ! awk -F'\t' '$2 == "Audit recipe" { found = 1 } END { exit !found }' <<<"$log"; then
  log="$(awk -F'\t' '$2 == "UNKNOWN STEP"' <<<"$log")"
  audit_filter='any'
else
  audit_filter='audit'
fi
section="$(awk -F'\t' -v f="$audit_filter" 'f == "any" || $2 == "Audit recipe" { sub(/^[^ ]+ /, "", $3); print $3 }' <<<"$log" |
  awk '/^== Check ==$/ { on = 1; next } on && (/^== .* ==$/ || /^[0-9]+ warning\(s\)/ || /^##\[/) { on = 0; done = 1 } on && !done' |
  sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')"

if [[ -z "$section" ]]; then
  echo "check: unknown (no Check section in Audit recipe's log -- the run predates it; see its Diagnose check failure / Detect empty check / Detect skipped tests steps)"
  exit 0
fi
echo "$section"
