# Sourced by audit_recipe.sh: the "Check" section, on what `cygport
# check` did. That step is continue-on-error (build-package.yml), so a
# failing test suite leaves the run -- and the step's own conclusion --
# green, and neither a pass nor a failure says how much of the suite
# ran. The section starts with one verdict line:
#
#   check: FAILED      the step failed (or timed out); then why, below
#   check: FAILED (N of M unit tests failed, though cygport check passed)
#                      a test driver that exits 0 on failures and only
#                      prints "unit testing failed: N" (libosip2's
#                      src/test/tst)
#   check: empty (<reason>)
#                      it passed without running any tests
#   check: passed
#   check: unknown (...)
#                      no check log to read
#
# and, whichever it is, ends with the tests it skipped
# ("check-skipped: N test(s)" and one line per test).
#
# Expects $checklog, $workdir and $B (cygport vars), $cygport_file in the
# current directory and $check_outcome (steps.check.outcome). Sets check_verdict (failed, empty, passed or
# unknown, empty when check didn't run), check_empty_reason and
# check_skipped (the number of skipped tests, empty for none).

# --- Why it failed ------------------------------------------------------
#
# The reason sits in a test log that never leaves the runner: meson's
# testlog.txt, ctest's LastTest.log, automake's test-suite.log. libeconf
# 0.8.6 was the case in point: all 73 tests failed with exit status 127
# and nothing in the job log said why, even though meson had already put
# the build root (where the DLL was) on PATH.
#
# Exit status 127 on Cygwin means the program couldn't be started at all
# -- most often a DLL it needs isn't found -- so besides the test log,
# this runs `cygcheck` on the first failing test executable (with the
# PATH meson ran it with, when the check log shows it), which names any
# DLL that can't be found, and then runs that executable once directly
# to capture what the loader itself says. A summary and the first few
# distinct failures, not the whole log.

