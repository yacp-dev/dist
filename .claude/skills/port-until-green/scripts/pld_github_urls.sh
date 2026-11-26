#!/usr/bin/env bash
# Rewrites a recipe's git.pld-linux.org file URLs to the GitHub mirror,
# pinned to a commit:
#
#   https://git.pld-linux.org/?p=packages/<repo>.git;a=blob_plain;f=<path>[;h=<blob>][;hb=<ref>][#/<name>]
#     -> https://raw.githubusercontent.com/pld-linux/<repo>/<sha>/<path>[#/<name>]
#
# git.pld-linux.org serves a bot challenge page (Anubis) instead of the
# file to non-browser clients, so cygport prep downloads HTML and the
# patch fails with "Only garbage was found in the patch input" (yasr
# 0.6.9-1bl4's preflight). GitHub's pld-linux organization mirrors the
# same package repositories.
#
# The commit: an hb= that is a full 40-digit SHA is kept. Otherwise, with
# an h= (the blob gitweb was asked for), the newest commit touching the
# file whose version of it is that blob; without one, the newest commit
# touching the file -- what gitweb's HEAD would serve -- or, when that
# commit deleted it, its parent. A #/<name> that only repeats the file's
# own name is dropped (the raw URL already ends in it); any other is kept.
#
# ${PN}, ${PV}, ${P}, ${PF}, ${PR}, ${PVR} in the repository and path are
# expanded from the .cygport's file name to look the file up, and kept as
# written in the recipe. A URL with anything else to expand, one that
# isn't a blob_plain/f= file URL, or a file the mirror doesn't have (at
# that blob) is left as it is and reported on stderr (exit status 1).
# Plain repository links (a HOMEPAGE such as ?p=packages/<pkg>.git) are
# not file URLs and are ignored.
#
# Usage: pld_github_urls.sh --file path/to/<pkg>-<ver>-<rel>.cygport [--dry-run]
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

# The blob SHA of <path> in <owner>/<repo> at <sha>; fails when absent.
blob_at() {
  gh api "repos/$1/contents/$3?ref=$2" --jq 'select(.type == "file") | .sha' 2>/dev/null | grep -E '^[0-9a-f]{40}$'
}

# The value of key <k> in a gitweb query string (; or & separated).
param() {
  local query="$1" k="$2" part
  local IFS=';&'
  for part in $query; do
    [[ "$part" == "$k="* ]] && { printf '%s' "${part#"$k="}"; return 0; }
  done
  return 1
}

status=0
while IFS= read -r url; do
  [[ -n "$url" ]] || continue
  base="${url%%#*}"
  rename=""
  [[ "$url" == *'#/'* ]] && rename="${url#*#/}"
  query="${base#*\?}"
  [[ "$query" != "$base" ]] || continue
  f="$(param "$query" f)" || continue          # not a file URL (a repository link)
  p="$(param "$query" p)" || { echo "left as is (no p=): $url" >&2; status=1; continue; }
  a="$(param "$query" a)" || a=""
  if [[ -n "$a" && "$a" != blob_plain ]]; then
    echo "left as is (a=$a, not blob_plain): $url" >&2; status=1; continue
  fi
  h="$(param "$query" h)" || h=""
  hb="$(param "$query" hb)" || hb=""
  if [[ "$p" != packages/*.git ]]; then
    echo "left as is (not a packages/<name>.git repository): $url" >&2; status=1; continue
  fi
  repo="${p#packages/}"; repo="${repo%.git}"
  xrepo="$(expand "$repo")"
  xpath="$(expand "$f")"
  if [[ "$xrepo$xpath" == *'$'* ]]; then
    echo "left as is (can't expand $xrepo/$xpath): $url" >&2; status=1; continue
  fi
  mirror="pld-linux/$xrepo"
  sha=""
  if [[ "$hb" =~ ^[0-9a-f]{40}$ ]]; then
    sha="$hb"
  else
    shas="$(gh api "repos/$mirror/commits?path=$xpath&per_page=100" --jq '.[].sha' 2>/dev/null)" || shas=""
    [[ -n "$shas" ]] || { echo "left as is ($mirror has no commit touching $xpath): $url" >&2; status=1; continue; }
    if [[ -n "$h" ]]; then
      for c in $shas; do
        if [[ "$(blob_at "$mirror" "$c" "$xpath" || true)" == "$h" ]]; then sha="$c"; break; fi
      done
      [[ -n "$sha" ]] || { echo "left as is ($mirror has no commit where $xpath is blob $h): $url" >&2; status=1; continue; }
    else
      sha="$(head -n1 <<<"$shas")"
      if ! blob_at "$mirror" "$sha" "$xpath" >/dev/null; then
        # The newest commit removed it: the one before still has it.
        sha="$(gh api "repos/$mirror/commits/$sha" --jq '.parents[0].sha' 2>/dev/null)" || sha=""
      fi
    fi
  fi
  blob="$( [[ -n "$sha" ]] && blob_at "$mirror" "$sha" "$xpath" || true)"
  if [[ -z "$blob" ]]; then
    echo "left as is ($mirror has no $xpath at ${sha:-?}): $url" >&2; status=1; continue
  fi
  if [[ -n "$h" && "$blob" != "$h" ]]; then
    echo "left as is ($xpath at $sha is blob $blob, not h=$h): $url" >&2; status=1; continue
  fi
  new="https://raw.githubusercontent.com/pld-linux/$repo/$sha/$f"
  if [[ -n "$rename" && "$(expand "$rename")" != "$(basename "$xpath")" ]]; then
    new+="#/$rename"
  fi
  echo "$url -> $new"
  [[ -n "$dry_run" ]] && continue
  OLD="$url" NEW="$new" perl -pi -e 's/\Q$ENV{OLD}\E(?=[\s"\x27]|$)/$ENV{NEW}/g' "$file"
done < <(grep -oE 'https?://git\.pld-linux\.org/[^[:space:]"'\'']+' "$file" | sort -u)

exit "$status"
