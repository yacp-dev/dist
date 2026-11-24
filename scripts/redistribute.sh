#!/usr/bin/env bash
# Decides whether the build's packages may be handed out as a dist artifact:
# the recipe's YACP_NO_REDISTRIBUTE, set to 1 for software whose license
# doesn't permit redistributing binaries (a LicenseRef-* with such a
# term). The Actions artifacts of a public repository can be downloaded by
# anyone, so for these packages no artifact is uploaded at all, which also
# leaves publish.yml with nothing to publish.
#
# Anything that isn't empty or 0 counts as set: a typo has to fail on the
# safe side, since an artifact can't be taken back once it's been seen.
#
# Usage (paths relative to the package directory, e.g. yacp/libjxl):
#   redistribute.sh --dir yacp/libjxl --file libjxl-0.12.0-1bl1.cygport
# Output: `redistribute=true|false` to GITHUB_OUTPUT, and the reason to
# stdout.

set -uo pipefail

dir=""
cygport_file=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) dir="$2"; shift 2 ;;
    --file) cygport_file="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$dir" && -n "$cygport_file" ]] || { echo "--dir and --file are required" >&2; exit 1; }

# `cygport vars` may exit non-zero for a variable the recipe doesn't set
# (check_timeout.sh tolerates that too), so a failure only counts when the
# recipe's own text names the variable: then the answer can't be guessed.
if ! decl="$(cd "$dir" && cygport "$cygport_file" vars YACP_NO_REDISTRIBUTE 2>/dev/null)" &&
   [[ -z "$decl" ]] && grep -q 'YACP_NO_REDISTRIBUTE' "$dir/$cygport_file"; then
  echo "::error::cygport vars failed, and the recipe mentions YACP_NO_REDISTRIBUTE; can't tell its value" >&2
  exit 1
fi
YACP_NO_REDISTRIBUTE=""
if [[ -n "$decl" ]]; then
  eval "$decl"
fi
value="$YACP_NO_REDISTRIBUTE"

case "$value" in
  "" | 0)
    result=true
    echo "redistribute: yes (YACP_NO_REDISTRIBUTE isn't set)"
    ;;
  1)
    result=false
    echo "redistribute: no, the recipe sets YACP_NO_REDISTRIBUTE=1; no dist artifact is uploaded"
    ;;
  *)
    result=false
    echo "::warning::YACP_NO_REDISTRIBUTE '$value' isn't 1 or 0; treating it as 1 (no dist artifact)"
    ;;
esac

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "redistribute=$result" >> "$GITHUB_OUTPUT"
fi
