#!/usr/bin/env bash
# Collects the patches Debian, Fedora and Gentoo carry for one upstream
# version, so a version update can pick up the ones that matter on
# Cygwin. Repology names each distro's source packages; their versions
# come from the distro itself, since Repology can lag behind it (Fedora
# rawhide at 0.19 while Repology still said 0.16): Debian's every
# version on sources.debian.org, Fedora rawhide's spec, Gentoo's ebuilds
# in the tree. Repology's own entries at --version are kept as a fallback
# (a Fedora stable branch, a spec whose Version is a macro). For each
# source package the newest packaging revision wins (Debian unstable's
# 1.5.7+dfsg-4 over trixie's -1).
#
# Every patch is downloaded into --out and printed with a URL pinned to
# that exact revision, ready for PATCH_URI: Debian's data/ URL carries
# the full version, Fedora's and Gentoo's carry a commit, so the URL keeps
# working after the distro moves on (unlike .../raw/rawhide/f/...).
# Deciding which patches to take is left to the caller: this only gathers.
#
# Usage:
#   distro_patches.sh --project zstd --version 1.5.7 --out /path/to/dir
# --project is the Repology project name (may need lowercasing or a
# prefix like python:). Output, per distro and source package: the
# revision used, the lines that say how the patches are applied (Debian
# series, Fedora spec Patch/%if lines, Gentoo ebuild PATCHES/FILESDIR
# lines), and "<local file>  <pinned URL>" per patch.

set -euo pipefail

project=""
version=""
out=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) project="$2"; shift 2 ;;
    --version) version="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$project" ]] || { echo "--project is required" >&2; exit 1; }
[[ -n "$version" ]] || { echo "--version is required" >&2; exit 1; }
[[ -n "$out" ]] || { echo "--out is required" >&2; exit 1; }

mkdir -p "$out"

entries="$(curl -sf -A 'dorgann port-until-green' "https://repology.org/api/v1/project/$project")" ||
  { echo "Repology lookup failed for $project" >&2; exit 1; }

# Source package names Repology knows for one distro, at any version.
# mingw-* (Fedora's MinGW cross builds) aren't Cygwin's concern.
srcnames() {
  jq -r --arg p "$1" '
    .[] | select(.repo | startswith($p))
    | select(.srcname | startswith("mingw-") | not) | .srcname' <<<"$entries" | sort -u
}

# "<repo> <origversion>" for one distro's entries of one srcname at --version.
matching() {
  jq -r --arg v "$version" --arg p "$1" --arg s "$2" '
    .[] | select(.repo | startswith($p)) | select(.version == $v) | select(.srcname == $s)
    | "\(.repo) \(.origversion // .version)"' <<<"$entries"
}

found=""

echo "== Debian"
while read -r src; do
  # Every version sources.debian.org has of --version (epoch, Debian
  # revision and a +dfsg-style repack suffix stripped, as Repology does),
  # plus Repology's own; the newest wins.
  read -r area ver < <(
    { curl -sf "https://sources.debian.org/api/src/$src/" |
        jq -r --arg v "$version" '
          .versions[]? | select(.version | sub("^[0-9]+:"; "") | sub("-[^-]*$"; "")
                                         | sub("[+~](dfsg|ds|repack).*$"; "") == $v)
          | "\(.area) \(.version)"' || true
      matching debian "$src" | awk '{print "main", $2}'
    } | sort -k2,2V | tail -n 1) || continue
  found=1
  prefix="${src:0:1}"; [[ "$src" == lib* ]] && prefix="${src:0:4}"
  base="https://sources.debian.org/data/$area/$prefix/$src/$ver/debian/patches"
  dir="$out/debian/$src"
  mkdir -p "$dir"
  echo "-- $src $ver"
  if ! curl -sf "$base/series" -o "$dir/series"; then
    echo "(no debian/patches/series)"
    continue
  fi
  sed 's/^/series: /' "$dir/series"
  # A series line is "<name> [-pN]"; # starts a comment.
  sed -e 's/#.*//' "$dir/series" | awk 'NF {print $1}' | while read -r name; do
    mkdir -p "$dir/$(dirname "$name")"
    curl -sf "$base/$name" -o "$dir/$name" && echo "$dir/$name  $base/$name" ||
      echo "(failed to fetch $base/$name)"
  done
done < <(srcnames debian)

