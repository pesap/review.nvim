--- Commit and review-unit context popups for review.nvim.
local diff_mod = require("review.diff")
local highlights = require("review.ui.highlights")

local M = {}

local HL = highlights.groups

---@param scale number|nil
---@param cap number|nil
---@return number width, number col
local function float_dimensions(scale, cap)
  scale = scale or 0.7
  cap = cap or 90
  local cols = vim.o.columns
  local width
  if cols < 60 then
    width = cols - 4
  elseif cols < 100 then
    width = math.floor(cols * 0.85)
  else
    width = math.min(math.floor(cols * scale), cap)
  end
  return width, math.floor((cols - width) / 2)
end

---@param lines string[]
---@param title string
---@param width number|nil
---@param height number|nil
---@param line_actions table<number, table>|nil
local function open_centered_scratch(lines, title, width, height, line_actions)
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
  vim.wo[win].fillchars = "eob: "

  local opts = { buffer = buf, noremap = true, silent = true }
  vim.keymap.set("n", "q", function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end, opts)
  vim.keymap.set("n", "<Esc>", function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end, opts)
  if line_actions then
    vim.keymap.set("n", "<CR>", function()
      local row = vim.api.nvim_win_get_cursor(win)[1]
      local action = line_actions[row]
      if not action then
        return
      end
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
      action()
    end, opts)
  end
end

---@param file ReviewFile
---@return number additions, number deletions
local function file_stats(file)
  local additions, deletions = 0, 0
  for _, hunk in ipairs(file.hunks or {}) do
    for _, line in ipairs(hunk.lines or {}) do
      if line.type == "add" then
        additions = additions + 1
      elseif line.type == "del" then
        deletions = deletions + 1
      end
    end
  end
  return additions, deletions
end

---@param hunk ReviewHunk
---@return number start_line
---@return number end_line
local function hunk_new_range(hunk)
  local start_line = tonumber(hunk.new_start) or 0
  local count = tonumber(hunk.new_count) or 0
  if count <= 0 then
    count = 1
  end
  return start_line, start_line + count - 1
end

---@param a_start number
---@param a_end number
---@param b_start number
---@param b_end number
---@return boolean
local function ranges_overlap(a_start, a_end, b_start, b_end)
  return a_start <= b_end and b_start <= a_end
end

---@param left_file ReviewFile
---@param right_file ReviewFile
---@return table[]
local function overlapping_hunks(left_file, right_file)
  local overlaps = {}
  for _, left_hunk in ipairs(left_file.hunks or {}) do
    local left_start, left_end = hunk_new_range(left_hunk)
    for _, right_hunk in ipairs(right_file.hunks or {}) do
      local right_start, right_end = hunk_new_range(right_hunk)
      if ranges_overlap(left_start, left_end, right_start, right_end) then
        table.insert(overlaps, {
          left_start = left_start,
          left_end = left_end,
          right_start = right_start,
          right_end = right_end,
        })
      end
    end
  end
  return overlaps
end

---@param commit_idx number
---@param path string
---@param line number
local function jump_to_compare_hunk(commit_idx, path, line)
  local state = require("review.state")
  local ui = require("review.ui")
  local session = state.get()
  if not session or not session.commits or not session.commits[commit_idx] then
    return
  end

  state.set_commit(commit_idx)
  state.set_scope_mode("current_commit")
  local file
  for idx, candidate in ipairs(state.active_files()) do
    if candidate.path == path then
      state.set_file(idx)
      file = candidate
      break
    end
  end
  ui.refresh()

  local ui_state = state.get_ui()
  if not file or not ui_state or not ui_state.diff_win or not vim.api.nvim_win_is_valid(ui_state.diff_win) then
    return
  end
  local _, _, new_to_display = diff_mod.build_line_map(file.hunks or {})
  local display_line = new_to_display[line]
  if display_line then
    vim.api.nvim_set_current_win(ui_state.diff_win)
    vim.api.nvim_win_set_cursor(ui_state.diff_win, { display_line, 0 })
  end
