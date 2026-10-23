#!/usr/bin/env bash
# Renames a package's `.cygport` file (and any sibling files sharing the same
# versioned basename, e.g. `<PN>-<PV>-<PR>.src.patch`) to a new version, using
# util-linux's `rename` for the filename change and `perl` for a best-effort
# substitution of the old bare version string inside each file's content (for
# cases where SRC_URI etc. hardcode the version instead of referencing ${PV}).
# `rename` comes from the Cygwin `util-linux` package; `perl` is already
# pulled in as a dependency of `cygport` itself.
#
# This does NOT replace `xezat bump` (which only regenerates README/changelog
# after a build) -- xezat has no command that performs this rename itself.
#
# Usage:
#   bump_version.sh --dir yacp/googletest --version 1.18.0
#   bump_version.sh --dir yacp/sfparse --version 0.0.0+git20260912 --git-rev <40-hex sha>
#
# A git-snapshot recipe (a literal 40-hex GIT_REV="..." -- most `inherit
# git` ones in yacp) needs --git-rev, which replaces that GIT_REV: the
# version string alone says nothing about which commit to build, so
# without it the bump would build the old commit under the new version,
# and succeed. GIT_REV values derived from ${PV} (tags) follow PV on
# their own and need nothing.
#
# Input: CLI args only (no GitHub Actions context dependency, so this can be
# run and debugged locally, given a Cygwin-flavored `rename`/`sed` on PATH).
# Output: prints the new .cygport basename, and if GITHUB_OUTPUT is set,
# appends `cygport_file=<basename>` and `version=<new_version>` there --
# the latter mirrors detect_cygport_file.sh's own `version` output, so
# build-package.yml can read whichever of the two actually ran without
# caring which one it was (branch-rebuild mode, doc/spec.md 4.6).

set -euo pipefail

dir=""
new_version=""
new_git_rev=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) dir="$2"; shift 2 ;;
    --version) new_version="$2"; shift 2 ;;
    --git-rev) new_git_rev="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$dir" ]] || { echo "--dir is required" >&2; exit 1; }
[[ -n "$new_version" ]] || { echo "--version is required" >&2; exit 1; }
[[ -d "$dir" ]] || { echo "No such directory: $dir" >&2; exit 1; }

# yacp convention: the package directory name equals PN. Resolve this before
# cd'ing so it works for relative --dir arguments too.
pn="$(basename "$(cd "$dir" && pwd)")"

cd "$dir"

