#!/usr/bin/env bash
# Fetches and prepares a cygport file's sources (`cygport <file> fetch`
# + `cygport <file> prep`), then copies the package directory's README
# into the build tree ($C). That copy is what a later `xezat bump` reads
# and appends a changelog entry to -- without it, xezat bump would
# operate on whatever stale/absent README happens to already be there
# instead of the current one.
#
# This is what `xezat prep` does, written out so this step doesn't go
# through xezat (its own variable dump, bashvar, can die on cygport's
# output before the build has even started).
#
# Usage (paths relative to the package directory, e.g. yacp/googletest):
#   cygport_prep.sh --dir yacp/googletest --file googletest-1.18.0-1bl1.cygport
#
# cygport runs with the Windows directories left out of PATH, as in
# cygport_build.sh (see cygwin_path.sh).

set -euo pipefail

source "$(dirname "$0")/cygwin_path.sh"

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

cd "$dir"
[[ -f "$cygport_file" ]] || { echo "No such file: $dir/$cygport_file" >&2; exit 1; }

restrict_path_to_cygwin
cygport "$cygport_file" fetch
cygport "$cygport_file" prep

[[ -f README ]] || exit 0

# Same `cygport <file> vars <NAME>` mechanism as embed_readme.sh.
vars_decl="$(cygport "$cygport_file" vars C)"
eval "$vars_decl"
[[ -n "${C:-}" && -d "$C" ]] || { echo "cygport_prep.sh: 'cygport $cygport_file vars C' didn't give an existing \$C" >&2; exit 1; }
cp README "$C/README"
echo "Copied README to $C/README"
