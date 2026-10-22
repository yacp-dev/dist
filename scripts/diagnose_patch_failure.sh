#!/usr/bin/env bash
# Surfaces exactly which patch -- and which hunk of it -- conflicts, for
# cygport's own "patch ... will not apply" failure (lib/src_prep.cygpart's
# cygpatch(), confirmed against a real run -- yacp-dev/dist#23, io_lib
# 1.16.0). cygpatch() tries patch levels 0 through 5, each via
# `patch -N -s --dry-run -p<level> -i <patchfile> &> /dev/null` --
# both -s and the /dev/null redirect discard the patch tool's own
# diagnostic entirely, so cygport's error message never says which
# file/hunk/line actually conflicts, at any level.
#
# Meant to run as an `if: failure()`-conditioned step right after xezat
# prep, while the failed run's unpacked source tree is still on disk -- a
# step failing doesn't tear down the rest of the job's filesystem, only
# skips later default-condition steps.
#
# cygport's __src_prep applies patches in two stages, and which tree
# exists on disk says which stage failed:
#   1. PATCH_URI patches, in order, onto $origsrcdir/$SRC_DIR -- then
#      rsyncs $origsrcdir to $srcdir, which is what creates $S.
#   2. The .src.patch onto $S.
# So $S existing means stage 1 succeeded and the .src.patch is the one to
# retry; $S missing but the origsrc tree present means a PATCH_URI patch
# stopped stage 1 (confirmed by a real run: lastz 1.04.60's
# nullchar.patch). For that case, stage 1 is replayed from scratch in a
# temp tree -- the source tarballs re-unpacked, then each PATCH_URI patch
# classified and (if it applies) applied in cygport's own order -- rather
# than classified in the failed origsrc tree in place: there, every patch
# cygport applied before the failure already reverse-applies, which is
# indistinguishable from one upstream already has (and so can be
# dropped), the one thing worth knowing about them. If the tarballs can't
# be re-unpacked with plain tar, it falls back to the in-place tree and
# says so. src_unpack_hook/src_patch_hook aren't replayed.
#
# Usage:
#   diagnose_patch_failure.sh --dir yacp/googletest --file googletest-1.18.0-1bl1.cygport
#
# Output: prints the diagnostic to stdout; if GITHUB_OUTPUT is set, also
# writes it to a temp file and appends `diagnostic_file=<path>` there
# (for write_job_summary.sh to show in the run summary) -- only when
# there was something to diagnose, so a skipped/inapplicable run leaves
# it as the empty string a skipped step's outputs already are.

set -uo pipefail # NOT -e: patch's own nonzero exit on a failed dry-run attempt is expected here, not a bug in this script

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

# cygport's ${top}: the directory the cygport file lives in.
top="$(pwd)"
src_patch_file="$top/${cygport_file%.cygport}.src.patch"

# Same `cygport <file> vars <NAME>` mechanism cygport_depends.sh already
# uses to read cygport-computed variables without going through xezat.
# _src_orig_patches is cygport's own PATCH_URI list reduced to file names
# (bin/cygport.in), so it doesn't need re-deriving here.
vars_decl="$(cygport "$cygport_file" vars S srcdir origsrcdir DISTDIR DISTCLEANFILES _src_orig_pkgs _src_orig_patches 2>/dev/null)"
if [[ -z "$vars_decl" ]]; then
  echo "diagnose_patch_failure.sh: 'cygport $cygport_file vars ...' returned nothing -- can't locate the unpacked source tree" >&2
  exit 0
fi
eval "$vars_decl"

