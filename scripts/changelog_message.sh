#!/usr/bin/env bash
# Decides the changelog message `xezat bump` should write (passed on as
# scripts/xezat_bump.sh's XEZAT_BUMP_MESSAGE), by comparing the package's
# cygport file against the one committed on yacp's checked-out HEAD
# (always yacp's default branch, even in branch-rebuild mode -- see
# build-package.yml's Checkout yacp):
#
# - PV changed (or the package is new to HEAD): prints nothing, leaving
#   xezat's own default "Version bump." in place.
# - Only the release changed (e.g. 1bl1 -> 1bl2), and gcc-core's
#   upstream version differs from the gcc-core-<ver> listed under the
#   HEAD README's "Build requirements": "Rebuild with gcc-<upstream>",
#   matching yacp's own existing convention (e.g. "Rebuild with
#   gcc-13.4.0" -- upstream version only, no Cygwin package release).
# - Only the release changed, gcc unchanged (or not recorded at all):
#   "Rebuild".
#
# Decided from the files themselves rather than build-package.yml's
# `rebuild` input, since a release-only bump also reaches here via
# branch-rebuild mode (re-running a rebuild whose first attempt failed),
# where `rebuild` is ignored -- confirmed by a real run (superlu
# 7.0.1-1bl2) that wrote "Version bump." for exactly that case.
#
# Usage:
#   changelog_message.sh --dir yacp --package superlu \
#     --file superlu-7.0.1-1bl2.cygport --gcc-version 14.4.0-1
# Output: prints the message (possibly empty) to stdout; if GITHUB_OUTPUT
# is set, appends `message=<message>` there too.

set -euo pipefail

dir=""
package=""
cygport_file=""
gcc_version=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) dir="$2"; shift 2 ;;
    --package) package="$2"; shift 2 ;;
    --file) cygport_file="$2"; shift 2 ;;
    --gcc-version) gcc_version="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$dir" ]] || { echo "--dir is required" >&2; exit 1; }
[[ -n "$package" ]] || { echo "--package is required" >&2; exit 1; }
[[ -n "$cygport_file" ]] || { echo "--file is required" >&2; exit 1; }
[[ -n "$gcc_version" ]] || { echo "--gcc-version is required" >&2; exit 1; }

# <PN>-<PV>-<PR>.cygport minus its trailing -<PR>.cygport. Comparing
# these directly sidesteps needing to know PN (which can itself contain
# dashes, and isn't always the directory name).
strip_release() {
  local name="${1%.cygport}"
  echo "${name%-*}"
}

head_cygport="$(git -C "$dir" ls-tree --name-only HEAD -- "$package/" | grep '\.cygport$' | head -n 1 || true)"

message=""
if [[ -n "$head_cygport" && "$(strip_release "${head_cygport##*/}")" == "$(strip_release "$cygport_file")" ]]; then
  gcc_upstream="${gcc_version%-*}"
  old_gcc="$(git -C "$dir" show "HEAD:$package/README" 2>/dev/null | sed -n 's/^[[:space:]]*gcc-core-\(.*\)-[^-]*$/\1/p' | head -n 1 || true)"
  if [[ -n "$old_gcc" && "$old_gcc" != "$gcc_upstream" ]]; then
    message="Rebuild with gcc-$gcc_upstream"
  else
    message="Rebuild"
  fi
fi

echo "$message"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "message=$message" >> "$GITHUB_OUTPUT"
fi
