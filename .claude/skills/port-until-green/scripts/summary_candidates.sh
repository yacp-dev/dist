#!/usr/bin/env bash
# Whether a recipe's SUMMARY is over 80 characters, and if so, the short
# descriptions upstream and the distros give the package, as candidates
# for a shorter one. Only reports: the SUMMARY is the user's to change.
#
# Sources, each printed with its length (and "fits" when at most 80):
#   - the GitHub repository's description (HOMEPAGE or SRC_URI/GIT_URI
#     on github.com),
#   - HOMEPAGE's <meta name="description">, og:description and <title>,
#   - Debian's binary package short descriptions (debian/control of the
#     newest source package, by the package's lowercase name or --debian),
#   - Repology's summaries (project = the lowercase name, or --repology).
#
# Usage:
#   summary_candidates.sh --recipe path/to/<pkg>-<ver>-<rel>.cygport
#                         [--package P] [--repology NAME] [--debian NAME]
#                         [--max 80]
# --package defaults to the recipe's directory name.
# Output: "summary: <N> chars (ok|over <max>)", then, when over, one
# "candidate (<source>, <N> chars[, fits]): <text>" line per candidate.
# Exit status 0 either way; 2 on bad usage.

set -euo pipefail

usage() {
  echo "Usage: $0 --recipe F [--package P] [--repology NAME] [--debian NAME] [--max N]" >&2
  exit 2
}

recipe="" package="" repology="" debian="" max=80
while [[ $# -gt 0 ]]; do
  case "$1" in
    --recipe) recipe="$2"; shift 2 ;;
    --package) package="$2"; shift 2 ;;
    --repology) repology="$2"; shift 2 ;;
    --debian) debian="$2"; shift 2 ;;
    --max) max="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -f "$recipe" ]] || usage
[[ -n "$package" ]] || package="$(basename "$(dirname "$(cd "$(dirname "$recipe")" && pwd)/x")")"
lower="$(tr '[:upper:]' '[:lower:]' <<<"$package")"
[[ -n "$repology" ]] || repology="$lower"
[[ -n "$debian" ]] || debian="$lower"

# A variable's literal value as written (single line), ${PN} expanded.
recipe_value() {
  sed -nE "s/^$1=\"([^\"]*)\".*/\1/p; s/^$1='([^']*)'.*/\1/p" "$recipe" | head -n 1 |
    sed "s/\${PN}/$package/g; s/\$PN/$package/g"
}

summary="$(recipe_value SUMMARY)"
if [[ -z "$summary" ]]; then
  echo "summary: not set"
  exit 0
fi
len=${#summary}
if (( len <= max )); then
  echo "summary: $len chars (ok)"
  exit 0
fi
echo "summary: $len chars (over $max): $summary"

candidates=()
add() {  # source text
  local text
  text="$(tr -s ' \t\n' ' ' <<<"$2" | sed 's/^ //; s/ $//; s/\.$//')"
  [[ -n "$text" ]] || return 0
  candidates+=("$1"$'\t'"$text")
}

homepage="$(recipe_value HOMEPAGE)"
repo="$(printf '%s\n%s\n%s\n' "$homepage" "$(recipe_value SRC_URI)" "$(recipe_value GIT_URI)" |
  sed -nE 's|^https?://github\.com/([^/]+)/([^/#?]+).*|\1/\2|p' | sed 's/\.git$//' | head -n 1)"
if [[ -n "$repo" ]]; then
  add "GitHub $repo" "$(curl -sL --retry 2 "https://api.github.com/repos/$repo" |
    perl -MJSON::PP -0e 'my $d = eval { decode_json(<STDIN>) } || {}; print $d->{description} // ""')"
fi

if [[ -n "$homepage" && "$homepage" != *github.com/* ]]; then
  page="$(curl -sL --retry 2 --max-time 20 "$homepage" 2>/dev/null | head -c 500000)" || page=""
  if [[ -n "$page" ]]; then
    while IFS=$'\t' read -r src text; do
      add "$src" "$text"
    done < <(perl -0ne '
      sub un { my $s = shift; $s =~ s/&amp;/&/g; $s =~ s/&lt;/</g; $s =~ s/&gt;/>/g; $s =~ s/&quot;/"/g; $s =~ s/&#39;/'\''/g; $s =~ s/\s+/ /g; $s }
      for my $n ("description", "og:description") {
        if (/<meta\b[^>]*(?:name|property)=["\x27]\Q$n\E["\x27][^>]*content=["\x27]([^"\x27]*)/i
            || /<meta\b[^>]*content=["\x27]([^"\x27]*)["\x27][^>]*(?:name|property)=["\x27]\Q$n\E["\x27]/i) {
          print "homepage $n\t", un($1), "\n";
        }
      }
      print "homepage title\t", un($1), "\n" if /<title[^>]*>(.*?)<\/title>/is;
    ' <<<"$page")
  fi
fi

deb_ver="$(curl -sL --retry 2 "https://sources.debian.org/api/src/$debian/" |
  perl -MJSON::PP -0e 'my $d = eval { decode_json(<STDIN>) } || {}; my $v = $d->{versions} || []; print $v->[0]{version} // ""')" || deb_ver=""
if [[ -n "$deb_ver" ]]; then
  deb_ver_url="${deb_ver//+/%2B}"
  while IFS=$'\t' read -r src text; do
    add "$src" "$text"
  done < <(curl -sL --retry 2 "https://sources.debian.org/data/main/${debian:0:1}/$debian/$deb_ver_url/debian/control" |
    awk -v v="$deb_ver" '/^Package:/ { p = $2 } /^Description:/ { sub(/^Description:[[:space:]]*/, ""); print "Debian " p " " v "\t" $0 }')
fi

sleep 1  # Repology asks for at most one request a second
while IFS=$'\t' read -r src text; do
  add "$src" "$text"
done < <(curl -sL --retry 2 -A 'port-until-green' "https://repology.org/api/v1/project/$repology" |
  perl -MJSON::PP -0e 'my $d = eval { decode_json(<STDIN>) } || []; my %seen;
    for (@$d) { my $s = $_->{summary} // next; next if $_->{repo} eq "yacp" || $seen{$s}++; print "Repology $_->{repo}\t$s\n" }')

if (( ${#candidates[@]} == 0 )); then
  echo "no short description found upstream or in the distros -- shorten it by hand"
  exit 0
fi
declare -A shown=()
for c in "${candidates[@]}"; do
  src="${c%%$'\t'*}" text="${c#*$'\t'}"
  [[ -z "${shown[$text]:-}" ]] || continue
  shown[$text]=1
  n=${#text}
  note="$n chars"
  (( n <= max )) && note+=", fits"
  echo "candidate ($src, $note): $text"
done