# Replayed source trees and decompressed patches.
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# cygpatch()'s own decision for one patch, levels 0-5 in order: applies
# (forward, then --binary), already applied (reverse), or neither -- and,
# with --apply, applies it for real when it applies, as cygpatch() does.
# -f is added to every dry-run: without it, `patch` meets an
# already-applied patch with an "Assume -R? [y]" prompt, which
# non-interactively answers itself and turns a forward check into a
# silent reverse one.
classify() {
  local apply=""
  if [[ "$1" == "--apply" ]]; then apply=1; shift; fi
  local patch_path="$1" tree="$2" level mode
  for level in 0 1 2 3 4 5; do
    for mode in "" --binary; do
      if patch -N -f -s $mode --dry-run -p"$level" -d "$tree" -i "$patch_path" &>/dev/null; then
        [[ -n "$apply" ]] && patch -N -f -s $mode -p"$level" -d "$tree" -i "$patch_path" &>/dev/null
        echo "applies (-p$level${mode:+ $mode})"
        return
      fi
    done
    if patch -R -f -s --dry-run -p"$level" -d "$tree" -i "$patch_path" &>/dev/null; then
      echo "already applied (reverse applies at -p$level)"
      return
    fi
  done
  echo "WILL NOT APPLY"
}

# The dry-run output at the level(s) where the patch's files are actually
# found -- the other levels only ever say "can't find file to patch",
# which buried the real hunk failures among six near-identical blocks.
# Falls back to every level if no level finds the files at all, since
# then that itself is the problem.
show_failure() {
  local patch_path="$1" tree="$2" level out shown=""
  for level in 0 1 2 3 4 5; do
    out="$(patch -N -f --dry-run -p"$level" -d "$tree" -i "$patch_path" 2>&1)"
    # GNU patch says "can't find file to patch", and with -f also (as BSD
    # patch only does) "No file to patch".
    if ! grep -qE "can't find file to patch|No file to patch" <<<"$out"; then
      printf '\n--- %s: patch -p%s --dry-run ---\n%s\n' "${patch_path##*/}" "$level" "$out"
      shown=1
    fi
  done
  if [[ -z "$shown" ]]; then
    for level in 0 1 2 3 4 5; do
      out="$(patch -N -f --dry-run -p"$level" -d "$tree" -i "$patch_path" 2>&1)"
      printf '\n--- %s: patch -p%s --dry-run ---\n%s\n' "${patch_path##*/}" "$level" "$out"
    done
  fi
}

# Resolves a _src_orig_pkgs/_src_orig_patches entry to a file the same
# way __src_prep does: a downloaded copy in DISTDIR, else one next to the
# cygport file.
resolve_file() {
  local p="$1"
  if [[ -n "${DISTDIR:-}" && -f "$DISTDIR/$p" && ! -f "$top/$p" ]]; then
    echo "$DISTDIR/$p"
  elif [[ -f "$top/${p##*/}" && ! -f "$top/$p" ]]; then
    echo "$top/${p##*/}"
  else
    echo "$top/$p"
  fi
}

# Decompresses a compressed patch into a temp file the way cygpatch()
# unpacks *.gz/*.bz2/*.xz/*.zst ones, echoing the path to use.
plain_patch() {
  local p="$1" tmp
  case "$p" in
    *.gz|*.bz2|*.xz|*.zst)
      tmp="$(mktemp "$scratch/patch.XXXXXX")"
      case "$p" in
        *.gz) gzip -dc "$p" ;;
        *.bz2) bzip2 -dc "$p" ;;
        *.xz) xz -dc "$p" ;;
        *.zst) zstd -dc "$p" ;;
      esac > "$tmp" 2>/dev/null
      echo "$tmp"
      ;;
    *) echo "$p" ;;
  esac
}

# Re-unpacks the source tarballs into a fresh directory, mirroring
# __src_prep's own unpack loop and DISTCLEANFILES removal, and echoes the
# replayed $S there -- or nothing if any tarball isn't one plain tar can
# unpack (cygport's own unpack() also handles zip, 7z, rpm, ...).
replay_tree() {
  local root="$scratch/replay" pkg path
  mkdir -p "$root"
  for pkg in ${_src_orig_pkgs:-}; do
    path="$(resolve_file "$pkg")"
    case "$path" in
      *.tar|*.tar.gz|*.tgz|*.tar.bz2|*.tbz2|*.tar.xz|*.txz|*.tar.zst|*.tar.lz) ;;
      *) return ;;
    esac
    tar -xf "$path" -C "$root" 2>/dev/null || return
  done
  local tree="$root${S#"${srcdir:-}"}"
  [[ -d "$tree" ]] || return
  if [[ -n "${DISTCLEANFILES:-}" ]]; then
    # shellcheck disable=SC2086 # a list of (possibly globbed) paths, as cygport uses it
    (cd "$tree" && rm -f $DISTCLEANFILES)
  fi
  echo "$tree"
}

