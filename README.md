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
- Reference other notes with `#<id>` syntax
- Export notes to markdown
- Configurable keymaps
- Colorblind-friendly color scheme (enabled by default)
- `:checkhealth review`

## Requirements

- Neovim >= 0.9.0
- `git`
- `gh` CLI (https://cli.github.com) for GitHub PR features
- `glab` CLI (https://gitlab.com/gitlab-org/cli) for GitLab MR features
- `plenary.nvim` for tests

You only need `gh` or `glab` for the forge you use.

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
:ReviewExport        " export notes to markdown
```

You can also call `toggle()` from a keymap:

```lua
vim.keymap.set("n", "<leader>rr", "<cmd>ReviewToggle<cr>", { desc = "Toggle review" })
```

## Config

```lua
require("review").setup({
  view = "unified",       -- "unified" or "split"
  colorblind = true,      -- blue/yellow scheme (default), set false for red/green
  provider = nil,         -- "github" | "gitlab" | nil (auto-detect from origin URL)
  keymaps = {
    add_note = "a",
    edit_note = "e",
    delete_note = "d",
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

## Keymaps

Explorer: `<CR>` select, `q` close, `N` notes list

Diff viewer:

| Key | What |
|-----|------|
| `a` | add note (normal or visual) |
| `S` | suggestion note (normal or visual) |
| `e` | edit note |
| `d` | delete note |
| `N` | notes list |
| `]c` / `[c` | next/prev hunk |
| `]f` / `[f` | next/prev file |
| `]n` / `[n` | next/prev note |
| `s` | toggle split |
| `q` | close |

Notes list:

| Key | What |
|-----|------|
| `j` / `k` | navigate between notes |
| `<CR>` | jump to note in diff |
| `dd` | delete note |
| `p` | toggle draft/staged |
| `P` | publish all staged notes |
| `C` | clear all notes |
| `gd` | jump to referenced note (`#<id>`) |
| `q` | close |

Note editor: `<C-s>` or `:wq` save, `<Esc>` cancel

## Notes workflow

Notes go through three stages:

1. **Draft** (`-`) — newly created notes start here
2. **Staged** (`+`) — press `p` to mark a note as ready to publish
3. **Published** (`*`) — press `P` to publish all staged notes

Notes persist across sessions automatically. Reference other notes by typing `#<id>` in the note body (e.g., `see #1 for context`). Referenced notes are highlighted and navigable with `gd`.

## Inspiration

Frankenstein of [afewyards/codereview.nvim](https://github.com/afewyards/codereview.nvim) and [MaraniMatias/codereview.nvim](https://github.com/MaraniMatias/codereview.nvim).

## Acknowledgments

This repo was bootstrapped with the [ellisonleao/nvim-plugin-template](https://github.com/ellisonleao/nvim-plugin-template).

## License

MIT
