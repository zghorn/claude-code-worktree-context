#!/usr/bin/env bash
# SessionStart hook: if this worktree has a prior saved session, inject a
# context block so Claude can brief the user on "where we left off".
#
# Reads hook event JSON from stdin. On match, prints a JSON response that adds
# `additionalContext` to Claude's initial context.
#
# Intentionally non-fatal: any error exits 0 with no output, which lets Claude
# start normally without a loaded context.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

input="$(cat || true)"
if [[ -z "$input" ]]; then
  exit 0
fi

get() {
  local key="$1"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$input" | jq -r --arg k "$key" '.[$k] // empty' 2>/dev/null
  else
    printf '%s' "$input" \
      | tr ',' '\n' \
      | grep -E "\"$key\"[[:space:]]*:" \
      | head -n1 \
      | sed -E 's/.*:[[:space:]]*"?([^"]*)"?[[:space:]]*\}?[[:space:]]*$/\1/'
  fi
}

cwd="$(get cwd)"
source_kind="$(get source)"
cwd="${cwd:-$PWD}"

# `clear` means the user explicitly wiped context — respect that and don't
# re-inject. For startup, resume, and compact we want context back.
case "$source_kind" in
  clear) exit 0 ;;
esac

context_dir="$(resolve_context_dir "$cwd" || true)"
if [[ -z "$context_dir" || ! -d "$context_dir" ]]; then
  exit 0
fi

handoff_file="$context_dir/handoff.md"
meta_file="$context_dir/session-meta.json"

if [[ ! -f "$handoff_file" && ! -f "$meta_file" ]]; then
  exit 0
fi

# Build the additionalContext payload. Use a clear marker so the skill can
# recognize it and trigger the "where we left off" behavior.
payload=""
payload+="<<<WORKTREE_CONTEXT_LOADED>>>"$'\n\n'
payload+="A prior Claude session worked in this git worktree. Use the information below to brief the user on where you left off, then proceed."$'\n\n'
payload+="**Context directory:** \`$context_dir\`"$'\n\n'

if [[ -f "$meta_file" ]]; then
  payload+="## Prior session metadata"$'\n\n'
  payload+='```json'$'\n'
  payload+="$(cat "$meta_file")"$'\n'
  payload+='```'$'\n\n'
  payload+="To recall deeper context than the handoff provides, you can read the prior transcript file (\`transcript_path\` above) — it is a JSONL file with full conversation history. Grep it for specific topics when needed."$'\n\n'
fi

if [[ -f "$handoff_file" ]]; then
  payload+="## Handoff from prior session"$'\n\n'
  payload+="$(cat "$handoff_file")"$'\n'
fi

# Build a user-visible confirmation. This surfaces in the Claude Code UI so the
# user knows the handoff loaded without waiting for Claude's first reply.
wt_name="$(basename "$(resolve_current_worktree "$cwd" || true)")"
last_updated=""
if [[ -f "$handoff_file" ]]; then
  last_updated="$(grep -m1 -E '^\*\*Last updated:\*\*' "$handoff_file" 2>/dev/null \
    | sed -E 's/^\*\*Last updated:\*\*[[:space:]]*//; s/[[:space:]]*$//' || true)"
fi

system_message="📂 Loaded worktree handoff"
if [[ -n "$wt_name" ]]; then
  system_message+=": $wt_name"
fi
if [[ -n "$last_updated" ]]; then
  system_message+=" (last updated $last_updated)"
fi

# Emit the JSON response. Use jq if available for robust escaping; otherwise
# rely on Python (present on macOS by default) for JSON encoding.
if command -v jq >/dev/null 2>&1; then
  jq -n \
    --arg ctx "$payload" \
    --arg msg "$system_message" \
    '{systemMessage:$msg, hookSpecificOutput:{hookEventName:"SessionStart", additionalContext:$ctx}}'
else
  WORKTREE_CTX_PAYLOAD="$payload" \
  WORKTREE_CTX_SYSMSG="$system_message" \
  python3 -c '
import json, os
print(json.dumps({
  "systemMessage": os.environ["WORKTREE_CTX_SYSMSG"],
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": os.environ["WORKTREE_CTX_PAYLOAD"],
  },
}))
'
fi

exit 0
