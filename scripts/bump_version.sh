#!/usr/bin/env bash
# Renames a package's `.cygport` file (and any sibling files sharing the same
# versioned basename, e.g. `<PN>-<PV>-<PR>.src.patch`) to a new version, using
# util-linux's `rename` for the filename change and `perl` for a best-effort
# substitution of the old bare version string inside each file's content (for
# cases where SRC_URI etc. hardcode the version instead of referencing ${PV}).
# `rename` comes from the Cygwin `util-linux` package; `perl` is already
# pulled in as a dependency of `cygport` itself.
#
# This does NOT replace `xezat bump` (which only regenerates README/changelog
# after a build) -- xezat has no command that performs this rename itself.
#
# Usage:
#   bump_version.sh --dir yacp/googletest --version 1.18.0
#
# Input: CLI args only (no GitHub Actions context dependency, so this can be
# run and debugged locally, given a Cygwin-flavored `rename`/`sed` on PATH).
# Output: prints the new .cygport basename, and if GITHUB_OUTPUT is set,
# appends `cygport_file=<basename>` and `version=<new_version>` there --
# the latter mirrors detect_cygport_file.sh's own `version` output, so
# build-package.yml can read whichever of the two actually ran without
# caring which one it was (branch-rebuild mode, doc/spec.md 4.6).

set -euo pipefail

dir=""
new_version=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) dir="$2"; shift 2 ;;
    --version) new_version="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$dir" ]] || { echo "--dir is required" >&2; exit 1; }
[[ -n "$new_version" ]] || { echo "--version is required" >&2; exit 1; }
[[ -d "$dir" ]] || { echo "No such directory: $dir" >&2; exit 1; }

# yacp convention: the package directory name equals PN. Resolve this before
# cd'ing so it works for relative --dir arguments too.
pn="$(basename "$(cd "$dir" && pwd)")"

cd "$dir"

shopt -s nullglob
cygport_files=(*.cygport)
shopt -u nullglob
if [[ ${#cygport_files[@]} -ne 1 ]]; then
  echo "Expected exactly one .cygport file in $dir, found ${#cygport_files[@]}: ${cygport_files[*]}" >&2
  exit 1
fi

old_basename="${cygport_files[0]%.cygport}"

prefix="${pn}-"
if [[ "$old_basename" != "$prefix"* ]]; then
  echo "cygport filename $old_basename does not start with package name $pn" >&2
  exit 1
fi

# "<PN>-<PV>-<PR>.cygport" -> strip "<PN>-" prefix, then drop the trailing "-<PR>" segment.
rest="${old_basename#"$prefix"}"
old_version="${rest%-*}"
if [[ -z "$old_version" || "$old_version" == "$rest" ]]; then
  echo "Could not parse a version out of cygport filename $old_basename" >&2
  exit 1
fi

if [[ "$old_version" == "$new_version" ]]; then
  echo "Package $pn is already at version $new_version" >&2
  exit 1
fi

# Release is reset to "1bl1" on a version bump. The "bl" marker distinguishes
# this build from the official Cygwin package of the same name/version.
# Packages that need a different release suffix are expected to be adjusted
# by hand afterwards.
new_basename="${pn}-${new_version}-1bl1"

# Every sibling file sharing the old versioned basename (the .cygport file
# itself, plus companions like "<PN>-<PV>-<PR>.src.patch") gets the old
# version substituted in its content, then all of them get renamed in one
# batch. Files that don't follow this versioned naming (e.g. README) are
# left untouched.
#
# The match is literal (\Q...\E) and bounded: not preceded by a digit or
# dot, and not followed by a digit or a dot+digit. A plain
# `sed s/$old/$new/g` treated the version's dots as regex wildcards and
# had no boundaries, so 1.0.3 matched the "130,3" in a .src.patch hunk
# header (`@@ -130,3 ...`), corrupting it (confirmed by a real run:
# libdecaf 1.0.5) -- and a dotless version like 14 would match any line
# number or literal containing it.
#
# In a .src.patch only the ---/+++ header lines' top directory
# (origsrc/<SRC_DIR>/, src/<SRC_DIR>/) is touched -- that's the only place
# `cygport diff` itself puts the version. SRC_DIR isn't always <PN>-<PV>
# (e.g. abPOA-1.5.6, aespipe-v2.4j), so the version is matched within that
# component rather than the whole component being rebuilt. Hunk contents
# are left alone: rewriting a version that appears in the patched code
# itself is never what the recipe meant.
shopt -s nullglob
sibling_files=("$old_basename".*)
shopt -u nullglob

version_re='(?<![0-9.])\Q$ENV{OLD}\E(?![0-9]|\.[0-9])'
for f in "${sibling_files[@]}"; do
  if [[ "$f" == *.src.patch ]]; then
    OLD="$old_version" NEW="$new_version" perl -pi -e \
      "s{^((?:---|\\+\\+\\+) (?:origsrc|src)/)([^/]*)}{my (\$p, \$d) = (\$1, \$2); \$p . (\$d =~ s/${version_re}/\$ENV{NEW}/gr)}e" "$f"
  else
    OLD="$old_version" NEW="$new_version" perl -pi -e "s/${version_re}/\$ENV{NEW}/g" "$f"
  fi
done

rename -- "$old_basename" "$new_basename" "${sibling_files[@]}"

new_cygport_file="${new_basename}.cygport"
echo "Bumped $pn: $old_version -> $new_version (${#sibling_files[@]} file(s))"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "cygport_file=$new_cygport_file"
    echo "version=$new_version"
  } >> "$GITHUB_OUTPUT"
fi
