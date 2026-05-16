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
    table.insert(
      lines,
      vim.fn.strdisplaywidth(title) > content_width and title:sub(1, math.max(content_width - 3, 1)) .. "..." or title
    )
  end

  table.insert(
    lines,
    vim.fn.strdisplaywidth("review.nvim                                                        *review-help*")
          > content_width
        and "review.nvim  *review-help*"
      or "review.nvim                                                        *review-help*"
  )
  for _, wrapped in ipairs(wrap_text("Press keys in the focused review pane. Use q or <Esc> to close this help.")) do
    table.insert(lines, wrapped)
  end

  add_section("NAVIGATOR                                              *review-navigator-keys*")
  add_item("<CR>", "open file, thread, directory, or scope")
  add_item(km.focus_files, "focus files")
  add_item(km.focus_threads, "focus threads")
  add_item(km.focus_diff, "return to diff")
  add_item(km.toggle_stack, "cycle scope")
  add_item(km.commit_details, "commit details")
  add_item(km.compare_unit, "compare explorer")
  add_item("u", "copy handoff for selected unit")
  add_item("r", "toggle reviewed status")
  add_item("za", "expand/collapse row")
  if km.toggle_file_tree then
    add_item(km.toggle_file_tree, "tree/flat files")
  end
  add_item(km.sort_files, "cycle sort")
  add_item(km.toggle_reviewed, "hide/show reviewed")
  add_item(km.filter_attention, "attention filter")
  add_item("/", "filter files")
  add_item("c", "clear filter")
  add_item(km.refresh, "refresh")
  add_item(km.notes_list, "notes list")
  add_item(km.help, "help")
  add_item(km.close, "close review")

  add_section("DIFF                                                    *review-diff-keys*")
  add_item(km.add_note, "add note")
  add_item(km.suggestion, "add suggestion")
  add_item(km.edit_note, "edit note")
  add_item(km.delete_note, "delete note")
  add_item(km.next_hunk, "next hunk")
  add_item(km.prev_hunk, "previous hunk")
  add_item(km.next_file, "next file")
  add_item(km.prev_file, "previous file")
  if km.next_note_short then
    add_item(km.next_note_short, "next note")
  end
  add_item(km.next_note, "next note")
  add_item(km.prev_note, "previous note")
  add_item(km.toggle_split, "unified/split")
  add_item(km.blame, "blame panel")
  add_item(km.file_history, "file history")
  add_item(km.focus_files, "focus files")
  add_item(km.focus_threads, "focus threads")
  add_item(km.refresh, "refresh")
  add_item(km.notes_list, "notes list")
  add_item("<CR>", "open thread/edit note under cursor")

  add_section("REVIEW                                                   *review-actions*")
  add_item(km.change_base, "change base")
  add_item(km.mark_baseline, "mark baseline")
  add_item(km.compare_baseline, "compare baseline")
  add_item(km.compare_unit, "compare explorer")
  add_item("r", "toggle reviewed status")
  add_item("t", "toggle blame side")
  add_item("a", "attach blame/history context")

  add_section("NOTES                                                   *review-notes-keys*")
  add_item("<CR>", "open location/thread")
  add_item("s", "draft/staged")
  add_item("P", "publish staged")
  add_item("y", "copy all review notes")
  add_item("Y", "copy local notes")
  add_item("u", "copy note handoff")
  add_item("d", "delete local note")
  add_item("R", "refresh comments")
  add_item("C", "clear local notes")
  add_item("gd", "jump to #note reference")
  add_item("b", "open remote URL")
  add_item("q", "close")
  add_item("?", "help")

  add_section("COMMANDS                                                *review-commands*")
  add_item(":Review [ref]", "open review")
  add_item(":ReviewClose", "close review")
  add_item(":ReviewToggle", "toggle review")
  add_item(":ReviewRefresh", "refresh")
  add_item(":ReviewNotes", "notes list")
  add_item(":ReviewComment [target]", "add note")
  add_item(":ReviewSuggestion [target]", "add suggestion")
  add_item(":ReviewChangeBase [ref]", "change base")
  add_item(":ReviewMarkBaseline", "mark baseline")
  add_item(":ReviewCompareBaseline", "compare baseline")
  add_item(":ReviewCompare", "compare explorer")
  add_item(":ReviewBack", "return from compare")
  add_item(":ReviewCompareUnit [idx]", "compare review units")
  add_item(":ReviewClipboard", "copy all review notes")
  add_item(":ReviewClipboardLocal", "copy local notes")
  add_item(":ReviewClearLocal", "clear local notes")
  add_item(":ReviewExport [path]", "export markdown")
  add_item(":ReviewHelp", "help")

  add_section("TOOLS                                                   *review-tools*")
  if vim.fn.executable("git") == 1 then
    add_item("git", "available")
  else
    add_item("git", "missing: install git")
  end

  local git = require("review.git")
  local remote = git.parse_remote()
  local forge_name = remote and remote.forge or nil
  if forge_name == "github" or not forge_name then
    if vim.fn.executable("gh") == 1 then
      add_item("GitHub", "available: gh")
    else
      add_item("GitHub", "missing: install gh for PR comments")
    end
  end
  if forge_name == "gitlab" or not forge_name then
    if vim.fn.executable("glab") == 1 then
      add_item("GitLab", "available: glab")
    else
      add_item("GitLab", "missing: install glab for MR comments")
    end
  end
  if vim.fn.executable("but") == 1 then
    add_item("GitButler", "available: but")
  else
    add_item("GitButler", "missing: install but for virtual branches")
  end

  open_centered_scratch(lines, " Review Help ", width, math.min(#lines, vim.o.lines - 6))
end

return M
