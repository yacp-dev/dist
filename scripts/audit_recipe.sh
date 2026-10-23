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
# $S, REUSE's LICENSES/*.txt, and the license texts in $S (and
# LICENSE_URI), told apart by their own wording. A license text can't say
# -only from -or-later, so those are only compared against the headers.
# LICENSE describes what the binary packages ship, and only that: a
# license counts, both ways, when a shipped file carries it -- one
# installed into $D, or a source file the build compiled (cygport copies
# those into $D/usr/src/debug/$PF for the debuginfo package). Files of a
# backend the build leaves out don't count (ggml's Apache-2.0 SYCL and
# OpenVINO sources, gperftools' 0BSD vendor/aw-backtrace). The texts at
# the top of $S are the project's own and always count, except for a
# section that names its own files on a "Files:" line (draco's MIT one
# for a docs script): that counts when one of those files ships. A text
# further down (vendor/libbacktrace/LICENSE) counts when a compiled
# source sits below it, and a REUSE text when a shipped header names it. With no binaries
# in $D, $D is all that ships; with binaries but no $D/usr/src/debug --
# no debuginfo -- what was compiled is unknown, and all of $S counts.
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
  # Without line-leading comment marks: libbacktrace's LICENSE is "# "-
  # prefixed, which would split "used to # endorse" below.
  text="$(sed -E 's@^[[:space:]]*(#+|//+|\*+|;+|--)[[:space:]]?@@' "$1" | tr -s '[:space:]' ' ')"
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
    elif [[ "$text" == *"Neither the name"* || "$text" == *"used to endorse or promote"* ]]; then
      echo "BSD-3-Clause"
    else
      echo "BSD-2-Clause"
    fi
  fi
  # 0BSD is ISC without the condition to keep the notice.
  if [[ "$text" == *"Permission to use, copy, modify, and"*"distribute this software for any purpose with or without fee is hereby granted"* ]]; then
    if [[ "$text" == *"provided that the above copyright notice"* ]]; then
      echo "ISC"
    else
      echo "0BSD"
    fi
  fi
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

