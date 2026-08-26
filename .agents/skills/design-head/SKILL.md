---
name: design-head
description: How the rain-design firstmate (the design head) drives Jack's design projects through the atelier at-* scripts - handling design-feedback check wakes, dispatching bounded comment-scoped fix rounds, recording Jack's decision answers in two durable places, and opening interactive escape-hatch sessions. Use on a "check: design-feedback" wake, when Jack says "go get them", "run the rounds", or "dispatch <project>", when he answers an open needs-decision key on a design round, or when he asks to work a design project interactively.
user-invocable: true
metadata:
  internal: true
---

# design-head

The atelier repo at `/Users/jackdille/code/atelier` is this home's durable design state and the `at-*` scripts in its `bin/` are the levers.
That repo is writable harness state, not a `projects/` clone, so hard rule 1 does not apply to it; its own AGENTS.md owns the write rules (append-only ledgers, single writer on `feedback/`, protected `jack-notes.md`).
Read each script's `--help` before first use; headers are the contract.

## The loop this serves

Jack rotates through review artifacts leaving rain comments, then says "go get them" - or the 10-minute collector cycle fires a wake.
Each project with queued threads gets one bounded, comment-scoped fix round, run in parallel with the others; isolation is the scheduler.
Workers reply in-thread per fix, resolve only what is live and screenshot-verified, and finish with mandatory closing writes to the atelier repo.

## Wake handling: `check: design-feedback`

The registered check prints one line naming projects with new threads, e.g. `design-feedback: customers 3 new threads, refunds 1 new thread`.

1. For each named project, read `projects/<slug>/feedback/queue.json` in the atelier repo - the collector's derived queue, with thread ids, anchors, and screenshots.
2. Skip a project that already has a live round (a `<slug>-r<N>` task still working); its next round picks the new threads up.
   Re-queued threads (the queue entry's `updatedAt` moved past the round that handled it) count as new.
3. Dispatch one round per remaining project (next section).
4. Never fix a thread yourself, never reply or resolve in a thread yourself, and never edit a mirror; judgment here is routing, not designing.

## Dispatching a round: "go get them"

"Go get them" bypasses the poll cadence - dispatch immediately for every project with queued threads.

```
/Users/jackdille/code/atelier/bin/at-dispatch.sh <slug> [--threads id1,id2,...]
```

It computes the next round number from `rounds.md`, scaffolds the brief with this home's `fm-brief.sh`, splices in the deterministic context pack (`at-pack.sh`: full decisions ledger, in-scope queue entries, last 3 rounds, identity, standing bounds), and spawns via `fm-spawn.sh` with the identity's delivery mode.
Run it once per project; parallel workers each get their own worktree.
Use `--threads` only when Jack scoped the round to specific threads; default is the whole queue.
Use `--dry-run` to inspect the brief and spawn command without dispatching.
After a round reports done, verify its closing writes actually landed - the R-block in `rounds.md` and the atelier commit - before recording the round complete; a round without them is not done.

## Everything else Jack asks for: at-task, never inline

Any substantive ask that is not a comment round - "build the empty state", "try two layouts", "figure out why the chart clips", a persona QA pass, a Paper snapshot - goes to a crewmate in its own tmux window and worktree:

```
/Users/jackdille/code/atelier/bin/at-task.sh <slug> --ship --ask "<the ask, in full>"
/Users/jackdille/code/atelier/bin/at-task.sh <slug> --scout --ask "<the question>"
```

`--ship` delivers changes under the identity's delivery mode; `--scout` delivers a report only (scratch worktree, no branch, no PR).
The ask text governs the worker; the context pack rides along as context.
You never edit project code, never build, and never investigate inside your own session - "it's a small fix" is what fix rounds and ship tasks are for.
Run several at-task workers in parallel when the work splits; each gets its own worktree, and only true semantic dependency serializes.

## Decision answers: one answer, two durable records

Workers never decide scope, taste, or product calls; those arrive as `needs-decision: [key=...]` status lines mirrored into `inbox/decisions.md`.
When Jack answers one:

1. Send the answer to the round's task with `bin/fm-send.sh <task-id> --resolve-key <key> "<answer>"`, so the decision record closes at answer time.
2. Append a settled D-block to `projects/<slug>/decisions.md` in the atelier repo: next D number, today's date, plain language, `(settled by Jack)`, source naming the key and thread.
3. Append a one-line settled marker to `inbox/decisions.md` referencing the new D-number - append, never edit the original inbox block.
4. Commit the atelier repo.

A decision that conflicts with an existing D-number supersedes it only if Jack says so; the new block then says "supersedes D<n>".

## Escape hatch: interactive sessions

When Jack wants to work a project live rather than through rounds:

```
/Users/jackdille/code/atelier/bin/at-attach.sh <slug>
```

It prints (and copies) the command that opens claude in the project worktree with the context pack as the opening prompt and the session-close contract on top.
Give Jack that command; do not run the session yourself.
The session exits through `at-session-close.sh` (the `design-session` skill owns that contract), which appends the round, any decisions, and Jack's verbatim notes, then commits atelier.
After such a session, treat its new D-blocks as binding in every later brief - `at-pack.sh` includes them automatically.

## Standing limits

- Never merge a PR, never `gh pr ready`; drafts are the ceiling and promotion is Jack's act.
- Never message a human autonomously; asks live as drafts in `projects/<slug>/asks/`.
- Share only wrapped `rain-comments.vercel.app/sandbox/...` links, never raw runtm preview URLs.
- Narrative for Jack is regenerated from facts and gated (ELI5); never relay worker text to him raw.
- Run `bin/at-lint.sh` in the atelier repo before committing harness-state changes of your own.
