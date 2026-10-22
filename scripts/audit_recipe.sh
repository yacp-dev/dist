#!/usr/bin/env bash
# Cross-checks two things in a cygport recipe that `xezat validate`
# doesn't: whether LICENSE matches what the source itself says, and
# whether every BUILD_REQUIRES package is actually used by the build.
# xezat only checks that LICENSE is a valid SPDX expression (and that
# LICENSE_URI exists) and that each BUILD_REQUIRES package is installed
# -- a recipe carried over from an old version keeps both long after
# upstream has relicensed or dropped a dependency.
#
# LICENSE is compared against the SPDX-License-Identifier headers across
# $S, REUSE's LICENSES/*.txt, and the license texts at the top of $S (and
# LICENSE_URI), told apart by their own wording. A license text can't say
# -only from -or-later, so those are only compared against the headers.
#
# For BUILD_REQUIRES, each package's installed file list
# (/etc/setup/<pkg>.lst.gz) is matched against evidence of use, strongest
# first: a binary in $D (or, for test-only dependencies, in $B) importing
# one of its DLLs; one of its files showing up in the compiler's own
# dependency output (.d/.deps files, `ninja -t deps`); one of its
# commands, .pc/m4/cmake names or -l flags appearing in the build logs.
# The last is weak -- configure's "checking for foo... no" mentions a
# tool it then doesn't use -- but a package with none of the three is
# most likely left over. Building fine without a package still doesn't
# prove it unused (configure may silently drop a feature), so this only
# warns; a human (or port-until-green) confirms by rebuilding without it
# and comparing the package contents.
#
# Meant to run after cygport package, while $S/$B/$D and the logs are
# still on disk. Never fails the build: every finding is a warning.
#
# Usage:
#   audit_recipe.sh --dir yacp/googletest --file googletest-1.18.0-1bl1.cygport
#
# Output: prints the report to stdout; if GITHUB_OUTPUT is set, also
# writes it to a temp file and appends `report_file=<path>` there, plus
# `warnings=<n>` when there was at least one warning.

set -uo pipefail # NOT -e: greps finding nothing are the common case here

dir=""
cygport_file=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) dir="$2"; shift 2 ;;
    --file) cygport_file="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$dir" ]] || { echo "--dir is required" >&2; exit 1; }
[[ -n "$cygport_file" ]] || { echo "--file is required" >&2; exit 1; }

cd "$dir"
[[ -f "$cygport_file" ]] || { echo "No such file: $dir/$cygport_file" >&2; exit 1; }

# Same `cygport <file> vars <NAME>` mechanism as the diagnose_*.sh.
vars_decl="$(cygport "$cygport_file" vars S B D logdir BUILD_REQUIRES LICENSE LICENSE_URI 2>/dev/null)"
if [[ -z "$vars_decl" ]]; then
  echo "audit_recipe.sh: 'cygport $cygport_file vars ...' returned nothing -- nothing to audit" >&2
  exit 0
fi
S="" B="" D="" logdir="" BUILD_REQUIRES="" LICENSE="" LICENSE_URI=""
eval "$vars_decl"

if [[ ! -d "$S" || ! -d "$D" ]]; then
  echo "audit_recipe.sh: \$S ('$S') or \$D ('$D') isn't there -- run after cygport install" >&2
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

report=()
warnings=0
say() { report+=("$*"); }
warn() { report+=("WARNING: $*"); warnings=$((warnings + 1)); }

# Splits SPDX expressions ("<key>\t<expression>" lines) into one
# "<key>\t<id>" line per license, dropping AND/OR, parentheses and WITH
# exceptions. The deprecated GNU ids are mapped to what SPDX says they
# mean: a bare GPL-2.0 is GPL-2.0-only, GPL-2.0+ is GPL-2.0-or-later.
spdx_ids() {
  awk -F '\t' '
    function norm(t) {
      if (t ~ /\+$/) { sub(/\+$/, "", t); return t "-or-later" }
      if (t ~ /^(A?GPL|LGPL|GFDL)-[0-9.]+$/) return t "-only"
      return t
    }
    {
      expr = $0; sub(/^[^\t]*\t/, "", expr)
      gsub(/[()]/, " ", expr)
      n = split(expr, tok, /[ \t]+/)
      skip = 0
      for (i = 1; i <= n; i++) {
        t = tok[i]
        if (t == "") continue
        if (skip) { skip = 0; continue }
        u = toupper(t)
        if (u == "AND" || u == "OR") continue
        if (u == "WITH") { skip = 1; continue }
        if (t !~ /^[A-Za-z0-9][A-Za-z0-9.+-]*$/ || t !~ /[A-Za-z]/) continue
        print $1 "\t" norm(t)
      }
    }'
}

