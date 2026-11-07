#!/usr/bin/env bash
# Copies the build's README and src.patch back into the package directory
# in the yacp checkout. This is what actually lands the README's
# regenerated changelog (written by `xezat bump` into the build tree, $C)
# onto the tracked file that a later diff/PR step looks at -- xezat bump
# alone never writes there: xezat's own source shows `prep` only copies
# package-dir -> build-tree (so bump has a README to read/append to), and
# `bump` only writes back to that same build-tree copy. Nothing copies
# build-tree -> package-dir except this.
#
# This replaces `xezat port`, which needed a config file and a scratch
# directory (its cygport-file copy would have been onto itself) for the
# same three copies: the the cygport file (already in the package
# directory, where bump_version.sh put it before the build), $C/README and
# ${patchdir}/${PF}.src.patch (not when empty) into <portdir>/<PN>/. All
# three are cygport variables, read with `cygport vars`.
#
# The .src.patch is `cygport diff`'s, which
# leaves out whatever cygport's diff excludes (`*.h.in`, `config.h`,
# generated autotools files, DIFF_EXCLUDES): a change the recipe's own
# .src.patch made to such a file builds green in this run, then silently
# drops out of the committed patch, and the next build of the recipe
# fails without it (e.g. a bundled library's
# include/<lib>/autogen/config.h.in). So before overwriting it, the files
# the old patch
# changes are compared with the new one's, and any that went missing are
# reported as a warning, in the run summary and as `dropped_files=` in
# GITHUB_OUTPUT for the PR body. Such a change belongs in a PATCH_URI
# patch of its own, applied to origsrc, which `cygport diff` never sees.
#
# Usage (paths relative to the package directory, e.g. yacp/googletest):
#   copy_results_back.sh --dir yacp/googletest --file googletest-1.18.0-1bl1.cygport

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

# The files a patch changes, relative to ${S}: cygport diff's headers
# name them as src/<top>/<path> (origsrc/ on the --- side), a git-style
# patch as b/<path>. Sorted, for comm.
patched_files() {
  sed -n 's/^+++ \([^	]*\).*/\1/p' "$1" \
    | grep -v '^/dev/null$' \
    | sed -e 's|^src/[^/]*/||' -e 's|^b/||' \
    | sort -u
}

dir_abs="$(cd "$dir" && pwd)"

cd "$dir_abs"
[[ -f "$cygport_file" ]] || { echo "No such file: $dir_abs/$cygport_file" >&2; exit 1; }

vars_decl="$(cygport "$cygport_file" vars C patchdir PF)"
C="" patchdir="" PF=""
eval "$vars_decl"
[[ -n "$C" && -n "$patchdir" && -n "$PF" ]] || { echo "cygport $cygport_file vars C patchdir PF printed: $vars_decl" >&2; exit 1; }

cp -f "$C/README" "$dir_abs/README"

new_patch="$patchdir/$PF.src.patch"
[[ -f "$new_patch" ]] || { echo "No such file: $new_patch" >&2; exit 1; }
if [[ -s "$new_patch" ]]; then
  old_patch="$dir_abs/$(basename "$new_patch")"
  if [[ -f "$old_patch" ]]; then
    dropped="$(comm -23 <(patched_files "$old_patch") <(patched_files "$new_patch") | tr '\n' ' ' | sed 's/ $//')"
    if [[ -n "$dropped" ]]; then
      echo "::warning title=.src.patch lost changes::cygport diff left out changes the recipe's .src.patch made to: $dropped -- move them into a PATCH_URI patch of their own"
      if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        echo "dropped_files=$dropped" >> "$GITHUB_OUTPUT"
      fi
    fi
  fi
  cp -f "$new_patch" "$dir_abs/"
fi