end

---@param commit ReviewCommit
---@return string
function M.unit_label(commit)
  if commit.gitbutler and commit.gitbutler.kind == "branch" then
    return commit.gitbutler.branch_name or commit.message or commit.short_sha or commit.sha or "branch"
  end
  if commit.gitbutler and commit.gitbutler.kind == "unassigned" then
    return "unassigned changes"
  end
  return string.format("%s %s", commit.short_sha or tostring(commit.sha or ""):sub(1, 7), commit.message or "")
end

---@param commit ReviewCommit
---@return boolean
local function ensure_unit_files(commit)
  if commit.files then
    return true
  end
  if commit.gitbutler then
    commit.files = commit.files or {}
    return true
  end
  if not commit.sha then
    return false
  end
  local git = require("review.git")
  local diff_text = git.commit_diff(commit.sha)
  commit.files = diff_mod.parse(diff_text)
  return true
end

---@param idx number|nil
---@param opts table|nil
function M.open_commit_details(idx, opts)
  opts = opts or {}
  local state = require("review.state")
  local s = state.get()
  if not s then
    return
  end
  local commit = idx and s.commits[idx] or state.current_commit()
  if not commit then
    vim.notify("No commit selected", vim.log.levels.INFO)
    return
  end

  local lines
  if commit.gitbutler then
    lines = {
      "commit " .. tostring(commit.sha or commit.short_sha or ""),
      "Author: " .. tostring(commit.author or "-"),
      "",
      tostring(commit.message or ""),
      "",
      "Changed paths:",
    }
    for _, file in ipairs(commit.files or {}) do
      table.insert(lines, string.format("  %s %s", file.status or "M", file.path or ""))
    end
  else
    local git = require("review.git")
    local request_token = opts.next_request_token and opts.next_request_token() or nil
    vim.notify("Loading commit details...", vim.log.levels.INFO)
    if git.commit_details_async then
      git.commit_details_async(commit.sha, function(detail_lines, err)
        if opts.request_is_current and not opts.request_is_current(request_token) then
          return
        end
        if not detail_lines then
          vim.notify("Could not load commit details: " .. (err or "unknown"), vim.log.levels.WARN)
          return
        end
        if #detail_lines == 0 then
          detail_lines = { "(no commit details)" }
        end
        local width = float_dimensions(0.72, 100)
        local height = math.min(#detail_lines, math.floor(vim.o.lines * 0.72))
        open_centered_scratch(detail_lines, " Commit Details ", width, height)
      end)
      return
    else
      local detail_lines, err = git.commit_details(commit.sha)
      if not detail_lines then
        vim.notify("Could not load commit details: " .. (err or "unknown"), vim.log.levels.WARN)
        return
      end
      lines = detail_lines
    end
  end

  if #lines == 0 then
    lines = { "(no commit details)" }
  end
  local width = float_dimensions(0.72, 100)
  local height = math.min(#lines, math.floor(vim.o.lines * 0.72))
  open_centered_scratch(lines, " Commit Details ", width, height)
end

---@param left_idx number
---@param right_idx number
---@return string[]|nil lines
---@return string|nil err
---@return table<number, function>|nil line_actions
function M.compare_lines(left_idx, right_idx)
  local state = require("review.state")
  local s = state.get()
  if not s or not s.commits then
    return nil, "No active review session"
  end
  right_idx = tonumber(right_idx)
  if not right_idx or not s.commits[right_idx] or right_idx == left_idx then
    return nil, "Choose a different review unit to compare"
  end

  local left = s.commits[left_idx]
  local right = s.commits[right_idx]
  if not left or not ensure_unit_files(left) or not ensure_unit_files(right) then
    return nil, "Could not load review unit files"
  end

  local left_by_path = {}
  local right_by_path = {}
  for _, file in ipairs(left.files or {}) do
    left_by_path[file.path] = file
  end
  for _, file in ipairs(right.files or {}) do
    right_by_path[file.path] = file
  end

  local overlap = {}
  local left_only = {}
  local right_only = {}
  for path, file in pairs(left_by_path) do
    if right_by_path[path] then
      table.insert(overlap, { path = path, left = file, right = right_by_path[path] })
    else
      table.insert(left_only, file)
    end
  end
  for path, file in pairs(right_by_path) do
    if not left_by_path[path] then
      table.insert(right_only, file)
    end
  end
  table.sort(overlap, function(a, b)
    return a.path < b.path
  end)
  table.sort(left_only, function(a, b)
    return a.path < b.path
  end)
  table.sort(right_only, function(a, b)
    return a.path < b.path
  end)

  local function stat_text(file)
    local adds, dels = file_stats(file)
    return string.format("%s +%d -%d", file.status or "M", adds, dels)
  end

  local line_actions = {}
  local lines = {
    "Compare Review Units",
    "",
    string.format("left  #%d  %s", left_idx, M.unit_label(left)),
    string.format("right #%d  %s", right_idx, M.unit_label(right)),
    "",
    string.format("Overlap (%d)", #overlap),
  }
  for _, item in ipairs(overlap) do
    table.insert(
      lines,
      string.format("  %s  left:%s  right:%s", item.path, stat_text(item.left), stat_text(item.right))
    )
    local hunks = overlapping_hunks(item.left, item.right)
    if #hunks == 0 then
      table.insert(lines, "    overlap hunks: none")
    else
      for _, hunk in ipairs(hunks) do
        table.insert(
          lines,
          string.format(
            "    overlap hunks: left +%d-%d  right +%d-%d  <CR> jump",
            hunk.left_start,
            hunk.left_end,
            hunk.right_start,
            hunk.right_end
          )
        )
        local line_nr = #lines
        line_actions[line_nr] = function()
          jump_to_compare_hunk(left_idx, item.path, hunk.left_start)
        end
      end
    end
  end
  if #overlap == 0 then
    table.insert(lines, "  (none)")
  end

  table.insert(lines, "")
  table.insert(lines, string.format("Left Only (%d)", #left_only))
  for _, file in ipairs(left_only) do
    table.insert(lines, string.format("  %s  %s", file.path, stat_text(file)))
  end
  if #left_only == 0 then
    table.insert(lines, "  (none)")
  end

  table.insert(lines, "")
  table.insert(lines, string.format("Right Only (%d)", #right_only))
  for _, file in ipairs(right_only) do
    table.insert(lines, string.format("  %s  %s", file.path, stat_text(file)))
  end
  if #right_only == 0 then
    table.insert(lines, "  (none)")
  end

  return lines, nil, line_actions
end

---@param idx number|nil
function M.open_unit_compare(idx)
  local state = require("review.state")
  local s = state.get()
  if not s or not s.commits or #s.commits < 2 then
    vim.notify("Need at least two review units to compare", vim.log.levels.INFO)
    return
  end

  local left_idx = s.current_commit_idx
  if not left_idx then
    vim.notify("Select a review unit before comparing", vim.log.levels.INFO)
    return
  end

  local function render_compare(right_idx)
    local lines, err, line_actions = M.compare_lines(left_idx, right_idx)
    if not lines then
      vim.notify(err, err == "Could not load review unit files" and vim.log.levels.WARN or vim.log.levels.WARN)
      return
    end
    open_centered_scratch(
      lines,
      " Compare Units ",
      math.min(110, math.max(60, math.floor(vim.o.columns * 0.78))),
      nil,
      line_actions
    )
  end

  if idx then
    render_compare(idx)
    return
  end

  local choices = {}
  for commit_idx, commit in ipairs(s.commits) do
    if commit_idx ~= left_idx then
      table.insert(choices, string.format("%d: %s", commit_idx, M.unit_label(commit)))
    end
  end
  vim.ui.select(choices, { prompt = "Compare with review unit:" }, function(choice)
    if not choice then
      return
    end
    render_compare(tonumber(choice:match("^(%d+):")))
  end)
end

return M
