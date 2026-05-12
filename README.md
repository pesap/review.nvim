# review.nvim

Minimal code review plugin for Neovim.

> This plugin was vibe-coded to scratch my own itch. It works for me but might be rough around the edges. PRs are welcome, though more mature alternatives like [afewyards/codereview.nvim](https://github.com/afewyards/codereview.nvim) and [MaraniMatias/codereview.nvim](https://github.com/MaraniMatias/codereview.nvim) probably already have what you need. This project borrows ideas from both.

## What it does

- Dual-panel layout (file explorer + diff viewer) in its own tab
- Unified and side-by-side split views
- Word-level diff highlighting
- Commit navigation with per-commit file filtering
- Inline notes on any diff line or visual selection
- Suggestion notes with GitHub-compatible `suggestion` blocks
- Notes list panel with draft/staged/published workflow
- Note persistence across sessions
- Live Hunk session integration with inline note mirroring
- Reference other notes with `#<id>` syntax
- Export notes to markdown
- Copy all notes to the clipboard for LLM handoff
- Configurable keymaps
- Colorblind-friendly color scheme (enabled by default)
- `:checkhealth review`

## Requirements

- Neovim >= 0.9.0
- `git`
- `gh` CLI (https://cli.github.com) for GitHub PR features
- `glab` CLI (https://gitlab.com/gitlab-org/cli) for GitLab MR features
- `plenary.nvim` for tests

You only need `gh` or `glab` for the forge you use. The optional Hunk viewer requires the `hunk` CLI from `hunkdiff`.

## Install

lazy.nvim:

```lua
{ "pesap/review.nvim", config = function() require("review").setup() end }
```

## Usage

```vim
:Review              " unstaged changes
:Review HEAD~3       " diff against a ref (shows commits)
:Review main         " diff against main
:ReviewToggle        " open/close
:ReviewHelp          " open review help
:ReviewHunk          " open or reload Hunk for the current review
:ReviewNotes         " open notes list from anywhere
:ReviewComment       " add note at current Hunk location (or pass path/line)
:ReviewSuggestion    " add suggestion at current Hunk location
:ReviewExport        " export notes to markdown
:ReviewClipboard     " copy all notes to the clipboard
:ReviewClearLocal    " clear all local notes after confirmation
```

You can also call `toggle()` from a keymap:

```lua
vim.keymap.set("n", "<leader>rr", "<cmd>ReviewToggle<cr>", { desc = "Toggle review" })
```

## Config

```lua
require("review").setup({
  view = "unified",       -- "unified" or "split" for the native viewer
  viewer = "native",      -- "native" or "hunk"
  hunk = {
    mode = "session",     -- "session" = full Hunk UI, "companion" = keep native UI and sync to any live Hunk session
  },
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
  vcs_mode = "auto",      -- "auto" | "git" | "gitlab" | "gitbutler" for navigator history labels
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
    next_note = "]n",
    prev_note = "[n",
    toggle_split = "s",
    notes_list = "N",
    suggestion = "S",
    close = "q",
  },
})
```

## Hunk viewer

To use [Hunk](https://github.com/modem-dev/hunk) as the diff surface:

```bash
npm i -g hunkdiff
```

```lua
require("review").setup({
  viewer = "hunk",
})
```

With `viewer = "hunk"`, `:Review` opens or reloads a Hunk session for the current repo while `review.nvim` keeps the draft/staged/publish workflow in Neovim. `:Review HEAD~3` forwards the ref to `hunk diff HEAD~3`.

When a PR/MR is detected:

- `:ReviewRefresh` fetches GitHub/GitLab threads and mirrors inline comments into the live Hunk session
- `:ReviewComment` and `:ReviewSuggestion` create review notes from the current Hunk selection
- `:ReviewNotes` opens the notes list so you can stage, publish, refresh, and inspect threads

You can also target a location explicitly:

```vim
:ReviewComment README.md:103
:ReviewComment lua/review.lua 42 old
```

`review.nvim` treats Hunk's inline comments as a projection of the current plugin session, so refreshing or re-syncing rewrites the Hunk overlay from the plugin's note state.

## Hunk companion mode

If you want faster startup and native note handling, keep the native viewer and use Hunk as a companion instead of the primary UI:

```lua
require("review").setup({
  viewer = "native",
  hunk = {
    mode = "companion",
  },
})
```

In companion mode:

- `:Review` stays in the native `review.nvim` diff UI
- note creation, staging, publishing, and navigation stay entirely in the native buffers
- `:ReviewHunk` opens Hunk on demand for the current review range
- if a live Hunk session already exists for the repo, `review.nvim` mirrors notes into it automatically

This is the fast path if you want Hunk available without paying the cost of launching its full TUI on every review open.

## Keymaps

Explorer: `<CR>` select, `N` notes list, `?` help, `q` close full review

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
| `]n` / `[n` | next/prev note                     |
| `s`         | toggle split                       |
| `q`         | close full review                  |

Hunk viewer:

| Command | What |
| ------- | ---- |
| `:ReviewHunk` | open or reload Hunk for the current review |
| `:ReviewComment` | add a note at the selected Hunk |
| `:ReviewSuggestion` | add a suggestion at the selected Hunk |
| `:ReviewNotes` | open the notes list |
| `:ReviewClipboard` | copy all notes and remote threads to the clipboard |
| `:ReviewClearLocal` | clear all local notes after confirmation |
| `:ReviewRefresh` | re-fetch PR/MR comments and re-sync the Hunk overlay |

Notes list:

| Key       | What                              |
| --------- | --------------------------------- |
| `j` / `k` | navigate between notes            |
| `<CR>`    | jump to note in diff              |
| `dd`      | delete note                       |
| `s`       | toggle draft/staged               |
| `P`       | publish all staged notes          |
| `y`       | copy all notes to the clipboard   |
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

Use `:ReviewClipboard` or `y` from the notes list to copy the full current review bundle, including local notes and remote GitHub/GitLab threads, into your clipboard for LLM handoff.

## Inspiration

Frankenstein of [afewyards/codereview.nvim](https://github.com/afewyards/codereview.nvim) and [MaraniMatias/codereview.nvim](https://github.com/MaraniMatias/codereview.nvim).

## Acknowledgments

This repo was bootstrapped with the [ellisonleao/nvim-plugin-template](https://github.com/ellisonleao/nvim-plugin-template).

## License

MIT
