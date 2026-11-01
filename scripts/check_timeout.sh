#!/usr/bin/env bash
# Decides the timeout of the `cygport check` step: the workflow's
# check_timeout_minutes input if given, else the recipe's
# YACP_CHECK_TIMEOUT_MINUTES (for a test suite known to be slow, so that
# no rebuild has to remember to ask for it), else 10.
#
# The recipe's value is capped at 180, since a hang holds the runner for
# as long as the timeout; the input isn't, being asked for by hand. A value
# that isn't a positive whole number is reported and passed over: an
# invalid timeout-minutes doesn't fail the workflow, it leaves the step
# with no timeout at all.
#
# Usage (paths relative to the package directory, e.g. yacp/libjxl):
#   check_timeout.sh --dir yacp/libjxl --file libjxl-0.12.0-1bl1.cygport
# Input: the check_timeout_minutes input in $CHECK_TIMEOUT_INPUT (empty if not
# given; pwsh, the steps' shell, can drop an empty argument on its way to bash).
# Output: `minutes=N` to GITHUB_OUTPUT, and where N came from to stdout.

set -uo pipefail

default=10
recipe_max=180

dir=""
cygport_file=""
input="${CHECK_TIMEOUT_INPUT:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) dir="$2"; shift 2 ;;
    --file) cygport_file="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$dir" && -n "$cygport_file" ]] || { echo "--dir and --file are required" >&2; exit 1; }

is_minutes() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }

decide() {
  if [[ -n "$input" ]]; then
    if is_minutes "$input"; then
      minutes="$input"
      echo "check timeout: $minutes minute(s), from the check_timeout_minutes input"
      return
    fi
    echo "::warning::check_timeout_minutes '$input' isn't a positive whole number; ignoring it"
  fi

  local decl YACP_CHECK_TIMEOUT_MINUTES=""
  decl="$(cd "$dir" && cygport "$cygport_file" vars YACP_CHECK_TIMEOUT_MINUTES 2>/dev/null)"
  if [[ -n "$decl" ]]; then
    eval "$decl"
  fi
  local value="$YACP_CHECK_TIMEOUT_MINUTES"

  if [[ -z "$value" ]]; then
    echo "check timeout: $minutes minute(s), the default"
  elif ! is_minutes "$value"; then
    echo "::warning::YACP_CHECK_TIMEOUT_MINUTES '$value' isn't a positive whole number; using the default of $minutes"
  elif (( ${#value} > 4 || value > recipe_max )); then
    minutes="$recipe_max"
    echo "::warning::YACP_CHECK_TIMEOUT_MINUTES '$value' is over the limit of $recipe_max; using $recipe_max"
  else
    minutes="$value"
    echo "check timeout: $minutes minute(s), from the recipe's YACP_CHECK_TIMEOUT_MINUTES"
  fi
}

minutes="$default"
decide

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "minutes=$minutes" >> "$GITHUB_OUTPUT"
fi
