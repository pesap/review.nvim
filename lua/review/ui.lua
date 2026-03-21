--- All window/buffer/layout management for review.nvim
local state = require("review.state")
local diff_mod = require("review.diff")

local M = {}

-- Highlight group names
local HL = {
  add = "ReviewDiffAdd",
  del = "ReviewDiffDelete",
  add_text = "ReviewDiffAddText",
  del_text = "ReviewDiffDeleteText",
  hunk_header = "ReviewHunkHeader",
  file_header = "ReviewFileHeader",
  explorer_file = "ReviewExplorerFile",
  explorer_active = "ReviewExplorerActive",
  status_m = "ReviewStatusM",
  status_a = "ReviewStatusA",
  status_d = "ReviewStatusD",
  note_sign = "ReviewNoteSign",
  commit = "ReviewCommit",
  commit_active = "ReviewCommitActive",
  commit_author = "ReviewCommitAuthor",
}

--- Set up highlight groups (called once).
function M.setup_highlights()
  local set = vim.api.nvim_set_hl
  set(0, HL.add, { bg = "#2a4a2a" })
  set(0, HL.del, { bg = "#4a2a2a" })
  set(0, HL.add_text, { bg = "#3a6a3a", bold = true })
  set(0, HL.del_text, { bg = "#6a3a3a", bold = true })
  set(0, HL.hunk_header, { fg = "#888888", italic = true })
  set(0, HL.file_header, { fg = "#61afef", bold = true })
  set(0, HL.explorer_file, { fg = "#abb2bf" })
  set(0, HL.explorer_active, { fg = "#61afef", bold = true })
  set(0, HL.status_m, { fg = "#e5c07b" })
  set(0, HL.status_a, { fg = "#98c379" })
  set(0, HL.status_d, { fg = "#e06c75" })
  set(0, HL.note_sign, { fg = "#c678dd", bold = true })
  set(0, HL.commit, { fg = "#d19a66" })
  set(0, HL.commit_active, { fg = "#e5c07b", bold = true })
  set(0, HL.commit_author, { fg = "#888888", italic = true })
end

--- Create a scratch buffer with given options.
---@param name string
---@param opts table|nil
---@return number bufnr
local function create_buf(name, opts)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, name)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  if opts and opts.filetype then
    vim.bo[buf].filetype = opts.filetype
  end
  return buf
end

--- Render a list of files into the explorer lines/highlights.
---@param files ReviewFile[]
---@param lines string[]
---@param highlights table[]
---@param active_idx number
local function render_file_list(files, lines, highlights, active_idx)
  for i, file in ipairs(files) do
    local status_char = file.status
    local icon = " "
    if status_char == "M" then
      icon = "~"
    elseif status_char == "A" then
      icon = "+"
    elseif status_char == "D" then
      icon = "-"
    elseif status_char == "R" then
      icon = "→"
    end

    -- Count notes for this file
    local note_count = #state.get_notes(file.path)
    local note_badge = ""
    if note_count > 0 then
      note_badge = " [" .. note_count .. "]"
    end

    local line = string.format("   %s %s%s", icon, file.path, note_badge)
    table.insert(lines, line)

    local is_active = (i == active_idx)
    local line_idx = #lines - 1

    -- Status color
    local status_hl = HL.status_m
    if status_char == "A" then
      status_hl = HL.status_a
    elseif status_char == "D" then
      status_hl = HL.status_d
    end
    table.insert(highlights, { line = line_idx, hl = status_hl, col_start = 3, col_end = 4 })

    -- File name
    if is_active then
      table.insert(highlights, { line = line_idx, hl = HL.explorer_active, col_start = 5, col_end = -1 })
    else
      table.insert(highlights, { line = line_idx, hl = HL.explorer_file, col_start = 5, col_end = -1 })
    end
  end
end

-- Explorer line type map: tracks what each line in the explorer represents.
-- Stored per-render so keymaps can resolve cursor position.
---@type table[]|nil  Each: {type: "header"|"separator"|"commit"|"file", idx: number|nil}
local explorer_line_map = nil

