#!/usr/bin/env bash
# Step 1's `latest` lookup: the newest upstream version of a ports package
# on Repology. The project name is the ports name lowercased, unless
# repology_names.tsv (next to this script) maps it to another.
#
# Usage:
#   repology_newest.sh --package knot [--current 3.6.1]
# Output:
#   project: <name>          (the one to pass to distro_patches.sh --project)
#   note: <text>             from repology_names.tsv, if any
#   newest: <ver> (<N> repo(s): <repos>)   one line per distinct version;
#                            more than one, or one that looks like a
#                            prerelease or a distro fork, is for the user
#   version: <ver>           the newest with `_` normalized to `.`, when
#                            there's exactly one
#   current: <ver> up to date | bump <ver> -> <newest>   with --current
# Exit 3 when Repology has no such project: it prints projects whose
# name contains the package's, to try (and add to repology_names.tsv)
# before asking the user.

set -euo pipefail

pkg="" current=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --package) pkg="$2"; shift 2 ;;
    --current) current="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done
[[ -n "$pkg" ]] || { echo "--package is required" >&2; exit 1; }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project="$(printf '%s' "$pkg" | tr '[:upper:]' '[:lower:]')"
note=""
if line="$(awk -F'\t' -v p="$pkg" '!/^#/ && $1 == p' "$here/repology_names.tsv")" && [[ -n "$line" ]]; then
  IFS=$'\t' read -r _ project note <<<"$line"
fi

ua="port-until-green"
entries="$(curl -sf -A "$ua" "https://repology.org/api/v1/project/$project")" || {
  echo "Repology didn't answer for $project" >&2; exit 1; }

echo "project: $project"
[[ -n "$note" ]] && echo "note: $note"

if [[ "$entries" == "[]" ]]; then
  echo "no Repology project named $project; projects containing it (also try a shorter name, e.g. catch for Catch2):"
  curl -sf -A "$ua" "https://repology.org/api/v1/projects/?search=$project" |
    jq -r 'keys[]' | head -n 15 | sed 's/^/  /'
  exit 3
fi

newest="$(jq -r '
  [.[] | select(.status == "newest")] | group_by(.version)
  | map({v: .[0].version, n: length, r: ([.[].repo] | unique | .[:4] | join(" "))})
  | sort_by(-.n)[] | "\(.v)\t\(.n)\t\(.r)"' <<<"$entries")"
if [[ -z "$newest" ]]; then
  echo "newest: none (no repository marks a version newest: check upstream's releases by hand)"
  exit 0
fi
awk -F'\t' '{ print "newest: " $1 " (" $2 " repo(s): " $3 ")" }' <<<"$newest"
(( $(wc -l <<<"$newest") == 1 )) || exit 0

ver="$(cut -f1 <<<"$newest" | tr '_' '.')"
echo "version: $ver"
if [[ -n "$current" ]]; then
  if [[ "$current" == "$ver" ]]; then
    echo "current: $current up to date"
  else
    echo "current: bump $current -> $ver"
  fi
fi