# The blocks of a test log that belong to failing tests: up to 3, each
# capped at 40 lines (the first and last 20 of a longer one -- an abort
# or crash message comes last). meson's testlog.txt separates tests with
# "==== N/M ====" lines and records "result: exit status <n>" (or e.g.
# "result: timeout"; 77 is a skip); ctest's LastTest.log starts each test
# with "N/M Testing: name" and says "Test Failed" -- its "----" lines
# also come *inside* a test, around the output, so splitting on them
# left only the "Test Failed" tail ("Subprocess aborted" and not a line of
# why); automake's per-test .log files are named in
# test-suite.log's own FAIL lines, so its head is enough.
#
# A block whose content -- minus the lines that differ per test anyway
# (name, timing, command), and with the test's own name and any .exe path
# masked out of the rest -- repeats an earlier one is counted instead of
# shown: when a whole suite fails for one reason (e.g. a loader error naming
# each test's own .exe), three copies of
# it would crowd out nothing but themselves.
#
# For testlog.txt, which blocks failed is taken from meson's own verdict
# in the check log ("58/320 suite - name  FAIL  ..."), passed in as the
# test numbers: the block's "result:" line can't tell, since it says
# "exit status 1" for a should_fail test meson counts as EXPECTEDFAIL
# too (a should_fail test filled a slot while real failures showed none).
# Without those numbers, "result:" is only looked for in
# the block's header -- a test's stdout can have a "result:" line of its
# own.
check_failure_blocks() {
  local log="$1" failed_nums="${2:-}" sep bad_re
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
  awk -v sep="$sep" -v bad_re="$bad_re" -v failed_nums="$failed_nums" -v max=3 -v cap=40 '
    BEGIN { n = split(failed_nums, f, " "); for (i = 1; i <= n; i++) failed[f[i]] = 1 }
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
    $0 ~ sep {
      flush(); if (done) exit; delete buf; key = ""; name = ""; lines = 0; bad = 0; body = 0
      # meson "==== 58/320 ====": the test number
      if (n) { num = $0; sub(/^=+ /, "", num); sub(/\/.*/, "", num); bad = (num in failed) }
    }
    # meson "---- stdout ----"/"---- stderr ----" end the header
    /^-+ std(out|err) -+$/ { body = 1 }
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
    !n && !body && $0 ~ bad_re && !/exit status (0|77)[[:space:]]*$/ { bad = 1 }
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
check_failure_diagnostic() {
  # In a $(...) subshell, so this PATH stays here: the direct run below
  # sees the PATH cygport check ran with (Windows directories left out,
  # see cygwin_path.sh), so it fails the same way.
  restrict_path_to_cygwin 2>/dev/null
  echo "cygport check failed. From $checklog:"
  echo
  # Totals first -- meson ("Ok:"/"Fail:"/"Timeout:"), ctest ("% tests
  # passed"), automake ("# FAIL:"/"# ERROR:"), googletest ("[  PASSED  ]
  # N tests.") -- then the first few
  # failing tests, since a suite where everything fails would otherwise
  # bury the totals under dozens of near-identical lines.
  totals="$(grep -E '^(Ok|Fail|Expected Fail|Unexpected Pass|Skipped|Timeout): |tests passed|^# (TOTAL|PASS|FAIL|ERROR|XPASS):|^\[(=+| +PASSED +| +FAILED +| +SKIPPED +)\] [0-9]+ tests?' "$checklog" | head -n 10)"
  [[ -z "$totals" ]] || echo "$totals"
  failing="$(grep -E '^ *[0-9]+/[0-9]+ .* (FAIL|TIMEOUT|ERROR|UNEXPECTEDPASS) |\*\*\*(Failed|Exception|Timeout)|^(FAIL|ERROR): |^\[  FAILED  \] [A-Za-z_]' "$checklog" |
    # googletest prints each failed test twice, with and without "(N ms)".
    sed -E 's/^(\[  FAILED  \] [^ ]+) \([0-9]+ ms\)$/\1/' | awk '!seen[$0]++')"
  if [[ -n "$failing" ]]; then
    echo
    head -n 10 <<<"$failing"
    count="$(wc -l <<<"$failing")"
    (( count > 10 )) && echo "... and $((count - 10)) more"
  fi

  shopt -s nullglob globstar
  test_logs=("$workdir"/**/meson-logs/testlog.txt "$workdir"/**/Testing/Temporary/LastTest.log "$workdir"/**/test-suite.log)
  # meson's verdict lines (" 58/320 suite - name  FAIL  0.45s ..."): the
  # test numbers, for picking testlog.txt's blocks (see check_failure_blocks).
  meson_failed="$(grep -E '^ *[0-9]+/[0-9]+ ' <<<"${failing:-}" | sed -E 's|^ *([0-9]+)/.*|\1|' | tr '\n' ' ')"
  for log in "${test_logs[@]}"; do
    case "$log" in
      */testlog.txt) block="$(check_failure_blocks "$log" "$meson_failed")" ;;
      *) block="$(check_failure_blocks "$log")" ;;
    esac
    [[ -n "$block" ]] || continue
    echo
    echo "--- failures in $log (first 3 distinct) ---"
    echo "$block"
    break
  done

  # No test runner's results anywhere: a src_test that runs its own
  # commands, so what it printed is all there is to go on (e.g.
  # `./prog.exe --version` exits 42, and this section said nothing else).
  if [[ -z "$totals$failing${block:-}" ]]; then
    echo "--- end of $checklog (no test runner's results in it) ---"
    check_log_body | tail -n 20
  fi

  # meson prints each failing test's full environment and command on a
  # ">>> VAR=... /path/to/test.exe" line; otherwise fall back to the
  # first path that exists in the failing blocks (ctest's "Command:"
  # line) or the check log. Blocks come first and the toolchain's own
  # programs are skipped: the check log's compile lines name
  # /usr/bin/gcc.exe, which the diagnostic ran in place of
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
    # -k: a test that handles SIGTERM can go on running after it
    # (e.g. a scheduler starts a shutdown that
    # waits on services nobody runs, and the step hung until the 6-hour
    # job limit). Into a file rather than $(...): a process the test left
    # behind would hold the pipe open, and $(...) waits for its EOF.
    run_log="$(mktemp)"
    (cd "$(dirname "$exe")" && PATH="${test_path:-$PATH}" /usr/bin/timeout -k 5 20 "$exe" </dev/null >"$run_log" 2>&1)
    run_status=$?
    head -n 20 "$run_log"
    rm -f "$run_log"
    echo "exit status: $run_status"
  fi
}


