#!/usr/bin/env bash
# Bumps a git-snapshot package (`inherit git` with a literal GIT_REV,
# versioned <base>+git<YYYYMMDD>) to its upstream HEAD on a new
# dorgann/<pkg>-<ver> branch, and pushes it. The branch is checked out
# in its own worktree (~/src/ports-wt/<pkg>-<ver>), not in ~/src/ports,
# which other sessions share; the worktree is left in place for further
# fixes on the branch.
#
# The workflow's own Bump version can't do this: it has no way to learn
# the new commit, so bump_version.sh refuses a literal GIT_REV unless
# given --git-rev. Doing the bump here (with --git-rev) and then
# dispatching with --branch skips that step entirely (branch-rebuild
# mode, doc/spec.md 4.6).
#
# The version date is the HEAD commit's committer date in UTC, matching
# how earlier snapshots in ports were named (e.g. sfparse ff7f230 ->
# +git20251223). File renames and content substitution go through
# dorgann's own scripts/bump_version.sh, so the result is exactly what
# the workflow would have produced -- with a stand-in for util-linux's
# `rename`, which macOS lacks.
#
# Usage:
#   git_snapshot_bump.sh --package sfparse [--version 0.0.0+git20260912] [--dry-run]
# Output: the branch name on stdout, and the worktree path on stderr.
# With --dry-run, prints the version and revision it would use and
# changes nothing.

set -euo pipefail

ports="${PORTS_DIR:-$HOME/src/ports}"
worktrees="${PORTS_WORKTREES_DIR:-$HOME/src/ports-wt}"
dorgann="$(cd "$(dirname "$0")/../../../.." && pwd)"
package=""
version=""
dry_run=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --package) package="$2"; shift 2 ;;
    --version) version="$2"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$package" ]] || { echo "--package is required" >&2; exit 1; }

git -C "$ports" fetch -q origin
cygport="$(git -C "$ports" ls-tree --name-only origin/master "$package/" | grep '\.cygport$')" ||
  { echo "No .cygport for $package on origin/master" >&2; exit 1; }
content="$(git -C "$ports" show "origin/master:$cygport")"

git_uri="$(sed -nE 's/^GIT_URI="?([^"]*)"?$/\1/p' <<<"$content")"
old_rev="$(sed -nE 's/^GIT_REV="?([0-9a-f]{40})"?$/\1/p' <<<"$content")"
git_branch="$(sed -nE 's/^GIT_BRANCH="?([^"]*)"?$/\1/p' <<<"$content")"
[[ -n "$git_uri" && -n "$old_rev" ]] ||
  { echo "$cygport has no GIT_URI with a literal 40-hex GIT_REV -- not a git snapshot this script handles" >&2; exit 1; }

# GIT_URI usually spells the repo via ${PN}.
git_uri="${git_uri//\$\{PN\}/$package}"
git_uri="${git_uri//\$PN/$package}"
[[ "$git_uri" =~ github\.com[/:]([^/]+)/([^/]+)$ ]] ||
  { echo "GIT_URI $git_uri isn't on GitHub -- resolve HEAD by hand" >&2; exit 1; }
repo="${BASH_REMATCH[1]}/${BASH_REMATCH[2]%.git}"

ref="${git_branch:-$(gh api "repos/$repo" --jq .default_branch)}"
read -r new_rev new_date < <(gh api "repos/$repo/commits/$ref" --jq '.sha + " " + .commit.committer.date')
date_utc="$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$new_date" +%Y%m%d 2>/dev/null ||
            date -u -d "$new_date" +%Y%m%d)"

old_basename="${cygport##*/}"
old_basename="${old_basename%.cygport}"
old_version="${old_basename#"$package"-}"
old_version="${old_version%-*}"
[[ "$old_version" == *+git* ]] ||
  { echo "Current version $old_version isn't <base>+git<date>" >&2; exit 1; }
head_version="${old_version%%+git*}+git${date_utc}"

if [[ "$new_rev" == "$old_rev" ]]; then
  echo "$package is already at $repo's $ref HEAD ($new_rev, $old_version)" >&2
  exit 1
fi
if [[ -n "$version" && "$version" != "$head_version" ]]; then
  echo "Requested $version, but $repo's $ref HEAD is $new_rev from $new_date, i.e. $head_version" >&2
  exit 1
fi
version="$head_version"
branch="dorgann/$package-$version"

if [[ -n "$dry_run" ]]; then
  echo "$package: $old_version ($old_rev) -> $version ($new_rev, $repo $ref)" >&2
  echo "$branch"
  exit 0
fi

if git -C "$ports" ls-remote --exit-code --heads origin "$branch" >/dev/null; then
  echo "$branch already exists -- dispatch with --branch instead" >&2
  exit 1
fi
wt="$worktrees/$package-$version"
if [[ -e "$wt" ]]; then
  echo "$wt already exists -- remove it (git -C $ports worktree remove) or use it" >&2
  exit 1
fi

shim="$(mktemp -d)"
trap 'rm -rf "$shim"' EXIT
# util-linux `rename FROM TO FILE...`: replaces the first FROM in each name.
cat > "$shim/rename" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "--" ]] && shift
from="$1" to="$2"; shift 2
for f; do mv -- "$f" "${f/"$from"/$to}"; done
EOF
chmod +x "$shim/rename"

git -C "$ports" worktree add -q -B "$branch" "$wt" origin/master
cd "$wt"
PATH="$shim:$PATH" bash "$dorgann/scripts/bump_version.sh" --dir "$package" --version "$version" --git-rev "$new_rev" >&2
git add -A -- "$package"
git commit -q -m "$package-$version"
git push -q origin "$branch"
echo "worktree: $wt" >&2
echo "$branch"
