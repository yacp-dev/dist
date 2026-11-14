#!/usr/bin/env bash
# Step 4's "Checking a dependency is unavailable": whether the two package
# lists the workflow installs from -- the Cygwin mirror and dist.yacp.dev
# -- have a package, at what curr version ([test] versions aren't
# installed), and whether yacp-dev/ports has an unpublished recipe for it.
#
# --file looks the file up in Cygwin's package file lists
# (cygwin.com/packages' package-grep, mingw64 cross packages left out)
# and checks every package that has it. dist.yacp.dev's file lists
# aren't searchable: name its package with --package.
#
# Usage:
#   dep_available.sh --file zstd.pc [--min 1.5.6]
#   dep_available.sh --package libzstd-devel [--package other ...] [--min 1.5.6]
# Output: per package, "<name>: cygwin <curr|-> [test <v>], dist <curr|->
# [test <v>], ports <recipe dir|->", with "too old for <min>" when the
# newest curr is older than --min; then a last line:
#   available <package> <version>   one meets it (curr, either list)
#   unpublished <ports dir>          only a ports recipe nobody published
#   unavailable                      nothing installable: stop (Step 3)

set -euo pipefail

pkgs=() file="" min=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --package) pkgs+=("$2"); shift 2 ;;
    --file) file="$2"; shift 2 ;;
    --min) min="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done
[[ ${#pkgs[@]} -gt 0 || -n "$file" ]] || { echo "--package or --file is required" >&2; exit 1; }

if [[ -n "$file" ]]; then
  # "libzstd-devel-1.5.7-1 - libzstd-devel: Zstandard ..." -> libzstd-devel
  while IFS= read -r p; do pkgs+=("$p"); done < <(
    curl -sf "https://cygwin.com/cgi-bin2/package-grep.cgi?grep=$(jq -rn --arg f "$file" '$f|@uri')&arch=x86_64&text=1" |
      sed -n 's/^[^ ]* - \([^:]*\): .*/\1/p' | grep -v '^mingw64-' | sort -u || true)
  [[ ${#pkgs[@]} -gt 0 ]] || echo "$file: in no Cygwin package's file list"
fi

cygwin_ini="$(curl -sf https://mirrors.kernel.org/sourceware/cygwin/x86_64/setup.xz | xz -d)"
dist_ini="$(curl -sf https://dist.yacp.dev/x86_64/setup.ini)"

# "<curr> <test> <source package>" of a package in a setup.ini, "-" for none.
stanza() {
  awk -v p="$2" '
    /^@ / { on = ($2 == p); sect = "curr"; next }
    !on { next }
    /^\[test\]/ { sect = "test"; next }
    /^\[/ { sect = "other"; next }
    /^version:/ { if (sect == "curr" && !c) c = $2; if (sect == "test" && !t) t = $2 }
    /^source:/ && sect == "curr" && !s { n = split($2, a, "/"); s = a[n]; sub(/-[^-]+-[^-]+-src\.tar\..*$/, "", s) }
    END { print (c ? c : "-") " " (t ? t : "-") " " (s ? s : "-") }' <<<"$1"
}

# Is version $1 at least $2?
at_least() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n 1)" == "$2" ]]; }

best="" unpublished=""
for p in ${pkgs[@]+"${pkgs[@]}"}; do
  read -r cc ct cs <<<"$(stanza "$cygwin_ini" "$p")"
  read -r dc dt ds <<<"$(stanza "$dist_ini" "$p")"
  src="$cs"; [[ "$src" == - ]] && src="$ds"; [[ "$src" == - ]] && src="$p"
  ports="-"
  gh api "repos/yacp-dev/ports/contents/$src" --jq '.[0].name' >/dev/null 2>&1 && ports="$src"
  line="$p: cygwin $cc"; [[ "$ct" != - ]] && line+=" [test $ct]"
  line+=", dist $dc"; [[ "$dt" != - ]] && line+=" [test $dt]"
  line+=", ports $ports"
  ok=""
  for v in "$cc" "$dc"; do
    [[ "$v" == - ]] && continue
    if [[ -z "$min" ]] || at_least "${v%-*}" "$min"; then ok="$v"; fi
  done
  if [[ -n "$ok" ]]; then
    [[ -z "$best" ]] && best="$p $ok"
  elif [[ "$cc" != - || "$dc" != - ]]; then
    line+=" -- too old for $min"
  fi
  [[ -z "$ok" && "$ports" != - && -z "$unpublished" ]] && unpublished="$ports"
  echo "$line"
done

if [[ -n "$best" ]]; then
  echo "available $best"
elif [[ -n "$unpublished" ]]; then
  echo "unpublished $unpublished"
else
  echo "unavailable"
fi