# --- Whether it ran anything --------------------------------------------
#
# A check that runs nothing passes just the same, so a green check says
# nothing about whether the recipe's src_test reaches upstream's test
# suite at all: cygport's default src_test (cygtest) only tries `make
# check` and `make test`, and a recipe whose src_test is `:` or that
# inherits a cygclass the suite isn't wired into passes without running
# anything. Recognized as "ran no tests":
#   - src_test printed nothing (the check log is only __log_init's
#     header: the cygport version and the PF/S/B/... = lines)
#   - cygtest's "No testsuite detected."
#   - top-level make's "Nothing to be done for 'check'/'test'" (a
#     recursive make prints it as make[N] for each subdirectory without
#     tests, even when another one runs the suite)
#   - ctest's "No tests were found", meson's "No tests defined.",
#     automake's "# TOTAL: 0", pytest's "collected 0 items"/"no tests ran",
#     googletest's "Running 0 tests"
#   - a recursive automake `make check` where no directory it entered has
#     anything to run (check_automake_runs_nothing)
# A suite that ran but printed none of the totals these runners print
# isn't guessed at.
#
# The log alone can't tell that last case. automake's check depends on all,
# so a directory's all-local recipe prints its commands under `make check`
# as a test would (e.g. libtool --mode=execute copying a test binary that
# `make check` never runs), and make[N]'s "Nothing to be done" lines
# say nothing about the directories that printed something. What automake
# generated can: a directory with TESTS, check_PROGRAMS, check-local or the
# like has a recipe under check-am, or its own check rule.
#
# $1 is a Makefile. True when automake generated it and its check does
# nothing but go on to check-am or check-recursive. Written with $(MAKE)
# in the recipe when the directory has BUILT_SOURCES.
automake_makefile_runs_no_tests() {
  awk '
    NR == 1 && !/^# Makefile\.in generated by automake/ { exit 1 }
    rule != "" && /^\t/ {
      if (rule != "check" || $0 !~ /^\t\$\(MAKE\) \$\(AM_MAKEFLAGS\) check-(am|recursive)[ \t]*$/) { bad = 1 }
      next
    }
    { rule = "" }
    /^check-am:/ {
      rule = "check-am"; seen = 1
      if ($0 !~ /^check-am:[ \t]*all-am[ \t]*$/) bad = 1
      next
    }
    /^check:/ {
      rule = "check"
      if ($0 !~ /^check:[ \t]*(\$\(BUILT_SOURCES\)|check-am|check-recursive)?[ \t]*$/) bad = 1
    }
    END { exit (bad || !seen) }
  ' "$1"
}

# The directories `make check` went into, as make names them.
check_entered_dirs() {
  sed -nE "s/^make(\[[0-9]+\])?: Entering directory [\`']([^']+)'\$/\2/p" <<<"$1" | sort -u
}

# $1 is what src_test printed. True when it's cygport's own src_test running
# a recursive automake `make check` and neither $B nor any directory make
# entered has anything to run. A recipe's src_test may run more than make,
# and a directory that isn't automake's may run anything, so both count as
# running something. Nor does this see a single-directory package, where make
# enters nothing: without an all-local there, "Nothing to be done" says so.
check_automake_runs_nothing() {
  local dir entered=0
  grep -qE '^[[:space:]]*(function[[:space:]]+)?src_test[[:space:]]*(\(\)|\{|$)' "${cygport_file:-}" 2>/dev/null && return 1
  automake_makefile_runs_no_tests "$B/Makefile" 2>/dev/null || return 1
  while IFS= read -r dir; do
    entered=1
    automake_makefile_runs_no_tests "$dir/Makefile" 2>/dev/null || return 1
  done < <(check_entered_dirs "$1")
  (( entered ))
}

# $1 is what src_test printed (check_log_body); prints the reason, or
# nothing.
check_empty_reason_of() {
  local body="$1"
  if [[ -z "${body//[[:space:]]/}" ]]; then
    echo "src_test printed nothing"
  elif grep -q 'No testsuite detected' <<<"$body"; then
    echo "cygtest found no check or test target"
  elif grep -qE "^make: Nothing to be done for [\`'\"](check|test)['\"]" <<<"$body"; then
    echo "make's check/test target does nothing"
  elif grep -q 'No tests were found' <<<"$body"; then
    echo "ctest found no tests"
  elif grep -q '^No tests defined\.' <<<"$body"; then
    echo "meson found no tests"
  elif grep -qE '^# TOTAL: 0$' <<<"$body"; then
    echo "automake's test suite has no tests"
  elif grep -qE 'collected 0 items|no tests ran' <<<"$body"; then
    echo "pytest collected no tests"
  elif grep -qE '^\[=+\] Running 0 tests' <<<"$body" && ! grep -qE '^\[=+\] Running [1-9]' <<<"$body"; then
    echo "googletest ran no tests"
  elif check_automake_runs_nothing "$body"; then
    echo "automake's Makefiles have no tests"
  fi
}

