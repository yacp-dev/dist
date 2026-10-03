#!/usr/bin/env bash
# Determines the extra Cygwin packages needed to build a given cygport file,
# beyond the fixed base toolchain that build-package.yml always installs
# first (cygport itself already depends on autoconf/automake/libtool/make/
# binutils etc., but not on a compiler -- see build-package.yml).
#
# This mirrors the *primary* mechanism used by Cygwin's own official CI
# (cygwin/scallywag, analyze.py): shell out to `cygport <file> vars ...`,
# which fully evaluates the cygport file (inherit/cygclass processing
# included) and dumps the requested variables as `declare -p` lines. We
# read BUILD_REQUIRES/DEPEND directly, and reuse scallywag's small
# "inherited cygclass implies these extra packages" table and its
# cross-compilation toolchain-prefix logic. Unlike scallywag, we don't
# assume a compiler is already present in the build image, so gcc-core/
# gcc-g++ are part of build-package.yml's fixed base list instead of being
# computed here.
#
# This does NOT go through xezat: the "parsing" here is cygport's own
# built-in `vars` subcommand, not textual regex parsing of the file, so
# there's nothing to gain from xezat's cygport-sourcing plumbing -- and
# doing so would pull in xezat's untested-on-Windows gem dependencies for
# no reason.
#
# Usage (paths relative to the package directory, e.g. yacp/googletest):
#   cygport_depends.sh --dir yacp/googletest --file googletest-1.18.0-1bl1.cygport
#
# Output: prints the extra packages (space-separated) to stdout, and if
# GITHUB_OUTPUT is set, appends `extra_packages=<list>` there.

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

cd "$dir"
[[ -f "$cygport_file" ]] || { echo "No such file: $dir/$cygport_file" >&2; exit 1; }

# Some cygclasses check for their prerequisites unconditionally on inherit,
# which would otherwise make this read-only `vars` query fail if those
# prerequisites aren't installed yet -- exactly what we're trying to
# determine. Make those checks non-fatal (same workaround analyze.py uses).
export __cygport_check_prog_req_nonfatal=1
export cygport_no_error=1

# Cygport variables like BUILD_REQUIRES are conventionally written across
# multiple lines (e.g. `BUILD_REQUIRES="\n\tzlib-devel\n"`). bash's `declare
# -p` doesn't emit that as literal embedded newlines inside "..." -- it
# switches to $'...' ANSI-C quoting with backslash-escaped control
# characters instead (e.g. `declare -- BUILD_REQUIRES=$'\n\tzlib-devel\n'`,
# confirmed directly against bash). Hand-parsing every quoting style
# declare -p might choose is fragile, so just eval its output -- that's
# the one thing guaranteed to reconstruct the value correctly, since
# producing re-evaluable output is the entire point of `declare -p`.
get_var() {
  local name="$1" decl
  decl="$(cygport "$cygport_file" vars "$name")"
  # `&&` here (rather than `if`) would make the function's own exit status
  # equal to the `[[ ]]` test's status whenever it's false, since this is
  # the function's last command -- and under `set -e`, that trips errexit
  # on the *function call*, unlike the same `&&` as a bare top-level
  # statement (which set -e's && / || exemption does cover). `if` always
  # returns 0 when its condition is false and there's no `else`.
  if [[ -n "$decl" ]]; then
    eval "$decl"
  fi
  if [[ -v "$name" ]]; then
    printf '%s' "${!name}"
  fi
  return 0
}

build_requires="$(get_var BUILD_REQUIRES)"
depend="$(get_var DEPEND)"
inherited="$(get_var INHERITED)"
cross_host="$(get_var CROSS_HOST)"

declare -A extra=()
for pkg in $build_requires $depend; do
  extra["$pkg"]=1
done

# Cygclasses that imply extra build-time packages, mirrored from
# cygwin/scallywag's analyze.py (depends_from_inherits). Kept intentionally
# small for now -- extend as unsupported cygclasses show up in practice.
add_for_inherit() {
  local class="$1"; shift
  if [[ " $inherited " == *" $class "* ]]; then
    for pkg in "$@"; do extra["$pkg"]=1; done
  fi
}
add_for_inherit cmake cmake ninja make
add_for_inherit meson meson pkg-config
add_for_inherit ninja ninja
add_for_inherit python3 python3 python3-devel
add_for_inherit perl perl
add_for_inherit ruby ruby-devel rubygems
add_for_inherit lua lua liblua-devel
# VCS-sourced packages (GIT_URI/SVN_URI/HG_URI instead of a SRC_URI
# tarball): cygport's fetch shells out to the VCS client itself. These
# used to work only by accident, via Git for Windows etc. leaking in
# through the runner's Windows PATH -- confirmed by a real run
# (minitrace, `inherit git`) failing "git is required to build this
# package" once configure_cygport.sh restricted cygport's PATH to
# /usr/bin.
add_for_inherit git git
add_for_inherit svn subversion
add_for_inherit hg mercurial

# Plain autotools packages (or ones with no inherit at all) want pkg-config,
# same rule as scallywag.
if [[ -z "$inherited" || " $inherited " == *" autotools "* ]]; then
  extra["pkg-config"]=1
fi

# Cross-compilation needs a prefixed toolchain instead of the native one
# that build-package.yml's base install provides.
if [[ " $inherited " == *" cross "* ]]; then
  case "$cross_host" in
    i686-w64-mingw32) prefix=mingw64-i686- ;;
    x86_64-w64-mingw32) prefix=mingw64-x86_64- ;;
    i686-pc-cygwin) prefix=cygwin32- ;;
    x86_64-pc-cygwin) prefix=cygwin64- ;;
    *) echo "Unknown CROSS_HOST: $cross_host" >&2; prefix="" ;;
  esac
  if [[ -n "$prefix" ]]; then
    for tool in binutils gcc-core gcc-g++ pkg-config; do
      extra["${prefix}${tool}"]=1
    done
  fi
fi

extra_packages="${!extra[*]}"
echo "Extra packages for $cygport_file: ${extra_packages:-(none)}" >&2
echo "$extra_packages"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "extra_packages=$extra_packages" >> "$GITHUB_OUTPUT"
fi
