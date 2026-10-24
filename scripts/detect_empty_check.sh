#!/usr/bin/env bash
# Tells whether a passing `cygport check` actually ran any tests. A
# check that runs nothing passes just the same, so a green check said
# nothing about whether the recipe's src_test reaches upstream's test
# suite at all: cygport's default src_test (cygtest) only tries `make
# check` and `make test`, and a recipe whose src_test is `:` or that
# inherits a cygclass the suite isn't wired into passes without running
# anything.
#
# Recognized as "ran no tests":
#   - src_test printed nothing (the check log is only __log_init's
#     header: the cygport version and the PF/S/B/... = lines)
#   - cygtest's "No testsuite detected."
#   - top-level make's "Nothing to be done for 'check'/'test'" (a
#     recursive make prints it as make[N] for each subdirectory without
#     tests, even when another one runs the suite: mecab-0.996)
#   - ctest's "No tests were found", meson's "No tests defined.",
#     automake's "# TOTAL: 0", pytest's "collected 0 items"/"no tests ran"
# A suite that ran but printed none of the totals these runners print
# isn't guessed at.
#
# Meant to run right after cygport check when its outcome is success,
# while the check log is still on disk.
#
# Usage:
#   detect_empty_check.sh --dir yacp/googletest --file googletest-1.18.0-1bl1.cygport
#
# Output: "check-empty: <reason>" plus the end of the check log when no
# tests ran, nothing otherwise; if GITHUB_OUTPUT is set, also
# `reason=<reason>` there.

set -uo pipefail # NOT -e: greps finding nothing are expected here

dir=""
cygport_file=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) dir="$2"; shift 2 ;;
    --file) cygport_file="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$dir" ]] || { echo "--dir is required" >&2; exit 1; }
[[ -n "$cygport_file" ]] || { echo "--file is required" >&2; exit 1; }

cd "$dir"
[[ -f "$cygport_file" ]] || { echo "No such file: $dir/$cygport_file" >&2; exit 1; }

# Same `cygport <file> vars <NAME>` mechanism as the diagnose_*.sh scripts.
vars_decl="$(cygport "$cygport_file" vars checklog 2>/dev/null)"
if [[ -z "$vars_decl" ]]; then
  echo "detect_empty_check.sh: 'cygport $cygport_file vars ...' returned nothing -- can't locate the check log" >&2
  exit 0
fi
eval "$vars_decl"

if [[ ! -f "${checklog:-}" ]]; then
  echo "detect_empty_check.sh: no check log at '${checklog:-(unset)}'" >&2
  exit 0
fi

# What src_test printed: everything after __log_init's header, whose
# last variable line is MAKEOPTS, with inform()'s colors stripped.
body="$(awk 'header_done { print; next } /^MAKEOPTS = / { header_done = 1 }' "$checklog" |
  perl -pe 's/\e\[[0-9;]*m//g')"

reason=""
if [[ -z "${body//[[:space:]]/}" ]]; then
  reason="src_test printed nothing"
elif grep -q 'No testsuite detected' <<<"$body"; then
  reason="cygtest found no check or test target"
elif grep -qE "^make: Nothing to be done for [\`'\"](check|test)['\"]" <<<"$body"; then
  reason="make's check/test target does nothing"
elif grep -q 'No tests were found' <<<"$body"; then
  reason="ctest found no tests"
elif grep -q '^No tests defined\.' <<<"$body"; then
  reason="meson found no tests"
elif grep -qE '^# TOTAL: 0$' <<<"$body"; then
  reason="automake's test suite has no tests"
elif grep -qE 'collected 0 items|no tests ran' <<<"$body"; then
  reason="pytest collected no tests"
fi

[[ -n "$reason" ]] || exit 0

echo "check-empty: $reason"
echo
echo "--- end of $checklog ---"
tail -n 20 <<<"$body"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "reason=$reason" >> "$GITHUB_OUTPUT"
fi
