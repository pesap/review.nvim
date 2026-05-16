# Refactor User Stories

## Purpose

This document rewrites the refactor plan as user stories for the interaction people should follow in `review.nvim`.

Target product shape: a human reviewer opens one review workspace, explores many agent/branch changes, adds actionable notes, gathers git context, and hands those notes back to LLM agents or publishes them to PR/MR threads. The default path should be review and handoff, not mutation.

> [!NOTE]
> These stories describe target behavior. The **Status** column on each story tracks what exists today.

## Product principles

- **One place for many changes:** multiple agents, branches, PRs/MRs, commits, GitButler virtual branches, and unassigned changes should be explorable together.
- **Diff stays primary:** context panes should explain the diff without hiding it.
- **Read-only by default:** reviewing and writing notes must be safer and more prominent than staging or committing.
- **Notes are the work product:** every interaction should make it easy to produce precise, actionable messages for humans, forges, or LLM agents.
- **Git context is one action away:** history, blame, file log, PR/MR discussion, and branch comparison should be available from the current line/file/unit.
- **State is durable:** notes, reviewed status, stale context, and handoff packets should survive refreshes and branch switches.
- **Performance is a priority:** all operations feel smooth and instant.
- **Visual precision:** the UI must be pixel-aligned with zero visual jank — uniform column widths, consistent padding, monospaced grid alignment, no orphaned gutters, no ragged right edges. Every row in the navigator, threads pane, and diff viewer snaps to the same baseline grid. Status icons, badges, and separators occupy fixed-width columns so nothing shifts when content changes.

## Core concepts

| Concept | Meaning |
| --- | --- |
| Review workspace | The top-level review session that can contain many review units. |
| Review unit | One branch, PR/MR, GitButler virtual branch, unassigned scope, commit range, or agent task. Each unit carries its own base ref and head ref. |
| File node | A changed file inside one or more review units. |
| Hunk | A changed region inside a file. |
| Note | A local review message attached to a file, line, hunk, file, unit, or discussion. |
| Thread | A remote PR/MR thread or local conversation around a note. |
| Handoff packet | Structured markdown copied/exported so an LLM agent can act on the notes. |
| Context popup | A floating window for file history or commit details — invoked from the diff, not a permanent pane. |
| Blame panel | A vertical split between the left rail and diff for line-by-line blame comparison. |

## Target layout

The review UI is a two-pane left rail plus a diff viewer. No embedded Fugitive or GitButler status panes — the app is read-only by design.

```
┌─────────────────────────┬──────────────────────────────────┐
│ ▸ feature-a (#42)  3/5  │                                  │
│   base: main  [change]  │                                  │
│   ├ abc1234 fix login   │                                  │
│   └ def5678 add cache   │        Diff viewer               │
│ ▸ feature-b        1/2  │                                  │
│ ─ Files [3/5 reviewed]  │   b = blame side panel           │
│ src/                    │   L = file history popup         │
│   ~ state.lua    (2) ✓  │   n = jump to threads            │
│   + context.lua         │                                  │
│ lua/review/             │                                  │
│   ~ ui.lua       (1)    │                                  │
│   - old_pane.lua     ✓  │                                  │
├─────────────────────────┤                                  │
│ Threads 5 open·2 res·1▆ │                                  │
│ [all] open  res  stale  │                                  │
│ ▾ github/           [3] │                                  │
│   state.lua         [2] │                                  │
│    ● ps “repo_root p…” 2h│                                  │
│    ● ps “note_index…”  1h│                                  │
│   ui.lua             [1]│                                  │
│ ▸ local/            [2] │                                  │
│ ▸ Stale             [1] │                                  │
└─────────────────────────┴──────────────────────────────────┘

Blame side panel (b from diff):
┌─────────────────────────┬────────────────┬─────────────────┐
│     Navigator            │ Blame (base)   │   Diff viewer    │
│     ...                  │ [base] head    │   ...           │
│                         │ e2f3a1b jdoe   │                 │
├─────────────────────────┤ a9c0d2e psanch │                 │
│     Threads              │ b7d8e9f agent  │                 │
│     ...                  │                │                 │
└─────────────────────────┴────────────────┴─────────────────┘
```

### Top pane — Navigator

A single scrollable pane containing review units, commits, and files as one continuous tree:

1. **Review units** are top-level rows showing label, source type, PR/MR id, note count, and reviewed/total progress. `T` cycles the active unit. Each unit carries its own base ref; a "change base" action lets the reviewer re-diff against any arbitrary ref.
2. **Commits** nest as expandable children under their unit. Selecting a commit — from any unit, not just the active one — filters the file list to that commit's changed files and updates the diff. Selecting the unit header returns to all files. Clicking a commit in a collapsed unit expands that unit, activates it, and filters to the commit's files in one action.
3. **Files** appear below a `Files [N/M reviewed]` separator. Files are grouped by directory (tree layout) or shown as a flat list. `t` toggles tree ↔ flat. Directory headers are non-selectable separator rows that aggregate note counts and reviewed state. Files show status icons (`~`/`+`/`-`/`→`/`?`), note count badges `(N)`, and optional devicons.

This is one buffer, one window, one cursor — units, commits, and files flow together. The split between "unit rail" and "file tree" is visual (separator rows and highlights), not structural.

