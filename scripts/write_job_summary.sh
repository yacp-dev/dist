#!/usr/bin/env bash
# Writes a short "what happened" summary (yacp PR link, diagnostics) to
# $GITHUB_STEP_SUMMARY, which GitHub renders as Markdown
# right at the top of the run page -- unlike a plain log line, which
# stays buried until someone opens this specific job and finds the right
# step.
#
# A real script file rather than an inline `run: |` block on purpose
# (doc/spec.md 5's own policy) -- the first attempt inlined this directly
# in build-package.yml and hit a real CRLF failure: `shell: bash` on this
# runner resolves to Cygwin's own (strict, CRLF-intolerant) bash once
# Cygwin is installed, but the temp script GitHub's own runner generates
# for a multi-line `run: |` block is written CRLF on Windows -- fine for
# the more lenient Git-for-Windows bash every *other* step in this
# workflow defaults to, fatal for Cygwin's ("line 1: $'{\r': command not
# found", confirmed by a real run). A checked-out script file doesn't
# have this problem: .gitattributes already guarantees it's LF, and it's
# invoked the same single-line `bash -- scripts/foo.sh` way as every
# other script in this workflow.
#
# pr_url is meant to be the concatenation of the (at most one non-empty)
# Create Pull Request/Create draft Pull Request step outputs in
# build-package.yml -- whichever mutually exclusive success/failure-path
# step actually ran is the one whose output survives -- so an empty
# string here just means there's no PR for this run, not an error.
#
# artifact_id is Upload dist artifact's own step output -- always passed
# when set, but only worth printing a ready-to-run publish command for
# when there's no PR (deploy mode, doc/spec.md 4.4.2's "semi-automated"
# path assumes a PR body carries this same command otherwise, e.g. Create
# Pull Request's own body already includes it) -- otherwise this would
# just be a redundant duplicate of what the PR body already says.
#
# audit_file/audit_warnings/audit_open are Audit recipe's outputs: the
# one report on the build (undefined autoconf macros, what cygport check
# did) and the recipe. It's shown whenever there is one, opened when
# audit_open says something in it is worth a look, and capped at
# diagnostic_max_bytes, since a step summary over 1 MiB isn't shown at
# all; the full report stays in Audit recipe's own log, which the
# truncation note points to.
#
# audit_oks_file/audit_oks_count are what Audit recipe checked and found
# fine, for looking over for a false negative: always folded, capped the
# same way, and shown even when the report itself is empty.
#
# Layout: a two-column table (package, version, tests, PR, ...) instead of
# a heading, then what the audit found as NG/OK blocks, each a heading
# with its content (the report's "== Section ==" blocks, and the
# "ok: Section: ..." lines grouped by Section). Deciding what needs fixing
# is left to whoever reads it (port-until-green's Claude): this only lays
# the findings out.
#
# With --pr-body-file it writes the same report, wrapped for a PR body
# (--pr-kind ready: dorgann-meta and the publish command; draft: how to
# retry a failed build), to that file instead of the step summary, in
# half the space a PR body has to spare.
#
# Usage:
#   write_job_summary.sh --package foo --pr-url <url-or-empty> [--version <v>] [--mode <mode>] [--artifact-id <id-or-empty>] [--audit-file <path-or-empty>] [--audit-warnings <n-or-empty>] [--audit-open <true-or-empty>] [--audit-oks-file <path-or-empty>] [--audit-oks-count <n-or-empty>] [--check <verdict-or-empty>] [--check-tests <str-or-empty>] [--check-skipped <n-or-empty>] [--check-upstream-tests <str-or-empty>] [--dropped-files <files-or-empty>] [--run-url <url>] [--pr-body-file <path> [--pr-kind ready|draft]]

set -euo pipefail

package=""
pr_url=""
version=""
mode=""
artifact_id=""
audit_file=""
audit_warnings=""
audit_open=""
audit_oks_file=""
audit_oks_count=""
check=""
check_tests=""
check_skipped=""
check_upstream_tests=""
dropped_files=""
run_url=""
pr_body_file=""
pr_kind="ready"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --package) package="$2"; shift 2 ;;
    --pr-url) pr_url="$2"; shift 2 ;;
    --version) version="$2"; shift 2 ;;
    --mode) mode="$2"; shift 2 ;;
    --artifact-id) artifact_id="$2"; shift 2 ;;
    --audit-file) audit_file="$2"; shift 2 ;;
    --audit-warnings) audit_warnings="$2"; shift 2 ;;
    --audit-open) audit_open="$2"; shift 2 ;;
    --audit-oks-file) audit_oks_file="$2"; shift 2 ;;
    --audit-oks-count) audit_oks_count="$2"; shift 2 ;;
    --check) check="$2"; shift 2 ;;
    --check-tests) check_tests="$2"; shift 2 ;;
    --check-skipped) check_skipped="$2"; shift 2 ;;
    --check-upstream-tests) check_upstream_tests="$2"; shift 2 ;;
    --dropped-files) dropped_files="$2"; shift 2 ;;
    --run-url) run_url="$2"; shift 2 ;;
    --pr-body-file) pr_body_file="$2"; shift 2 ;;
    --pr-kind) pr_kind="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$package" ]] || { echo "--package is required" >&2; exit 1; }
