# Persistent per-worktree context for Claude Code

A new session in a worktree starts with the previous session's context already loaded.

## What it does

- On session start, loads the worktree's `handoff.md` into Claude's initial context.
- On mid-session activity in a different worktree, injects that worktree's `handoff.md` so context follows directory changes.
- Before `/compact`, prompts Claude to flush an updated `handoff.md` for each worktree touched this session.

Each worktree has its own context directory; they are never merged.

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

Five shell scripts wire into Claude Code's hook system:

| Hook | Trigger | Action |
|---|---|---|
| `SessionStart` | New session opened in a worktree | Loads that worktree's `handoff.md` and `session-meta.json` into Claude's initial context. |
| `PostToolUse` | `Edit`, `Write`, `Read`, `Bash`, `Grep`, `Glob`, or `NotebookEdit` on a path in a worktree | Appends a row to `activity.jsonl`. On first touch of a worktree this session, injects that worktree's handoff inline. |
| `UserPromptSubmit` | Each user turn | Fallback path: if `PostToolUse` didn't deliver, injects pending handoffs at the start of the next turn. |
| `PreCompact` | Just before `/compact` | Lists every worktree touched this session and prompts Claude to write or update each one's `handoff.md`. |
| `SessionEnd` | Session terminates | Writes `session-meta.json` (transcript path, branch, cwd, end timestamp) so the next session can locate the prior transcript. |

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
