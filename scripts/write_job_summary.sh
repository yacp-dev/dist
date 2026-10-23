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
# macro_diagnostic_file is Diagnose undefined macro's output, set only
# when cygport compile failed and there was something to diagnose. It and
# check_diagnostic_file are capped at diagnostic_max_bytes, since a step
# summary over 1 MiB isn't shown at all. The diagnose scripts also print
# their full output to their own step's log, which the truncation note
# points to.
#
# check_diagnostic_file is Diagnose check failure's output, set only when
# cygport check failed -- which, being continue-on-error, nothing else
# on a green run shows.
#
# audit_file/audit_warnings are Audit recipe's outputs; the report is
# shown whenever there is one, opened when it has warnings.
#
# Usage:
#   write_job_summary.sh --package foo --pr-url <url-or-empty> [--artifact-id <id-or-empty>] [--macro-diagnostic-file <path-or-empty>] [--check-diagnostic-file <path-or-empty>] [--audit-file <path-or-empty>] [--audit-warnings <n-or-empty>]

set -euo pipefail

package=""
pr_url=""
artifact_id=""
macro_diagnostic_file=""
check_diagnostic_file=""
audit_file=""
audit_warnings=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --package) package="$2"; shift 2 ;;
    --pr-url) pr_url="$2"; shift 2 ;;
    --artifact-id) artifact_id="$2"; shift 2 ;;
    --macro-diagnostic-file) macro_diagnostic_file="$2"; shift 2 ;;
    --check-diagnostic-file) check_diagnostic_file="$2"; shift 2 ;;
    --audit-file) audit_file="$2"; shift 2 ;;
    --audit-warnings) audit_warnings="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$package" ]] || { echo "--package is required" >&2; exit 1; }
[[ -n "${GITHUB_STEP_SUMMARY:-}" ]] || { echo "GITHUB_STEP_SUMMARY must be set" >&2; exit 1; }

diagnostic_max_bytes=200000

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
    printf '[... truncated: %s of %s bytes shown -- the full diagnostic is in the diagnose step'\''s own log]\n' \
      "$diagnostic_max_bytes" "$size"
  fi
}

# Prints a collapsible block of file $2 titled $1 when $2 is a non-empty
# file; $3 is "open" to show it expanded.
print_details() {
  local title="$1" file="$2" open="${3:-}"
  [[ -n "$file" && -s "$file" ]] || return 0
  echo
  echo "<details${open:+ open}><summary>$title</summary>"
  echo
  echo '```'
  print_bounded "$file"
  echo '```'
  echo
  echo "</details>"
}

{
  echo "### dorgann: $package"
  echo
  if [[ -n "$pr_url" ]]; then
    echo "- yacp PR: $pr_url"
  fi
  if [[ -n "$artifact_id" && -z "$pr_url" ]]; then
    echo "- dist artifact: $artifact_id (no PR was created -- deploy mode)"
    echo
    echo "To publish this build to gh-pages:"
    echo '```'
    echo "gh workflow run publish.yml -f artifact_id=$artifact_id --repo ${GITHUB_REPOSITORY:-yacp-dev/dist}"
    echo '```'
  fi
  print_details "cygport compile failed: undefined autoconf macros" "$macro_diagnostic_file" open
  print_details "cygport check failed (non-blocking)" "$check_diagnostic_file"
  if [[ -n "$audit_file" && -s "$audit_file" ]]; then
    echo
    if [[ -n "$audit_warnings" ]]; then
      echo "<details open><summary>Recipe audit: $audit_warnings warning(s)</summary>"
    else
      echo "<details><summary>Recipe audit: no warnings</summary>"
    fi
    echo
    echo '```'
    cat "$audit_file"
    echo '```'
    echo
    echo "</details>"
  fi
} >> "$GITHUB_STEP_SUMMARY"