# What src_test printed: everything after __log_init's header, whose
# last variable line is MAKEOPTS, with inform()'s colors stripped.
check_log_body() {
  awk 'header_done { print; next } /^MAKEOPTS = / { header_done = 1 }' "$checklog" |
    perl -pe 's/\e\[[0-9;]*m//g'
}

# --- What it skipped ----------------------------------------------------
#
# A skipped test passes (or isn't counted) just the same, so nothing else
# on the run says the suite didn't cover it -- and a skip is often a
# missing BUILD_REQUIRES in disguise: a test script that looks for a tool
# and exits 0 when it's absent ("Missing ImageMagick, test skipped", which
# ctest counts as Passed), or
# a test upstream's build disables when an optional dependency isn't
# there ("Not Run (Disabled)" without libxml2).
#
# Read from the check log:
#   - ctest's "***Skipped" and "***Not Run (Disabled)" verdicts
#   - meson's SKIP verdicts
#   - automake's "SKIP: <test>" lines
#   - googletest's "[  SKIPPED ] Suite.name" lines
#   - pytest's "N skipped" totals
# and from ctest's LastTest.log, which keeps every test's output (the
# check log only has the verdicts): each test whose output says skip,
# skipped or skipping, with the first two such lines. Shell trace lines
# (`set -x`'s "+ ...") are left out, since they echo the message before
# the script prints it, and so are totals of "0 skipped".
check_skipped_tests() {
  perl -pe 's/\e\[[0-9;]*m//g' "$checklog" | awk '
    # ctest: " 60/63 Test #60: test_cmd_stdin ......***Not Run (Disabled)   0.00 sec"
    # A plain "Not Run" is ctest not finding the executable ("Unable to
    # find executable: hyphy"): a failure, already in the totals, not a skip.
    /Test +#[0-9]+: .*\*\*\*(Skipped|Not Run \(Disabled\))/ {
      name = $0; sub(/.*Test +#[0-9]+: /, "", name); sub(/ .*/, "", name)
      why = $0; sub(/.*\*\*\*/, "", why); sub(/ +[0-9.]+ sec.*/, "", why)
      print name ": " why; next
    }
    # meson: " 3/12 suite - name   SKIP   0.01s   exit status 77"
    /^ *[0-9]+\/[0-9]+ .* SKIP / {
      line = $0; sub(/^ *[0-9]+\/[0-9]+ /, "", line); sub(/ +SKIP .*/, "", line)
      print line ": SKIP (meson)"; next
    }
    # automake: "SKIP: t/foo.sh"
    /^SKIP: / { name = $0; sub(/^SKIP: /, "", name); print name ": SKIP (automake)"; next }
    # googletest: "[  SKIPPED ] Suite.name (0 ms)" (and again in its
    # "listed below" summary; the totals line starts with a digit)
    /^\[  SKIPPED \] [A-Za-z_]/ { print $4 ": SKIP (gtest)"; next }
    # pytest: "=== 10 passed, 2 skipped in 1.23s ==="
    /^=+ .*[0-9]+ skipped/ { line = $0; gsub(/^=+ | =+$/, "", line); print "pytest: " line; next }
  '

  local log
  shopt -s nullglob globstar
  for log in "$workdir"/**/Testing/Temporary/LastTest.log; do
    perl -pe 's/\e\[[0-9;]*m//g' "$log" | awk '
      /^[0-9]+\/[0-9]+ Testing: / { name = $0; sub(/^[0-9]+\/[0-9]+ Testing: /, "", name); out = 0; n = 0; next }
      /^Output:$/ { out = 1; next }
      /^<end of output>$/ { out = 0; next }
      out && !/^\++ / && n < 2 {
        l = tolower($0)
        # Totals saying none did (doctest: "0 failed | 0 skipped").
        if (l ~ /(^|[^0-9])0 skipped/) next
        # An option prompt or usage text ("[select 0 to skip]", "(null to
        # skip)") says nothing about this run.
        if (l ~ /to skip/) next
        if (l ~ /(^|[^a-z_])skip(ped|ping|s)?([^a-z_]|$)/) {
          print name ": " $0; n++
        }
      }
    '
  done
  shopt -u nullglob globstar
}

