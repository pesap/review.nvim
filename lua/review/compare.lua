--- Two-sided comparison explorer.
local M = {}

local highlights = require("review.ui.highlights")
local HL = highlights.groups

local explorer = nil
local render

local KIND_LABELS = {
  git = "ref",
  gitbutler = "but",
  raw_prompt = "input",
  cli_prompt = "input",
  file = "file",
  hunk = "hunk",
}

---@param value string|nil
---@param fallback string
---@return string
local function label(value, fallback)
  if value and value ~= "" then
    return value
  end
  return fallback
end

---@param text string
---@param max_width number
---@return string
local function truncate(text, max_width)
  text = tostring(text or "")
  if vim.fn.strdisplaywidth(text) <= max_width then
    return text
  end
  if max_width <= 1 then
    return text:sub(1, max_width)
  end
  return text:sub(1, math.max(max_width - 3, 1)) .. "..."
end

---@param text string
---@param width number
---@return string
local function pad_right(text, width)
  text = truncate(text, width)
  local gap = math.max(width - vim.fn.strdisplaywidth(text), 0)
  return text .. string.rep(" ", gap)
end

---@param text string
---@param width number
---@return string
local function pad_left(text, width)
  text = truncate(text, width)
  local gap = math.max(width - vim.fn.strdisplaywidth(text), 0)
  return string.rep(" ", gap) .. text
end

---@param left string
---@param right string
---@param width number
---@return string
local function two_column_line(left, right, width)
  right = tostring(right or "")
  local right_width = vim.fn.strdisplaywidth(right)
  local left_budget = math.max(width - right_width - 2, 1)
  left = truncate(left, left_budget)
  local gap = math.max(width - vim.fn.strdisplaywidth(left) - right_width, 1)
  return left .. string.rep(" ", gap) .. right
end

---@param text string
---@return string
local function dim(text)
  return tostring(text or "")
end

---@param rows table[]
---@param section string
---@param kind string
---@param name string
---@param value string
---@param detail string|nil
---@param extra table|nil
local function add_target(rows, section, kind, name, value, detail, extra)
  local row = vim.tbl_extend("force", extra or {}, {
    type = "target",
    section = section,
    kind = kind,
    name = name,
    value = value,
    detail = detail,
  })
  table.insert(rows, row)
end

---@param rows table[]
---@param files ReviewFile[]
local function add_file_and_hunk_rows(rows, files)
  if not files or #files == 0 then
    return
  end
  table.insert(rows, { type = "section", section = "Files", name = "Files" })
  for _, file in ipairs(files) do
    add_target(rows, "Files", "file", file.path, file.path, file.status or "M", {
      focus = { file_path = file.path },
    })
  end

  table.insert(rows, { type = "section", section = "Hunks", name = "Hunks" })
  for _, file in ipairs(files) do
    for _, hunk in ipairs(file.hunks or {}) do
      local line = hunk.new_start and hunk.new_start > 0 and hunk.new_start or hunk.old_start
      add_target(
        rows,
        "Hunks",
        "hunk",
        string.format("%s:%s", file.path, tostring(line or 1)),
        file.path,
        hunk.header,
        {
          focus = {
            file_path = file.path,
            line = line,
            side = hunk.new_start and hunk.new_start > 0 and "new" or "old",
          },
        }
      )
    end
  end
end

---@return string
local function default_left()
  local state = require("review.state")
  local git = require("review.git")
  local s = state.get()
  if s and s.left_ref then
    return s.left_ref
  end
  if s and s.base_ref then
    return s.base_ref
  end
  return git.default_branch() or "HEAD"
end

---@return string
local function default_right()
  local state = require("review.state")
  local s = state.get()
  if s and s.right_ref then
    return s.right_ref
  end
  if s and s.vcs == "gitbutler" then
    return "workspace"
  end
  return "HEAD"
end