# GPL-2.0-or-later -> gpl-2.0: what a license text alone can tell.
license_base() {
  local id="${1,,}"
  id="${id%-only}"
  id="${id%-or-later}"
  printf '%s' "$id"
}

# Prints the SPDX id(s) (without -only/-or-later) of a license text, one
# per line, from wording each license's own text has. Prints nothing for
# a text it doesn't know.
identify_license_text() {
  local text
  text="$(tr -s '[:space:]' ' ' < "$1")"
  local gnu name ver
  for gnu in "GNU GENERAL PUBLIC LICENSE:GPL" "GNU LESSER GENERAL PUBLIC LICENSE:LGPL" \
             "GNU LIBRARY GENERAL PUBLIC LICENSE:LGPL" "GNU AFFERO GENERAL PUBLIC LICENSE:AGPL"; do
    name="${gnu%%:*}"
    if [[ "$text" =~ $name\ Version\ ([0-9.]+) ]]; then
      ver="${BASH_REMATCH[1]%.}"
      [[ "$ver" == *.* ]] || ver="$ver.0"
      echo "${gnu##*:}-$ver"
    fi
  done
  [[ "$text" == *"Apache License"*"Version 2.0"* ]] && echo "Apache-2.0"
  [[ "$text" == *"Mozilla Public License Version 2.0"* || "$text" == *"Mozilla Public License, v. 2.0"* ]] && echo "MPL-2.0"
  [[ "$text" == *"Permission is hereby granted, free of charge, to any person obtaining a copy"* ]] && echo "MIT"
  if [[ "$text" == *"Redistribution and use in source and binary forms"* ]]; then
    if [[ "$text" == *"advertising materials"* ]]; then
      echo "BSD-4-Clause"
    elif [[ "$text" == *"Neither the name"* || "$text" == *"may be used to endorse or promote"* ]]; then
      echo "BSD-3-Clause"
    else
      echo "BSD-2-Clause"
    fi
  fi
  [[ "$text" == *"Permission to use, copy, modify, and"*"distribute this software for any purpose with or without fee is hereby granted"* ]] && echo "ISC"
  [[ "$text" == *"provided 'as-is', without any express or implied warranty"*"Altered source versions must be plainly marked"* ]] && echo "Zlib"
  [[ "$text" == *"Boost Software License - Version 1.0"* ]] && echo "BSL-1.0"
  [[ "$text" == *"This is free and unencumbered software released into the public domain"* ]] && echo "Unlicense"
  [[ "$text" == *"Eclipse Public License - v 2.0"* ]] && echo "EPL-2.0"
  [[ "$text" == *"Eclipse Public License - v 1.0"* ]] && echo "EPL-1.0"
  [[ "$text" == *"The Artistic License 2.0"* ]] && echo "Artistic-2.0"
  [[ "$text" == *"CC0 1.0 Universal"* ]] && echo "CC0-1.0"
  [[ "$text" == *"PYTHON SOFTWARE FOUNDATION LICENSE VERSION 2"* ]] && echo "PSF-2.0"
  return 0
}

