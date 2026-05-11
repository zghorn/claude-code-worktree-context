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

### The hook system

Claude Code lets you register shell commands against lifecycle events: `SessionStart`, `PostToolUse`, `UserPromptSubmit`, `PreCompact`, and `SessionEnd`. When an event fires, Claude Code spawns the command synchronously, pipes a JSON payload (`session_id`, `cwd`, `tool_name`, …) to its stdin, and reads its stdout. If the stdout is JSON containing `hookSpecificOutput.additionalContext`, that string is injected into Claude's context as a `<system-reminder>` — visible to Claude without any tool call.

### What this project registers

Five hooks that use both channels (disk side-effect, and `additionalContext` injection):

- **`SessionStart`** — reads the worktree's `handoff.md` and injects it so Claude opens with the prior session's notes already in context.
- **`PostToolUse`** — appends every relevant tool call to `activity.jsonl`, and injects the handoff inline the first time Claude touches a worktree this session.
- **`UserPromptSubmit`** — fallback injector for any worktree whose handoff hasn't been delivered yet.
- **`PreCompact`** — injects a sentinel prompting Claude to flush fresh handoffs before context is wiped.
- **`SessionEnd`** — writes a `session-meta.json` pointer so the next session can locate the prior transcript.

Each injected payload starts with a marker like `<<<WORKTREE_HANDOFF_LOADED>>>`. The installed SKILL.md teaches Claude how to react when it sees one. The marker is the wire format; the skill is the handler.

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
