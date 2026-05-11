---
name: worktree-handoff
description: Persist and resume Claude context per git worktree, automatically — across context switches within a single session. Use whenever you see any of `<<<WORKTREE_HANDOFF_LOADED>>>` (SessionStart loaded a prior handoff), `<<<WORKTREE_HANDOFF_AUTOLOAD>>>` (your tool calls just touched a worktree mid-session — its handoff has been auto-injected), or `<<<WORKTREE_HANDOFF_PRECOMPACT>>>` (compaction is imminent — flush every active worktree's handoff before context wipes). Also use whenever the user is actively working in a git worktree and you should be maintaining the on-disk handoff — update it at natural stopping points, after a PR is opened, or whenever the user signals they're wrapping up. Use even if the user hasn't mentioned "handoff" or "context" explicitly — this is a background responsibility for the whole session whenever a worktree context directory exists at `~/worktrees/contexts/<repo>/<worktree>/`. Multiple worktrees may be active in a single session; maintain a separate `handoff.md` per worktree.
---

# Worktree Handoff

This skill gives Claude a persistent per-worktree notebook so a new session in the same worktree can pick up where the last one left off — even when the transcript itself has been compacted away. The context system also tracks worktree activity *within* a session, so a single Claude session that spans multiple worktrees keeps each one's handoff fresh independently.

Five hooks work together so you don't have to think about which directory you're in:

- **SessionStart** — on a new session inside a worktree, loads that worktree's existing handoff into your opening context. Marker: `<<<WORKTREE_HANDOFF_LOADED>>>`.
- **PostToolUse** — silent. Whenever you Edit/Write/Read/Bash/Grep/Glob a path inside a git worktree, appends a line to that worktree's `activity.jsonl` and marks a per-session sentinel.
- **UserPromptSubmit** — when you've just touched a worktree whose handoff isn't already loaded, injects that worktree's handoff at the start of the next user turn. Marker: `<<<WORKTREE_HANDOFF_AUTOLOAD>>>`.
- **PreCompact** — fires before context compaction. Lists every worktree this session has touched and tells you to flush their handoffs *before* compaction wipes your memory. Marker: `<<<WORKTREE_HANDOFF_PRECOMPACT>>>`.
- **SessionEnd** — writes `session-meta.json` so the next session can find this session's transcript, and cleans up per-session sentinels.

Your job when this skill applies is two-sided:

1. **On arrival** (any of the three markers above): brief the user when appropriate, and treat the loaded handoff(s) as your working notes for the corresponding worktree.
2. **In flight**: keep `handoff.md` reasonably fresh in every worktree you're active in, especially right before `/compact` and at natural stopping points.

Both sides are equally important. A skill that reads context but never writes it decays to nothing within a session.

## When this skill applies

**On `<<<WORKTREE_HANDOFF_LOADED>>>` (SessionStart)** — A prior session worked in the worktree you're starting in. Do the "arrival" behavior below.

**On `<<<WORKTREE_HANDOFF_AUTOLOAD>>>` (mid-session, after touching a new worktree)** — Treat the handoff(s) in the payload as loaded context for the named worktree(s). Do *not* break flow to brief the user unless they ask — the user's expectation is silent context retention. Just incorporate the handoff into your understanding and update it as you continue working there.

**On `<<<WORKTREE_HANDOFF_PRECOMPACT>>>` (just before `/compact`)** — Stop and flush. Read each existing `handoff.md` listed, merge in everything new since it was last written, and save before compaction proceeds. This is the single highest-leverage update of the session.

**During any session in a worktree** — If the current working directory is inside a git worktree, there is a context directory for it at `~/worktrees/contexts/<main-repo-name>/<worktree-name>/`. Maintain `handoff.md` in that directory throughout the session. You do not need the hook to have loaded anything to start writing — the first session in a new worktree should create and populate the file.

If you're not sure whether you're in a worktree, run:

```bash
git rev-parse --show-toplevel
```

If that succeeds, you're in a git repo (worktree or main). Compute the context dir with:

```bash
MAIN_WT="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"
CURRENT_WT="$(git rev-parse --path-format=absolute --show-toplevel)"
CTX_DIR="$HOME/worktrees/contexts/$(basename "$MAIN_WT")/$(basename "$CURRENT_WT")"
```

## Cross-worktree sessions

A single Claude session may touch several worktrees — for example, you start in the main repo, `cd` into worktree A to investigate, then run a command that edits worktree B. The hooks make this transparent:

- Each worktree gets its own context dir, its own `handoff.md`, and its own `activity.jsonl`. They are never merged.
- The first time your tool calls touch a worktree this session, the next user turn will receive a `<<<WORKTREE_HANDOFF_AUTOLOAD>>>` block with that worktree's handoff. After that, no further auto-injection happens for that worktree this session.
- When updating handoffs, scope each one to *that worktree's* work. Don't dump global session context into one worktree's handoff just because that's where you happened to look first.
- The user does **not** need to tell you which directory or branch you're in. The hooks track it. Your job is to keep each handoff faithful to the work that happened in its worktree.

## Arrival behavior: "where we left off"

When you see `<<<WORKTREE_HANDOFF_LOADED>>>` in your initial context, your **first response to the user** must lead with a short "where we left off" briefing. Keep it to 3–6 sentences. Cover:

1. What was being worked on (one sentence of framing).
2. The most important open threads — the 1–3 things the user is likely to want to pick up next.
3. Any open PRs and JIRA tickets associated with the work (list them by number/key, with one-line status).
4. A single-sentence pointer to anything that was deliberately left undone ("I paused mid-refactor of X because…").

Then, only if the user's question requires it, dive deeper. Do not paste the whole handoff back. Do not narrate that you loaded context — just use it.

**Example of a good briefing:**

> Picking up where we left off: you were migrating the contractor worksheet to the new CurrencySwitcher column (PAYPROF-1534). Open threads — (1) Jest tests in `ContractorWorksheet.test.tsx` are failing on the currency formatter mock, (2) PR #14450 is up but waiting on review from @kbriggs. JIRA PAYPROF-1534 is in "In Review". Previous session paused before wiring up the empty-state because we weren't sure whether to reuse `PaymentMethodEmpty` — worth deciding first.

### When the handoff looks stale or thin

If the handoff has no timestamp, or is older than a few days, or feels generic, **say so briefly** and offer to re-derive state from the current branch instead (git log, open PRs, local diff). Don't pretend a stale handoff is authoritative.

### When deeper recall is needed

The hook includes a `transcript_path` pointing to the prior session's full conversation as a `.jsonl` file. Each line is a JSON record with the message content. When the user asks about something the handoff doesn't cover — "what did we decide about X?", "why did we rule out Y?" — read that file directly (or grep it) rather than guessing. Treat the transcript as authoritative over the handoff summary when they disagree.

Example:

```bash
jq -r 'select(.type=="text") | .text' <transcript_path> | grep -i "currency formatter" -A 3
```

## In-flight behavior: maintain `handoff.md`

Throughout the session, keep `$CTX_DIR/handoff.md` updated. Use the template in `assets/handoff-template.md`. Write it with the `Write` tool as a normal file.

### When to update

Update proactively — don't wait to be asked — when any of these happen:

- **Before `/compact`**: this is the most important trigger. Compaction will erase your working memory; the handoff is the only thing that survives for next time.
- **After completing a logical chunk**: a PR is opened, a subtask is finished, a decision is made, a bug is root-caused.
- **At natural conversational breakpoints**: the user says "let's pause", "good stopping point", "I need to step away", etc.
- **When the user pivots to a different thread of work**: capture where the first thread stood before moving on.
- **Every ~30 minutes of substantive work** if none of the above has triggered — lean toward too-frequent rather than too-rare, because partial is better than stale.

You don't need to announce every update. A single-line note like "Updating handoff" is enough when it's not part of a larger exchange.

### What to include

The handoff is *for the next Claude* — optimize for someone picking up cold, not for a human reader. Five sections, in this order:

1. **Where we left off** — 2–4 sentences of framing. What problem are we solving, what's the current state.
2. **Active work** — concrete threads in flight. Checkboxes are fine. Keep it specific (file paths, function names, test names).
3. **Open PRs and JIRA** — snapshot at write time. Use `gh pr list --head "$(git branch --show-current)"` for PRs; parse the branch name or recent commits for JIRA keys (e.g., `PAYPROF-1534`). Record status (draft/open/in review/merged).
4. **Key files** — the 5–15 files most relevant to the current thread, each with a one-line note on *why* it matters. Not a file tree — a curated map.
5. **Next steps / open questions** — what the next session should pick up, and anything undecided.

Optionally, a **Notes** section for gotchas, decisions, and dead-ends (so the next session doesn't re-walk them).

See `assets/handoff-template.md` for the exact structure.

### Snapshotting PRs and JIRA

Snapshot these *at write time* — don't try to be clever about freshness. The next session's hook will re-read this file, so stale-but-dated is fine.

```bash
# Open PRs from the current branch:
gh pr list --head "$(git branch --show-current)" --json number,title,state,url,isDraft 2>/dev/null

# JIRA keys from the current branch and recent commits:
git log -20 --format='%s' | grep -oE '[A-Z]+-[0-9]+' | sort -u
git branch --show-current | grep -oE '[A-Z]+-[0-9]+' | head -1
```

If JIRA keys are found, include them; don't fetch from JIRA unless the user specifically asks — the keys alone are enough for the next session to look up.

## What NOT to do

- **Don't overwrite with less info.** When updating, read the existing file first and merge forward. It's fine (and often correct) for the handoff to grow over a long session.
- **Don't treat the handoff as a user-facing document.** It's a note-to-self for the next Claude. Terse is good. Jargon is fine.
- **Don't try to "auto-resume" by replaying the prior transcript.** The transcript file is there for targeted lookups, not for re-loading. Trust the handoff for the briefing.
- **Don't write the handoff on session start unless you'd have something genuinely new to add.** The hook already loaded the existing file; re-writing it with less detail is worse than leaving it alone.
- **Don't skip the briefing just because the work in this session turned out to be unrelated.** Acknowledge what you loaded and pivot — "I see we were in the middle of X; it sounds like you want to work on Y now — let me know if you want me to update the handoff for X before we switch."

## Files this skill owns

```
~/worktrees/contexts/<repo>/<worktree>/
├── handoff.md              # You (Claude) write this. The next session reads it.
├── session-meta.json       # SessionEnd hook writes. Points to the prior transcript.
├── session-history.jsonl   # SessionEnd hook appends. Audit log of every ended session.
├── activity.jsonl          # PostToolUse hook appends. One line per tool call that touched this worktree.
├── .touched-<session_id>   # PostToolUse hook touches on first activity per session.
└── .delivered-<session_id> # UserPromptSubmit hook touches after auto-injecting the handoff.
```

You (Claude) own `handoff.md`. The hooks own everything else. The `.touched-*` and `.delivered-*` sentinels are cleaned up by SessionEnd; if cleanup is missed, leftover sentinels are harmless because their session_id will never match again.

You can ignore `activity.jsonl` most of the time — it's a breadcrumb trail for forensic use, not a substitute for `handoff.md`. But if `handoff.md` looks thin and the user asks "what did I do here recently?", the activity log is the source of truth.
