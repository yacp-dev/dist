#!/usr/bin/env bash
# Trims cygwin-install-action's package directory down to the tarballs the
# base toolchain install actually used, and names an Actions cache for
# them, so later runs restore them instead of downloading all ~200 again.
# The download itself isn't slow (mirrors.kernel.org gave 400-1000 Mbit/s
# from every runner region probed), but setup.exe fetches one file at a
# time and now and then a single small one stalls -- libuchardet0 took 89s
# and dos2unix 27s in one run, turning a ~30s download into ~3 minutes.
#
# setup.exe never deletes a superseded tarball from its package directory,
# so a restored cache would only ever grow; any release file not named in
# /etc/setup/installed.db is removed before saving. The per-site setup.xz
# and friends are left in place (setup.exe refetches them every run
# anyway) and kept out of the key, so the key changes only when the set of
# tarballs does -- the workflow saves a new cache only then.
#
# Must run right after the base toolchain install, before the extra
# dependencies land in the same directory and installed.db.
#
# Usage: cygwin_package_cache.sh <package dir> (Windows path, as
#   cygwin-install-action's package-cache output gives it)
# Output: appends `key=cygwin-base-<hash>` to GITHUB_OUTPUT if set.

set -euo pipefail

dir="$(cygpath -u "$1")"

declare -A installed
while read -r _ tarball _; do
  installed[$tarball]=1
done < <(tail -n +2 /etc/setup/installed.db)

removed=0
while IFS= read -r -d '' f; do
  if [[ -z "${installed[${f##*/}]:-}" ]]; then
    rm -f -- "$f"
    removed=$((removed + 1))
  fi
done < <(find "$dir" -path '*/release/*' -type f -print0)
find "$dir" -depth -mindepth 1 -type d -empty -delete

kept="$(cd "$dir" && find . -path '*/release/*' -type f | LC_ALL=C sort)"
key="cygwin-base-$(sha256sum <<<"$kept" | cut -c1-16)"

echo "removed $removed stale file(s), kept $(wc -l <<<"$kept"): $(du -sh "$dir" | cut -f1)"
echo "$key"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "key=$key" >> "$GITHUB_OUTPUT"
fi
