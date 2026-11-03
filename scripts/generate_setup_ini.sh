#!/usr/bin/env bash
# Regenerates setup.ini (plus compressed setup.bz2/setup.xz copies of the
# same content, which newer setup.exe versions prefer) from the release
# area laid out by layout_release_area.sh, via calm's mksetupini
# (doc/spec.md 3.2). The --disable-check list is needed because this is a
# small overlay repository, not a full package set -- packages here can
# legitimately (build-)depend on packages that only exist in the official
# Cygwin repository, which mksetupini would otherwise flag as errors and
# refuse to write anything at all (confirmed by an actual run: cygport's
# generated *-src.hint always records build-depends: cygport plus
# whatever the package itself needs, e.g. zlib-devel for "last" -- missing-
# depended-package/missing-required-package alone don't cover that,
# missing-build-depended-package is the separate check for it).
#
# Requires `mksetupini` on PATH (the calm package's own console_scripts
# entry point -- `pip install git+https://github.com/cygwin/calm.git`).
#
# Usage: generate_setup_ini.sh --gh-pages-dir gh-pages

set -euo pipefail

gh_pages_dir=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --gh-pages-dir) gh_pages_dir="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$gh_pages_dir" ]] || { echo "--gh-pages-dir is required" >&2; exit 1; }

inifile="$gh_pages_dir/x86_64/setup.ini"

mksetupini \
  --arch x86_64 \
  --releasearea "$gh_pages_dir" \
  --inifile "$inifile" \
  --disable-check=missing-required-package,missing-depended-package,missing-build-depended-package

bzip2 -k -f -c "$inifile" > "$gh_pages_dir/x86_64/setup.bz2"
xz -k -f -c "$inifile" > "$gh_pages_dir/x86_64/setup.xz"
