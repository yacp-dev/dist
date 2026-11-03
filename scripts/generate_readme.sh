#!/usr/bin/env bash
# Writes a package's README -- the file cygport embeds into
# usr/share/doc/Cygwin/<PN>.README and ports keeps next to the recipe --
# from what the build left behind. This is `xezat bump` in bash: same
# layout (xezat's README.erb), same sources for each part, except the
# build requirements' tools, which come from what the build did instead
# of from guesses at the source tree (below).
#
# Must run after a successful `cygport package` and before any
# `cygport ... clean`, since the file lists ($T/.<pkg>.lst) and the build
# tree are what it reads. The README it replaces is $C/README, which
# cygport_prep.sh copied from the package directory: its "Port Notes"
# are kept and get an entry for this release.
#
# Parts, in README order:
#
#   header          PN and DESCRIPTION, folded at 79 columns like facets'
#                   String#word_wrap (the same two regexes, in perl).
#   Runtime         `cygport dep`, with the directories of the built
#                   .exe/.dll/.so on PATH so it finds them; python3,
#                   perl5_0NN and ruby_NN become the installed package;
#                   REQUIRES are added as installed.
#   Build           the compilers (from the languages in the debuginfo's
#                   DWARF; without debuginfo, from the kinds of files the
#                   packages ship: .exe/.dll/.a/.so -> C, libgfortran or
#                   .mod -> Fortran), the tools the build evidently used
#                   (detect_tools), BUILD_REQUIRES and cygport itself,
#                   each as the installed package's name-version-release.
#   Canonical       HOMEPAGE, and the first of <VCS>_URI (the VCS cygclass
#                   inherited) or SRC_URI.
#   Files           $T/.<pkg>.lst of each package, directories left out,
#                   plus the README itself for the package named PN.
#   Port Notes      the existing ones, newest first, with this release's
#                   entry added (message, "Version bump." by default).
#                   A package's initial release entry is left as it is.
#
# Tools are what the build did, not what the source might need: a
# Makefile, build.ninja, CMakeCache.txt or meson-private in the build
# tree; autoreconf's own lines in the compile log for autoconf, automake,
# libtool and gettext's autopoint; python3 and gobject-introspection
# from what the packages install. BUILD_REQUIRES already names the rest
# (it's what the build ran with); add a case to detect_tools for one that
# turns out to matter.
#
# Usage (paths relative to the package directory, e.g. yacp/googletest):
#   generate_readme.sh --dir yacp/googletest --file googletest-1.18.0-1bl1.cygport \
#     [--message "Rebuild with gcc-14.4.0"] [--output README.new]
# Without --output it replaces $C/README. --previous FILE is the README
# whose Port Notes are carried over (default $C/README, which is already
# xezat's once that has run); --compare FILE writes nothing and diffs
# against FILE (--compare-built: $C/README) instead (build-package.yml runs it that way next to xezat). GENERATE_README_VARS, a file of
# `declare` lines, stands in for `cygport vars` (tests); GENERATE_README_DEP
# does the same for `cygport dep`'s output.

set -euo pipefail

# Who "Initial release" is credited to.
initial_release='Initial release by yacp-dev <https://github.com/yacp-dev>'

dir=""
cygport_file=""
message=""
output=""
previous=""
compare=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) dir="$2"; shift 2 ;;
    --file) cygport_file="$2"; shift 2 ;;
    --message) message="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    --previous) previous="$2"; shift 2 ;;
    --compare) compare="$2"; shift 2 ;;
    --compare-built) compare="@C"; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$dir" ]] || { echo "--dir is required" >&2; exit 1; }
[[ -n "$cygport_file" ]] || { echo "--file is required" >&2; exit 1; }
message="${message:-Version bump.}"

cd "$dir"
[[ -f "$cygport_file" || -n "${GENERATE_README_VARS:-}" ]] || { echo "No such file: $dir/$cygport_file" >&2; exit 1; }

