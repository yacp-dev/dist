#!/usr/bin/env bash
# Removes a package from yacp: first its binaries from dist, then its
# recipe from ports (doc/spec.md 4.4.3). Without --execute it only reports
# what it would do. Run it again after a failure: a step already done is
# skipped, since the package is then simply not there.
#
# <package> is the directory name in ports, which is also the source
# package's directory in dist. It stops, removing nothing, on anything that
# still needs the package:
#   - in setup.ini, another source package's depends2/requires/build-depends
#   - in ports master, another recipe's BUILD_REQUIRES, DEPEND or *_REQUIRES,
#     or a README's requirement lists. setup.ini can't answer this alone: it
#     only knows published packages, a fraction of ports
#   - a dorgann/<package>-<version> branch: merging its PR would publish the
#     package again
#
# The names to look for are the binary packages in setup.ini plus the
# recipe's PKG_NAMES, since master can have subpackages dist doesn't yet,
# and an unpublished recipe has only those. PKG_NAMES is read rather than
# evaluated (no cygport here), knowing ${PN}, ${PV} and ${PV[n]}. Anything
# else in it stops the script: looking for the wrong names would report
# "no dependents" with nothing behind it. --names gives them by hand then.
#
# gh-pages is only ever changed by unpublish.yml, queued with publish.yml.
# A run waiting in a concurrency group is cancelled by the next one queued,
# so this waits for those workflows to be idle before dispatching, not to
# cancel a publish, and goes no further unless its own run succeeded.
#
# Usage: remove_package.sh <package> [--execute] [--names "a b c"]
#   [--ports-dir DIR]
# Exit status 0 if removed (or, without --execute, removable), 1 otherwise.

set -euo pipefail

dist_repo="yacp-dev/dist"
ports_repo="yacp-dev/ports"
site="https://dist.yacp.dev/x86_64/setup.ini"
ports_dir="$HOME/src/ports"
package=""
execute=0
names_override=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --execute) execute=1; shift ;;
    --names) names_override="$2"; shift 2 ;;
    --ports-dir) ports_dir="$2"; shift 2 ;;
    -*) echo "Unknown argument: $1" >&2; exit 1 ;;
    *)
      [[ -z "$package" ]] || { echo "Only one package at a time: $1" >&2; exit 1; }
      package="$1"
      shift
      ;;
  esac
done