# A top-level license text made of sections, each saying which files it
# covers with a "Files:" line (Debian copyright style), as draco's
# LICENSE does: Apache-2.0 for the project, then MIT for
# docs/assets/js/ASCIIMathML.js and the Unlicense for
# docs/assets/css/pygments/*. A section counts when one of its files
# ships -- compiled, or installed into $D under the same name -- and,
# like the rest, when what ships is unknown. The text before the first
# "Files:" line is the project's own and always counts. Sections are
# split at "Files:" lines and at lines of ---------- or ==========.
# Called from audit_license, whose locals it fills in.
audit_license_sections() {
  local f="$1" rel="$2" sec scope ids id pat m hit
  rm -rf "$tmp/sections"
  mkdir "$tmp/sections"
  awk -v dir="$tmp/sections" '
    BEGIN { n = 0 }
    function next_section() { n++; content = 0 }
    /^(----------|==========)/ { next_section(); files = 0; next }
    /^Files:[[:space:]]/ {
      if (content) next_section()
      sub(/^Files:[[:space:]]*/, "")
      print > (dir "/" n ".files"); files = 1; next
    }
    files && /^[[:space:]]+[^[:space:]]/ { print > (dir "/" n ".files"); next }
    { files = 0; print > (dir "/" n); if ($0 ~ /[^[:space:]]/) content = 1 }
  ' "$f"

  for sec in $(find "$tmp/sections" -type f ! -name '*.files' -print | sed 's#.*/##' | sort -n); do
    sec="$tmp/sections/$sec"
    ids="$(identify_license_text "$sec" | sort -u | tr '\n' ' ')"
    ids="${ids% }"
    [[ -n "$ids" ]] || continue
    if [[ -f "$sec.files" ]]; then
      scope="$(tr -s '[:space:]' ' ' < "$sec.files")"
      scope="${scope# }"
      scope="${scope% }"
      if [[ -n "$shipped_known" ]]; then
        hit=""
        for pat in $scope; do
          while IFS= read -r m; do
            if grep -qxF "$m" "$tmp/compiled" || grep -qxF "${m##*/}" "$tmp/installed_names"; then
              hit="$m"
              break 2
            fi
          done < <(cd "$S" && compgen -G "$pat" | while IFS= read -r m; do
                     if [[ -d "$m" ]]; then find "$m" -type f; else printf '%s\n' "$m"; fi
                   done)
        done
        if [[ -z "$hit" ]]; then
          say "License text $rel (Files: $scope): $ids -- none of these files ships, LICENSE needn't include it"
          continue
        fi
        say "License text $rel (Files: $scope): $ids (shipped: e.g. $hit)"
      else
        say "License text $rel (Files: $scope): $ids"
      fi
    else
      say "License text $rel: $ids"
    fi
    for id in $ids; do
      text_ids["$(license_base "$id")"]="$rel"
      text_names["$(license_base "$id")"]="$id"
      found_base["$(license_base "$id")"]=1
    done
  done
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
    | spdx_ids | sort -u > "$tmp/header_files"
  cut -f2 "$tmp/header_files" | sort | uniq -c | sort -rn > "$tmp/headers"

  # The same for the files the packages ship (see the top of this file),
  # and the compiled sources among them, as paths relative to $S.
  declare -A shipped=()
  local shipped_known=""
  : > "$tmp/compiled"
  if [[ -d "$D/usr/src/debug" ]]; then
    shipped_known=1
    find "$D/usr/src/debug" -mindepth 2 -type f 2>/dev/null | while IFS= read -r f; do
      f="${f#"$D"/usr/src/debug/*/}"
      [[ -f "$S/$f" ]] && printf '%s\n' "$f"
    done | sort -u > "$tmp/compiled"
  elif [[ -z "$(find "$D" -path "$D/usr/lib/debug" -prune -o -type f \
         \( -iname '*.dll' -o -iname '*.exe' -o -iname '*.so' -o -iname '*.a' \) -print 2>/dev/null | head -1)" ]]; then
    shipped_known=1
  fi
  if [[ -n "$shipped_known" ]]; then
    while read -r count id; do
      shipped["$id"]="$count"
    done < <(find "$D" -path "$D/usr/lib/debug" -prune -o -type f -print0 2>/dev/null \
      | xargs -0 -r grep -HIoE --null 'SPDX-License-Identifier:[[:space:]]*[A-Za-z0-9.+() -]+' 2>/dev/null \
      | tr '\0' '\t' \
      | sed -E 's/\tSPDX-License-Identifier:[[:space:]]*/\t/' \
      | spdx_ids | sort -u | cut -f2 | sort | uniq -c)
  fi

  # A license only a shipped file outside $S carries (a generated
  # header installed into $D) is checked like the rest.
  for id in "${!shipped[@]}"; do
    cut -f2 "$tmp/header_files" | grep -qxF "$id" || printf '%s %s\n' "${shipped[$id]}" "$id" >> "$tmp/headers"
  done

  # What the packages are found to carry: the shipped headers' licenses
  # and the license texts that count. LICENSE is checked against these
  # both ways. Without shipped_known, every header in $S counts.
  declare -A found_base=() shipped_base=()
  local count
  for id in "${!shipped[@]}"; do
    shipped_base["$(license_base "$id")"]=1
  done
  if [[ -s "$tmp/headers" ]]; then
    say "SPDX-License-Identifier headers in the source:"
    while read -r count id; do
      if [[ -n "$shipped_known" ]]; then
        say "  $id: $count file(s), ${shipped[$id]:-none} of them shipped"
        [[ -n "${shipped[$id]:-}" ]] && found_base["$(license_base "$id")"]=1
      else
        say "  $id: $count file(s)"
        found_base["$(license_base "$id")"]=1
      fi
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

  # Basenames of what $D installs, to tell whether a file a license text
  # section names (below) ships without being compiled: a header, a doc.
  find "$D" \( -path "$D/usr/lib/debug" -o -path "$D/usr/src/debug" \) -prune -o -type f -print 2>/dev/null \
    | sed 's#.*/##' | sort -u > "$tmp/installed_names"

  declare -A seen_text=() text_ids=() text_names=()
  local ids rel
  for f in "${texts[@]}"; do
    rel="${f#"$S"/}"
    [[ -n "${seen_text[$rel]:-}" ]] && continue
    seen_text["$rel"]=1
    if grep -qE '^Files:[[:space:]]' "$f"; then
      audit_license_sections "$f" "$rel"
      continue
    fi
    ids="$(identify_license_text "$f" | sort -u | tr '\n' ' ')"
    ids="${ids% }"
    say "License text $rel: ${ids:-(not recognized)}"
    for id in $ids; do
      text_ids["$(license_base "$id")"]="$rel"
      text_names["$(license_base "$id")"]="$id"
      found_base["$(license_base "$id")"]=1
    done
  done

  # License texts further down, usually of vendored code: they count
  # when a compiled source sits below them. Unrecognized ones are left
  # out -- at that depth, LICENSE* also matches source files.
  local dir covered
  while IFS= read -r -d '' f; do
    rel="${f#"$S"/}"
    [[ -n "${seen_text[$rel]:-}" ]] && continue
    seen_text["$rel"]=1
    ids="$(identify_license_text "$f" | sort -u | tr '\n' ' ')"
    ids="${ids% }"
    [[ -n "$ids" ]] || continue
    dir="${rel%/*}"
    if [[ ! -s "$tmp/compiled" ]]; then
      say "License text $rel: $ids (not checked: which of the source the packages carry is unknown)"
      continue
    fi
    covered="$(awk -v d="$dir/" 'index($0, d) == 1 { print; exit }' "$tmp/compiled")"
    if [[ -z "$covered" ]]; then
      say "License text $rel: $ids -- nothing below $dir/ is compiled into the packages, LICENSE needn't include it"
      continue
    fi
    say "License text $rel: $ids (compiled into the packages: e.g. $covered)"
    for id in $ids; do
      text_ids["$(license_base "$id")"]="$rel"
      text_names["$(license_base "$id")"]="$id"
      found_base["$(license_base "$id")"]=1
    done
  done < <(find "$S" -mindepth 2 \( -name .git -o -name CYGWIN-PATCHES -o -path "$S/LICENSES" \) -prune -o -type f \
             \( -iname 'COPYING*' -o -iname 'LICENSE*' -o -iname 'LICENCE*' -o -iname 'COPYRIGHT*' -o -iname 'UNLICENSE*' \) \
             -print0 2>/dev/null | sort -z)

  for f in "${reuse[@]}"; do
    id="$(basename "$f" .txt)"
    if [[ -n "$shipped_known" && -z "${shipped_base[$(license_base "$id")]:-}" ]]; then
      if [[ -n "${recipe_base[$(license_base "$id")]:-}" ]]; then
        say "License text ${f#"$S"/} (no shipped file's header names it)"
      else
        say "License text ${f#"$S"/} -- no shipped file's header names it, LICENSE needn't include it"
      fi
      continue
    fi
    say "License text ${f#"$S"/}"
    text_ids["$(license_base "$id")"]="${f#"$S"/}"
    text_names["$(license_base "$id")"]="$id"
    found_base["$(license_base "$id")"]=1
  done

  # Something the source says that LICENSE doesn't.
  local base r example
  while read -r count id; do
    base="$(license_base "$id")"
    if [[ -n "$shipped_known" && -z "${shipped[$id]:-}" ]]; then
      if [[ -z "${recipe[${id,,}]:-}" ]]; then
        example="$(awk -F '\t' -v id="$id" '$2 == id { print $1; exit }' "$tmp/header_files")"
        say "The $id headers ($count file(s), e.g. ${example#"$S"/}) are all in files the packages don't ship -- LICENSE needn't include it"
      fi
      continue
    fi
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
  local where="in the source"
  [[ -n "$shipped_known" ]] && where="of what the packages ship"
  for r in "${recipe[@]}"; do
    [[ -n "${found_base[$(license_base "$r")]:-}" ]] \
      || warn "LICENSE has $r but no header or license text $where says so"
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
