#!/usr/bin/env bash
# Decides how to build a target again after a fix: re-run the previous
# run's failed jobs (same run, attempt N+1), dispatch a new run, or wait
# for a run that's still going. Reads what dispatch_build.sh recorded for
# the latest run of that target.
#
# A re-run uses the run's own main SHA and inputs, but fetches the
# dorgann/<pkg>-<ver> branch afresh, so a recipe fix on the branch is
# picked up. So it's a re-run only when nothing else changed:
#   - the inputs passed now are the same as the run's (-f ...), and
#   - nothing under .github/ or scripts/ (what the workflow runs) changed
#     on main since the run's main SHA.
# Anything else, or no record of an earlier run, means a new dispatch.
#
# Usage:
#   run_decision.sh --target openzl-0.3.0 [-f changelog_message="Fix x"]
# Output (one line):
#   rerun <run id>                  gh run rerun <id> -R yacp-dev/dist --failed
#   wait <run id>                   the run is queued or in progress
#   dispatch <reason>               dispatch_build.sh with the same arguments

set -euo pipefail

repo="yacp-dev/dist"
state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/port-until-green/runs"
target=""
values=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) target="$2"; values+=("target=$2"); shift 2 ;;
    -f) values+=("$2"); shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$target" ]] || { echo "--target is required" >&2; exit 2; }

# The latest recorded run for this target (run ids grow over time).
last=""
if [[ -d "$state_dir" ]]; then
  last=$(grep -lxF "field=target=$target" "$state_dir"/* 2>/dev/null | sed 's|.*/||' | sort -n | tail -n 1 || true)
fi
[[ -n "$last" ]] || { echo "dispatch no earlier run recorded for $target"; exit 0; }

status=$(gh run view "$last" -R "$repo" --json status,conclusion --jq '.status + " " + (.conclusion // "")' 2>/dev/null) || {
  echo "dispatch could not read run $last"; exit 0; }
read -r run_status run_conclusion <<< "$status"
if [[ "$run_status" != "completed" ]]; then
  echo "wait $last"; exit 0
fi
if [[ "$run_conclusion" == "success" ]]; then
  echo "dispatch run $last succeeded; a new build is needed"; exit 0
fi

# Same inputs as the run's? (-f ... in the same order as dispatch_build.sh records them.)
now_fields=$(printf 'field=%s\n' "${values[@]}" | sort)
then_fields=$(grep '^field=' "$state_dir/$last" | sort)
if [[ "$now_fields" != "$then_fields" ]]; then
  echo "dispatch inputs changed since run $last"; exit 0
fi

# Did dorgann's workflow or scripts change on main since that run?
then_sha=$(sed -n 's/^main_sha=//p' "$state_dir/$last")
now_sha=$(gh api "repos/$repo/commits/main" --jq .sha 2>/dev/null) || {
  echo "dispatch could not read main"; exit 0; }
if [[ "$then_sha" == "$now_sha" ]]; then
  echo "rerun $last"; exit 0
fi
changed=$(gh api "repos/$repo/compare/$then_sha...$now_sha" --jq '.files[].filename' 2>/dev/null) || {
  echo "dispatch could not compare $then_sha with $now_sha (force-pushed?)"; exit 0; }
dorgann_changed=$(grep -E '^(\.github/|scripts/)' <<< "$changed" || true)
if [[ -n "$dorgann_changed" ]]; then
  echo "dispatch workflow or scripts changed on main since run $last: $(tr '\n' ' ' <<< "$dorgann_changed")"
else
  echo "rerun $last"
fi
