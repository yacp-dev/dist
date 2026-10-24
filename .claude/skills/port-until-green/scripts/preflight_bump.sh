#!/usr/bin/env bash
# Bumps a package to a new version on a local dorgann/<pkg>-<ver> branch
# and checks, before any CI run, what the workflow's mechanical bump
# would get wrong: patches that no longer apply, a SOVERSION that moved,
# a LICENSE that's missing. Fixing those first and pushing the branch
# makes the first dispatch a branch rebuild (doc/spec.md 4.6) of a recipe
# that already accounts for them, instead of a run that fails on them.
#
# Steps:
#   1. A worktree ~/src/ports-wt/<pkg>-<ver> on a new dorgann/<pkg>-<ver>
#      branch from origin/master, with the files renamed by dorgann's own
#      scripts/bump_version.sh (the same bump the workflow does), committed
#      as <pkg>-<ver> but NOT pushed: fixes go on top, then the caller
#      pushes and dispatches.
#   2. The new version's source, from the bumped recipe's SRC_URI (or
#      GIT_URI + GIT_TAG), unpacked into <work>/origsrc/ like cygport's
#      prep does.
#   3. The patches applied the way cygport's cygpatch does (-N, -p0..5,
#      GNU patch): PATCH_URI in order in origsrc/<SRC_DIR>, then the tree
#      copied to src/ and the .src.patch applied there. Each one is
#      reported as applied, already in the source (applies in reverse:
#      drop it), or failing (rebase it). origsrc/ and src/ are left as
#      the starting point for regenerating the .src.patch.
#   4. The DLLs the current runtime packages ship (master's README file
#      list and the recipe's *_CONTENTS), next to every SOVERSION-setting
#      line in the new source's build files, with the libtool/CMake/meson
#      number worked out where it's a literal.
#   5. Whether LICENSE, LICENSE_SPDX and LICENSE_URI are set, whether
#      LICENSE_URI exists in the new source, and the license texts (as
#      audit_recipe.sh recognizes them) of licenses LICENSE lacks, marked
#      when added or changed since the current version, plus the ones the
#      new version dropped (the current source is downloaded for that).
#
# Only reports: nothing beyond the bump is changed, and nothing is
# pushed. Git snapshots (literal GIT_REV) go through git_snapshot_bump.sh
# instead.
#
# Usage:
#   preflight_bump.sh --package knot --version 3.5.2 --work /path/to/scratch/knot-3.5.2
#                     [--source URL]
# --source overrides the primary source URL, for a recipe whose SRC_URI
# comes from a cygclass (github, pypi, ...) or doesn't resolve here.
# Output: the report on stdout; the worktree path on its first line.

set -euo pipefail

ports="${PORTS_DIR:-$HOME/src/ports}"
worktrees="${PORTS_WORKTREES_DIR:-$HOME/src/ports-wt}"
here="$(cd "$(dirname "$0")" && pwd)"
dorgann="$(cd "$here/../../../.." && pwd)"
package=""
version=""
work=""
source_override=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --package) package="$2"; shift 2 ;;
    --version) version="$2"; shift 2 ;;
    --work) work="$2"; shift 2 ;;
    --source) source_override="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$package" ]] || { echo "--package is required" >&2; exit 1; }
[[ -n "$version" ]] || { echo "--version is required" >&2; exit 1; }
[[ -n "$work" ]] || { echo "--work is required" >&2; exit 1; }

# cygpatch's behavior (fuzz, -N, reverse detection) is GNU patch's;
# macOS's own patch is BSD's.
if command -v gpatch >/dev/null; then
  gpatch=gpatch
elif patch --version 2>/dev/null | grep -q 'GNU patch'; then
  gpatch=patch
else
  echo "GNU patch is required (brew install gpatch)" >&2
  exit 1
fi

# identify_license_text and friends, shared with the recipe audit.
source "$dorgann/scripts/license_text.sh"

branch="dorgann/$package-$version"
wt="$worktrees/$package-$version"

git -C "$ports" fetch -q origin
if git -C "$ports" ls-remote --exit-code --heads origin "$branch" >/dev/null; then
  echo "$branch already exists -- dispatching $package-$version rebuilds it" >&2
  exit 1
