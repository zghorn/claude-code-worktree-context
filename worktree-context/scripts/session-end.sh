#!/usr/bin/env bash
# SessionEnd hook: record session metadata for the current worktree so that a
# future session (in this same worktree) can resume with context.
#
# Reads hook event JSON from stdin; writes nothing back to Claude.
# Intentionally non-fatal: any error silently exits 0 so a broken hook never
# blocks session termination.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

# Read the hook input. jq is optional — fall back to naive parsing if absent.
input="$(cat || true)"
if [[ -z "$input" ]]; then
  exit 0
fi

get() {
  local key="$1"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$input" | jq -r --arg k "$key" '.[$k] // empty' 2>/dev/null
  else
    # Minimal fallback: grep the value out of the JSON blob.
    printf '%s' "$input" \
      | tr ',' '\n' \
      | grep -E "\"$key\"[[:space:]]*:" \
      | head -n1 \
      | sed -E 's/.*:[[:space:]]*"?([^"]*)"?[[:space:]]*\}?[[:space:]]*$/\1/'
  fi
}

session_id="$(get session_id)"
cwd="$(get cwd)"
transcript_path="$(get transcript_path)"
reason="$(get reason)"

# cwd may be missing in some invocations — fall back to the shell's cwd.
cwd="${cwd:-$PWD}"

context_dir="$(resolve_context_dir "$cwd" || true)"
if [[ -z "$context_dir" ]]; then
  exit 0
fi

mkdir -p "$context_dir"

branch="$(current_branch "$cwd")"
ended_at="$(now_iso)"

# Write the latest session pointer.
meta_file="$context_dir/session-meta.json"
if command -v jq >/dev/null 2>&1; then
  jq -n \
    --arg session_id "$session_id" \
    --arg transcript_path "$transcript_path" \
    --arg ended_at "$ended_at" \
    --arg reason "$reason" \
    --arg branch "$branch" \
    --arg cwd "$cwd" \
    '{session_id:$session_id, transcript_path:$transcript_path, ended_at:$ended_at, reason:$reason, branch:$branch, cwd:$cwd}' \
    > "$meta_file"
else
  cat > "$meta_file" <<EOF
{
  "session_id": "$session_id",
  "transcript_path": "$transcript_path",
  "ended_at": "$ended_at",
  "reason": "$reason",
  "branch": "$branch",
  "cwd": "$cwd"
}
EOF
fi

# Append to rolling history for debugging / audit.
history_file="$context_dir/session-history.jsonl"
printf '%s\n' "$(cat "$meta_file")" >> "$history_file"

# Clean up per-session sentinel files written by PostToolUse and
# UserPromptSubmit hooks for this session, across every worktree this
# session touched. Leftover sentinels are harmless (the session_id will
# never match again), but cleanup keeps the context dirs tidy.
ctx_root="${WORKTREE_CONTEXT_ROOT:-$HOME/worktrees/contexts}"
if [[ -n "$session_id" && -d "$ctx_root" ]]; then
  find "$ctx_root" -maxdepth 4 -type f \
    \( -name ".touched-$session_id" -o -name ".delivered-$session_id" \) \
    -delete 2>/dev/null || true
fi

exit 0
