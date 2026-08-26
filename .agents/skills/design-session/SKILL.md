---
name: design-session
description: Exit contract for an interactive design session opened by atelier's at-attach.sh in a project worktree - work the session however Jack steers it, capture his decisions and dictated notes as you go, and end ONLY through bin/at-session-close.sh so the round, the decisions, and the notes land in the atelier repo. Use when a session was opened with an atelier context pack as its first prompt, when Jack says "close the session", "wrap up", or "we're done here" in such a session, or whenever Jack voices a decision or dictates a note he wants kept.
user-invocable: true
metadata:
  internal: true
---

# design-session

You are in an interactive design session with Jack, opened by `at-attach.sh` in one project's worktree.
The opening prompt is that project's context pack: its settled decisions, its queued feedback threads, its recent rounds, and its identity (worktree, branch, sandbox, comment keys, Paper file).
The standing bounds at the end of the pack bind here exactly as they bind a background fix round, except that Jack is present and his explicit word in this session overrides them case by case.

## The one rule that matters

Nothing Jack says may live only in this chat.
His notes have been lost twice to exactly that failure, and this skill exists to make it structurally impossible.
The session ends through `bin/at-session-close.sh`, never by just stopping.

## During the session

- Work in this worktree only; the pack names it.
- Keep a running private list as you go, so the close is a paste and not an act of recall:
  - **Decisions**: anything Jack settles that a future round must not re-litigate ("the pill replaces the tour on mobile", "never name the review state").
    A preference he merely leans toward is not a decision; ask "is that settled?" when it matters.
  - **Notes**: anything he dictates for the record. Capture his words verbatim, not your paraphrase.
  - **What happened**: the summary the round ledger will carry.
- The decisions ledger in the pack is binding; if Jack contradicts a D-number, say so plainly - he may be superseding it, and the close records that as a new decision, never as an edit to the old block.
- Sync the sandbox after code changes (`./sandbox sync` for frontend, `./sandbox reboot` for backend or dependencies) and confirm pages serve, so Jack reviews live state, not stale state.
- Never push, open a PR, resolve a comment thread, or message anyone without Jack's explicit word in this session.
- Atelier write rules hold: ledgers append-only, `feedback/` mirrors read-only, `jack-notes.md` receives only Jack's verbatim words through the close script.

## Ending the session

Before the session ends - Jack says to wrap up, or you see it winding down - run:

```
/Users/jackdille/Desktop/code/atelier/bin/at-session-close.sh <slug> \
  --round-summary "<what happened, plainly>" \
  --decision "<one settled decision>" \
  --decision "<another>" \
  --note "<Jack's words, verbatim>"
```

For long text, write a markdown file with `## round-summary` / `## decision` / `## note` section headers and pass `--from-file <path>` instead.
The script appends the R-block to `rounds.md`, one D-block per decision to `decisions.md`, each note verbatim to `jack-notes.md`, and commits the atelier repo with `session close: <slug>`.
That commit is sanctioned: the atelier repo is writable harness state, and this script is its one git-commit path.

Confirm the script printed what it wrote and that the commit landed before you say the session is closed.
If it errored, fix the input and rerun; do not end the session with the records unwritten.
At least one `--round-summary` is required - a session in which "nothing happened" still gets a one-line round block saying so, because the ledger is how the next session knows this one existed.