fi
[[ ! -e "$wt" ]] || { echo "$wt already exists -- remove it (git -C $ports worktree remove) or use it" >&2; exit 1; }
[[ ! -e "$work" ]] || { echo "$work already exists -- pick a new --work directory" >&2; exit 1; }

old_cygport="$(git -C "$ports" ls-tree --name-only origin/master "$package/" | grep '\.cygport$')" ||
  { echo "No .cygport for $package on origin/master" >&2; exit 1; }
if git -C "$ports" show "origin/master:$old_cygport" | grep -qE '^GIT_REV="?[0-9a-f]{40}"?[[:space:]]*$'; then
  echo "$package is a git snapshot (literal GIT_REV) -- use git_snapshot_bump.sh" >&2
  exit 1
fi

# 1. Bump.
git -C "$ports" worktree add -q -B "$branch" "$wt" origin/master
PATH="$here/bin:$PATH" bash "$dorgann/scripts/bump_version.sh" --dir "$wt/$package" --version "$version" >/dev/null
git -C "$wt" add -A -- "$package"
git -C "$wt" commit -q -m "$package-$version"

top="$wt/$package"
cygport="$(cd "$top" && ls ./*.cygport)"
cygport="$top/${cygport#./}"
pf="$(basename "$cygport" .cygport)"

echo "worktree: $wt"
echo "branch:   $branch (committed locally, not pushed)"
echo "work:     $work"

