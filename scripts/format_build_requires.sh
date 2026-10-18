#!/usr/bin/env bash
# Rewrites a cygport file's BUILD_REQUIRES into yacp's one-package-per-
# line form, in place:
#
#   BUILD_REQUIRES="
#   	pkg-a
#   	pkg-b
#   "
#
# whatever form it was in before -- a single-line list
# (BUILD_REQUIRES="pkg-a pkg-b"), space-indented lines, or several
# packages on one line. Package order is kept as is (no sorting, no
# deduplication), so the only change is whitespace. Running it on an
# already-formatted file changes nothing, so build-package.yml runs it
# unconditionally and the change rides along in the PR's diff.
#
# A general-purpose shell formatter (shfmt etc.) can't do this: the value
# is a quoted string literal, whose contents a formatter never touches.
#
# Only a plain `BUILD_REQUIRES="..."` starting at column 0 is rewritten.
# A value with anything this script can't safely re-split -- a comment,
# a backslash, another quote, a command substitution, or text after the
# closing quote -- is left untouched (with a warning) rather than
# guessed at. `${VAR}` references are fine: they're single words.
#
# Usage (paths relative to the package directory, e.g. yacp/googletest):
#   format_build_requires.sh --dir yacp/googletest --file googletest-1.18.0-1bl1.cygport
# Output: prints whether the file changed.

set -euo pipefail

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

path="$dir/$cygport_file"
[[ -f "$path" ]] || { echo "No such file: $path" >&2; exit 1; }

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

# Plain POSIX awk (no gawk extensions), so this also runs against a local
# checkout on macOS for debugging.
awk -v sq="'" '
  function flush_raw(   i) {
    for (i = 1; i <= n; i++) print raw[i]
  }
  function emit(   i, m, words) {
    m = split(value, words, /[ \t\n]+/)
    # split() yields empty leading/trailing fields around the separators.
    count = 0
    for (i = 1; i <= m; i++) if (words[i] != "") count++
    if (count == 0) { flush_raw(); return }
    print "BUILD_REQUIRES=\""
    for (i = 1; i <= m; i++) if (words[i] != "") print "\t" words[i]
    print "\""
  }
  # Ends the current block: rest is whatever follows the closing quote.
  function close_block(rest) {
    if (rest !~ /^[ \t]*$/ || value ~ /[#\\`"]/ || index(value, sq) || value ~ /\$\(/) {
      printf "Leaving BUILD_REQUIRES at line %d as is: unexpected content\n", start > "/dev/stderr"
      flush_raw()
    } else {
      emit()
    }
    inblock = 0
  }
  function take(line,   q) {
    q = index(line, "\"")
    if (q == 0) { value = value "\n" line; return }
    value = value "\n" substr(line, 1, q - 1)
    close_block(substr(line, q + 1))
  }

  inblock { raw[++n] = $0; take($0); next }

  /^BUILD_REQUIRES="/ {
    inblock = 1; start = NR; n = 0; value = ""
    raw[++n] = $0
    rest = substr($0, length("BUILD_REQUIRES=\"") + 1)
    q = index(rest, "\"")
    if (q == 0) { value = rest }
    else { value = substr(rest, 1, q - 1); close_block(substr(rest, q + 1)) }
    next
  }

  { print }

  END {
    if (inblock) {
      printf "Leaving BUILD_REQUIRES at line %d as is: no closing quote\n", start > "/dev/stderr"
      flush_raw()
    }
  }
' "$path" >"$tmp"

if cmp -s "$path" "$tmp"; then
  echo "BUILD_REQUIRES in $cygport_file already one per line"
else
  cat "$tmp" >"$path"
  echo "Reformatted BUILD_REQUIRES in $cygport_file to one per line"
fi