---@return table[]
local function build_rows()
  local rows = {}
  local state = require("review.state")
  local git = require("review.git")
  local gitbutler = require("review.gitbutler")
  local s = state.get()

  table.insert(rows, { type = "section", section = "Raw refs", name = "Raw refs" })
  add_target(rows, "Raw refs", "raw_prompt", "Enter raw ref...", "", "branch, tag, SHA, or relative ref")

  if state.is_gitbutler() then
    local status = s and s.gitbutler or gitbutler.status()
    table.insert(rows, { type = "section", section = "Stacks", name = "Stacks" })
    for _, stack in ipairs((status and status.stacks) or {}) do
      if stack.cliId then
        add_target(rows, "Stacks", "gitbutler", stack.name or stack.cliId, stack.cliId, "but:" .. stack.cliId)
      end
    end

    table.insert(rows, { type = "section", section = "Virtual branches", name = "Virtual branches" })
    for _, stack in ipairs((status and status.stacks) or {}) do
      for _, branch in ipairs(stack.branches or {}) do
        if branch.cliId then
          add_target(
            rows,
            "Virtual branches",
            "gitbutler",
            branch.name or branch.cliId,
            branch.cliId,
            "but:" .. branch.cliId
          )
        end
      end
    end

    table.insert(rows, { type = "section", section = "Unassigned", name = "Unassigned" })
    add_target(rows, "Unassigned", "gitbutler", "unassigned changes", "", "but diff")

    table.insert(rows, { type = "section", section = "CLI targets", name = "CLI targets" })
    add_target(
      rows,
      "CLI targets",
      "cli_prompt",
      "Enter GitButler CLI target...",
      "",
      "stack, branch, commit, or change ID"
    )
  end

  table.insert(rows, { type = "section", section = "Branches", name = "Branches" })
  for _, branch in ipairs(git.local_branches()) do
    add_target(rows, "Branches", "git", branch, branch, "branch")
  end

  table.insert(rows, { type = "section", section = "Tags", name = "Tags" })
  for _, tag in ipairs(git.tags()) do
    add_target(rows, "Tags", "git", tag, tag, "tag")
  end

  table.insert(rows, { type = "section", section = "Recent commits", name = "Recent commits" })
  for _, commit in ipairs(git.recent_commits(24)) do
    add_target(rows, "Recent commits", "git", commit.short_sha .. "  " .. commit.message, commit.sha, commit.author)
  end

  add_file_and_hunk_rows(rows, s and state.active_files() or {})
  return rows
end

---@param row table
---@param query string
---@return boolean
local function row_matches(row, query)
  if query == "" or row.type == "section" then
    return true
  end
  local text =
    table.concat({ row.section or "", row.kind or "", row.name or "", row.value or "", row.detail or "" }, " "):lower()
  return text:find(query, 1, true) ~= nil
end

---@param state table
---@return table[]
local function visible_rows(state)
  local out = {}
  local query = vim.trim(tostring(state.query or "")):lower()
  local pending_section = nil
  local section_has_rows = false
  for _, row in ipairs(state.rows) do
    if row.type == "section" then
      if pending_section and section_has_rows then
        table.insert(out, pending_section)
      end
      pending_section = row
      section_has_rows = false
    elseif row_matches(row, query) then
      if pending_section and not section_has_rows then
        table.insert(out, pending_section)
      end
      pending_section = nil
      section_has_rows = true
      table.insert(out, row)
    end
  end
  if pending_section and section_has_rows then
    table.insert(out, pending_section)
  end
  return out
end

---@param rows table[]
---@return table<string, number>
local function section_counts(rows)
  local counts = {}
  local current = nil
  for _, row in ipairs(rows) do
    if row.type == "section" then
      current = row.name
      counts[current] = counts[current] or 0
    elseif row.type == "target" and current then
      counts[current] = counts[current] + 1
    end
  end
  return counts
end

local function close()
  if explorer and explorer.win and vim.api.nvim_win_is_valid(explorer.win) then
    vim.api.nvim_win_close(explorer.win, true)
  end
  explorer = nil
end