[[ -n "$pr_body_file" || -n "${GITHUB_STEP_SUMMARY:-}" ]] || { echo "GITHUB_STEP_SUMMARY must be set (or give --pr-body-file)" >&2; exit 1; }

diagnostic_max_bytes=200000
# A PR body is limited to 65536 characters, and the NG and OK blocks each
# get diagnostic_max_bytes: for a PR body, half of that budget with each
# block cut at block_max_lines (a failing check's log is the long one).
# Lines and bytes are capped per block too, so that a block ends with its
# closing fence instead of being cut mid-block by print_bounded (a failing
# check's log has lines of a kilobyte: the compiler command lines).
block_max_lines=0
block_max_bytes=0
line_max_chars=0
if [[ -n "$pr_body_file" ]]; then
  diagnostic_max_bytes=25000
  block_max_lines=100
  block_max_bytes=8000
  line_max_chars=300
fi

# Prints $1, or if it's over diagnostic_max_bytes, its first that many
# bytes minus the last (possibly cut mid-line, or mid-character) line,
# followed by a note saying where the rest is.
print_bounded() {
  local file="$1" size
  size="$(wc -c <"$file" | tr -d ' ')"
  if (( size <= diagnostic_max_bytes )); then
    cat "$file"
  else
    head -c "$diagnostic_max_bytes" "$file" | sed '$d'
    printf '[... truncated: %s of %s bytes shown -- the full report is in the Audit recipe step'\''s own log]\n' \
      "$diagnostic_max_bytes" "$size"
  fi
}

# The Tests cell: the verdict, the runner's totals, what was skipped and,
# for a check that ran nothing, whether upstream has tests.
tests_cell() {
  local cell=""
  case "$check" in
    passed) cell="✅ passed" ;;
    failed) cell="❌ failed" ;;
    empty)  cell="⚠️ no tests ran" ;;
    unknown) cell="❓ unknown" ;;
    *) echo "-"; return ;;
  esac
  [[ -z "$check_tests" ]] || cell+=" -- $check_tests"
  [[ -z "$check_skipped" ]] || cell+=", $check_skipped skipped"
  [[ -z "$check_upstream_tests" ]] || cell+="; ⚠️ upstream has tests, not run ($check_upstream_tests)"
  echo "$cell"
}

# Section names are the audit's own, and two are file patterns; the
# summary names the check instead.
TITLES='function title(n) {
  if (n == "*.pc") return "pkg-config"
  if (n == "*-config") return "Config scripts"
  return n
}'

# Splits the report into "== Section ==" blocks, each a "#### Section"
# heading and a code block. mode=ng prints the blocks with a WARNING line,
# and the Check section unless it passed and skipped nothing; mode=info
# prints the others (a section that only says what it looked at: LICENSE,
# BUILD_REQUIRES' "probably used", "nothing downloaded"). Drops the
# closing "N warning(s)." line, which the table already says.
render_sections() {
  awk -v mode="$1" -v check="$check" -v skipped="$check_skipped" -v cap="$block_max_lines" \
      -v bcap="$block_max_bytes" -v lmax="$line_max_chars" "$TITLES"'
    function flush(  i, bad, last, bytes, line) {
      if (name == "") return
      while (n > 0 && buf[n] == "") n--
      bad = warned || (name == "Check" && !(check == "passed" && skipped == ""))
      if ((mode == "ng") == (bad ? 1 : 0)) {
        printf "\n#### %s\n```\n", title(name)
        last = (cap > 0 && n > cap) ? cap : n
        bytes = 0
        for (i = 1; i <= last; i++) {
          line = buf[i]
          if (lmax > 0 && length(line) > lmax) line = substr(line, 1, lmax) " ..."
          if (bcap > 0 && bytes + length(line) + 1 > bcap) { last = i - 1; break }
          bytes += length(line) + 1
          print line
        }
        if (last < n) printf "... (%d more line(s); the full text is in the run summary)\n", n - last
        print "```"
      }
      name = ""; n = 0; warned = 0
    }
    /^== .* ==$/ { flush(); name = $0; sub(/^== /, "", name); sub(/ ==$/, "", name); next }
    /^[0-9]+ warning\(s\)\./ { next }
    name != "" { buf[++n] = $0; if ($0 ~ /^WARNING: /) warned = 1 }
    END { flush() }
  ' "$2"
}

