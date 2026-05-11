#!/usr/bin/env bash
# Idempotently register worktree-handoff hooks in ~/.claude/settings.json.
# Safe to run multiple times — it will not duplicate existing hook entries
# that point to this skill's scripts.
#
# Hooks installed:
#   SessionStart      (startup|resume|compact) -> session-start.sh
#   SessionEnd        (any reason)             -> session-end.sh
#   PostToolUse       (Edit|Write|Read|Bash|Grep|Glob|NotebookEdit) -> post-tool-use.sh
#   UserPromptSubmit  (any prompt)             -> user-prompt-submit.sh
#   PreCompact        (manual|auto)            -> pre-compact.sh
#
# Usage:
#   bash ~/.claude/skills/worktree-handoff/scripts/install-hooks.sh

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="$SKILL_DIR/scripts"
SESSION_START="$SCRIPTS/session-start.sh"
SESSION_END="$SCRIPTS/session-end.sh"
POST_TOOL_USE="$SCRIPTS/post-tool-use.sh"
USER_PROMPT="$SCRIPTS/user-prompt-submit.sh"
PRE_COMPACT="$SCRIPTS/pre-compact.sh"
SETTINGS="$HOME/.claude/settings.json"

for script in "$SESSION_START" "$SESSION_END" "$POST_TOOL_USE" "$USER_PROMPT" "$PRE_COMPACT"; do
  if [[ ! -x "$script" ]]; then
    chmod +x "$script" 2>/dev/null || true
  fi
  if [[ ! -x "$script" ]]; then
    echo "error: hook script missing or not executable at $script" >&2
    exit 1
  fi
done

if [[ ! -f "$SETTINGS" ]]; then
  echo "{}" > "$SETTINGS"
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required to safely merge settings.json — install it first (brew install jq)" >&2
  exit 1
fi

# Snapshot before mutating.
backup="$SETTINGS.bak.$(date -u +%Y%m%dT%H%M%SZ)"
cp "$SETTINGS" "$backup"

tmp="$(mktemp)"
jq \
  --arg start "$SESSION_START" \
  --arg end "$SESSION_END" \
  --arg post "$POST_TOOL_USE" \
  --arg prompt "$USER_PROMPT" \
  --arg precompact "$PRE_COMPACT" '
  .hooks //= {}
  | .hooks.SessionStart //= []
  | .hooks.SessionEnd //= []
  | .hooks.PostToolUse //= []
  | .hooks.UserPromptSubmit //= []
  | .hooks.PreCompact //= []

  | if ([.hooks.SessionStart[]?.hooks[]?.command // empty] | index($start)) then .
    else .hooks.SessionStart += [{
      matcher: "startup|resume|compact",
      hooks: [{type: "command", command: $start, timeout: 10}]
    }] end

  | if ([.hooks.SessionEnd[]?.hooks[]?.command // empty] | index($end)) then .
    else .hooks.SessionEnd += [{
      hooks: [{type: "command", command: $end, timeout: 10}]
    }] end

  | if ([.hooks.PostToolUse[]?.hooks[]?.command // empty] | index($post)) then .
    else .hooks.PostToolUse += [{
      matcher: "Edit|Write|Read|Bash|Grep|Glob|NotebookEdit",
      hooks: [{type: "command", command: $post, timeout: 5}]
    }] end

  | if ([.hooks.UserPromptSubmit[]?.hooks[]?.command // empty] | index($prompt)) then .
    else .hooks.UserPromptSubmit += [{
      hooks: [{type: "command", command: $prompt, timeout: 10}]
    }] end

  | if ([.hooks.PreCompact[]?.hooks[]?.command // empty] | index($precompact)) then .
    else .hooks.PreCompact += [{
      matcher: "manual|auto",
      hooks: [{type: "command", command: $precompact, timeout: 10}]
    }] end
  ' "$SETTINGS" > "$tmp"

mv "$tmp" "$SETTINGS"

echo "Installed worktree-handoff hooks into $SETTINGS"
echo "Backup saved to $backup"
echo
echo "Hooks registered:"
echo "  SessionStart     (startup|resume|compact)                       -> $SESSION_START"
echo "  SessionEnd       (any reason)                                   -> $SESSION_END"
echo "  PostToolUse      (Edit|Write|Read|Bash|Grep|Glob|NotebookEdit)  -> $POST_TOOL_USE"
echo "  UserPromptSubmit (any prompt)                                   -> $USER_PROMPT"
echo "  PreCompact       (manual|auto)                                  -> $PRE_COMPACT"
echo
echo "New Claude Code sessions will pick these up automatically."
