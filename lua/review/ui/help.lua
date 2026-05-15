--- Contextual help popup for review.nvim.
local highlights = require("review.ui.highlights")

local M = {}

local HL = highlights.groups

---@param lines string[]
---@param title string
---@param width number|nil
---@param height number|nil
local function open_centered_scratch(lines, title, width, height)
  width = width or math.min(90, math.max(50, math.floor(vim.o.columns * 0.7)))
  height = height or math.min(#lines, math.max(8, math.floor(vim.o.lines * 0.7)))
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "center",
  })

  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
  vim.wo[win].cursorlineopt = "line"
  vim.wo[win].winhighlight = table.concat({
    "NormalFloat:",
    HL.float_bg,
    ",FloatBorder:",
    HL.window_edge,
    ",FloatTitle:",
    HL.panel_title,
    ",CursorLine:",
    HL.cursorline,
  })

  vim.keymap.set("n", "q", function()
    vim.api.nvim_win_close(win, true)
  end, { buffer = buf, silent = true })
  vim.keymap.set("n", "<Esc>", function()
    vim.api.nvim_win_close(win, true)
  end, { buffer = buf, silent = true })
end

function M.open()
  local km = require("review").config.keymaps
  local width = math.min(92, vim.o.columns - 6)
  local lines = {}
  local content_width = math.max(width - 2, 20)

  local function wrap_text(text, indent)
    indent = indent or ""
    local _max_width = math.max(content_width - vim.fn.strdisplaywidth(indent), 8)
    local out = {}
    local current = indent

    for word in text:gmatch("%S+") do
      local candidate = current == indent and (indent .. word) or (current .. " " .. word)
      if current ~= indent and vim.fn.strdisplaywidth(candidate) > content_width then
        table.insert(out, current)
        current = indent .. word
      else
        current = candidate
      end
    end

    if current ~= indent then
      table.insert(out, current)
    end
    if #out == 0 then
      table.insert(out, indent)
    end
    return out
  end

  local function add_item(lhs, rhs)
    if not lhs then
      return
    end
    local base = "  " .. lhs
    local target_col = 24
    local gap = math.max(2, target_col - vim.fn.strdisplaywidth(base))
    local one_line = base .. string.rep(" ", gap) .. rhs
    if vim.fn.strdisplaywidth(one_line) <= content_width then
      table.insert(lines, one_line)
      return
    end

    table.insert(lines, base)
    for _, wrapped in ipairs(wrap_text(rhs, "      ")) do
      table.insert(lines, wrapped)
    end
  end

  local function add_section(title)
    if #lines > 0 then
      table.insert(lines, "")
    end
    table.insert(lines, title)
  end

  add_section("Commands")
  add_item(":Review [ref]", "Open review for working tree or ref")
  add_item(":ReviewClose", "Close the full review layout")
  add_item(":ReviewToggle", "Toggle the review layout")
  add_item(":ReviewHelp", "Open this help")
  add_item(":ReviewNotes", "Open the notes list")
  add_item(":ReviewClipboard", "Copy local notes, open threads, and discussion")
  add_item(":ReviewClipboardLocal", "Copy only local notes to the clipboard")
  add_item(":ReviewClearLocal", "Clear all local notes after confirmation")
  add_item(":ReviewRefresh", "Refresh review data")
  add_item(":ReviewChangeBase [ref]", "Re-diff the active local review against another base")
  add_item(":ReviewMarkBaseline", "Save current HEAD as the before-fix baseline")
  add_item(":ReviewCompareBaseline", "Compare current work against the saved baseline")
  add_item(":ReviewCompareUnit [idx]", "Compare selected/current review unit with another unit")
  add_item(":ReviewComment", "Add a note")
  add_item(":ReviewSuggestion", "Add a suggestion")
  add_item(":ReviewExport [path]", "Export notes to markdown")

  add_section("Explorer")
  add_item(km.close, "Close the full review layout")
  add_item(km.help, "Open this help")
  add_item(km.notes_list, "Open notes list")
  add_item("u", "Copy handoff packet for selected review unit")
  add_item(km.focus_files, "Focus Files section")
  add_item(km.focus_diff, "Focus Diff section")
  add_item(km.toggle_file_tree, "Toggle tree/flat file layout")
  add_item(km.sort_files, "Cycle file sort: path, risk, overlap, notes, size, unreviewed")
  add_item(km.toggle_reviewed, "Hide or show reviewed files")
  add_item(km.filter_attention, "Filter files by attention flag")
  add_item("/", "Search files, notes, and commit messages")
  add_item("c", "Clear file search")
  add_item(km.focus_threads, "Focus Threads section")
  add_item(km.toggle_stack, "Cycle stack/commit scope")
  add_item(km.commit_details, "Open commit details for the selected commit")
  add_item(km.change_base, "Change review base")
  add_item(km.mark_baseline, "Mark before-fix baseline")
  add_item(km.compare_baseline, "Compare against marked baseline")
  add_item(km.compare_unit, "Compare review units")
  add_item(km.refresh, "Refresh review data")
  add_item("<CR>", "Open file or thread")

  add_section("Diff")
  add_item(km.add_note, "Add note")
  add_item(km.suggestion, "Add suggestion")
  add_item(km.edit_note, "Edit note")
  add_item(km.delete_note, "Delete note")
  add_item(km.next_hunk, "Next hunk")
  add_item(km.prev_hunk, "Previous hunk")
  add_item(km.next_file, "Next file")
  add_item(km.prev_file, "Previous file")
  if km.next_note_short then
    add_item(km.next_note_short, "Next note")
  end
  add_item(km.next_note, "Next note")
  add_item(km.prev_note, "Previous note")
  add_item(km.toggle_split, "Toggle unified/split view")
  add_item(km.focus_files, "Focus Files section")
  add_item(km.focus_diff, "Focus Diff section")
  add_item(km.toggle_file_tree, "Toggle tree/flat file layout")
  add_item(km.sort_files, "Cycle file sort")
  add_item(km.toggle_reviewed, "Hide or show reviewed files")
  add_item(km.filter_attention, "Cycle attention filter")
  add_item("/", "Search files, notes, and commit messages")
  add_item("c", "Clear file search")
  add_item(km.focus_threads, "Focus Threads section")
  add_item(km.toggle_stack, "Cycle stack/commit scope")
  add_item(km.commit_details, "Open current commit details")
  add_item(km.change_base, "Change review base")
  add_item(km.mark_baseline, "Mark before-fix baseline")
  add_item(km.compare_baseline, "Compare against marked baseline")
  add_item(km.compare_unit, "Compare review units")
  add_item(km.refresh, "Refresh review data")
  add_item(km.notes_list, "Open notes list")
  add_item(km.close, "Close the full review layout")
  add_item(km.help, "Open this help")
  add_item("<CR>", "Open thread or edit note under cursor")

  add_section("Review Status")
  add_item("r", "Cycle file status: unreviewed, reviewed, needs-agent, blocked, resolved")
  add_item("za", "Expand or collapse inline note rows under a file")
  add_item("b", "Open blame side panel from the diff")
  add_item("t", "Toggle blame between base and head inside the blame panel")
  add_item("a", "Attach selected blame/history row to the next note")
  add_item("L", "Open file history from the diff")

  add_section("Notes List")
  add_item("<CR>", "Open note location or thread")
  add_item("s", "Toggle draft/staged")
  add_item("P", "Publish staged notes")
  add_item("y", "Copy local notes, open threads, and discussion")
  add_item("u", "Copy handoff packet for this note's review unit")
  add_item("Y", "Copy only local notes to the clipboard")
  add_item("R", "Refresh remote comments")
  add_item("C", "Clear all local notes")
  add_item("gd", "Jump to #note references")
  add_item("b", "Open remote URL")
  add_item("q", "Close")
  add_item("?", "Open this help")

  add_section("Availability")
  if vim.fn.executable("git") == 1 then
    add_item("git", "available")
  else
    add_item("git", "unavailable: install git from https://git-scm.com/")
  end

  local git = require("review.git")
  local remote = git.parse_remote()
  local forge_name = remote and remote.forge or nil
  if forge_name == "github" or not forge_name then
    if vim.fn.executable("gh") == 1 then
      add_item("GitHub", "available with gh; run `gh auth status` if publish or refresh fails")
    else
      add_item("GitHub", "unavailable: install gh from https://cli.github.com/ to refresh/publish PR comments")
    end
  end
  if forge_name == "gitlab" or not forge_name then
    if vim.fn.executable("glab") == 1 then
      add_item("GitLab", "available with glab; run `glab auth status` if publish or refresh fails")
    else
      add_item(
        "GitLab",
        "unavailable: install glab from https://gitlab.com/gitlab-org/cli to refresh/publish MR comments"
      )
    end
  end
  if vim.fn.executable("but") == 1 then
    add_item("GitButler", "available with but CLI")
  else
    add_item("GitButler", "unavailable: install but CLI to review GitButler virtual branches")
  end

  open_centered_scratch(lines, " Review Help ", width, math.min(#lines, vim.o.lines - 6))
end

return M
