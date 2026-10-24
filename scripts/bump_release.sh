#!/usr/bin/env bash
# Bumps a package's cygport release number in place, for a same-version
# "rebuild" (build-package.yml's `rebuild`/`gcc-rebuild` modes): picking up a newer
# toolchain (e.g. gcc) with no source changes, so PV stays the same but
# PR needs to move so the new .tar.xz doesn't collide with the one
# already published. Renames "<PN>-<PV>-<oldPR>.cygport" (and any sibling
# file sharing that versioned basename, e.g. a `.src.patch`) to
# "<PN>-<PV>-<newPR>", where <newPR> increments the numeric suffix after
# "bl" (1bl1 -> 1bl2).
#
# Unlike bump_version.sh, PV doesn't change here, so there's no old-
# version string to substitute inside file content -- this is a pure
# rename, and xezat_bump.sh (not this script) is what records *why* in
# the changelog.
#
# Usage:
#   bump_release.sh --dir yacp/googletest
#
# Input: CLI args only (no GitHub Actions context dependency, so this can
# be run and debugged locally, macOS included: the rename is a plain `mv`).
# Output: prints the new .cygport basename, and if GITHUB_OUTPUT is set,
# appends `cygport_file=<basename>` there.

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

# "<PN>-<PV>-<PR>.cygport" -> strip "<PN>-" prefix, then split off the
# trailing "-<PR>" segment (mirrors bump_version.sh's own parsing, minus
# the version string it goes on to substitute -- PV isn't changing here).
rest="${old_basename#"$prefix"}"
old_release="${rest##*-}"
pv="${rest%-"$old_release"}"
if [[ -z "$pv" || "$pv" == "$rest" ]]; then
  echo "Could not parse a version out of cygport filename $old_basename" >&2
  exit 1
fi

# Only the "<N>bl<M>" convention bump_version.sh itself produces (see its
# own comment) is handled automatically here -- a release that was
# hand-adjusted to something else needs the same by-hand treatment.
if [[ ! "$old_release" =~ ^([0-9]+)bl([0-9]+)$ ]]; then
  echo "Release '$old_release' doesn't match the <N>bl<M> convention -- bump it by hand" >&2
  exit 1
fi
bl_prefix="${BASH_REMATCH[1]}"
bl_number="${BASH_REMATCH[2]}"
new_release="${bl_prefix}bl$((bl_number + 1))"

new_basename="${pn}-${pv}-${new_release}"

# Every sibling file sharing the old versioned basename gets renamed too,
# same as bump_version.sh -- but with no version-string substitution,
# since PV is unchanged.
shopt -s nullglob
sibling_files=("$old_basename".*)
shopt -u nullglob

for f in "${sibling_files[@]}"; do
  mv -- "$f" "${new_basename}${f#"$old_basename"}"
done

new_cygport_file="${new_basename}.cygport"
echo "Bumped $pn release: $old_release -> $new_release (${#sibling_files[@]} file(s))"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "cygport_file=$new_cygport_file" >> "$GITHUB_OUTPUT"
fi