diagnose_patch_uri() {
  local tree p path plain status failed="" apply=--apply
  tree="$(replay_tree)"
  echo "Stage 1 (PATCH_URI) failed: \$S ($S) was never created."
  if [[ -n "$tree" ]]; then
    echo "Each PATCH_URI patch replayed in cygport's order against a fresh unpack of the sources:"
  else
    tree="$1"
    apply=""
    echo "Couldn't re-unpack the sources with tar, so each PATCH_URI patch is classified against the failed tree ($tree) as cygport left it -- patches before the failing one show as \"already applied\" whether cygport applied them or upstream already has them:"
  fi
  echo
  for p in ${_src_orig_patches:-}; do
    path="$(resolve_file "$p")"
    case "$path" in
      *.tar.gz|*.tgz|*.tar.bz2|*.tbz2|*.tar.xz|*.tar.zst)
        printf '  %-40s %s\n' "${p##*/}" "(tarball of patches -- not diagnosed)"
        continue
        ;;
    esac
    if [[ ! -f "$path" ]]; then
      printf '  %-40s %s\n' "${p##*/}" "not found at $path"
      continue
    fi
    plain="$(plain_patch "$path")"
    status="$(classify $apply "$plain" "$tree")"
    if [[ -n "$apply" && "$status" == already* ]]; then
      status="$status -- upstream already has it, can be dropped"
    fi
    if [[ "$status" == "WILL NOT APPLY" && -z "$failed" ]]; then
      status="$status  <- cygport stopped here"
      failed="$plain"
    elif [[ -n "$failed" ]]; then
      # cygport never got this far, so this is against a tree missing the
      # failed patch above -- still useful to see the next problem early.
      status="$status (not reached by cygport; tried without the failed patch above)"
    fi
    printf '  %-40s %s\n' "${p##*/}" "$status"
  done
  if [[ -n "$failed" ]]; then
    show_failure "$failed" "$tree"
  fi
}

diagnose_src_patch() {
  echo "Stage 2 (.src.patch) failed: retrying ${src_patch_file##*/} against \$S ($S) without the -s/&>/dev/null that normally hides this, at the levels (of the 0-5 cygport's own cygpatch() tries) where its files are found:"
  show_failure "$src_patch_file" "$S"
}

origsrc_tree="${origsrcdir:-}${S#"${srcdir:-}"}"

if [[ -d "${S:-}" ]]; then
  if [[ ! -f "$src_patch_file" ]]; then
    echo "diagnose_patch_failure.sh: \$S exists (PATCH_URI patches all applied) and there's no ${src_patch_file##*/} -- nothing to diagnose" >&2
    exit 0
  fi
  diagnostic="$(diagnose_src_patch)"
elif [[ -n "${origsrcdir:-}" && -d "$origsrc_tree" ]]; then
  if [[ -z "${_src_orig_patches:-}" ]]; then
    echo "diagnose_patch_failure.sh: \$S doesn't exist but there are no PATCH_URI patches -- prep failed for some other reason, nothing to diagnose" >&2
    exit 0
  fi
  diagnostic="$(diagnose_patch_uri "$origsrc_tree")"
else
  echo "diagnose_patch_failure.sh: neither '${S:-(unset)}' nor '${origsrc_tree}' exists -- prep must have failed before unpacking, nothing to diagnose" >&2
  exit 0
fi

echo "$diagnostic"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  output="$(mktemp)"
  printf '%s\n' "$diagnostic" > "$output"
  echo "diagnostic_file=$output" >> "$GITHUB_OUTPUT"
fi
