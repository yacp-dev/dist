#!/usr/bin/env bash
# Surfaces autoconf's own "undefined macro" errors for a failed cygport
# compile, the failure configure_cygport.sh's m4_pattern_forbid acsite.m4
# deliberately causes when a package uses an AX_*/PKG_* macro whose .m4
# isn't installed (doc/spec.md 4.3.1). cygautoreconf runs inside
# src_compile, so this shows up as a `cygport compile` failure, often
# buried under a verbose autoreconf log -- and the fix (adding
# autoconf-archive/pkgconf to BUILD_REQUIRES) is mechanical enough that
# having the macro names right in the build-failed Issue is what makes
# it actionable without opening the run at all.
#
# Meant to run as an `if: failure()`-conditioned step right after cygport
# compile, while that run's log ($logdir/<PF>-compile.log, which cygport
# itself tees src_compile's output into) is still on disk. Same
# self-contained, bounded shape as diagnose_patch_failure.sh: only the
# matching error lines, never a general log excerpt (doc/spec.md 4.5).
#
# Usage:
#   diagnose_undefined_macro.sh --dir yacp/googletest --file googletest-1.18.0-1bl1.cygport
#
# Output: prints the diagnostic to stdout; if GITHUB_OUTPUT is set, also
# writes it to a temp file and appends `diagnostic_file=<path>` there
# (for report_build_failure.sh to embed in the Issue body) -- only when
# there was something to diagnose, so a compile failure of any other
# kind leaves it as the empty string a skipped step's outputs already are.

set -uo pipefail # NOT -e: grep finding nothing is the common, expected case here

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

# Same `cygport <file> vars <NAME>` mechanism diagnose_patch_failure.sh
# uses for S.
logdir_decl="$(cygport "$cygport_file" vars logdir 2>/dev/null)"
if [[ -z "$logdir_decl" ]]; then
  echo "diagnose_undefined_macro.sh: 'cygport $cygport_file vars logdir' returned nothing -- can't locate the compile log" >&2
  exit 0
fi
eval "$logdir_decl"

shopt -s nullglob
logs=("${logdir:-/nonexistent}"/*-compile.log)
if [[ ${#logs[@]} -eq 0 ]]; then
  echo "diagnose_undefined_macro.sh: no compile log under '${logdir:-(unset)}' -- nothing to diagnose" >&2
  exit 0
fi

# autoconf 2.69 says "possibly undefined macro", 2.72+ "undefined or
# overquoted macro" (confirmed locally against 2.73, the version Cygwin's
# autoconf2.7 currently ships).
diagnostic="$(grep -hE 'error: (possibly undefined|undefined or overquoted) macro: ' "${logs[@]}")"
if [[ -z "$diagnostic" ]]; then
  echo "diagnose_undefined_macro.sh: no undefined-macro errors in ${logs[*]} -- compile failed for some other reason" >&2
  exit 0
fi

diagnostic="$diagnostic

An AX_* macro usually means BUILD_REQUIRES is missing autoconf-archive,
a PKG_* macro pkgconf. If the token is a false positive, patch in an
m4_pattern_allow for it instead (doc/spec.md 4.3.1)."

echo "$diagnostic"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  output="$(mktemp)"
  printf '%s\n' "$diagnostic" > "$output"
  echo "diagnostic_file=$output" >> "$GITHUB_OUTPUT"
fi
