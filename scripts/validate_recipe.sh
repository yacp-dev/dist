#!/usr/bin/env bash
# Sanity-checks the finished build, in bash instead of `xezat validate`
# (which it replaces): the .cygport file has no BOM, CATEGORY is one of
# data/categories.yml's (xezat's list, copied here so xezat isn't needed
# for it), HOMEPAGE and LICENSE_URI answer with 200 (HOMEPAGE redirects
# are reported by audit_recipe.sh, which also gives the target to set),
# every BUILD_REQUIRES package is installed (/etc/setup/installed.db),
# each installed *-config script's --libs `-l` libraries exist, and
# nothing is left in the legacy AppStream path /usr/share/appdata.
#
# *.pc files under $D (usr/lib/pkgconfig, usr/share/pkgconfig) are read
# with pkg-config, with those directories put in PKG_CONFIG_PATH: their
# version must be $PV, their prefix /usr, their --libs must resolve (a
# Requires that isn't found is a warning, pkg-config's own message
# included), and their -l libraries must exist. Not using
# PKG_CONFIG_SYSROOT_DIR or PKG_CONFIG_LIBDIR on purpose: the first would
# rewrite the system's -L paths into $D, the second hides the system's
# .pc files. What's wrong *inside* a .pc file (a build-tree path) is
# audit_recipe.sh's to report.
#
# Not checked here: LICENSE's SPDX validity (dropped; LICENSE is only
# checked to be set, and audit_recipe.sh compares it with the source).
#
# A *-config that answers neither --version nor --libs isn't a
# pkg-config-style script (some are named *-config for something else),
# so it's skipped and listed as skipped.
#
# Never fails the build: every finding is a warning (a GitHub Actions
# ::warning:: annotation plus a line in the log), like xezat's logged
# errors were. Runs after `cygport ... install`, so $D is populated, and
# before `xezat bump`, so a bad build doesn't get a changelog entry.
#
# Usage:
#   validate_recipe.sh --dir yacp/googletest --file googletest-1.18.0-1bl1.cygport

set -uo pipefail # NOT -e: a failing check is a finding, not a stop

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

categories="$(cd "$(dirname "$0")/.." && pwd)/data/categories.yml"
[[ -f "$categories" ]] || { echo "validate_recipe.sh: $categories not found" >&2; exit 1; }
installed_db="${VALIDATE_INSTALLED_DB:-/etc/setup/installed.db}" # overridable for tests

cd "$dir"
[[ -f "$cygport_file" ]] || { echo "No such file: $dir/$cygport_file" >&2; exit 1; }

# Same `cygport <file> vars <NAME>` mechanism as audit_recipe.sh.
vars_decl="$(cygport "$cygport_file" vars PN PV CATEGORY HOMEPAGE LICENSE LICENSE_URI BUILD_REQUIRES S D 2>/dev/null)"
if [[ -z "$vars_decl" ]]; then
  echo "validate_recipe.sh: 'cygport $cygport_file vars ...' returned nothing -- nothing to validate" >&2
  exit 0
fi
PN="" PV="" CATEGORY="" HOMEPAGE="" LICENSE="" LICENSE_URI="" BUILD_REQUIRES="" S="" D=""
eval "$vars_decl"

warnings=0
warn() { echo "::warning::validate_recipe.sh: $*"; warnings=$((warnings + 1)); }
say() { echo "$*"; }

# HTTP status of one GET without following redirects (a 3xx stays a 3xx,
# as xezat's Net::HTTP.get_response did). Prints "<code>"; 000 when the
# server couldn't be reached at all, which is a warning of its own but
# not a failure -- the network is no reason to fail the build.
http_code() {
  local out
  out="$(curl -s -o /dev/null --max-time 30 -w '%{http_code}' "$1" 2>/dev/null)"
  echo "${out:-000}"
}

check_url() { # <label> <url>
  local label="$1" url="$2" code
  code="$(http_code "$url")"
  if [[ "$code" == 200 ]]; then
    say "$label = $url (200)"
  elif [[ "$code" == 000 ]]; then
    warn "$label $url: cannot reach it"
  else
    warn "$label $url returns $code, not 200"
  fi
}

# --- .cygport: no BOM -------------------------------------------------
if [[ "$(head -c 3 "$cygport_file" | od -An -tx1 | tr -d ' \n')" == efbbbf ]]; then
  warn ".cygport contains a BOM"
fi

# --- CATEGORY: each word is in data/categories.yml (case-insensitive) --
if [[ -z "${CATEGORY// /}" ]]; then
  warn "CATEGORY is not defined"
else
  for cat in $CATEGORY; do
    lower="$(tr 'A-Z' 'a-z' <<< "$cat")"
    grep -qxF -- "- $lower" "$categories" || warn "CATEGORY is invalid: $cat"
  done
fi

# --- HOMEPAGE: 200 -----------------------------------------------------
if [[ -z "$HOMEPAGE" ]]; then
  warn "HOMEPAGE is not defined"
else
  check_url HOMEPAGE "$HOMEPAGE"
fi

# --- LICENSE: presence only (SPDX validity is not checked) -------------
if [[ -z "$LICENSE" ]]; then
  warn "LICENSE is not defined"
fi

# --- LICENSE_URI: 200 for a URL, or an existing file under $S ----------
if [[ -z "$LICENSE_URI" ]]; then
  warn "LICENSE_URI is not defined"
