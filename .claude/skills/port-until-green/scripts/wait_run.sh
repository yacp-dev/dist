#!/usr/bin/env bash
# Waits for a build-package run to finish and exits with its result.
#
# Stands in for `gh run watch`, which refreshes every 3 seconds and
# fetches the run and its jobs on each refresh: one watch over a 30-minute
# build costs ~1,200 API calls, so a few concurrent sessions exhaust the
# 5,000/hour REST limit they share. Here each check is a single
# `gh run view --json status,conclusion`, at a pace suited to builds that
# take minutes. A failed check (network blip, rate limit) is retried at
# the next interval rather than aborting the wait.
#
# Usage:
#   wait_run.sh --run 123456789 [--interval 90]
# Output: "<conclusion> <run url>" on stdout once the run completes.
# Exit status 0 if the conclusion is success, 1 otherwise.

set -euo pipefail

repo="yacp-dev/dist"
run=""
interval=90

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run) run="$2"; shift 2 ;;
    --interval) interval="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$run" ]] || { echo "--run is required" >&2; exit 1; }

while :; do
  if state="$(gh run view "$run" -R "$repo" --json status,conclusion,url \
      --jq '.status + " " + .conclusion + " " + .url' 2>&1)"; then
    read -r status conclusion url <<<"$state"
    if [[ "$status" == "completed" ]]; then
      echo "$conclusion $url"
      [[ "$conclusion" == "success" ]]
      exit
    fi
  else
    echo "gh run view failed, retrying: $state" >&2
  fi
  sleep "$interval"
done