# --- How many tests, and whether upstream has any ----------------------
#
# The totals the test runner printed, as one short string for the run
# summary ("ctest 97/101 passed", "meson 12/12 passed", "automake 8/8
# passed", "gtest 120/123 passed"); empty when the log has none of these runners' totals.
check_test_counts() {
  local line total failed ok
  perl -pe 's/\e\[[0-9;]*m//g' "$checklog" | awk '
    /tests passed, [0-9]+ tests? failed out of [0-9]+/ {
      f = $0; sub(/.*passed, /, "", f); sub(/ test.*/, "", f)
      t = $0; sub(/.*out of /, "", t); sub(/[^0-9].*/, "", t)
      ctest = (t - f) "/" t " passed"
    }
    /^Ok: +[0-9]+/ { mok = $2; m += $2; meson = 1 }
    /^(Expected Fail|Fail|Unexpected Pass|Skipped|Timeout): +[0-9]+/ { m += $NF; meson = 1 }
    /^# TOTAL: [0-9]+/ { at = $3; auto = 1 }
    /^# PASS: +[0-9]+/ { ap = $3 }
    # googletest, summed over every test executable that ran:
    #   "[==========] 123 tests from 10 test suites ran. (45 ms total)"
    #   "[  PASSED  ] 120 tests."
    /^\[=+\] [0-9]+ tests? from .* ran\./ {
      n = $0; sub(/^\[=+\] /, "", n); sub(/ .*/, "", n); gt += n; gtest = 1
    }
    /^\[ +PASSED +\] [0-9]+ tests?\./ {
      n = $0; sub(/^\[ +PASSED +\] /, "", n); sub(/ .*/, "", n); gp += n
    }
    END {
      if (ctest != "") print "ctest " ctest
      else if (meson) print "meson " mok "/" m " passed"
      else if (auto && at > 0) print "automake " ap "/" at " passed"
      else if (gtest && gt > 0) print "gtest " gp "/" gt " passed"
    }'
}

# What in $S says upstream has a test suite: prints a short evidence
# string, or nothing. Only meant for a check that ran no tests, to tell
# "upstream has none" from "src_test doesn't reach them". Bash and grep
# only, over the top two levels of the tree (and tests/, test/ below
# it): a hint for a human, not a proof.
check_upstream_tests_hint() {
  local f
  [[ -d "${S:-}" ]] || return 0
  for f in "$S"/CMakeLists.txt "$S"/*/CMakeLists.txt; do
    [[ -f "$f" ]] || continue
    if grep -qiE '^[[:space:]]*(enable_testing|include[[:space:]]*\([[:space:]]*CTest|add_test)[[:space:]]*\(' "$f" 2>/dev/null; then
      echo "${f#"$S"/} calls enable_testing()/add_test()"; return 0
    fi
  done
  for f in "$S"/meson.build "$S"/*/meson.build; do
    [[ -f "$f" ]] || continue
    if grep -qE '^[[:space:]]*test[[:space:]]*\(' "$f" 2>/dev/null; then
      echo "${f#"$S"/} calls test()"; return 0
    fi
  done
  for f in "$S"/Makefile.am "$S"/*/Makefile.am; do
    [[ -f "$f" ]] || continue
    if grep -qE '^[[:space:]]*(TESTS|check_PROGRAMS|check_SCRIPTS)[[:space:]]*\+?=' "$f" 2>/dev/null; then
      echo "${f#"$S"/} defines TESTS/check_PROGRAMS"; return 0
    fi
  done
  for f in "$S"/tests "$S"/test "$S"/t; do
    if [[ -d "$f" ]] && [[ -n "$(ls -A "$f" 2>/dev/null)" ]]; then
      echo "${f#"$S"/}/ exists"; return 0
    fi
  done
  return 0
}

# --- The section --------------------------------------------------------

# Appends each line of $1 to the report.
say_lines() {
  local line
  while IFS= read -r line; do
    say "$line"
  done <<<"$1"
}

# The section's work, run in a child bash by audit_check (below) with
# `say` writing to a file: it reads the whole check log several times,
# and a log of hundreds of MB would otherwise hold the Audit recipe step
# until its own timeout, losing every other section with it.
audit_check_body() {
  local body unit failed total skipped count lines max_lines=30
  check_verdict="" check_empty_reason="" check_skipped="" check_tests="" check_upstream_tests=""
  say ""
  say "== Check =="
  if [[ ! -f "${checklog:-}" ]]; then
    check_verdict=unknown
    say "check: unknown (no check log at '${checklog:-(unset)}' -- check never got as far as running src_test, or timed out before cygport created it)"
    return 0
  fi

  if [[ "$check_outcome" == failure ]]; then
    check_verdict=failed
    say "check: FAILED"
    say ""
    say_lines "$(check_failure_diagnostic)"
  else
    body="$(check_log_body)"
    check_empty_reason="$(check_empty_reason_of "$body")"
    unit="$(grep '^unit testing ' <<<"$body")"
    failed="$(sed -n 's/^unit testing failed: *//p' <<<"$unit")"
    if [[ -n "$check_empty_reason" ]]; then
      check_verdict=empty
      check_upstream_tests="$(check_upstream_tests_hint)"
      say "check: empty ($check_empty_reason) -- see whether upstream has a test suite src_test doesn't reach"
      [[ -z "$check_upstream_tests" ]] || say "check-upstream-tests: upstream has tests that were not run ($check_upstream_tests)"
      say ""
      say "--- end of $checklog ---"
      say_lines "$(tail -n 20 <<<"$body")"
    elif [[ -n "$failed" && "$failed" != 0 ]]; then
      check_verdict=failed
      total="$(sed -n 's/^unit testing total : *//p' <<<"$unit")"
      say "check: FAILED ($failed of $total unit tests failed, though cygport check passed)"
      say ""
      say_lines "$unit"
    else
      check_verdict=passed
      say "check: passed"
    fi
  fi

  check_tests="$(check_test_counts)"
  [[ -z "$check_tests" ]] || say "check-tests: $check_tests"

  skipped="$(check_skipped_tests | awk '!seen[$0]++')"
  [[ -n "$skipped" ]] || return 0
  # Tests, not lines: LastTest.log can give one test two lines.
  count="$(sed 's/: .*//' <<<"$skipped" | sort -u | wc -l | tr -d ' ')"
  lines="$(wc -l <<<"$skipped" | tr -d ' ')"
  check_skipped="$count"
  say ""
  say "check-skipped: $count test(s) -- a tool or library missing from BUILD_REQUIRES may be why"
  say_lines "$(head -n "$max_lines" <<<"$skipped")"
  (( lines > max_lines )) && say "... and $((lines - max_lines)) more line(s)"
  return 0
}

