#!/usr/bin/env bash
# PostToolUse hook: log Claude's filesystem activity per worktree, and on
# first touch of a worktree this session, inject that worktree's handoff
# inline (same turn) via hookSpecificOutput.additionalContext.
#
# Reads hook event JSON from stdin. For tools that touch the filesystem
# (Edit, Write, Read, Bash, Grep, Glob, NotebookEdit), resolve the target
# path to a git worktree, append a one-line entry to that worktree's
# activity.jsonl, and mark a per-session sentinel.
#
# Same-turn injection: if the worktree hasn't been delivered yet this
# session, emit a JSON payload with the handoff so Claude sees it before
# its same-turn response. Whether Claude Code surfaces additionalContext
# from PostToolUse is version-dependent; UserPromptSubmit stays wired up
# as the reliable fallback (it skips already-delivered worktrees).
#
# Always exits 0; failures fall back to silence.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

input="$(cat || true)"
[[ -z "$input" ]] && exit 0

command -v jq >/dev/null 2>&1 || exit 0

session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
tool="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)"
[[ -z "$session_id" || -z "$tool" ]] && exit 0

# Pick the path most likely to identify which worktree this tool call hit.
target_path=""
detail=""
case "$tool" in
  Edit|Write|Read|NotebookEdit)
    target_path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
    detail="$target_path"
    ;;
  Bash)
    target_path="$(printf '%s' "$input" | jq -r '.tool_input.cwd // empty' 2>/dev/null)"
    [[ -z "$target_path" ]] && target_path="$cwd"
    detail="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null | head -c 200)"
    ;;
  Grep|Glob)
    target_path="$(printf '%s' "$input" | jq -r '.tool_input.path // empty' 2>/dev/null)"
    [[ -z "$target_path" ]] && target_path="$cwd"
    detail="$(printf '%s' "$input" | jq -r '.tool_input.pattern // .tool_input.query // empty' 2>/dev/null | head -c 200)"
    ;;
  *)
    exit 0
    ;;
esac

[[ -z "$target_path" ]] && exit 0

context_dir="$(resolve_context_dir_for_path "$target_path" || true)"
[[ -z "$context_dir" ]] && exit 0

mkdir -p "$context_dir"

# Append to activity log.
ts="$(now_iso)"
log_line="$(jq -nc \
  --arg ts "$ts" \
  --arg tool "$tool" \
  --arg path "$target_path" \
  --arg detail "$detail" \
  --arg session "$session_id" \
  '{ts:$ts, tool:$tool, path:$path, detail:$detail, session:$session}' 2>/dev/null)"

if [[ -n "$log_line" ]]; then
  printf '%s\n' "$log_line" >> "$context_dir/activity.jsonl"
fi

# Mark first-touch sentinel for this session if not already present.
sentinel="$(session_touched_sentinel "$context_dir" "$session_id")"
[[ ! -f "$sentinel" ]] && touch "$sentinel"

# Same-turn injection: if this worktree's handoff hasn't been delivered
# yet this session, build the autoload payload and emit it now so Claude
# sees it before continuing the current turn.
delivered="$(session_delivered_sentinel "$context_dir" "$session_id")"
if [[ ! -f "$delivered" ]]; then
  wt_name="$(basename "$context_dir")"
  repo_name="$(basename "$(dirname "$context_dir")")"
  handoff_file="$context_dir/handoff.md"
  meta_file="$context_dir/session-meta.json"

  payload=""
  payload+="<<<WORKTREE_CONTEXT_AUTOLOAD>>>"$'\n\n'
  payload+="Your tool call just touched a git worktree that wasn't already loaded as context. Treat the handoff below as your working notes for that worktree, and keep \`handoff.md\` updated as you continue work there."$'\n\n'
  payload+="### Worktree: \`$repo_name/$wt_name\`"$'\n\n'
  payload+="**Context directory:** \`$context_dir\`"$'\n\n'

  if [[ -f "$meta_file" ]]; then
    payload+="**Prior session metadata:**"$'\n\n'
    payload+='```json'$'\n'
    payload+="$(cat "$meta_file")"$'\n'
    payload+='```'$'\n\n'
  fi

  if [[ -f "$handoff_file" ]]; then
    payload+="**Handoff:**"$'\n\n'
    payload+="$(cat "$handoff_file")"$'\n\n'
  else
    payload+="_No \`handoff.md\` exists for this worktree yet. Create one at \`$handoff_file\` if you continue work here._"$'\n\n'
  fi

  jq -n \
    --arg ctx "$payload" \
    '{hookSpecificOutput:{hookEventName:"PostToolUse", additionalContext:$ctx}}' 2>/dev/null

  # Mark delivered so UserPromptSubmit (and subsequent PostToolUse calls
  # in the same worktree) won't re-inject.
  touch "$delivered"
fi

exit 0
