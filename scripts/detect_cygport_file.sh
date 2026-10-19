#!/usr/bin/env bash
# Finds the single `.cygport` file already present in --dir and extracts
# its version, for branch-rebuild mode (an existing branch for
# build-package.yml's target): when re-running a build against an existing
# `dorgann/<pkg>-<ver>` branch that a human has already amended by hand
# (e.g. adding a missing BUILD_REQUIRES, or renaming PKG_NAMES for an ABI
# bump) directly on yacp, the file is already at its target name --
# there's nothing left to rename, unlike bump_version.sh's fresh-bump path
# (this script is read-only; bump_version.sh is the one that renames).
#
# Version parsing mirrors bump_version.sh's own "<PN>-<PV>-<PR>.cygport"
# convention, so the two scripts agree on what counts as PV.
#
# Usage: detect_cygport_file.sh --dir yacp/libucl
# Output: prints "<cygport_file> <version>" to stdout, and if
# GITHUB_OUTPUT is set, also appends cygport_file=.../version=... there.

set -euo pipefail

dir=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) dir="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$dir" ]] || { echo "--dir is required" >&2; exit 1; }
[[ -d "$dir" ]] || { echo "No such directory: $dir" >&2; exit 1; }

pn="$(basename "$(cd "$dir" && pwd)")"

cd "$dir"

shopt -s nullglob
cygport_files=(*.cygport)
shopt -u nullglob
if [[ ${#cygport_files[@]} -ne 1 ]]; then
  echo "Expected exactly one .cygport file in $dir, found ${#cygport_files[@]}: ${cygport_files[*]}" >&2
  exit 1
fi

cygport_file="${cygport_files[0]}"
basename_noext="${cygport_file%.cygport}"

prefix="${pn}-"
if [[ "$basename_noext" != "$prefix"* ]]; then
  echo "cygport filename $basename_noext does not start with package name $pn" >&2
  exit 1
fi

rest="${basename_noext#"$prefix"}"
version="${rest%-*}"
if [[ -z "$version" || "$version" == "$rest" ]]; then
  echo "Could not parse a version out of cygport filename $basename_noext" >&2
  exit 1
fi

echo "$cygport_file $version"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "cygport_file=$cygport_file"
    echo "version=$version"
  } >>"$GITHUB_OUTPUT"
fi
