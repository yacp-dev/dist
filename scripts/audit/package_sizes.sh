# Sourced by audit_recipe.sh: say/warn/ok, $D, $PN and $PVR come from it.
#
# Each tarball cygport package left in dist/$PN, against GitHub's 100 MiB
# file limit: publish.yml pushes the release area to the gh-pages branch,
# and GitHub rejects the whole push over one file past it (libjxl
# 0.13.0-1bl1's -src.tar.xz, 112.21 MB with every git submodule in it).
# The build itself goes green, so without this the PR gets merged and only
# the publish run fails. A -debuginfo tarball is only listed:
# layout_release_area.sh --exclude-debuginfo leaves it out of gh-pages.

github_file_limit=$((100 * 1024 * 1024))

audit_package_sizes() {
  local distdir tarball rel size mib printed=0 over=0 checked=0 largest=0 largest_rel=""
  distdir="$(dirname "$D")/dist/$PN"
  [[ -d "$distdir" ]] || return 0
  while IFS= read -r -d '' tarball; do
    rel="${tarball#"$distdir"/}"
    size="$(stat -c %s "$tarball")"
    mib="$(awk -v s="$size" 'BEGIN { printf "%.1f", s / 1048576 }')"
    checked=$((checked + 1))
    if (( size > largest )); then
      largest=$size largest_rel="$rel ($mib MiB)"
    fi
    (( size > github_file_limit )) || continue
    over=1
    if [[ "$rel" == *-debuginfo/* ]]; then
      ok "Package size: $rel is $mib MiB, over GitHub's 100 MiB file limit, but publish leaves -debuginfo out of gh-pages"
      continue
    fi
    if (( ! printed )); then
      say ""
      say "== Package size =="
      printed=1
    fi
    if [[ "$rel" == *-src.tar.xz ]]; then
      warn "$rel is $mib MiB, over GitHub's 100 MiB file limit -- publish can't push it to gh-pages. It holds everything SRC_URI/GIT_URI fetched: take a release tarball instead of a git clone with every submodule, and only the parts the build uses"
    else
      warn "$rel is $mib MiB, over GitHub's 100 MiB file limit -- publish can't push it to gh-pages"
    fi
  done < <(find "$distdir" -name "*-$PVR*.tar.xz" -print0 2>/dev/null | sort -z)
  (( over )) || (( checked == 0 )) ||
    ok "Package size: all $checked tarball(s) in dist/$PN under GitHub's 100 MiB file limit, the largest $largest_rel"
}
