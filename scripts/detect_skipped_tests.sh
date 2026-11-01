#!/usr/bin/env bash
# Lists the tests `cygport check` skipped. A skipped test passes (or isn't
# counted) just the same, so nothing else on the run says the suite didn't
# cover it -- and a skip is often a missing BUILD_REQUIRES in disguise: a
# test script that looks for a tool and exits 0 when it's absent
# (libavif 1.4.2's test_cmd_icc_profile: "Missing ImageMagick, test
# skipped", which ctest counts as Passed), or a test upstream's build
# disables when an optional dependency isn't there (its test_cmd_stdin,
# "Not Run (Disabled)" without libxml2).
#
# Read from the check log:
#   - ctest's "***Skipped" and "***Not Run" verdicts
#   - meson's SKIP verdicts
#   - automake's "SKIP: <test>" lines
#   - pytest's "N skipped" totals
# and from ctest's LastTest.log, which keeps every test's output (the
# check log only has the verdicts): each test whose output says skip,
# skipped or skipping, with the first two such lines. Shell trace lines
# (`set -x`'s "+ ...") are left out, since they echo the message before
# the script prints it.
#
# Meant to run right after cygport check, passed or failed, while the
# build tree is still on disk.
#
# Usage:
#   detect_skipped_tests.sh --dir yacp/libavif --file libavif-1.4.2-1bl2.cygport
#
# Output: "check-skipped: N test(s)" plus one line per test when any
# were skipped, nothing otherwise; if GITHUB_OUTPUT is set, also
# `count=N` and `report_file=<path>` there.

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
vars_decl="$(cygport "$cygport_file" vars checklog workdir 2>/dev/null)"
if [[ -z "$vars_decl" ]]; then
  echo "detect_skipped_tests.sh: 'cygport $cygport_file vars ...' returned nothing -- can't locate the check log" >&2
  exit 0
fi
eval "$vars_decl"

if [[ ! -f "${checklog:-}" ]]; then
  echo "detect_skipped_tests.sh: no check log at '${checklog:-(unset)}'" >&2
  exit 0
fi

max_lines=30

skipped_tests() {
  perl -pe 's/\e\[[0-9;]*m//g' "$checklog" | awk '
    # ctest: " 60/63 Test #60: test_cmd_stdin ......***Not Run (Disabled)   0.00 sec"
    /Test +#[0-9]+: .*\*\*\*(Skipped|Not Run)/ {
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
    # pytest: "=== 10 passed, 2 skipped in 1.23s ==="
    /^=+ .*[0-9]+ skipped/ { line = $0; gsub(/^=+ | =+$/, "", line); print "pytest: " line; next }
  '

  shopt -s nullglob globstar
  local log
  for log in "$workdir"/**/Testing/Temporary/LastTest.log; do
    perl -pe 's/\e\[[0-9;]*m//g' "$log" | awk '
      /^[0-9]+\/[0-9]+ Testing: / { name = $0; sub(/^[0-9]+\/[0-9]+ Testing: /, "", name); out = 0; n = 0; next }
      /^Output:$/ { out = 1; next }
      /^<end of output>$/ { out = 0; next }
      out && !/^\++ / && n < 2 {
        l = tolower($0)
        if (l ~ /(^|[^a-z_])skip(ped|ping|s)?([^a-z_]|$)/) {
          print name ": " $0; n++
        }
      }
    '
  done
}

report="$(skipped_tests | awk '!seen[$0]++')"
[[ -n "$report" ]] || exit 0

# Tests, not lines: LastTest.log can give one test two lines.
count="$(sed 's/: .*//' <<<"$report" | sort -u | wc -l | tr -d ' ')"
total_lines="$(wc -l <<<"$report" | tr -d ' ')"

output="check-skipped: $count test(s)"$'\n'"$(head -n "$max_lines" <<<"$report")"
if (( total_lines > max_lines )); then
  output+=$'\n'"... and $((total_lines - max_lines)) more line(s)"
fi

echo "$output"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  report_file="$(mktemp)"
  printf '%s\n' "$output" > "$report_file"
  {
    echo "count=$count"
    echo "report_file=$report_file"
  } >> "$GITHUB_OUTPUT"
fi
