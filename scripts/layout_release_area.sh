#!/usr/bin/env bash
# Lays cygport's dist output out into the Cygwin-repository release-area
# convention calm's mksetupini expects: <rel_area>/x86_64/release/<source
# package>/<binary package>/ -- doc/spec.md 3.2, matching the real Cygwin
# mirrors' own layout (e.g. release/zlib/zlib-devel/...), not just a
# calm-specific convention.
#
# cygport's own dist/ layout (see cygport's pkg_pkg.cygpart) is
# dist/<PN>/[<subpkg-name>/]<file>.{hint,tar.xz}: files for whichever
# binary package shares its name with PN (the "main" package, plus the
# -src pseudo-package cygport always produces alongside it) sit directly
# in dist/<PN>/, while every other PKG_NAMES entry (e.g. <PN>-devel, the
# auto-generated <PN>-debuginfo, or an arbitrary split like lua-libucl)
# gets its own dist/<PN>/<subpkg-name>/ subdirectory. calm's own upload-
# processing (which reshapes maintainer uploads into the release area on
# the real Cygwin infrastructure) is what normally does this reshaping,
# but we're not using that here, so it has to happen in this script.
#
# The `dist` directory itself is located by name (rather than assumed to
# sit at a fixed depth under --artifact-dir) since how many wrapper
# levels precede it (e.g. <PN>-<PV>-<PR>.x86_64/dist/) depends on exactly
# what build-package.yml's own Upload dist artifact step globbed.
#
# Keeps only one generation per *source* package (doc/spec.md 3.3): its
# entire target directory (covering every one of its binary packages) is
# wiped before the new files are copied in, rather than accumulating
# multiple versions -- or, after a PKG_NAMES change, orphaned old
# subpackage directories -- side by side.
#
# --exclude-debuginfo leaves every <PN>-debuginfo binary package out of
# the release area -- both the ones in this artifact and any already on
# gh-pages from earlier publishes. GitHub rejects any pushed file over
# 100 MB, which a debuginfo tarball can exceed (mlpack-debuginfo 4.8.0:
# 177 MB), and they take up most of the Pages site's 1 GB limit too.
# Nothing depends on a -debuginfo package, so setup.ini stays consistent
# without them.
#
# Output: prints the published binary package names (space-separated) to
# stdout, and if GITHUB_OUTPUT is set, appends `published_packages=<list>`
# there.
#
# Usage:
#   layout_release_area.sh --artifact-dir artifact --gh-pages-dir gh-pages \
#     [--exclude-debuginfo]

set -euo pipefail

artifact_dir=""
gh_pages_dir=""
exclude_debuginfo=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --artifact-dir) artifact_dir="$2"; shift 2 ;;
    --gh-pages-dir) gh_pages_dir="$2"; shift 2 ;;
    --exclude-debuginfo) exclude_debuginfo=true; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$artifact_dir" ]] || { echo "--artifact-dir is required" >&2; exit 1; }
[[ -n "$gh_pages_dir" ]] || { echo "--gh-pages-dir is required" >&2; exit 1; }

dist_dir="$(find "$artifact_dir" -type d -name dist -print -quit)"
[[ -n "$dist_dir" ]] || { echo "No 'dist' directory found under $artifact_dir" >&2; exit 1; }

release_dir="$gh_pages_dir/x86_64/release"
mkdir -p "$release_dir"

published=()
shopt -s nullglob
for src_pkg_dir in "$dist_dir"/*/; do
  pn="$(basename "$src_pkg_dir")"
  target_src_dir="$release_dir/$pn"

  echo "Publishing source package $pn from $src_pkg_dir" >&2
  rm -rf "$target_src_dir"

  # Files sitting directly in dist/<PN>/ -- the main package sharing PN's
  # own name, plus the -src pseudo-package alongside it (cygport uses an
  # empty distsubdir for both) -- still get their own <PN> binary-package
  # directory nested under the source package, per the real Cygwin
  # mirror convention.
  main_files=("$src_pkg_dir"/*.hint "$src_pkg_dir"/*.tar.*)
  if [[ ${#main_files[@]} -gt 0 ]]; then
    mkdir -p "$target_src_dir/$pn"
    cp "${main_files[@]}" "$target_src_dir/$pn/"
    published+=("$pn")
  fi

  # Each subdirectory of dist/<PN>/ is one more binary package (e.g.
  # <PN>-devel, <PN>-debuginfo, or an arbitrary PKG_NAMES entry like
  # lua-libucl) -- preserve its own name as-is.
  for subpkg_dir in "$src_pkg_dir"*/; do
    subpkg_name="$(basename "$subpkg_dir")"
    if [[ "$exclude_debuginfo" == true && "$subpkg_name" == *-debuginfo ]]; then
      echo "Skipping $subpkg_name (--exclude-debuginfo)" >&2
      continue
    fi
    mkdir -p "$target_src_dir/$subpkg_name"
    cp "$subpkg_dir"*.hint "$subpkg_dir"*.tar.* "$target_src_dir/$subpkg_name/"
    published+=("$subpkg_name")
  done
done
shopt -u nullglob

if [[ "$exclude_debuginfo" == true ]]; then
  find "$release_dir" -mindepth 2 -maxdepth 2 -type d -name '*-debuginfo' \
    -print -exec rm -rf {} + >&2
fi

if [[ ${#published[@]} -eq 0 ]]; then
  echo "No .hint files found under $dist_dir" >&2
  exit 1
fi

published_packages="${published[*]}"
echo "$published_packages"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "published_packages=$published_packages" >> "$GITHUB_OUTPUT"
fi
