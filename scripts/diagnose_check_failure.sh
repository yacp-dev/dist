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
# diagnose_*.sh scripts: a summary and the first few distinct failures, not the whole
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

# The blocks of a test log that belong to failing tests: up to 3, each
# capped at 40 lines (the first and last 20 of a longer one -- an abort
# or crash message comes last). meson's testlog.txt separates tests with
# "==== N/M ====" lines and records "result: exit status <n>" (or e.g.
# "result: timeout"; 77 is a skip); ctest's LastTest.log starts each test
# with "N/M Testing: name" and says "Test Failed" -- its "----" lines
# also come *inside* a test, around the output, so splitting on them
# left only the "Test Failed" tail (spdlog 1.17.0: "Subprocess aborted"
# and not a line of why); automake's per-test .log files are named in
# test-suite.log's own FAIL lines, so its head is enough.
#
# A block whose content -- minus the lines that differ per test anyway
# (name, timing, command), and with the test's own name and any .exe path
# masked out of the rest -- repeats an earlier one is counted instead of
# shown: when a whole suite fails for one reason (libeconf 0.8.6: 73
# tests, one loader error naming each test's own .exe), three copies of
# it would crowd out nothing but themselves.
failure_blocks() {
  local log="$1" sep bad_re
  case "$log" in
    */testlog.txt)
      sep='^=+ [0-9]+/[0-9]+ =+$'
      bad_re='^result:'
      ;;
    */LastTest.log)
      sep='^[0-9]+/[0-9]+ Testing: '
      bad_re='Test Failed'
      ;;
    *)
      head -n 40 "$log"
      return
      ;;
  esac
  awk -v sep="$sep" -v bad_re="$bad_re" -v max=3 -v cap=40 '
    function flush(  i, half) {
      if (!bad) return
      if (key in seen) { dup++; return }
      seen[key] = 1
      half = int(cap / 2)
      for (i = 1; i <= lines; i++) {
        if (lines > cap && i == half + 1) {
          printf "... (%d lines omitted)\n", lines - 2 * half
          i = lines - half + 1
        }
        print buf[i]
      }
      if (++shown >= max) { done = 1 }
    }
    $0 ~ sep { flush(); if (done) exit; delete buf; key = ""; name = ""; lines = 0; bad = 0 }
    # meson "test:  suite:name", ctest "N/M Test: name"
    /^test:/ || /^[0-9]+\/[0-9]+ Test:/ {
      name = $NF; sub(/.*:/, "", name)
      # gsub() below takes it as a regex; names like "c++" must stay literal.
      gsub(/[][\\.^$*+?(){}|]/, "\\\\&", name)
    }
    {
      buf[++lines] = $0
      # ctest: "Test time =   5.58 sec", "\"name\" time elapsed: 00:00:05"
      if ($0 !~ /^(test|start time|duration|command|[0-9]+\/[0-9]+ Test|Start testing|End testing|Test time|"[^"]*" (start|end) time):/ && $0 !~ /^Test time = |^"[^"]*" time elapsed:/ && $0 !~ sep) {
        line = $0
        gsub(/[^ ]*\.exe/, "<exe>", line)
        if (name != "") gsub(name, "<test>", line)
        key = key line "\n"
      }
    }
    $0 ~ bad_re && !/exit status (0|77)[[:space:]]*$/ { bad = 1 }
    END {
      if (!done) flush()
      if (dup) printf "\n(%d more failing test(s) with the same output as one above)\n", dup
    }' "$log"
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
    block="$(failure_blocks "$log")"
    [[ -n "$block" ]] || continue
    echo
    echo "--- failures in $log (first 3 distinct) ---"
    echo "$block"
    break
  done

  # meson prints each failing test's full environment and command on a
  # ">>> VAR=... /path/to/test.exe" line; otherwise fall back to the
  # first path that exists in the failing blocks (ctest's "Command:"
  # line) or the check log. Blocks come first and the toolchain's own
  # programs are skipped: the check log's compile lines name
  # /usr/bin/gcc.exe, which nghttp3 1.18.0's diagnostic ran in place of
  # the test. ctest names the test without .exe
  # ("Command: \"/.../build/tests/main\""), so each path is also tried
  # with it added.
  cmd_line="$(grep -m1 -E '^>>> .*\.exe' "$checklog")"
  exe="$(grep -oE '/[^ ]+\.exe' <<<"${cmd_line:-}" | tail -n1)"
  test_path="$(grep -oE '(^| )PATH=[^ ]+' <<<"${cmd_line:-}" | sed -E 's/^ ?PATH=//')"
  if [[ -z "$exe" ]]; then
    while IFS= read -r candidate; do
      [[ "$candidate" == /usr/* || "$candidate" == /bin/* ]] && continue
      for path in "$candidate.exe" "$candidate"; do
        [[ -f "$path" ]] && { exe="$path"; break 2; }
      done
    done < <(cat - "$checklog" <<<"${block:-}" \
      | grep -oE '^Command: "[^"]+"|/[^ "]+\.exe' \
      | sed -E 's/^Command: "(.*)"$/\1/' \
      | awk '!seen[$0]++')
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
