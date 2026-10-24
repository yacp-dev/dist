#!/usr/bin/env bash
# Splits build-package.yml's single `target` input (`pkg`, `pkg-ver` or
# `pkg-ver-rel`) into its parts and decides what to build, by comparing
# against the .cygport committed on yacp's master. The port-until-green
# skill runs it too, before dispatching.
#
# Package names can contain dashes themselves, so the package is the
# longest yacp directory name the target equals or starts with followed
# by `-` (case-insensitively if there's no exact match, so `catch2` finds
# `Catch2`). Cygwin's PV and PR can't contain dashes, so what's left is
# `ver` or `ver-rel`.
#
# Modes:
#   latest       pkg              -- no version given; the caller has to
#                                    look up the newest upstream one
#                                    (build-package.yml refuses this)
#   bump         pkg-ver          -- ver differs from yacp: version update
#   rebuild      pkg-ver          -- ver equals yacp: release bump (1bl1 -> 1bl2)
#   gcc-rebuild  pkg-ver-rel      -- ver equals yacp, rel is yacp's +1
#   deploy       pkg-ver-rel      -- ver and rel equal yacp: build as is,
#                                    no PR (validate-only)
#   invalid      pkg-ver-rel      -- anything else (exit status 2)
#   new          pkg-ver          -- pkg isn't on master, but
#                                    dorgann/pkg-ver carries its draft
#                                    recipe: build that branch (release
#                                    is the branch's, current_* empty)
#
# Usage: resolve_target.sh --repo yacp-dev/ports --target superlu-7.0.1-1bl2
# Output: key=value lines on stdout (mode, package, version, release,
# current_version, current_release, cygport_file), plus a `message=`
# line explaining an invalid mode; the same lines are appended to
# GITHUB_OUTPUT when set.

set -euo pipefail

repo=""
target=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --target) target="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$repo" ]] || { echo "--repo is required" >&2; exit 1; }
[[ -n "$target" ]] || { echo "--target is required" >&2; exit 1; }

dirs="$(gh api "repos/$repo/git/trees/master" --jq '.tree[] | select(.type == "tree") | .path')"

# Longest directory name that is `$1` itself or a `<name>-` prefix of it.
match() {
  local d best=""
  while IFS= read -r d; do
    if [[ "$1" == "$d" || "$1" == "$d-"* ]] && (( ${#d} > ${#best} )); then
      best="$d"
    fi
  done <<<"$2"
  echo "$best"
}

package="$(match "$target" "$dirs")"
if [[ -z "$package" ]]; then
  lower_match="$(match "$(tr '[:upper:]' '[:lower:]' <<<"$target")" "$(tr '[:upper:]' '[:lower:]' <<<"$dirs")")"
  if [[ -n "$lower_match" ]]; then
    package="$(grep -ix -- "$lower_match" <<<"$dirs" | head -n 1)"
    target="$package${target:${#package}}"
  fi
fi

# A package not on master yet is built from its draft recipe, pushed by
# hand as dorgann/<pkg>-<ver> (doc/spec.md 4.8): the package is then the
# longest directory name on that branch, and its .cygport has to be at
# exactly the target's version. Looked up even when master matched,
# since a new foo-bar would otherwise be taken for master's foo at
# version bar-<ver>.
branch=""
if gh api "repos/$repo/branches/dorgann/$target" >/dev/null 2>&1; then
  branch_package="$(match "$target" "$(gh api "repos/$repo/git/trees/dorgann/$target" --jq '.tree[] | select(.type == "tree") | .path')")"
  if (( ${#branch_package} > ${#package} )); then
    package="$branch_package"
    branch="dorgann/$target"
  fi
fi
[[ -n "$package" ]] || { echo "No package in $repo matches '$target' (a new package needs its recipe pushed as dorgann/<pkg>-<ver> first)" >&2; exit 1; }

if [[ -n "$branch" ]]; then
  cygport_file="$(gh api "repos/$repo/contents/$package?ref=$branch" --jq '.[].name' | grep '\.cygport$' || true)"
  [[ "$(grep -c . <<<"$cygport_file")" -eq 1 ]] || { echo "Expected exactly one .cygport in $repo/$package on $branch, found: ${cygport_file:-none}" >&2; exit 1; }
  name="${cygport_file%.cygport}"
  name="${name#"$package"-}"
  version="${name%-*}"
  release="${name##*-}"
  [[ "$target" == "$package-$version" ]] || { echo "$branch carries $cygport_file, not $target" >&2; exit 1; }

  result="mode=new
package=$package
version=$version
release=$release
current_version=
current_release=
cygport_file=$cygport_file"
  echo "$result"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "$result" >> "$GITHUB_OUTPUT"
  fi
  exit 0
fi

rest="${target#"$package"}"
rest="${rest#-}"
version=""
release=""
if [[ "$rest" == *-*-* ]]; then
  echo "Can't parse '$rest' as <ver> or <ver>-<rel> (too many dashes)" >&2
  exit 1
elif [[ "$rest" == *-* ]]; then
  version="${rest%-*}"
  release="${rest#*-}"
else
  version="$rest"
fi

cygport_file="$(gh api "repos/$repo/contents/$package" --jq '.[].name' | grep '\.cygport$' | head -n 1 || true)"
[[ -n "$cygport_file" ]] || { echo "No .cygport in $repo/$package on master" >&2; exit 1; }
current="${cygport_file%.cygport}"
current="${current#"$package"-}"
current_release="${current##*-}"
current_version="${current%-*}"

next_release=""
if [[ "$current_release" =~ ^([0-9]+)bl([0-9]+)$ ]]; then
  next_release="${BASH_REMATCH[1]}bl$((BASH_REMATCH[2] + 1))"
fi

message=""
if [[ -z "$version" ]]; then
  mode="latest"
elif [[ -z "$release" ]]; then
  if [[ "$version" == "$current_version" ]]; then mode="rebuild"; else mode="bump"; fi
elif [[ "$version" == "$current_version" && "$release" == "$current_release" ]]; then
  mode="deploy"
elif [[ "$version" == "$current_version" && -n "$next_release" && "$release" == "$next_release" ]]; then
  mode="gcc-rebuild"
else
  mode="invalid"
  message="yacp has $package-$current_version-$current_release; <pkg>-<ver>-<rel> only takes that exact release (build and publish) or $package-$current_version-${next_release:-<next release>} (gcc rebuild). Use $package or $package-<ver> instead."
fi

result="mode=$mode
package=$package
version=$version
release=$release
current_version=$current_version
current_release=$current_release
cygport_file=$cygport_file"
[[ -z "$message" ]] || result+=$'\n'"message=$message"

echo "$result"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "$result" >> "$GITHUB_OUTPUT"
fi

[[ "$mode" != "invalid" ]] || exit 2
