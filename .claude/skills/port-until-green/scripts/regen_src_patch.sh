#!/usr/bin/env bash
# Rebases a recipe's .src.patch onto a new source without Cygwin, in the
# shape `cygport diff` writes: `diff -urNp` between origsrc/<dir>/ and
# src/<dir>/, with no "diff ..." lines. Good enough for `patch -p0`; once
# a run succeeds, the workflow's copy-back step replaces it with the real
# `cygport diff` output.
#
#   prepare  extracts the source tarball into <work>/origsrc and
#            <work>/src, applies each --pre-patch (PATCH_URI patches, in
#            order, -p1 -N -f) to both, then the old .src.patch to src/
#            only (-p0 -N -f), and lists the hunks that failed (*.rej).
#            Resolve those by hand in src/ (drop hunks upstream merged).
#   write    writes the new .src.patch from the two trees, leaving out
#            *.orig/*.rej. Generated files are left for you to drop.
#
# Usage:
#   regen_src_patch.sh prepare --source knot-3.6.3.tar.xz --work DIR \
#       [--patch knot-3.6.2-1bl1.src.patch] [--pre-patch FILE ...]
#   regen_src_patch.sh write --work DIR --out knot-3.6.3-1bl1.src.patch
# Output: prepare prints the tree's directory name and any rejected
# hunks; write prints the patch's path and the files it touches.

set -euo pipefail

cmd="${1:-}"; shift || true
source="" work="" patch="" out=""
pre=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --source) source="$2"; shift 2 ;;
    --work) work="$2"; shift 2 ;;
    --patch) patch="$2"; shift 2 ;;
    --pre-patch) pre+=("$2"); shift 2 ;;
    --out) out="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done
[[ -n "$work" ]] || { echo "--work is required" >&2; exit 1; }

case "$cmd" in
  prepare)
    [[ -f "$source" ]] || { echo "--source must be a downloaded tarball" >&2; exit 1; }
    [[ ! -e "$work/origsrc" && ! -e "$work/src" ]] || { echo "$work already has origsrc/ or src/" >&2; exit 1; }
    # Absolute paths: the patches are applied from inside the trees.
    source="$(cd "$(dirname "$source")" && pwd)/$(basename "$source")"
    [[ -z "$patch" ]] || patch="$(cd "$(dirname "$patch")" && pwd)/$(basename "$patch")"
    for i in "${!pre[@]}"; do pre[i]="$(cd "$(dirname "${pre[i]}")" && pwd)/$(basename "${pre[i]}")"; done
    mkdir -p "$work/origsrc" "$work/src"
    tar -xf "$source" -C "$work/origsrc"
    tar -xf "$source" -C "$work/src"
    dir="$(ls "$work/origsrc")"
    (( $(wc -l <<<"$dir") == 1 )) || { echo "the tarball has no single top directory: $dir" >&2; exit 1; }
    echo "dir: $dir"
    for p in ${pre[@]+"${pre[@]}"}; do
      for tree in origsrc src; do
        (cd "$work/$tree/$dir" && patch -p1 -N -f -s < "$p") || echo "pre-patch $(basename "$p") failed in $tree/"
      done
    done
    if [[ -n "$patch" ]]; then
      (cd "$work" && patch -p0 -N -f -s < "$patch") || true
      rej="$(cd "$work" && find src -name '*.rej' | sort)"
      if [[ -n "$rej" ]]; then
        echo "rejected (resolve by hand in src/, then delete the .rej):"
        sed 's/^/  /' <<<"$rej"
      else
        echo "the old patch applied cleanly"
      fi
    fi
    ;;
  write)
    [[ -n "$out" ]] || { echo "--out is required" >&2; exit 1; }
    dir="$(ls "$work/origsrc")"
    rej="$(cd "$work" && find src -name '*.rej')"
    [[ -z "$rej" ]] || { echo "unresolved .rej files left in src/:"; echo "$rej"; exit 1; } >&2
    case "$out" in /*) ;; *) out="$PWD/$out" ;; esac
    # `command` skips an alias like diff --color; exit 1 just means "differs".
    (cd "$work" && TZ=UTC command diff -urNp -x '*.orig' -x '*.rej' "origsrc/$dir" "src/$dir" | grep -v '^diff ' > "$out") || true
    echo "$out"
    sed -n 's/^+++ src\/[^/]*\/\([^[:space:]]*\).*/  \1/p' "$out"
    ;;
  *)
    echo "usage: regen_src_patch.sh prepare|write ..." >&2; exit 1 ;;
esac