[[ -n "$package" ]] || { echo "Usage: remove_package.sh <package> [--execute]" >&2; exit 1; }
if [[ ! "$package" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]; then
  echo "Not a package name: $package" >&2
  exit 1
fi

here="$(cd "$(dirname "$0")" && pwd)"
wait_run="$here/../.claude/skills/port-until-green/scripts/wait_run.sh"
ref="origin/master"
tmp="$(mktemp -d)"
worktree=""

cleanup() {
  if [[ -n "$worktree" ]]; then
    git -C "$ports_dir" worktree remove --force "$worktree" 2>/dev/null || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

# Prints the whitespace-separated words assigned to the variables whose
# name matches the regex $1, in the recipe on stdin. Follows every
# assignment, wanted or not, so that a line inside a multi-line DESCRIPTION
# isn't taken for an assignment.
recipe_values() {
  awk -v want="$1" '
    function emit(s,    k, i, w) {
      k = split(s, w, /[ \t]+/)
      for (i = 1; i <= k; i++) if (w[i] != "") print w[i]
    }
    # The quote closing the value, past any backslash-escaped ones.
    function closing(s, q,    t) {
      t = s
      gsub(/\\./, "__", t)
      return index(t, q)
    }
    quote != "" {
      p = closing($0, quote)
      if (p) {
        if (wanted) emit(substr($0, 1, p - 1))
        quote = ""
      } else if (wanted) {
        emit($0)
      }
      next
    }
    /^[ \t]*#/ { next }
    match($0, /^[ \t]*(export[ \t]+)?[A-Za-z_][A-Za-z0-9_]*\+?=/) {
      lhs = substr($0, 1, RLENGTH)
      rest = substr($0, RLENGTH + 1)
      gsub(/^[ \t]*(export[ \t]+)?/, "", lhs)
      sub(/\+?=$/, "", lhs)
      wanted = (lhs ~ want)
      q = substr(rest, 1, 1)
      if (q == "\"" || q == "\047") {
        rest = substr(rest, 2)
        p = closing(rest, q)
        if (p) {
          if (wanted) emit(substr(rest, 1, p - 1))
        } else {
          if (wanted) emit(rest)
          quote = q
        }
      } else if (wanted) {
        sub(/[ \t;#].*$/, "", rest)
        emit(rest)
      }
    }
  '
}

# Prints the packages of a README's requirement lists: `  <name>-<ver>-<rel>`
# lines, between "Runtime requirements:" and "Canonical website:".
readme_requirements() {
  awk '
    /^Runtime requirements:/ { on = 1; next }
    /^Canonical website:/ { on = 0 }
    on && /^[ \t]+[^ \t]+-[^-]+-[^- \t]+[ \t]*$/ {
      name = $1
      sub(/-[^-]+-[^-]+$/, "", name)
      print name
    }
  '
}

# Prints the recipe's binary package names. Exit status 1 on one it can't
# expand.
recipe_package_names() {
  local dir="$1" recipe base pv rest i token found=0 parts
  for recipe in $(git -C "$ports_dir" ls-tree --name-only "$ref:$dir" | grep '\.cygport$'); do
    base="${recipe%.cygport}"
    pv="${base%-*}"
    pv="${pv#"$dir"-}"
    parts="$(printf '%s' "$pv" | tr '.+_-' ' ')"
    rest="$(git -C "$ports_dir" show "$ref:$dir/$recipe" | recipe_values '^PKG_NAMES$')"
    for token in $rest; do
      found=1
      token="${token//\$\{PN\}/$dir}"
      token="${token//\$\{PV\}/$pv}"
      token="${token//\$\{PV\[0\]\}/$pv}"
      i=1
      for part in $parts; do
        token="${token//\$\{PV\[$i\]\}/$part}"
        i=$((i + 1))
      done
      if [[ "$token" == *'$'* ]]; then
        echo "Can't expand \`$token\` in $dir/$recipe's PKG_NAMES: give them with --names" >&2
        return 1
      fi
      echo "$token"
    done
  done
  if [[ "$found" == 0 ]]; then
    echo "$dir"
  fi
}

# Prints "<file> <package>" per dependency on a name in $1 (a file of names)
# in ports master, the package's own directory left out.
ports_dependents() {
  local names_file="$1" candidates file values
  candidates="$tmp/candidates"
  git -C "$ports_dir" grep -l -F -f "$names_file" "$ref" -- '*.cygport' '*/README' |
    sed "s|^$ref:||" | { grep -v "^$package/" || true; } > "$candidates"
  while IFS= read -r file; do
    case "$file" in
      *.cygport) values="$(git -C "$ports_dir" show "$ref:$file" | recipe_values '^([A-Za-z0-9_]*_)?(REQUIRES|DEPEND)$')" ;;
      *) values="$(git -C "$ports_dir" show "$ref:$file" | readme_requirements)" ;;
    esac
    printf '%s\n' "$values" | grep -F -x -f "$names_file" | sort -u | sed "s|^|$file |" || true
  done < "$candidates"
}

workflows_active() {
  local wf count total=0
  for wf in publish.yml unpublish.yml; do
    count="$(gh run list -R "$dist_repo" --workflow "$wf" --limit 20 --json status \
      --jq '[.[] | select(.status != "completed")] | length')"
    total=$((total + count))
  done
  [[ "$total" -gt 0 ]]
}

setup_ini_lists_package() {
  grep -q "^source: x86_64/release/$package/" "$1"
}

# --- What's there ---

git -C "$ports_dir" fetch --quiet origin

in_ports=0
if [[ -n "$(git -C "$ports_dir" ls-tree -d --name-only "$ref" -- "$package")" ]]; then
  in_ports=1
fi

setup_ini="$tmp/setup.ini"
gh api "repos/$dist_repo/contents/x86_64/setup.ini?ref=gh-pages" \
  -H 'Accept: application/vnd.github.raw' > "$setup_ini"
grep -q '^setup-timestamp:' "$setup_ini" || { echo "gh-pages' setup.ini doesn't look like one" >&2; exit 1; }

owned="$(bash "$here/setup_ini_dependents.sh" --setup-ini "$setup_ini" --package "$package" --owned)"
in_dist=0
if [[ -n "$owned" ]]; then
  in_dist=1
fi

if [[ "$in_ports" == 0 && "$in_dist" == 0 ]]; then
  echo "$package is neither in ports nor in dist: nothing to remove."
  echo "(Package names are case-sensitive here: it's the directory name in ports.)"
  exit 1
fi

names_file="$tmp/names"
{
  [[ -z "$owned" ]] || printf '%s\n' "$owned"
  if [[ -n "$names_override" ]]; then
    printf '%s\n' $names_override
  elif [[ "$in_ports" == 1 ]]; then
    recipe_package_names "$package"
  fi
} | grep -v -- '-src$' | sort -u > "$names_file"

echo "$package: in ports: $([[ "$in_ports" == 1 ]] && echo yes || echo no), in dist: $([[ "$in_dist" == 1 ]] && echo yes || echo no)"
echo "Binary packages looked for: $(tr '\n' ' ' < "$names_file")"

# --- What still needs it ---

blocked=0

dist_dependents="$(bash "$here/setup_ini_dependents.sh" --setup-ini "$setup_ini" --package "$package")"
if [[ -n "$dist_dependents" ]]; then
  blocked=1
  echo
  echo "Dependents in dist (dependent, field, package):"
  printf '%s\n' "$dist_dependents" | sed 's/^/  /'
fi

recipe_dependents="$(ports_dependents "$names_file")"
if [[ -n "$recipe_dependents" ]]; then
  blocked=1
  echo
  echo "Dependents in ports master (file, package):"
  printf '%s\n' "$recipe_dependents" | sed 's/^/  /'
fi

branches="$(gh api "repos/$ports_repo/git/matching-refs/heads/dorgann/$package-" --paginate --jq '.[].ref' |
  sed 's|^refs/heads/||' | { grep -E "^dorgann/${package//+/\\+}-[0-9]" || true; })"
if [[ -n "$branches" ]]; then
  blocked=1
  echo
  echo "Branches that could publish it again:"
  printf '%s\n' "$branches" | sed 's/^/  /'
fi

if [[ "$blocked" == 1 ]]; then
  echo
  echo "Not removing $package: nothing was changed."
  exit 1
fi

echo
echo "No dependents."

if [[ "$execute" == 0 ]]; then
  [[ "$in_dist" == 0 ]] || echo "Would remove x86_64/release/$package/ from gh-pages and wait for dist.yacp.dev to stop listing it."
  [[ "$in_ports" == 0 ]] || echo "Would commit \`remove $package\` to ports master."
  echo "Run again with --execute to do it."
  exit 0
fi

# --- dist ---

if [[ "$in_dist" == 1 ]]; then
  while workflows_active; do
    echo "Waiting for publish/unpublish runs to finish..."
    sleep 30
  done

  url="$(gh workflow run unpublish.yml -R "$dist_repo" -f "package=$package" 2>&1 |
    grep -o "https://github.com/$dist_repo/actions/runs/[0-9]*" | head -n1)"
  [[ -n "$url" ]] || { echo "Dispatched, but gh printed no run URL (gh older than 2.102?)" >&2; exit 1; }
  echo "Unpublishing: $url"

  if ! result="$(bash "$wait_run" --run "${url##*/}" --interval 30)"; then
    echo "Unpublish didn't succeed ($result): ports left as it is." >&2
    exit 1
  fi

  live="$tmp/live.ini"
  deadline=$((SECONDS + 1800))
  while :; do
    if curl -fsSL "$site" -o "$live" && grep -q '^setup-timestamp:' "$live" && ! setup_ini_lists_package "$live"; then
      break
    fi
    if [[ "$SECONDS" -ge "$deadline" ]]; then
      echo "$site still lists $package after 30 minutes: ports left as it is. Run this again once it's gone." >&2
      exit 1
    fi
    echo "Waiting for $site to stop listing $package..."
    sleep 60
  done
  echo "dist no longer lists $package."
fi

# --- ports ---

if [[ "$in_ports" == 1 ]]; then
  worktree="$tmp/ports"
  git -C "$ports_dir" fetch --quiet origin
  git -C "$ports_dir" worktree add --quiet --detach "$worktree" "$ref"
  git -C "$worktree" rm -r --quiet -- "$package"
  git -C "$worktree" commit --quiet -m "remove $package"
  git -C "$worktree" push --quiet origin HEAD:refs/heads/master
  echo "Removed $package from ports: $(git -C "$worktree" rev-parse --short HEAD)"
fi

echo "$package removed."
