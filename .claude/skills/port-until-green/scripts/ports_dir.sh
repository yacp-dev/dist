#!/usr/bin/env bash
# The local clone of yacp-dev/ports, from $PORTS_DIR (set it in the
# environment, e.g. the "env" of .claude/settings.local.json; where it
# lives is the user's business, so no path is written down here).
# Cloned there if it isn't yet.
#
# Other sessions share this clone: never check out or reset in it.
# Branch work goes in a worktree (worktree.sh).
#
# Usage:
#   ports=$(scripts/ports_dir.sh)
# Output: the clone's path (stdout); exit 1 when PORTS_DIR is unset.

set -euo pipefail

if [[ -z "${PORTS_DIR:-}" ]]; then
  # Fall back to .claude/settings.local.json when running outside Claude Code (e.g. agy)
  here="$(cd "$(dirname "$0")" && pwd)"
  for settings in "$here/../../../settings.local.json" "$here/../../../../.claude/settings.local.json"; do
    if [[ -f "$settings" ]]; then
      candidate="$(python3 -c "import json; print(json.load(open('$settings')).get('env', {}).get('PORTS_DIR', ''))" 2>/dev/null || true)"
      if [[ -n "$candidate" ]]; then
        PORTS_DIR="$candidate"
        break
      fi
    fi
  done
fi

[[ -n "${PORTS_DIR:-}" ]] || {
  echo "PORTS_DIR is unset: set it to where the yacp-dev/ports clone lives (or should be cloned)" >&2
  exit 1
}
if [[ ! -d "$PORTS_DIR/.git" ]]; then
  gh repo clone yacp-dev/ports "$PORTS_DIR" -- -q >&2
fi
echo "$PORTS_DIR"
