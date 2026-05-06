#!/usr/bin/env bash
# PostToolUse hook: silently log Claude's filesystem activity per worktree.
#
# Reads hook event JSON from stdin. For tools that touch the filesystem
# (Edit, Write, Read, Bash, Grep, Glob, NotebookEdit), resolve the target
# path to a git worktree, append a one-line entry to that worktree's
# activity.jsonl, and mark a per-session sentinel on first touch.
#
# This hook never prints to stdout (no context injection here — that happens
# at the next UserPromptSubmit). Always exits 0; failures are silent.

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

exit 0
