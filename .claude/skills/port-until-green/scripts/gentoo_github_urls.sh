#!/usr/bin/env bash
# Rewrites a recipe's gitweb.gentoo.org URLs to the GitHub mirror,
# pinned to a commit:
#
#   https://gitweb.gentoo.org/repo/gentoo.git/plain/<path>[?id=<sha>]
#     -> https://raw.githubusercontent.com/gentoo/gentoo/<sha>/<path>
#   https://gitweb.gentoo.org/repo/proj/guru.git/plain/<path>[?id=<sha>]
#     -> https://raw.githubusercontent.com/gentoo/guru/<sha>/<path>
#
# gitweb.gentoo.org answers 503 ("No healthy backends") often enough to
# fail cygport prep on a recipe that hasn't changed (zopfli 1.0.3-1bl2's
# deploy, run 45738880501, twice in a row); GitHub's mirror is the same
# repository. An unpinned URL (no ?id=) gets the newest commit that
# touched the file -- the content master's gitweb would serve -- or, when
# that commit deleted it, that commit's parent. A ?id= keeps its commit.
#
# ${PN}, ${PV}, ${P}, ${PF}, ${PR}, ${PVR} in the path are expanded from
# the .cygport's file name to look the file up, and kept as written in
# the recipe. A URL with anything else to expand, a file the mirror
# doesn't have at that commit, or another gitweb repository is left as
# it is and reported on stderr (exit status 1).
#
# Usage: gentoo_github_urls.sh --file path/to/<pkg>-<ver>-<rel>.cygport [--dry-run]
# Prints "<old> -> <new>" for each URL rewritten (or that would be, with
# --dry-run); nothing when the recipe has none.

set -euo pipefail

file=""
dry_run=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --file) file="$2"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done
[[ -f "$file" ]] || { echo "--file: no such file: $file" >&2; exit 1; }

PF="$(basename "$file" .cygport)"
PR="${PF##*-}"
PVR="${PF%-*}"          # <pkg>-<ver>; a version has no dash, a name may
PV="${PVR##*-}"
PN="${PVR%-*}"
P="$PN-$PV"
PVR="$PV-$PR"

expand() {
  local s="$1" v
  for v in PN PV P PF PR PVR; do
    s="${s//\$\{$v\}/${!v}}"
  done
  printf '%s' "$s"
}

# Whether <owner>/<repo> has <path> at <sha>.
has_file() {
  gh api "repos/$1/contents/$3?ref=$2" --jq '.type' >/dev/null 2>&1
}

status=0
while IFS= read -r url; do
  [[ -n "$url" ]] || continue
  rest="${url#*://gitweb.gentoo.org/}"
  case "$rest" in
    repo/gentoo.git/plain/*) mirror=gentoo/gentoo; path="${rest#repo/gentoo.git/plain/}" ;;
    repo/proj/guru.git/plain/*) mirror=gentoo/guru; path="${rest#repo/proj/guru.git/plain/}" ;;
    *) echo "left as is (no GitHub mirror known): $url" >&2; status=1; continue ;;
  esac
  sha=""
  if [[ "$path" == *\?* ]]; then
    query="${path#*\?}"
    path="${path%%\?*}"
    if [[ "$query" =~ (^|[\;\&])id=([0-9a-f]{40})($|[\;\&]) ]]; then
      sha="${BASH_REMATCH[2]}"
    else
      echo "left as is (query other than a full ?id=): $url" >&2; status=1; continue
    fi
  fi
  xpath="$(expand "$path")"
  if [[ "$xpath" == *'$'* ]]; then
    echo "left as is (can't expand $xpath): $url" >&2; status=1; continue
  fi
  if [[ -z "$sha" ]]; then
    sha="$(gh api "repos/$mirror/commits?path=$xpath&per_page=1" --jq '.[0].sha // empty' 2>/dev/null)" || sha=""
    [[ -n "$sha" ]] || { echo "left as is ($mirror has no commit touching $xpath): $url" >&2; status=1; continue; }
    if ! has_file "$mirror" "$sha" "$xpath"; then
      # The newest commit removed it: the one before still has it.
      sha="$(gh api "repos/$mirror/commits/$sha" --jq '.parents[0].sha' 2>/dev/null)" || sha=""
    fi
  fi
  if [[ -z "$sha" ]] || ! has_file "$mirror" "$sha" "$xpath"; then
    echo "left as is ($mirror has no $xpath at ${sha:-?}): $url" >&2; status=1; continue
  fi
  new="https://raw.githubusercontent.com/$mirror/$sha/$path"
  echo "$url -> $new"
  [[ -n "$dry_run" ]] && continue
  OLD="$url" NEW="$new" perl -pi -e 's/\Q$ENV{OLD}\E(?=[\s"\x27#]|$)/$ENV{NEW}/g' "$file"
done < <(grep -oE 'https?://gitweb\.gentoo\.org/[^[:space:]"#'\'']+' "$file" | sort -u)

exit "$status"
