1. if we collapsa a folder it moves the cursor up instead of staying there.
2. File pane top section to clutter. We should keep only the abs necessary

```
 GitButler workspace
 behind 0 upstream commit(s)
 Scope  branch · feat/review-ui-h…
 <Tab> scope  C cmp  B base
    all         0/39 workspace f39
    at  feat/review-…  0/29 gb f29
    unassigned  chan…  0/10 gb f10
 [F] Files 0/29 +9748 -1967 ▪▪▪▪▪
  ~ README.md
```

3. Opening blame panel resizes the left rail. If closed and open twice it
   resizes again.

4. We should probably remove `t` for tree view and let tree view be the default
   for the moment, and let t to be thread pane.
5. No way to go back to the split pane if we press f. We need a key non
   competing with vim visual mode that takes us back to the same position wwe were.
6.  Note panel too clunky. Let's improve the redability and reduce the number of
    suggestion by having more sensible key designs:

    ```
       Your Notes (1)
    ○ #1 README.md:19  notes

  ────────────────────────────────────────────────────────────────────────────────────────
   <CR> open  s stage  P publish  y clipboard  u unit  Y local  d delete  x resolve
   a attach  R refresh  / search  f filter  c clear filters  C clear local  b url  q close
   ? help
  ```

7. Probably use tab for cycling notes as well on thread tab.
8. Notes have a lot of unnecesary information that is not relevant or explained.
   We could simplify it even more and be more align with our files tab

```
 [T] Threads o1 d0 s0
 [all] open done stale
   - local/ [1]
     + README.md  [1] notes
```

9. Default note copy is way to verbose simplify to save tokens but pass the
   right information. It also loocks that we are copying the full diff which we
should not unless we pass a split recommendation

```
# Local Review Notes

- branch: `GitButler workspace`
- base: `6e21b777f52a71b13fcc519c9d3ef0554599ce46`
- included: 2

## Your Notes

### README.md:20 new
- id: #2
- unit: `gitbutler/workspace`
- meta: draft, suggestion
- target: `README.md:20:new`
```diff
@@ -6,34 +6,35 @@
 
 ## What it does
 
-- Dual-panel layout (file explorer + diff viewer) in its own tab
-- Embedded Fugitive status pane for worktree reviews
-- GitButler workspace detection with a read-only stack pane
+- Two-pane review layout in its own tab: navigator, threads, and diff
+- Read-only by default: no embedded staging, restore, commit, Fugitive, or GitButler mutation pane
+- GitButler workspace detection with virtual branches and unassigned changes as review units
 - Unified and side-by-side split views
 - Word-level diff highlighting
 - Explicit review scope modes: `All`, `Current Commit`, and `Select Commit`
 - Commit navigation with per-commit file and thread filtering
+- File tree and flat navigator modes, review status markers, risk sorting, and reviewed-file hiding
+- Blame side panel and file history popup from the diff
 - Inline notes on any diff line or visual selection
+- Multiple notes on the same line
 - Suggestion notes with GitHub-compatible `suggestion` blocks
-- Notes list panel with draft/staged/published workflow
-- Note persistence across sessions
-- Grouped thread queue for GitHub/GitLab and local notes
+- Notes list panel with draft/staged/resolved/published workflow, search, filters, and per-unit copy
+- Note, review-status, and UI preference persistence across sessions
+- Grouped thread queue for GitHub/GitLab, PR/MR summary context, stale threads, and local notes
 - Stale notes/threads surfaced separately when files disappear or remote review context goes stale
 - Reference other notes with `#<id>` syntax
-- Export notes to markdown
-- Copy all notes to the clipboard for LLM handoff
+- Export notes to markdown and copy rich handoff packets to the clipboard
 - Configurable keymaps
 - Colorblind-friendly color scheme (enabled by default)
 - `:checkhealth review`
 
 ## Requirements
 
-- Neovim >= 0.9.0
+- Neovim >= 0.10.0
 - `git`