---@param side "left"|"right"
---@param row table
local function set_side(side, row)
  if row.kind == "raw_prompt" then
    vim.ui.input({ prompt = "Git ref for " .. side .. ": " }, function(input)
      if input and vim.trim(input) ~= "" and explorer then
        explorer[side] = vim.trim(input)
        explorer[side .. "_kind"] = "git"
        render()
      end
    end)
    return
  end
  if row.kind == "cli_prompt" then
    vim.ui.input({ prompt = "GitButler CLI target for " .. side .. ": " }, function(input)
      if input and vim.trim(input) ~= "" and explorer then
        explorer[side] = vim.trim(input)
        explorer[side .. "_kind"] = "gitbutler"
        render()
      end
    end)
    return
  end
  if row.kind == "file" or row.kind == "hunk" then
    explorer.focus = row.focus
    explorer.message = row.kind == "file" and ("will focus " .. row.focus.file_path .. " after compare")
      or ("will focus " .. row.focus.file_path .. ":" .. tostring(row.focus.line or 1) .. " after compare")
    render()
    return
  end
  explorer[side] = row.value
  explorer[side .. "_kind"] = row.kind == "gitbutler" and "gitbutler" or "git"
  explorer.message = (side == "left" and "left" or "right") .. " set to " .. label(row.value, row.name)
end

render = function()
  if not explorer or not vim.api.nvim_buf_is_valid(explorer.buf) then
    return
  end
  local width = vim.api.nvim_win_is_valid(explorer.win) and vim.api.nvim_win_get_width(explorer.win) or 90
  local lines = {}
  local map = {}
  local highlights_to_apply = {}
  local active = explorer.active_side == "left" and "left" or "right"
  local left_active = active == "left"
  local right_active = active == "right"
  local content_width = math.max(width - 4, 20)
  local left_label = label(explorer.left, "base")
  local right_label = label(explorer.right, "compare")
  local visible = visible_rows(explorer)
  local counts = section_counts(visible)

  local function add_line(text, entry, hl, col_start, col_end)
    table.insert(lines, "  " .. truncate(text, content_width))
    table.insert(map, entry or { type = "header" })
    if hl then
      table.insert(highlights_to_apply, {
        line = #lines - 1,
        hl = hl,
        col_start = (col_start or 0) + 2,
        col_end = col_end and (col_end + 2) or -1,
      })
    end
  end

  add_line(two_column_line("Compare Explorer", "[C] apply", content_width), { type = "header" }, HL.panel_title)

  local action_bar = "<CR> select   / filter   Tab side   K details   x clear   q close"
  add_line(action_bar, { type = "header" }, HL.panel_meta)

  local half = math.floor((content_width - 3) / 2)
  local left_card =
    string.format("%s %-7s %s", left_active and ">" or " ", "BASE", truncate(left_label, math.max(half - 11, 4)))
  local right_card = string.format(
    "%s %-7s %s",
    right_active and ">" or " ",
    "COMPARE",
    truncate(right_label, math.max(content_width - half - 14, 4))
  )
  add_line(pad_right(left_card, half) .. " | " .. pad_right(right_card, math.max(content_width - half - 3, 1)))
  table.insert(highlights_to_apply, {
    line = #lines - 1,
    hl = left_active and HL.explorer_scope_value or HL.panel_meta,
    col_start = 2,
    col_end = half + 2,
  })
  table.insert(highlights_to_apply, {
    line = #lines - 1,
    hl = right_active and HL.explorer_scope_value or HL.panel_meta,
    col_start = half + 5,
    col_end = -1,
  })

  local status_bits = {}
  if explorer.query ~= "" then
    table.insert(status_bits, "filter: " .. explorer.query)
  end
  if explorer.focus then
    local suffix = explorer.focus.line and (":" .. tostring(explorer.focus.line)) or ""
    table.insert(status_bits, "land: " .. explorer.focus.file_path .. suffix)
  end
  if explorer.message and explorer.message ~= "" then
    table.insert(status_bits, explorer.message)
  end
  if #status_bits > 0 then
    add_line(table.concat(status_bits, "  |  "), { type = "header" }, HL.note_ref)
  end

  local name_width = math.max(content_width - 31, 14)
  local detail_width = math.max(content_width - name_width - 11, 8)

  add_line(string.rep("-", content_width), { type = "blank" }, HL.note_separator)
  add_line(
    pad_right("  type", 8) .. pad_right("target", name_width) .. " " .. pad_left("detail", detail_width),
    { type = "header" },
    HL.panel_meta
  )

  local shown = 0
  for _, row in ipairs(visible) do
    if row.type == "section" then
      local section_name = row.name
      local count = counts[section_name] or 0
      add_line("", { type = "blank" })
      add_line(two_column_line(section_name, tostring(count), content_width), row, HL.panel_title)
    else
      shown = shown + 1
      local side_marker = " "
      if row.kind == "file" or row.kind == "hunk" then
        if
          explorer.focus
          and row.focus
          and explorer.focus.file_path == row.focus.file_path
          and explorer.focus.line == row.focus.line
        then
          side_marker = "*"
        end
      elseif row.value == explorer.left then
        side_marker = "L"
      elseif row.value == explorer.right then
        side_marker = "R"
      end
      local kind = KIND_LABELS[row.kind] or row.kind or "target"
      local name = row.name or row.value or ""
      local detail = row.detail and row.detail ~= "" and row.detail or ""
      local row_text = string.format(
        "%s %s %s %s",
        side_marker,
        pad_right(kind, 6),
        pad_right(name, name_width),
        pad_left(dim(detail), detail_width)
      )
      table.insert(lines, "  " .. truncate(row_text, content_width))
      table.insert(map, row)
      local li = #lines - 1
      local kind_hl = (row.kind == "file" or row.kind == "hunk") and HL.explorer_file or HL.explorer_active
      table.insert(highlights_to_apply, {
        line = li,
        hl = kind_hl,
        col_start = 4,
        col_end = 12,
      })
      if side_marker ~= " " then
        table.insert(highlights_to_apply, {
          line = li,
          hl = side_marker == "*" and HL.commit_active or HL.explorer_scope_value,
          col_start = 2,
          col_end = 3,
        })
      end
    end
  end

  if shown == 0 then
    add_line("no targets match", { type = "blank" }, HL.panel_meta)
  end

  add_line(string.rep("-", content_width), { type = "blank" }, HL.note_separator)
  add_line("L/R mark selected refs. * marks the landing file or hunk after apply.", { type = "footer" }, HL.panel_meta)

  explorer.line_map = map
  vim.bo[explorer.buf].modifiable = true
  vim.api.nvim_buf_set_lines(explorer.buf, 0, -1, false, lines)
  vim.bo[explorer.buf].modifiable = false
  local ns = vim.api.nvim_create_namespace("review_compare_explorer")
  vim.api.nvim_buf_clear_namespace(explorer.buf, ns, 0, -1)
  for _, h in ipairs(highlights_to_apply) do
    vim.api.nvim_buf_add_highlight(explorer.buf, ns, h.hl, h.line, h.col_start, h.col_end)
  end
