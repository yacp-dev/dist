#!/usr/bin/env bash
# Collects the patches Debian, Fedora, Gentoo, AUR and PLD carry for one
# upstream version, so a version update can pick up the ones that matter on
# Cygwin. Repology names each distro's source packages; their versions
# come from the distro itself, since Repology can lag behind it: Debian's every
# version on sources.debian.org, Fedora rawhide's spec, Gentoo's ebuilds
# in the tree, AUR's current PKGBUILD (its RPC info, then the git repo),
# PLD's spec on the master branch of the pld-linux GitHub mirror.
# Repology's own entries at --version are kept as a fallback (a Fedora
# stable branch, a spec whose Version is a macro). For each source package
# the newest packaging revision wins (e.g. Debian unstable's -4 over trixie's -1).
#
# A distro with no package at --version gets its newest one in the same
# major version instead (1.5.6 or 1.5.8 for --version 1.5.7), marked
# "(not <version>: ...)" in the output: such a patch was written for
# another version, so the caller tries it like any other and takes it only
# when it applies.
#
# Every patch is downloaded into --out and printed with a URL pinned to
# that exact revision, ready for PATCH_URI: Debian's data/ URL carries
# the full version, Fedora's, Gentoo's, AUR's and PLD's carry a commit, so
# the URL keeps working after the distro moves on (unlike .../raw/rawhide/f/...).
# Deciding which patches to take is left to the caller: this only gathers.
#
# Usage:
#   distro_patches.sh --project zstd --version 1.5.7 --out /path/to/dir
# --project is the Repology project name (may need lowercasing or a
# prefix like python:). Output, per distro and source package: the
# revision used, the lines that say how the patches are applied (Debian
# series, Fedora spec Patch/%if lines, Gentoo ebuild PATCHES/FILESDIR
# lines, AUR PKGBUILD source lines, PLD spec Patch lines), and
# "<local file>  <pinned URL>" per patch.

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

entries="$(curl -sf "https://repology.org/api/v1/project/$project")" ||
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

# The fallback: a version in the same major as --version.
major="${version%%.*}"
same_major() { [[ "${1%%.*}" == "$major" ]]; }

found=""

