#!/usr/bin/env bash
# Writes gh-pages's CNAME file so GitHub Pages serves this site at the
# custom domain (dist.yacp.dev) instead of the default yacp-dev.github.io/
# dist. gh-pages is rebuilt as a fresh orphan commit and force-pushed on
# every publish (publish_gh_pages.sh, doc/spec.md 3.3), but
# checkout_gh_pages.sh clones the *existing* tree into --dir first, so a
# previously-written CNAME already round-trips through that on its own --
# this step exists to (re-)create it after gh-pages doesn't exist yet
# (checkout_gh_pages.sh's from-scratch bootstrap path) or if it's ever
# removed by hand. Idempotent -- safe to run on every publish.
#
# Usage: ensure_gh_pages_cname.sh --dir gh-pages --domain dist.yacp.dev

set -euo pipefail

dir=""
domain=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) dir="$2"; shift 2 ;;
    --domain) domain="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$dir" ]] || { echo "--dir is required" >&2; exit 1; }
[[ -n "$domain" ]] || { echo "--domain is required" >&2; exit 1; }
[[ -d "$dir" ]] || { echo "No such directory: $dir" >&2; exit 1; }

echo "$domain" > "$dir/CNAME"
