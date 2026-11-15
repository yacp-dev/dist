#!/usr/bin/env bash
# The folder this session's worktrees of the ports clone go in: the
# Claude Code session's own scratchpad, so no session touches another's
# checkout and none is left behind next to the clone. A PreToolUse hook
# (~/.claude/hooks/session_worktree.py) refuses `git worktree add`
# anywhere else.
#
#   /private/tmp/claude-<uid>/<project>/<session>/scratchpad/worktrees
#
# PORTS_WORKTREES_DIR overrides it (outside Claude Code).
#
# Usage:
#   root=$(scripts/worktree_root.sh)
# Output: the folder (stdout; not created); exit 1 when no session is found.

set -euo pipefail

if [[ -n "${PORTS_WORKTREES_DIR:-}" ]]; then
  echo "$PORTS_WORKTREES_DIR"
  exit 0
fi

# Antigravity (agy) session
if [[ -n "${ANTIGRAVITY_CONVERSATION_ID:-}" ]]; then
  app_data="${ANTIGRAVITY_APP_DATA_DIR:-$HOME/.gemini/antigravity-cli}"
  echo "$app_data/brain/$ANTIGRAVITY_CONVERSATION_ID/scratch/worktrees"
  exit 0
fi

sid="${CLAUDE_CODE_SESSION_ID:-}"
[[ -n "$sid" ]] || { echo "not in a Claude Code or Antigravity session; set PORTS_WORKTREES_DIR" >&2; exit 1; }

shopt -s nullglob
found=("/private/tmp/claude-$(id -u)"/*/"$sid"/scratchpad)
(( ${#found[@]} == 1 )) || { echo "no scratchpad for session $sid under /private/tmp/claude-$(id -u)" >&2; exit 1; }
echo "${found[0]}/worktrees"
