#!/usr/bin/env bash
# Copies the build's README and src.patch back into the package directory
# in the yacp checkout, via `xezat port`. This is what actually lands the
# README's xezat-regenerated changelog (written by `xezat bump` into the
# build tree, $C) onto the tracked file that a later diff/PR step looks at
# -- xezat bump alone never writes there: xezat's own source shows `prep`
# only copies package-dir -> build-tree (so bump has a README to read/
# append to), and `bump` only writes back to that same build-tree copy.
# Nothing copies build-tree -> package-dir except this.
#
# `xezat port` also copies the cygport file itself, from vars[:top] (the
# directory the cygport file actually lives in). In yacp's layout that's
# the same package directory this script needs to copy *into* -- pointing
# --portdir straight at the package directory's parent would make source
# and destination the same file, and Ruby's FileUtils.cp refuses same-file
# copies (confirmed by the actual ArgumentError in a real run). So `xezat
# port` is run against a throwaway scratch directory instead, and only
# README/src.patch are copied back out of it -- the cygport file's own
# copy in there is redundant (bump_version.sh already put the correct
# content directly in the package directory before the build ran) and is
# discarded along with the rest of the scratch directory.
#
# `xezat port`'s --portdir option is only consulted as a fallback: it
# unconditionally tries to read its config file first (~/.xezat/config.yml
# by default, via Xezat::Command::Port#get_port_directory ->
# Xezat#config), and YAML.load_file raises Errno::ENOENT if that file
# doesn't exist -- which it never does on a fresh Actions runner. An empty
# (but valid) config file avoids that crash while leaving portdir unset
# there, so --portdir below is what actually gets used.
#
# The .src.patch `xezat port` brings back is `cygport diff`'s, which
# leaves out whatever cygport's diff excludes (`*.h.in`, `config.h`,
# generated autotools files, DIFF_EXCLUDES): a change the recipe's own
# .src.patch made to such a file builds green in this run, then silently
# drops out of the committed patch, and the next build of the recipe
# fails without it (libquo-1.4.1: hwloc's include/hwloc/autogen/
# config.h.in). So before overwriting it, the files the old patch
# changes are compared with the new one's, and any that went missing are
# reported as a warning, in the run summary and as `dropped_files=` in
# GITHUB_OUTPUT for the PR body. Such a change belongs in a PATCH_URI
# patch of its own, applied to origsrc, which `cygport diff` never sees.
#
# Usage (paths relative to the package directory, e.g. yacp/googletest):
#   xezat_port.sh --dir yacp/googletest --file googletest-1.18.0-1bl1.cygport

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
pn="$(basename "$dir_abs")"

config_file="$HOME/.xezat/config.yml"
if [[ ! -f "$config_file" ]]; then
  mkdir -p "$(dirname "$config_file")"
  printf 'xezat: {}\n' > "$config_file"
fi

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

cd "$dir_abs"
[[ -f "$cygport_file" ]] || { echo "No such file: $dir_abs/$cygport_file" >&2; exit 1; }

xezat port "$cygport_file" --portdir "$scratch"

cp -f "$scratch/$pn/README" "$dir_abs/README"

shopt -s nullglob
src_patches=("$scratch/$pn"/*.src.patch)
shopt -u nullglob
if [[ ${#src_patches[@]} -gt 0 ]]; then
  new_patch="${src_patches[0]}"
  old_patch="$dir_abs/$(basename "$new_patch")"
  if [[ -f "$old_patch" ]]; then
    dropped="$(comm -23 <(patched_files "$old_patch") <(patched_files "$new_patch") | tr '\n' ' ' | sed 's/ $//')"
    if [[ -n "$dropped" ]]; then
      echo "::warning title=.src.patch lost changes::cygport diff left out changes the recipe's .src.patch made to: $dropped -- move them into a PATCH_URI patch of their own"
      if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        echo "dropped_files=$dropped" >> "$GITHUB_OUTPUT"
      fi
      if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
        {
          echo "### .src.patch lost changes"
          echo
          echo "\`cygport diff\` (via \`xezat port\`) left these files out of the regenerated \`$(basename "$new_patch")\`, though the recipe's own patch changed them. This build had the changes; the committed recipe won't. Move them into a \`PATCH_URI\` patch of their own:"
          echo
          for f in $dropped; do echo "- \`$f\`"; done
          echo
        } >> "$GITHUB_STEP_SUMMARY"
      fi
    fi
  fi
  cp -f "$new_patch" "$dir_abs/"
fi