end

local function selected_row()
  if not explorer or not explorer.line_map then
    return nil
  end
  local line = vim.api.nvim_win_get_cursor(explorer.win)[1]
  local row = explorer.line_map[line]
  if row and row.type ~= "section" and row.type ~= "header" and row.type ~= "blank" and row.type ~= "footer" then
    return row
  end
  return nil
end

---@return number|nil
local function first_target_line()
  if not explorer or not explorer.line_map then
    return nil
  end
  for line, row in ipairs(explorer.line_map) do
    if row and row.type == "target" then
      return line
    end
  end
  return nil
end

local function show_details()
  local row = selected_row()
  if not row then
    return
  end
  local lines = {
    row.section or "",
    "kind: " .. tostring(row.kind or ""),
    "name: " .. tostring(row.name or ""),
    "value: " .. tostring(row.value or ""),
  }
  if row.detail then
    table.insert(lines, "detail: " .. tostring(row.detail))
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local width = math.min(80, math.max(40, math.floor(vim.o.columns * 0.5)))
  local height = math.min(#lines, 10)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " Target Details ",
    title_pos = "center",
  })
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
end

local function apply()
  if not explorer then
    return
  end
  local review = require("review")
  local state = require("review.state")
  local previous_review = review._review_return_target and review._review_return_target(state.get()) or nil
  local left = explorer.left
  local right = explorer.right
  local left_kind = explorer.left_kind
  local right_kind = explorer.right_kind
  local focus = explorer.focus
  close()
  if (right_kind == "gitbutler" and right == "workspace") or (left_kind == "gitbutler" and left == "workspace") then
    if state.get_ui() then
      require("review.ui").close()
    end
    review._open_with_ref(nil, { requested_ref = nil })
    return
  end
  if right_kind == "gitbutler" then
    review._open_gitbutler_target(right, { focus = focus, previous_review = previous_review })
    return
  end
  if left_kind == "gitbutler" then
    review._open_gitbutler_target(left, { focus = focus, previous_review = previous_review })
    return
  end
  review._open_with_refs(left, right, { focus = focus, previous_review = previous_review })
