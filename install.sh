#!/usr/bin/env bash
# One-command installer for the worktree-context skill.
#
# Copies the skill into ~/.claude/skills/worktree-context/ (creating a
# timestamped backup outside the skills dir if one already exists), then
# registers the hook entries in ~/.claude/settings.json via the skill's
# own installer.
#
# Idempotent: safe to run multiple times.
#
# Usage:
#   bash install.sh

set -euo pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$PKG_DIR/worktree-context"
DEST="$HOME/.claude/skills/worktree-context"
BACKUP_ROOT="$HOME/.claude/skills-backups"

if [[ ! -d "$SRC" ]]; then
  echo "error: payload not found at $SRC" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required (brew install jq) — needed to safely merge ~/.claude/settings.json" >&2
  exit 1
fi

if ! command -v git >/dev/null 2>&1; then
  echo "warning: git not found on PATH — the hooks will no-op outside git repos, but you should install git" >&2
fi

mkdir -p "$HOME/.claude/skills"

if [[ -d "$DEST" ]]; then
  mkdir -p "$BACKUP_ROOT"
  backup="$BACKUP_ROOT/worktree-context.$(date -u +%Y%m%dT%H%M%SZ)"
  echo "Existing skill found — backing up to $backup"
  mv "$DEST" "$backup"
fi

cp -R "$SRC" "$DEST"
chmod +x "$DEST/scripts/"*.sh

echo "Skill files installed at $DEST"
echo

bash "$DEST/scripts/install-hooks.sh"

echo
echo "Done. Open a new Claude Code session inside a git repo to verify."
echo "First session in a worktree will create ~/worktrees/contexts/<repo>/<worktree>/"
echo "and start writing handoff.md as work progresses."