elif [[ "$LICENSE_URI" == http://* || "$LICENSE_URI" == https://* ]]; then
  check_url LICENSE_URI "$LICENSE_URI"
elif [[ -e "$S/$LICENSE_URI" ]]; then
  say "LICENSE_URI = $LICENSE_URI"
else
  warn "LICENSE_URI = $LICENSE_URI (not found under \$S)"
fi

# --- BUILD_REQUIRES: each package is installed ---------------------------
for pkg in $BUILD_REQUIRES; do
  if [[ ! -f "$installed_db" ]]; then
    warn "$installed_db not found, BUILD_REQUIRES can't be checked"
    break
  fi
  awk -v want="$pkg" 'NF == 3 && $1 == want { found = 1 } END { exit !found }' "$installed_db" \
    || warn "BUILD_REQUIRES: $pkg not installed"
done

shopt -s nullglob

# Where a -l library may live, as xezat looked it up: $D/usr/lib, then
# /usr/lib, /usr/lib/w32api and the compiler's own library directory.
# That last one is gcc's libgcc directory (gcc-core's
# /usr/lib/gcc/<target>/<major>), taken from gcc itself so it doesn't
# need the version parsed out of cygcheck's output.
gcc_libdir=""
libgcc="$(gcc -print-libgcc-file-name 2>/dev/null)"
[[ "$libgcc" == /* ]] && gcc_libdir="$(dirname "$libgcc")"
lib_dirs=("$D/usr/lib" /usr/lib /usr/lib/w32api)
[[ -n "$gcc_libdir" ]] && lib_dirs+=("$gcc_libdir")

# One -l<name> from a --libs output: <owner> is who asked for it, for the
# warning.
check_lib_flag() { # <owner> <-lname>
  local owner="$1" lib="${2#-l}" dir
  for dir in "${lib_dirs[@]}"; do
    [[ -f "$dir/lib$lib.dll.a" || -f "$dir/lib$lib.a" ]] && return 0
  done
  warn "$owner --libs: -l$lib not found (looked in ${lib_dirs[*]})"
}

# --- *-config (under $D/usr/bin) ---------------------------------------
for config in "$D"/usr/bin/*-config; do
  name="$(basename "$config")"

  version="$(timeout 5 "$config" --version </dev/null 2>/dev/null)"
  version_rc=$?
  libs="$(timeout 5 "$config" --libs </dev/null 2>/dev/null)"
  libs_rc=$?

  if (( version_rc != 0 && libs_rc != 0 )); then
    say "$name: not a pkg-config style *-config (neither --version nor --libs works), skipped"
    continue
  fi

  if (( version_rc == 0 )); then
    version="${version//$'\r'/}"
    pv="${PV%%+*}"
    [[ "$version" == "$pv" ]] || warn "$name --version is '$version', not \$PV ($pv)"
  fi

  if (( libs_rc == 0 )); then
    for opt in $libs; do
      [[ "$opt" == -l* ]] && check_lib_flag "$name" "$opt"
    done
  fi
done

# --- *.pc (under $D/usr/lib/pkgconfig and usr/share/pkgconfig) ---------
# The .pc files are looked up by name with pkg-config, with $D's
# directories first. The system's own .pc files stay visible behind
# them, as they'd be for the package's users, so a Requires on something
# installed is resolved the same way.
pc_path=""
for pcdir in "$D/usr/lib/pkgconfig" "$D/usr/share/pkgconfig"; do
  [[ -d "$pcdir" ]] && pc_path="${pc_path:+$pc_path:}$pcdir"
done

if [[ -n "$pc_path" ]]; then
  if ! command -v pkg-config >/dev/null 2>&1; then
    warn "pkg-config is not installed, *.pc files under \$D can't be checked"
  else
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    declare -A seen=()
    pc() { PKG_CONFIG_PATH="$pc_path" pkg-config "$@"; }
    for pcfile in "$D"/usr/lib/pkgconfig/*.pc "$D"/usr/share/pkgconfig/*.pc; do
      name="$(basename "$pcfile" .pc)"
      [[ -n "${seen[$name]:-}" ]] && continue
      seen[$name]=1

      modversion="$(pc --modversion "$name" 2>"$tmp/err")" \
        || { warn "$name.pc: pkg-config can't read it: $(tr '\n' ' ' < "$tmp/err")"; continue; }
      pv="${PV%%+*}"
      [[ "$modversion" == "$pv" ]] || warn "$name.pc: modversion is '$modversion', not \$PV ($pv)"

      prefix="$(pc --variable=prefix "$name" 2>/dev/null)"
      if [[ -n "$prefix" && "$prefix" != /usr ]]; then
        warn "$name.pc: prefix = $prefix (not standard)"
      fi

      libs="$(pc --libs --print-errors "$name" 2>"$tmp/err")"
      if (( $? != 0 )); then
        warn "$name.pc: --libs failed: $(tr '\n' ' ' < "$tmp/err")"
        continue
      fi
      for opt in $libs; do
        [[ "$opt" == -l* ]] && check_lib_flag "$name.pc" "$opt"
      done
    done
  fi
fi

# --- AppStream: nothing in the legacy path -----------------------------
for file in "$D"/usr/share/appdata/*; do
  warn "$(basename "$file") is in the legacy AppStream path /usr/share/appdata, move it to /usr/share/metainfo"
done

if (( warnings == 0 )); then
  say "validate_recipe.sh: no warnings"
else
  say "validate_recipe.sh: $warnings warning(s)"
fi
exit 0