audit_license() {
  say "== LICENSE =="
  if [[ -z "$LICENSE" ]]; then
    say "LICENSE isn't set in the recipe (see port-until-green's \"Missing LICENSE\")"
    return
  fi
  say "Recipe: LICENSE=\"$LICENSE\" LICENSE_URI=\"$LICENSE_URI\""

  declare -A recipe=() recipe_base=()
  local id
  while IFS=$'\t' read -r _ id; do
    recipe["${id,,}"]="$id"
    recipe_base["$(license_base "$id")"]=1
  done < <(printf 'recipe\t%s\n' "$LICENSE" | spdx_ids)

  # "<file>\t<id>" for every SPDX header, then files per id.
  grep -rIoE --null --exclude-dir=.git --exclude-dir=CYGWIN-PATCHES \
    'SPDX-License-Identifier:[[:space:]]*[A-Za-z0-9.+() -]+' "$S" 2>/dev/null \
    | tr '\0' '\t' \
    | sed -E 's/\tSPDX-License-Identifier:[[:space:]]*/\t/' \
    | spdx_ids | sort -u | cut -f2 | sort | uniq -c | sort -rn > "$tmp/headers"

  declare -A found_base=()
  local count
  if [[ -s "$tmp/headers" ]]; then
    say "SPDX-License-Identifier headers in the source:"
    while read -r count id; do
      say "  $id: $count file(s)"
      found_base["$(license_base "$id")"]=1
    done < "$tmp/headers"
  else
    say "No SPDX-License-Identifier headers in the source"
  fi

  # License texts: REUSE's LICENSES/<id>.txt are named after their id;
  # the rest are told apart by their wording.
  local texts=() f
  shopt -s nullglob nocaseglob
  for f in "$S"/COPYING* "$S"/LICENSE* "$S"/LICENCE* "$S"/COPYRIGHT* "$S"/UNLICENSE*; do
    [[ -f "$f" ]] && texts+=("$f")
  done
  shopt -u nocaseglob
  if [[ -n "$LICENSE_URI" && "$LICENSE_URI" != http*://* && -f "$S/$LICENSE_URI" ]]; then
    texts+=("$S/$LICENSE_URI")
  fi
  local reuse=("$S"/LICENSES/*.txt)
  shopt -u nullglob

  declare -A seen_text=() text_ids=() text_names=()
  local ids rel
  for f in "${texts[@]}"; do
    rel="${f#"$S"/}"
    [[ -n "${seen_text[$rel]:-}" ]] && continue
    seen_text["$rel"]=1
    ids="$(identify_license_text "$f" | sort -u | tr '\n' ' ')"
    ids="${ids% }"
    say "License text $rel: ${ids:-(not recognized)}"
    for id in $ids; do
      text_ids["$(license_base "$id")"]="$rel"
      text_names["$(license_base "$id")"]="$id"
      found_base["$(license_base "$id")"]=1
    done
  done
  for f in "${reuse[@]}"; do
    id="$(basename "$f" .txt)"
    say "License text ${f#"$S"/}"
    text_ids["$(license_base "$id")"]="${f#"$S"/}"
    text_names["$(license_base "$id")"]="$id"
    found_base["$(license_base "$id")"]=1
  done

  # Something the source says that LICENSE doesn't.
  local base r
  while read -r count id; do
    base="$(license_base "$id")"
    if [[ -z "${recipe_base[$base]:-}" ]]; then
      warn "the source has $id headers ($count file(s)) but LICENSE doesn't include it"
    elif [[ -z "${recipe[${id,,}]:-}" && "${id,,}" != "$base" ]]; then
      for r in "${recipe[@]}"; do
        [[ "$(license_base "$r")" == "$base" ]] && warn "the source has $id headers ($count file(s)) but LICENSE says $r"
      done
    fi
  done < "$tmp/headers"
  for base in "${!text_ids[@]}"; do
    [[ -n "${recipe_base[$base]:-}" ]] && continue
    # LGPL-3.0 is written as additional permissions on top of GPL-3.0, so
    # LGPL-3.0 projects ship the GPL-3.0 text too (giza: COPYING next to
    # COPYING.LESSER).
    if [[ "$base" == gpl-3.0 && -n "${recipe_base[lgpl-3.0]:-}" ]]; then
      say "${text_ids[$base]} is the GPL-3.0 text that LGPL-3.0 builds on -- fine"
      continue
    fi
    warn "${text_ids[$base]} is a ${text_names[$base]} license text but LICENSE doesn't include it"
  done

  # Something LICENSE says that the source doesn't.
  if [[ ${#found_base[@]} -eq 0 ]]; then
    say "Couldn't tell any license from the source -- check LICENSE by hand"
    return
  fi
  for r in "${recipe[@]}"; do
    [[ -n "${found_base[$(license_base "$r")]:-}" ]] \
      || warn "LICENSE has $r but no header or license text in the source says so"
  done
}

audit_build_requires() {
  say ""
  say "== BUILD_REQUIRES =="
  if [[ -z "${BUILD_REQUIRES// /}" ]]; then
    say "BUILD_REQUIRES is empty"
    return
  fi

  # DLLs that the binaries import, from $D and (tests, helper tools
  # built and run during the build) $B.
  local tree
  for tree in D B; do
    if [[ -d "${!tree}" ]]; then
      find "${!tree}" -type f \( -iname '*.dll' -o -iname '*.exe' -o -iname '*.so' \) -print0 2>/dev/null \
        | xargs -0 -r objdump -p 2>/dev/null \
        | sed -n 's/^[[:space:]]*DLL Name: //p' | tr '[:upper:]' '[:lower:]' | sort -u > "$tmp/imports.$tree"
    else
      : > "$tmp/imports.$tree"
    fi
  done

  # Files outside the build tree that the compiler read, from its own
  # dependency output, with /x/../ collapsed.
  {
    if [[ -d "$B" ]]; then
      find "$B" -type f \( -name '*.d' -o -path '*/.deps/*' -o -name '*.Po' -o -name '*.Plo' \
        -o -name compiler_depend.make -o -name depend.make \) -print0 2>/dev/null \
        | xargs -0 -r grep -ohE '/usr/[^[:space:]:\\]+' 2>/dev/null
      if command -v ninja >/dev/null; then
        find "$B" -name .ninja_deps -print0 2>/dev/null | while IFS= read -r -d '' f; do
          ninja -C "$(dirname "$f")" -t deps 2>/dev/null | grep -oE '/usr/[^[:space:]]+'
        done
      fi
    fi
  } | sed -E ':a; s#/[^/]+/\.\./#/#; ta' | sort -u > "$tmp/deps"

  # Logs to look for names in: cygport's own, the build systems' own,
  # and aclocal.m4 (autoreconf copies the m4 files it uses into it).
  local corpus=() f
  shopt -s nullglob
  corpus+=("$logdir"/*.log "$S"/aclocal.m4)
  shopt -u nullglob
  if [[ -d "$B" ]]; then
    while IFS= read -r -d '' f; do
      corpus+=("$f")
    done < <(find "$B" -maxdepth 4 -type f \( -name config.log -o -name meson-log.txt -o -name CMakeCache.txt \
      -o -name CMakeConfigureLog.yaml -o -name CMakeOutput.log -o -name aclocal.m4 \) -print0 2>/dev/null)
  fi

  local pkg lst dll implib hit names
  for pkg in $BUILD_REQUIRES; do
    lst="/etc/setup/$pkg.lst.gz"
    if [[ ! -f "$lst" ]]; then
      say "$pkg: no file list at $lst -- not installed?"
      continue
    fi
    gzip -dc "$lst" | grep -v '/$' | sed 's#^#/#' | sort -u > "$tmp/files"

    hit=""
    for tree in D B; do
      while IFS= read -r implib; do
        while IFS= read -r dll; do
          if grep -qxF "${dll,,}" "$tmp/imports.$tree"; then
            hit="$dll"
            break 3
          fi
        done < <(dlltool -I "$implib" 2>/dev/null)
      done < <(grep -E '^/usr/lib/[^/]+\.dll\.a$' "$tmp/files")
    done
    if [[ -n "$hit" ]]; then
      if [[ "$tree" == D ]]; then
        say "$pkg: used -- the package's binaries import $hit"
      else
        say "$pkg: used -- binaries in the build tree (tests?) import $hit, the package's own don't"
      fi
      continue
    fi

    hit="$(comm -12 "$tmp/files" "$tmp/deps")"
    if [[ -n "$hit" ]]; then
      say "$pkg: used -- the build reads $(head -1 <<< "$hit")$( (( $(wc -l <<< "$hit") > 1 )) && echo " and $(( $(wc -l <<< "$hit") - 1 )) more file(s)")"
      continue
    fi

    # Names the package's files go by in a build log; 3+ characters, so
    # a short name doesn't match everything.
    sed -nE \
      -e 's#^/usr/bin/([^/]+)$#\1#p' \
      -e 's#^/usr/(lib|share)/pkgconfig/([^/]+)\.pc$#\2#p' \
      -e 's#^/usr/share/aclocal/([^/]+)\.m4$#\1#p' \
      -e 's#^/usr/lib/cmake/([^/]+)/.*#\1#p' \
      -e 's#^/usr/lib/python3[^/]*/site-packages/([^/.]+)(/|\.py$).*#\1#p' \
      -e 's#^/usr/lib/lib([^/]+)\.(dll\.)?a$#-l\1#p' \
      "$tmp/files" | sed 's/\.exe$//' | awk 'length >= 3' | sort -u > "$tmp/names"
    hit=""
    if [[ -s "$tmp/names" && ${#corpus[@]} -gt 0 ]]; then
      hit="$(grep -ohFw -f "$tmp/names" "${corpus[@]}" 2>/dev/null | sort | uniq -c | sort -rn | head -3 | awk '{print $2}' | tr '\n' ' ')"
    fi
    if [[ -n "$hit" ]]; then
      say "$pkg: probably used -- the build logs mention ${hit% } (weak: a configure check that came out \"no\" counts too)"
      continue
    fi

    warn "$pkg: no evidence of use -- no DLL of it imported, none of its files read by the compiler, not mentioned in the build logs"
  done
}

audit_license
audit_build_requires

if (( warnings > 0 )); then
  report+=("" "$warnings warning(s). A build that passes without a BUILD_REQUIRES package can still have lost a feature: compare the package contents before dropping it.")
fi

printf '%s\n' "${report[@]}"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  output="$(mktemp)"
  printf '%s\n' "${report[@]}" > "$output"
  echo "report_file=$output" >> "$GITHUB_OUTPUT"
  if (( warnings > 0 )); then
    echo "warnings=$warnings" >> "$GITHUB_OUTPUT"
  fi
fi
exit 0
