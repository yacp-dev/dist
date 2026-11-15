#!/usr/bin/env bash
# Plays a sound so the user notices the run has finished or needs them.
#
# Which file to play is the user's business: set PORT_SOUND_DONE and
# PORT_SOUND_ASK in the environment (e.g. the "env" of
# .claude/settings.local.json); no path is written down here. Falls back to
# that settings file when running outside Claude Code (e.g. agy).
#
# Does nothing (and exits 0) when the variable is unset, the file is missing
# or afplay is unavailable: the sound is a convenience and must never break
# the loop. Runs detached, so it never delays the report.
#
# Usage:
#   notify_sound.sh done   # the run is over, nothing left to decide (PORT_SOUND_DONE)
#   notify_sound.sh ask    # waiting on the user (PORT_SOUND_ASK)

case "${1:-}" in
  done) var=PORT_SOUND_DONE ;;
  ask)  var=PORT_SOUND_ASK ;;
  *) echo "Usage: notify_sound.sh done|ask" >&2; exit 1 ;;
esac

sound="${!var:-}"
if [[ -z "$sound" ]]; then
  here="$(cd "$(dirname "$0")" && pwd)"
  for settings in "$here/../../../settings.local.json" "$here/../../../../.claude/settings.local.json"; do
    if [[ -f "$settings" ]]; then
      sound="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('env', {}).get(sys.argv[2], ''))" "$settings" "$var" 2>/dev/null || true)"
      [[ -n "$sound" ]] && break
    fi
  done
fi

command -v afplay >/dev/null 2>&1 && [[ -f "$sound" ]] || exit 0
afplay "$sound" >/dev/null 2>&1 &
exit 0
