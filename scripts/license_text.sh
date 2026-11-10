# License helpers shared by audit_recipe.sh and port-until-green's
# preflight_bump.sh (source this file; it defines functions only).
# Needs bash 4+ (${var,,}).

# Splits SPDX expressions ("<key>\t<expression>" lines) into one
# "<key>\t<id>" line per license, dropping AND/OR, parentheses, WITH
# exceptions and a trailing period. The deprecated GNU ids are mapped to
# what SPDX says they mean: a bare GPL-2.0 is GPL-2.0-only, GPL-2.0+ is
# GPL-2.0-or-later.
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
        # A header ending its sentence ("BSD-3-Clause.") is the same id.
        sub(/\.+$/, "", t)
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
  # C locale: a license text can hold bytes that are invalid UTF-8 (a Latin-1
  # quote in ButterflyPACK's license.txt), which make macOS sed and tr fail
  # and bash's pattern matching miss. Every pattern here is ASCII.
  local -x LC_ALL=C
  local text
  # Without line-leading comment marks: libbacktrace's LICENSE is "# "-
  # prefixed, which would split "used to # endorse" below. The same for
  # a "/* ... */" block comment written one line at a time (mt19937.c),
  # whose "*/ /*" would split "General Public License".
  text="$(sed -E -e 's@^[[:space:]]*(#+|//+|/\*+|\*+|;+|--)[[:space:]]?@@' -e 's@[[:space:]]*\*+/[[:space:]]*$@@' "$1" | tr -s '[:space:]' ' ')"
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
  # NCSA opens with MIT's grant but keeps its notice with "the above
  # copyright notice, this list of conditions" instead (LLVM's, whose
  # code capstone's arch/ disassemblers derive from).
  if [[ "$text" == *"University of Illinois/NCSA Open Source License"* ]]; then
    echo "NCSA"
  # MIT-0 is MIT without the condition to keep the notice (minicoro's
  # LICENSE, compiled into BehaviorTree.CPP). The condition may name
  # several notices (htslib's bgzip.c: "The above copyright notices and
  # this permission notice").
  # The ICU License (SPDX ICU) is MIT's grant with the notice condition
  # worded "the above copyright notice(s) and this permission notice
  # appear in all copies", which isn't MIT's sentence and isn't MIT-0
  # either (cg3's license.icu.txt, ICU's uoptions code).
  elif [[ "$text" == *"ICU License"* ||
          "$text" == *"above copyright notice(s) and this permission notice appear in all copies"* ]]; then
    echo "ICU"
  elif [[ "$text" == *"Permission is hereby granted, free of charge, to any person obtaining a copy"* ]]; then
    if [[ "$text" == *"The above copyright notice and this permission notice"* ||
          "$text" == *"The above copyright notices and this permission notice"* ]]; then
      echo "MIT"
    else
      echo "MIT-0"
    fi
  fi
  # The BSD licenses grant it "provided that" conditions are met; a grant
  # with none ("... with or without modification, are permitted.", the
  # public-domain fallback of Solar Designer's md5.c in htslib) isn't one.
  # The conditions are the BSD ones only when the list starts with them: a
  # header that adds its own first ("1. This software is only used for
  # private, research, or academic purposes", libprng's) is a custom license.
  if [[ "$text" == *"Redistribution and use in source and binary forms"*"provided that"* &&
        "$text" =~ provided\ that[^.]{0,60}:?\ ?[-*0-9.\(\)\ ]{0,8}Redistributions?\ of\ source\ code ]]; then
    if [[ "$text" == *"advertising materials"* ]]; then
      echo "BSD-4-Clause"
    elif [[ "$text" == *"Neither the name"* || "$text" == *"used to endorse or promote"* ]]; then
      # The Clear BSD License (vvenc) is the 3-clause text plus an explicit
      # denial of patent rights.
      if [[ "$text" == *"NO EXPRESS OR IMPLIED LICENSES TO ANY PARTY'S PATENT RIGHTS ARE GRANTED"* ]]; then
        echo "BSD-3-Clause-Clear"
      # BSD-3-Clause-LBNL (ButterflyPACK) is the 3-clause text plus the
      # "Enhancements" grant to Lawrence Berkeley National Laboratory.
      elif [[ "$text" == *"You are under no obligation whatsoever to provide any bug fixes"*"Enhancements"* ]]; then
        echo "BSD-3-Clause-LBNL"
      else
        echo "BSD-3-Clause"
      fi
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
  # The space after the dash isn't always there (adolc's LICENSE: "Eclipse
  # Public License -v 1.0").
  [[ "$text" =~ Eclipse\ Public\ License\ -\ ?v\ 2\.0 ]] && echo "EPL-2.0"
  [[ "$text" =~ Eclipse\ Public\ License\ -\ ?v\ 1\.0 ]] && echo "EPL-1.0"
  [[ "$text" == *"The Artistic License 2.0"* ]] && echo "Artistic-2.0"
  [[ "$text" == *"CC0 1.0 Universal"* ]] && echo "CC0-1.0"
  [[ "$text" == *"PYTHON SOFTWARE FOUNDATION LICENSE VERSION 2"* ]] && echo "PSF-2.0"
  [[ "$text" == *"Server Side Public License, version 1"* ]] && echo "SSPL-1.0"
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