--- Render the file explorer buffer.
---@param buf number
local function render_explorer(buf)
  local s = state.get()
  if not s then
    return
  end

  local lines = {}
  local highlights = {}
  explorer_line_map = {}

  -- Commits section (if any)
  if #s.commits > 0 then
    table.insert(lines, "  Commits")
    table.insert(explorer_line_map, { type = "header" })
    table.insert(highlights, { line = #lines - 1, hl = HL.file_header, col_start = 0, col_end = -1 })
    table.insert(lines, string.rep("─", 30))
    table.insert(explorer_line_map, { type = "separator" })

    -- "All changes" entry
    local all_prefix = s.current_commit_idx == nil and "▸ " or "  "
    table.insert(lines, all_prefix .. "All changes (" .. #s.files .. " files)")
    table.insert(explorer_line_map, { type = "commit", idx = nil })
    local all_hl = s.current_commit_idx == nil and HL.commit_active or HL.commit
    table.insert(highlights, { line = #lines - 1, hl = all_hl, col_start = 0, col_end = -1 })

    for i, commit in ipairs(s.commits) do
      local prefix = (s.current_commit_idx == i) and "▸ " or "  "
      local commit_line = string.format("%s%s %s", prefix, commit.short_sha, commit.message)
      table.insert(lines, commit_line)
      table.insert(explorer_line_map, { type = "commit", idx = i })
      local c_line_idx = #lines - 1

      local c_hl = (s.current_commit_idx == i) and HL.commit_active or HL.commit
      table.insert(highlights, { line = c_line_idx, hl = c_hl, col_start = 0, col_end = -1 })

      -- Author on same line (after message)
      local author_text = " — " .. commit.author
      -- Update the line to include author
      lines[#lines] = lines[#lines] .. author_text
      local author_start = #commit_line
      table.insert(highlights, { line = c_line_idx, hl = HL.commit_author, col_start = author_start, col_end = -1 })
    end

    table.insert(lines, "")
    table.insert(explorer_line_map, { type = "separator" })
  end

  -- Files section
  table.insert(lines, "  Files")
  table.insert(explorer_line_map, { type = "header" })
  table.insert(highlights, { line = #lines - 1, hl = HL.file_header, col_start = 0, col_end = -1 })
  table.insert(lines, string.rep("─", 30))
  table.insert(explorer_line_map, { type = "separator" })

  local active_files = state.active_files()
  for i, file in ipairs(active_files) do
    local status_char = file.status
    local icon = " "
    if status_char == "M" then
      icon = "~"
    elseif status_char == "A" then
      icon = "+"
    elseif status_char == "D" then
      icon = "-"
    elseif status_char == "R" then
      icon = "→"
    end

    local note_count = #state.get_notes(file.path)
    local note_badge = ""
    if note_count > 0 then
      note_badge = " [" .. note_count .. "]"
    end

    local line = string.format("   %s %s%s", icon, file.path, note_badge)
    table.insert(lines, line)
    table.insert(explorer_line_map, { type = "file", idx = i })

    local is_active = (i == s.current_file_idx)
    local line_idx = #lines - 1

    local status_hl = HL.status_m
    if status_char == "A" then
      status_hl = HL.status_a
    elseif status_char == "D" then
      status_hl = HL.status_d
    end
    table.insert(highlights, { line = line_idx, hl = status_hl, col_start = 3, col_end = 4 })

    if is_active then
      table.insert(highlights, { line = line_idx, hl = HL.explorer_active, col_start = 5, col_end = -1 })
    else
      table.insert(highlights, { line = line_idx, hl = HL.explorer_file, col_start = 5, col_end = -1 })
    end
  end

  if #active_files == 0 then
    table.insert(lines, "   (no files)")
    table.insert(explorer_line_map, { type = "separator" })
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  -- Apply highlights
  local ns = vim.api.nvim_create_namespace("review_explorer")
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, h in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(buf, ns, h.hl, h.line, h.col_start, h.col_end)
  end
end

--- Format a single diff line with gutter.
---@param dl ReviewDiffLine
---@return string display  The formatted line
---@return number gutter_len  Length of the gutter prefix (before the text content)
local function format_diff_line(dl)
  local prefix
  if dl.type == "add" then
    prefix = "+"
  elseif dl.type == "del" then
    prefix = "-"
  else
    prefix = " "
  end
  local old_num = dl.old_lnum and string.format("%4d", dl.old_lnum) or "    "
  local new_num = dl.new_lnum and string.format("%4d", dl.new_lnum) or "    "
  local gutter = string.format("%s %s│%s│", old_num, new_num, prefix)
  return gutter .. dl.text, #gutter
end

--- Build display lines and highlights for a file's diff.
---@param file ReviewFile
---@return string[] lines
---@return table[] highlights  Each: {line, hl, col_start, col_end}
local function build_diff_display(file)
  local lines = {}
  local highlights = {}

  for _, hunk in ipairs(file.hunks) do
    -- Hunk header
    table.insert(lines, hunk.header)
    table.insert(highlights, {
      line = #lines - 1,
      hl = HL.hunk_header,
      col_start = 0,
      col_end = -1,
    })

    -- Pre-compute word diff pairs for this hunk
    local word_diff_pairs = diff_mod.pair_changed_lines(hunk)
    local pair_map = {} -- line_idx -> {del_idx, add_idx}
    for _, pair in ipairs(word_diff_pairs) do
      pair_map[pair[1]] = pair -- del line
      pair_map[pair[2]] = pair -- add line
    end

    -- Track the display line index where each hunk line starts
    local hunk_base = #lines

    for line_idx, dl in ipairs(hunk.lines) do
      local display, gutter_len = format_diff_line(dl)
      table.insert(lines, display)
      local display_idx = #lines - 1

      local hl_group
      if dl.type == "add" then
        hl_group = HL.add
      elseif dl.type == "del" then
        hl_group = HL.del
      end

      if hl_group then
        -- Background highlight for the whole line
        table.insert(highlights, {
          line = display_idx,
          hl = hl_group,
          col_start = 0,
          col_end = -1,
        })

        -- Word-level highlight if this line is part of a paired change
        local pair = pair_map[line_idx]
        if pair then
          local del_line = hunk.lines[pair[1]]
          local add_line = hunk.lines[pair[2]]
          local old_ranges, new_ranges = diff_mod.word_diff(del_line.text, add_line.text)

          if dl.type == "del" then
            for _, range in ipairs(old_ranges) do
              table.insert(highlights, {
                line = display_idx,
                hl = HL.del_text,
                col_start = gutter_len + range[1],
                col_end = gutter_len + range[2],
              })
            end
          else
            for _, range in ipairs(new_ranges) do
              table.insert(highlights, {
                line = display_idx,
                hl = HL.add_text,
                col_start = gutter_len + range[1],
                col_end = gutter_len + range[2],
              })
            end
          end
        end
      end
    end
  end

  if #lines == 0 then
    table.insert(lines, "  (no diff content)")
  end

  return lines, highlights
end

--- Render the diff viewer buffer for the current file.
---@param buf number
local function render_diff(buf)
  local file = state.active_current_file()
  if not file then
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "  No files to display" })
    vim.bo[buf].modifiable = false
    return
  end

  local lines, highlights = build_diff_display(file)

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  -- Apply highlights
  local ns = vim.api.nvim_create_namespace("review_diff")
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, h in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(buf, ns, h.hl, h.line, h.col_start, h.col_end)
  end

  -- Show note signs
  M.render_note_signs(buf)
end

--- Render note signs in the diff buffer.
---@param buf number
function M.render_note_signs(buf)
  local file = state.active_current_file()
  if not file then
    return
  end

  local ns = vim.api.nvim_create_namespace("review_notes")
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

  local notes = state.get_notes(file.path)
  if #notes == 0 then
    return
  end

  -- Build line map to find display positions
  local _, _, new_to_display, old_to_display = diff_mod.build_line_map(file.hunks)

  for _, note in ipairs(notes) do
    local display_line
    if note.side == "old" then
      display_line = old_to_display[note.line]
    else
      display_line = new_to_display[note.line]
    end

    if display_line then
      vim.api.nvim_buf_set_extmark(buf, ns, display_line - 1, 0, {
        sign_text = "N",
        sign_hl_group = HL.note_sign,
        priority = 100,
      })
    end
  end
end

--- Build split-view display: separate old and new side buffers.
--- Each side has the same number of lines (padded with blanks) for scrollbind.
---@param file ReviewFile
---@return string[] old_lines
---@return table[] old_highlights
---@return string[] new_lines
---@return table[] new_highlights
local function build_split_display(file)
  local old_lines = {}
  local old_hl = {}
  local new_lines = {}
  local new_hl = {}

  for _, hunk in ipairs(file.hunks) do
    -- Hunk header on both sides
    table.insert(old_lines, hunk.header)
    table.insert(old_hl, { line = #old_lines - 1, hl = HL.hunk_header, col_start = 0, col_end = -1 })
    table.insert(new_lines, hunk.header)
    table.insert(new_hl, { line = #new_lines - 1, hl = HL.hunk_header, col_start = 0, col_end = -1 })

    -- Pre-compute word diff pairs
    local word_diff_pairs = diff_mod.pair_changed_lines(hunk)
    local pair_map = {}
    for _, pair in ipairs(word_diff_pairs) do
      pair_map[pair[1]] = pair
      pair_map[pair[2]] = pair
    end

    -- Group lines into chunks: context lines go on both sides,
    -- del/add blocks need to be aligned side-by-side with padding.
    local i = 1
    while i <= #hunk.lines do
      local dl = hunk.lines[i]

      if dl.type == "ctx" then
        local old_num = dl.old_lnum and string.format("%4d", dl.old_lnum) or "    "
        local new_num = dl.new_lnum and string.format("%4d", dl.new_lnum) or "    "
        table.insert(old_lines, string.format("%s│ │%s", old_num, dl.text))
        table.insert(new_lines, string.format("%s│ │%s", new_num, dl.text))
        i = i + 1

      elseif dl.type == "del" then
        -- Collect consecutive del lines
        local dels = {}
        while i <= #hunk.lines and hunk.lines[i].type == "del" do
          table.insert(dels, { idx = i, line = hunk.lines[i] })
          i = i + 1
        end
        -- Collect consecutive add lines
        local adds = {}
        while i <= #hunk.lines and hunk.lines[i].type == "add" do
          table.insert(adds, { idx = i, line = hunk.lines[i] })
          i = i + 1
        end

        local max_count = math.max(#dels, #adds)
        for j = 1, max_count do
          if j <= #dels then
            local d = dels[j]
            local num = d.line.old_lnum and string.format("%4d", d.line.old_lnum) or "    "
            local text = string.format("%s│-│%s", num, d.line.text)
            table.insert(old_lines, text)
            local line_idx = #old_lines - 1
            table.insert(old_hl, { line = line_idx, hl = HL.del, col_start = 0, col_end = -1 })

            -- Word-level highlight
            local pair = pair_map[d.idx]
            if pair then
              local del_l = hunk.lines[pair[1]]
              local add_l = hunk.lines[pair[2]]
              local old_ranges, _ = diff_mod.word_diff(del_l.text, add_l.text)
              local gutter_len = #num + 3 -- "NNNN│-│"
              for _, range in ipairs(old_ranges) do
                table.insert(old_hl, {
                  line = line_idx,
                  hl = HL.del_text,
                  col_start = gutter_len + range[1],
                  col_end = gutter_len + range[2],
                })
              end
            end
          else
            table.insert(old_lines, "")
          end

          if j <= #adds then
            local a = adds[j]
            local num = a.line.new_lnum and string.format("%4d", a.line.new_lnum) or "    "
            local text = string.format("%s│+│%s", num, a.line.text)
            table.insert(new_lines, text)
            local line_idx = #new_lines - 1
            table.insert(new_hl, { line = line_idx, hl = HL.add, col_start = 0, col_end = -1 })

            -- Word-level highlight
            local pair = pair_map[a.idx]
            if pair then
              local del_l = hunk.lines[pair[1]]
              local add_l = hunk.lines[pair[2]]
              local _, new_ranges = diff_mod.word_diff(del_l.text, add_l.text)
              local gutter_len = #num + 3
              for _, range in ipairs(new_ranges) do
                table.insert(new_hl, {
                  line = line_idx,
                  hl = HL.add_text,
                  col_start = gutter_len + range[1],
                  col_end = gutter_len + range[2],
                })
              end
            end
          else
            table.insert(new_lines, "")
          end
        end

      elseif dl.type == "add" then
        -- Standalone adds (no preceding del)
        local num = dl.new_lnum and string.format("%4d", dl.new_lnum) or "    "
        table.insert(old_lines, "")
        table.insert(new_lines, string.format("%s│+│%s", num, dl.text))
        table.insert(new_hl, { line = #new_lines - 1, hl = HL.add, col_start = 0, col_end = -1 })
        i = i + 1
      else
        i = i + 1
      end
    end
  end

  return old_lines, old_hl, new_lines, new_hl
end

--- Render the split view (old left, new right) for the current file.
local function render_split(ui_state)
  local file = state.active_current_file()
  if not file then
    return
  end

  local old_lines, old_hl, new_lines, new_hl = build_split_display(file)

  -- Old side (reuse diff_buf)
  vim.bo[ui_state.diff_buf].modifiable = true
  vim.api.nvim_buf_set_lines(ui_state.diff_buf, 0, -1, false, old_lines)
  vim.bo[ui_state.diff_buf].modifiable = false

  local ns_old = vim.api.nvim_create_namespace("review_diff")
  vim.api.nvim_buf_clear_namespace(ui_state.diff_buf, ns_old, 0, -1)
  for _, h in ipairs(old_hl) do
    vim.api.nvim_buf_add_highlight(ui_state.diff_buf, ns_old, h.hl, h.line, h.col_start, h.col_end)
  end

  -- New side
  vim.bo[ui_state.split_buf].modifiable = true
  vim.api.nvim_buf_set_lines(ui_state.split_buf, 0, -1, false, new_lines)
  vim.bo[ui_state.split_buf].modifiable = false

  local ns_new = vim.api.nvim_create_namespace("review_diff_new")
  vim.api.nvim_buf_clear_namespace(ui_state.split_buf, ns_new, 0, -1)
  for _, h in ipairs(new_hl) do
    vim.api.nvim_buf_add_highlight(ui_state.split_buf, ns_new, h.hl, h.line, h.col_start, h.col_end)
  end

  -- Enable scrollbind on both windows
  vim.wo[ui_state.diff_win].scrollbind = true
  vim.wo[ui_state.split_win].scrollbind = true
  vim.cmd("syncbind")
end

--- Toggle between unified and split view.
function M.toggle_split()
  local ui_state = state.get_ui()
  if not ui_state then
    return
  end

  if ui_state.view_mode == "unified" then
    -- Switch to split mode
    ui_state.view_mode = "split"

    -- Create the split buffer and window
    local split_buf = create_buf("review://diff-new", { filetype = "review-diff" })

    -- Focus the diff window and split it
    vim.api.nvim_set_current_win(ui_state.diff_win)
    vim.cmd("vsplit")
    vim.cmd("wincmd l")
    vim.api.nvim_set_current_buf(split_buf)

    local split_win = vim.api.nvim_get_current_win()

    vim.wo[split_win].number = false
    vim.wo[split_win].relativenumber = false
    vim.wo[split_win].signcolumn = "yes"
    vim.wo[split_win].wrap = false
    vim.wo[split_win].cursorline = true

    ui_state.split_buf = split_buf
    ui_state.split_win = split_win

    -- Set up keymaps on the new buffer too
    setup_diff_keymaps(split_buf)

    render_split(ui_state)
  else
    -- Switch back to unified mode
    ui_state.view_mode = "unified"

    -- Disable scrollbind
    vim.wo[ui_state.diff_win].scrollbind = false

    -- Close the split window/buffer
    if ui_state.split_win and vim.api.nvim_win_is_valid(ui_state.split_win) then
      vim.api.nvim_win_close(ui_state.split_win, true)
    end
    ui_state.split_buf = nil
    ui_state.split_win = nil

    -- Re-render unified diff
    render_diff(ui_state.diff_buf)
  end
end

--- Select a commit (nil = all changes) and refresh the view.
---@param idx number|nil  Commit index, or nil for all changes
function M.select_commit(idx)
  local s = state.get()
  if not s then
    return
  end

  -- If selecting a specific commit, lazily load its files
  if idx ~= nil then
    local commit = s.commits[idx]
    if commit and not commit.files then
      local git = require("review.git")
      local diff_text = git.commit_diff(commit.sha)
      commit.files = diff_mod.parse(diff_text)
    end
  end

  state.set_commit(idx)

  local ui_state = state.get_ui()
  if ui_state then
    render_explorer(ui_state.explorer_buf)
    if ui_state.view_mode == "split" and ui_state.split_buf then
      render_split(ui_state)
    else
      render_diff(ui_state.diff_buf)
    end
  end
end

--- Select a file in the explorer and render its diff.
---@param idx number
function M.select_file(idx)
  state.set_file(idx)
  local ui_state = state.get_ui()
  if ui_state then
    render_explorer(ui_state.explorer_buf)
    if ui_state.view_mode == "split" and ui_state.split_buf then
      render_split(ui_state)
    else
      render_diff(ui_state.diff_buf)
    end
  end
end

--- Set up keymaps for the explorer buffer.
---@param buf number
local function setup_explorer_keymaps(buf)
  local opts = { buffer = buf, noremap = true, silent = true }

  -- Enter: select commit or file under cursor
  vim.keymap.set("n", "<CR>", function()
    if not explorer_line_map then
      return
    end
    local cursor = vim.api.nvim_win_get_cursor(0)
    local entry = explorer_line_map[cursor[1]]
    if not entry then
      return
    end

    if entry.type == "commit" then
      M.select_commit(entry.idx)
    elseif entry.type == "file" then
      M.select_file(entry.idx)
    end
  end, opts)

  -- q: close review
  vim.keymap.set("n", "q", function()
    M.close()
  end, opts)
end

--- Get line info at cursor in the diff buffer.
--- Returns the source line number and side for the current cursor position.
---@return table|nil  {new_lnum, old_lnum, type}
function M.get_cursor_line_info()
  local file = state.active_current_file()
  if not file then
    return nil
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local display_line = cursor[1]

  local dn, do_ = diff_mod.build_line_map(file.hunks)
  return {
    new_lnum = dn[display_line],
    old_lnum = do_[display_line],
  }
end

--- Set up keymaps for the diff buffer.
---@param buf number
local function setup_diff_keymaps(buf)
  local opts = { buffer = buf, noremap = true, silent = true }

  -- q: close review
  vim.keymap.set("n", "q", function()
    M.close()
  end, opts)

  -- ]c: next hunk
  vim.keymap.set("n", "]c", function()
    local file = state.active_current_file()
    if not file then
      return
    end
    local cursor = vim.api.nvim_win_get_cursor(0)
    local current_line = cursor[1]

    -- Find the next hunk header line
    local display_line = 0
    for _, hunk in ipairs(file.hunks) do
      display_line = display_line + 1 -- hunk header
      if display_line > current_line then
        vim.api.nvim_win_set_cursor(0, { display_line, 0 })
        return
      end
      display_line = display_line + #hunk.lines
    end
  end, opts)

  -- [c: prev hunk
  vim.keymap.set("n", "[c", function()
    local file = state.active_current_file()
    if not file then
      return
    end
    local cursor = vim.api.nvim_win_get_cursor(0)
    local current_line = cursor[1]

    -- Collect all hunk header positions
    local hunk_positions = {}
    local display_line = 0
    for _, hunk in ipairs(file.hunks) do
      display_line = display_line + 1
      table.insert(hunk_positions, display_line)
      display_line = display_line + #hunk.lines
    end

    -- Find the last header before current line
    for i = #hunk_positions, 1, -1 do
      if hunk_positions[i] < current_line then
        vim.api.nvim_win_set_cursor(0, { hunk_positions[i], 0 })
        return
      end
    end
  end, opts)

  -- ]f: next file
  vim.keymap.set("n", "]f", function()
    local s = state.get()
    local files = state.active_files()
    if s and s.current_file_idx < #files then
      M.select_file(s.current_file_idx + 1)
    end
  end, opts)

  -- [f: prev file
  vim.keymap.set("n", "[f", function()
    local s = state.get()
    if s and s.current_file_idx > 1 then
      M.select_file(s.current_file_idx - 1)
    end
  end, opts)

  -- a: add note on current line
  vim.keymap.set("n", "a", function()
    M.open_note_float()
  end, opts)

  -- A: add note on visual selection (range)
  vim.keymap.set("v", "A", function()
    -- Exit visual mode first to get marks
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
    vim.schedule(function()
      M.open_note_float({ range = true })
    end)
  end, opts)

  -- e: edit note on current line
  vim.keymap.set("n", "e", function()
    M.edit_note_at_cursor()
  end, opts)

  -- d: delete note on current line
  vim.keymap.set("n", "d", function()
    M.delete_note_at_cursor()
  end, opts)

  -- ]n: next note
  vim.keymap.set("n", "]n", function()
    M.jump_to_note(1)
  end, opts)

  -- [n: prev note
  vim.keymap.set("n", "[n", function()
    M.jump_to_note(-1)
  end, opts)

  -- s: toggle split view
  vim.keymap.set("n", "s", function()
    M.toggle_split()
  end, opts)
end

--- Open the two-panel review layout.
function M.open()
  local s = state.get()
  if not s then
    vim.notify("No review session active", vim.log.levels.ERROR)
    return
  end

  M.setup_highlights()

  -- Create a new tab for the review
  vim.cmd("tabnew")
  local tab = vim.api.nvim_get_current_tabpage()

  -- Create buffers
  local explorer_buf = create_buf("review://explorer", { filetype = "review-explorer" })
  local diff_buf = create_buf("review://diff", { filetype = "review-diff" })

  -- Set up layout: explorer on left (30 cols), diff on right
  vim.api.nvim_set_current_buf(explorer_buf)
  vim.cmd("vsplit")
  vim.cmd("wincmd l")
  vim.api.nvim_set_current_buf(diff_buf)

  -- Resize explorer to 30 columns
  vim.cmd("wincmd h")
  vim.cmd("vertical resize 35")

  local explorer_win = vim.api.nvim_get_current_win()

  -- Move to diff window
  vim.cmd("wincmd l")
  local diff_win = vim.api.nvim_get_current_win()

  -- Window options
  for _, win in ipairs({ explorer_win, diff_win }) do
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "yes"
    vim.wo[win].wrap = false
    vim.wo[win].cursorline = true
  end

  -- Store UI state
  state.set_ui({
    explorer_buf = explorer_buf,
    explorer_win = explorer_win,
    diff_buf = diff_buf,
    diff_win = diff_win,
    tab = tab,
    view_mode = "unified",
  })

  -- Set up keymaps
  setup_explorer_keymaps(explorer_buf)
  setup_diff_keymaps(diff_buf)

  -- Render initial content
  render_explorer(explorer_buf)
  render_diff(diff_buf)

  -- Focus the explorer
  vim.api.nvim_set_current_win(explorer_win)
  -- Move cursor to first file (line 3, after header)
  if #s.files > 0 then
    vim.api.nvim_win_set_cursor(explorer_win, { 3, 0 })
  end

  -- Auto-close when tab is closed
  vim.api.nvim_create_autocmd("TabClosed", {
    callback = function(ev)
      -- Check if our tab still exists
      local tabs = vim.api.nvim_list_tabpages()
      local found = false
      for _, t in ipairs(tabs) do
        if t == tab then
          found = true
          break
        end
      end
      if not found then
        state.destroy()
      end
    end,
    once = true,
  })
end

--- Close the review layout.
function M.close()
  local ui = state.get_ui()
  if ui and ui.tab then
    -- Close the tab (this wipes the buffers too since bufhidden=wipe)
    local tabs = vim.api.nvim_list_tabpages()
    for _, t in ipairs(tabs) do
      if t == ui.tab then
        -- Switch to another tab first if this is the current one
        if vim.api.nvim_get_current_tabpage() == ui.tab then
          vim.cmd("tabprevious")
        end
        vim.cmd("tabclose " .. vim.api.nvim_tabpage_get_number(ui.tab))
        break
      end
    end
  end
  state.destroy()
end

--- Open a floating window to add a note on the current diff line.
---@param opts table|nil  {range: boolean}
function M.open_note_float(opts)
  opts = opts or {}
  local file = state.active_current_file()
  if not file then
    return
  end

  local line_info = M.get_cursor_line_info()
  if not line_info then
    vim.notify("Cannot add note here", vim.log.levels.WARN)
    return
  end

  local target_line = line_info.new_lnum or line_info.old_lnum
  local side = line_info.new_lnum and "new" or "old"
  if not target_line then
    vim.notify("Cannot add note on this line", vim.log.levels.WARN)
    return
  end

  local end_line = nil
  if opts.range then
    local start_pos = vim.api.nvim_buf_get_mark(0, "<")
    local end_pos = vim.api.nvim_buf_get_mark(0, ">")
    -- Resolve both positions to source lines
    local dn, do_ = diff_mod.build_line_map(file.hunks)
    local start_source = dn[start_pos[1]] or do_[start_pos[1]]
    local end_source = dn[end_pos[1]] or do_[end_pos[1]]
    if start_source and end_source then
      target_line = start_source
      end_line = end_source
    end
  end

  -- Create floating window
  local width = math.floor(vim.o.columns * 0.5)
  local height = 10
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  -- Editable note body with context in the title
  local note_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[note_buf].buftype = "nofile"
  vim.bo[note_buf].filetype = "markdown"

  local title = string.format(
    " %s L%d%s (%s) │ <C-s> save  <Esc> cancel ",
    file.path,
    target_line,
    end_line and ("-" .. end_line) or "",
    side
  )

  local note_win = vim.api.nvim_open_win(note_buf, true, {
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

  -- Allow :w and :wq by using BufWriteCmd
  vim.bo[note_buf].buftype = ""
  vim.bo[note_buf].modified = false

  -- Start in insert mode
  vim.cmd("startinsert")

  -- Keymaps for the note float
  local function save_and_close()
    local lines = vim.api.nvim_buf_get_lines(note_buf, 0, -1, false)
    local body = table.concat(lines, "\n")
    if body:match("%S") then
      local s = state.get()
      if s and s.mode == "pr" then
        state.add_draft(file.path, target_line, body, end_line, side == "old" and "LEFT" or "RIGHT")
      else
        state.add_note(file.path, target_line, body, end_line, side)
      end
    end
    vim.api.nvim_win_close(note_win, true)
    -- Re-render
    local ui_s = state.get_ui()
    if ui_s then
      render_explorer(ui_s.explorer_buf)
      if ui_s.view_mode == "split" and ui_s.split_buf then
        render_split(ui_s)
      else
        render_diff(ui_s.diff_buf)
      end
    end
  end

  local function cancel_and_close()
    vim.api.nvim_win_close(note_win, true)
  end

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = note_buf,
    callback = function()
      vim.bo[note_buf].modified = false
      vim.cmd("stopinsert")
      save_and_close()
    end,
  })

  local float_opts = { buffer = note_buf, noremap = true, silent = true }
  vim.keymap.set("n", "<Esc>", cancel_and_close, float_opts)
  vim.keymap.set({ "n", "i" }, "<C-s>", function()
    vim.cmd("stopinsert")
    save_and_close()
  end, float_opts)
end

--- Edit the note at the current cursor position.
function M.edit_note_at_cursor()
  local file = state.active_current_file()
  if not file then
    return
  end

  local line_info = M.get_cursor_line_info()
  if not line_info then
    return
  end

  local target_line = line_info.new_lnum or line_info.old_lnum
  local side = line_info.new_lnum and "new" or "old"
  if not target_line then
    return
  end

  -- Find existing note at this position
  local s = state.get()
  if not s then
    return
  end

  local note_idx = nil
  for i, note in ipairs(s.notes) do
    if note.file_path == file.path and note.line == target_line and note.side == side then
      note_idx = i
      break
    end
  end

  if not note_idx then
    vim.notify("No note on this line", vim.log.levels.INFO)
    return
  end

  local note = s.notes[note_idx]

  -- Open float pre-populated with note body
  local width = math.floor(vim.o.columns * 0.5)
  local height = 10
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local note_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[note_buf].filetype = "markdown"
  local body_lines = vim.split(note.body, "\n")
  vim.api.nvim_buf_set_lines(note_buf, 0, -1, false, body_lines)

  -- Allow :w and :wq
  vim.bo[note_buf].buftype = ""
  vim.bo[note_buf].modified = false

  local note_win = vim.api.nvim_open_win(note_buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " Edit Note  <C-s> save  :wq ",
    title_pos = "center",
  })

  local function save_and_close()
    local lines = vim.api.nvim_buf_get_lines(note_buf, 0, -1, false)
    note.body = table.concat(lines, "\n")
    vim.api.nvim_win_close(note_win, true)
    local ui_s = state.get_ui()
    if ui_s then
      if ui_s.view_mode == "split" and ui_s.split_buf then
        render_split(ui_s)
      else
        render_diff(ui_s.diff_buf)
      end
    end
  end

  local function cancel_and_close()
    vim.api.nvim_win_close(note_win, true)
  end

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = note_buf,
    callback = function()
      vim.bo[note_buf].modified = false
      vim.cmd("stopinsert")
      save_and_close()
    end,
  })

  local float_opts = { buffer = note_buf, noremap = true, silent = true }
  vim.keymap.set("n", "<Esc>", cancel_and_close, float_opts)
  vim.keymap.set({ "n", "i" }, "<C-s>", function()
    vim.cmd("stopinsert")
    save_and_close()
  end, float_opts)
end

--- Delete the note at the current cursor position.
function M.delete_note_at_cursor()
  local file = state.active_current_file()
  if not file then
    return
  end

  local line_info = M.get_cursor_line_info()
  if not line_info then
    return
  end

  local target_line = line_info.new_lnum or line_info.old_lnum
  local side = line_info.new_lnum and "new" or "old"
  if not target_line then
    return
  end

  local s = state.get()
  if not s then
    return
  end

  for i, note in ipairs(s.notes) do
    if note.file_path == file.path and note.line == target_line and note.side == side then
      table.remove(s.notes, i)
      vim.notify("Note deleted", vim.log.levels.INFO)
      local ui = state.get_ui()
      if ui then
        render_explorer(ui.explorer_buf)
        render_diff(ui.diff_buf)
      end
      return
    end
  end

  vim.notify("No note on this line", vim.log.levels.INFO)
end

--- Jump to the next or previous note in the current file.
---@param direction number  1 for next, -1 for previous
function M.jump_to_note(direction)
  local file = state.active_current_file()
  if not file then
    return
  end

  local notes = state.get_notes(file.path)
  if #notes == 0 then
    vim.notify("No notes in this file", vim.log.levels.INFO)
    return
  end

  local _, _, new_to_display, old_to_display = diff_mod.build_line_map(file.hunks)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local current_display = cursor[1]

  -- Collect display positions of all notes
  local note_positions = {}
  for _, note in ipairs(notes) do
    local pos
    if note.side == "old" then
      pos = old_to_display[note.line]
    else
      pos = new_to_display[note.line]
    end
    if pos then
      table.insert(note_positions, pos)
    end
  end

  table.sort(note_positions)

  if #note_positions == 0 then
    return
  end

  local target
  if direction > 0 then
    -- Find first position after current
    for _, pos in ipairs(note_positions) do
      if pos > current_display then
        target = pos
        break
      end
    end
    -- Wrap around
    if not target then
      target = note_positions[1]
    end
  else
    -- Find last position before current
    for i = #note_positions, 1, -1 do
      if note_positions[i] < current_display then
        target = note_positions[i]
        break
      end
    end
    -- Wrap around
    if not target then
      target = note_positions[#note_positions]
    end
  end

  if target then
    vim.api.nvim_win_set_cursor(0, { target, 0 })
  end
end

--- Refresh both panels (call after state changes).
function M.refresh()
  local ui_state = state.get_ui()
  if not ui_state then
    return
  end
  if vim.api.nvim_buf_is_valid(ui_state.explorer_buf) then
    render_explorer(ui_state.explorer_buf)
  end
  if ui_state.view_mode == "split" and ui_state.split_buf then
    render_split(ui_state)
  elseif vim.api.nvim_buf_is_valid(ui_state.diff_buf) then
    render_diff(ui_state.diff_buf)
  end
end

return M