# --- Bounded ------------------------------------------------------------
#
# audit_check_body in a child bash under timeout(1), so a check log too
# large to read in time costs this section only: what it had printed by
# then is kept, and the verdict is `unknown`, not `passed`. The seconds
# come from AUDIT_CHECK_TIMEOUT_SECONDS (default 300). The child needs
# the cygport variables exported, and gets say() as a file append; the
# verdict variables come back through a file. An absolute path, since
# audit_recipe.sh has changed to the package directory by the time the child
# sources it, and a relative BASH_SOURCE wouldn't survive that.
check_sh="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

audit_check() {
  local out vars rc line secs="${AUDIT_CHECK_TIMEOUT_SECONDS:-300}"
  check_verdict="" check_empty_reason="" check_skipped="" check_tests="" check_upstream_tests=""
  case "$check_outcome" in
    success|failure) ;;
    *) return 0 ;;  # never ran (an earlier step failed), or cancelled
  esac
  out="$(mktemp)"
  vars="$(mktemp)"
  export checklog workdir B S D logdir cygport_file check_outcome
  timeout -k 5 "$secs" bash -c '
    source "$1"; source "$2"
    out_file=$3; say() { printf "%s\n" "$*" >> "$out_file"; }
    audit_check_body
    printf "check_verdict=%q\ncheck_empty_reason=%q\ncheck_skipped=%q\ncheck_tests=%q\ncheck_upstream_tests=%q\n" \
      "$check_verdict" "$check_empty_reason" "$check_skipped" "$check_tests" "$check_upstream_tests" > "$4"
  ' _ "$(dirname "$check_sh")/../cygwin_path.sh" "$check_sh" "$out" "$vars"
  rc=$?
  while IFS= read -r line; do
    say "$line"
  done < "$out"
  if (( rc == 124 || rc == 137 )); then
    check_verdict=unknown check_empty_reason="" check_skipped="" check_tests="" check_upstream_tests=""
    say ""
    warn "the Check section didn't finish in ${secs}s (a check log too large to read?) -- the test side of the audit was cut off; what the section printed so far is above"
  else
    # shellcheck disable=SC1090
    [[ -s "$vars" ]] && source "$vars"
  fi
  rm -f "$out" "$vars"
  return 0
}