echo "== Debian"
while read -r src; do
  # Every version sources.debian.org has, as "<area> <upstream> <version>"
  # (epoch, Debian revision and a +dfsg-style repack suffix stripped from
  # the upstream part, as Repology does).
  listing="$(curl -sf "https://sources.debian.org/api/src/$src/" | jq -r '
      .versions[]? | (.version | sub("^[0-9]+:"; "") | sub("-[^-]*$"; "")
                                | sub("[+~](dfsg|ds|repack).*$"; "")) as $up
      | "\(.area) \($up) \(.version)"' || true)"
  # At --version (Repology's entries too), else the newest in the same major.
  pick="$({ awk -v v="$version" '$2 == v {print $1, $3}' <<<"$listing"
            matching debian "$src" | awk '{print "main", $2}'
         } | sort -k2,2V | tail -n 1)"
  note=""
  if [[ -z "$pick" ]]; then
    pick="$(awk -v m="$major" '{ split($2, a, "."); if (a[1] == m) print $1, $3 }' <<<"$listing" |
      sort -k2,2V | tail -n 1)"
    [[ -n "$pick" ]] && note=" (not $version: Debian's newest $major.x)"
  fi
  [[ -n "$pick" ]] || continue
  found=1
  read -r area ver <<<"$pick"
  prefix="${src:0:1}"; [[ "$src" == lib* ]] && prefix="${src:0:4}"
  base="https://sources.debian.org/data/$area/$prefix/$src/$ver/debian/patches"
  dir="$out/debian/$src"
  mkdir -p "$dir"
  echo "-- $src $ver$note"
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
  # rawhide when its spec is at --version. Else the newest branch Repology
  # has at --version (a stable branch, or rawhide behind a macro Version),
  # else rawhide's spec in the same major.
  sha="$(jq -r '.branches.rawhide // empty' <<<"$branches")"
  rawver=""
  if [[ -n "$sha" ]]; then
    rawver="$(curl -sf "https://src.fedoraproject.org/rpms/$src/raw/$sha/f/$src.spec" |
      sed -nE 's/^Version:[[:space:]]*//p' | head -n 1)" || true
  fi
  branch=""
  specver="$version"
  shown="$version"
  note=""
  if [[ -n "$rawver" && "$rawver" == "$version" ]]; then
    branch=rawhide
  else
    branch="$(matching fedora "$src" | awk '{b = $1; sub(/^fedora_/, "", b)
        if (b == "rawhide") print 9999, b; else if (b ~ /^[0-9]+$/) print b, "f" b}' |
      sort -n | tail -n 1 | cut -d' ' -f2)"
    if [[ -n "$branch" ]]; then
      sha="$(jq -r --arg b "$branch" '.branches[$b] // empty' <<<"$branches")"
      [[ -n "$sha" ]] || { echo "-- $src $version: branch $branch not found"; continue; }
    elif [[ -n "$rawver" ]] && same_major "$rawver"; then
      branch=rawhide
      specver="$rawver"
      shown="$rawver"
      note=" (not $version: rawhide's $rawver)"
    else
      continue
    fi
  fi
  found=1
  base="https://src.fedoraproject.org/rpms/$src/raw/$sha/f"
  dir="$out/fedora/$src"
  mkdir -p "$dir"
  echo "-- $src $shown ($branch at $sha)$note"
  curl -sf "$base/$src.spec" -o "$dir/$src.spec" || { echo "(no $src.spec)"; continue; }
  grep -nE '^(Version|Patch[0-9]*):|^%(if|elif|else|endif|patch|autopatch|autosetup)' "$dir/$src.spec" |
    sed 's/^/spec: /' || true
  # Expand the macros patch names commonly use; anything else is left
  # for the caller to read off the spec.
  name="$(sed -nE 's/^Name:[[:space:]]*//p' "$dir/$src.spec" | head -n 1)"
  sed -nE 's/^Patch[0-9]*:[[:space:]]*//p' "$dir/$src.spec" |
    sed -e "s/%{name}/$name/g" -e "s/%{version}/$specver/g" | while read -r patch; do
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
  names="$(gh api "repos/gentoo/gentoo/contents/$src?ref=$sha" --jq '.[].name')" || true
  # The newest ebuild of --version in the tree, -rN revisions included;
  # else the newest in the same major.
  ebuild="$(awk -v want="$pn-$version" '/\.ebuild$/ {
      v = $0; sub(/\.ebuild$/, "", v); sub(/-r[0-9]+$/, "", v); if (v == want) print }' <<<"$names" |
    sort -V | tail -n 1)"
  note=""
  if [[ -z "$ebuild" ]]; then
    ebuild="$(awk -v pn="$pn" -v maj="$major" '/\.ebuild$/ {
        v = $0; sub(/\.ebuild$/, "", v); sub(/-r[0-9]+$/, "", v)
        if (index(v, pn "-") == 1) { w = substr(v, length(pn) + 2); split(w, a, "."); if (a[1] == maj) print $0 } }' <<<"$names" |
      sort -V | tail -n 1)"
    [[ -n "$ebuild" ]] && note=" (not $version: newest $major.x in the tree)"
  fi
  [[ -n "$ebuild" ]] || continue
  found=1
  base="https://raw.githubusercontent.com/gentoo/gentoo/$sha/$src"
  dir="$out/gentoo/$src"
  mkdir -p "$dir/files"
  echo "-- $src ${ebuild%.ebuild} ($sha)$note"
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

