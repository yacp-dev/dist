# Sourced by audit_recipe.sh: the "Undefined macros" section.
#
# autoconf's own "undefined macro" errors for a failed cygport compile,
# the failure configure_cygport.sh's m4_pattern_forbid acsite.m4
# deliberately causes when a package uses an AX_*/PKG_* macro whose .m4
# isn't installed (doc/spec.md 4.3.1). cygautoreconf runs inside
# src_compile, so this shows up as a `cygport compile` failure, often
# buried under a verbose autoreconf log -- and the fix (adding
# autoconf-archive/pkgconf to BUILD_REQUIRES) is mechanical enough that
# having the macro names right in the report is what makes it
# actionable without digging through the log. Only the matching error
# lines, never a general log excerpt (doc/spec.md 4.5).
#
# Reads $logdir/<PF>-compile.log, which cygport itself tees src_compile's
# output into. Sets macro_errors to the number of lines found.

audit_undefined_macros() {
  local -a logs
  local found line
  shopt -s nullglob
  logs=("$logdir"/*-compile.log)
  shopt -u nullglob
  macro_errors=0
  (( ${#logs[@]} > 0 )) || return 0
  # autoconf 2.69 says "possibly undefined macro", 2.72+ "undefined or
  # overquoted macro" (confirmed locally against 2.73, the version
  # Cygwin's autoconf2.7 currently ships).
  found="$(grep -hE 'error: (possibly undefined|undefined or overquoted) macro: ' "${logs[@]}")"
  if [[ -z "$found" ]]; then
    ok "Undefined macros: none in ${#logs[@]} compile log(s)"
    return 0
  fi
  macro_errors="$(wc -l <<<"$found" | tr -d ' ')"
  say ""
  say "== Undefined macros =="
  while IFS= read -r line; do
    warn "$line"
  done <<<"$found"
  say "An AX_* macro usually means BUILD_REQUIRES is missing autoconf-archive,"
  say "a PKG_* macro pkgconf. If the token is a false positive, patch in an"
  say "m4_pattern_allow for it instead (doc/spec.md 4.3.1)."
}
