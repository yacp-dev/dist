#!/usr/bin/env bash
# Downloads and lays out release artifacts for publish.yml.
#
# Processes the primary artifact given via --artifact-id, as well as any
# unpublished dist artifacts from recently-merged PRs in yacp-dev/ports.
#
# Why scan merged PRs:
#   GitHub Actions' concurrency queue only holds at most 1 pending run
#   (cancel-in-progress: false does not prevent pending runs from being
#   superseded). A rapid succession of PR merges causes intermediate
#   publish runs to be cancelled:
#     "Canceling since a higher priority waiting request for publish-gh-pages exists"
#   Scanning recently-merged PRs for any artifacts whose packages/versions
#   are not yet present in gh-pages/x86_64/release/ ensures that no packages
#   are lost even when an intermediate publish run was cancelled.
#
# Usage:
#   sync_release_artifacts.sh \
#     --dist-repo yacp-dev/dist \
#     --gh-pages-dir gh-pages \
#     [--ports-repo yacp-dev/ports] \
#     [--artifact-id 12345] \
#     [--scan-limit 10] \
#     [--exclude-debuginfo]

set -euo pipefail

dist_repo=""
ports_repo="yacp-dev/ports"
gh_pages_dir=""
primary_artifact_id=""
scan_limit=10
exclude_debuginfo=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dist-repo) dist_repo="$2"; shift 2 ;;
    --ports-repo) ports_repo="$2"; shift 2 ;;
    --gh-pages-dir) gh_pages_dir="$2"; shift 2 ;;
    --artifact-id) primary_artifact_id="$2"; shift 2 ;;
    --scan-limit) scan_limit="$2"; shift 2 ;;
    --exclude-debuginfo) exclude_debuginfo=true; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$dist_repo" ]] || { echo "--dist-repo is required" >&2; exit 1; }