echo
echo "== AUR"
while read -r src; do
  # Git snapshots (-git, -svn, ...) and the cross or Android builds aren't
  # releases of the upstream version.
  case "$src" in
    *-git|*-svn|*-hg|*-bzr|*-cvs|*-nightly|android-*|mingw-*) continue ;;
  esac
  # AUR only has each package's current PKGBUILD: its version is the one
  # --version is compared with, else the same major. pkgver can't hold a
  # dash, so the underscore form counts as the same version too.
  info="$(curl -sf "https://aur.archlinux.org/rpc/v5/info?arg[]=$src" | jq -c '.results[0] // empty')" || continue
  [[ -n "$info" ]] || continue
  aurver="$(jq -r '.Version' <<<"$info")"
  aurver="${aurver#*:}"
  aurver="${aurver%-*}"
  note=""
  if [[ "$aurver" == "$version" || "$aurver" == "${version//-/_}" ]]; then
    :
  elif same_major "$aurver"; then
    note=" (not $version: AUR's $aurver)"
  else
    continue
  fi
  dir="$out/aur/$src"
  mkdir -p "$out/aur"
  rm -rf "$dir"
  git clone -q --depth 1 "https://aur.archlinux.org/$src.git" "$dir" 2>/dev/null ||
    { echo "-- $src: clone of the AUR repo failed"; continue; }
  found=1
  sha="$(git -C "$dir" rev-parse HEAD)"
  rm -rf "$dir/.git"
  echo "-- $src $aurver$note ($sha)"
  # The source=( ... ) array, with $pkgver and $pkgname filled in; then each
  # entry: "name::url", a URL, or a file in the repo. Patches and diffs only.
  sed -n '/^source[^=]*=(/,/)/p' "$dir/PKGBUILD" | sed 's/^/PKGBUILD: /' || true
  sed -n '/^source[^=]*=(/,/)/p' "$dir/PKGBUILD" |
    sed -e 's/^source[^=]*=(//' -e 's/)[[:space:]]*$//' -e "s/[\"']//g" \
        -e "s/\${pkgver}/$aurver/g; s/\$pkgver/$aurver/g; s/\${pkgname}/$src/g; s/\$pkgname/$src/g" |
    tr ' \t' '\n\n' | awk 'NF' | while read -r entry; do
      if [[ "$entry" == *::* ]]; then name="${entry%%::*}"; url="${entry#*::}"; else name=""; url="$entry"; fi
      case "$url" in
        http://*|https://*)
          clean="${url%%[?#]*}"
          case "$clean" in *.patch|*.diff) ;; *) continue ;; esac
          [[ -n "$name" ]] || name="$(basename "$clean")"
          file="$dir/$name"
          curl -sfL "$url" -o "$file" && echo "$file  $url" ||
            echo "(failed to fetch $url)" ;;
        *)
          case "$url" in *.patch|*.diff) ;; *) continue ;; esac
          if [[ -f "$dir/$url" ]]; then
            echo "$dir/$url  https://aur.archlinux.org/cgit/aur.git/plain/$url?h=$src&id=$sha"
          else
            echo "(no $url in the AUR repo)"
          fi ;;
      esac
    done
done < <(srcnames aur)

echo
echo "== PLD"
while read -r src; do
  # PLD's packages are mirrored on GitHub under pld-linux; the spec on
  # the master branch is PLD's current package.
  dir="$out/pld/$src"
  mkdir -p "$out/pld"
  rm -rf "$dir"
  git clone -q --depth 1 "https://github.com/pld-linux/$src.git" "$dir" 2>/dev/null || continue
  [[ -f "$dir/$src.spec" ]] || { rm -rf "$dir"; continue; }
  sha="$(git -C "$dir" rev-parse HEAD)"
  rm -rf "$dir/.git"
  pldver="$(sed -nE 's/^Version:[[:space:]]*//p' "$dir/$src.spec" | head -n 1)"
  note=""
  if [[ "$pldver" == "$version" ]]; then
    :
  elif same_major "$pldver"; then
    note=" (not $version: PLD's $pldver)"
  else
    rm -rf "$dir"; continue
  fi
  found=1
  echo "-- $src $pldver$note ($sha)"
  grep -nE '^(Version|Patch[0-9]*):|^%(patch|setup|autosetup)' "$dir/$src.spec" | sed 's/^/spec: /' || true
  sed -nE 's/^Patch[0-9]*:[[:space:]]*//p' "$dir/$src.spec" |
    sed -e "s/%{name}/$src/g" -e "s/%{version}/$pldver/g" | while read -r patch; do
    case "$patch" in
      http://*|https://*)
        file="$dir/$(basename "${patch%%[?#]*}")"
        curl -sfL "$patch" -o "$file" && echo "$file  $patch" ||
          echo "(failed to fetch $patch)" ;;
      *%*) echo "(unexpanded macro: $patch)" ;;
      *)
        if [[ -f "$dir/$patch" ]]; then
          echo "$dir/$patch  https://raw.githubusercontent.com/pld-linux/$src/$sha/$patch"
        else
          echo "(no $patch in the PLD repo)"
        fi ;;
    esac
  done
done < <(srcnames pld)

[[ -n "$found" ]] || echo "(no Debian/Fedora/Gentoo/AUR/PLD package in major $major)"
