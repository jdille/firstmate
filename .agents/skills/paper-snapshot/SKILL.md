---
name: paper-snapshot
description: Rebuild a project's Paper artboards in place from the worktree code, as native editable layers with real Stratus tokens, stamped with the commit they came from. Carried by the crewmate that bin/at-paper-snapshot.sh dispatches; never run against an artboard holding an un-pulled Jack edit.
---

# Paper snapshot — rebuild artboards from code

You rebuild the artboards listed in this project's paper-map so they show what
the code renders at the current commit. Artboards are regenerable snapshots:
rebuilt in place, never appended, never screenshots. Code stays canon — Paper
mirrors it. Jack's hand edits are feedback for the code, never something you
overwrite.

The dispatch brief gives you: the atelier root, the project slug, the
paper-map JSON (fileId, pageId, artboards), the project worktree, and the
exact stamp line.

Hard rules, before anything else:

- **Never `create_artboard`.** The artboard set is fixed by the paper-map. A
  genuinely new screen goes through `bin/at-paper-map-add.mjs`, decided by the
  captain — not by this task.
- **Never rename an artboard.** Names are the map's join key.
- **Never destroy an un-pulled Jack edit.** The edit guard below decides,
  artboard by artboard. When in doubt, block the artboard and say so.

## Setup

1. `get_guide({topic:"paper-mcp-instructions"})`, then
   `open_file({fileId, pageId})` from the paper-map, then `get_basic_info`.
2. `get_font_family_info` before your first typographic styling.
3. `get_tokens` — build with the file's real Stratus/Rain tokens. Never invent
   hex values a token already names, and never repoint tokens another page
   uses: changing their values silently restyles that page.

## Step 1 — edit guard FIRST, per artboard

Run this for every artboard in the map before touching any of them:

1. `get_jsx` on the artboard. Save it to a temp file.
2. Compare against the stored snapshot,
   `projects/<slug>/paper/snapshots/<artboard-slug>.jsx`:
   `node lib/jsx-diff.mjs <stored>.jsx <fresh>.jsx` (run from the atelier
   root). Exit 0 means identical — the artboard is clean, rebuild freely.
3. Exit 3 means the artboard differs from the last snapshot — Jack (or
   someone) edited it. Check whether that edit was already pulled: run
   `node lib/jsx-diff.mjs --hash <fresh>.jsx` and compare the hash against
   `incomingNormalizedSha256` for this artboard in the newest
   `projects/<slug>/paper/pulls/<timestamp>.json` record.
   - Hash matches the newest pull record: the edit is already in the feedback
     queue. Rebuilding is allowed — the code the worker round produced is the
     answer to that edit.
   - No match (or no pull record): the edit is **un-pulled**. Write your fresh
     dump to `projects/<slug>/paper/pulls/incoming/<artboard-slug>.jsx`, skip
     this artboard entirely — no `delete_nodes`, no `write_html` — and report
     it as `blocked: un-pulled edit, run at-paper-pull`.
4. No stored snapshot (first snapshot): an empty or placeholder artboard is
   yours to build. An artboard that already holds real content was built by a
   person — treat it exactly like an un-pulled edit: dump to `incoming/`,
   block, report.

## Step 2 — rebuild in place

Per artboard that passed the guard:

1. Read the worktree code for what the screen actually renders at HEAD —
   headline, row order, labels, tag strings, empty states. The route comes
   from the artboard's `stateId` in `capture-spec.json`. The code is the
   source of truth; never copy from a stale screenshot.
2. `delete_nodes` on the artboard's **children** (never the artboard itself).
3. Rebuild with `write_html`, one visual group per call: chrome first (topbar,
   then sidebar, then main), then content groups. Measured Rain chrome
   constants: sidebar 256, topbar 72, main padding 16, card width 1152 with
   24 padding, nav row 40, drawer 608.
4. Mechanics that cost time to rediscover:
   - Flex, padding, and gap only — no `margin`, no `grid`, no HTML tables.
   - Fixed-width slots (`width` + `flexShrink: 0`) for icons and trailing
     actions in repeated rows, or columns drift between rows.
   - `<x-paper-clone>` collapses inside a narrower parent: give it `width`,
     `minWidth`, and `flexShrink: 0`.
   - Local images need an explicit `height` or they render at 0. Paper evicts
     image fills past a ceiling and the source path is lost — anything that
     must survive is layers, never an image.
   - Screenshots render only the active page; `open_file` to the right page
     before `get_screenshot`.
5. Name layers so the tree reads: `Row — Status`, `Refund credit block`.
6. Rain copy rules bind: no em dashes, no emojis, nothing that reveals
   internal Rain state.

## Step 3 — stamp

Put the brief's exact stamp line — `<branch> @ <shortsha> · <date>` — on the
artboard. Try the artboard description first if it is writable; otherwise add
one small muted text layer named `Stamp` at the top of the artboard. One line,
nothing else. This is how anyone can tell what code the artboard mirrors.

## Step 4 — persist

Per rebuilt artboard, from the atelier root:

1. `get_jsx` the finished artboard →
   `projects/<slug>/paper/snapshots/<artboard-slug>.jsx`.
2. `export` the artboard as PNG →
   `projects/<slug>/paper/snapshots/<artboard-slug>.png`.
3. Update the artboard's entry in `projects/<slug>/paper/paper-map.json`:
   `lastSnapshot: { "commit": "<worktree HEAD sha>", "at": "<ISO time>",
   "jsxFile": "snapshots/<artboard-slug>.jsx" }`.
4. After the last artboard: set `paper.snapshot_commit` in
   `projects/<slug>/identity.json` to the same sha, and
   `finish_working_on_nodes`.

Never write `paper/pulls/*.json` records — only `at-paper-pull` writes those.
The only pull file you may create is an `incoming/` dump from the edit guard.

## Finishing

- Run `bin/at-lint.sh`; fix what it lists.
- Commit the atelier repo: the snapshot JSX + PNG files, the paper-map, and
  identity.json.
- Report per artboard: `rebuilt @ <shortsha>` or
  `blocked: un-pulled edit, run at-paper-pull`. A blocked artboard is a
  normal outcome, not a failure — but it must be reported loudly, never
  papered over by rebuilding anyway.
