#!/usr/bin/env bash
# Checks a LICENSE expression the way publish's mksetupini will: calm's
# hint.py parses the license: of every package's hint with the
# license_expression library, strictly, and refuses to write setup.ini
# for the whole dist when one doesn't parse. A recipe whose LICENSE fails
# that builds green and only breaks at publish (duo_unix 2.3.0's
# `GPL-2.0-with-classpath-exception`, a deprecated SPDX id, instead of
# `GPL-2.0-only WITH Classpath-exception-2.0`). This repeats calm's check,
# including the extra ids it permits, so the failure shows up in the
# recipe audit and port-until-green's preflight instead.
#
# Usage: check_license_expression.sh "<LICENSE expression>"
# Exit status 0 if calm accepts it (what it only warns about -- an id the
# library doesn't know, like LicenseRef-*, or a normalization -- is printed
# with status 0), 1 if it refuses it (the reason on stdout, in calm's
# words), 2 if it can't be checked because no python has the
# license_expression module (`pip install license-expression`) and none
# could be installed.
# LICENSE_EXPRESSION_PYTHON names the python to use; otherwise python3
# and python are tried in turn, then (outside GitHub Actions) a venv under
# ~/.cache/dorgann/license-venv, created on first use.

set -uo pipefail

expression="${1:-}"
[[ -n "$expression" ]] || { echo "usage: $0 <LICENSE expression>" >&2; exit 1; }

py=""
for c in ${LICENSE_EXPRESSION_PYTHON:-} python3 python; do
  # The runner hands over a Windows path for the native Python.
  [[ "$c" == *:* ]] && command -v cygpath >/dev/null && c="$(cygpath -u "$c")"
  if "$c" -c 'import license_expression' 2>/dev/null; then py="$c"; break; fi
done

# Locally (not on the runner, where build-package.yml installs the module
# itself) a venv of its own is made once and kept, so the check works
# without anyone installing anything.
if [[ -z "$py" && -z "${GITHUB_ACTIONS:-}" ]]; then
  venv="${XDG_CACHE_HOME:-$HOME/.cache}/dorgann/license-venv"
  if [[ ! -x "$venv/bin/python" ]]; then
    python3 -m venv "$venv" >/dev/null 2>&1 &&
      "$venv/bin/python" -m pip install -q license-expression >/dev/null 2>&1 ||
      rm -rf "$venv"
  fi
  [[ -x "$venv/bin/python" ]] && py="$venv/bin/python"
fi
[[ -n "$py" ]] || exit 2

"$py" -I - "$expression" <<'PY'
import re, sys
import license_expression

# Same list as calm/hint.py's extra_licenses.
index = license_expression.get_license_index()
for l in ('Linux-man-pages-copyleft', 'OFSFDL', 'Public-Domain'):
    if not any(j["spdx_license_key"] == l for j in index):
        index.append({"spdx_license_key": l})
licensing = license_expression.build_spdx_licensing(index)

value = re.sub(r'\s+', ' ', sys.argv[1])
try:
    licensing.parse(value, strict=True)
    le = licensing.validate(value, strict=True)
except license_expression.ExpressionParseError as e:
    print('errors parsing license expression: %s' % e)
    sys.exit(1)
except license_expression.ExpressionError as e:
    print('errors validating license expression: %s' % e)
    sys.exit(1)
# Only warnings in calm (setup.ini is still written), so status 0.
if not le.normalized_expression:
    print('errors in license expression: %s' % (le.errors,))
    sys.exit(0)
if le.original_expression.lower() != le.normalized_expression.lower():
    print("'%s' normalizes to '%s'" % (value, le.normalized_expression))
PY
