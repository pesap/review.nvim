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
- Notes list panel, jump between notes across files
- Export notes to markdown
- Configurable keymaps
- Colorblind-friendly color scheme option
- `:checkhealth review`

## Requirements

- Neovim >= 0.9.0
- `git`
- `gh` CLI (https://cli.github.com) for future PR features
- `plenary.nvim` for tests

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

## Config

```lua
require("review").setup({
  view = "unified",       -- "unified" or "split"
  colorblind = false,     -- blue/yellow instead of red/green
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

Notes list: `j`/`k` navigate, `<CR>` jump, `dd` delete, `q` close

Note editor: `<C-s>` or `:wq` save, `<Esc>` cancel

## Inspiration

Frankenstein of [afewyards/codereview.nvim](https://github.com/afewyards/codereview.nvim) and [MaraniMatias/codereview.nvim](https://github.com/MaraniMatias/codereview.nvim).

## License

MIT
