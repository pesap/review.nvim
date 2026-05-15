--- Blame side panel for review.nvim.
local state = require("review.state")

local M = {}

---@param text string
---@param max_width number
---@return string
local function truncate_end_text(text, max_width)
  if max_width <= 0 then
    return ""
  end
  if vim.fn.strdisplaywidth(text) <= max_width then
    return text
  end
  local prefix = ""
  local chars = vim.fn.strchars(text)
  for i = 1, chars do
    local next_prefix = prefix .. vim.fn.strcharpart(text, i - 1, 1)
    if vim.fn.strdisplaywidth(next_prefix .. "\u{2026}") > max_width then
      break
    end
    prefix = next_prefix
  end
  return prefix .. "\u{2026}"
end

---@param win number
local function apply_pane_style(win)
  local HL = require("review.ui.highlights").groups
  vim.wo[win].winhighlight = table.concat({
    "Normal:",
    HL.pane_bg,
    ",EndOfBuffer:",
    HL.pane_bg,
    ",SignColumn:",
    HL.pane_bg,
    ",StatusLine:",
    HL.pane_bg,
    ",StatusLineNC:",
    HL.pane_bg,
    ",WinSeparator:",
    HL.window_edge,
    ",CursorLine:",
    HL.cursorline,
  })
  vim.wo[win].fillchars = "eob: "
  vim.api.nvim_set_option_value("statusline", " ", { scope = "local", win = win })
end

---@return number
local function create_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "review://blame")
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "review-blame"
  return buf
end

local function valid_win(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function set_scrollbind(win, enabled)
  if valid_win(win) then
    vim.wo[win].scrollbind = enabled
  end
end

local function sync_blame_scroll(ui_state)
  if not ui_state then
    return
  end

  local diff_win = ui_state.diff_win
  local split_win = ui_state.split_win
  local blame_win = ui_state.blame_win
  set_scrollbind(diff_win, true)
  set_scrollbind(split_win, true)
  set_scrollbind(blame_win, true)

  if valid_win(diff_win) and valid_win(blame_win) then
    local view
    vim.api.nvim_win_call(diff_win, function()
      view = vim.fn.winsaveview()
    end)
    if view then
      vim.api.nvim_win_call(blame_win, function()
        vim.fn.winrestview({ topline = view.topline, leftcol = view.leftcol })
      end)
    end
  end
  pcall(vim.cmd, "syncbind")
end

local function restore_diff_scrollbind(ui_state)
  if not ui_state then
    return
  end
  local split_active = ui_state.view_mode == "split" and valid_win(ui_state.split_win)
  set_scrollbind(ui_state.diff_win, split_active)
  set_scrollbind(ui_state.split_win, split_active)
end

function M.close()
  local ui_state = state.get_ui()
  if not ui_state then
    return
  end
  if ui_state.blame_win and vim.api.nvim_win_is_valid(ui_state.blame_win) then
    vim.api.nvim_win_close(ui_state.blame_win, true)
  end
  ui_state.blame_win = nil
  ui_state.blame_buf = nil
  restore_diff_scrollbind(ui_state)
end

---@param file ReviewFile
---@param ref string|nil
---@param mode "base"|"head"
---@param lines string[]|nil
---@param opts table
local function open_panel(file, ref, mode, lines, opts)
  local ui_state = state.get_ui()
  if not ui_state or not file then
    return
  end
  if ui_state.blame_win and vim.api.nvim_win_is_valid(ui_state.blame_win) then
    return
  end

  opts = opts or {}
  local queue_context = opts.queue_context or function() end
  local blame_lines = { " Blame " .. mode .. ": " .. tostring(ref or "HEAD") }
  local previous_meta = nil
  for _, line in ipairs(lines or {}) do
    local sha, author_date, code = line:match("^(%S+)%s+%((.-)%s+%d+%)%s?(.*)$")
    if sha and author_date then
      local meta = string.format("%-8s %s", sha:sub(1, 8), truncate_end_text(author_date or "", 18))
      if meta == previous_meta then
        meta = string.rep(" ", vim.fn.strdisplaywidth(meta))
      else
        previous_meta = meta
      end
      table.insert(blame_lines, string.format(" %s %s", meta, code or ""))
    else
      previous_meta = nil
      table.insert(blame_lines, line)
    end
  end

  local original = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(ui_state.diff_win)
  vim.cmd("leftabove vsplit")
  local win = vim.api.nvim_get_current_win()
  local buf = create_buf()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_width(win, 40)
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
  apply_pane_style(win)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, blame_lines)
  vim.bo[buf].modifiable = false
  ui_state.blame_win = win
  ui_state.blame_buf = buf
  sync_blame_scroll(ui_state)

  local keymap_opts = { buffer = buf, noremap = true, silent = true }
  vim.keymap.set("n", "b", M.close, keymap_opts)
  vim.keymap.set("n", "<Esc>", M.close, keymap_opts)
  vim.keymap.set("n", "q", M.close, keymap_opts)
  vim.keymap.set("n", "t", function()
    local next_mode = mode == "base" and "head" or "base"
    M.close()
    M.open(file, opts, next_mode)
  end, keymap_opts)
  vim.keymap.set("n", "a", function()
    local row = vim.api.nvim_win_get_cursor(win)[1]
    local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
    if line and not line:match("^%s*Blame ") then
      queue_context("blame_context", line)
    end
  end, keymap_opts)
  if vim.api.nvim_win_is_valid(original) then
    vim.api.nvim_set_current_win(original)
  end
end

---@param file ReviewFile|nil
---@param opts table
---@param mode "base"|"head"|nil
function M.open(file, opts, mode)
  opts = opts or {}
  local ui_state = state.get_ui()
  if not ui_state or not file then
    return
  end

  local git = require("review.git")
  local s = state.get()
  mode = mode or "base"
  local ref = nil
  if mode ~= "head" then
    ref = s and s.base_ref or nil
  end
  local request_token = opts.next_request_token and opts.next_request_token() or nil
  vim.notify("Loading blame...", vim.log.levels.INFO)
  if git.blame_async then
    git.blame_async(ref, file.path, function(lines, err)
      if opts.request_is_current and not opts.request_is_current(request_token) then
        return
      end
      if not lines then
        vim.notify("Could not load blame: " .. (err or "unknown"), vim.log.levels.WARN)
        return
      end
      open_panel(file, ref, mode, lines, opts)
    end)
  else
    local lines, err = git.blame(ref, file.path)
    if not lines then
      vim.notify("Could not load blame: " .. (err or "unknown"), vim.log.levels.WARN)
      return
    end
    open_panel(file, ref, mode, lines, opts)
  end
end

---@param file ReviewFile|nil
---@param opts table
function M.toggle(file, opts)
  opts = opts or {}
  local ui_state = state.get_ui()
  if not ui_state or not file then
    return
  end
  if ui_state.blame_win and vim.api.nvim_win_is_valid(ui_state.blame_win) then
    M.close()
    return
  end
  M.open(file, opts, "base")
end

return M
