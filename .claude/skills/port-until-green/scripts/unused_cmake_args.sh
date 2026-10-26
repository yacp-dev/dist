#!/usr/bin/env bash
# Lists the -D<VAR> a cmake recipe passes (CYGCMAKE_ARGS, or a cygcmake
# call) that no build file in the source reads. CMake only warns about
# them ("Manually-specified variables were not used by the project") in
# the compile log of a run, where nobody looks once it's green: onnx's
# -DONNX_BUILD_BENCHMARKS outlived the option by several releases.
#
# A variable counts as read when its name appears as a word in any
# CMakeLists.txt, *.cmake or *.cmake.in under the source, vendored
# directories included (a subproject may read it), outside comments and
# message() calls, or anywhere in a header template configure_file()
# fills in (*.h.in, *.h.cmake: libwebsockets' LWS_WITH_SERVER_STATUS is
# only in lws_config.h.in's #cmakedefine, which isn't a comment there).
# A variable only shown in the configure summary changes nothing
# (uvwasi's UVWASI_BUILD_TESTS, printed under "Build tests:" while
# BUILD_TESTING decided), and CMake doesn't warn about it either, since
# printing it reads it. Not checked, since
# CMake's own modules read them: CMAKE_*, BUILD_SHARED_LIBS,
# BUILD_TESTING, and <Pkg>_* for a find_package(<Pkg>) in the source.
# A name built from other variables (${PROJECT_NAME}_BUILD_TESTS) can't
# be seen this way: the log's CMake warning is the final word.
#
# Usage:
#   unused_cmake_args.sh --recipe FILE.cygport --source DIR [--old-source DIR]
# --old-source marks which of them the current version still read, i.e.
# which went unused with the new version.
# Output: one line per unused variable; nothing when all are read.

set -euo pipefail

recipe=""
src=""
old_src=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --recipe) recipe="$2"; shift 2 ;;
    --source) src="$2"; shift 2 ;;
    --old-source) old_src="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -f "$recipe" ]] || { echo "--recipe must be a file" >&2; exit 1; }
[[ -d "$src" ]] || { echo "--source must be a directory" >&2; exit 1; }

# The -D names in CYGCMAKE_ARGS (however many assignments, quoted over
# several lines) and on cygcmake command lines.
vars="$(perl -0ne '
  while (/^\s*CYGCMAKE_ARGS\+?=("(?:[^"\\]|\\.)*"|'\''[^'\'']*'\''|\S*)/mg) { print "$1\n" }
  while (/^\s*cygcmake\b([^\n]*(?:\\\n[^\n]*)*)/mg) { print "$1\n" }' "$recipe" |
  grep -oE -- '-D[A-Za-z_][A-Za-z0-9_]*' | sed 's/^-D//' | sort -u)" || true
[[ -n "$vars" ]] || exit 0

build_files() {
  find "$1" -type f \( -name CMakeLists.txt -o -name '*.cmake' -o -name '*.cmake.in' -o -name '*.h.in' \) -print0
}

# Whether a build file under $1 names $2 as a word, leaving out
# comments and message() calls. The file list is read whole before
# perl can exit on a match: otherwise find dies of SIGPIPE, and
# pipefail turns a found variable into an unused one (libwebsockets'
# 342 build files).
reads() {
  build_files "$1" | perl -0e '
    my $v = shift;
    my @files = <STDIN>;
    for my $f (@files) {
      chomp $f;
      open(my $fh, "<", $f) or next;
      my $s = do { local $/; <$fh> };
      if ($f =~ /\.h\.(?:in|cmake)$/) {
        exit 0 if $s =~ /(?<![A-Za-z0-9_])\Q$v\E(?![A-Za-z0-9_])/;
        next;
      }
      $s =~ s/#\[(=*)\[.*?\]\1\]//gs;
      $s =~ s/("(?:[^"\\]|\\.)*")|#[^\n]*/defined $1 ? $1 : ""/ge;
      $s =~ s/\bmessage\s*\((?:[^()"]|"(?:[^"\\]|\\.)*"|\((?:[^()"]|"(?:[^"\\]|\\.)*")*\))*\)//gi;
      exit 0 if $s =~ /(?<![A-Za-z0-9_])\Q$v\E(?![A-Za-z0-9_])/;
    }
    exit 1' "$2" 2>/dev/null
}

# A find_package() of the project itself (onnx's examples look up ONNX)
# says nothing about its own options.
projects="$(build_files "$src" | xargs -0 grep -hoiE '^[[:space:]]*project[[:space:]]*\([[:space:]]*[A-Za-z0-9_]+' 2>/dev/null |
  sed -E 's/.*\([[:space:]]*//' | sort -u)" || true
packages="$(build_files "$src" | xargs -0 grep -hoiE 'find_package[[:space:]]*\([[:space:]]*[A-Za-z0-9_]+' 2>/dev/null |
  sed -E 's/.*\([[:space:]]*//' | sort -u | grep -vixF -e "${projects:-}" -e '')" || true

while IFS= read -r v; do
  case "$v" in
    CMAKE_*|BUILD_SHARED_LIBS|BUILD_TESTING) continue ;;
  esac
  skip=""
  while IFS= read -r p; do
    [[ -n "$p" && "$v" == "$p"_* ]] && { skip=1; break; }
  done <<<"$packages"
  [[ -n "$skip" ]] && continue
  reads "$src" "$v" && continue
  mark=""
  if [[ -n "$old_src" && -d "$old_src" ]]; then
    reads "$old_src" "$v" && mark=" (read by the current version: dropped with this one)" ||
      mark=" (the current version doesn't read it either)"
  fi
  echo "$v$mark"
done <<<"$vars"
