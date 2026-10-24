# License helpers shared by audit_recipe.sh and port-until-green's
# preflight_bump.sh (source this file; it defines functions only).
# Needs bash 4+ (${var,,}).

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
  # MIT-0 is MIT without the condition to keep the notice (minicoro's
  # LICENSE, compiled into BehaviorTree.CPP).
  if [[ "$text" == *"Permission is hereby granted, free of charge, to any person obtaining a copy"* ]]; then
    if [[ "$text" == *"The above copyright notice and this permission notice"* ]]; then
      echo "MIT"
    else
      echo "MIT-0"
    fi
  fi
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

# Prints, NUL-separated and sorted, the license text files under a source
# tree -- by name, as audit_recipe.sh looks for them at every depth -- in
# the form <dir>/<relative path>.
license_text_files() {
  find "$1" \( -name .git -o -name CYGWIN-PATCHES \) -prune -o -type f \
    \( -iname 'COPYING*' -o -iname 'LICENSE*' -o -iname 'LICENCE*' -o -iname 'COPYRIGHT*' -o -iname 'UNLICENSE*' \) \
    -print0 2>/dev/null | sort -z
}
