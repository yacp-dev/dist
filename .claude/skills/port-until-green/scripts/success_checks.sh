#!/usr/bin/env bash
# Everything Step 2's Success checks look at on a green build-package
# run, in one go:
#   == PR               the branch's PR and whether it's still a draft
#   == Check            check_summary.sh's output
#   == Recipe           LICENSE/LICENSE_SPDX/LICENSE_URI missing from the
#                       branch's cygport, or `inherit git` with neither
#                       GIT_REV nor GIT_TAG
#   == Audit            each section of the Audit recipe report with a
#                       WARNING: line, whole, plus "Dependencies the
#                       build didn't find" (candidates, not warnings)
#                       when it names a Cygwin package that has one;
#                       Check is left to the section above
#   == PR body          the ".src.patch lost changes" block, if any
# and a last line, "to look at: N" (0 = nothing beyond the Check verdict).
#
# Usage:
#   success_checks.sh --run 123456789 --package knot --version 3.6.2

set -euo pipefail

repo="yacp-dev/dist"
ports="yacp-dev/ports"
run="" pkg="" ver=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run) run="$2"; shift 2 ;;
    --package) pkg="$2"; shift 2 ;;
    --version) ver="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done
[[ -n "$run" && -n "$pkg" && -n "$ver" ]] || { echo "--run, --package and --version are required" >&2; exit 1; }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
branch="dorgann/$pkg-$ver"
todo=0

conclusion="$(gh run view "$run" -R "$repo" --json conclusion --jq .conclusion)"
if [[ "$conclusion" != success ]]; then
  echo "run $run: ${conclusion:-not finished} -- these checks are for a green run"
  exit 1
fi

echo "== PR"
pr="$(gh pr list -R "$ports" --head "$branch" --state open --json url,isDraft \
  --jq '.[0] | select(.) | .url + (if .isDraft then " DRAFT" else " ready" end)')"
if [[ -z "$pr" ]]; then
  echo "no open PR for $branch"; todo=$((todo + 1))
else
  echo "$pr"
  [[ "$pr" == *DRAFT ]] && todo=$((todo + 1))
fi

echo
echo "== Check"
bash "$here/check_summary.sh" --run "$run"

echo
echo "== Recipe"
cygport="$(gh api "repos/$ports/contents/$pkg?ref=$branch" --jq '.[].name | select(endswith(".cygport"))' | head -n 1)"
if [[ -z "$cygport" ]]; then
  echo "no .cygport in $pkg/ on $branch"; todo=$((todo + 1))
else
  recipe="$(gh api "repos/$ports/contents/$pkg/$cygport?ref=$branch" -H 'Accept: application/vnd.github.raw')"
  found=0
  for v in LICENSE LICENSE_SPDX LICENSE_URI; do
    if ! grep -qE "^$v=" <<<"$recipe"; then
      echo "$v is not defined (Missing LICENSE)"; found=1
    fi
  done
  if grep -qE '^inherit .*\bgit\b' <<<"$recipe" && ! grep -qE '^GIT_(REV|TAG)=' <<<"$recipe"; then
    echo "inherit git with neither GIT_REV nor GIT_TAG (Git HEAD, Step 1b)"; found=1
  fi
  if (( found )); then todo=$((todo + 1)); else echo "ok"; fi
fi

# The Audit recipe step's lines: third tab-separated field is
# "<timestamp> <line>". When GitHub's log loses the step names
# ("UNKNOWN STEP"), every line is searched for the section headers.
echo
echo "== Audit"
log="$(gh run view "$run" -R "$repo" --log | perl -pe 's/\e\[[0-9;]*m//g')"
if awk -F'\t' '$2 == "Audit recipe" { f = 1 } END { exit !f }' <<<"$log"; then
  filter=audit
else
  filter=any
fi
audit="$(awk -F'\t' -v f="$filter" 'f == "any" || $2 == "Audit recipe" { sub(/^[^ ]+ /, "", $3); print $3 }' <<<"$log" |
  awk '
    function flush() {
      if (name != "" && name != "Check" && (warn || cand))
        { printf "%s%s", hdr, body; n++ }
      name = ""; body = ""; warn = 0; cand = 0
    }
    /^== .* ==$/ { flush(); name = substr($0, 4, length($0) - 6); hdr = $0 "\n"; next }
    /^[0-9]+ warning\(s\)/ || /^##\[/ || /^-- checked/ { flush(); next }
    name != "" {
      body = body $0 "\n"
      if ($0 ~ /^WARNING: /) warn = 1
      # A Cygwin package that has what the build went without.
      if (name ~ /^Dependencies the build didn/ && $0 ~ /: Cygwin has it in |, which is installed -- /) cand = 1
    }
    END { flush(); print "sections: " n + 0 }
  ')"
sections="${audit##*sections: }"
audit="${audit%sections: *}"
if (( sections > 0 )); then
  printf '%s' "$audit"
  todo=$((todo + sections))
else
  echo "no WARNING"
fi

echo
echo "== PR body"
body=""
[[ -n "$pr" ]] && body="$(gh pr view "${pr%% *}" -R "$ports" --json body --jq .body)"
lost="$(awk '/^#### \.src\.patch lost changes/ { on = 1 } on && /^#### / && !/lost changes/ { on = 0 } on' <<<"$body")"
if [[ -n "$lost" ]]; then
  echo "$lost"; todo=$((todo + 1))
else
  echo "no .src.patch lost changes"
fi

echo
echo "to look at: $todo"
