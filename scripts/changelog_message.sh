#!/usr/bin/env bash
# Decides the changelog message generate_readme.sh should write (passed on as
# its --message, from build-package.yml's Update README step), by comparing the package's
# cygport file against the one committed on yacp's checked-out HEAD
# (always yacp's default branch, even in branch-rebuild mode -- see
# build-package.yml's Checkout yacp):
#
# - PV changed (or the package is new to HEAD): prints nothing, leaving
#   generate_readme.sh's own default "Version bump." in place.
# - Only the release changed (e.g. 1bl1 -> 1bl2), and gcc-core's
#   upstream version differs from the gcc-core-<ver> listed under the
#   HEAD README's "Build requirements" (or gcc-g++-<ver>/gcc-fortran-<ver>,
#   all one gcc version, for a package whose README names only those):
#   "Rebuild with gcc-<upstream>",
#   matching yacp's own existing convention (e.g. "Rebuild with
#   gcc-13.4.0" -- upstream version only, no Cygwin package release).
# - Only the release changed, and the HEAD README's "Build requirements"
#   names no compiler (gcc-core/gcc-g++/gcc-fortran, or an old README's
#   gcc4-core/gcc4-g++) and no binutils: nothing was compiled
#   (generate_readme.sh lists a compiler and binutils only for what the
#   debuginfo or the installed .exe/.dll/.a/.so show was built), e.g. a
#   shell script, a header-only library or a data package: "Repackage".
# - Only the release changed, gcc unchanged (or the README has no "Build
#   requirements" at all, so whether it was compiled is unknown):
#   "Rebuild".
#
# Decided from the files themselves rather than build-package.yml's
# resolved mode, since a release-only bump also reaches here via
# branch-rebuild mode (re-running a rebuild whose first attempt failed),
# where the release isn't bumped again -- confirmed by a real run (superlu
# 7.0.1-1bl2) that wrote "Version bump." for exactly that case.
#
# Usage:
#   changelog_message.sh --dir yacp --package superlu \
#     --file superlu-7.0.1-1bl2.cygport
# Output: prints the message (possibly empty) to stdout; if GITHUB_OUTPUT
# is set, appends `message=<message>` there too.

set -euo pipefail

dir=""
package=""
cygport_file=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) dir="$2"; shift 2 ;;
    --package) package="$2"; shift 2 ;;
    --file) cygport_file="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$dir" ]] || { echo "--dir is required" >&2; exit 1; }
[[ -n "$package" ]] || { echo "--package is required" >&2; exit 1; }
[[ -n "$cygport_file" ]] || { echo "--file is required" >&2; exit 1; }

# <PN>-<PV>-<PR>.cygport minus its trailing -<PR>.cygport. Comparing
# these directly sidesteps needing to know PN (which can itself contain
# dashes, and isn't always the directory name).
strip_release() {
  local name="${1%.cygport}"
  echo "${name%-*}"
}

head_package="$package"
head_cygport="$(git -C "$dir" ls-tree --name-only HEAD -- "$package/" | grep '\.cygport$' | head -n 1 || true)"
if [[ -z "$head_cygport" ]]; then
  match_dir="$(git -C "$dir" ls-tree --name-only HEAD | grep -ix "$package" | head -n 1 || true)"
  if [[ -n "$match_dir" ]]; then
    head_package="$match_dir"
    head_cygport="$(git -C "$dir" ls-tree --name-only HEAD -- "$match_dir/" | grep '\.cygport$' | head -n 1 || true)"
  fi
fi

message=""
if [[ -n "$head_cygport" ]] && [[ "$(tr '[:upper:]' '[:lower:]' <<<"$(strip_release "${head_cygport##*/}")")" == "$(tr '[:upper:]' '[:lower:]' <<<"$(strip_release "$cygport_file")")" ]]; then
  # The installed Cygwin gcc-core package's version (e.g. "14.2.0-1"),
  # not `gcc --version`'s output, so it lines up with the gcc-core-<ver>
  # generate_readme.sh records under a README's "Build requirements". gcc-core is
  # always installed as part of the base toolchain (build-package.yml's
  # "Install Cygwin (base toolchain)").
  gcc_version="$(cygcheck -c gcc-core 2>/dev/null | awk '$1 == "gcc-core" { print $2 }' || true)"
  if [[ -n "$gcc_version" ]]; then
    gcc_upstream="${gcc_version%-*}"
  else
    gcc_upstream="$(gcc -dumpversion 2>/dev/null || true)"
  fi
  # gcc-core, gcc-g++ and gcc-fortran always share one version, and a
  # C++-only package's README lists gcc-g++ rather than gcc-core.
  head_readme="$(git -C "$dir" show "HEAD:$head_package/README" 2>/dev/null || true)"
  old_gcc="$(sed -En 's/^[[:space:]]*gcc-(core|g\+\+|fortran)-([0-9][^-]*)-[^-]*$/\2/p' <<<"$head_readme" | head -n 1 || true)"
  if [[ -n "$old_gcc" && -n "$gcc_upstream" && "$old_gcc" != "$gcc_upstream" ]]; then
    message="Rebuild with gcc-$gcc_upstream"
  elif grep -q '^Build requirements:' <<<"$head_readme" \
       && ! sed -n '/^Build requirements:/,/^$/p' <<<"$head_readme" | grep -qE '^[[:space:]]*(gcc[0-9]*-[a-z+]+|binutils)-[0-9]'; then
    message="Repackage"
  else
    message="Rebuild"
  fi
fi

echo "$message"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "message=$message" >> "$GITHUB_OUTPUT"
fi