Tree layout reference: [MaraniMatias/codereview.nvim](https://github.com/MaraniMatias/codereview.nvim) explorer model — directory-grouped tree with flat toggle, status icons, note count badges, and inline note expansion.

### Bottom pane — Threads

The threads pane is the reviewer's always-visible workspace for notes and discussions:

- **Header** shows total thread/note count and a status summary (e.g. `Threads  5 open · 2 resolved · 1 stale`).
- **Status filter:** a toggle bar below the header cycles through `all → open → resolved → stale` to filter visible threads.
- **Groups** organize threads by source: `github/`, `gitlab/`, `local/`, `Stale`. Each group header shows count and can be collapsed with `<CR>` or `za`.
- **File rows** under each group show the filename, thread count, and the **first line preview** of the latest note (dimmed, truncated). Clicking a file row jumps to that file in the diff.
- **Expanded thread rows** appear under their file when the file is selected/expanded in the threads pane. Each thread row shows: author avatar/initial, note preview, timestamp (relative: "2h ago"), reply count badge, and status indicator (● open / ✓ resolved / ◌ stale).
- **Keyboard:** `<CR>` on a thread row opens the full thread view (existing US-20). `n` from the diff or navigator jumps cursor to the threads pane.

The full notes list (`:ReviewNotes`) remains a floating window — it provides a different view: sorted, searchable, with stage/publish/clipboard actions. The threads pane is the always-visible summary; the notes list is the action-oriented detail view.

### Blame side panel

`b` from a diff line opens a **blame panel** between the left rail and the diff viewer (a vertical split, not a floating popup). This keeps blame visible alongside the diff for line-by-line comparison. Blame runs at the base ref by default (to understand what was there before the change); a toggle at the top switches to the head ref. `b` or `Esc` closes the panel. Context from blame can be attached to notes for inclusion in handoff packets.

### File history popup

`L` from a diff line opens a **file history floating popup** showing `git log --follow` unrestricted by the review unit's range. Selecting a history entry shows that commit's diff for the file. Context from file history can be attached to notes for inclusion in handoff packets.

### What this replaces

The current Fugitive status pane and GitButler status pane are removed. Fugitive remains available as a standalone plugin (`:Git`) but is not embedded in the review layout. GitButler workspace metadata (branch status, review IDs, upstream state) is shown per review unit in the navigator, not as a separate pane. This enforces read-only-by-default (US-29) without needing config gates, and drops `vim-fugitive` from a hard dependency to optional.

The current three-pane left rail (files + threads + git-status) becomes two panes (navigator + threads). The files pane and the unit/scope rows that are currently at the top of the files pane merge into the navigator. The git-status pane is removed entirely.

### Visual design constraints

The review UI renders inside a terminal with a monospaced font. Every element must respect the character grid:

1. **Fixed-width columns.** Status icons (`~`/`+`/`-`/`→`/`?`), expand indicators (`▸`/`▾`), tree glyphs (`├`/`└`), note badges `(N)`, review checkmarks `✓`, and thread counts `[N]` each occupy a known fixed column width. These widths never change based on content — a file with 0 notes still reserves the badge column as whitespace.
2. **Uniform row height.** Every row in the navigator and threads pane is exactly one terminal line. No multi-line wrapping inside a row. Note previews in threads truncate with `…` to fit.
3. **Aligned separators.** The `Files [N/M reviewed]` separator, the threads header, group headers, and directory headers all left-align their labels at the same indent depth within their pane.
4. **Consistent indent levels.** Unit rows: indent 0. Commit rows: indent 2 (after tree glyph). Directory headers: indent 0 below the files separator. File rows: indent 2 under their directory. Thread group headers: indent 0. Thread file rows: indent 2. Thread note rows: indent 4.
5. **No ragged right edges.** Truncation (`…`) is preferred over wrapping or overflow for labels, commit messages, note previews, and filenames. The right edge of the navigator and threads pane is always clean.
6. **Highlight groups, not ad-hoc styling.** All colors are defined as named highlight groups in `highlights.lua` (e.g. `ReviewUnitActive`, `ReviewFileModified`, `ReviewThreadOpen`). No inline color codes in rendering logic.
7. **Grid-snapped blame panel.** When the blame side panel is open, it occupies a fixed column width (configurable, default 40 columns). The blame SHA, author, date, and code columns are right-padded to fixed widths so they form a clean table. The panel border aligns with the navigator/threads border vertically.

## Primary workflow people should follow

1. Open a review workspace from the repository.
2. Confirm what is being reviewed: base, heads, branches, agents, PRs/MRs, GitButler stacks, and dirty worktree state.
3. Pick a review unit or compare two review units.
4. Walk the file tree and diff hunks.
5. Open context when needed: blame side panel, file history popup, PR/MR timeline, or branch comparison.
6. Add notes and suggestions directly on lines, hunks, files, or review units.
7. Mark files/units reviewed, blocked, needs-agent, or resolved.
8. Copy/export notes as a handoff packet for one agent, one branch, or the whole workspace.
9. Refresh after the agent changes code.
10. Re-review only changed/stale/unresolved items.
11. Publish notes to PR/MR threads when appropriate, leaving unpublishable local notes staged and visible.

## Personas

### Human reviewer

A developer reviewing output from multiple LLM agents. They need to understand which agent changed what, compare alternatives, and write precise instructions without losing context.

### Agent fixer

An LLM agent receiving a handoff packet. It needs file paths, note IDs, branch/unit ownership, exact lines/hunks, surrounding context, git blame/log context, and validation expectations.

### Maintainer

A person deciding which branches or agent outputs should move forward. They need progress, risk, overlap/conflict, and unresolved-note visibility.

### Returning reviewer

A reviewer reopening the app after refresh, branch switch, or agent update. They need durable state and stale-note detection.

## Story map

### A. Open and orient

#### US-01: Open a review workspace

**Status: ✅ Done**

As a human reviewer, I want to open one review workspace from the current repository so I can see all reviewable changes in one interface.

Acceptance criteria:

- Running `:Review` opens a workspace view.
- The workspace clearly shows whether it is reviewing Git, GitHub, GitLab, GitButler, or a local worktree.
- If no changes exist, the app explains what was checked and how to choose a review target.
- If GitButler workspace data is available, virtual branches and unassigned changes are shown as review units.

> **Current state:** `:Review` opens, detects GitButler/Git/forge, shows files. All criteria met.

#### US-02: Understand the active scope

**Status: ✅ Done**

As a reviewer, I want the UI to always show base, head, comparison mode, and active review unit so I do not comment on the wrong diff.

Acceptance criteria:

- The header/statusline shows base ref, head ref, merge-base when relevant, dirty worktree state, and selected scope.
- Worktree, staged, unstaged, untracked, PR/MR, and GitButler scopes are labeled differently.
- The UI warns when a branch switch or refresh makes the active context stale.

> **Current state:** Scope mode (`all`/`current commit`/`select commit`) is shown. The navigator shows base/head context, merge-base when available, persistent stale-context warnings, and a dirty worktree row that distinguishes staged, unstaged, and untracked files. Worktree, untracked, PR/MR, and GitButler contexts have distinct labels in the navigator/threads panes.

#### US-03: See all review units in the navigator

**Status: ✅ Done**

As a reviewer, I want review units at the top of the navigator pane so I can choose among agent branches, PRs/MRs, GitButler virtual branches, and unassigned changes.

Acceptance criteria:

- Each review unit shows label, source type, branch/PR/MR id, owner/agent when known, file count, additions/deletions, note counts, and reviewed/total progress.
- Commits are expandable children under their review unit. Selecting a commit filters the files section below.
- Each unit carries a base ref. A "change base" action lets the reviewer re-diff against any arbitrary ref.
- Review units can be filtered and sorted.
- Selecting a review unit updates the files section, diff, and threads pane.
- `T` cycles units for keyboard-first navigation.
- Units, commits, and files are all in one buffer/window — the navigator.

> **Current state:** Review units are rendered at the top of the unified navigator, with source labels, file/note/progress stats, sorting/filtering, `T` cycling, selectable unit rows, base-changing actions, and file/thread/diff updates when a unit is selected. GitButler branches and unassigned changes are first-class review units.

### B. Navigate many branches and agents

#### US-04: Browse a file tree, not only a flat list

**Status: ✅ Done**

As a reviewer, I want changed files grouped as a tree so I can navigate large multi-agent changes quickly.

Acceptance criteria:

- Files appear in the navigator's files section (below units/commits, separated by a `Files [N/M reviewed]` header).
- Files are grouped by directory with non-selectable directory header rows.
- Directory headers aggregate note counts and reviewed state.
- Files show status icons (`~`/`+`/`-`/`→`/`?`), note count badges `(N)`, and optional devicons.
- `t` toggles between tree layout (directory-grouped) and flat layout (filename first, dimmed directory suffix).
- Inline note sub-rows expand under files (`za` toggle).
- Root-level files appear under a `./` directory header.

Design reference: [MaraniMatias/codereview.nvim](https://github.com/MaraniMatias/codereview.nvim) explorer model (`lua/codereview/ui/explorer/model.lua`).

> **Current state:** The navigator has a files section with tree/flat modes, directory aggregate rows, note badges, status icons, root `./` grouping, and inline note sub-rows toggled with `za`.

#### US-05: Find files that need attention

**Status: ✅ Done**

As a reviewer, I want risk and attention hints so I can start with the most important files.

Acceptance criteria:

- Files can be sorted by size, note count, unreviewed state, changed-by-many-units, conflicts, and risk signals.
- Large additions, deleted files, generated files, and files with open threads are visually distinct.
- Reviewed files can be hidden.

> **Current state:** Files and review-unit rows support risk/overlap/notes/size/unreviewed sorting, attention flags for large/deleted/generated/open-thread/overlap/conflict/baseline-changed files, and reviewed-file hiding.

#### US-06: Filter the workspace

**Status: ✅ Done**

As a reviewer, I want filters so I can focus on one agent, branch, status, or concern.

Acceptance criteria:

- Filters include agent/owner, review unit, file path, note status, thread status, stale state, unreviewed files, conflicts, overlap, and changed-by-multiple-units.
- Active filters are visible and easy to clear.
- Search covers file paths, note bodies, thread bodies, commit messages, and branch names.

> **Current state:** Navigator search covers paths, notes, authors, statuses, commit messages, SHAs, and branch labels. Attention filters cover stale/unreviewed/conflict/overlap/changed-thread risk buckets, thread and notes panes have status filters, active filters render in-pane, and `c` clears search/filter state.

#### US-07: Compare two review units

**Status: ✅ Done**

As a reviewer, I want to compare two agent branches or review units so I can choose the better implementation or detect overlap.

Acceptance criteria:

- The reviewer can choose `Compare with...` from a review unit.
- The diff clearly labels left and right units.
- Files changed in both units are marked.
- Overlapping hunks are easy to jump between.

> **Current state:** `:ReviewCompareUnit`/`C` opens a compare popup for the selected/current unit against another unit, labels left/right units, separates overlap/left-only/right-only files, marks overlapping hunk ranges, and jumps back to overlapping hunks with `<CR>`.

### C. Review diffs

#### US-08: Read diffs in unified or split view

**Status: ✅ Done**

As a reviewer, I want unified and side-by-side diff views so I can use the layout that best fits the change.

Acceptance criteria:

- The reviewer can toggle unified/split without losing cursor position.
- Word-level highlights are preserved when possible.
- Very large files fall back gracefully without blocking the editor.

> **Current state:** Unified/split toggle (`s`), word-level highlights, and large-file fallback all work.

#### US-09: Navigate hunks, files, notes, and threads by keyboard

**Status: ✅ Done**

As a reviewer, I want fast keyboard navigation so I can review without leaving the diff.

Acceptance criteria:

- Keys exist for next/previous hunk, file, note, thread, and review unit.
- Navigation wraps predictably.
- The UI shows key help for the current pane.

> **Current state:** All navigation keys implemented. `?` shows help per pane.

#### US-10: Add notes to exact lines, ranges, hunks, files, or units

**Status: ✅ Done**

As a reviewer, I want to attach feedback at the right granularity so the agent receives clear instructions.

Acceptance criteria:

- A note can target a line, visual range, hunk, file, review unit, or general discussion.
- Suggestions create forge-compatible suggestion blocks when the target supports it.
- Notes include target side (`old`/`new`) and review unit metadata.

> **Current state:** Line, visual range, and suggestion notes work. Side tracking and GitButler metadata present.

#### US-11: Support multiple notes on the same line

**Status: ✅ Done**

As a reviewer, I want multiple notes on one line so separate concerns from different agents or humans do not overwrite each other.

Acceptance criteria:

- The note index stores a list of notes per location.
- The gutter shows a stacked marker or count.
- Opening a line with multiple notes shows a chooser or thread list.
- Edit/delete actions require choosing the specific local note.

> **Current state:** Location indexes store all notes for a line/side, the gutter shows stacked counts, inline previews summarize multiple notes, and edit/delete flows present a chooser when multiple local notes share the same location.

#### US-12: Mark review progress

**Status: ✅ Done**

As a reviewer, I want to mark files and units reviewed, blocked, needs-agent, or resolved so I can track progress across a large workspace.

Acceptance criteria:

- File and review unit statuses include `unreviewed`, `reviewed`, `needs-agent`, `blocked`, and `resolved`.
- Status can be changed from the file tree or notes list.
- Progress counts appear in the review unit rail and workspace summary.

> **Current state:** Files and review units support `unreviewed`, `reviewed`, `needs-agent`, `blocked`, and `resolved`; `r` cycles status from navigator rows; unit/file progress appears in the rail and persists across sessions.

### D. Explore git context

#### US-13: Inspect commit history for the active unit

**Status: ✅ Done**

As a reviewer, I want to see the commit history for a review unit so I understand how the change evolved.

Acceptance criteria:

- Commits are shown as expandable children under their review unit in the navigator.
- Selecting a commit — from any unit, not just the active one — activates that unit, expands it if collapsed, filters the files section to that commit's changed files, and updates the diff.
- Selecting the unit header returns to showing all files across all commits.
- Commit rows show short SHA, message summary, and author in fixed-width columns (no layout shift).
- A commit detail popup (invoked from the navigator) shows full message, file stats, and changed paths.

> **Current state:** Commit/review-unit rows live in the navigator, show SHA/message/source metadata without layout shift, select from any row to filter the files and diff, return to all files from the unit header, and `K` opens an async commit detail popup with full message and changed paths.

#### US-14: Blame a line from the diff

**Status: ✅ Done**

As a reviewer, I want to blame a changed or surrounding line so I can understand ownership and prior intent.

Acceptance criteria:

- From a diff line, `b` opens a blame side panel between the left rail and the diff viewer.
- The blame panel is a vertical split, not a floating popup — it stays visible alongside the diff for line-by-line comparison.
- Blame runs at the review unit's base ref by default (what was there before). A toggle at the top switches to the head ref.
- `b` or `Esc` closes the blame panel.
- Blame output includes author, date, commit, summary, and link/open action when possible.
- Blame context can be attached to a note and included in handoff packets.

> **Current state:** `b` opens a side blame panel from the diff, toggles between base/head blame, closes with `b`/`Esc`, includes commit summaries, and queues selected blame context for handoff notes.

#### US-15: Inspect file history

**Status: ✅ Done**

As a reviewer, I want file history for the selected file so I can see related prior changes before writing feedback.

Acceptance criteria:

- From the diff, `L` opens a file history floating popup showing `git log --follow -- <file>`.
- The popup is unrestricted by the review unit's commit range — it shows the full repo history for the file.
- Selecting a history entry shows that commit's diff for the file in the popup.
- File history context can be attached to a note and included in handoff packets.

> **Current state:** `L` opens async file history for the current file, supports drilling into a commit diff, and queues selected history context for inclusion in handoff notes.

#### US-16: Inspect PR/MR discussion and timeline

**Status: ✅ Done**

As a reviewer, I want PR/MR comments, reviews, approvals, and timeline events in the app so I do not lose context switching to the browser.

Acceptance criteria:

- Remote open, resolved, outdated, and general discussion threads are visible.
- PR/MR review summaries and approvals are shown separately from line comments.
- Refresh preserves local notes and marks remote context stale if fetch fails.

> **Current state:** Remote open, resolved, outdated, and discussion threads are grouped in the threads pane. GitHub approvals/reviews and GitLab system/timeline notes are extracted separately from line comments, and failed/changed remote context is surfaced as stale without dropping local notes.

### E. Manage notes and threads

#### US-17: See note IDs everywhere

**Status: ✅ Done**

As a reviewer, I want every note to have a visible `#id` so I can reference notes in later notes and handoff packets.

Acceptance criteria:

- `#id` appears in notes list, inline preview, thread view, export, clipboard output, publish errors, and blocked-note messages.
- `#id` references are highlighted.
- `gd` jumps to the referenced note.

> **Current state:** IDs appear in notes list rows, inline previews, thread views, export/clipboard packets, publish errors, and blocked-note messages. `#id` references are highlighted and `gd` jumps to the referenced note.

#### US-18: Move notes through review states

**Status: ✅ Done**

As a reviewer, I want notes to move from draft to staged to published or blocked so I know what has been sent.

Acceptance criteria:

- Local notes start as `draft`.
- Staged notes are ready to publish or hand off.
- Published notes are removed locally only after the remote post succeeds or are clearly marked if kept.
- Notes that cannot be published remain local/staged with a clear reason.

> **Current state:** Draft/staged/published flow fully implemented. Published notes removed after success, unpublishable notes stay staged with reason.

#### US-19: Route GitButler notes to the right PR/MR

**Status: ✅ Done**

As a reviewer, I want notes in a GitButler workspace to publish to the PR/MR for their virtual branch so comments do not land on the wrong review.

Acceptance criteria:

- Notes inherit branch metadata from the current review unit or current file.
- Publishing uses GitButler `reviewId` first.
- If no `reviewId` exists, publishing falls back to exactly one open PR/MR by branch name.
- Unassigned, no-PR, unpublished, or ambiguous notes remain staged and local with reasons.

> **Current state:** Fully implemented in `gitbutler.resolve_review_target()` and the publish flow.

#### US-20: Open and act on threads

**Status: ✅ Done**

As a reviewer, I want a rich threads pane and full thread view so I can browse, triage, and act on all review discussions at a glance.

Acceptance criteria:

**Threads pane (bottom-left, always visible):**

- Header shows summary: `Threads  N open · M resolved · K stale`.
- Status filter bar below header cycles `all → open → resolved → stale`.
- Threads grouped by source (`github/`, `gitlab/`, `local/`, `Stale`). Group headers show count and collapse with `<CR>` or `za`.
- File rows under each group show filename, thread count `[N]`, and first-line preview of latest note (dimmed, truncated with `…`).
- Selecting a file row jumps to that file in the diff.
- Expanding a file row shows individual thread rows: author initial, note preview, relative timestamp ("2h ago"), reply count badge, status indicator (● open / ✓ resolved / ◌ stale).
- All columns (icon, author, preview, timestamp, count, status) are fixed-width — no layout shift.
- `n` from diff or navigator jumps focus to the threads pane.

**Full thread view (opened from threads pane or diff):**

- `<CR>` on a thread row opens the full thread view with all replies, author, and date.
- Actions are permission-aware (reply, edit own, delete own, resolve, reopen, open remote URL).
- Closing returns to the caller context: diff if opened from diff, threads pane if opened from threads.

> **Current state:** The threads pane has summary counts, status filtering, grouped/collapsible source sections, file rows with previews and badges, expanded thread rows, and `n` focus. The full thread view exposes reply/edit/delete/resolve/reopen/open-URL actions and returns to the review flow when closed.

#### US-21: Keep stale notes visible

**Status: ✅ Done**

As a returning reviewer, I want stale notes to remain visible so no feedback silently disappears after a branch update.

Acceptance criteria:

- Notes become stale when their file, commit, branch, or remote context no longer matches.
- Stale notes appear in a separate section with reason when possible.
- Stale notes remain exportable for human/agent follow-up.

> **Current state:** `state.note_is_stale()` checks file, commit, GitButler scope, and remote context. Stale notes shown under `Stale` section. Exportable.

### F. Handoff to LLM agents

#### US-22: Copy all actionable feedback

**Status: ✅ Done**

As a reviewer, I want to copy the current review queue so I can paste it to an LLM agent.

Acceptance criteria:

- Clipboard output includes local notes, open remote threads, and discussion items by default.
- Resolved threads are excluded unless requested.
- Output is grouped by review unit and file.

> **Current state:** `build_clipboard_content` groups by file and includes local notes, open threads, and discussion. Resolved excluded. Missing: grouping by review unit (currently groups by file only).

#### US-23: Copy feedback for one agent or branch

**Status: ✅ Done**

As a reviewer, I want to copy only notes for one review unit so each agent receives only relevant work.

Acceptance criteria:

- The notes list and review unit rail expose `copy handoff for this unit`.
- The packet includes only notes/threads relevant to that unit.
- Blocked and stale notes are included with labels when they affect that unit.

> **Current state:** The notes list exposes `u` for the selected note's review unit, and the navigator exposes `u` on review unit rows. Both paths use the same handoff exporter with unit filtering so agents/branches receive only their relevant packet.

#### US-24: Include enough context for the agent to act

**Status: ✅ Done**

As an agent fixer, I want the handoff packet to include precise context so I can fix issues without asking the reviewer to rediscover them.

Acceptance criteria:

Each note in the packet includes:

- Note id.
- Review unit id/label.
- Branch, PR/MR, or GitButler target.
- Base/head/merge-base.
- File path, line/range, side, and note status.
- Hunk text and surrounding context.
- Suggestion block when present.
- Related thread replies when present.
- Blame/log snippets when the reviewer attached them.
- Requested action and expected validation when provided.

> **Current state:** Handoff packets include note ids, unit labels, branch/forge/GitButler metadata, base/head/merge-base, target path/range/side/status, diff hunk context, suggestions, replies, attached blame/log context, requested action, and validation expectations when provided.

#### US-25: Export durable markdown

**Status: ✅ Done**

As a reviewer, I want to export the same handoff packet to markdown so I can archive, send, or attach it elsewhere.

Acceptance criteria:

- Export and clipboard formats are consistent.
- Markdown renders cleanly on GitHub.
- Export can target all units, one unit, local-only notes, or stale notes.

> **Current state:** `export_content()` and clipboard use the same handoff builder, render GitHub-compatible markdown, and support all-notes, one-unit, local-only, and stale-only output.

### G. Refresh and re-review

#### US-26: Refresh after agents push changes

**Status: ✅ Done**

As a reviewer, I want to refresh the workspace after agents update branches so I can re-review only what changed.

Acceptance criteria:

- Refresh updates review units, files, remote threads, GitButler status, and notes.
- The app preserves cursor, selected unit, filters, and open notes list where possible.
- Notes whose targets disappear move to stale, not deleted.

> **Current state:** `R` refreshes. File index, commit index, scope mode, and notes list preserved. Stale notes moved correctly.

#### US-27: Compare before and after agent fixes

**Status: ✅ Done**

As a reviewer, I want to compare an agent's updated branch with the previous reviewed state so I can verify the requested fixes.

Acceptance criteria:

- The app stores a reviewed snapshot or enough metadata to identify prior state.
- Changed-since-last-review files are highlighted.
- Fixed, unchanged, and newly introduced notes can be distinguished.

> **Current state:** `:ReviewMarkBaseline` stores the current HEAD plus file signatures, and `:ReviewCompareBaseline` re-diffs against that baseline. The navigator marks files changed since the baseline with `B` and files newly introduced since the baseline with `N`; the `changed` attention filter isolates both. The notes list labels resolved notes as fixed and labels file notes as unchanged, changed, or new since baseline.

#### US-28: Resolve completed feedback

**Status: ✅ Done**

As a reviewer, I want to mark notes resolved after an agent fixes them so the queue reflects remaining work.

Acceptance criteria:

- Local notes can be marked resolved without deleting them.
- Remote threads can be resolved/reopened when supported by the forge.
- Resolved notes are hidden by default but available by filter/export.

> **Current state:** Local notes can be resolved/reopened without deletion, remote threads resolve/reopen through the forge when supported, and resolved items are hidden from the default handoff queue while remaining visible through filters/export.

### H. Safety and mutation boundaries

#### US-29: Review without accidental repo mutation

**Status: ✅ Done**

As a reviewer, I want the app to be read-only by default so I do not accidentally stage, restore, delete, or commit files while reviewing.

Acceptance criteria:

- The review layout contains no embedded staging, committing, or restore actions.
- The Fugitive status pane and GitButler status pane are removed from the review layout.
- GitButler workspace metadata is shown per review unit in the rail, not as a mutation-capable pane.
- Users who want Fugitive staging use `:Git` outside the review tab.
- `vim-fugitive` moves from a hard dependency to optional.

> **Current state:** The review layout no longer embeds Fugitive or GitButler mutation panes. GitButler metadata is shown read-only in navigator review units, Fugitive remains external via `:Git`, and `vim-fugitive` is no longer a hard dependency.

#### Keymap changes from layout removal

| Key | Current | After refactor |
|-----|---------|----------------|
| `g` | Focus Fugitive/GitButler pane | *Free* — candidate for threads focus or unit rail focus |
| `n` | *(unused in rail)* | Jump to threads pane from diff/navigator |
| `T` | Cycle GitButler branch/unassigned scope | Cycle review units in the rail |
| `b` | *(unused)* | Blame popup from diff line |
| `L` | *(unused)* | File history popup |
| `t` | *(unused in diff/explorer)* | Toggle tree ↔ flat file layout |

#### US-30: Confirm destructive note actions

**Status: ✅ Done**

As a reviewer, I want confirmation before deleting many notes so I do not lose review work.

Acceptance criteria:

- Clearing all local notes requires confirmation.
- Bulk actions state exactly which notes/statuses are affected.
- Remote threads are never deleted by local clear actions.

> **Current state:** `clear_local_notes()` prompts with count. Remote notes excluded from clear. Fully implemented.

### I. Persist and reopen work

#### US-31: Persist notes per review workspace

**Status: ✅ Done**

As a returning reviewer, I want notes tied to the correct review workspace so notes from one branch/PR/GitButler stack do not bleed into another.

Acceptance criteria:

- Storage keys include repo root, review mode, base/head refs, PR/MR id, GitButler branch ids, and review unit ids as available.
- Old note storage is migrated or read safely.
- Reopening a workspace restores notes, statuses, filters, and reviewed state.

> **Current state:** `storage.lua` keys persisted state by repo root, branch, review mode, base ref, PR/MR number, head/worktree identity, and available review-unit ids. It still reads previous v2 mode/base/PR keys and legacy branch-only keys so existing notes migrate safely. Notes, statuses, filters, and baseline snapshots restore with the workspace.

#### US-32: Open multiple review sessions

**Status: ✅ Done**

As a reviewer, I want multiple review tabs or sessions so I can compare workspaces without losing state.

Acceptance criteria:

- State is keyed by session id, not one global singleton.
- `:ReviewToggle` affects the active review tab/session.
- Closing one session does not destroy another.

> **Current state:** `state.lua` keeps sessions keyed by tab, `:ReviewToggle`/close operate on the active review tab, and destroying one tab's session leaves other sessions intact.

### J. Performance and responsiveness

#### US-33: Load large workspaces incrementally

**Status: ✅ Done**

As a reviewer, I want the UI to stay responsive while loading many branches, diffs, and comments.

Acceptance criteria:

- Expensive git, forge, and GitButler calls run asynchronously.
- Partial results render as they arrive.
- Loading state is visible per review unit.
- Refresh can be cancelled or superseded by a newer refresh.

> **Current state:** Forge detection/comments, Git diffs/logs/blame/commit details, and GitButler workspace loads have async paths. Per-unit commit diffs show loading state, duplicate in-flight jobs are coalesced, and stale async callbacks are ignored after superseding refreshes.

#### US-34: Cache context safely

**Status: ✅ Done**

As a reviewer, I want repeated context lookups to be fast but correct.

Acceptance criteria:

- Per-unit diff/log/blame results are cached.
- Cache invalidates when the relevant ref, workspace signature, or remote thread version changes.
- Stale cached remote data is labeled as cached/stale.

> **Current state:** Git diffs, commit diffs, commit logs, file history, file show, and blame are cached/coalesced by ref/path; GitButler and forge detection cache per root; cache invalidates on workspace signature or explicit invalidation; remote bundles validate branch/base and stale remote context is surfaced in the UI.

### K. Accessibility and discoverability

#### US-35: Discover actions from anywhere

**Status: ✅ Done**

As a reviewer, I want contextual help so I can remember commands without leaving the review.

Acceptance criteria:

- `?` shows pane-specific keys and commands.
- Help distinguishes current behavior from disabled or unavailable actions.
- Missing tools explain what feature is affected and how to install/authenticate.

> **Current state:** `?` lists pane actions and commands, includes availability checks for git/GitHub/GitLab/GitButler tooling, and explains what to install when an integration is unavailable.

#### US-36: Keep the UI readable

**Status: ✅ Done**

As a reviewer, I want dense but legible panes that work in small terminals and colorblind themes.

Acceptance criteria:

- Long paths, branch names, and titles truncate without hiding key identity.
- Color is not the only status signal.
- Badges/icons have text equivalents in help or statusline.
- Layout degrades gracefully in narrow terminals.

> **Current state:** Long paths, branch labels, notes, titles, footers, gutter columns, thread badges, and statuslines truncate or compact in narrow terminals; colorblind highlights are centralized; status icons have textual help/statusline equivalents; layout degradation is covered by narrow-width UI specs.

---

## Architectural migration plan

The stories above require structural changes to the codebase. This section describes *how* the code gets from current shape to target shape.

### Current module layout (9,306 lines)

```
lua/review.lua          983 lines  — entry point, export, commands
lua/review/ui.lua     4,867 lines  — ALL window/buffer/layout
lua/review/state.lua    876 lines  — singleton session state
lua/review/forge.lua    783 lines  — GitHub/GitLab API
lua/review/git.lua      583 lines  — git CLI wrapper
lua/review/gitbutler.lua 475 lines — GitButler CLI adapter
lua/review/diff.lua     264 lines  — unified diff parser
lua/review/provider.lua 222 lines  — provider detection
lua/review/storage.lua  177 lines  — JSON persistence
lua/review/health.lua    76 lines  — checkhealth
```

### Target module layout

Split `ui.lua` into focused modules. Each module owns its buffer, window, keymaps, and rendering:

```
lua/review/ui/init.lua        — two-pane layout orchestration, tab management
lua/review/ui/navigator.lua   — top-left: units + commits + file tree in one buffer (US-03, US-04, US-13)
lua/review/ui/diff.lua        — unified and split diff rendering
lua/review/ui/blame.lua       — blame side panel between rail and diff (US-14)
lua/review/ui/file_log.lua    — file history floating popup (US-15)
lua/review/ui/threads.lua     — bottom-left: thread/notes sidebar (US-20)
lua/review/ui/notes_list.lua  — notes list floating window
lua/review/ui/help.lua        — contextual help
lua/review/ui/highlights.lua  — highlight group definitions
lua/review/handoff.lua        — handoff packet builder (US-22–25)
```

Removed modules (no longer needed after layout change):
- Fugitive pane embedding code
- GitButler status pane rendering code
- `g` keymap for focus-git-pane (repurposed or freed)

**Migration approach:** Extract one module at a time from `ui.lua`. Each extraction is a standalone PR that does not change behavior — only moves code. Run the full test suite after each extraction.

### <a id="session-registry"></a>Session registry (US-32)

Current: `state.lua` holds `local session = nil` — a single global.

Target: A session registry keyed by tab number or session id.

```lua
-- state.lua
local sessions = {}  -- tab_number -> ReviewSession

function M.create(tab, mode, base_ref, files, opts) ... end
function M.get(tab)     return sessions[tab or current_tab()] end
function M.destroy(tab) sessions[tab or current_tab()] = nil end
```

**Migration path:**

1. Add a `tab` parameter to `create()`, `get()`, `destroy()` with a default of `vim.api.nvim_get_current_tabpage()`.
2. Replace the singleton `session` with `sessions[tab]`.
3. Update all callers that use `state.get()` to pass tab context.
4. Update storage to include tab/session id in the save/load path.

### <a id="note-index-multi-note"></a>Note index: multi-note per location (US-11)

Current: `note_index_by_location[key]` stores `{ note, idx }` — one entry per `(file, line, side)`.

Target: Store a list per location.

```lua
-- Change from:
session.note_index_by_location[key] = { note = note, idx = idx }

-- To:
if not session.note_index_by_location[key] then
  session.note_index_by_location[key] = {}
end
table.insert(session.note_index_by_location[key], { note = note, idx = idx })
```

**Migration path:**

1. Change `rebuild_note_indexes()` to collect lists.
2. Update `find_note_at()` to return a list or the first match with a count.
3. Update `ui.lua` gutter rendering to show count when `#list > 1`.
4. Update edit/delete flows to show a chooser when multiple notes exist at the cursor.

### <a id="storage-key-evolution"></a>Storage key evolution (US-31)

Current key: `repo_root::branch` (sanitized to filesystem-safe chars).

Target key: `repo_root::branch::mode::pr_number` when a PR is detected.

```lua
local function storage_key()
  local git = require("review.git")
  local root = git.root()
  if not root then return nil end
  local branch = git.current_branch() or "HEAD"
  local state = require("review.state")
  local s = state.get()
  local pr = s and s.forge_info and s.forge_info.pr_number
  local key = root .. "::" .. branch
  if pr then
    key = key .. "::pr" .. tostring(pr)
  end
  return key:gsub("[/\\:]", "_")
end
```

**Migration:** Check for the old key format on load. If a file exists at the old path but not the new path, read from the old path and write to the new path on next save.

### UI decomposition order

1. **Extract `highlights.lua`** — pure data, zero risk.
2. **Remove Fugitive/GitButler pane code** — delete embedding logic, free `g` keymap.
3. **Extract `help.lua`** — self-contained floating window.
4. **Extract `notes_list.lua`** — floating window with its own keymaps.
5. **Extract `diff.lua`** — largest piece, most keymaps.
6. **Extract `threads.lua`** — bottom-left pane, kept as-is.
7. **Build `navigator.lua`** — merge current files pane + scope/commit rows into one buffer with units → commits → files (US-03, US-04, US-13). Add tree mode with `t` toggle.
8. **Add `blame.lua`** — side panel (vertical split between rail and diff) from `b` key (US-14).
9. **Add `file_log.lua`** — floating popup from diff `L` key (US-15).
10. **Wire two-pane layout in `init.lua`** — navigator (top-left) + threads (bottom-left) + diff (right).

---

## Technical constraints and risks

### Neovim version floor

- `vim.system()` requires Neovim ≥ 0.10. The README says 0.9+, but `forge.lua` and `gitbutler.lua` already use `vim.system()`. **Decision needed:** bump the minimum to 0.10 or replace `vim.system()` calls with `vim.fn.jobstart()`.
- `vim.api.nvim_set_hl()` with `link` field requires ≥ 0.9 (already met).

### Performance bounds

| Dimension | Comfortable | Degraded | Must handle gracefully |
|-----------|------------|----------|----------------------|
| Changed files | < 100 | 100–500 | > 500 (incremental render) |
| Diff lines per file | < 2,000 | 2,000–10,000 | > 10,000 (truncate/paginate) |
| Notes per session | < 200 | 200–1,000 | > 1,000 (virtual scroll) |
| Review units | < 10 | 10–30 | > 30 (lazy load) |
| Forge API calls per refresh | < 5 | 5–15 | > 15 (batch/rate limit) |

### Forge API limits

- GitHub GraphQL: 5,000 points/hour. The threads query costs ~1 point per call. At 15 review units × 2 refreshes, this is safe. Pagination caps at 100 threads — workspaces with > 100 threads need cursor-based pagination.
- GitLab REST: 2,000 requests/minute (authenticated). `--paginate` handles multi-page responses but can be slow for large MRs.
- **Mitigation:** Cache aggressively per-session. Only re-fetch when the user explicitly refreshes or the workspace signature changes.

### GitButler CLI stability

- `but -j status` and `but -j diff` JSON schema is not versioned. Breaking changes in `but` CLI updates can silently break the adapter.
- **Mitigation:** Pin expected field names in `gitbutler.lua`. Add a `health.lua` check that validates the `but --version` output and warns if it's older/newer than the tested range. Fail gracefully with `vim.notify` rather than a Lua error.

### Startup time budget

- `:Review` should open the UI within **200ms** for a 50-file diff on local git.
- Forge detection and comment fetch happen asynchronously and should not block the initial render.
- GitButler `but -j status` + `but -j diff` currently run synchronously. For workspaces with > 5 stacks, consider async with placeholder rendering.

---

## Edge cases and error handling

These scenarios are not covered by the user stories but need explicit handling:

### GitButler workspace changes mid-review

- **Branch deleted mid-review:** Notes on that branch become stale. The review unit disappears from the rail on refresh. Stale notes remain visible and exportable.
- **Stack reordered mid-review:** File assignments may shift. Refresh rebuilds scope from fresh `but -j status`. Notes stay attached to their branch by `branch_cli_id`; if the ID changes, notes become stale.
- **New branch appears mid-review:** Refresh picks it up as a new review unit. No existing notes are affected.

### Forge API unreachable during publish

- Publish should fail per-note, not all-or-nothing. Successfully published notes are removed; failed notes remain staged with an error reason per note.
- The current implementation already handles this — `publish_staged()` only removes notes with a URL in `url_map`.

### Two review units modify the same file

- The file should appear once in the file tree but be tagged with both review units.
- Notes on that file should inherit the review unit from the scope active when the note was created, not from the file itself.
- The overlap badge (US-05) surfaces this to the reviewer.

### Note target shifts after rebase

- After a force-push or rebase, line numbers shift. Notes with stale line numbers should be detected via `workspace_signature` change and marked stale.
- Future: consider storing hunk context (3 lines above/below) to attempt fuzzy re-anchoring after rebase.

### Storage corruption

- `storage.load()` already uses `pcall(vim.fn.json_decode)` and returns `{}` on failure.
- Add: backup the last-known-good file before overwriting. If decode fails, notify the user and offer to discard or inspect the corrupted file.

---

## <a id="handoff-packet-example"></a>Handoff packet example

Target format for US-24. This is what a rich handoff packet should look like:

````markdown
# Review Handoff for GitHub #42

- branch: `feature/add-caching`
- base: `main`
- head: `abc1234`
- merge-base: `def5678`
- review units: 1

## feature/add-caching (GitHub PR #42)

### lua/review/state.lua:87:new

- id: #3
- status: draft
- type: comment
- action: fix

```diff
@@ -85,7 +85,7 @@
   local function rebuild_note_indexes()
     if not session then
       return
     end
-    session.note_index_by_location[key] = { note = note, idx = idx }
+    -- BUG: overwrites previous note at same location
+    session.note_index_by_location[key] = { note = note, idx = idx }
```

> This should store a list, not a single entry. Multiple notes on the same line
> get silently dropped. See #1 for the user-facing impact.

- blame: @pesap 2025-12-01 "initial note index implementation"
- validation: `busted tests/review/state_spec.lua` should pass after fix

### lua/review/storage.lua:42:new

- id: #5
- status: staged
- type: suggestion

```suggestion
local function storage_key()
  local git = require("review.git")
  local root = git.root()
  if not root then return nil end
  local branch = git.current_branch() or "HEAD"
  local s = require("review.state").get()
  local pr = s and s.forge_info and s.forge_info.pr_number
  local key = root .. "::" .. branch
  if pr then key = key .. "::pr" .. tostring(pr) end
  return key:gsub("[/\\:]", "_")
end
```

> Include PR number in storage key to prevent note collision across PRs on the same branch.
````

---

## MVP story sequence

Implement the target interaction in this order. Sub-steps within each phase are ordered by dependency.

### Phase 1: Workspace orientation

1. US-29 — Remove Fugitive/GitButler panes, establish two-pane layout (read-only-by-default).
2. US-02 — Stale-context warning banner in the UI.
3. US-03 — Navigator pane: review units with commits as expandable children and per-unit base ref.
4. US-04 — Navigator pane: file tree section with directory grouping and `t` flat/tree toggle.

### Phase 2: Reliable notes

1. US-11 — Multi-note per location (data structure change in `state.lua`).
2. US-17 — Note IDs in all error/blocked messages.
3. US-12 — Reviewed/needs-agent/blocked/resolved status per file and unit.
4. US-28 — Local note resolve status.

### Phase 3: Agent handoff

1. US-24 — Enrich handoff packet with hunk text, context lines, base/head/merge-base.
2. US-23 — Per-unit clipboard/export.
3. US-25 — Export modes: all, one unit, local-only, stale-only.

### Phase 4: Progress tracking

1. US-05 — Attention hints and risk sorting.
2. US-06 — Workspace filters.

### Phase 5: Git context

1. US-14 — Blame side panel from diff (`b` key, new `blame.lua`).
2. US-15 — File history floating popup from diff (`L` key, new `file_log.lua`).
3. US-13 — Commit detail popup from the navigator.
4. US-16 — PR/MR timeline events.

### Phase 6: Compare mode

1. US-07 — Compare two review units.
2. US-27 — Before/after agent fix comparison.

### Phase 7: Durability

1. US-31 — Storage key evolution with migration.
2. US-32 — Session registry (singleton → multi-session).

### Phase 8: Scale

1. US-33 — Async git operations and cancellable refresh.
2. US-34 — Per-unit caching with invalidation.

---

## Definition of done for the refactor

### Product behavior

- A human can review multiple agents/branches in one workspace without switching branches manually.
- Every note knows which review unit it belongs to.
- Multiple notes on the same line are visible and actionable.
- The app can produce a structured handoff packet that an LLM agent can act on.
- Git history, blame, file log, and branch comparison are available from the review flow.
- Review progress is visible across units and files.
- The default UI does not encourage accidental repo mutation.
- Refreshing after agent updates preserves useful state and surfaces stale feedback.

### Engineering quality

- Each extracted UI module has its own test file under `tests/review/ui/`.
- `state_spec.lua` covers multi-note indexing, session registry, and storage key migration.
- `gitbutler_spec.lua` covers mid-review scope changes (branch deleted, stack reordered).
- `:checkhealth review` validates Neovim version, `git`, `but`, `gh`/`glab` availability and version ranges.
- README documents all new commands, keymaps, and config options introduced by the refactor.

### Backward compatibility

- Existing note files at the old storage key format are read on first load and migrated transparently.
- Existing keymaps and commands continue to work unchanged.
- Users who do not use GitButler or forge features see no behavior change.

---

## Assumptions

- The primary user is a human reviewer coordinating LLM-generated changes.
- LLM agents act outside the app after receiving exported/copied notes.
- Publishing to GitHub/GitLab is useful, but local handoff remains first-class.
- GitButler virtual branches should be treated as review units, not just commit filters.
- The minimum supported Neovim version is 0.10 (required by `vim.system()`).
- `vim-fugitive` is optional, not required. The review layout does not embed Fugitive.
