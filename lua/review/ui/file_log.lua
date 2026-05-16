--- File history popup for review.nvim.
local M = {}

local HL = require("review.ui.highlights").groups

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

---@param scale number|nil
---@param cap number|nil
---@return number width, number col
local function float_dimensions(scale, cap)
  scale = scale or 0.7
  cap = cap or 90
  local cols = vim.o.columns
  local w
  if cols < 60 then
    w = cols - 4
  elseif cols < 100 then
    w = math.floor(cols * 0.85)
  else
    w = math.min(math.floor(cols * scale), cap)
  end
  return w, math.floor((cols - w) / 2)
end

---@param win number
local function apply_float_style(win)
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
end

---@param file ReviewFile|nil
---@param lines string[]
---@param opts table
local function open_popup(file, lines, opts)
  if not file then
    return
  end
  opts = opts or {}
  local git = require("review.git")
  local queue_context = opts.queue_context or function() end
  if #lines == 0 then
    lines = { "(no history)" }
  end

  local display = { " File history: " .. file.path, "" }
  local line_to_sha = {}
  for _, line in ipairs(lines) do
    local sha, date, author, msg = line:match("^([^\t]+)\t([^\t]+)\t([^\t]+)\t(.*)$")
    if sha then
      table.insert(display, string.format(" %-8s %-10s %-14s %s", sha, date, truncate_end_text(author, 14), msg))
      line_to_sha[#display] = sha
    else
      table.insert(display, line)
    end
  end

  local width, col = float_dimensions(0.75, 110)
  local height = math.min(#display, math.floor(vim.o.lines * 0.7))
  local row = math.floor((vim.o.lines - height) / 2)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, display)
  vim.bo[buf].modifiable = false
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " File History ",
    title_pos = "center",
  })
  apply_float_style(win)
  vim.wo[win].cursorline = true

  local opts = { buffer = buf, noremap = true, silent = true }
  vim.keymap.set("n", "q", function()
    vim.api.nvim_win_close(win, true)
  end, opts)
  vim.keymap.set("n", "<Esc>", function()
    vim.api.nvim_win_close(win, true)
  end, opts)
  vim.keymap.set("n", "a", function()
    local row_nr = vim.api.nvim_win_get_cursor(win)[1]
    local line = vim.api.nvim_buf_get_lines(buf, row_nr - 1, row_nr, false)[1]
    if line and line_to_sha[row_nr] then
      queue_context("log_context", line)
    end
  end, opts)
  vim.keymap.set("n", "<CR>", function()
    local sha = line_to_sha[vim.api.nvim_win_get_cursor(win)[1]]
    if not sha then
      return
    end

    local function render_diff(diff_text)
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      local diff_lines = vim.split(diff_text or "", "\n")
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, diff_lines)
      vim.bo[buf].modifiable = false
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_set_cursor(win, { 1, 0 })
      end
    end

    if git.file_show_async then
      local request_token = opts.next_request_token and opts.next_request_token() or nil
      vim.notify("Loading file diff...", vim.log.levels.INFO)
      git.file_show_async(sha, file.path, function(diff_text, err)
        if opts.request_is_current and not opts.request_is_current(request_token) then
          return
        end
        if not diff_text then
          vim.notify("Could not load file diff: " .. (err or "unknown"), vim.log.levels.WARN)
          return
        end
        render_diff(diff_text)
      end)
    else
      local diff_text, err = git.file_show(sha, file.path)
      if not diff_text then
        vim.notify("Could not load file diff: " .. (err or "unknown"), vim.log.levels.WARN)
        return
      end
      render_diff(diff_text)
    end
  end, opts)
end

---@param file ReviewFile|nil
---@param opts table
function M.open(file, opts)
  opts = opts or {}
  if not file then
    return
  end
  local git = require("review.git")
  local request_token = opts.next_request_token and opts.next_request_token() or nil
  vim.notify("Loading file history...", vim.log.levels.INFO)
  if git.file_history_async then
    git.file_history_async(file.path, function(lines, err)
      if opts.request_is_current and not opts.request_is_current(request_token) then
        return
      end
      if not lines then
        vim.notify("Could not load file history: " .. (err or "unknown"), vim.log.levels.WARN)
        return
      end
      open_popup(file, lines, opts)
    end)
  else
    local lines, err = git.file_history(file.path)
    if not lines then
      vim.notify("Could not load file history: " .. (err or "unknown"), vim.log.levels.WARN)
      return
    end
    open_popup(file, lines, opts)
  end
end

return M
