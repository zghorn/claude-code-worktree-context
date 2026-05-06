# Never lose context between Claude sessions

Install this once and Claude will remember what it was doing in every git
worktree on your machine — across restarts, across compactions, across
weeks. No more copy-pasting session IDs to resume work. No more
re-explaining where you left off. No more thinking about which directory
or branch you're in.

## What changes for you

- **Restart Claude → Claude picks up where it left off.** Open a new
  session inside a worktree, and you'll get a "where we left off"
  briefing in the first reply. Pull requests, JIRA tickets, half-finished
  threads, decisions you made — all loaded automatically.
- **No more session-ID bookkeeping.** Claude tracks context per worktree,
  not per session. You don't have to remember or save anything to come
  back to a piece of work later.
- **Switch worktrees mid-conversation, transparently.** If Claude touches
  a different worktree to investigate something, it'll silently load
  *that* worktree's history right then — same turn, before responding.
  Each worktree keeps its own notes; they never get jumbled.
- **`/compact` won't lose your progress.** Right before context gets
  wiped, Claude is prompted to save its working notes to disk. The next
  session reads them back in.
- **Works for the whole team.** Send a teammate this repo; one command
  installs it on their laptop. Pairing on the same branch? Sync the
  matching `~/worktrees/contexts/<repo>/<worktree>/` directory between
  your machines (Dropbox, iCloud Drive, syncthing — anything that mirrors
  files) and you'll share the same handoff. Claude on one laptop picks
  up where Claude on the other left off.

## Install

```bash
git clone https://github.com/zghorn/claude-code-worktree-context.git
cd claude-code-worktree-context
bash install.sh
```

Requires `jq` (`brew install jq`) and Claude Code.

To check it's wired up:

```bash
jq '.hooks | keys' ~/.claude/settings.json
# Should list SessionStart, SessionEnd, PostToolUse, UserPromptSubmit, PreCompact
```

To update later:

```bash
cd claude-code-worktree-context
git pull
bash install.sh
```

The installer is idempotent and writes a timestamped backup of
`~/.claude/settings.json` and any pre-existing skill at the same path
before making changes.

To remove:

```bash
rm -rf ~/.claude/skills/worktree-context
cp ~/.claude/settings.json ~/.claude/settings.json.bak.$(date -u +%Y%m%dT%H%M%SZ)
jq '.hooks |= with_entries(
      .value |= map(select(.hooks // [] | all(.command | test("worktree-context/scripts/") | not)))
    )' ~/.claude/settings.json > /tmp/s.json && mv /tmp/s.json ~/.claude/settings.json
rm -rf ~/worktrees/contexts   # optional: wipe accumulated per-worktree notes
```

## How it works (for the curious)

Five small shell scripts run at key moments in Claude's lifecycle:

| When | What it does |
|---|---|
| Session starts in a worktree | Loads that worktree's existing notes into Claude's opening context |
| Claude touches a file or runs a command in a worktree | Logs the activity, and on first touch this session, injects that worktree's notes inline (same turn, before Claude responds) |
| Each new user turn | Fallback: if a same-turn injection didn't go through, the next user turn auto-loads any pending worktree notes |
| Right before `/compact` | Reminds Claude to flush its notes to disk before memory wipes |
| Session ends | Saves a pointer to the transcript and cleans up |

Notes live at `~/worktrees/contexts/<repo>/<worktree>/handoff.md` — one
file per worktree, written by Claude, read by the next Claude. Override
the location with `WORKTREE_CONTEXT_ROOT` if you keep your worktrees
somewhere else.

### Why shell scripts and not "just ask Claude to remember"?

Some moments happen when Claude can't run — before the first turn, or
during memory compaction. Some need to fire on every tool call, where an
LLM round-trip would be too slow and expensive. And persistence to disk
needs *something* running outside the model loop. The shell scripts are
the host's hands; the skill prose is Claude's brain. They collaborate.

## What's in the repo

```
claude-code-worktree-context/
├── README.md            ← this file
├── install.sh           ← one-command installer
└── worktree-context/    ← skill payload (copied to ~/.claude/skills/)
    ├── SKILL.md
    ├── assets/handoff-template.md
    ├── evals/evals.json
    └── scripts/         ← the five hook scripts + lib + installer
```
