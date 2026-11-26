#!/usr/bin/env bash
# Before a gcc-rebuild: has gcc changed since the package was last built?
# Compares the gcc-core-<ver> (or gcc-g++/gcc-fortran) under "Build
# requirements" in the package's README on ports master with gcc-core's curr version on the Cygwin
# mirror (upstream version only, no Cygwin release), the same comparison
# dorgann's changelog_message.sh makes for the changelog line.
#
# Usage:
#   gcc_changed.sh --package superlu
# Output (one line):
#   changed <readme gcc> -> <curr gcc>    the changelog says "Rebuild with gcc-<curr>"
#   same <gcc>                            it would only say "Rebuild"
#   none                                  nothing compiled (README's build
#                                         requirements name no gcc/binutils):
#                                         it says "Repackage"
#   unknown <reason>                      the README records no gcc

set -euo pipefail

pkg=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --package) pkg="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done
[[ -n "$pkg" ]] || { echo "--package is required" >&2; exit 1; }

readme="$(gh api "repos/yacp-dev/ports/contents/$pkg/README" -H 'Accept: application/vnd.github.raw' 2>/dev/null || true)"
# gcc-core, gcc-g++ and gcc-fortran share one version; a C++-only
# package's README lists gcc-g++ rather than gcc-core.
readme_gcc="$(sed -En 's/^[[:space:]]*gcc-(core|g\+\+|fortran)-([0-9][^-]*)-[^-]*$/\2/p' <<<"$readme" | head -n 1 || true)"
# The mirror now and then serves a truncated setup.xz: retry.
ini=""
for _ in 1 2 3; do
  ini="$(curl -sf https://mirrors.kernel.org/sourceware/cygwin/x86_64/setup.xz | xz -d 2>/dev/null)" && [[ -n "$ini" ]] && break
  ini=""; sleep 5
done
curr_gcc="$(awk '/^@ gcc-core$/ { f = 1; next } f && /^version:/ { print $2; exit }' <<<"$ini")"
curr_gcc="${curr_gcc%-*}"
[[ -n "$curr_gcc" ]] || { echo "unknown could not read gcc-core from the Cygwin mirror"; exit 0; }

if grep -q '^Build requirements:' <<<"$readme" \
   && ! sed -n '/^Build requirements:/,/^$/p' <<<"$readme" | grep -qE '^[[:space:]]*(gcc[0-9]*-[a-z+]+|binutils)-[0-9]'; then
  echo "none $pkg's README names no compiler: nothing compiled"
elif [[ -z "$readme_gcc" ]]; then
  echo "unknown $pkg's README records no gcc (curr: $curr_gcc)"
elif [[ "$readme_gcc" == "$curr_gcc" ]]; then
  echo "same $curr_gcc"
else
  echo "changed $readme_gcc -> $curr_gcc"
fi
