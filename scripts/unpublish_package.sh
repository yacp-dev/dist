#!/usr/bin/env bash
# Removes one source package's release directory from a gh-pages checkout
# (doc/spec.md 4.4.3), every binary package of it, after checking setup.ini
# in that same checkout for dependents. remove_package.sh checked before
# dispatching, but only this run's checkout is what gets force-pushed, and
# a publish that ran while this one waited may have added a dependent.
#
# Refuses a name that isn't a plain package name: it goes into an rm -rf.
#
# Usage: unpublish_package.sh --gh-pages-dir gh-pages --package evmc

set -euo pipefail

gh_pages_dir=""
package=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --gh-pages-dir) gh_pages_dir="$2"; shift 2 ;;
    --package) package="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$gh_pages_dir" ]] || { echo "--gh-pages-dir is required" >&2; exit 1; }
[[ -n "$package" ]] || { echo "--package is required" >&2; exit 1; }

if [[ ! "$package" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]; then
  echo "Not a package name: $package" >&2
  exit 1
fi

target="$gh_pages_dir/x86_64/release/$package"
[[ -d "$target" ]] || { echo "$package isn't published: no $target" >&2; exit 1; }

here="$(cd "$(dirname "$0")" && pwd)"
dependents="$(bash "$here/setup_ini_dependents.sh" --setup-ini "$gh_pages_dir/x86_64/setup.ini" --package "$package")"
if [[ -n "$dependents" ]]; then
  {
    echo "$package still has dependents in setup.ini (dependent, field, package):"
    echo "$dependents"
  } >&2
  exit 1
fi

rm -rf -- "$target"
echo "Removed $target" >&2
