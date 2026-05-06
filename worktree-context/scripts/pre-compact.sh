#!/usr/bin/env bash
# PreCompact hook: before context compaction wipes Claude's working memory,
# inject a reminder listing every worktree this session has touched, and
# tell Claude to write/refresh handoff.md for each before compaction
# proceeds. This is the highest-leverage moment to prompt a flush — the
# alternative is losing the session's accumulated context entirely.
#
# Reads hook event JSON from stdin. Emits JSON with hookSpecificOutput.
# Always exits 0; failures are silent.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

input="$(cat || true)"
[[ -z "$input" ]] && exit 0

command -v jq >/dev/null 2>&1 || exit 0

session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)"
[[ -z "$session_id" ]] && exit 0

ctx_root="${WORKTREE_CONTEXT_ROOT:-$HOME/worktrees/contexts}"
[[ ! -d "$ctx_root" ]] && exit 0

active=()
while IFS= read -r -d '' sentinel; do
  ctx_dir="$(dirname "$sentinel")"
  active+=("$ctx_dir")
done < <(find "$ctx_root" -maxdepth 4 -type f -name ".touched-$session_id" -print0 2>/dev/null)

[[ ${#active[@]} -eq 0 ]] && exit 0

payload=""
payload+="<<<WORKTREE_CONTEXT_PRECOMPACT>>>"$'\n\n'
payload+="**Compaction is about to wipe your working memory.** Before it runs, update \`handoff.md\` in each of these worktrees so the next session can resume:"$'\n\n'

for ctx_dir in "${active[@]}"; do
  wt_name="$(basename "$ctx_dir")"
  repo_name="$(basename "$(dirname "$ctx_dir")")"
  handoff_file="$ctx_dir/handoff.md"
  status="exists"
  [[ ! -f "$handoff_file" ]] && status="missing — create it"
  payload+="- \`$handoff_file\` _(worktree: $repo_name/$wt_name; $status)_"$'\n'
done
payload+=$'\n'
payload+="Read each existing \`handoff.md\` first and merge forward — don't overwrite with less detail. Use the template at \`~/.claude/skills/worktree-context/assets/handoff-template.md\` for any new file. Optimize each handoff for the *next* Claude session that opens that worktree, not for a human reader."$'\n'

jq -n \
  --arg ctx "$payload" \
  '{hookSpecificOutput:{hookEventName:"PreCompact", additionalContext:$ctx}}'

exit 0
