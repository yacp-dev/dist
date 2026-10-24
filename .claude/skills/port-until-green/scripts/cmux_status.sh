#!/usr/bin/env bash
# Shows which package this session is porting, and where it is in the
# loop, as a status pill on its cmux workspace in the sidebar, so
# concurrent sessions can be told apart at a glance.
#
# Does nothing (and exits 0) outside cmux, or if the cmux CLI fails: the
# pill is a convenience and must never break the loop.
#
# Usage:
#   cmux_status.sh "<pkg>-<ver> · build #2 running"
#   cmux_status.sh --clear

key="port-until-green"

[[ -n "${CMUX_WORKSPACE_ID:-}" ]] || exit 0
cmux="${CMUX_BUNDLED_CLI_PATH:-$(command -v cmux)}"
[[ -x "$cmux" ]] || exit 0

if [[ "${1:-}" == "--clear" ]]; then
  "$cmux" clear-status "$key" >/dev/null 2>&1
else
  [[ -n "${1:-}" ]] || { echo "Usage: cmux_status.sh <text> | --clear" >&2; exit 1; }
  "$cmux" set-status "$key" "$1" --icon hammer >/dev/null 2>&1
fi
exit 0
