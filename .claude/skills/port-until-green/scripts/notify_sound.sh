#!/usr/bin/env bash
# Plays a sound so the user notices the run has finished or needs them.
#
# Does nothing (and exits 0) where afplay or the sound file is missing
# (non-macOS, SSH): the sound is a convenience and must never break the loop.
# Runs detached, so it never delays the report.
#
# Usage:
#   notify_sound.sh done   # the run is over, nothing left to decide
#   notify_sound.sh ask    # waiting on the user (decision, review, question)

case "${1:-}" in
  done) sound=/System/Library/Sounds/Glass.aiff ;;
  ask)  sound=/System/Library/Sounds/Ping.aiff ;;
  *) echo "Usage: notify_sound.sh done|ask" >&2; exit 1 ;;
esac

command -v afplay >/dev/null 2>&1 && [[ -f "$sound" ]] || exit 0
afplay "$sound" >/dev/null 2>&1 &
exit 0
