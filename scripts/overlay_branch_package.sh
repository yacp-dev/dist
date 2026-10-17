#!/usr/bin/env bash
# Branch-rebuild mode (doc/spec.md 4.6): overlays every file an existing
# yacp branch changed onto the current (default-branch) checkout, so a human's manual fix pushed to that branch (however it got
# there -- including a squash + force-push) shows up as a plain
# uncommitted diff against master, the same shape build-package.yml's
# fresh-bump path already produces.
#
# Deliberately does NOT check out the branch itself as this job's working
# base (that was tried first, via actions/checkout's `ref:` input, and it
# broke peter-evans/create-pull-request's own base-branch reconciliation:
# with nothing "new" committed during a run that only re-validates an
# already-fixed branch, it collapsed the whole branch down to be
# byte-identical to base and deleted/closed it outright -- confirmed by a
# real run against libucl). Overlaying just one directory's content on
# top of an ordinary master checkout sidesteps that entirely, since it's
# exactly the shape (an uncommitted diff against a freshly-checked-out
# default branch) create-pull-request already knows how to diff and
# commit correctly.
#
# Which files to overlay comes from GitHub's compare API (--base...
# --branch, i.e. diffed against their merge base, so changes merged
# into master after the branch was cut aren't reverted), not from the
# package directory name: a human's fix can rename the package
# directory itself (e.g. JAGS/ -> jags/), and only overlaying
# `<package>/` then left the old directory's deletion out of the PR
# entirely -- worse, on the windows-latest runner's case-insensitive
# NTFS, a case-only rename like that made `git rm -r jags` miss JAGS/
# (git pathspecs are case-sensitive) while `git checkout -- jags` wrote
# into that very same on-disk directory, leaving both versions'
# .cygport files side by side (confirmed by a real run: jags 5.0.0).
# Removals (including a rename's old path) are `git rm`'d and
# everything else is checked out from the branch, all of it staged
# here: create-pull-request commits the whole index, so a deletion
# outside its add-paths still lands in the PR (an add-paths entry for
# a path that no longer exists anywhere would instead make its own
# `git add` fail outright).
#
# Usage:
#   overlay_branch_package.sh --dir yacp --repo yacp-dev/ports --base master --branch dorgann/libucl-0.9.4
# Requires GH_TOKEN (read access to --repo) for the compare API.

set -euo pipefail

dir=""
repo=""
base=""
branch=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) dir="$2"; shift 2 ;;
    --repo) repo="$2"; shift 2 ;;
    --base) base="$2"; shift 2 ;;
    --branch) branch="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$dir" ]] || { echo "--dir is required" >&2; exit 1; }
[[ -n "$repo" ]] || { echo "--repo is required" >&2; exit 1; }
[[ -n "$base" ]] || { echo "--base is required" >&2; exit 1; }
[[ -n "$branch" ]] || { echo "--branch is required" >&2; exit 1; }

# actions/checkout's default fetch refspec only covers the ref it was
# told to check out (the default branch here), so a plain `git fetch
# origin <branch>` wouldn't create a usable origin/<branch> tracking ref
# -- spelling out the destination explicitly makes it do so regardless.
git -C "$dir" fetch --depth=1 origin "$branch:refs/remotes/origin/$branch"

# One "<status>\x1f<previous_filename>\x1f<filename>" line per file;
# previous_filename is only set for renames. \x1f rather than a tab:
# `read` collapses consecutive whitespace IFS characters, so an empty
# previous_filename would shift filename into its place.
compare="$(gh api "repos/$repo/compare/$base...$branch" --jq '.files | length, (.[] | [.status, (.previous_filename // ""), .filename] | join("\u001f"))')"
file_count="$(head -n 1 <<<"$compare")"
# The compare API silently truncates its file list at 300.
if [[ "$file_count" -ge 300 ]]; then
  echo "$branch changes $file_count+ files vs $base -- too many for the compare API to list completely" >&2
  exit 1
fi

removed_paths=()
updated_paths=()
while IFS=$'\x1f' read -r status previous filename; do
  [[ -n "$previous" ]] && removed_paths+=("$previous")
  if [[ "$status" == "removed" ]]; then
    removed_paths+=("$filename")
  else
    updated_paths+=("$filename")
  fi
done < <(tail -n +2 <<<"$compare")

echo "Overlaying $branch onto $base: ${#updated_paths[@]} added/changed, ${#removed_paths[@]} removed path(s)" >&2

# Literal pathspecs: these are exact paths from the API, not globs.
# Removals run first so a case-only rename's old files are already gone
# from disk before the new ones are written into the same directory.
if [[ ${#removed_paths[@]} -gt 0 ]]; then
  git -C "$dir" --literal-pathspecs rm -q --ignore-unmatch -- "${removed_paths[@]}"
fi
if [[ ${#updated_paths[@]} -gt 0 ]]; then
  git -C "$dir" --literal-pathspecs checkout "origin/$branch" -- "${updated_paths[@]}"
fi

# cygport sources .cygport files as a bash script, so CRLF line endings
# are fatal to it ("line 3: $'\r': command not found", confirmed by a
# real run) -- and unlike a fresh checkout of dorgann-generated content,
# these files were just brought in from whatever a human
# committed by hand, quite possibly from a Windows git/editor setup that
# reintroduces CRLF into the blob itself. build-package.yml's own
# "Disable line-ending conversion on checkout" doesn't help here: it only
# stops checkout from adding *more* conversion on top of a blob, it can't
# strip bytes the blob already contains. Normalize defensively rather
# than trust every future manual fix to get this right.
# grep exits 1 (not an error, just "no matches") whenever nothing in the
# directory actually has CRLF -- under `set -e -o pipefail`, piping that
# straight into xargs would make the *normal* case (nothing to strip)
# abort the whole script. Collecting matches into an array first, with an
# explicit `|| true`, sidesteps that -- sed only runs at all if there's
# something to fix.
# (Skipped outright with nothing checked out, since grep given no file
# arguments would read stdin instead.)
crlf_files=()
if [[ ${#updated_paths[@]} -gt 0 ]]; then
  mapfile -d '' -t crlf_files < <(grep -lZ $'\r$' "${updated_paths[@]/#/$dir/}" || true)
fi
if [[ ${#crlf_files[@]} -gt 0 ]]; then
  sed -i 's/\r$//' "${crlf_files[@]}"
fi
