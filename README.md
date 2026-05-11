# Persistent per-worktree context for Claude Code

Claude resumes the previous session's context every time it works in a worktree.

## What it does

- Each worktree has its own context directory: `handoff.md` plus session metadata, activity logs, and per-session sentinels.
- Claude reads the worktree's handoff at session start, and again whenever mid-session activity touches a new worktree.
- Claude writes the worktree's handoff at natural stopping points and immediately before `/compact`.

## Install

```bash
git clone https://github.com/zghorn/worktree-handoff.git
cd worktree-handoff
bash install.sh
```

Or install from a tarball if you don't want a git clone:

```bash
curl -L https://github.com/zghorn/worktree-handoff/archive/refs/heads/main.tar.gz | tar xz
cd worktree-handoff-main
bash install.sh
```

Requires `jq` (`brew install jq`) and Claude Code.

Verify the hooks are registered:

```bash
jq '.hooks | keys' ~/.claude/settings.json
# Should list SessionStart, SessionEnd, PostToolUse, UserPromptSubmit, PreCompact
```

Update later by pulling and re-running `bash install.sh`. The installer is idempotent and writes timestamped backups of `~/.claude/settings.json` and the prior skill payload before making changes.

To remove:

```bash
rm -rf ~/.claude/skills/worktree-handoff
cp ~/.claude/settings.json ~/.claude/settings.json.bak.$(date -u +%Y%m%dT%H%M%SZ)
jq '.hooks |= with_entries(
      .value |= map(select(.hooks // [] | all(.command | test("worktree-handoff/scripts/") | not)))
    )' ~/.claude/settings.json > /tmp/s.json && mv /tmp/s.json ~/.claude/settings.json
rm -rf ~/worktrees/contexts   # optional: also wipe accumulated handoffs
```

## How it works

Five hooks run across the Claude Code lifecycle:

- **Load** (`SessionStart`, `PostToolUse`, `UserPromptSubmit`) — pull the worktree's handoff into Claude's context, at session start and when mid-session activity touches a new worktree.
- **Log** (`PostToolUse`) — append every relevant tool call to `activity.jsonl`.
- **Save** (`PreCompact`, `SessionEnd`) — prompt Claude to write the handoff before context is lost, and record a transcript pointer for the next session.

Handoffs live at `~/worktrees/contexts/<repo>/<worktree>/handoff.md`. Override the root with `WORKTREE_HANDOFF_ROOT` if your worktrees are stored elsewhere.

## What's in a worktree's context directory

```
~/worktrees/contexts/<repo>/<worktree>/
├── handoff.md              # Written by Claude, read by the next session. The primary artifact.
├── session-meta.json       # Last session's transcript path, branch, cwd, end timestamp.
├── session-history.jsonl   # Append-only log: one record per ended session.
├── activity.jsonl          # Append-only log: one row per tool call that touched this worktree.
├── .touched-<session_id>   # Sentinel: this session has done at least one tool call here.
└── .delivered-<session_id> # Sentinel: this session's handoff has been auto-injected.
```

`.touched-*` and `.delivered-*` are per-session sentinels cleaned up by `SessionEnd`. Everything else accumulates.