-- `vim-fugitive` (https://github.com/tpope/vim-fugitive) for the embedded git status pane
-- `but` CLI (https://docs.gitbutler.com/cli-overview) for GitButler workspace support
-- `gh` CLI (https://cli.github.com) for GitHub PR features
-- `glab` CLI (https://gitlab.com/gitlab-org/cli) for GitLab MR features
+- `but` CLI (https://docs.gitbutler.com/cli-overview) for GitButler workspace support, optional
+- `gh` CLI (https://cli.github.com) for GitHub PR features, optional
+- `glab` CLI (https://gitlab.com/gitlab-org/cli) for GitLab MR features, optional
 - `plenary.nvim` for tests
 
 You only need `gh` or `glab` for the forge you use.
```
```suggestion
- Suggestion notes with GitHub-compatible `suggestion` blocks
```


### README.md:20 old
- id: #3
- unit: `gitbutler/workspace`
- meta: draft, comment
- target: `README.md:20:old`
```diff
@@ -6,34 +6,35 @@
 
 ## What it does
 
-- Dual-panel layout (file explorer + diff viewer) in its own tab
-- Embedded Fugitive status pane for worktree reviews
-- GitButler workspace detection with a read-only stack pane
+- Two-pane review layout in its own tab: navigator, threads, and diff
+- Read-only by default: no embedded staging, restore, commit, Fugitive, or GitButler mutation pane
+- GitButler workspace detection with virtual branches and unassigned changes as review units
 - Unified and side-by-side split views
 - Word-level diff highlighting
 - Explicit review scope modes: `All`, `Current Commit`, and `Select Commit`
 - Commit navigation with per-commit file and thread filtering
+- File tree and flat navigator modes, review status markers, risk sorting, and reviewed-file hiding
+- Blame side panel and file history popup from the diff
 - Inline notes on any diff line or visual selection
+- Multiple notes on the same line
 - Suggestion notes with GitHub-compatible `suggestion` blocks
-- Notes list panel with draft/staged/published workflow
-- Note persistence across sessions
-- Grouped thread queue for GitHub/GitLab and local notes
+- Notes list panel with draft/staged/resolved/published workflow, search, filters, and per-unit copy
+- Note, review-status, and UI preference persistence across sessions
+- Grouped thread queue for GitHub/GitLab, PR/MR summary context, stale threads, and local notes
 - Stale notes/threads surfaced separately when files disappear or remote review context goes stale
 - Reference other notes with `#<id>` syntax
-- Export notes to markdown
-- Copy all notes to the clipboard for LLM handoff
+- Export notes to markdown and copy rich handoff packets to the clipboard
 - Configurable keymaps
 - Colorblind-friendly color scheme (enabled by default)
 - `:checkhealth review`
 
 ## Requirements
 
-- Neovim >= 0.9.0
+- Neovim >= 0.10.0
 - `git`
-- `vim-fugitive` (https://github.com/tpope/vim-fugitive) for the embedded git status pane
-- `but` CLI (https://docs.gitbutler.com/cli-overview) for GitButler workspace support
-- `gh` CLI (https://cli.github.com) for GitHub PR features
-- `glab` CLI (https://gitlab.com/gitlab-org/cli) for GitLab MR features
+- `but` CLI (https://docs.gitbutler.com/cli-overview) for GitButler workspace support, optional
+- `gh` CLI (https://cli.github.com) for GitHub PR features, optional
+- `glab` CLI (https://gitlab.com/gitlab-org/cli) for GitLab MR features, optional
 - `plenary.nvim` for tests
 
 You only need `gh` or `glab` for the forge you use.
```
Note
```1

10. We should only have navigation possible on the text such that people can
    ccopy the code with visual block and not copy the line numbers or anything.
11. Line number differece color should be standarize: currently file pane has a
    dimmmed version but bottom bar does not
12. If we press B it just says GitButler review base comes from workspace
    metadata which is not useful or what we intended.
