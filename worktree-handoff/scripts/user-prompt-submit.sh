#!/usr/bin/env bash
# UserPromptSubmit hook: at the start of each user turn, scan worktree
# context dirs for first-touch sentinels matching this session, and inject
# the handoff for any worktree whose handoff hasn't been delivered yet
# this session.
#
# This is what makes "context switching mid-session" silent: when Claude
# touches a new worktree via PostToolUse, the next user turn auto-loads
# that worktree's handoff so Claude can keep its own working memory current.
#
# Reads hook event JSON from stdin. Emits JSON with hookSpecificOutput.
# Always exits 0; failures emit no additionalContext rather than blocking.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

input="$(cat || true)"
[[ -z "$input" ]] && exit 0

command -v jq >/dev/null 2>&1 || exit 0

session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)"
[[ -z "$session_id" ]] && exit 0

ctx_root="${WORKTREE_HANDOFF_ROOT:-$HOME/worktrees/contexts}"
[[ ! -d "$ctx_root" ]] && exit 0

# Find every context dir that has a touched-sentinel for this session AND
# does not yet have a delivered-sentinel for this session.
to_inject=()
while IFS= read -r -d '' sentinel; do
  ctx_dir="$(dirname "$sentinel")"
  delivered="$(session_delivered_sentinel "$ctx_dir" "$session_id")"
  [[ -f "$delivered" ]] && continue
  to_inject+=("$ctx_dir")
done < <(find "$ctx_root" -maxdepth 4 -type f -name ".touched-$session_id" -print0 2>/dev/null)

[[ ${#to_inject[@]} -eq 0 ]] && exit 0

# Build payload.
payload=""
payload+="<<<WORKTREE_HANDOFF_AUTOLOAD>>>"$'\n\n'
if [[ ${#to_inject[@]} -eq 1 ]]; then
  payload+="Your tool calls touched a git worktree that wasn't already loaded as context. Treat the handoff below as your working notes for that worktree, and keep \`handoff.md\` updated as you continue work there."$'\n\n'
else
  payload+="Your tool calls touched ${#to_inject[@]} git worktrees that weren't already loaded as context. Each section below is the loaded handoff for one worktree. Keep each \`handoff.md\` updated as you continue work in the corresponding worktree."$'\n\n'
fi

for ctx_dir in "${to_inject[@]}"; do
  wt_name="$(basename "$ctx_dir")"
  repo_name="$(basename "$(dirname "$ctx_dir")")"
  handoff_file="$ctx_dir/handoff.md"
  meta_file="$ctx_dir/session-meta.json"

  payload+="### Worktree: \`$repo_name/$wt_name\`"$'\n\n'
  payload+="**Context directory:** \`$ctx_dir\`"$'\n\n'

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
    payload+="_No \`handoff.md\` exists for this worktree yet. Create one at \`$handoff_file\` if you continue work here. Use the template at \`~/.claude/skills/worktree-handoff/assets/handoff-template.md\`._"$'\n\n'
  fi

  # Mark delivered so we don't re-inject next turn.
  touch "$(session_delivered_sentinel "$ctx_dir" "$session_id")"
done

jq -n \
  --arg ctx "$payload" \
  '{hookSpecificOutput:{hookEventName:"UserPromptSubmit", additionalContext:$ctx}}'

exit 0
