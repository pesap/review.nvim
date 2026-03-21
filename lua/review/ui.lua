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
  note_published = "ReviewNotePublished",
  note_draft = "ReviewNoteDraft",
  note_ref = "ReviewNoteRef",
}

--- Set up highlight groups (called once).
---@param colorblind boolean
function M.setup_highlights(colorblind)
  local set = vim.api.nvim_set_hl
  if colorblind then
    -- Blue/yellow scheme — safe for protanopia, deuteranopia, tritanopia
    set(0, HL.add, { bg = "#1a3a4a" })
    set(0, HL.del, { bg = "#4a3a1a" })
    set(0, HL.add_text, { bg = "#2a5a6a", bold = true })
    set(0, HL.del_text, { bg = "#6a5a2a", bold = true })
    set(0, HL.status_a, { fg = "#61afef" })
    set(0, HL.status_d, { fg = "#d19a66" })
  else
    set(0, HL.add, { bg = "#2a4a2a" })
    set(0, HL.del, { bg = "#4a2a2a" })
    set(0, HL.add_text, { bg = "#3a6a3a", bold = true })
    set(0, HL.del_text, { bg = "#6a3a3a", bold = true })
    set(0, HL.status_a, { fg = "#98c379" })
    set(0, HL.status_d, { fg = "#e06c75" })
  end
  set(0, HL.hunk_header, { fg = "#888888", italic = true })
  set(0, HL.file_header, { fg = "#61afef", bold = true })
  set(0, HL.explorer_file, { fg = "#abb2bf" })
  set(0, HL.explorer_active, { fg = "#61afef", bold = true })
  set(0, HL.status_m, { fg = "#e5c07b" })
  set(0, HL.note_sign, { fg = "#c678dd", bold = true })
  set(0, HL.commit, { fg = "#d19a66" })
  set(0, HL.commit_active, { fg = "#e5c07b", bold = true })
  set(0, HL.commit_author, { fg = "#888888", italic = true })
  set(0, HL.note_published, { fg = "#98c379" })
  set(0, HL.note_draft, { fg = "#e5c07b" })
  set(0, HL.note_ref, { fg = "#61afef", underline = true })
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

--- Set up :w, :wq, :q, <C-s>, <Esc> handling for a note float buffer.
---@param note_buf number
---@param note_win number
---@param save_fn function  Called to save (no args)
---@param close_fn function  Called to close (no args)
local function setup_note_float_keymaps(note_buf, note_win, save_fn, close_fn)
  local saved = false

  local function do_save()
    if saved then
      return
    end
    saved = true
    vim.cmd("stopinsert")
    save_fn()
  end

  local function do_close()
    if vim.api.nvim_win_is_valid(note_win) then
      close_fn()
    end
  end

  -- Use acwrite so :w triggers BufWriteCmd
  vim.bo[note_buf].buftype = "acwrite"

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = note_buf,
    callback = function()
      do_save()
      -- Mark unmodified so :q after :w doesn't warn
      if vim.api.nvim_buf_is_valid(note_buf) then
        vim.bo[note_buf].modified = false
      end
    end,
  })

  local float_opts = { buffer = note_buf, noremap = true, silent = true }

  -- <Esc>: cancel (no save)
  vim.keymap.set("n", "<Esc>", function()
    vim.cmd("stopinsert")
    do_close()
  end, float_opts)

  -- <C-s>: save and close
  vim.keymap.set({ "n", "i" }, "<C-s>", function()
    do_save()
    do_close()
  end, float_opts)
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

    local file_notes = state.get_notes(file.path)
    local note_count = #file_notes
    local note_badge = ""
    if note_count > 0 then
      local staged_count = 0
      for _, n in ipairs(file_notes) do
        if n.status == "staged" then
          staged_count = staged_count + 1
        end
      end
      if staged_count > 0 then
        note_badge = string.format(" [%d/%d]", staged_count, note_count)
      else
        note_badge = " [" .. note_count .. "]"
      end
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
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
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

        -- Pre-compute word diffs for paired lines (once per pair)
        local num_pairs = math.min(#dels, #adds)
        local pair_diffs = {}
        for j = 1, num_pairs do
          local d_pair = pair_map[dels[j].idx]
          if d_pair then
            local del_l = hunk.lines[d_pair[1]]
            local add_l = hunk.lines[d_pair[2]]
            pair_diffs[j] = { diff_mod.word_diff(del_l.text, add_l.text) }
          end
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

            if pair_diffs[j] then
              local old_ranges = pair_diffs[j][1]
              local gutter_len = #num + 3
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

            if pair_diffs[j] then
              local new_ranges = pair_diffs[j][2]
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

  M.refresh()
end

--- Select a file in the explorer and render its diff.
---@param idx number
function M.select_file(idx)
  state.set_file(idx)
  M.refresh()
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
      -- Auto-jump to diff window
      local ui_state = state.get_ui()
      if ui_state and vim.api.nvim_win_is_valid(ui_state.diff_win) then
        vim.api.nvim_set_current_win(ui_state.diff_win)
      end
    end
  end, opts)

  local km = require("review").config.keymaps

  vim.keymap.set("n", km.close, function()
    M.close()
  end, opts)

  vim.keymap.set("n", km.notes_list, function()
    M.open_notes_list()
  end, opts)
