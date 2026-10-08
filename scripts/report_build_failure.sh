#!/usr/bin/env bash
# Files (or updates) a build-failed Issue (doc/spec.md 4.5) for a package.
# Meant to be wired up as the last step of build-package.yml's job with
# `if: failure()` -- steps only get this far if something earlier in the
# same job errored out (bump, cygport build, xezat, Create Pull Request,
# ...).
#
# Reuses find_failure_issue.sh so repeat failures of the same package
# (e.g. re-running after tweaking BUILD_REQUIRES) update the existing
# Issue in place -- new version -- instead of piling up a duplicate every
# time. A future daily-cron loop (doc/spec.md 4.2, not yet implemented)
# reads the version back out of this same dorgann-meta comment to decide
# whether upstream has since published something newer worth retrying.
#
# Deliberately does NOT embed a general log excerpt (doc/spec.md 4.5's
# original design called for one; dropped after actually using this
# against a couple of real failures) -- a fixed line count is either too
# long for the common case or too short to contain the actual error for
# a build that fails many steps in, and the run itself keeps the
# complete log for the full retention period anyway, which is plenty of
# time to investigate. The Issue just links to the run instead.
#
# --diagnostic-file is a narrow, deliberate exception to that: unlike an
# arbitrary log excerpt, scripts/diagnose_patch_failure.sh's output is
# self-contained and inherently bounded (a handful of patch-level dry-run
# attempts for one file), so it doesn't have the same "how many lines"
# problem -- and having it right in the Issue body, not one click away
# in the run log, is what actually makes the Issue usable by whoever (or
# whatever -- e.g. an AI agent assigned the Issue) fixes it next.
# --macro-diagnostic-file is the same kind of exception, for
# scripts/diagnose_undefined_macro.sh's output: just autoconf's own
# undefined-macro error lines from the compile log.
#
# Usage:
#   report_build_failure.sh --repo yacp-dev/dist --package foo --version 1.2.3 \
#     --run-url https://github.com/yacp-dev/dist/actions/runs/123456789 \
#     [--diagnostic-file /tmp/patch-diagnostic.txt] \
#     [--macro-diagnostic-file /tmp/macro-diagnostic.txt]

set -euo pipefail

repo=""
package=""
version=""
run_url=""
diagnostic_file=""
macro_diagnostic_file=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --package) package="$2"; shift 2 ;;
    --version) version="$2"; shift 2 ;;
    --run-url) run_url="$2"; shift 2 ;;
    --diagnostic-file) diagnostic_file="$2"; shift 2 ;;
    --macro-diagnostic-file) macro_diagnostic_file="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$repo" ]] || { echo "--repo is required" >&2; exit 1; }
[[ -n "$package" ]] || { echo "--package is required" >&2; exit 1; }
[[ -n "$run_url" ]] || { echo "--run-url is required" >&2; exit 1; }

# --version is allowed to be empty (not required, unlike the other args)
# specifically for build-package.yml's own Bump version/Detect existing
# cygport steps (doc/spec.md 4.6) -- when *those* are what fails (a bad
# --version input, or a branch whose .cygport filename doesn't parse),
# there's no version to report yet, but the failure should still get
# filed rather than this script itself erroring out on a missing arg.
version="${version:-(unknown)}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

body_file="$(mktemp)"
trap 'rm -f "$body_file"' EXIT

# Built with printf '%s', not an interpolated heredoc, purely out of
# habit/consistency with the rest of this repo's scripts -- there's no
# untrusted content in these particular values (package/version/run_url
# all come from this same workflow run), but it costs nothing here either.
{
  printf '<!-- dorgann-meta: {"package":"%s","version":"%s"} -->\n\n' "$package" "$version"
  printf '| Field   | Value |\n|---------|-------|\n'
  printf '| Package | %s |\n| Version | %s |\n\n' "$package" "$version"
  printf 'Run: %s\n' "$run_url"
  # diagnose_patch_failure.sh only ever produces this file when it found
  # both a .src.patch and cygport's own unpacked source tree to retry it
  # against -- empty/missing here just means this failure wasn't that
  # kind (or wasn't a patch-apply failure at all), not an error.
  if [[ -n "$diagnostic_file" && -s "$diagnostic_file" ]]; then
    printf '\n<details><summary>Patch failure diagnostic</summary>\n\n```\n'
    cat "$diagnostic_file"
    printf '```\n\n</details>\n'
  fi
  # Likewise for diagnose_undefined_macro.sh, which only writes this
  # when the compile log actually has autoconf undefined-macro errors.
  if [[ -n "$macro_diagnostic_file" && -s "$macro_diagnostic_file" ]]; then
    printf '\n<details><summary>Undefined autoconf macro diagnostic</summary>\n\n```\n'
    cat "$macro_diagnostic_file"
    printf '```\n\n</details>\n'
  fi
} >"$body_file"

# "<PN>-<PV>", matching the naming convention build-package.yml's own
# yacp PR title already uses (doc/spec.md 4.4.1) -- the build-failed
# label already says this is a failure, so the title doesn't need to
# spell that out too.
title="$package-$version"

# `gh` on windows-latest (this script's only caller, build-package.yml, is
# windows-only) is the runner's native Windows gh.exe, not a Cygwin build
# -- it can't resolve the POSIX-style path mktemp just gave us (confirmed
# by a real run: "open /tmp/tmp.XXXXXXXX: The system cannot find the path
# specified", the Windows API's own wording for a path it can't parse at
# all). cygpath -w is the same POSIX->Windows conversion
# scripts/xezat_cache_info.sh already relies on for the same reason. Kept
# conditional so this script still runs as-is on a non-Cygwin box (e.g.
# testing locally on macOS/Linux per doc/spec.md 5's reproducibility goal).
body_file_native="$body_file"
if command -v cygpath >/dev/null 2>&1; then
  body_file_native="$(cygpath -w "$body_file")"
fi

existing="$("$script_dir/find_failure_issue.sh" --repo "$repo" --package "$package")"

if [[ -n "$existing" ]]; then
  echo "Updating existing build-failed Issue #$existing for $package" >&2
  gh issue edit "$existing" --repo "$repo" --title "$title" --body-file "$body_file_native"
  # `gh issue edit` doesn't reliably print the URL to stdout the way `gh
  # issue create` does, so build it directly rather than depend on that.
  issue_url="https://github.com/$repo/issues/$existing"
else
  # `gh issue create --label` fails outright if the label doesn't already
  # exist in the repo (confirmed by a real run: "could not add label:
  # 'build-failed' not found") -- rather than depending on a one-time
  # manual repo-setup step to create it first, create it here on demand.
  # Idempotent: gh label create's own "already exists" error is swallowed,
  # same as every other already-exists case this repo treats as a no-op
  # (e.g. checkout_gh_pages.sh bootstrapping gh-pages).
  gh label create build-failed --repo "$repo" --color d73a4a \
    --description "A dorgann build for this package failed" 2>/dev/null || true

  echo "Filing a new build-failed Issue for $package" >&2
  # `gh issue create`'s own stdout on success is exactly the new Issue's
  # URL, nothing else -- reused directly instead of a separate lookup.
  issue_url="$(gh issue create --repo "$repo" --title "$title" --body-file "$body_file_native" --label build-failed)"
fi

echo "$issue_url"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "issue_url=$issue_url" >> "$GITHUB_OUTPUT"
fi
