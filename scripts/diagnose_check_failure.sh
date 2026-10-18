#!/usr/bin/env bash
# Surfaces why `cygport check` failed. That step is continue-on-error
# (build-package.yml), so a failing test suite leaves the run -- and the
# step's own conclusion -- green, and the reason sits in a test log that
# never leaves the runner: meson's testlog.txt, ctest's LastTest.log,
# automake's test-suite.log. libeconf 0.8.6 was the case in point: all 73
# tests failed with exit status 127 and nothing in the job log said
# why, even though meson had already put the build root (where the DLL
# was) on PATH.
#
# Exit status 127 on Cygwin means the program couldn't be started at all
# -- most often a DLL it needs isn't found -- so besides the test log,
# this runs `cygcheck` on the first failing test executable (with the
# PATH meson ran it with, when the check log shows it), which names any
# DLL that can't be found, and then runs that executable once directly
# to capture what the loader itself says.
#
# Meant to run right after cygport check when its outcome is failure,
# while the build tree is still on disk. Same bounded shape as the other
# diagnose_*.sh scripts: a summary and the first failure, not the whole
# log.
#
# Usage:
#   diagnose_check_failure.sh --dir yacp/googletest --file googletest-1.18.0-1bl1.cygport
#
# Output: prints the diagnostic to stdout; if GITHUB_OUTPUT is set, also
# writes it to a temp file and appends `diagnostic_file=<path>` there.

set -uo pipefail # NOT -e: greps finding nothing, and the test executable failing, are expected here

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

# Same `cygport <file> vars <NAME>` mechanism as the other diagnose_*.sh.
vars_decl="$(cygport "$cygport_file" vars checklog workdir 2>/dev/null)"
if [[ -z "$vars_decl" ]]; then
  echo "diagnose_check_failure.sh: 'cygport $cygport_file vars ...' returned nothing -- can't locate the check log" >&2
  exit 0
fi
eval "$vars_decl"

if [[ ! -f "${checklog:-}" ]]; then
  echo "diagnose_check_failure.sh: no check log at '${checklog:-(unset)}' -- check never got as far as running src_test (or timed out before cygport created it)" >&2
  exit 0
fi

# The first block of a test log that belongs to a failing test, capped.
# meson's testlog.txt separates tests with "==== N/M ====" lines and
# records "result: exit status <n>" (or e.g. "result: timeout"; 77 is a
# skip); ctest's LastTest.log separates them with
# "----" lines and says "Test Failed"; automake's per-test .log files
# are named in test-suite.log's own FAIL lines, so its head is enough.
first_failure_block() {
  local log="$1"
  case "$log" in
    */testlog.txt)
      awk '/^=+ [0-9]+\/[0-9]+ =+$/ { if (bad) exit; block = ""; }
           { block = block $0 "\n" }
           /^result:/ && !/exit status (0|77)[[:space:]]*$/ { bad = 1 }
           END { if (bad) printf "%s", block }' "$log" | head -n 60
      ;;
    */LastTest.log)
      awk '/^-{20,}/ { if (bad) exit; block = ""; }
           { block = block $0 "\n" }
           /Test Failed/ { bad = 1 }
           END { if (bad) printf "%s", block }' "$log" | head -n 60
      ;;
    *)
      head -n 60 "$log"
      ;;
  esac
}

# A function rather than one big $( ... ): bash's parser misreads an
# apostrophe inside a command substitution (in a comment, or in a
# ${var:+...} word) as an opening quote -- Cygwin's bash failed this way
# with "bad substitution" on a real run, /bin/bash 3.2 with "unexpected
# EOF".
build_diagnostic() {
  echo "cygport check failed. From $checklog:"
  echo
  # Totals first -- meson ("Ok:"/"Fail:"/"Timeout:"), ctest ("% tests
  # passed"), automake ("# FAIL:"/"# ERROR:") -- then the first few
  # failing tests, since a suite where everything fails would otherwise
  # bury the totals under dozens of near-identical lines.
  grep -E '^(Ok|Fail|Expected Fail|Unexpected Pass|Skipped|Timeout): |tests passed|^# (TOTAL|PASS|FAIL|ERROR|XPASS):' "$checklog" | head -n 10
  failing="$(grep -E '^ *[0-9]+/[0-9]+ .* (FAIL|TIMEOUT|ERROR) |\*\*\*(Failed|Exception|Timeout)|^(FAIL|ERROR): ' "$checklog")"
  if [[ -n "$failing" ]]; then
    echo
    head -n 10 <<<"$failing"
    count="$(wc -l <<<"$failing")"
    (( count > 10 )) && echo "... and $((count - 10)) more"
  fi

  shopt -s nullglob globstar
  test_logs=("$workdir"/**/meson-logs/testlog.txt "$workdir"/**/Testing/Temporary/LastTest.log "$workdir"/**/test-suite.log)
  for log in "${test_logs[@]}"; do
    block="$(first_failure_block "$log")"
    [[ -n "$block" ]] || continue
    echo
    echo "--- first failure in $log ---"
    echo "$block"
    break
  done

  # meson prints each failing test's full environment and command on a
  # ">>> VAR=... /path/to/test.exe" line; otherwise fall back to the
  # first .exe path the check log mentions that exists.
  cmd_line="$(grep -m1 -E '^>>> .*\.exe' "$checklog")"
  exe="$(grep -oE '/[^ ]+\.exe' <<<"${cmd_line:-}" | tail -n1)"
  test_path="$(grep -oE '(^| )PATH=[^ ]+' <<<"${cmd_line:-}" | sed -E 's/^ ?PATH=//')"
  if [[ -z "$exe" ]]; then
    for candidate in $(grep -oE '/[^ ]+\.exe' "$checklog" | awk '!seen[$0]++'); do
      [[ -f "$candidate" ]] && { exe="$candidate"; break; }
    done
  fi
  if [[ -n "$exe" && -f "$exe" ]]; then
    echo
    echo "--- cygcheck $exe${test_path:+ (with the PATH meson gave the test)} ---"
    # Absolute paths: the test's own PATH needn't include /usr/bin.
    PATH="${test_path:-$PATH}" /usr/bin/cygcheck "$exe" 2>&1 | head -n 40
    echo
    echo "--- running $exe directly${test_path:+ (with the PATH meson gave the test)} ---"
    run_out="$(cd "$(dirname "$exe")" && PATH="${test_path:-$PATH}" /usr/bin/timeout 20 "$exe" </dev/null 2>&1)"
    run_status=$?
    head -n 20 <<<"$run_out"
    echo "exit status: $run_status"
  fi
}

diagnostic="$(build_diagnostic)"

echo "$diagnostic"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  output="$(mktemp)"
  printf '%s\n' "$diagnostic" > "$output"
  echo "diagnostic_file=$output" >> "$GITHUB_OUTPUT"
fi