# C sorts bytes, as Ruby's String#<=> does.
export LC_ALL=C

# --- variables ---------------------------------------------------------

vcs_vars=(BZR_URI CVS_URI FOSSIL_URI GIT_URI HG_URI MTN_URI SVN_URI)
if [[ -n "${GENERATE_README_VARS:-}" ]]; then
  vars_decl="$(cat "$GENERATE_README_VARS")"
else
  vars_decl="$(cygport "$cygport_file" vars PN P PF PV PVR PR DESCRIPTION HOMEPAGE SRC_URI PKG_NAMES \
    T D C S B logdir REQUIRES BUILD_REQUIRES "${vcs_vars[@]}")"
fi
PN="" P="" PF="" PV="" PVR="" PR="" DESCRIPTION="" HOMEPAGE="" SRC_URI="" PKG_NAMES=""
T="" D="" C="" S="" B="" logdir="" REQUIRES="" BUILD_REQUIRES=""
eval "$vars_decl"
[[ -n "$PN" && -n "$PVR" ]] || { echo "generate_readme.sh: cygport vars gave no PN/PVR" >&2; exit 1; }
# A recipe without PKG_NAMES builds the one package $PN, as cygport's
# pkg_name=(${PKG_NAMES:-${PN}}) does.
PKG_NAMES="${PKG_NAMES:-$PN}"
readme_in="${previous:-$C/README}"
installed_db="${AUDIT_INSTALLED_DB:-/etc/setup/installed.db}"

# --- installed packages ------------------------------------------------

declare -A installed=()
while read -r name file _; do
  [[ -n "${file:-}" ]] || continue
  installed["$name"]="$(sed -E 's/\.tar\.[A-Za-z0-9]+$//' <<<"$file")"
done < <(awk 'NF == 3' "$installed_db")

# A package's name-version-release, or nothing (a warning) when it isn't
# installed.
installed_name() {
  if [[ -n "${installed[$1]:-}" ]]; then
    printf '%s\n' "${installed[$1]}"
  else
    echo "::warning title=README::$1 is not installed, left out of the README" >&2
  fi
}

# --- runtime requirements ----------------------------------------------

runtime_requirements() {
  local out dep_path=""
  if [[ -n "${GENERATE_README_DEP:-}" ]]; then
    out="$(cat "$GENERATE_README_DEP")"
  else
    dep_path="$(find "$D" -type f \( -name '*.exe' -o -name '*.dll' -o -name '*.so' \) -printf '%h\n' 2>/dev/null | sort -u | paste -sd: -)"
    out="$(LANG=C PATH="${dep_path:+$dep_path:}$PATH" cygport "$cygport_file" dep)"
  fi
  {
    grep -v '\*\*\*' <<<"$out" | sed -E 's/^[[:space:]]+//' | awk 'NF' | while read -r pkg; do
      case "$pkg" in
        python3|python3[[:space:]]*) installed_name python3 ;;
        perl5_0[0-9][0-9]) installed_name perl_base ;;
        ruby_[0-9][0-9]) installed_name ruby ;;
        *) printf '%s\n' "$pkg" ;;
      esac
    done
    for pkg in $REQUIRES; do
      installed_name "$pkg"
    done
  } | sort -u
}

# --- build requirements ------------------------------------------------

