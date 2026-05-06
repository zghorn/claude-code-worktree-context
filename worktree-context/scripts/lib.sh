#!/usr/bin/env bash
# Shared helpers for worktree-context hooks.
# Sourced by session-start.sh and session-end.sh.

set -euo pipefail

# Root where per-worktree context is persisted.
WORKTREE_CONTEXT_ROOT="${WORKTREE_CONTEXT_ROOT:-$HOME/worktrees/contexts}"

# Resolve the main worktree path for a given directory.
# Prints absolute path of the main worktree, or empty if not in a git repo.
resolve_main_worktree() {
  local dir="$1"
  git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null \
    | xargs -I{} dirname {} \
    | head -n1
}

# Resolve the current worktree path. In linked worktrees this differs from the
# main worktree; in the main repo it matches resolve_main_worktree.
resolve_current_worktree() {
  local dir="$1"
  git -C "$dir" rev-parse --path-format=absolute --show-toplevel 2>/dev/null | head -n1
}

# Compute the on-disk context directory for a given cwd.
# Prints the directory path, or empty if cwd is not inside a git repo.
resolve_context_dir() {
  local cwd="$1"
  local main_wt current_wt repo_name wt_name
  main_wt="$(resolve_main_worktree "$cwd" || true)"
  current_wt="$(resolve_current_worktree "$cwd" || true)"
  if [[ -z "$main_wt" || -z "$current_wt" ]]; then
    return 0
  fi
  repo_name="$(basename "$main_wt")"
  wt_name="$(basename "$current_wt")"
  printf '%s/%s/%s\n' "$WORKTREE_CONTEXT_ROOT" "$repo_name" "$wt_name"
}

# Current branch name (or empty for detached HEAD / non-repo).
current_branch() {
  local dir="$1"
  git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true
}

# ISO-8601 UTC timestamp.
now_iso() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Resolve context dir for an arbitrary path (file or dir, may not exist yet).
# Walks up the path until it finds an existing directory, then resolves via git.
# Prints the context dir, or empty if the path is not inside a git repo.
resolve_context_dir_for_path() {
  local path="$1"
  [[ -z "$path" ]] && return 0
  local dir="$path"
  while [[ -n "$dir" && "$dir" != "/" && ! -d "$dir" ]]; do
    dir="$(dirname "$dir")"
  done
  [[ -z "$dir" || ! -d "$dir" ]] && return 0
  resolve_context_dir "$dir"
}

# Per-session sentinel paths. We track two states per worktree-and-session:
#   .touched-<session_id>   — Claude has done at least one tool call here
#   .delivered-<session_id> — UserPromptSubmit hook has injected the handoff
session_touched_sentinel() {
  printf '%s/.touched-%s\n' "$1" "$2"
}
session_delivered_sentinel() {
  printf '%s/.delivered-%s\n' "$1" "$2"
}

# JSON-escape a string by piping it through jq. Used to build payloads
# without spawning python or hand-rolling escapes.
json_string() {
  jq -Rs . <<<"$1"
}