[[ -n "$gh_pages_dir" ]] || { echo "--gh-pages-dir is required" >&2; exit 1; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
release_dir="$gh_pages_dir/x86_64/release"
mkdir -p "$release_dir"

declare -A seen_artifacts=()
ordered_artifacts=()

# 1. Scan recently merged PRs in ports for unpublished artifacts
echo "Checking recently merged PRs in $ports_repo (limit: $scan_limit) for unpublished artifacts..." >&2

pr_json="$(gh pr list --repo "$ports_repo" --state merged -L "$scan_limit" --json number,title,headRefName,body,mergedAt 2>/dev/null || true)"

if [[ -n "$pr_json" ]]; then
  # Extract candidate PR metadata: {number, title, pkg, ver, aid}
  # Ordered oldest to newest so earlier PRs are laid out before later ones.
  candidates="$(jq -c '
    [ .[] | select(.headRefName | startswith("dorgann/")) |
      try {
        number: .number,
        title: .title,
        pkg: ((.body | capture("\\| \\*\\*package\\*\\* \\| (?<pkg>[^ |]+) \\|").pkg) // ""),
        ver: ((.body | capture("\\| \\*\\*version\\*\\* \\| (?<ver>[^ |]+) \\|").ver) // ""),
        aid: ((.body | capture("<!-- dorgann-meta: (?<meta>.*) -->").meta | fromjson | .artifact_id) // "")
      } catch empty
    ] | reverse | .[]
  ' <<<"$pr_json" 2>/dev/null || true)"

  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    num="$(jq -r '.number' <<<"$item")"
    title="$(jq -r '.title' <<<"$item")"
    pkg="$(jq -r '.pkg' <<<"$item")"
    ver="$(jq -r '.ver' <<<"$item")"
    aid="$(jq -r '.aid' <<<"$item")"

    # Fallback for pkg / ver from title if table parsing was empty
    if [[ -z "$pkg" || -z "$ver" ]]; then
      clean_title="${title%% *}"
      if [[ "$clean_title" =~ ^(.+)-([^-]+)$ ]]; then
        pkg="${pkg:-${BASH_REMATCH[1]}}"
        ver="${ver:-${BASH_REMATCH[2]}}"
      fi
    fi

    [[ -n "$pkg" && -n "$ver" && -n "$aid" ]] || continue

    already_published=false
    if [[ -d "$release_dir/$pkg" ]]; then
      match="$(find "$release_dir/$pkg" -maxdepth 2 -type f -name "*${ver}*.tar.*" -print -quit 2>/dev/null || true)"
      if [[ -n "$match" ]]; then
        already_published=true
      fi
    fi

    if [[ "$already_published" == true ]]; then
      echo "PR #$num ($pkg $ver, artifact $aid) is already published in $release_dir/$pkg" >&2
    else
      echo "PR #$num ($pkg $ver, artifact $aid) is NOT yet in $release_dir/$pkg -- adding to publish queue" >&2
      if [[ -z "${seen_artifacts[$aid]:-}" ]]; then
        seen_artifacts["$aid"]=1
        ordered_artifacts+=("$aid")
      fi
    fi
  done <<<"$candidates"
else
  echo "Warning: failed to query PRs from $ports_repo" >&2
fi

# 2. Include the primary artifact if given
if [[ -n "$primary_artifact_id" ]]; then
  if [[ -z "${seen_artifacts[$primary_artifact_id]:-}" ]]; then
    seen_artifacts["$primary_artifact_id"]=1
    ordered_artifacts+=("$primary_artifact_id")
    echo "Primary artifact $primary_artifact_id added to publish queue" >&2
  else
    echo "Primary artifact $primary_artifact_id already in queue from merged PRs" >&2
  fi
fi

# Nothing to publish is not an error: a package whose recipe sets
# YACP_NO_REDISTRIBUTE=1 leaves no dist artifact (build-package.yml), so
# the `publish` event for its merged PR arrives with an empty artifact id,
# and no merged PR has an unpublished one either. published_packages stays
# empty, which publish.yml reads as "skip the rest".
if [[ ${#ordered_artifacts[@]} -eq 0 ]]; then
  echo "No artifacts to publish -- nothing to do" >&2
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "published_packages=" >> "$GITHUB_OUTPUT"
  fi
  exit 0
fi

echo "Artifacts to download and layout: ${ordered_artifacts[*]}" >&2

# 3. Download each artifact and lay it out
tmp_base="$(mktemp -d)"
trap 'rm -rf "$tmp_base"' EXIT

all_published=()

for aid in "${ordered_artifacts[@]}"; do
  echo "--- Fetching and laying out artifact $aid ---" >&2
  dest="$tmp_base/$aid"
  mkdir -p "$dest"

  if ! bash -- "$script_dir/download_dist_artifact.sh" --repo "$dist_repo" --artifact-id "$aid" --dest "$dest"; then
    echo "Warning: failed to download artifact $aid (might be expired or inaccessible) -- skipping" >&2
    continue
  fi

  layout_args=(--artifact-dir "$dest" --gh-pages-dir "$gh_pages_dir")
  if [[ "$exclude_debuginfo" == true ]]; then
    layout_args+=(--exclude-debuginfo)
  fi

  if published_out="$(bash -- "$script_dir/layout_release_area.sh" "${layout_args[@]}")"; then
    read -ra pkgs <<<"$published_out"
    all_published+=("${pkgs[@]}")
  else
    echo "Warning: layout_release_area failed for artifact $aid" >&2
  fi
done

# Deduplicate published package names
declare -A seen_pkgs=()
unique_published=()
for p in "${all_published[@]}"; do
  if [[ -z "${seen_pkgs[$p]:-}" ]]; then
    seen_pkgs["$p"]=1
    unique_published+=("$p")
  fi
done

if [[ ${#unique_published[@]} -eq 0 ]]; then
  echo "No packages were laid out" >&2
  exit 1
fi

published_packages="${unique_published[*]}"
echo "$published_packages"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "published_packages=$published_packages" >> "$GITHUB_OUTPUT"
fi