echo
echo "== Fedora"
while read -r src; do
  branches="$(curl -sf "https://src.fedoraproject.org/api/0/rpms/$src/git/branches?with_commits=true")" ||
    { echo "-- $src: no branches on src.fedoraproject.org"; continue; }
  # rawhide when its spec is at --version, else the newest branch
  # Repology has at it (a stable branch, or rawhide behind a macro Version).
  branch=""
  sha="$(jq -r '.branches.rawhide // empty' <<<"$branches")"
  if [[ -n "$sha" ]] && curl -sf "https://src.fedoraproject.org/rpms/$src/raw/$sha/f/$src.spec" |
      sed -nE 's/^Version:[[:space:]]*//p' | head -n 1 | grep -qxF "$version"; then
    branch=rawhide
  else
    branch="$(matching fedora "$src" | awk '{b = $1; sub(/^fedora_/, "", b)
        if (b == "rawhide") print 9999, b; else if (b ~ /^[0-9]+$/) print b, "f" b}' |
      sort -n | tail -n 1 | cut -d' ' -f2)"
    [[ -n "$branch" ]] || continue
    sha="$(jq -r --arg b "$branch" '.branches[$b] // empty' <<<"$branches")"
    [[ -n "$sha" ]] || { echo "-- $src $version: branch $branch not found"; continue; }
  fi
  found=1
  base="https://src.fedoraproject.org/rpms/$src/raw/$sha/f"
  dir="$out/fedora/$src"
  mkdir -p "$dir"
  echo "-- $src $version ($branch at $sha)"
  curl -sf "$base/$src.spec" -o "$dir/$src.spec" || { echo "(no $src.spec)"; continue; }
  grep -nE '^(Version|Patch[0-9]*):|^%(if|elif|else|endif|patch|autopatch|autosetup)' "$dir/$src.spec" |
    sed 's/^/spec: /'
  # Expand the macros patch names commonly use; anything else is left
  # for the caller to read off the spec.
  name="$(sed -nE 's/^Name:[[:space:]]*//p' "$dir/$src.spec" | head -n 1)"
  sed -nE 's/^Patch[0-9]*:[[:space:]]*//p' "$dir/$src.spec" |
    sed -e "s/%{name}/$name/g" -e "s/%{version}/$version/g" | while read -r patch; do
    case "$patch" in
      http://*|https://*)
        file="$dir/$(basename "${patch%%#*}")"
        curl -sfL "$patch" -o "$file" && echo "$file  $patch" ||
          echo "(failed to fetch $patch)" ;;
      *%*) echo "(unexpanded macro: $patch)" ;;
      *)
        curl -sf "$base/$patch" -o "$dir/$patch" && echo "$dir/$patch  $base/$patch" ||
          echo "(failed to fetch $base/$patch)" ;;
    esac
  done
done < <(srcnames fedora)

echo
echo "== Gentoo"
while read -r src; do
  pn="${src#*/}"
  sha="$(gh api "repos/gentoo/gentoo/commits?path=$src&per_page=1" --jq '.[0].sha')" || continue
  [[ -n "$sha" ]] || continue
  # The newest ebuild of --version in the tree, -rN revisions included.
  ebuild="$(gh api "repos/gentoo/gentoo/contents/$src?ref=$sha" --jq '.[].name' |
    awk -v want="$pn-$version" '/\.ebuild$/ {
      v = $0; sub(/\.ebuild$/, "", v); sub(/-r[0-9]+$/, "", v); if (v == want) print }' |
    sort -V | tail -n 1)" || true
  [[ -n "$ebuild" ]] || continue
  found=1
  base="https://raw.githubusercontent.com/gentoo/gentoo/$sha/$src"
  dir="$out/gentoo/$src"
  mkdir -p "$dir/files"
  echo "-- $src ${ebuild%.ebuild} ($sha)"
  curl -sf "$base/$ebuild" -o "$dir/$ebuild" || { echo "(failed to fetch $ebuild)"; continue; }
  # PATCHES=( ... ) (or MESON_PATCHES etc.) spans lines; print the array whole, plus any other
  # line that applies a patch or names one (incl. patch tarballs in SRC_URI).
  awk '/^[[:space:]]*[A-Z_]*PATCHES=\(/ {p=1} p {print; if (/\)/) p=0; next}
       /eapply|FILESDIR|patch/ {print}' "$dir/$ebuild" | sed 's/^/ebuild: /'
  # files/ holds patches for every version in the directory; fetch the
  # lot and let the ebuild lines above say which apply. Many packages
  # have no files/ at all.
  { gh api "repos/gentoo/gentoo/contents/$src/files?ref=$sha" --jq '.[] | select(.type == "file") | .name' \
      2>/dev/null || true; } | while read -r name; do
    curl -sf "$base/files/$name" -o "$dir/files/$name" &&
      echo "$dir/files/$name  $base/files/$name" || echo "(failed to fetch $base/files/$name)"
  done
done < <(srcnames gentoo)

[[ -n "$found" ]] || echo "(no Debian/Fedora/Gentoo package at $version)"
