#!/usr/bin/env bash
# Creates the draft recipe for a package that isn't in yacp-dev/ports yet
# (port-until-green's "New packages"), from scripts/templates/recipe.in,
# without xezat: it needs only bash, git and the ports clone.
#
# The skeleton has the fields that can be known from the command line
# (HOMEPAGE, SRC_URI, CATEGORY, SUMMARY, DESCRIPTION) filled in, and the
# rest (LICENSE*, BUILD_REQUIRES, the SOVERSION-dependent runtime names,
# inherit, the build) left for the draft to be fitted to the source.
#
# Steps:
#   1. Refuses if the package is already in origin/master, or if
#      dorgann/<pkg>-<ver> already exists on origin or has a worktree.
#   2. A worktree ~/src/ports-wt/<pkg>-<ver> on a new dorgann/<pkg>-<ver>
#      branch from origin/master.
#   3. <pkg>/<pkg>-<ver>-1bl1.cygport written from the template, and
#      committed as <pkg>-<ver>. NOT pushed: the caller fits the recipe,
#      then pushes the branch for review.
#
# Usage:
#   new_recipe.sh --package openzl --version 0.3.0 \
#       --source https://github.com/facebook/openzl/archive/refs/tags/v0.3.0.tar.gz \
#       --homepage https://github.com/facebook/openzl \
#       [--category Libs] [--summary "..."] [--description "..."]
#   new_recipe.sh ... --dry-run    # print the rendered recipe, touch nothing
#
# Values go into double-quoted shell strings, so they must not contain
# a double quote or a dollar sign.

# A bash 5.2 replacement would expand & in a value to the matched text.
shopt -u patsub_replacement 2>/dev/null

set -euo pipefail

usage() {
  echo "Usage: $0 --package P --version V --source URL --homepage URL [--category C] [--summary S] [--description D] [--dry-run]" >&2
  exit 2
}

package="" version="" source="" homepage="" category="Libs" summary="" description="" dry_run=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --package) package="$2"; shift 2 ;;
    --version) version="$2"; shift 2 ;;
    --source) source="$2"; shift 2 ;;
    --homepage) homepage="$2"; shift 2 ;;
    --category) category="$2"; shift 2 ;;
    --summary) summary="$2"; shift 2 ;;
    --description) description="$2"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    *) usage ;;
  esac
done
[[ -n "$package" && -n "$version" && -n "$source" && -n "$homepage" ]] || usage

template="$(dirname "$0")/templates/recipe.in"
[[ -r "$template" ]] || { echo "No template: $template" >&2; exit 1; }

# The cygport's variable names: '-', '+' and '.' become '_' (as cygport expands them).
var="${package//[-+.]/_}"
# The runtime and devel subpackages are lib<base>0 and lib<base>-devel, so
# a package that already starts with "lib" isn't given it twice.
base="${package#lib}"
basevar="${base//[-+.]/_}"
content="$(<"$template")"
content="${content//@HOMEPAGE@/$homepage}"
content="${content//@SRC_URI@/$source}"
content="${content//@CATEGORY@/$category}"
content="${content//@SUMMARY@/$summary}"
content="${content//@DESCRIPTION@/$description}"
content="${content//@PKG@/$package}"
content="${content//@VAR@/$var}"
content="${content//@BASE@/$base}"
content="${content//@BASEVAR@/$basevar}"

if (( dry_run )); then
  printf '%s\n' "$content"
  exit 0
fi

ports="$HOME/src/ports"
branch="dorgann/$package-$version"
wt="$HOME/src/ports-wt/$package-$version"
file="$package/$package-$version-1bl1.cygport"

[[ -d "$ports" ]] || { echo "No ports clone at $ports (gh repo clone yacp-dev/ports $ports)" >&2; exit 1; }
git -C "$ports" fetch -q origin

if git -C "$ports" cat-file -e "origin/master:$package" 2>/dev/null; then
  echo "$package is already in yacp-dev/ports; use /port-until-green $package instead" >&2
  exit 1
fi
if git -C "$ports" ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
  echo "origin already has $branch" >&2
  exit 1
fi
if [[ -e "$wt" ]]; then
  echo "Worktree $wt already exists" >&2
  exit 1
fi

git -C "$ports" worktree add -q -B "$branch" "$wt" origin/master
mkdir -p "$wt/$package"
printf '%s\n' "$content" > "$wt/$file"
git -C "$wt" add "$file"
git -C "$wt" commit -q -m "$package-$version"

echo "$wt/$file"
echo "Committed as $package-$version on $branch (not pushed)."
echo "Fit the recipe to the source, then push the branch for review."
