#!/usr/bin/env bash
# Builds the commit message build-package.yml gives the bot's squash commit
# (peter-evans/create-pull-request's `commit-message`). yacp only
# rebase-merges, so this title is what lands in its history.
#
#   <pkg>-<ver>                           plain version bump
#   <pkg>-<ver> (<changelog>)             the README's changelog entry is
#                                         something other than "Version bump."
#                                         (first letter lowercased, no
#                                         trailing period), e.g.
#                                         "Rebuild with gcc-14.4.0" ->
#                                         "pkg-1.2.3 (rebuild with gcc-14.4.0)"
#   <pkg>-<ver> (WIP)                     cygport check failed
#   <pkg>-<ver> (<changelog> / WIP)       both
#
# The PR title stays plain `<pkg>-<ver>`.
#
# Usage:
#   commit_message.sh --package P --version V [--message "Rebuild"] [--wip true]
# Output: prints the message; if GITHUB_OUTPUT is set, appends
# `message=<message>` there too.

set -euo pipefail

package=""
version=""
message=""
wip="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --package) package="$2"; shift 2 ;;
    --version) version="$2"; shift 2 ;;
    --message) message="$2"; shift 2 ;;
    --wip) wip="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$package" ]] || { echo "--package is required" >&2; exit 1; }
[[ -n "$version" ]] || { echo "--version is required" >&2; exit 1; }

# Trim whitespace (and a stray CR from a Windows runner) and the trailing
# period, so "Version bump." and "Version bump" both mean "nothing to add".
message="${message//$'\r'/}"
message="${message#"${message%%[![:space:]]*}"}"
message="${message%"${message##*[![:space:]]}"}"
message="${message%.}"

extra=""
if [[ -n "$message" && "$message" != "Version bump" ]]; then
  extra="$(tr '[:upper:]' '[:lower:]' <<<"${message:0:1}")${message:1}"
fi

title="$package-$version"
if [[ -n "$extra" && "$wip" == "true" ]]; then
  title+=" ($extra / WIP)"
elif [[ -n "$extra" ]]; then
  title+=" ($extra)"
elif [[ "$wip" == "true" ]]; then
  title+=" (WIP)"
fi

echo "$title"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "message=$title" >> "$GITHUB_OUTPUT"
fi