# Counts the blocks in $1.
count_headings() { grep -c '^#### ' <<<"$1" || true; }

# "ok: Section: text" lines grouped by Section into "#### Section" and a
# code block of the texts.
render_ok() {
  awk "$TITLES"'
    /^ok: / {
      line = substr($0, 5); sec = line; txt = line
      if (index(line, ": ")) { sec = substr(line, 1, index(line, ": ") - 1); txt = substr(line, index(line, ": ") + 2) }
      else sec = "Other"
      sec = title(sec)
      if (!(sec in items)) order[++k] = sec
      items[sec] = items[sec] txt "\n"
    }
    END {
      for (i = 1; i <= k; i++) {
        printf "\n#### %s\n```\n%s```\n", order[i], items[order[i]]
      }
    }
  ' "$1"
}

report_body() {
  echo "| | |"
  echo "|---|---|"
  echo "| **package** | $package |"
  if [[ -n "$version" ]]; then
    echo "| **version** | $version$([[ "$mode" == new ]] && echo " (new)") |"
  fi
  echo "| **tests** | $(tests_cell) |"
  if [[ -n "$audit_warnings" ]]; then
    echo "| **audit** | ⚠️ $audit_warnings warning(s) |"
  elif [[ -n "$audit_open" ]]; then
    echo "| **audit** | ⚠️ see the report below |"
  else
    echo "| **audit** | ✅ |"
  fi
  if [[ -n "$pr_url" ]]; then
    echo "| **PR** | $pr_url |"
  fi
  if [[ -z "$pr_body_file" && -n "$artifact_id" && -z "$pr_url" ]]; then
    echo "| **dist artifact** | $artifact_id (no PR was created -- deploy mode) |"
    echo
    echo "To publish this build to gh-pages:"
    echo '```'
    echo "gh workflow run publish.yml -f artifact_id=$artifact_id --repo ${GITHUB_REPOSITORY:-yacp-dev/dist}"
    echo '```'
  fi
  ng_tmp="$(mktemp)"
  [[ -z "$audit_file" || ! -s "$audit_file" ]] || render_sections ng "$audit_file" > "$ng_tmp"
  if [[ -n "$dropped_files" ]]; then
    {
      echo
      echo "#### .src.patch lost changes"
      echo '```'
      echo "cygport diff left these files out of the regenerated .src.patch, though the recipe's own patch changed them."
      echo "This build had the changes; the committed recipe won't. Move them into a PATCH_URI patch of their own:"
      for f in $dropped_files; do echo "  $f"; done
      echo '```'
    } >> "$ng_tmp"
  fi
  if [[ -s "$ng_tmp" ]]; then
    echo
    echo "<details${audit_open:+ open}><summary>❌ NG ($(count_headings "$(cat "$ng_tmp")"))</summary>"
    print_bounded "$ng_tmp"
    echo
    echo "</details>"
  fi
  rm -f "$ng_tmp"
  ok_tmp="$(mktemp)"
  [[ -z "$audit_file" || ! -s "$audit_file" ]] || render_sections info "$audit_file" >> "$ok_tmp"
  [[ -z "$audit_oks_file" || ! -s "$audit_oks_file" ]] || render_ok "$audit_oks_file" >> "$ok_tmp"
  if [[ -s "$ok_tmp" ]]; then
    echo
    echo "<details><summary>✅ OK ($(count_headings "$(cat "$ok_tmp")"))</summary>"
    print_bounded "$ok_tmp"
    echo
    echo "</details>"
  fi
  rm -f "$ok_tmp"
}

if [[ -z "$pr_body_file" ]]; then
  report_body >> "$GITHUB_STEP_SUMMARY"
  exit 0
fi

# The PR body: the same report, with what a reader of the PR needs around
# it. A failed build's draft PR says how to retry; a built one carries the
# dorgann-meta comment publish.yml reads (doc/spec.md 4.4.1) and the
# publish command.
repo="${GITHUB_REPOSITORY:-yacp-dev/dist}"
{
  if [[ "$pr_kind" == draft ]]; then
    echo "Version \`$version\`, but the build failed -- see the report below and the run log for what's wrong."
    echo
    echo "Push a fix directly onto this branch (\`dorgann/$package-$version\`), then re-run the build against it:"
    echo '```'
    echo "gh workflow run build-package.yml -f target=$package-$version --repo $repo"
    echo '```'
    echo
  fi
  report_body
  echo
  [[ -z "$run_url" ]] || { echo "Run: $run_url"; echo; }
  if [[ "$pr_kind" != draft ]]; then
    echo "<!-- dorgann-meta: {\"artifact_id\":\"$artifact_id\"} -->"
    echo
    echo "To publish this build to gh-pages:"
    echo '```'
    echo "gh workflow run publish.yml -f artifact_id=$artifact_id --repo $repo"
    echo '```'
  fi
} > "$pr_body_file"
