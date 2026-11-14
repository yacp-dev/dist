#!/usr/bin/env bash
# Before a gcc-rebuild: has gcc changed since the package was last built?
# Compares the gcc-core-<ver> under "Build requirements" in the package's
# README on ports master with gcc-core's curr version on the Cygwin
# mirror (upstream version only, no Cygwin release), the same comparison
# dorgann's changelog_message.sh makes for the changelog line.
#
# Usage:
#   gcc_changed.sh --package superlu
# Output (one line):
#   changed <readme gcc> -> <curr gcc>    the changelog says "Rebuild with gcc-<curr>"
#   same <gcc>                            it would only say "Rebuild"
#   unknown <reason>                      the README records no gcc-core
#                                         (it names a gcc-g++/gcc-fortran
#                                         it does record)

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
readme_gcc="$(sed -n 's/^[[:space:]]*gcc-core-\(.*\)-[^-]*$/\1/p' <<<"$readme" | head -n 1 || true)"
# A C++/Fortran-only package lists gcc-g++/gcc-fortran instead.
other_gcc="$(sed -En 's/^[[:space:]]*(gcc-g\+\+|gcc-fortran)-([0-9][^-]*)-[^-]*$/\1 \2/p' <<<"$readme" | head -n 1 || true)"
curr_gcc="$(curl -sf https://mirrors.kernel.org/sourceware/cygwin/x86_64/setup.xz | xz -d |
  awk '/^@ gcc-core$/ { f = 1; next } f && /^version:/ { print $2; exit }' || true)"
curr_gcc="${curr_gcc%-*}"
[[ -n "$curr_gcc" ]] || { echo "unknown could not read gcc-core from the Cygwin mirror"; exit 0; }

if [[ -z "$readme_gcc" ]]; then
  if [[ -n "$other_gcc" ]]; then
    echo "unknown $pkg's README records ${other_gcc% *}-${other_gcc#* } but no gcc-core (curr: $curr_gcc); changelog_message.sh reads only gcc-core, so the changelog will say Rebuild"
  else
    echo "unknown $pkg's README records no gcc-core (curr: $curr_gcc)"
  fi
elif [[ "$readme_gcc" == "$curr_gcc" ]]; then
  echo "same $curr_gcc"
else
  echo "changed $readme_gcc -> $curr_gcc"
fi