# 2. Source. The variables cygport needs to place the source and the
# patches are evaluated the way cygport would see them (bin/cygport.in
# defines PN, PV as an array, P, ... before sourcing the recipe), but only
# their own assignments, not the whole recipe. Anything with a command
# substitution is left out. Prints them as assignments to eval.
recipe_vars() {
  local file="$1" ver="$2" file_pf="$3" assignments
  assignments="$(perl -0ne '
    while (/^((?:SRC_URI|SRC_DIR|PATCH_URI|GIT_URI|GIT_TAG|GIT_BRANCH|GIT_MODULE|GIT_SUBDIR)\+?=(?:"(?:[^"\\]|\\.)*"|'\''[^'\'']*'\''|\S*))/mg) {
      my $a = $1;
      print "$a\n" unless $a =~ /\$\(|`/;
    }' "$file")"
  (
    set -f
    PN="$package"
    PR="${file_pf##*-}"
    PVP=(${ver//[-._]/ })
    PV=("$ver" "${PVP[@]}")
    P="$PN-$ver"
    PVR="$ver-$PR"
    PF="$file_pf"
    PV_MAJ="${PV[1]}"
    PV_MAJ_MIN="${PV[1]}.${PV[2]:-}"
    NAME="$PN" VERSION="$ver" RELEASE="$PR"
    SRC_URI="" SRC_DIR="" PATCH_URI="" GIT_URI="" GIT_TAG="" GIT_BRANCH="" GIT_MODULE="" GIT_SUBDIR=""
    set +u
    eval "$assignments"
    for v in SRC_URI SRC_DIR PATCH_URI GIT_URI GIT_TAG GIT_BRANCH GIT_MODULE GIT_SUBDIR; do
      printf '%s=%q\n' "$v" "$(echo ${!v})"
    done
  )
}
eval "$(recipe_vars "$cygport" "$version" "$pf")"

inherits="$(sed -nE 's/^inherit[[:space:]]+//p' "$cygport" | tr '\n' ' ')"

mkdir -p "$work/dl" "$work/origsrc" "$work/patches"

# cygport's data/mirrors, default mirror of each.
mirror_url() {
  local url="$1"
  case "$url" in
    mirror://sourceforge/*) echo "https://downloads.sourceforge.net/${url#mirror://sourceforge/}" ;;
    mirror://gnu/*) echo "https://ftpmirror.gnu.org/${url#mirror://gnu/}" ;;
    mirror://savannah/*) echo "https://download.savannah.nongnu.org/releases/${url#mirror://savannah/}" ;;
    mirror://gnome/*) echo "https://download.gnome.org/${url#mirror://gnome/}" ;;
    mirror://debian/*) echo "https://deb.debian.org/debian/${url#mirror://debian/}" ;;
    mirror://*) return 1 ;;
    *) echo "$url" ;;
  esac
}

# Downloads one SRC_URI/PATCH_URI entry into a directory, honoring
# cygport's #/FILENAME fragment, and prints the local path -- or, failing
# that, why.
fetch() {
  local entry="$1" dir="$2" url name code
  url="${entry%%#/*}"
  if [[ "$entry" == *'#/'* ]]; then name="${entry##*#/}"; else name="${url##*/}"; name="${name%%\?*}"; fi
  url="$(mirror_url "$url")" || { echo "unsupported mirror"; return 1; }
  code="$(curl -sL --retry 2 -A 'dorgann port-until-green' -o "$dir/$name" -w '%{http_code}' "$url")" || code="${code:-000}"
  [[ "$code" == 2* ]] || { echo "HTTP $code from $url"; return 1; }
  echo "$dir/$name"
}

echo
echo "== Source =="
source_ok=""
if [[ " $inherits " == *" git "* ]]; then
  [[ -n "$GIT_URI" ]] || { echo "inherit git, but GIT_URI didn't resolve"; }
  module="${GIT_MODULE:-$(basename "${GIT_URI%/}" .git)}"
  SRC_DIR="$module${GIT_SUBDIR:+/$GIT_SUBDIR}"
  if [[ -z "$GIT_TAG" ]]; then
    echo "inherit git without GIT_TAG (GIT_BRANCH=${GIT_BRANCH:-<default>}): the version doesn't pick the source -- check by hand"
  elif git clone -q --depth 1 --branch "$GIT_TAG" "$GIT_URI" "$work/origsrc/$module" 2>"$work/dl/git-clone.log"; then
    echo "git $GIT_URI tag $GIT_TAG -> origsrc/$module"
    source_ok=1
  else
    echo "git clone of $GIT_URI at tag $GIT_TAG FAILED (the tag may be named differently):"
    sed 's/^/  /' "$work/dl/git-clone.log"
  fi
else
  set -f
  read -r -a src_entries <<<"$SRC_URI"
  set +f
  [[ -n "$source_override" ]] && src_entries=("$source_override" "${src_entries[@]:1}")
  if [[ ${#src_entries[@]} -eq 0 || "${src_entries[*]}" == *'$'* ]]; then
    echo "SRC_URI didn't resolve here (inherit: ${inherits:-none}; SRC_URI='$SRC_URI') -- rerun with --source <URL>"
  else
    source_ok=1
    for entry in "${src_entries[@]}"; do
      if file="$(fetch "$entry" "$work/dl")"; then
        echo "$entry -> ${file##*/}"
        case "$file" in
          *.tar|*.tar.*|*.tgz|*.tbz|*.tbz2|*.txz|*.zip) tar -xf "$file" -C "$work/origsrc" ;;
          *) cp "$file" "$work/origsrc/" ;;
        esac
      else
        echo "FAILS: $entry ($file)"
        source_ok=""
      fi
    done
  fi
  SRC_DIR="${SRC_DIR:-$package-$version}"
fi
if [[ -n "$source_ok" && ! -d "$work/origsrc/$SRC_DIR" ]]; then
  echo "SRC_DIR $SRC_DIR is not in the unpacked source (top level: $(ls "$work/origsrc" | tr '\n' ' ')) -- SRC_DIR needs fixing"
  source_ok=""
fi
[[ -n "$source_ok" ]] && echo "S = origsrc/$SRC_DIR"

# The current version's source too, for the license texts the new one
# adds, changes or drops (5.). Only the primary source; a --source URL
# is reused with the version swapped. Prints its $S, or nothing.
old_pf="$(basename "$old_cygport" .cygport)"
old_version="${old_pf%-*}"
old_version="${old_version#"$package"-}"
old_source() {
  local SRC_URI SRC_DIR PATCH_URI GIT_URI GIT_TAG GIT_BRANCH GIT_MODULE GIT_SUBDIR module entry file
  git -C "$ports" show "origin/master:$old_cygport" > "$work/old.cygport"
  eval "$(recipe_vars "$work/old.cygport" "$old_version" "$old_pf")"
  mkdir -p "$work/old/dl" "$work/old/origsrc"
  if [[ " $(sed -nE 's/^inherit[[:space:]]+//p' "$work/old.cygport" | tr '\n' ' ') " == *" git "* ]]; then
    [[ -n "$GIT_URI" && -n "$GIT_TAG" ]] || return 0
    module="${GIT_MODULE:-$(basename "${GIT_URI%/}" .git)}"
    git clone -q --depth 1 --branch "$GIT_TAG" "$GIT_URI" "$work/old/origsrc/$module" 2>/dev/null || return 0
    SRC_DIR="$module${GIT_SUBDIR:+/$GIT_SUBDIR}"
  else
    set -f
    entry="${SRC_URI%% *}"
    set +f
    [[ -n "$source_override" ]] && entry="${source_override//"$version"/"$old_version"}"
    [[ -n "$entry" && "$entry" != *'$'* ]] || return 0
    file="$(fetch "$entry" "$work/old/dl")" || return 0
    case "$file" in
      *.tar|*.tar.*|*.tgz|*.tbz|*.tbz2|*.txz|*.zip) tar -xf "$file" -C "$work/old/origsrc" || return 0 ;;
      *) return 0 ;;
    esac
    SRC_DIR="${SRC_DIR:-$package-$old_version}"
  fi
  [[ -d "$work/old/origsrc/$SRC_DIR" ]] && echo "$work/old/origsrc/$SRC_DIR"
  return 0
}
old_s=""
[[ -n "$source_ok" ]] && old_s="$(old_source)"

# 3. Patches, as cygpatch applies them: the first -pN (0..5) whose dry run
# succeeds, plain then --binary; a reverse dry run succeeding means the
# change is already in the source.
cygpatch() {
  local file="$1" label="$2" level
  for level in 0 1 2 3 4 5; do
    if "$gpatch" -N -s --dry-run -p"$level" -i "$file" &>/dev/null; then
      "$gpatch" -N -s -p"$level" --no-backup-if-mismatch -i "$file" >/dev/null
      echo "applies (-p$level): $label"
      return 0
    elif "$gpatch" -N -s --binary --dry-run -p"$level" -i "$file" &>/dev/null; then
      "$gpatch" -N -s --binary -p"$level" --no-backup-if-mismatch -i "$file" >/dev/null
      echo "applies (--binary -p$level): $label"
      return 0
    elif "$gpatch" -R -s --dry-run -p"$level" -i "$file" &>/dev/null; then
      echo "ALREADY IN SOURCE (applies in reverse, -p$level): $label -- drop it"
      return 0
    fi
  done
  echo "FAILS: $label"
  # The level whose dry run fails on the fewest hunks is the one meant.
  local best="" best_count=999999 count out
  for level in 0 1 2 3 4 5; do
    out="$("$gpatch" -N -f --dry-run -p"$level" -i "$file" 2>&1 || true)"
    grep -q "can't find file to patch\|No file to patch" <<<"$out" && continue
    count="$(grep -c 'FAILED' <<<"$out" || true)"
    if (( count < best_count )); then best="$out"; best_count="$count"; fi
  done
  [[ -n "$best" ]] && sed 's/^/    /' <<<"$best" | head -n 30
  return 0
}

echo
echo "== Patches =="
if grep -qE '^(src_unpack_hook|src_patch_hook|src_patch_apply_hook)\(\)|^DISTCLEANFILES=' "$cygport"; then
  echo "note: the recipe defines $(grep -oE '^(src_unpack_hook|src_patch_hook|src_patch_apply_hook)\(\)|^DISTCLEANFILES' "$cygport" | tr '\n' ' ')-- not run here, so results may differ from cygport's"
fi
if [[ -z "$source_ok" ]]; then
  echo "skipped: no source"
else
  set -f
  read -r -a patch_entries <<<"$PATCH_URI"
  set +f
  for entry in "${patch_entries[@]}"; do
    if [[ "$entry" == *://* ]]; then
      file="$(fetch "$entry" "$work/patches")" || { echo "FAILS: PATCH_URI $entry ($file)"; continue; }
    elif [[ -f "$top/$entry" ]]; then
      file="$top/$entry"
    else
      echo "FAILS (no such file in the package dir): $entry"
      continue
    fi
    case "$file" in
      *.tar.*|*.tgz|*.tbz2) echo "skipped (patch tarball, check by hand): $entry"; continue ;;
      *.gz) gunzip -c "$file" > "${file%.gz}"; file="${file%.gz}" ;;
      *.bz2) bunzip2 -c "$file" > "${file%.bz2}"; file="${file%.bz2}" ;;
      *.xz) xz -dc "$file" > "${file%.xz}"; file="${file%.xz}" ;;
      *.zst) zstd -qdc "$file" > "${file%.zst}"; file="${file%.zst}" ;;
    esac
    (cd "$work/origsrc/$SRC_DIR" && cygpatch "$file" "PATCH_URI $entry")
  done
  [[ ${#patch_entries[@]} -eq 0 ]] && echo "no PATCH_URI"

  rsync -a --delete "$work/origsrc/" "$work/src/"
  for f in "$pf.cygwin.patch" "$pf.src.patch"; do
    if [[ -f "$top/$f" ]]; then
      (cd "$work/src/$SRC_DIR" && cygpatch "$top/$f" "$f")
    fi
  done
  [[ -f "$top/$pf.src.patch" || -f "$top/$pf.cygwin.patch" ]] || echo "no .src.patch"
  echo "(origsrc/ has PATCH_URI applied, src/ also the .src.patch where it applied)"
fi

# 4. SOVERSION.
echo
echo "== SOVERSION =="
echo "current DLLs (master README file list):"
git -C "$ports" show "origin/master:$package/README" 2>/dev/null |
  grep -oE 'usr/bin/cyg[^[:space:]]*\.dll' | sort -u | sed 's/^/  /' || true
# *_CONTENTS, one line each (they're usually spread over several).
contents="$(perl -0ne 'while (/^(\w+_CONTENTS)="([^"]*)"/mg) { my ($n, $v) = ($1, $2); $v =~ s/\s+/ /g; $v =~ s/^ | $//g; print "$n=\"$v\"\n" }' "$cygport")"
echo "CONTENTS naming usr/bin in the recipe:"
grep 'usr/bin' <<<"$contents" | sed 's/^/  /' || echo "  (none)"
grep -E '^lib' <<<"$contents" | grep -vE '_(devel|doc)_CONTENTS=' |
  grep -E 'usr/bin(/\*\.dll|/)?["[:space:]]' >/dev/null &&
  echo "  -> a runtime package's DLL isn't pinned: pin it to usr/bin/cyg*-N.dll"
if [[ -n "$source_ok" ]]; then
  echo "SOVERSION settings in the new source (vendored/test dirs left out):"
  (cd "$work/origsrc/$SRC_DIR" &&
    grep -rnE --include='CMakeLists.txt' --include='*.cmake' --include='meson.build' \
      --include='configure.ac' --include='configure.in' --include='Makefile.am*' --include='*.pro' \
      -e 'SOVERSION|soversion|-version-info|-release [^ ]|LT_(CURRENT|REVISION|AGE|VERSION)|_(CURRENT|AGE|SO_?VERSION|ABI_VERSION)[[:space:]]*[=,(]|^[[:space:]]*VERSION[[:space:]]*=' . 2>/dev/null |
    grep -vE '^\./(third_party|thirdparty|vendor|external|extern|deps|3rdparty|test|tests)/' |
    head -n 40 | sed 's/^/  /' | grep . ||
    echo "  (none found: upstream sets no SOVERSION, or sets it somewhere else)") || true
  # A literal libtool -version-info C:R:A gives cyg<name>-(C-A).dll.
  (cd "$work/origsrc/$SRC_DIR" &&
    grep -rhoE --include='Makefile.am*' -e '-version-info[[:space:]]+[0-9]+:[0-9]+:[0-9]+' . 2>/dev/null |
    sort -u | while read -r _ cra; do
      IFS=: read -r c _ a <<<"$cra"
      echo "  libtool -version-info $cra -> DLL suffix -$((c - a))"
    done) || true
fi
# An override in the recipe or the .src.patch decides the DLL name instead
# of upstream's.
overrides="$(cat "$cygport" "$top/$pf.src.patch" 2>/dev/null |
  grep -nE '^\+?.*(SOVERSION|soversion|-version-info)' | grep -vE '^[0-9]+:-' || true)"
if [[ -n "$overrides" ]]; then
  echo "SOVERSION in the recipe / .src.patch (an override to check against upstream's):"
  sed 's/^[0-9]*:/  /' <<<"$overrides"
fi

# 5. LICENSE.
echo
echo "== LICENSE =="
for v in LICENSE LICENSE_SPDX LICENSE_URI; do
  grep -qE "^$v=" "$cygport" && echo "$v set" || echo "$v MISSING"
done
license_uri="$(sed -nE 's/^LICENSE_URI="?([^"]*)"?$/\1/p' "$cygport")"
if [[ -n "$license_uri" && "$license_uri" != *://* && -n "$source_ok" ]]; then
  [[ -e "$work/origsrc/$SRC_DIR/$license_uri" ]] &&
    echo "LICENSE_URI $license_uri exists in the new source" ||
    echo "LICENSE_URI $license_uri is NOT in the new source"
fi

# License texts whose license LICENSE doesn't include, marked when the
# new version added or changed them since the current one, and the ones
# it dropped (a license LICENSE may no longer need). A vendored library's
# text counts only if the build compiles what it covers (port-until-green's
# "Missing LICENSE"), which only the build files tell: BehaviorTree.CPP
# compiled its vendored minicoro (MIT-0 OR Unlicense) for releases before
# the recipe's MIT said so. Unrecognized texts below the top level are
# left out, as audit_recipe.sh does: at that depth LICENSE* matches
# source files too.
license_texts() {
  local root="$1" f rel ids
  while IFS= read -r -d '' f; do
    rel="${f#"$root"/}"
    ids="$(identify_license_text "$f" | sort -u | tr '\n' ' ')"
    ids="${ids% }"
    [[ -z "$ids" && "$rel" == */* ]] && continue
    printf '%s\t%s\n' "$rel" "${ids:-unrecognized}"
  done < <(license_text_files "$root")
}
if [[ -n "$source_ok" ]]; then
  license="$(sed -nE 's/^LICENSE="?([^"]*)"?$/\1/p' "$cygport")"
  declare -A recipe_base=() old_texts=()
  while IFS=$'\t' read -r _ id; do
    recipe_base["$(license_base "$id")"]=1
  done < <(printf 'recipe\t%s\n' "$license" | spdx_ids)
  license_texts "$work/origsrc/$SRC_DIR" > "$work/license-texts.new"
  if [[ -n "$old_s" ]]; then
    license_texts "$old_s" > "$work/license-texts.old"
    while IFS=$'\t' read -r rel ids; do
      old_texts["$rel"]="$ids"
    done < "$work/license-texts.old"
  else
    echo "(the $old_version source didn't download: nothing marked new or gone)"
  fi
  lacking=""
  while IFS=$'\t' read -r rel ids; do
    missing=""
    for id in $ids; do
      [[ "$id" == unrecognized || -n "${recipe_base[$(license_base "$id")]:-}" ]] || missing+=" $id"
    done
    mark=""
    if [[ -n "$old_s" ]]; then
      if [[ -z "${old_texts[$rel]+x}" ]]; then
        mark=" (new since $old_version)"
      elif [[ "${old_texts[$rel]}" != "$ids" ]]; then
        mark=" (changed since $old_version, was ${old_texts[$rel]})"
      fi
      unset 'old_texts[$rel]'
    fi
    if [[ -n "$missing" ]]; then
      lacking+="  $rel$mark: $ids -- LICENSE lacks${missing}"$'\n'
    elif [[ "$ids" == unrecognized ]]; then
      lacking+="  $rel$mark: unrecognized -- read it"$'\n'
    fi
  done < "$work/license-texts.new"
  if [[ -n "$lacking" ]]; then
    echo "license texts of licenses LICENSE doesn't include (one counts only if the build compiles what it covers -- see the build files):"
    printf '%s' "$lacking"
  else
    echo "every recognized license text's license is in LICENSE"
  fi
  for rel in "${!old_texts[@]}"; do
    echo "  $rel (gone since $old_version): ${old_texts[$rel]} -- check LICENSE still needs it"
  done
fi