# Languages of the compile units built from the package's own source
# (/usr/src/debug/$PF), one per line. The startup code and libgcc linked
# into every executable come from elsewhere and are left out.
debuginfo_languages() {
  local dbg_dir="$D/usr/lib/debug" dbg
  [[ -d "$dbg_dir" ]] || return 0
  while IFS= read -r -d '' dbg; do
    objdump --dwarf=info --dwarf-depth=1 "$dbg" 2>/dev/null | awk -v src="/usr/src/debug/$PF/" '
      function flush(   path, lang) {
        if (!in_unit || name == "") return
        path = (name ~ /^\//) ? name : comp_dir "/" name
        if (index(path, src) != 1) return
        if (lang_attr ~ /C\+\+/ || producer ~ /^GNU C\+\+/) lang = "C++"
        else if (lang_attr ~ /[Ff]ortran/ || producer ~ /^GNU (Fortran|F77)/) lang = "Fortran"
        else if (lang_attr ~ /^(ANSI |non-ANSI )?C[0-9]*$/ || producer ~ /^GNU C[0-9]*[ \t]/) lang = "C"
        if (lang != "") print lang
      }
      function val(   v) { v = $0; sub(/^.*DW_AT_[a-z_]+[ \t]*:[ \t]*/, "", v); sub(/^\([^)]*\):[ \t]*/, "", v); sub(/[ \t]+$/, "", v); return v }
      /\(DW_TAG_compile_unit\)/ { flush(); in_unit = 1; name = producer = comp_dir = lang_attr = ""; next }
      in_unit && /DW_AT_producer/ && producer == "" { producer = val() }
      in_unit && /DW_AT_language/ && lang_attr == "" { v = val(); if (match(v, /\([^)]*\)/)) lang_attr = substr(v, RSTART + 1, RLENGTH - 2) }
      in_unit && /DW_AT_name/ && name == "" { name = val() }
      in_unit && /DW_AT_comp_dir/ && comp_dir == "" { comp_dir = val() }
      END { flush() }'
  done < <(find "$dbg_dir" -type f -name '*.dbg' -print0 2>/dev/null) | sort -u
}

# Packages implied by the languages, as compilers.yaml had them.
compiler_packages() { # <runtimes-file> <files-file>
  local langs lang
  langs="$(debuginfo_languages)"
  if [[ -z "$langs" ]]; then
    if grep -qE '\.(exe|dll|a|so)$' "$2"; then langs="C"; fi
    if grep -q '^libgfortran' "$1" || grep -q '\.mod$' "$2"; then langs+=$'\nFortran'; fi
  fi
  for lang in $langs; do
    case "$lang" in
      C) printf '%s\n' gcc-core binutils ;;
      C++) printf '%s\n' gcc-g++ binutils ;;
      Fortran) printf '%s\n' gcc-fortran binutils gcc-core ;;
    esac
  done | sort -u
}

