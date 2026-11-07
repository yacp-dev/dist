#!/usr/bin/env bash
# Whether a cmake recipe needs -DCMAKE_POLICY_VERSION_MINIMUM=3.5: CMake
# 4.0 refuses to configure a project whose cmake_minimum_required() (or
# cmake_policy(VERSION)) asks for less than 3.5, and the flag is the
# workaround. Read statically from the source's build files, so it's said
# before a build has to fail on it -- and said the other way round too,
# when the recipe passes the flag but no build file asks for less than 3.5
# any more (it would otherwise outlive its need on a green build;
# unused_cmake_args.sh skips CMAKE_* names).
#
# A build file counts when, outside comments, it has
# cmake_minimum_required(VERSION X) or cmake_policy(VERSION X) with X
# below 3.5. For a range (VERSION 3.1...3.27) CMake uses the upper end,
# so that is what is compared. A version given as a variable can't be
# read and is left out; so is anything the build downloads for itself
# (FetchContent, ExternalProject: audit_recipe.sh's build-time downloads
# lists those). Vendored directories and subdirectories the build never
# enters are included, so a hit there is a candidate, not a proof.
#
# Usage:
#   cmake_min_version.sh --recipe FILE.cygport --source DIR
# Output: a verdict line, then up to 10 offending files (file:line:
# declaration). Verdicts: "needs the flag", "flag set, but needed",
# "flag set, but no build file asks for less than 3.5 (drop it?)",
# "not needed".

set -euo pipefail

recipe=""
src=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --recipe) recipe="$2"; shift 2 ;;
    --source) src="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -f "$recipe" ]] || { echo "--recipe must be a file" >&2; exit 1; }
[[ -d "$src" ]] || { echo "--source must be a directory" >&2; exit 1; }

flagged=""
grep -qE -- '-DCMAKE_POLICY_VERSION_MINIMUM\b' "$recipe" && flagged=1

# "file:line: declaration" for each declaration below 3.5. The file list
# is read whole before perl runs (find would die of SIGPIPE otherwise).
hits="$(find "$src" -type f \( -name CMakeLists.txt -o -name '*.cmake' \) -print0 | perl -0e '
  my $root = shift;
  my @files = <STDIN>;
  sub below { my @v = split /\./, shift; push @v, 0 while @v < 3; return ($v[0] <=> 3 || $v[1] <=> 5) < 0 }
  for my $f (sort @files) {
    chomp $f;
    open(my $fh, "<", $f) or next;
    my $s = do { local $/; <$fh> };
    $s =~ s/#\[(=*)\[.*?\]\1\]//gs;
    $s =~ s/("(?:[^"\\]|\\.)*")|#[^\n]*/defined $1 ? $1 : ""/ge;
    while ($s =~ /\b(cmake_minimum_required|cmake_policy)\s*\(\s*VERSION\s+([0-9]+(?:\.[0-9]+)*)(?:\.\.\.<?([0-9]+(?:\.[0-9]+)*))?/gi) {
      my ($fn, $lo, $hi) = ($1, $2, $3);
      my $eff = defined $hi ? $hi : $lo;
      next unless below($eff);
      my $line = 1 + (substr($s, 0, $-[0]) =~ tr/\n//);
      (my $rel = $f) =~ s/^\Q$root\E\/?//;
      print "$rel:$line: $fn(VERSION $lo" . (defined $hi ? "...$hi" : "") . ")\n";
    }
  }' "$src")" || true

if [[ -n "$hits" ]]; then
  if [[ -n "$flagged" ]]; then
    echo "flag set, and needed: $(wc -l <<<"$hits" | tr -d ' ') declaration(s) below 3.5"
  else
    echo "needs -DCMAKE_POLICY_VERSION_MINIMUM:STRING=3.5: $(wc -l <<<"$hits" | tr -d ' ') declaration(s) below 3.5"
  fi
  head -n 10 <<<"$hits" | sed 's/^/  /'
  n="$(wc -l <<<"$hits" | tr -d ' ')"
  (( n > 10 )) && echo "  ... and $((n - 10)) more"
elif [[ -n "$flagged" ]]; then
  echo "flag set, but no build file asks for less than 3.5 (drop it?)"
else
  echo "not needed"
fi
exit 0
