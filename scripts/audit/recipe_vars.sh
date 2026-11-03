# Sourced by audit_recipe.sh: the "Recipe" section, on what the
# .cygport file itself says. These checks used to be the Validate build
# step (validate_recipe.sh, which replaced `xezat validate`): the file
# has no BOM, CATEGORY is one of data/categories.yml's (xezat's list,
# copied into dorgann), HOMEPAGE and LICENSE_URI answer 200 (a HOMEPAGE
# that redirects is warned with the URL to set instead), LICENSE is set
# (no SPDX validation; the LICENSE section compares it with the source),
# every BUILD_REQUIRES package is installed (/etc/setup/installed.db,
# overridable with AUDIT_INSTALLED_DB for tests), and PATCH_URI, *_REQUIRES
# and LICENSE are where ports' recipes keep them (audit/recipe_order.awk).
#
# None of this needs the build to have got anywhere, so the section runs
# whichever step failed -- a BUILD_REQUIRES package that isn't installed
# is as likely a cause of a failed build as anything. Only LICENSE_URI as
# a path needs $S, and is skipped without it (prep never ran).
#
# Prints the section header only when there's a warning.

# Resolved now: audit_recipe.sh sources this before it cd's into the
# package directory, and a relative BASH_SOURCE wouldn't survive that.
recipe_vars_categories="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/data/categories.yml"
recipe_vars_order_awk="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/recipe_order.awk"

audit_recipe_vars() {
  local categories="$recipe_vars_categories" installed_db cat pkg header=0
  installed_db="${AUDIT_INSTALLED_DB:-/etc/setup/installed.db}"

  rwarn() {
    if (( ! header )); then
      say ""
      say "== Recipe =="
      header=1
    fi
    warn "$*"
  }

  # HTTP status of one GET, without following redirects; 000 when the
  # server couldn't be reached at all, which is a warning of its own --
  # the network is no reason to fail anything.
  check_url() { # <label> <url>
    local label="$1" url="$2" out code target
    out="$(curl -s -o /dev/null --max-time 30 -w '%{http_code} %{redirect_url}' "$url" 2>/dev/null)"
    code="${out%% *}"
    target="${out#* }"
    [[ "$code" == "$out" ]] && target=""
    case "${code:-000}" in
      200) ok "Recipe: $label $url answers 200" ;;
      000) rwarn "$label $url: cannot reach it" ;;
      3??)
        # Only the first hop: a chain of redirects is reported as its
        # first target.
        if [[ -n "$target" ]]; then
          rwarn "$label $url redirects ($code) to $target -- set $label to that URL"
        else
          rwarn "$label $url redirects ($code) without a Location -- check where it points and set $label to that"
        fi
        ;;
      *) rwarn "$label $url returns $code, not 200" ;;
    esac
  }

  if [[ "$(head -c 3 "$cygport_file" | od -An -tx1 | tr -d ' \n')" == efbbbf ]]; then
    rwarn "$cygport_file starts with a BOM -- remove it"
  else
    ok "Recipe: $cygport_file has no BOM"
  fi

  if [[ -z "${CATEGORY// /}" ]]; then
    rwarn "CATEGORY is not defined"
  elif [[ ! -f "$categories" ]]; then
    rwarn "$categories not found, CATEGORY can't be checked"
  else
    for cat in $CATEGORY; do
      if grep -qxF -- "- ${cat,,}" "$categories"; then
        ok "Recipe: CATEGORY $cat is in data/categories.yml"
      else
        rwarn "CATEGORY is invalid: $cat (not in data/categories.yml)"
      fi
    done
  fi

  if [[ -z "$HOMEPAGE" ]]; then
    rwarn "HOMEPAGE is not defined"
  else
    check_url HOMEPAGE "$HOMEPAGE"
  fi

  if [[ -n "$LICENSE" ]]; then
    ok "Recipe: LICENSE is set ($LICENSE)"
  else
    rwarn "LICENSE is not defined (see port-until-green's \"Missing LICENSE\")"
  fi

  if [[ -z "$LICENSE_URI" ]]; then
    rwarn "LICENSE_URI is not defined"
  elif [[ "$LICENSE_URI" == http://* || "$LICENSE_URI" == https://* ]]; then
    check_url LICENSE_URI "$LICENSE_URI"
  elif [[ -d "$S" && ! -e "$S/$LICENSE_URI" ]]; then
    rwarn "LICENSE_URI = $LICENSE_URI is not found under \$S"
  elif [[ -d "$S" ]]; then
    ok "Recipe: LICENSE_URI = $LICENSE_URI is under \$S"
  fi

  if [[ -n "${BUILD_REQUIRES// /}" ]]; then
    if [[ ! -f "$installed_db" ]]; then
      rwarn "$installed_db not found, BUILD_REQUIRES can't be checked"
    else
      local w0=$warnings
      for pkg in $BUILD_REQUIRES; do
        awk -v want="$pkg" 'NF == 3 && $1 == want { found = 1 } END { exit !found }' "$installed_db" \
          || rwarn "BUILD_REQUIRES: $pkg is not installed -- setup couldn't install it: misspelled, or not a Cygwin package?"
      done
      (( warnings > w0 )) || ok "Recipe: all $(wc -w <<<"$BUILD_REQUIRES" | tr -d ' ') BUILD_REQUIRES package(s) are installed"
    fi
  fi

  local misplaced w1=$warnings
  while IFS= read -r misplaced; do
    [[ -n "$misplaced" ]] && rwarn "$misplaced"
  done < <(awk -f "$recipe_vars_order_awk" "$cygport_file")
  (( warnings > w1 )) || ok "Recipe: PATCH_URI, *_REQUIRES and LICENSE are where ports' recipes keep them"

  unset -f rwarn check_url
}