# Prints the "-or-later" GNU license(s) a source file's header names in
# prose, one SPDX id per line (GPL-2.0-or-later): the standard notice
# ("either version 2 of the License, or (at your option) any later
# version") and its short forms ("License: GPL version 2 or later",
# "GPLv2+"). A notice that names a version without "or later" isn't
# recognized: it would need "-only", which prose says less reliably.
identify_license_notice() {
  local -x LC_ALL=C
  local text fam ver
  text="$(sed -E -e 's@^[[:space:]]*(#+|//+|/\*+|\*+|;+|--)[[:space:]]?@@' -e 's@[[:space:]]*\*+/[[:space:]]*$@@' "$1" | tr -s '[:space:]' ' ')"
  if [[ "$text" =~ General\ Public\ License[^.]{0,200}[Vv]ersion\ ([0-9]+(\.[0-9]+)?)[^.\;]{0,80}(any\ later\ version|or\ later) ]]; then
    ver="${BASH_REMATCH[1]}"
    fam=GPL
    [[ "$text" == *"Lesser General Public"* || "$text" == *"Library General Public"* ]] && fam=LGPL
    [[ "$text" == *"Affero General Public"* ]] && fam=AGPL
    [[ "$ver" == *.* ]] || ver="$ver.0"
    echo "$fam-$ver-or-later"
  fi
  if [[ "$text" =~ (^|[^A-Za-z])(AGPL|LGPL|GPL)[\ -]*(version\ |v)?([0-9]+(\.[0-9]+)?)(\ or\ later|\ or\ any\ later|\+) ]]; then
    fam="${BASH_REMATCH[2]}"
    ver="${BASH_REMATCH[4]}"
    [[ "$ver" == *.* ]] || ver="$ver.0"
    echo "$fam-$ver-or-later"
  fi
}

# Whether the first version is not newer than the second (2.0, 3.0).
license_version_le() {
  [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" == "$1" ]]
}

# Whether one of the SPDX ids given after the first argument is an
# "-or-later" license that covers license <base> (gpl-3.0): same family,
# and a version no newer. GPL-2.0-or-later allows a GPL-3.0 text.
license_or_later_covers() {
  local base="$1" r rb
  shift
  for r in "$@"; do
    [[ "$r" == *-or-later ]] || continue
    rb="$(license_base "$r")"
    [[ "${rb%-*}" == "${base%-*}" ]] || continue
    license_version_le "${rb##*-}" "${base##*-}" && return 0
  done
  return 1
}
