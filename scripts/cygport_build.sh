#!/usr/bin/env bash
# Runs a single step of the cygport build pipeline (compile, check,
# install, list, package, postinst, or clean). download/prep are done
# beforehand by `xezat prep` (see
# xezat_prep.sh), which also copies the package's README into the build
# tree -- running them again here would re-apply patches that are already
# applied and fail. `all` is not used either, for the same reason (it
# includes prep).
#
# One cygport step per call (rather than looping over all three inside
# the script) so build-package.yml can give each its own GitHub Actions
# step -- separate logs/timings, and a failure points at exactly which
# phase broke instead of just "cygport build".
#
# Usage (paths relative to the package directory, e.g. yacp/googletest):
#   cygport_build.sh --dir yacp/googletest --file googletest-1.18.0-1bl1.cygport --step compile

set -euo pipefail

dir=""
cygport_file=""
step=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) dir="$2"; shift 2 ;;
    --file) cygport_file="$2"; shift 2 ;;
    --step) step="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$dir" ]] || { echo "--dir is required" >&2; exit 1; }
[[ -n "$cygport_file" ]] || { echo "--file is required" >&2; exit 1; }
[[ -n "$step" ]] || { echo "--step is required" >&2; exit 1; }

cd "$dir"
[[ -f "$cygport_file" ]] || { echo "No such file: $dir/$cygport_file" >&2; exit 1; }

cygport "$cygport_file" "$step"