end

--- Get the diff window, preferring the current window if it's a diff window.
---@return number|nil win
local function get_diff_win()
  local ui_state = state.get_ui()
  if not ui_state then
    return nil
  end
  -- Check if current window is the diff or split window
  local cur_win = vim.api.nvim_get_current_win()
  if cur_win == ui_state.diff_win or cur_win == ui_state.split_win then
    return cur_win
  end
  -- Default to diff_win
  if ui_state.diff_win and vim.api.nvim_win_is_valid(ui_state.diff_win) then
    return ui_state.diff_win
  end
  return nil
end

--- Get line info at cursor in the diff buffer.
--- Returns the source line number and side for the current cursor position.
---@return table|nil  {new_lnum, old_lnum, type}
function M.get_cursor_line_info()
  local file = state.active_current_file()
  if not file then
    return nil
  end

  local win = get_diff_win()
  if not win then
    return nil
  end

  local cursor = vim.api.nvim_win_get_cursor(win)
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

  local km = require("review").config.keymaps

  vim.keymap.set("n", km.close, function()
    M.close()
  end, opts)

  vim.keymap.set("n", km.next_hunk, function()
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

  vim.keymap.set("n", km.prev_hunk, function()
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

  vim.keymap.set("n", km.next_file, function()
    local s = state.get()
    local files = state.active_files()
    if s and s.current_file_idx < #files then
      M.select_file(s.current_file_idx + 1)
    end
  end, opts)

  vim.keymap.set("n", km.prev_file, function()
    local s = state.get()
    if s and s.current_file_idx > 1 then
      M.select_file(s.current_file_idx - 1)
    end
  end, opts)

  vim.keymap.set("n", km.add_note, function()
    M.open_note_float()
  end, opts)

  local function visual_add_note()
    local sl = vim.fn.line("v")
    local el = vim.fn.line(".")
    M.open_note_float({ range = true, start_line = sl, end_line = el })
  end
  local vopts = { buffer = buf, noremap = true, silent = true, nowait = true }
  vim.keymap.set("v", km.add_note, visual_add_note, vopts)

  vim.keymap.set("n", km.edit_note, function()
    M.edit_note_at_cursor()
  end, opts)

  vim.keymap.set("n", km.delete_note, function()
    M.delete_note_at_cursor()
  end, opts)

  vim.keymap.set("n", km.next_note, function()
    M.jump_to_note(1)
  end, opts)

  vim.keymap.set("n", km.prev_note, function()
    M.jump_to_note(-1)
  end, opts)

  vim.keymap.set("n", km.toggle_split, function()
    M.toggle_split()
  end, opts)

  vim.keymap.set("n", km.notes_list, function()
    M.open_notes_list()
  end, opts)

  vim.keymap.set("n", km.suggestion, function()
    M.open_note_float({ suggestion = true })
  end, opts)

  vim.keymap.set("v", km.suggestion, function()
    local sl = vim.fn.line("v")
    local el = vim.fn.line(".")
    M.open_note_float({ range = true, suggestion = true, start_line = sl, end_line = el })
  end, vopts)
end

--- Open the two-panel review layout.
function M.open()
  local s = state.get()
  if not s then
    vim.notify("No review session active", vim.log.levels.ERROR)
    return
  end

  local config = require("review").config
  M.setup_highlights(config.colorblind)

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
    view_mode = config.view or "unified",
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

  local dn, do_ = diff_mod.build_line_map(file.hunks)
  local target_line, end_line, side

  if opts.range then
    -- Use display line numbers passed directly from visual mode keymap
    local sl = opts.start_line or vim.fn.line("'<")
    local el = opts.end_line or vim.fn.line("'>")
    if sl > el then
      sl, el = el, sl
    end
    local start_source = dn[sl] or do_[sl]
    local end_source = dn[el] or do_[el]
    if start_source and end_source then
      target_line = math.min(start_source, end_source)
      end_line = math.max(start_source, end_source)
      side = dn[sl] and "new" or "old"
    end
  else
    -- Use cursor position
    local line_info = M.get_cursor_line_info()
    if line_info then
      target_line = line_info.new_lnum or line_info.old_lnum
      side = line_info.new_lnum and "new" or "old"
    end
  end

  if not target_line then
    vim.notify("Cannot add note on this line", vim.log.levels.WARN)
    return
  end

  -- Create floating window
  local width = math.floor(vim.o.columns * 0.5)
  local height = 10
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local is_suggestion = opts.suggestion or false
  local note_type = is_suggestion and "suggestion" or "comment"

  -- Editable note body with context in the title
  local note_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(note_buf, "review://note-" .. note_buf)

  local kind_label = is_suggestion and "Suggestion" or "Note"
  local title = string.format(
    " %s L%d%s (%s) │ %s │ <C-s> save  <Esc> cancel ",
    file.path,
    target_line,
    end_line and ("-" .. end_line) or "",
    side,
    kind_label
  )

  -- Pre-populate suggestion template with selected diff lines
  if is_suggestion then
    local selected_text = {}
    local ui_state = state.get_ui()
    if ui_state and vim.api.nvim_buf_is_valid(ui_state.diff_buf) then
      local sl_display = opts.start_line or vim.api.nvim_win_get_cursor(get_diff_win() or 0)[1]
      local el_display = opts.end_line or sl_display
      if sl_display > el_display then
        sl_display, el_display = el_display, sl_display
      end
      local buf_lines = vim.api.nvim_buf_get_lines(ui_state.diff_buf, sl_display - 1, el_display, false)
      for _, l in ipairs(buf_lines) do
        -- Strip the gutter (line numbers + separator), keep just the code
        local code = l:match("│.│(.*)$") or l
        table.insert(selected_text, code)
      end
    end
    local template = { "```suggestion" }
    for _, t in ipairs(selected_text) do
      table.insert(template, t)
    end
    table.insert(template, "```")
    table.insert(template, "")
    vim.api.nvim_buf_set_lines(note_buf, 0, -1, false, template)
  end

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

  vim.bo[note_buf].bufhidden = "wipe"

  -- Start in insert mode (at end for suggestions so user can edit the code)
  if is_suggestion then
    -- Place cursor inside the suggestion block
    local line_count = vim.api.nvim_buf_line_count(note_buf)
    vim.api.nvim_win_set_cursor(note_win, { math.max(1, line_count - 2), 0 })
  end
  vim.cmd("startinsert")

  setup_note_float_keymaps(note_buf, note_win, function()
    local lines = vim.api.nvim_buf_get_lines(note_buf, 0, -1, false)
    local body = table.concat(lines, "\n")
    if body:match("%S") then
      local s = state.get()
      if s and s.mode == "pr" then
        state.add_draft(file.path, target_line, body, end_line, side == "old" and "LEFT" or "RIGHT")
      else
        state.add_note(file.path, target_line, body, end_line, side, note_type)
      end
    end
    M.refresh()
  end, function()
    vim.api.nvim_win_close(note_win, true)
  end)
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

  local note, note_idx = state.find_note_at(file.path, target_line, side)
  if not note then
    vim.notify("No note on this line", vim.log.levels.INFO)
    return
  end

  local width = math.floor(vim.o.columns * 0.5)
  local height = 10
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local note_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[note_buf].filetype = "markdown"
  vim.api.nvim_buf_set_name(note_buf, "review://note-edit-" .. note_buf)
  local body_lines = vim.split(note.body, "\n")
  vim.api.nvim_buf_set_lines(note_buf, 0, -1, false, body_lines)

  vim.bo[note_buf].bufhidden = "wipe"

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

  setup_note_float_keymaps(note_buf, note_win, function()
    local lines = vim.api.nvim_buf_get_lines(note_buf, 0, -1, false)
    state.update_note_body(note_idx, table.concat(lines, "\n"))
    M.refresh()
  end, function()
    vim.api.nvim_win_close(note_win, true)
  end)
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

  local _, note_idx = state.find_note_at(file.path, target_line, side)
  if not note_idx then
    vim.notify("No note on this line", vim.log.levels.INFO)
    return
  end

  state.remove_note(note_idx)
  vim.notify("Note deleted", vim.log.levels.INFO)
  M.refresh()
end

--- Resolve a note to a display line in a file's diff.
---@param note ReviewNote
---@param hunks ReviewHunk[]
---@return number|nil display_line
local function note_to_display_line(note, hunks)
  local _, _, new_to_display, old_to_display = diff_mod.build_line_map(hunks)
  if note.side == "old" then
    return old_to_display[note.line]
  else
    return new_to_display[note.line]
  end
end

--- Jump to the next or previous note across all files.
---@param direction number  1 for next, -1 for previous
function M.jump_to_note(direction)
  local s = state.get()
  if not s then
    return
  end

  local all_notes = state.get_notes()
  if #all_notes == 0 then
    vim.notify("No notes", vim.log.levels.INFO)
    return
  end

  local win = get_diff_win()
  if not win then
    return
  end

  local files = state.active_files()
  local cur_fi = s.current_file_idx
  local cur_line = vim.api.nvim_win_get_cursor(win)[1]

  -- Build flat list of jumpable notes, computing line maps once per file
  local entries = {}
  for fi, file in ipairs(files) do
    local file_notes = state.get_notes(file.path)
    if #file_notes > 0 then
      local _, _, ntd, otd = diff_mod.build_line_map(file.hunks)
      for _, note in ipairs(file_notes) do
        local dl = (note.side == "old") and otd[note.line] or ntd[note.line]
        if dl then
          local dl_end = dl
          if note.end_line then
            local end_dl = (note.side == "old") and otd[note.end_line] or ntd[note.end_line]
            dl_end = end_dl or dl
          end
          table.insert(entries, { fi = fi, note = note, dl = dl, dl_end = dl_end })
        end
      end
    end
  end

  if #entries == 0 then
    vim.notify("No notes visible", vim.log.levels.INFO)
    return
  end

  table.sort(entries, function(a, b)
    if a.fi ~= b.fi then
      return a.fi < b.fi
    end
    return a.dl < b.dl
  end)

  -- Check if cursor is currently inside a note's range
  local on_entry_idx = nil
  for i, e in ipairs(entries) do
    if e.fi == cur_fi and cur_line >= e.dl and cur_line <= e.dl_end then
      on_entry_idx = i
      break
    end
  end

  local target
  if on_entry_idx then
    -- We're on a note — move to the next/prev different note
    if direction > 0 then
      target = entries[on_entry_idx < #entries and on_entry_idx + 1 or 1]
    else
      target = entries[on_entry_idx > 1 and on_entry_idx - 1 or #entries]
    end
  else
    -- We're not on a note — find closest in the given direction
    if direction > 0 then
      for _, e in ipairs(entries) do
        if e.fi > cur_fi or (e.fi == cur_fi and e.dl >= cur_line) then
          target = e
          break
        end
      end
      target = target or entries[1]
    else
      for i = #entries, 1, -1 do
        local e = entries[i]
        if e.fi < cur_fi or (e.fi == cur_fi and e.dl_end <= cur_line) then
          target = e
          break
        end
      end
      target = target or entries[#entries]
    end
  end

  if not target then
    return
  end

  -- Jump
  if target.fi ~= cur_fi then
    state.set_file(target.fi)
    M.refresh()
  end

  -- Resolve display line fresh (after potential re-render)
  local target_file = files[target.fi]
  local dl = note_to_display_line(target.note, target_file.hunks)
  if dl then
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_cursor(win, { dl, 0 })
  end
end

--- Open a floating window listing all notes across all files.
--- Pressing <CR> on a note jumps to that file and line.
function M.open_notes_list()
  local s = state.get()
  if not s then
    return
  end

  local all_notes = state.get_notes()
  if #all_notes == 0 then
    vim.notify("No notes yet", vim.log.levels.INFO)
    return
  end

  local lines = {}
  local note_refs = {} -- maps display line -> {note_idx, file_path, line, note_id}
  local highlight_rows = {} -- {line_idx, hl_group, col_start, col_end}

  -- Split notes by status
  local drafts = {}
  local staged = {}
  local published = {}
  for i, note in ipairs(all_notes) do
    local entry = { idx = i, note = note }
    if note.status == "published" then
      table.insert(published, entry)
    elseif note.status == "staged" then
      table.insert(staged, entry)
    else
      table.insert(drafts, entry)
    end
  end

  -- Render a section of notes grouped by file
  local function render_section(section_notes, section_label, status_char, status_hl)
    if #section_notes == 0 then
      return
    end

    table.insert(lines, section_label)
    highlight_rows[#lines] = { hl = HL.file_header }
    note_refs[#lines] = false

    -- Group by file
    local by_file = {}
    local file_order = {}
    for _, entry in ipairs(section_notes) do
      local fp = entry.note.file_path
      if not by_file[fp] then
        by_file[fp] = {}
        table.insert(file_order, fp)
      end
      table.insert(by_file[fp], entry)
    end

    for _, fp in ipairs(file_order) do
      table.insert(lines, "  " .. fp)
      highlight_rows[#lines] = { hl = HL.explorer_file }
      note_refs[#lines] = false

      for _, entry in ipairs(by_file[fp]) do
        local note = entry.note
        local line_ref = tostring(note.line)
        if note.end_line then
          line_ref = line_ref .. "-" .. tostring(note.end_line)
        end
        local body_preview = note.body:match("^([^\n]*)") or ""
        if #body_preview > 50 then
          body_preview = body_preview:sub(1, 47) .. "..."
        end
        local icon = (note.note_type == "suggestion") and "S" or " "
        local url_suffix = note.url and (" " .. note.url) or ""
        local display = string.format(
          "   %s %s #%-3d L%-6s %s%s",
          status_char,
          icon,
          note.id or 0,
          line_ref,
          body_preview,
          url_suffix
        )
        table.insert(lines, display)
        highlight_rows[#lines] = { hl = status_hl, col_start = 3, col_end = 4 }
        note_refs[#lines] = {
          idx = entry.idx,
          file_path = fp,
          line = note.line,
          side = note.side,
          note_id = note.id,
        }
      end
    end

    table.insert(lines, "")
    note_refs[#lines] = false
  end

  render_section(staged, "Staged", "+", HL.note_published)
  render_section(drafts, "Draft", "-", HL.note_draft)
  render_section(published, "Published", "*", HL.note_sign)

  -- Create float
  local width = math.min(math.floor(vim.o.columns * 0.7), 80)
  local height = math.min(#lines, math.floor(vim.o.lines * 0.6))
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local list_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[list_buf].buftype = "nofile"
  vim.bo[list_buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(list_buf, 0, -1, false, lines)
  vim.bo[list_buf].modifiable = false

  local list_win = vim.api.nvim_open_win(list_buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = string.format(
      " Notes (%d staged, %d draft, %d published) │ s stage  P publish  C clear  q close ",
      #staged,
      #drafts,
      #published
    ),
    title_pos = "center",
  })

  vim.wo[list_win].cursorline = true

  -- Highlights
  local ns = vim.api.nvim_create_namespace("review_notes_list")
  for i, _ in ipairs(lines) do
    local hr = highlight_rows[i]
    if hr then
      vim.api.nvim_buf_add_highlight(list_buf, ns, hr.hl, i - 1, hr.col_start or 0, hr.col_end or -1)
    end
    -- Highlight #<number> references in body previews
    if note_refs[i] and note_refs[i] ~= false then
      local line_text = lines[i]
      local search_start = 1
      while true do
        local s_pos, e_pos = line_text:find("#%d+", search_start)
        if not s_pos then
          break
        end
        -- Skip the note's own #id (which appears early in the line)
        local ref_id = tonumber(line_text:sub(s_pos + 1, e_pos))
        if ref_id and note_refs[i].note_id and ref_id ~= note_refs[i].note_id then
          vim.api.nvim_buf_add_highlight(list_buf, ns, HL.note_ref, i - 1, s_pos - 1, e_pos)
        end
        search_start = e_pos + 1
      end
    end
  end

  local buf_opts = { buffer = list_buf, noremap = true, silent = true }

  -- q / Esc: close
  vim.keymap.set("n", "q", function()
    vim.api.nvim_win_close(list_win, true)
  end, buf_opts)
  vim.keymap.set("n", "<Esc>", function()
    vim.api.nvim_win_close(list_win, true)
  end, buf_opts)

  -- s: toggle draft <-> staged
  vim.keymap.set("n", "s", function()
    local cursor = vim.api.nvim_win_get_cursor(list_win)
    local ref = note_refs[cursor[1]]
    if not ref or ref == false or not ref.note_id then
      return
    end
    state.toggle_staged(ref.note_id)
    vim.api.nvim_win_close(list_win, true)
    M.open_notes_list()
    M.refresh()
  end, buf_opts)

  -- P: publish all staged notes
  vim.keymap.set("n", "P", function()
    local staged_notes = {}
    for _, note in ipairs(all_notes) do
      if note.status == "staged" then
        table.insert(staged_notes, note)
      end
    end

    if #staged_notes == 0 then
      vim.notify("No staged notes to publish", vim.log.levels.INFO)
      return
    end

    local forge = require("review.forge")
    local info = forge.detect()

    if not info then
      -- No PR/MR detected, publish locally only
      local count = state.publish_staged()
      vim.notify(count .. " note(s) published locally (no PR/MR detected)", vim.log.levels.INFO)
      vim.api.nvim_win_close(list_win, true)
      M.open_notes_list()
      M.refresh()
      return
    end

    vim.notify(
      string.format("Publishing %d note(s) to %s PR #%d...", #staged_notes, info.forge, info.pr_number),
      vim.log.levels.INFO
    )

    local ctx, ctx_err = forge.resolve_context(info)
    if not ctx then
      vim.notify("Failed to resolve context: " .. (ctx_err or "unknown"), vim.log.levels.ERROR)
      return
    end

    local url_map = {}
    local errors = {}
    for _, note in ipairs(staged_notes) do
      local url, err = forge.post_comment(info, note, ctx)
      if url then
        url_map[note.id] = url
      elseif err then
        table.insert(errors, string.format("#%d: %s", note.id, err))
      end
    end

    local count = state.publish_staged(url_map)

    if #errors > 0 then
      vim.notify(
        string.format("%d published, %d failed:\n%s", count, #errors, table.concat(errors, "\n")),
        vim.log.levels.WARN
      )
    else
      vim.notify(count .. " note(s) published to " .. info.forge, vim.log.levels.INFO)
    end

    vim.api.nvim_win_close(list_win, true)
    M.open_notes_list()
    M.refresh()
  end, buf_opts)

  -- C: clear all notes
  vim.keymap.set("n", "C", function()
    local count = #all_notes
    state.clear_notes()
    vim.notify(count .. " note(s) cleared", vim.log.levels.INFO)
    vim.api.nvim_win_close(list_win, true)
    M.refresh()
  end, buf_opts)

  -- gd: jump to referenced note (find #<id> under cursor or in current line)
  vim.keymap.set("n", "gd", function()
    local cursor = vim.api.nvim_win_get_cursor(list_win)
    local line_text = lines[cursor[1]]
    if not line_text then
      return
    end
    -- Find #<number> references in the line (skip the note's own ID)
    local ref = note_refs[cursor[1]]
    local own_id = (ref and ref ~= false) and ref.note_id or nil
    for ref_str in line_text:gmatch("#(%d+)") do
      local ref_id = tonumber(ref_str)
      if ref_id and ref_id ~= own_id then
        -- Find the line in the notes list that has this note_id
        for line_nr, nr in pairs(note_refs) do
          if nr and nr ~= false and nr.note_id == ref_id then
            vim.api.nvim_win_set_cursor(list_win, { line_nr, 0 })
            return
          end
        end
        vim.notify("Note #" .. ref_id .. " not found", vim.log.levels.WARN)
        return
      end
    end
    vim.notify("No reference found on this line", vim.log.levels.INFO)
  end, buf_opts)

  -- <CR>: jump to note
  vim.keymap.set("n", "<CR>", function()
    local cursor = vim.api.nvim_win_get_cursor(list_win)
    local line_nr = cursor[1]
    local ref = note_refs[line_nr]
    if not ref or ref == false then
      return
    end

    local target_path = ref.file_path
    local target_line = ref.line
    local target_side = ref.side

    vim.api.nvim_win_close(list_win, true)

    vim.schedule(function()
      local sess = state.get()
      if sess and sess.current_commit_idx then
        state.set_commit(nil)
      end

      local active = state.active_files()
      local file_idx, file
      for i, f in ipairs(active) do
        if f.path == target_path then
          file_idx = i
          file = f
          break
        end
      end
      if not file then
        return
      end

      state.set_file(file_idx)
      M.refresh()

      local ui_state = state.get_ui()
      if not ui_state or not vim.api.nvim_win_is_valid(ui_state.diff_win) then
        return
      end
      vim.api.nvim_set_current_win(ui_state.diff_win)

      local dl = note_to_display_line({ line = target_line, side = target_side }, file.hunks)
      if not dl then
        local other = target_side == "old" and "new" or "old"
        dl = note_to_display_line({ line = target_line, side = other }, file.hunks)
      end
      if dl then
        vim.api.nvim_win_set_cursor(ui_state.diff_win, { dl, 0 })
      end
    end)
  end, buf_opts)

  -- dd: delete note under cursor
  vim.keymap.set("n", "dd", function()
    local cursor = vim.api.nvim_win_get_cursor(list_win)
    local ref = note_refs[cursor[1]]
    if not ref or ref == false then
      return
    end
    state.remove_note(ref.idx)
    vim.api.nvim_win_close(list_win, true)
    M.open_notes_list()
    M.refresh()
  end, buf_opts)

  -- ]n / [n: jump between note entries in the list (skip headers and blanks)
  local num_lines = #lines
  local function jump_in_list(dir)
    local cur = vim.api.nvim_win_get_cursor(list_win)[1]
    if dir > 0 then
      for i = cur + 1, num_lines do
        if note_refs[i] and note_refs[i] ~= false then
          vim.api.nvim_win_set_cursor(list_win, { i, 0 })
          return
        end
      end
      for i = 1, cur - 1 do
        if note_refs[i] and note_refs[i] ~= false then
          vim.api.nvim_win_set_cursor(list_win, { i, 0 })
          return
        end
      end
    else
      for i = cur - 1, 1, -1 do
        if note_refs[i] and note_refs[i] ~= false then
          vim.api.nvim_win_set_cursor(list_win, { i, 0 })
          return
        end
      end
      for i = num_lines, cur + 1, -1 do
        if note_refs[i] and note_refs[i] ~= false then
          vim.api.nvim_win_set_cursor(list_win, { i, 0 })
          return
        end
      end
    end
  end

  vim.keymap.set("n", "]n", function()
    jump_in_list(1)
  end, buf_opts)
  vim.keymap.set("n", "[n", function()
    jump_in_list(-1)
  end, buf_opts)
  vim.keymap.set("n", "j", function()
    jump_in_list(1)
  end, buf_opts)
  vim.keymap.set("n", "k", function()
    jump_in_list(-1)
  end, buf_opts)
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
