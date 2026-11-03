#!/usr/bin/env bash
# Runs a single step of the cygport build pipeline (compile, check,
# install, list, package, or clean). fetch/prep are done
# beforehand by cygport_prep.sh, which also copies the package's README
# into the build tree -- running them again here would re-apply patches that are already
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
#
# cygport runs with the Windows directories left out of PATH (see
# cygwin_path.sh): a tool missing from BUILD_REQUIRES then fails as
# missing rather than resolving to a same-named Windows one.
#
# check's output stops reaching the job log after CHECK_LOG_LIMIT_BYTES.
# A test that loops printing filled tomsfastmath 0.13.1's job log to 7.8 GB
# in its 10 minutes, and `gh run view --log` can't download one that size,
# which every later reading of the run needs. cygport's own check log,
# which Audit recipe reads, still gets all of it.

set -euo pipefail

source "$(dirname "$0")/cygwin_path.sh"

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

# Passes on the first CHECK_LOG_LIMIT_BYTES of stdin, then says so and
# reads the rest without printing it: stopping would kill the writer with
# SIGPIPE and fail the step.
limit_log() {
  local limit="${CHECK_LOG_LIMIT_BYTES:-33554432}" byte
  head -c "$limit"
  if IFS= read -r -n 1 -d '' byte; then
    printf '\n::warning::cygport check printed over %s bytes: the rest of its output is only in its check log\n' "$limit"
    cat > /dev/null
  fi
}

restrict_path_to_cygwin
if [[ "$step" == check ]]; then
  cygport "$cygport_file" "$step" 2>&1 | limit_log
else
  cygport "$cygport_file" "$step"
fi