# Tools the build used, one package per line. What's looked at is what
# the build left, so a tool the package merely could use isn't listed.
detect_tools() {
  local logs=() log_text=""
  shopt -s nullglob
  logs=("$logdir"/*-compile.log)
  shopt -u nullglob
  (( ${#logs[@]} == 0 )) || log_text="$(cat "${logs[@]}" 2>/dev/null || true)"
  log_has() { grep -qE "$1" <<<"$log_text"; }
  tree_has() { [[ -d "$B" ]] && [[ -n "$(find "$B" -maxdepth "$1" "${@:2}" -print -quit 2>/dev/null)" ]]; }

  if tree_has 4 \( -name Makefile -o -name GNUmakefile -o -name makefile \) -type f \
     || log_has '^make(\[[0-9]+\])?: (Entering|Leaving) directory'; then echo make; fi
  tree_has 3 -name build.ninja -type f && echo ninja
  tree_has 2 -name CMakeCache.txt -type f && echo cmake
  tree_has 2 -name meson-private -type d && echo meson
  # Cygwin's autoreconf names itself autoreconf-2.73 in its log lines.
  if log_has '^autoreconf(-[0-9.]+)?: .*running: .*autoconf'; then echo autoconf; fi
  if log_has '^autoreconf(-[0-9.]+)?: .*running: .*automake'; then echo automake; fi
  if log_has '^libtoolize: ' || tree_has 2 -name libtool -type f; then echo libtool; fi
  if log_has '^autoreconf(-[0-9.]+)?: .*running: .*(autopoint|gettextize)|^(autopoint|gettextize): '; then echo gettext-devel; fi
  [[ -d "$D/usr/lib/girepository-1.0" ]] && echo gobject-introspection
  if compgen -G "$D/usr/lib/python3.*" > /dev/null \
     || { [[ -d "$D" ]] && [[ -n "$(find "$D" -type f -name '*.py' -exec head -n 1 {} + 2>/dev/null | grep -m1 -E '^#!\s*(/usr/bin/env\s+)?(/usr/bin/)?python3?(\.[0-9]+)?\s*$' || true)" ]]; }; then
    echo python3
  fi
  return 0
}

build_requirements() { # <runtimes-file> <files-file>
  local names pkg
  names="$(
    {
      compiler_packages "$1" "$2"
      detect_tools
      for pkg in $BUILD_REQUIRES; do echo "$pkg"; done
      echo cygport
    } | sort -u)"
  # A versioned libssl or lua makes the unversioned one redundant.
  if grep -qx 'libssl1.0-devel' <<<"$names"; then names="$(grep -vx 'libssl-devel' <<<"$names" || true)"; fi
  if grep -qxE 'lua5\.1-devel|luajit-devel' <<<"$names"; then names="$(grep -vx 'lua' <<<"$names" || true)"; fi
  # gcc-fortran only with libgfortran or .mod files in what's built.
  if ! grep -q '^libgfortran' "$1" && ! grep -q '\.mod$' "$2"; then
    names="$(grep -vx 'gcc-fortran' <<<"$names" || true)"
  fi
  while read -r pkg; do
    [[ -n "$pkg" ]] && installed_name "$pkg"
  done <<<"$names" | sort -u
}

# --- files -------------------------------------------------------------

package_files() { # <pkg>
  local lst="$T/.$1.lst"
  [[ -r "$lst" ]] || { echo "generate_readme.sh: no such file: $lst" >&2; return 1; }
  {
    sed -E 's/[[:space:]]+$//' "$lst" | { grep -v '/$' || true; } | sed 's|^|/|'
    if [[ "$1" == "$PN" ]]; then echo "/usr/share/doc/Cygwin/$PN.README"; fi
  } | sort -u
}

# --- port notes --------------------------------------------------------

# "<version>\t<line>" for each line of the existing Port Notes. Blank
# lines are dropped, trailing blanks stripped; a line before the first
# version header is an error, as in xezat.
existing_notes() {
  [[ -f "$readme_in" ]] || return 0
  awk '
    /^Port Notes:[ \t]*$/ { on = 1; next }
    !on { next }
    { sub(/[ \t\r]+$/, "") }
    match($0, /^----- version .+ -----$/) { v = substr($0, 15, length($0) - 14 - 6); next }
    $0 == "" { next }
    v == "" { print "generate_readme.sh: README syntax error: version missing" > "/dev/stderr"; exit 1 }
    { print v "\t" $0 }' "$readme_in"
}

port_notes() {
  local notes versions count
  notes="$(existing_notes)"
  if [[ -z "$notes" && ! -f "$readme_in" ]]; then
    printf '%s\t%s\n' "$PVR" "$initial_release"
    return
  fi
  count="$(cut -f1 <<<"$notes" | awk 'NF && !seen[$0]++' | wc -l | tr -d ' ')"
  if (( count > 1 )) || ! grep -q "^$(sed 's/[][\.*^$/]/\\&/g' <<<"$PVR")	" <<<"$notes"; then
    # This release's entry is replaced, or goes first (the newest).
    { printf '%s\t%s\n' "$PVR" "$message"; grep -v "^$(sed 's/[][\.*^$/]/\\&/g' <<<"$PVR")	" <<<"$notes" || true; } | awk 'NF'
  else
    echo "::warning title=README::Initial release protected" >&2
    printf '%s\n' "$notes"
  fi
}

# --- output ------------------------------------------------------------

fold_description() {
  perl -e '
    my $s = join(" ", split(" ", $ARGV[0]));
    $s =~ s/(\S{79})(?=\S)/$1 /g;
    $s =~ s/(.{1,79})(?:\s+|$)/$1\n/mg;
    print $s;' -- "$DESCRIPTION"
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

: > "$work/files"
for pkg in $PKG_NAMES; do
  package_files "$pkg" > "$work/files.$pkg"
  cat "$work/files.$pkg" >> "$work/files"
done
runtime_requirements > "$work/runtime"
build_requirements "$work/runtime" "$work/files" > "$work/build"
port_notes > "$work/notes"

download="$SRC_URI"
for vcs in "${vcs_vars[@]}"; do
  if [[ -n "${!vcs:-}" ]]; then download="${!vcs}"; break; fi
done
# SRC_URI may start with a newline and indentation (one URI per line).
download="${download#"${download%%[![:space:]]*}"}"
download="${download%%[[:space:]]*}"

release_less="${PVR%-"$PR"}"

render() {
  echo "$PN"
  echo "------------------------------------------"
  fold_description
  echo
  echo "Runtime requirements:"
  sed 's/^/  /' "$work/runtime"
  echo
  echo "Build requirements:"
  echo "(besides corresponding -devel packages)"
  sed 's/^/  /' "$work/build"
  echo
  echo "Canonical website:"
  echo "  $HOMEPAGE"
  echo
  echo "Canonical download:"
  echo "  ${download%%[[:space:]]*}"
  echo
  echo "-------------------------------------------"
  echo
  echo "Build instructions:"
  echo "  1. unpack $P-X-src.tar.xz"
  echo "  2. if you use setup to install this src package,"
  echo "     it will be unpacked under /usr/src automatically"
  echo "        % cd /usr/src"
  echo "        % cygport ./$P-X.cygport all"
  echo
  echo "This will create:"
  echo "  /usr/src/$P-X-src.tar.xz"
  for pkg in $PKG_NAMES; do
    echo "  /usr/src/$pkg-$release_less-X.tar.xz"
  done
  echo
  echo "-------------------------------------------"
  echo
  echo "Files included in the binary package:"
  echo
  for pkg in $PKG_NAMES; do
    echo "($pkg)"
    sed 's/^/  /' "$work/files.$pkg"
    echo
  done
  echo "------------------"
  echo
  echo "Port Notes:"
  echo
  # Versions newest first: this release's entry is already first, and
  # the existing ones keep the order they were written in.
  awk -F'\t' '
    !($1 in seen) { seen[$1] = 1; order[++n] = $1 }
    { text[$1] = ($1 in text) ? text[$1] "\n" $2 : $2 }
    END { for (i = 1; i <= n; i++) printf "----- version %s -----\n%s\n\n", order[i], text[order[i]] }' "$work/notes"
}

# The template's last newline is dropped (xezat chops it).
render > "$work/readme"
perl -0pi -e 's/\n\z//' "$work/readme"

# --compare FILE: don't write anything, say how this differs from FILE
# (`xezat bump`'s README) -- the run summary and a warning when it does,
# and the step output compare=identical when it doesn't, which Audit recipe
# lists among what it found fine.
if [[ -n "$compare" ]]; then
  [[ "$compare" == @C ]] && compare="$C/README"
  if diff -u "$compare" "$work/readme" > "$work/diff"; then
    echo "generate_readme.sh: identical to $compare"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
      echo "compare=identical" >> "$GITHUB_OUTPUT"
    fi
  else
    echo "::warning title=README differs from xezat's::generate_readme.sh's README is not xezat bump's, see the run summary"
    cat "$work/diff"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
      {
        echo "### README differs from xezat bump's"
        echo
        echo '```diff'
        cat "$work/diff"
        echo '```'
        echo
      } >> "$GITHUB_STEP_SUMMARY"
    fi
  fi
  exit 0
fi

dest="${output:-$C/README}"
mkdir -p "$(dirname "$dest")"
cp -f "$work/readme" "$dest"
