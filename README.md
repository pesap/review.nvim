# review.nvim

Minimal code review plugin for Neovim.

> This plugin was vibe-coded to scratch my own itch. It works for me but might be rough around the edges. PRs are welcome, though more mature alternatives like [afewyards/codereview.nvim](https://github.com/afewyards/codereview.nvim) and [MaraniMatias/codereview.nvim](https://github.com/MaraniMatias/codereview.nvim) probably already have what you need. This project borrows ideas from both.

## What it does

- Two-pane review layout in its own tab: navigator, threads, and diff
- Read-only by default: no embedded staging, restore, commit, Fugitive, or GitButler mutation pane
- GitButler workspace detection with virtual branches and unassigned changes as review units
- Unified and side-by-side split views
- Word-level diff highlighting
- Explicit review scope modes: `All`, `Current Commit`, and `Select Commit`
- Commit navigation with per-commit file and thread filtering
- File tree and flat navigator modes, review status markers, risk sorting, and reviewed-file hiding
- Blame side panel and file history popup from the diff
- Inline notes on any diff line or visual selection
- Multiple notes on the same line
- Suggestion notes with GitHub-compatible `suggestion` blocks
- Notes list panel with draft/staged/resolved/published workflow, search, filters, and per-unit copy
- Note, review-status, and UI preference persistence across sessions
- Grouped thread queue for GitHub/GitLab, PR/MR summary context, stale threads, and local notes
- Stale notes/threads surfaced separately when files disappear or remote review context goes stale
- Reference other notes with `#<id>` syntax
- Export notes to markdown and copy rich handoff packets to the clipboard
- Configurable keymaps
- Colorblind-friendly color scheme (enabled by default)
- `:checkhealth review`

## Requirements

- Neovim >= 0.10.0
- `git`
- `but` CLI (https://docs.gitbutler.com/cli-overview) for GitButler workspace support, optional
- `gh` CLI (https://cli.github.com) for GitHub PR features, optional
- `glab` CLI (https://gitlab.com/gitlab-org/cli) for GitLab MR features, optional
- `plenary.nvim` for tests

You only need `gh` or `glab` for the forge you use.

## Install

lazy.nvim:

```lua
{
  "pesap/review.nvim",
  branch = "main", -- optional: track the main branch explicitly
  config = function()
    require("review").setup()
  end,
}
```

## Usage

```vim
:Review              " local review (GitButler workspace when detected, otherwise default branch/HEAD)
:Review HEAD~3       " diff against a ref (shows commits)
:Review main         " diff against main
:ReviewToggle        " open/close
:ReviewHelp          " open review help
:ReviewNotes         " open notes list from anywhere
:ReviewComment       " add note at cursor, selection, or an explicit line/file/unit/discussion target
:ReviewSuggestion    " add suggestion at cursor, selection, or an explicit path/line target
:ReviewChangeBase main " re-diff the active local review against another base
:ReviewMarkBaseline " mark current HEAD and current file state as a before-fix baseline
:ReviewCompareBaseline " compare current work against the marked baseline
:ReviewCompareUnit 2 " compare the selected/current review unit with another unit
:ReviewExport        " export notes to markdown
:ReviewClipboard     " copy all notes to the clipboard
:ReviewClipboardLocal " copy only local notes to the clipboard
:ReviewClearLocal    " clear all local notes after confirmation
```

You can also call `toggle()` from a keymap:

```lua
vim.keymap.set("n", "<leader>rr", "<cmd>ReviewToggle<cr>", { desc = "Toggle review" })
```

## Config

```lua
require("review").setup({
  view = "unified",       -- "unified" or "split"
  render = {
    word_diff = {
      enabled = true,         -- inline changed-text highlights for paired del/add lines
      max_line_length = 300,  -- skip word diff on very long lines
      max_pairs_per_hunk = 64,
      max_hunk_lines = 200,
      max_file_lines = 1500,  -- large files fall back to line-level highlighting
    },
  },
  notifications = {
    context = false,      -- suppress "Reviewing PR #... against main" info messages
  },
  colorblind = true,      -- blue/yellow scheme (default), set false for red/green
  provider = nil,         -- "github" | "gitlab" | nil (auto-detect from origin URL)
  keymaps = {
    add_note = "a",
    edit_note = "e",
    delete_note = "d",
    help = "?",
    next_hunk = "]c",
    prev_hunk = "[c",
    next_file = "]f",
    prev_file = "[f",
    next_note_short = nil,
    next_note = "]n",
    prev_note = "[n",
    toggle_split = "s",
    toggle_stack = "<Tab>",
    refresh = "R",
    focus_files = "f",
    focus_diff = "<leader>d",
    focus_git = nil,        -- compatibility only; no git mutation pane is embedded
    focus_threads = "T",
    toggle_file_tree = "t",
    sort_files = "o",
    toggle_reviewed = "H",
    filter_attention = "A",
    change_base = "B",
    mark_baseline = "M",
    compare_baseline = "V",
    compare_unit = "C",
    commit_details = "K",
    blame = "b",
    file_history = "L",
    notes_list = "N",
    suggestion = "S",
    close = "q",
  },
})
```

## Explicit note targets

`review.nvim` can place notes from the current cursor or selection, but you can also target a location explicitly:

```vim
:ReviewComment README.md:103
:ReviewComment lua/review.lua 42 old
:ReviewComment file lua/review.lua
:ReviewComment unit
:ReviewComment discussion
:ReviewSuggestion lua/review.lua:57:new
```

## Keymaps

Navigator headers show the main areas: `[F] Files`, `[Diff]`, `[S] split/unified`, and `[T] Threads`.
Use `<CR>` select, `N` notes list, `u` copy selected review unit handoff, `?` help, `q` close full review.

The left rail shows the active `Scope` explicitly:
- `all` for the whole branch/range
- `current · <sha>` for the current commit
- `select · <sha>` while browsing commits directly from the rail

Use `<Tab>` to cycle scope rows. Scope rows are the commit/review-unit list;
move the cursor onto one and press `C` to compare that unit against the
currently selected unit. Press `K` on a scope row to inspect its commit
details.

When available, the navigator also shows the merge-base SHA used for the
comparison.

Implicit worktree reviews also show a `dirty` context row when staged,
unstaged, or untracked files are present. Narrow rails compact that row to
`S`, `U`, and `?` counts.

When the current branch is `gitbutler/workspace` and `but -j status` works,
`:Review` switches to GitButler mode. The navigator is built from GitButler
stack branches plus staged and unassigned changes, `<Tab>` cycles through each
GitButler branch/unassigned scope, and `R` refreshes from the latest `but`
workspace state. Stack mutations still belong in GitButler or the `but` CLI.

Stale notes/threads are surfaced under `Stale` instead of silently disappearing.

Diff viewer:

| Key         | What                               |
| ----------- | ---------------------------------- |
| `a`         | add note (normal or visual)        |
| `S`         | suggestion note (normal or visual) |
| `e`         | edit note                          |
| `d`         | delete note                        |
| `N`         | notes list                         |
| `u`         | copy selected review unit handoff  |
| `?`         | help                               |
| `]c` / `[c` | next/prev hunk                     |
| `]f` / `[f` | next/prev file                     |
| `n`, `]n` / `[n` | next/prev note                 |
| `s`         | toggle split                       |
| `<Tab>`     | cycle scopes (GitButler: each branch/unassigned scope) |
| `R`         | refresh review data                |
| `f`         | focus the Files section            |
| `<leader>d` | focus the Diff section            |
| `T`         | focus the Threads section          |
| `t`         | toggle navigator tree/flat layout  |
| `o`         | cycle file sort                    |
| `A`         | cycle attention filter (`changed` shows files changed since baseline) |
| `H`         | hide/show reviewed files           |
| `B`         | change base ref                    |
| `M`         | mark before-fix baseline           |
| `V`         | compare with marked baseline       |
| `C`         | compare selected/current review units |
| `K`         | open commit details                |
| `b`         | open/close blame side panel        |
| `L`         | open file history popup            |
| `q`         | close full review                  |

review.nvim does not embed a git status pane. Use `:Git`, GitButler, or the
`but` CLI outside the review tab when you want to mutate the repository.

Commands:

| Command | What |
| ------- | ---- |
| `:ReviewNotes` | open the notes list |
| `:ReviewComment` | add a note at the cursor/selection or an explicit target |
| `:ReviewSuggestion` | add a suggestion at the cursor/selection or an explicit target |
| `:ReviewRefresh` | refresh review data |
| `:ReviewChangeBase [ref]` | re-diff the active local review against another base |
| `:ReviewMarkBaseline` | mark current HEAD and file state as the before-fix review baseline |
| `:ReviewCompareBaseline` | compare current work against the marked baseline |
| `:ReviewCompareUnit [idx]` | compare selected/current review unit with another unit |
| `:ReviewClipboard` | copy local notes, open threads, and discussion items to the clipboard |
| `:ReviewClipboardLocal` | copy only local draft/staged notes to the clipboard |
| `:ReviewClearLocal` | clear all local notes after confirmation |

Notes list:

| Key       | What                              |
| --------- | --------------------------------- |
| `j` / `k` | navigate between notes            |
| `<CR>`    | jump to note in diff              |
| `dd`      | delete note                       |
| `s`       | toggle draft/staged               |
| `P`       | publish all staged notes          |
| `y`       | copy local notes, open threads, and discussion items |
| `u`       | copy a handoff packet for the selected note's review unit |
| `Y`       | copy only local draft/staged notes |
| `x`       | resolve/reopen a local note       |
| `a`       | attach queued blame/history context to a local note |
| `/`       | search notes                      |
| `f`       | cycle note status filter          |
| `c`       | clear notes filters               |
| `C`       | clear all local notes             |
| `gd`      | jump to referenced note (`#<id>`) |
| `?`       | help                              |
| `q`       | close                             |

Note editor: `<C-s>` or `:wq` save, `<Esc>` cancel

## Notes workflow

Notes go through three stages:

1. **Draft** (`-`) — newly created notes start here
2. **Staged** (`+`) — press `s` to mark a note as ready to publish
3. **Published** (`*`) — press `P` to publish all staged notes

In GitButler workspaces, staged notes publish to the PR/MR for their virtual
branch. review.nvim uses GitButler `reviewId` metadata first, then falls back to
looking up one open PR/MR by branch name. Notes on unassigned changes, branches
without an open PR/MR, or ambiguous branch matches stay local/staged and are not
published.

Notes persist across sessions automatically. Reference other notes by typing `#<id>` in the note body (e.g., `see #1 for context`). Referenced notes are highlighted and navigable with `gd`.

Use `:ReviewClipboard` or `y` from the notes list to copy the actionable review queue into your clipboard for LLM handoff: local notes, open threads, and discussion items. Resolved threads are left out.

Use `:ReviewClipboardLocal` or `Y` if you only want your own local draft/staged notes.

Remote review threads are shown separately from the file list in the sidebar, grouped by source such as `github/`, `gitlab/`, or `local/`.

When you create a local note while scoped to a commit, the note is stamped with that commit SHA. In `all` scope those commit-bound notes can still be surfaced, but in commit scope only matching local notes are shown. Remote GitHub/GitLab threads stay conservative: they are filtered by active file membership rather than guessed commit attribution.

In GitButler mode, notes created on unassigned changes or unpublished branches
are marked `unpublished`. They are included in local/export/clipboard workflows,
but publishing to GitHub/GitLab is blocked until the change is committed and
pushed into a PR/MR-compatible branch context.

If you switch branches or the remote review context becomes outdated, `:ReviewRefresh`/UI refresh will reopen the session against the current branch and move no-longer-valid notes/threads into `Stale`.

## Inspiration

Frankenstein of [afewyards/codereview.nvim](https://github.com/afewyards/codereview.nvim) and [MaraniMatias/codereview.nvim](https://github.com/MaraniMatias/codereview.nvim).

## Acknowledgments

This repo was bootstrapped with the [ellisonleao/nvim-plugin-template](https://github.com/ellisonleao/nvim-plugin-template).

## License

MIT
