#!/usr/bin/env bash
# Reads setup.ini for what removing one source package from dist would
# break (doc/spec.md 4.4.3). A binary package belongs to the source package
# whose release directory holds its files, x86_64/release/<source
# package>/..., whatever the binary package is called (libfoo1 and
# libfoo-devel belong to foo).
#
# A dependent is a package of another source package whose depends2,
# requires or build-depends names one of those binary packages, or
# something one of them provides. A dependency between the source
# package's own subpackages doesn't count: they go together.
#
# Descriptions can span lines, so they're skipped rather than read as
# fields: a line of ldesc starting "depends2:" is not a dependency.
#
# Usage: setup_ini_dependents.sh --setup-ini setup.ini --package foo [--owned]
# Output: "<dependent> <field> <binary package>" per dependency, or with
# --owned, the source package's binary packages (and the -src pseudo-
# package), one per line. Nothing at all if it has neither. Exit status 0
# either way: an empty result is the answer, not an error.

set -euo pipefail

setup_ini=""
package=""
owned_only=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --setup-ini) setup_ini="$2"; shift 2 ;;
    --package) package="$2"; shift 2 ;;
    --owned) owned_only=1; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$setup_ini" ]] || { echo "--setup-ini is required" >&2; exit 1; }
[[ -n "$package" ]] || { echo "--package is required" >&2; exit 1; }
[[ -f "$setup_ini" ]] || { echo "No such file: $setup_ini" >&2; exit 1; }

awk -v prefix="x86_64/release/$package/" -v owned_only="$owned_only" '
  in_desc {
    if ($0 ~ /"[ \t]*$/) in_desc = 0
    next
  }
  /^(sdesc|ldesc|message): / {
    rest = $0
    if (sub(/^[^"]*"/, "", rest) && rest !~ /"[ \t]*$/) in_desc = 1
    next
  }
  /^@ / {
    cur = $2
    names[++n] = cur
    next
  }
  /^(install|source): / {
    if (index($2, prefix) == 1) owned[cur] = 1
    next
  }
  /^provides: / {
    rest = $0
    sub(/^[^:]*: /, "", rest)
    gsub(/,/, " ", rest)
    provides[cur] = provides[cur] " " rest
    next
  }
  /^(depends2|requires|build-depends): / {
    field = $1
    sub(/:$/, "", field)
    rest = $0
    sub(/^[^:]*: /, "", rest)
    gsub(/\([^)]*\)/, " ", rest)
    gsub(/,/, " ", rest)
    k = split(rest, deps, /[ \t]+/)
    for (i = 1; i <= k; i++) {
      if (deps[i] == "") continue
      m++
      dep_from[m] = cur
      dep_field[m] = field
      dep_name[m] = deps[i]
    }
    next
  }
  END {
    for (i = 1; i <= n; i++) {
      if (!(names[i] in owned)) continue
      if (owned_only) print names[i]
      target[names[i]] = 1
      k = split(provides[names[i]], p, /[ \t]+/)
      for (j = 1; j <= k; j++) if (p[j] != "") target[p[j]] = 1
    }
    if (owned_only) exit
    for (i = 1; i <= m; i++) {
      if (dep_from[i] in owned) continue
      if (dep_name[i] in target) print dep_from[i], dep_field[i], dep_name[i]
    }
  }
' "$setup_ini"