shopt -s nullglob
cygport_files=(*.cygport)
shopt -u nullglob
if [[ ${#cygport_files[@]} -ne 1 ]]; then
  echo "Expected exactly one .cygport file in $dir, found ${#cygport_files[@]}: ${cygport_files[*]}" >&2
  exit 1
fi

old_basename="${cygport_files[0]%.cygport}"

prefix="${pn}-"
if [[ "$old_basename" != "$prefix"* ]]; then
  echo "cygport filename $old_basename does not start with package name $pn" >&2
  exit 1
fi

# "<PN>-<PV>-<PR>.cygport" -> strip "<PN>-" prefix, then drop the trailing "-<PR>" segment.
rest="${old_basename#"$prefix"}"
old_version="${rest%-*}"
if [[ -z "$old_version" || "$old_version" == "$rest" ]]; then
  echo "Could not parse a version out of cygport filename $old_basename" >&2
  exit 1
fi

if [[ "$old_version" == "$new_version" ]]; then
  echo "Package $pn is already at version $new_version" >&2
  exit 1
fi

git_rev_re='^GIT_REV="?[0-9a-f]{40}"?[[:space:]]*$'
if grep -qE "$git_rev_re" "${cygport_files[0]}"; then
  if [[ -z "$new_git_rev" ]]; then
    echo "$pn is a git snapshot (literal GIT_REV in ${cygport_files[0]}): bumping the version alone would build the old commit under $new_version. Bump it by hand with the new GIT_REV (bump_version.sh --git-rev <sha>) on a dorgann/$pn-$new_version branch, then run this workflow with branch set to it." >&2
    exit 1
  fi
  [[ "$new_git_rev" =~ ^[0-9a-f]{40}$ ]] || { echo "--git-rev must be a full 40-hex commit id: $new_git_rev" >&2; exit 1; }
elif [[ -n "$new_git_rev" ]]; then
  echo "--git-rev given, but ${cygport_files[0]} has no literal GIT_REV to replace" >&2
  exit 1
fi

# Release is reset to "1bl1" on a version bump. The "bl" marker distinguishes
# this build from the official Cygwin package of the same name/version.
# Packages that need a different release suffix are expected to be adjusted
# by hand afterwards.
new_basename="${pn}-${new_version}-1bl1"

# Every sibling file sharing the old versioned basename (the .cygport file
# itself, plus companions like "<PN>-<PV>-<PR>.src.patch") gets the old
# version substituted in its content, then all of them get renamed in one
# batch. Files that don't follow this versioned naming (e.g. README) are
# left untouched.
#
# The match is literal (\Q...\E) and bounded: not preceded by a digit or
# dot, and not followed by a digit or a dot+digit. A plain
# `sed s/$old/$new/g` treated the version's dots as regex wildcards and
# had no boundaries, so 1.0.3 matched the "130,3" in a .src.patch hunk
# header (`@@ -130,3 ...`), corrupting it (confirmed by a real run:
# libdecaf 1.0.5) -- and a dotless version like 14 would match any line
# number or literal containing it.
#
# In a .src.patch only the ---/+++ header lines' top directory
# (origsrc/<SRC_DIR>/, src/<SRC_DIR>/) is touched -- that's the only place
# `cygport diff` itself puts the version. SRC_DIR isn't always <PN>-<PV>
# (e.g. abPOA-1.5.6, aespipe-v2.4j), so the version is matched within that
# component rather than the whole component being rebuilt. Hunk contents
# are left alone: rewriting a version that appears in the patched code
# itself is never what the recipe meant.
#
# A .cygport's PATCH_URI is left alone too: a literal version there names
# the version a patch was written for, not the one being built -- a
# Debian revision (.../debian/0.7.5-1/...), a Gentoo or Fedora file name
# (files/<pn>-<ver>-fix.patch), a local patch file that isn't renamed.
# Substituting it pointed the URL at something that doesn't exist
# (confirmed by a real run: msolve 0.11.0 fetched .../debian/0.11.0-1/...,
# a 404, where Debian only had 0.11.0-2). The old URL still fetches the
# old patch, and if it no longer applies, the build fails on it.
#
# A .cygport also gets its PV-derived variable names renamed: cygport
# derives a PKG_NAMES entry's variable names by turning its -+. into _, so
# `lib${PN}_${PV}` in PKG_NAMES pairs with literal names like
# libCatch2_3_15_3_CONTENTS. Before this, the dot-wildcard sed happened to
# match 3_15_3 and wrote back libCatch2_3.16.1_CONTENTS, an invalid name,
# leaving the DLL in no package (confirmed by a real run: Catch2 3.16.1).
# Each PKG_NAMES entry is expanded the way cygport would for the old and
# the new PV (${PV}, ${PV[n]}, $PV_MAJ, $PV_MAJ_MIN -- cygport's PV array
# is the full version followed by its [-._]-separated parts -- plus a
# literal old version, as in skyutils' lib${PN}2.8_4), and only names that
# actually change get renamed. Matching the underscore form by shape alone
# can't work: libCatch2_3_15_3's own "2_" looks just like part of a longer
# version, and names that don't come from PV must stay as they are. This
# runs before the plain version substitution below, since that rewrites
# literal versions inside PKG_NAMES itself.
shopt -s nullglob
sibling_files=("$old_basename".*)
shopt -u nullglob

version_re='(?<![0-9.])\Q$ENV{OLD}\E(?![0-9]|\.[0-9])'
# shellcheck disable=SC2016 # perl code, expanded by perl
pkg_var_rename='
  sub expand {
    my ($s, $v) = @_;
    my @pv = ($v, split /[-._]/, $v);
    $s =~ s/\$\{PV\[(\d+)\]\}/$pv[$1]/g;
    $s =~ s/\$\{?PV_MAJ_MIN\}?/$pv[1].$pv[2]/g;
    $s =~ s/\$\{?PV_MAJ\}?/$pv[1]/g;
    $s =~ s/\$\{?PV\}?(?![\w\[])/$v/g;
    $s =~ s/\$\{?PN\}?(?!\w)/$ENV{PN}/g;
    return $s;
  }
  if (/^PKG_NAMES="([^"]*)"/m) {
    for my $entry (split " ", $1) {
      my $o = expand($entry, $ENV{OLD});
      my $n = expand($entry =~ s/'"${version_re}"'/$ENV{NEW}/gr, $ENV{NEW});
      next if $o eq $n || "$o$n" =~ /\$/;
      tr/-+./___/ for $o, $n;
      s/^(\s*)\Q$o\E(?=_[A-Z])/$1$n/mg;
    }
  }'
for f in "${sibling_files[@]}"; do
  if [[ "$f" == *.src.patch ]]; then
    OLD="$old_version" NEW="$new_version" perl -pi -e \
      "s{^((?:---|\\+\\+\\+) (?:origsrc|src)/)([^/]*)}{my (\$p, \$d) = (\$1, \$2); \$p . (\$d =~ s/${version_re}/\$ENV{NEW}/gr)}e" "$f"
  else
    PN="$pn" OLD="$old_version" NEW="$new_version" perl -0pi -e "$pkg_var_rename" "$f"
    OLD="$old_version" NEW="$new_version" perl -0pi -e "s{(^PATCH_URI\\+?=(?:\"[^\"]*\"|\\S*))|${version_re}}{defined \$1 ? \$1 : \$ENV{NEW}}gme" "$f"
    if [[ -n "$new_git_rev" ]]; then
      REV="$new_git_rev" perl -pi -e 's/^(GIT_REV="?)[0-9a-f]{40}/$1$ENV{REV}/' "$f"
    fi
  fi
done

rename -- "$old_basename" "$new_basename" "${sibling_files[@]}"

new_cygport_file="${new_basename}.cygport"
echo "Bumped $pn: $old_version -> $new_version (${#sibling_files[@]} file(s))"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "cygport_file=$new_cygport_file"
    echo "version=$new_version"
  } >> "$GITHUB_OUTPUT"
fi
