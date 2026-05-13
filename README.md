# review.nvim

Minimal code review plugin for Neovim.

> This plugin was vibe-coded to scratch my own itch. It works for me but might be rough around the edges. PRs are welcome, though more mature alternatives like [afewyards/codereview.nvim](https://github.com/afewyards/codereview.nvim) and [MaraniMatias/codereview.nvim](https://github.com/MaraniMatias/codereview.nvim) probably already have what you need. This project borrows ideas from both.

## What it does

- Dual-panel layout (file explorer + diff viewer) in its own tab
- Embedded Fugitive status pane for worktree reviews
- Unified and side-by-side split views
- Word-level diff highlighting
- Explicit review scope modes: `All`, `Current Commit`, and `Select Commit`
- Commit navigation with per-commit file and thread filtering
- Inline notes on any diff line or visual selection
- Suggestion notes with GitHub-compatible `suggestion` blocks
- Notes list panel with draft/staged/published workflow
- Note persistence across sessions
- Grouped thread queue for GitHub/GitLab and local notes
- Stale notes/threads surfaced separately when files disappear or remote review context goes stale
- Reference other notes with `#<id>` syntax
- Export notes to markdown
- Copy all notes to the clipboard for LLM handoff
- Configurable keymaps
- Colorblind-friendly color scheme (enabled by default)
- `:checkhealth review`

## Requirements

- Neovim >= 0.9.0
- `git`
- `vim-fugitive` (https://github.com/tpope/vim-fugitive) for the embedded git status pane
- `gh` CLI (https://cli.github.com) for GitHub PR features
- `glab` CLI (https://gitlab.com/gitlab-org/cli) for GitLab MR features
- `plenary.nvim` for tests

You only need `gh` or `glab` for the forge you use.

## Install

lazy.nvim:

```lua
{
  "pesap/review.nvim",
  branch = "main", -- optional: track the main branch explicitly
  dependencies = { "tpope/vim-fugitive" },
  config = function()
    require("review").setup()
  end,
}
```

## Usage

```vim
:Review              " local review (default branch when available, otherwise HEAD/worktree)
:Review HEAD~3       " diff against a ref (shows commits)
:Review main         " diff against main
:ReviewToggle        " open/close
:ReviewHelp          " open review help
:ReviewNotes         " open notes list from anywhere
:ReviewComment       " add note at cursor, selection, or an explicit path/line target
:ReviewSuggestion    " add suggestion at cursor, selection, or an explicit path/line target
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
    next_note_short = "n",
    next_note = "]n",
    prev_note = "[n",
    toggle_split = "s",
    toggle_stack = "T",
    focus_files = "f",
    focus_git = "g",
    focus_threads = "t",
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
:ReviewSuggestion lua/review.lua:57:new
```

## Keymaps

Explorer: `<CR>` select, `N` notes list, `?` help, `q` close full review

The left rail shows the active `Scope` explicitly:
- `all` for the whole branch/range
- `current · <sha>` for the current commit
- `select · <sha>` while browsing commits directly from the rail

In local worktree reviews opened without an explicit ref, review.nvim embeds a
Fugitive status pane below the explorer in the left rail. Press `g` to jump to
it. That pane uses
your normal Fugitive keymaps and actions, but inherits review.nvim's window
theme so it feels like part of the same layout.

If Fugitive is not installed, review.nvim shows a small themed placeholder pane
instead of failing the whole review UI.

Stale notes/threads are surfaced under `Stale` instead of silently disappearing.

Diff viewer:

| Key         | What                               |
| ----------- | ---------------------------------- |
| `a`         | add note (normal or visual)        |
| `S`         | suggestion note (normal or visual) |
| `e`         | edit note                          |
| `d`         | delete note                        |
| `N`         | notes list                         |
| `?`         | help                               |
| `]c` / `[c` | next/prev hunk                     |
| `]f` / `[f` | next/prev file                     |
| `n`, `]n` / `[n` | next/prev note                 |
| `s`         | toggle split                       |
| `T`         | cycle `All` -> `Current Commit` -> `Select Commit` |
| `f`         | focus the Files section            |
| `g`         | focus the Fugitive pane            |
| `t`         | focus the Threads section          |
| `q`         | close full review                  |

Fugitive pane:

- `-` stage or unstage the entry under the cursor
- `cc` create a commit
- `A` stage all changes
- `q` closes the full review layout through review.nvim

Commands:

| Command | What |
| ------- | ---- |
| `:ReviewNotes` | open the notes list |
| `:ReviewComment` | add a note at the cursor/selection or an explicit target |
| `:ReviewSuggestion` | add a suggestion at the cursor/selection or an explicit target |
| `:ReviewRefresh` | re-fetch PR/MR comments |
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
| `Y`       | copy only local draft/staged notes |
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

Notes persist across sessions automatically. Reference other notes by typing `#<id>` in the note body (e.g., `see #1 for context`). Referenced notes are highlighted and navigable with `gd`.

Use `:ReviewClipboard` or `y` from the notes list to copy the actionable review queue into your clipboard for LLM handoff: local notes, open threads, and discussion items. Resolved threads are left out.

Use `:ReviewClipboardLocal` or `Y` if you only want your own local draft/staged notes.

Remote review threads are shown separately from the file list in the sidebar, grouped by source such as `github/`, `gitlab/`, or `local/`.

When you create a local note while scoped to a commit, the note is stamped with that commit SHA. In `all` scope those commit-bound notes can still be surfaced, but in commit scope only matching local notes are shown. Remote GitHub/GitLab threads stay conservative: they are filtered by active file membership rather than guessed commit attribution.

If you switch branches or the remote review context becomes outdated, `:ReviewRefresh`/UI refresh will reopen the session against the current branch and move no-longer-valid notes/threads into `Stale`.

## Inspiration

Frankenstein of [afewyards/codereview.nvim](https://github.com/afewyards/codereview.nvim) and [MaraniMatias/codereview.nvim](https://github.com/MaraniMatias/codereview.nvim).

## Acknowledgments

This repo was bootstrapped with the [ellisonleao/nvim-plugin-template](https://github.com/ellisonleao/nvim-plugin-template).

## License

MIT
