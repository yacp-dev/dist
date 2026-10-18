#!/usr/bin/env bash
# Finds the open `build-failed` Issue (doc/spec.md 4.5) for a given
# package, if one exists. Shared by report_build_failure.sh (reuse instead
# of piling up a duplicate Issue on every repeat failure) and
# close_failure_issue.sh (close it once a later build succeeds).
# --label switches to another label using the same dorgann-meta shape,
# e.g. check_update_blocked.sh's `update-blocked` (doc/spec.md 4.7).
#
# Issues are matched by the package field inside their `dorgann-meta` HTML
# comment -- a literal JSON substring match, not a regex or a title search
# -- since doc/spec.md 4.5 treats that comment as the source of truth for
# machine parsing (the title also carries the version, so it changes on
# every failure, and a Markdown table can be mis-parsed if formatting
# breaks). JSON is decoded with jq --arg rather than interpolated into a
# jq program string, so a package name can't break out of the filter.
#
# Usage: find_failure_issue.sh --repo yacp-dev/dist --package foo [--label build-failed]
# Output: the issue number on stdout if found; nothing (exit 0) if not.

set -euo pipefail

repo=""
package=""
label="build-failed"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --package) package="$2"; shift 2 ;;
    --label) label="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$repo" ]] || { echo "--repo is required" >&2; exit 1; }
[[ -n "$package" ]] || { echo "--package is required" >&2; exit 1; }

needle="\"package\":\"$package\""

# tr -d '\r' at the end: on windows-latest, gh/jq here are native Windows
# binaries piped through Cygwin bash, and one of them writes CRLF line
# endings even to a pipe -- confirmed by a real run, where the captured
# issue number came out as "1\r" (command substitution only strips
# trailing newlines, not embedded carriage returns), and gh issue
# edit/close then rejected it outright ('invalid issue format: "1\r"').
gh issue list --repo "$repo" --label "$label" --state open --limit 100 --json number,body |
  jq -r --arg needle "$needle" '.[] | select(.body | contains($needle)) | .number' |
  head -n1 |
  tr -d '\r'