end

function M.open()
  local state = require("review.state")
  if not state.get() then
    vim.notify("No active review session", vim.log.levels.ERROR)
    return
  end

  local width = math.min(110, math.max(64, math.floor(vim.o.columns * 0.78)))
  local height = math.min(math.max(16, math.floor(vim.o.lines * 0.72)), vim.o.lines - 4)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "review-compare"
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " Compare Explorer ",
    title_pos = "center",
  })
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].fillchars = "eob: "
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

  explorer = {
    buf = buf,
    win = win,
    rows = build_rows(),
    active_side = "left",
    left = default_left(),
    right = default_right(),
    left_kind = "git",
    right_kind = state.is_gitbutler() and "gitbutler" or "git",
    query = "",
  }
  render()
  local target_line = first_target_line()
  if target_line then
    vim.api.nvim_win_set_cursor(win, { target_line, 0 })
  end

  local opts = { buffer = buf, noremap = true, silent = true }
  vim.keymap.set("n", "q", close, opts)
  vim.keymap.set("n", "<Esc>", close, opts)
  vim.keymap.set("n", "h", function()
    explorer.active_side = "left"
    explorer.message = "selecting the left/base side"
    render()
  end, opts)
  vim.keymap.set("n", "l", function()
    explorer.active_side = "right"
    explorer.message = "selecting the right/compare side"
    render()
  end, opts)
  vim.keymap.set("n", "<Tab>", function()
    explorer.active_side = explorer.active_side == "left" and "right" or "left"
    explorer.message = "selecting the "
      .. (explorer.active_side == "left" and "left/base" or "right/compare")
      .. " side"
    render()
  end, opts)
  vim.keymap.set("n", "<S-Tab>", function()
    explorer.active_side = explorer.active_side == "left" and "right" or "left"
    explorer.message = "selecting the "
      .. (explorer.active_side == "left" and "left/base" or "right/compare")
      .. " side"
    render()
  end, opts)
  vim.keymap.set("n", "<CR>", function()
    local row = selected_row()
    if not row then
      return
    end
    set_side(explorer.active_side, row)
    render()
  end, opts)
  vim.keymap.set("n", "/", function()
    vim.ui.input({ prompt = "Filter targets: ", default = explorer.query }, function(input)
      if explorer then
        explorer.query = input and vim.trim(input) or ""
        explorer.message = explorer.query ~= "" and ("filter: " .. explorer.query) or "filter cleared"
        render()
        local target_line = first_target_line()
        if target_line and vim.api.nvim_win_is_valid(explorer.win) then
          vim.api.nvim_win_set_cursor(explorer.win, { target_line, 0 })
        end
      end
    end)
  end, opts)
  vim.keymap.set("n", "x", function()
    explorer.query = ""
    explorer.focus = nil
    explorer.message = "filter and landing focus cleared"
    render()
    local target_line = first_target_line()
    if target_line then
      vim.api.nvim_win_set_cursor(explorer.win, { target_line, 0 })
    end
  end, opts)
  vim.keymap.set("n", "C", apply, opts)
  vim.keymap.set("n", "K", show_details, opts)
end

return M
