# Sourced by audit_recipe.sh: the "*-config", "*.pc", "AppStream" and
# "Duplicate files" sections, on what the packages install for other builds to use. These
# checks (but the build-tree one) used to be the Validate build step
# (validate_recipe.sh, which replaced `xezat validate`). They read $D, so
# audit_recipe.sh runs them only once `cygport package` succeeded.
#
# Each section's header is printed only when it has a warning.

# Where a -l library may live, as xezat looked it up: $D/usr/lib, then
# /usr/lib, /usr/lib/w32api and the compiler's own library directory --
# gcc-core's /usr/lib/gcc/<target>/<major>, taken from gcc itself so it
# doesn't need the version parsed out of cygcheck's output.
installed_lib_dirs() {
  local libgcc
  lib_dirs=("$D/usr/lib" /usr/lib /usr/lib/w32api)
  libgcc="$(gcc -print-libgcc-file-name 2>/dev/null)"
  [[ "$libgcc" == /* ]] && lib_dirs+=("$(dirname "$libgcc")")
}

# Prints "<owner> --libs: -l<name> not found ..." for each -l in <libs>
# that's in none of lib_dirs.
missing_libs() { # <owner> <libs>
  local owner="$1" opt lib dir
  for opt in $2; do
    [[ "$opt" == -l* ]] || continue
    lib="${opt#-l}"
    for dir in "${lib_dirs[@]}"; do
      [[ -f "$dir/lib$lib.dll.a" || -f "$dir/lib$lib.a" ]] && continue 2
    done
    echo "$owner --libs: -l$lib not found (looked in ${lib_dirs[*]})"
  done
}

# Each $D/usr/bin/*-config: --version is $PV, --libs' -l libraries
# exist. One that answers neither --version nor --libs isn't a
# pkg-config-style script (some are named *-config for something else)
# and is skipped.
audit_config_scripts() {
  local -a lib_dirs found=()
  local config name version version_rc libs libs_rc pv="${PV%%+*}" line
  shopt -s nullglob
  local -a configs=("$D"/usr/bin/*-config)
  shopt -u nullglob
  (( ${#configs[@]} > 0 )) || return 0
  installed_lib_dirs

  local before detail
  for config in "${configs[@]}"; do
    before=${#found[@]}
    name="$(basename "$config")"
    version="$(timeout 5 "$config" --version </dev/null 2>/dev/null)"
    version_rc=$?
    libs="$(timeout 5 "$config" --libs </dev/null 2>/dev/null)"
    libs_rc=$?
    if (( version_rc != 0 && libs_rc != 0 )); then
      ok "*-config: $name answers neither --version nor --libs, skipped as not pkg-config style"
      continue
    fi
    if (( version_rc == 0 )); then
      version="${version//$'\r'/}"
      [[ "$version" == "$pv" ]] || found+=("$name --version is '$version', not \$PV ($pv)")
    fi
    if (( libs_rc == 0 )); then
      while IFS= read -r line; do
        [[ -n "$line" ]] && found+=("$line")
      done < <(missing_libs "$name" "$libs")
    fi
    if (( ${#found[@]} == before )); then
      detail=""
      (( version_rc == 0 )) && detail+=" --version $version"
      (( libs_rc == 0 )) && detail+=" --libs $libs"
      ok "*-config: $name$detail"
    fi
  done

  (( ${#found[@]} > 0 )) || return 0
  say ""
  say "== *-config =="
  for line in "${found[@]}"; do
    warn "$line"
  done
}

# Each *.pc under $D (usr/lib/pkgconfig, usr/share/pkgconfig), two ways.
#
# Read with pkg-config, $D's directories first in PKG_CONFIG_PATH: the
# version must be $PV, the prefix /usr, --libs must resolve (a Requires
# that isn't found is warned with pkg-config's own message) and its -l
# libraries exist. The system's own .pc files stay visible behind $D's,
# as they'd be for the package's users, so a Requires on something
# installed resolves the same way. Not PKG_CONFIG_SYSROOT_DIR (it would
# rewrite the system's -L paths into $D) nor PKG_CONFIG_LIBDIR (it hides
# the system's .pc files).
#
# And by line: one that names the build tree ($S, $B, $D, $C) or a
# /cygdrive, /home or /tmp path -- prefix, libdir, Libs, Cflags -- works
# on this build and nowhere else, so the .pc itself has to be fixed (a
# ${prefix}-relative path, or a patch of the .pc in src_patch or
# src_install), not the build output.
audit_pc_files() {
  local -a lib_dirs pats=() found=()
  local -A seen=()
  local p pcdir pcfile pc_path="" name modversion prefix libs hits hit line before pv="${PV%%+*}"
  shopt -s nullglob
  local -a pcfiles=("$D"/usr/lib/pkgconfig/*.pc "$D"/usr/share/pkgconfig/*.pc)
  shopt -u nullglob
  (( ${#pcfiles[@]} > 0 )) || return 0

  for pcdir in "$D/usr/lib/pkgconfig" "$D/usr/share/pkgconfig"; do
    [[ -d "$pcdir" ]] && pc_path="${pc_path:+$pc_path:}$pcdir"
  done
  if ! command -v pkg-config >/dev/null 2>&1; then
    found+=("pkg-config is not installed, *.pc files under \$D can't be read with it")
  else
    installed_lib_dirs
    for pcfile in "${pcfiles[@]}"; do
      name="$(basename "$pcfile" .pc)"
      [[ -n "${seen[$name]:-}" ]] && continue
      seen[$name]=1
      before=${#found[@]}
      if ! modversion="$(PKG_CONFIG_PATH="$pc_path" pkg-config --modversion "$name" 2>"$tmp/pc-err")"; then
        found+=("$name.pc: pkg-config can't read it: $(tr '\n' ' ' < "$tmp/pc-err")")
        continue
      fi
      [[ "$modversion" == "$pv" ]] || found+=("$name.pc: modversion is '$modversion', not \$PV ($pv)")
      prefix="$(PKG_CONFIG_PATH="$pc_path" pkg-config --variable=prefix "$name" 2>/dev/null)"
      [[ -z "$prefix" || "$prefix" == /usr ]] || found+=("$name.pc: prefix = $prefix, not /usr")
      if ! libs="$(PKG_CONFIG_PATH="$pc_path" pkg-config --libs --print-errors "$name" 2>"$tmp/pc-err")"; then
        found+=("$name.pc: --libs failed: $(tr '\n' ' ' < "$tmp/pc-err")")
        continue
      fi
      while IFS= read -r line; do
        [[ -n "$line" ]] && found+=("$line")
      done < <(missing_libs "$name.pc" "$libs")
      (( ${#found[@]} > before )) || ok "*.pc: $name.pc version $modversion, prefix ${prefix:-(none)}, --libs ${libs:-(none)}"
    done
  fi

  for p in "$S" "$B" "$D" "$C"; do
    [[ -n "$p" && "$p" != / ]] && pats+=("$p")
  done
  printf '%s\n' "${pats[@]}" > "$tmp/pc-patterns"
  for pcfile in "${pcfiles[@]}"; do
    hits="$( { grep -nF -f "$tmp/pc-patterns" "$pcfile"; grep -nE '/cygdrive/|/home/|/tmp/' "$pcfile"; } 2>/dev/null | sort -t: -k1,1n -u)"
    [[ -n "$hits" ]] || ok "*.pc: ${pcfile#"$D"/} names nothing of the build tree"
    while IFS= read -r hit; do
      [[ -n "$hit" ]] || continue
      found+=("${pcfile#"$D"/}:${hit%%:*} names the build tree: ${hit#*:} -- fix the .pc itself (a \${prefix}-relative path, or a patch of it in src_patch or src_install)")
    done <<< "$hits"
  done

  (( ${#found[@]} > 0 )) || return 0
  say ""
  say "== *.pc =="
  for line in "${found[@]}"; do
    warn "$line"
  done
}

# Nothing left in the legacy AppStream path /usr/share/appdata.
audit_appstream() {
  local file printed=0
  for file in "$D"/usr/share/appdata/*; do
    [[ -e "$file" ]] || continue
    if (( ! printed )); then
      say ""
      say "== AppStream =="
      printed=1
    fi
    warn "usr/share/appdata/$(basename "$file") is in the legacy AppStream path -- install it into /usr/share/metainfo"
  done
  (( printed )) || ok "AppStream: nothing in the legacy path usr/share/appdata"
}

# Nothing of CMake's in usr/share/cmake. CMake finds a package's
# <name>Config.cmake under <prefix>/share/cmake/<name>*/ as well as
# <prefix>/lib/cmake/<name>*/, but Cygwin packages keep them in
# usr/lib/cmake, so a file in usr/share/cmake is what an install that
# defaulted to the architecture-independent directory left. (usr/share/
# cmake-X.Y is CMake's own, and isn't looked at.)
audit_cmake_share() {
  local entry printed=0
  for entry in "$D"/usr/share/cmake/*; do
    [[ -e "$entry" ]] || continue
    if (( ! printed )); then
      say ""
      say "== CMake files =="
      printed=1
    fi
    warn "usr/share/cmake/$(basename "$entry") is in usr/share/cmake -- install it into /usr/lib/cmake (the package's own *_INSTALL_CMAKEDIR / CMAKE_INSTALL_PACKAGEDIR option, or move it in src_install)"
  done
  (( printed )) || ok "CMake files: nothing in usr/share/cmake"
}

# A file upstream's install left that has the same content as one cygport
# put in usr/share/doc/$PN itself (e.g. usr/share/<name>/LICENSE),
# under any name. Empty files say nothing, usr/share/doc/$PN's own tree is
# upstream's documentation, and usr/src holds the debuginfo sources.
audit_duplicate_docs() {
  local doc_dir="$D/usr/share/doc/$PN" doc size file printed=0 checked=0
  [[ -d "$doc_dir" ]] || return 0
  while IFS= read -r -d '' doc; do
    size="$(wc -c <"$doc" | tr -d '[:space:]')"
    checked=$((checked + 1))
    while IFS= read -r -d '' file; do
      cmp -s "$doc" "$file" || continue
      if (( ! printed )); then
        say ""
        say "== Duplicate files =="
        printed=1
      fi
      warn "${file#"$D"/} is a copy of ${doc#"$D"/}, which cygport installs itself -- remove it in src_install"
    done < <(find "$D" \( -path "$doc_dir" -o -path "$D/usr/src" -o -path "$D/usr/share/doc/Cygwin" \) -prune \
      -o -type f -size "${size}c" -print0)
  done < <(find "$doc_dir" -maxdepth 1 -type f -size +0 -print0)
  (( printed )) || ok "Duplicate files: none of the $checked file(s) in usr/share/doc/$PN has a copy elsewhere"
}
