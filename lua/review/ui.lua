--- All window/buffer/layout management for review.nvim
local state = require("review.state")
local diff_mod = require("review.diff")
local forge = require("review.forge")

local M = {}

local get_diff_win
local review_closing = false
local file_line_maps
local file_stats
local setup_diff_keymaps
local navigator_width
local current_navigator_width
local truncate_end_text

local HL = {
  add = "ReviewDiffAdd",
  del = "ReviewDiffDelete",
  add_text = "ReviewDiffAddText",
  del_text = "ReviewDiffDeleteText",
  diff_gutter = "ReviewDiffGutter",
  diff_context = "ReviewDiffContext",
  meta = "ReviewMeta",
  file_header = "ReviewFileHeader",
  panel_title = "ReviewPanelTitle",
  panel_meta = "ReviewPanelMeta",
  pane_bg = "ReviewPaneBg",
  float_bg = "ReviewFloatBg",
  cursorline = "ReviewCursorLine",
  window_edge = "ReviewWindowEdge",
  focus = "ReviewFocus",
  explorer_file = "ReviewExplorerFile",
  explorer_path = "ReviewExplorerPath",
  explorer_active = "ReviewExplorerActive",
  explorer_active_row = "ReviewExplorerActiveRow",
  status_m = "ReviewStatusM",
  status_a = "ReviewStatusA",
  status_d = "ReviewStatusD",
  status_a_dim = "ReviewStatusADim",
  status_d_dim = "ReviewStatusDDim",
  note_sign = "ReviewNoteSign",
  commit = "ReviewCommit",
  commit_active = "ReviewCommitActive",
  commit_author = "ReviewCommitAuthor",
  note_published = "ReviewNotePublished",
  note_draft = "ReviewNoteDraft",
  note_ref = "ReviewNoteRef",
  note_remote = "ReviewNoteRemote",
  note_remote_resolved = "ReviewNoteRemoteResolved",
  note_author = "ReviewNoteAuthor",
  note_separator = "ReviewNoteSeparator",
  threads_header = "ReviewThreadsHeader",
  vendor_group = "ReviewVendorGroup",
  local_group = "ReviewLocalGroup",
}

---@param opts table|nil
---@param success_msg string
local function copy_review_export(opts, success_msg)
  local review = package.loaded["review"] or require("review")
  if type(review.export_content) ~= "function" then
    package.loaded["review"] = nil
    review = require("review")
  end

  if type(review.export_content) ~= "function" then
    vim.notify("Could not load review.nvim clipboard exporter", vim.log.levels.ERROR)
    return
  end

  local content, err = review.export_content(opts or {})
  if not content then
    vim.notify(err, err == "No active review session" and vim.log.levels.ERROR or vim.log.levels.INFO)
    return
  end

  vim.fn.setreg('"', content)
  local copied = {}
  local ok_plus = pcall(vim.fn.setreg, "+", content)
  if ok_plus then
    table.insert(copied, "+")
  end
  local ok_star = pcall(vim.fn.setreg, "*", content)
  if ok_star then
    table.insert(copied, "*")
  end
  local target = #copied == 0 and [["]] or table.concat(copied, ", ")
  vim.notify(success_msg .. target, vim.log.levels.INFO)
end

--- Set up highlight groups (called once).
---@param colorblind boolean
function M.setup_highlights(colorblind)
  local set = vim.api.nvim_set_hl
  if colorblind then
    -- Okabe-Ito-inspired palette for better colorblind accessibility on dark backgrounds.
    set(0, HL.add, { bg = "#16384d" })
    set(0, HL.del, { bg = "#4d3410" })
    set(0, HL.add_text, { bg = "#215878", bold = true })
    set(0, HL.del_text, { bg = "#7a5318", bold = true })
    set(0, HL.status_a, { fg = "#56b4e9" })
    set(0, HL.status_d, { fg = "#e69f00" })
    set(0, HL.status_a_dim, { fg = "#4a90ba" })
    set(0, HL.status_d_dim, { fg = "#b78100" })
  else
    set(0, HL.add, { bg = "#2a4a2a" })
    set(0, HL.del, { bg = "#4a2a2a" })
    set(0, HL.add_text, { bg = "#3a6a3a", bold = true })
    set(0, HL.del_text, { bg = "#6a3a3a", bold = true })
    set(0, HL.status_a, { fg = "#98c379" })
    set(0, HL.status_d, { fg = "#e06c75" })
    set(0, HL.status_a_dim, { fg = "#70935a" })
    set(0, HL.status_d_dim, { fg = "#a85660" })
  end
  set(0, HL.pane_bg, { bg = "#101318" })
  set(0, HL.float_bg, { bg = "#141923" })
  set(0, HL.cursorline, { bg = "#1b2330" })
  set(0, HL.window_edge, { fg = "#303846", bg = "#101318" })
  set(0, HL.focus, { fg = colorblind and "#ebcb8b" or "#e5c07b", bold = true })
  set(0, HL.diff_gutter, { fg = "#5c6370" })
  set(0, HL.diff_context, { fg = "#9aa3b2" })
  set(0, HL.meta, { fg = "#888888", italic = true })
  set(0, HL.file_header, { fg = colorblind and "#d8dee9" or "#61afef", bold = true })
  set(0, HL.panel_title, { fg = colorblind and "#ebcb8b" or "#e5c07b", bold = true })
  set(0, HL.panel_meta, { fg = "#7f848e" })
  set(0, HL.explorer_file, { fg = "#abb2bf" })
  set(0, HL.explorer_path, { fg = "#7f848e", italic = true })
  set(0, HL.explorer_active, { fg = colorblind and "#88c0ff" or "#61afef", bold = true })
  set(0, HL.explorer_active_row, { bg = "#16202b" })
  set(0, HL.status_m, { fg = colorblind and "#cc79a7" or "#e5c07b" })
  set(0, HL.note_sign, { fg = colorblind and "#cc79a7" or "#c678dd", bold = true })
  set(0, HL.commit, { fg = colorblind and "#d9a441" or "#d19a66" })
  set(0, HL.commit_active, { fg = colorblind and "#ebcb8b" or "#e5c07b", bold = true })
  set(0, HL.commit_author, { fg = "#888888", italic = true })
  set(0, HL.note_published, { fg = colorblind and "#4db6ac" or "#98c379" })
  set(0, HL.note_draft, { fg = colorblind and "#ebcb8b" or "#e5c07b" })
  set(0, HL.note_ref, { fg = colorblind and "#56b4e9" or "#61afef", underline = true })
  set(0, HL.note_remote, { fg = colorblind and "#4db6ac" or "#56b6c2" })
  set(0, HL.note_remote_resolved, { fg = "#5c6370", italic = true })
  set(0, HL.note_author, { fg = colorblind and "#cc79a7" or "#c678dd", italic = true })
  set(0, HL.note_separator, { fg = "#3e4452" })
  set(0, HL.threads_header, { fg = colorblind and "#c7a252" or "#e5c07b", bold = true })
  set(0, HL.vendor_group, { fg = colorblind and "#4db6ac" or "#56b6c2", bold = true })
  set(0, HL.local_group, { fg = colorblind and "#cc79a7" or "#c678dd", bold = true })
end

--- Compute adaptive float width based on terminal size.
---@param scale number|nil  Width fraction for large screens (default 0.7)
---@param cap number|nil  Max width (default 90)
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

  return buf, win
end

---@param items string[]
---@param width number
---@return string[]
local function build_footer_legend(items, width)
  local out = {}
  local max_width = math.max(width - 2, 12)
  local current = ""

  for _, item in ipairs(items) do
    local candidate = current == "" and (" " .. item) or (current .. "  " .. item)
    if current ~= "" and vim.fn.strdisplaywidth(candidate) > max_width then
      table.insert(out, current)
      current = " " .. item
    else
      current = candidate
    end
  end

  if current ~= "" then
    table.insert(out, current)
  end

  return out
end

---@param base string
---@param segment_sets string[][]
---@param width number
---@return string
local function fit_float_title(base, segment_sets, width)
  for _, segments in ipairs(segment_sets) do
    local title = base
    if #segments > 0 then
      title = title .. " │ " .. table.concat(segments, "  ")
    end
    title = title .. " "
    if vim.fn.strdisplaywidth(title) <= width then
      return title
    end
  end

  return truncate_end_text(base .. " ", math.max(width, 8))
end

---@param win number
---@param kind string
local function apply_review_window_style(win, kind)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end

  if kind == "float" then
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
    return
  end

  vim.wo[win].winhighlight = table.concat({
    "Normal:",
    HL.pane_bg,
    ",EndOfBuffer:",
    HL.pane_bg,
    ",SignColumn:",
    HL.pane_bg,
    ",WinSeparator:",
    HL.window_edge,
    ",CursorLine:",
    HL.cursorline,
  })
  vim.wo[win].fillchars = "eob: "
end

---@param buf number
local function attach_review_quit_guard(buf)
  vim.api.nvim_create_autocmd("QuitPre", {
    buffer = buf,
    callback = function()
      if review_closing then
        return
      end
      review_closing = true
      vim.schedule(function()
        pcall(M.close)
      end)
    end,
  })
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
---@type table[]|nil  Each: {type: "header"|"separator"|"commit"|"file"|"folder", idx: number|nil}
local explorer_line_map = nil

---@param file ReviewFile
---@return table
local function file_cache(file)
  if not file._review_cache then
    file._review_cache = {}
  end
  return file._review_cache
end

---@param hunk ReviewHunk
---@return table
local function hunk_cache(hunk)
  if not hunk._review_cache then
    hunk._review_cache = {}
  end
  return hunk._review_cache
end

local function render_word_diff_config()
  local render = require("review").config.render or {}
  local word_diff = render.word_diff or {}
  return {
    enabled = word_diff.enabled ~= false,
    max_line_length = word_diff.max_line_length or 300,
    max_pairs_per_hunk = word_diff.max_pairs_per_hunk or 64,
    max_hunk_lines = word_diff.max_hunk_lines or 200,
    max_file_lines = word_diff.max_file_lines or 1500,
  }
end

---@param text string
---@param max_width number
---@return string
local function truncate_display_text(text, max_width)
  if max_width <= 0 then
    return ""
  end
  if vim.fn.strdisplaywidth(text) <= max_width then
    return text
  end

  local suffix_width = math.max(max_width - 1, 0)
  if suffix_width == 0 then
    return "\u{2026}"
  end

  local total_chars = vim.fn.strchars(text)
  local start = 0
  local suffix = text
  while start < total_chars and vim.fn.strdisplaywidth(suffix) > suffix_width do
    start = start + 1
    suffix = vim.fn.strcharpart(text, start)
  end
  return "\u{2026}" .. suffix
end

---@param text string
---@param max_width number
---@return string
local function display_prefix(text, max_width)
  if max_width <= 0 then
    return ""
  end
  local chars = vim.fn.strchars(text)
  local prefix = ""
  for i = 1, chars do
    local next = prefix .. vim.fn.strcharpart(text, i - 1, 1)
    if vim.fn.strdisplaywidth(next) > max_width then
      break
    end
    prefix = next
  end
  return prefix
end

---@param text string
---@param max_width number
---@return string
local function display_suffix(text, max_width)
  if max_width <= 0 then
    return ""
  end
  local chars = vim.fn.strchars(text)
  local suffix = text
  local start = 0
  while start < chars and vim.fn.strdisplaywidth(suffix) > max_width do
    start = start + 1
    suffix = vim.fn.strcharpart(text, start)
  end
  return suffix
end

---@param text string
---@param max_width number
---@return string
local function truncate_middle_text(text, max_width)
  if max_width <= 0 then
    return ""
  end
  if vim.fn.strdisplaywidth(text) <= max_width then
    return text
  end
  if max_width == 1 then
    return "\u{2026}"
  end

  local available = max_width - 1
  local prefix_width = math.ceil(available / 2)
  local suffix_width = math.floor(available / 2)
  local prefix = display_prefix(text, prefix_width)
  local suffix = display_suffix(text, suffix_width)
  return prefix .. "\u{2026}" .. suffix
end

---@param text string
---@param max_width number
---@return string
truncate_end_text = function(text, max_width)
  if max_width <= 0 then
    return ""
  end
  if vim.fn.strdisplaywidth(text) <= max_width then
    return text
  end
  if max_width == 1 then
    return "\u{2026}"
  end
  return display_prefix(text, max_width - 1) .. "\u{2026}"
end

---@param text string
---@param max_width number
---@return string[]
local function wrap_display_text(text, max_width)
  if max_width <= 0 then
    return { "" }
  end

  local lines = {}
  local remaining = text or ""
  while vim.fn.strdisplaywidth(remaining) > max_width do
    local prefix = display_prefix(remaining, max_width)
    local break_at = prefix:match(".*()%s")
    if break_at and break_at > 1 then
      local chunk = prefix:sub(1, break_at - 1):gsub("%s+$", "")
      table.insert(lines, chunk)
      remaining = remaining:sub(break_at + 1):gsub("^%s+", "")
    else
      table.insert(lines, prefix)
      remaining = remaining:sub(#prefix + 1)
    end
  end

  if remaining ~= "" then
    table.insert(lines, remaining)
  end
  if #lines == 0 then
    table.insert(lines, "")
  end
  return lines
end

---@param file ReviewFile
---@return number old_width, number new_width, number unified_width
local function file_line_number_widths(file)
  local cache = file_cache(file)
  if cache.line_number_widths then
    return cache.line_number_widths.old_width,
      cache.line_number_widths.new_width,
      cache.line_number_widths.unified_width
  end

  local max_old = 0
  local max_new = 0
  for _, hunk in ipairs(file.hunks) do
    for _, dl in ipairs(hunk.lines) do
      if dl.old_lnum and dl.old_lnum > max_old then
        max_old = dl.old_lnum
      end
      if dl.new_lnum and dl.new_lnum > max_new then
        max_new = dl.new_lnum
      end
    end
  end

  local old_width = math.max(4, #tostring(max_old > 0 and max_old or 0))
  local new_width = math.max(4, #tostring(max_new > 0 and max_new or 0))
  local unified_width = math.max(old_width, new_width)

  cache.line_number_widths = {
    old_width = old_width,
    new_width = new_width,
    unified_width = unified_width,
  }
  return old_width, new_width, unified_width
end

---@param lnum number|nil
---@param width number
---@return string
local function format_line_number(lnum, width)
  if not lnum then
    return string.rep(" ", width)
  end
  return string.format("%" .. tostring(width) .. "d", lnum)
end

---@return number files, number additions, number deletions, number notes
local function session_stats()
  local files = state.active_files()
  local additions, deletions = 0, 0
  for _, file in ipairs(files) do
    local fadd, fdel = file_stats(file)
    additions = additions + fadd
    deletions = deletions + fdel
  end
  return #files, additions, deletions, #state.get_notes()
end

---@param file ReviewFile
---@return number
local function visible_note_count(file)
  local file_notes = state.get_notes(file.path)
  if #file_notes == 0 then
    return 0
  end

  local _, _, n2d, o2d = file_line_maps(file)
  local note_count = 0
  for _, note in ipairs(file_notes) do
    local map = (note.side == "old") and o2d or n2d
    if type(note.line) == "number" and map[note.line] ~= nil then
      note_count = note_count + 1
    end
  end
  return note_count
end

---@param file ReviewFile
---@return number
local function file_focus_score(file)
  local additions, deletions, line_count = file_stats(file)
  local note_count = visible_note_count(file)

  local score = 0
  if file.status == "A" then
    score = score + 2
  end
  if additions >= 40 then
    score = score + 1
  end
  if line_count >= 120 then
    score = score + 1
  end
  if additions >= deletions * 2 and additions >= 20 then
    score = score + 1
  end
  if note_count == 0 and additions >= 25 then
    score = score + 1
  end

  return score
end

---@param prefix string
---@param value string
---@param max_width number
---@return string
local function format_context_line(prefix, value, max_width)
  local available = math.max(max_width - vim.fn.strdisplaywidth(prefix), 1)
  return prefix .. truncate_display_text(value, available)
end

---@return string, string|nil
local function navigator_context_lines()
  local git = require("review.git")
  local session = state.get()
  local branch = git.current_branch() or "HEAD"
  local base = session and session.base_ref or nil
  local max_width = math.max(current_navigator_width() - 1, 8)
  local branch_line = format_context_line(" ", branch, max_width)

  if base and base ~= "" and base ~= "HEAD" and branch ~= base then
    return branch_line, format_context_line(" against ", base, max_width)
  end
  return branch_line, nil
end

---@param max_width number
---@return string
local function compact_compare_label(max_width)
  local git = require("review.git")
  local session = state.get()
  if not session then
    return ""
  end

  local base = session.base_ref or "HEAD"
  local head = git.current_branch() or "HEAD"
  local commit = state.current_commit()
  if commit then
    head = commit.short_sha
  end

  local variants = {
    string.format("compare: %s -> %s", base, head),
    string.format("%s -> %s", base, head),
    string.format("%s -> %s", truncate_end_text(base, 10), truncate_end_text(head, 12)),
    string.format("%s→%s", truncate_end_text(base, 6), truncate_end_text(head, 8)),
  }

  for _, label in ipairs(variants) do
    if vim.fn.strdisplaywidth(label) <= max_width then
      return label
    end
  end
  return truncate_end_text(variants[#variants], max_width)
end

---@param max_width number
---@return string
local function compact_active_commit_label(max_width)
  local commit = state.current_commit()
  local variants
  if not commit then
    variants = {
      "Current stack",
      "stack",
    }
  else
    variants = {
      string.format("%s %s", commit.short_sha, commit.message),
      commit.short_sha,
    }
  end

  for _, label in ipairs(variants) do
    if vim.fn.strdisplaywidth(label) <= max_width then
      return label
    end
  end
  return truncate_end_text(variants[#variants], max_width)
end

---@param file ReviewFile
---@param width number
---@return string
local function build_diff_statusline(file, width)
  local additions, deletions = file_stats(file)
  local compare_budget = math.max(math.floor(width * 0.28), 12)
  local commit_budget = math.max(math.floor(width * 0.18), 8)
  local compare_label = compact_compare_label(compare_budget)
  local commit_label = compact_active_commit_label(commit_budget)
  local loading_suffix = state.comments_loading() and "  •  sync" or ""
  local right_text = compare_label .. "  •  " .. commit_label .. loading_suffix
  local right_width = vim.fn.strdisplaywidth(right_text)
  local counts_width = vim.fn.strdisplaywidth(" +" .. additions .. " -" .. deletions .. " ")
  local left_budget = math.max(width - right_width - counts_width - 6, 12)
  local path_label = truncate_middle_text(file.path, left_budget)

  return table.concat({
    "%#",
    HL.panel_meta,
    "# ",
    path_label,
    "  ",
    "%#",
    HL.status_a,
    "#+",
    tostring(additions),
    " ",
    "%#",
    HL.status_d,
    "#-",
    tostring(deletions),
    " ",
    "%#",
    HL.panel_meta,
    "#%=",
    right_text,
    " ",
  })
end

navigator_width = function()
  local cols = vim.o.columns
  if cols >= 170 then
    return 55
  end
  if cols >= 96 then
    return 34
  end
  return 21
end

current_navigator_width = function()
  local ui = state.get_ui()
  if ui then
    if ui.explorer_win and vim.api.nvim_win_is_valid(ui.explorer_win) then
      return vim.api.nvim_win_get_width(ui.explorer_win)
    end
    if ui.explorer_width and ui.explorer_width > 0 then
      return ui.explorer_width
    end
  end
  return navigator_width()
end

---@param files ReviewFile[]
---@return table[]
local function sorted_file_entries(files)
  local entries = {}
  for idx, file in ipairs(files) do
    local parts = vim.split(file.path, "/", { plain = true })
    table.insert(entries, {
      idx = idx,
      file = file,
      basename = parts[#parts] or file.path,
    })
  end

  table.sort(entries, function(a, b)
    return a.file.path:lower() < b.file.path:lower()
  end)
  return entries
end

---@param note ReviewNote
---@param file ReviewFile
---@return boolean
local function note_visible_in_file(note, file)
  if not note or not file or type(note.line) ~= "number" then
    return false
  end

  local _, _, new_to_display, old_to_display = file_line_maps(file)
  if note.side == "old" then
    return old_to_display[note.line] ~= nil
  end
  return new_to_display[note.line] ~= nil
end

---@param active_files ReviewFile[]
---@return table[]
local function build_thread_sections(active_files)
  local info = state.get_forge_info()
  local vendor_label = (info and info.forge or "vendor") .. "/"
  local by_path = {}

  for idx, file in ipairs(active_files) do
    by_path[file.path] = {
      idx = idx,
      file = file,
      vendor_count = 0,
      local_count = 0,
      first_vendor = nil,
      first_local = nil,
    }
  end

  for _, note in ipairs(state.get_notes()) do
    if not note.file_path then
      goto continue
    end
    local entry = by_path[note.file_path]
    if not entry then
      goto continue
    end
    if not note_visible_in_file(note, entry.file) then
      goto continue
    end

    if note.status == "remote" then
      if not note.resolved then
        entry.vendor_count = entry.vendor_count + 1
        if not entry.first_vendor then
          entry.first_vendor = note
        end
      end
    else
      entry.local_count = entry.local_count + 1
      if not entry.first_local then
        entry.first_local = note
      end
    end
    ::continue::
  end

  local vendor_rows = {}
  local local_rows = {}
  for path, entry in pairs(by_path) do
    if entry.vendor_count > 0 then
      table.insert(vendor_rows, {
        source = "vendor",
        label = vendor_label,
        path = path,
        idx = entry.idx,
        count = entry.vendor_count,
        note = entry.first_vendor,
      })
    end
    if entry.local_count > 0 then
      table.insert(local_rows, {
        source = "local",
        label = "local/",
        path = path,
        idx = entry.idx,
        count = entry.local_count,
        note = entry.first_local,
      })
    end
  end

  local function sort_rows(rows)
    table.sort(rows, function(a, b)
      if a.idx ~= b.idx then
        return a.idx < b.idx
      end
      return a.path < b.path
    end)
  end

  sort_rows(vendor_rows)
  sort_rows(local_rows)

  local sections = {}
  if #vendor_rows > 0 then
    table.insert(sections, { label = vendor_label, rows = vendor_rows })
  end
  if #local_rows > 0 then
    table.insert(sections, { label = "local/", rows = local_rows })
  end
  return sections
end

---@param file_path string
---@param line number|nil
---@param side string|nil
local function jump_to_file_location(file_path, line, side)
  local sess = state.get()
  if not sess then
    return
  end

  if sess.current_commit_idx then
    state.set_commit(nil)
  end

  local active = state.active_files()
  local file_idx, file
  for i, f in ipairs(active) do
    if f.path == file_path then
      file_idx = i
      file = f
      break
    end
  end
  if not file_idx or not file then
    return
  end

  state.set_file(file_idx)
  M.refresh()

  local ui_state = state.get_ui()
  if not ui_state or not vim.api.nvim_win_is_valid(ui_state.diff_win) then
    return
  end
  vim.api.nvim_set_current_win(ui_state.diff_win)

  if line then
    local _, _, new_to_display, old_to_display = file_line_maps(file)
    local primary = (side == "old") and old_to_display or new_to_display
    local dl = primary[line]
    if not dl and side then
      local fallback = (side == "old") and new_to_display or old_to_display
      dl = fallback[line]
    end
    if dl then
      vim.api.nvim_win_set_cursor(ui_state.diff_win, { dl, 0 })
    end
  end
end

---@return number|nil
local function navigator_selection_line()
  local s = state.get()
  if not s or not explorer_line_map then
    return nil
  end

  for line_nr, entry in ipairs(explorer_line_map) do
    if entry.type == "file" and entry.idx == s.current_file_idx then
      return line_nr
    end
  end

  for line_nr, entry in ipairs(explorer_line_map) do
    if entry.type == "commit" and entry.idx == s.current_commit_idx then
      return line_nr
    end
  end

  return nil
end

---@param section string
---@return number|nil
local function section_line(section)
  if not explorer_line_map then
    return nil
  end
  for line_nr, entry in ipairs(explorer_line_map) do
    if entry.section == section and entry.type ~= "header" then
      return line_nr
    end
  end
  for line_nr, entry in ipairs(explorer_line_map) do
    if entry.type == "header" and entry.section == section then
      return line_nr
    end
  end
  return nil
end

---@param section string
function M.focus_section(section)
  local ui_state = state.get_ui()
  if not ui_state or not ui_state.explorer_win or not vim.api.nvim_win_is_valid(ui_state.explorer_win) then
    return
  end
  local line_nr = section_line(section)
  if not line_nr then
    return
  end
  vim.api.nvim_set_current_win(ui_state.explorer_win)
  vim.api.nvim_win_set_cursor(ui_state.explorer_win, { line_nr, 0 })
end

local function update_window_chrome()
  local ui_state = state.get_ui()
  if not ui_state then
    return
  end

  local file = state.active_current_file()

  if ui_state.explorer_win and vim.api.nvim_win_is_valid(ui_state.explorer_win) then
    vim.wo[ui_state.explorer_win].winbar = ""
    vim.wo[ui_state.explorer_win].statusline = ""
  end

  if ui_state.diff_win and vim.api.nvim_win_is_valid(ui_state.diff_win) then
    vim.wo[ui_state.diff_win].winbar = ""
    if file then
      vim.wo[ui_state.diff_win].statusline = build_diff_statusline(file, vim.api.nvim_win_get_width(ui_state.diff_win))
    else
      vim.wo[ui_state.diff_win].statusline = ""
    end
  end
  if ui_state.split_win and vim.api.nvim_win_is_valid(ui_state.split_win) then
    vim.wo[ui_state.split_win].winbar = ""
    if file then
      vim.wo[ui_state.split_win].statusline =
        build_diff_statusline(file, vim.api.nvim_win_get_width(ui_state.split_win))
    else
      vim.wo[ui_state.split_win].statusline = ""
    end
  end
end

---@param highlights table[]
---@param line_idx number
---@param gutter_len number
---@param dl ReviewDiffLine
local function add_diff_gutter_highlights(highlights, line_idx, gutter_len, dl)
  table.insert(highlights, {
    line = line_idx,
    hl = HL.diff_gutter,
    col_start = 0,
    col_end = gutter_len,
  })

  local prefix_col = gutter_len - 2
  local symbol_hl = nil
  if dl.type == "add" then
    symbol_hl = HL.status_a
  elseif dl.type == "del" then
    symbol_hl = HL.status_d
  end
  if symbol_hl then
    table.insert(highlights, {
      line = line_idx,
      hl = symbol_hl,
      col_start = prefix_col,
      col_end = prefix_col + 1,
    })
  elseif dl.type == "ctx" then
    table.insert(highlights, {
      line = line_idx,
      hl = HL.diff_context,
      col_start = gutter_len,
      col_end = -1,
    })
  end
end

---@param file ReviewFile
---@return table display_to_new, table display_to_old, table new_to_display, table old_to_display
file_line_maps = function(file)
  local cache = file_cache(file)
  if not cache.line_maps then
    local display_to_new, display_to_old, new_to_display, old_to_display = diff_mod.build_line_map(file.hunks)
    cache.line_maps = {
      display_to_new = display_to_new,
      display_to_old = display_to_old,
      new_to_display = new_to_display,
      old_to_display = old_to_display,
    }
  end
  local maps = cache.line_maps
  return maps.display_to_new, maps.display_to_old, maps.new_to_display, maps.old_to_display
end

---@param file ReviewFile
---@return number additions, number deletions, number line_count
file_stats = function(file)
  local cache = file_cache(file)
  if cache.additions == nil or cache.deletions == nil or cache.line_count == nil then
    local additions, deletions, line_count = 0, 0, 0
    for _, hunk in ipairs(file.hunks) do
      line_count = line_count + #hunk.lines
      for _, dl in ipairs(hunk.lines) do
        if dl.type == "add" then
          additions = additions + 1
        elseif dl.type == "del" then
          deletions = deletions + 1
        end
      end
    end
    cache.additions = additions
    cache.deletions = deletions
    cache.line_count = line_count
  end
  return cache.additions, cache.deletions, cache.line_count
end

---@param file ReviewFile
---@param hunk ReviewHunk
---@return table pair_map
---@return table pair_diffs
local function hunk_word_diff_data(file, hunk)
  local cache = hunk_cache(hunk)
  if cache.word_diff_data then
    return cache.word_diff_data.pair_map, cache.word_diff_data.pair_diffs
  end

  local pair_map = {}
  local pair_diffs = {}
  local config = render_word_diff_config()
  local _, _, file_line_count = file_stats(file)

  if config.enabled and file_line_count <= config.max_file_lines and #hunk.lines <= config.max_hunk_lines then
    local word_diff_pairs = diff_mod.pair_changed_lines(hunk)
    if #word_diff_pairs <= config.max_pairs_per_hunk then
      for _, pair in ipairs(word_diff_pairs) do
        pair_map[pair[1]] = pair
        pair_map[pair[2]] = pair

        local del_line = hunk.lines[pair[1]]
        local add_line = hunk.lines[pair[2]]
        pair_diffs[pair[1]] = {
          diff_mod.word_diff(del_line.text, add_line.text, {
            max_line_length = config.max_line_length,
          }),
        }
      end
    end
  end

  cache.word_diff_data = {
    pair_map = pair_map,
    pair_diffs = pair_diffs,
  }
  return pair_map, pair_diffs
end

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

  local active_files = state.active_files()
  local _, additions, deletions = session_stats()
  local branch_line, base_line = navigator_context_lines()
  local header_indent = " "
  local file_indent = "  "
  local thread_group_indent = "   "
  local thread_row_indent = "     "
  local explorer_width = current_navigator_width()
  local row_budget = math.max(explorer_width - 7, 10)

  table.insert(lines, branch_line)
  table.insert(explorer_line_map, { type = "header", section = "context" })
  table.insert(highlights, { line = #lines - 1, hl = HL.explorer_active, col_start = 1, col_end = -1 })
  if base_line then
    table.insert(lines, base_line)
    table.insert(explorer_line_map, { type = "header", section = "context" })
    table.insert(highlights, { line = #lines - 1, hl = HL.panel_meta, col_start = 1, col_end = 9 })
    table.insert(highlights, { line = #lines - 1, hl = HL.panel_title, col_start = 9, col_end = -1 })
  end
  local files_header = string.format("%sFiles  +%d  -%d", header_indent, additions, deletions)
  table.insert(lines, files_header)
  table.insert(explorer_line_map, { type = "header", section = "files" })
  table.insert(highlights, { line = #lines - 1, hl = HL.file_header, col_start = 1, col_end = 6 })
  local plus_str = "+" .. tostring(additions)
  local minus_str = "-" .. tostring(deletions)
  local plus_start = files_header:find(plus_str, 1, true)
  if plus_start then
    plus_start = plus_start - 1
    table.insert(highlights, {
      line = #lines - 1,
      hl = HL.status_a_dim,
      col_start = plus_start,
      col_end = plus_start + #plus_str,
    })
    local minus_start = files_header:find(minus_str, plus_start + #plus_str + 1, true)
    if minus_start then
      minus_start = minus_start - 1
      table.insert(highlights, {
        line = #lines - 1,
        hl = HL.status_d_dim,
        col_start = minus_start,
        col_end = minus_start + #minus_str,
      })
    end
  end

  for _, entry in ipairs(sorted_file_entries(active_files)) do
    local file = entry.file
    local is_active = (entry.idx == s.current_file_idx)
    local tail = ""
    local basename_budget = math.max(row_budget - #tail - 4, 8)
    local basename = truncate_middle_text(entry.basename, basename_budget)
    local line = string.format("%s%s %s%s", file_indent, file.status, basename, tail)

    table.insert(lines, line)
    table.insert(explorer_line_map, { type = "file", idx = entry.idx, section = "files" })
    local li = #lines - 1
    if is_active then
      table.insert(highlights, {
        line = li,
        hl = HL.explorer_active_row,
        col_start = 0,
        col_end = -1,
      })
    end

    local status_hl = HL.status_m
    if file.status == "A" then
      status_hl = HL.status_a
    elseif file.status == "D" then
      status_hl = HL.status_d
    end
    table.insert(highlights, { line = li, hl = status_hl, col_start = 2, col_end = 3 })

    local basename_col = line:find(basename, 1, true)
    if basename_col then
      table.insert(highlights, {
        line = li,
        hl = is_active and HL.explorer_active or HL.explorer_file,
        col_start = basename_col - 1,
        col_end = basename_col - 1 + #basename,
      })
    end
  end

  local thread_sections = build_thread_sections(active_files)
  if #thread_sections > 0 then
    table.insert(lines, " " .. string.rep("─", math.max(8, explorer_width - 3)))
    table.insert(explorer_line_map, { type = "separator", section = "threads" })
    table.insert(highlights, { line = #lines - 1, hl = HL.note_separator, col_start = 1, col_end = -1 })
    table.insert(lines, header_indent .. "Threads")
    table.insert(explorer_line_map, { type = "header", section = "threads" })
    table.insert(highlights, { line = #lines - 1, hl = HL.threads_header, col_start = 1, col_end = -1 })

    for _, section in ipairs(thread_sections) do
      local max_badge_width = 0
      for _, row in ipairs(section.rows) do
        max_badge_width = math.max(max_badge_width, #string.format("[%d]", row.count))
      end

      table.insert(lines, thread_group_indent .. section.label)
      table.insert(explorer_line_map, { type = "header", section = "threads" })
      table.insert(highlights, {
        line = #lines - 1,
        hl = section.label == "local/" and HL.local_group or HL.vendor_group,
        col_start = 3,
        col_end = -1,
      })

      for _, row in ipairs(section.rows) do
        local fname = row.path:match("([^/]+)$") or row.path
        local badge = string.format("[%d]", row.count)
        local name_budget = math.max(row_budget - max_badge_width - #thread_row_indent - 1, 8)
        local short_name = truncate_middle_text(fname, name_budget)
        local gap = math.max(1, name_budget - vim.fn.strdisplaywidth(short_name) + 1)
        local thread_line = string.format("%s%s%s%s", thread_row_indent, short_name, string.rep(" ", gap), badge)
        table.insert(lines, thread_line)
        table.insert(explorer_line_map, {
          type = "thread",
          idx = row.idx,
          file_path = row.path,
          line = row.note and row.note.line or nil,
          side = row.note and row.note.side or "new",
          source = row.source,
          section = "threads",
        })
        local li = #lines - 1
        local source_hl = row.source == "vendor" and HL.note_remote or HL.note_sign
        local name_start = thread_line:find(short_name, 1, true)
        if name_start then
          table.insert(highlights, {
            line = li,
            hl = HL.explorer_file,
            col_start = name_start - 1,
            col_end = name_start - 1 + #short_name,
          })
        end
        local badge_start = thread_line:find("[", 1, true)
        if badge_start then
          table.insert(highlights, {
            line = li,
            hl = source_hl,
            col_start = badge_start - 1,
            col_end = -1,
          })
        end
      end
    end
  end

  if #active_files == 0 then
    table.insert(lines, "  (no files)")
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
---@param number_width number
---@return string display  The formatted line
---@return number gutter_len  Length of the gutter prefix (before the text content)
local function format_diff_line(dl, number_width)
  local prefix
  if dl.type == "add" then
    prefix = "+"
  elseif dl.type == "del" then
    prefix = "-"
  else
    prefix = " "
  end
  local old_num = format_line_number(dl.old_lnum, number_width)
  local new_num = format_line_number(dl.new_lnum, number_width)
  local gutter = string.format("%s %s│%s│", old_num, new_num, prefix)
  return gutter .. dl.text, #gutter
end

--- Build display lines and highlights for a file's diff.
---@param file ReviewFile
---@return string[] lines
---@return table[] highlights  Each: {line, hl, col_start, col_end}
local function build_diff_display(file)
  local cache = file_cache(file)
  if cache.unified_display then
    return cache.unified_display.lines, cache.unified_display.highlights
  end

  local lines = {}
  local highlights = {}
  local _, _, number_width = file_line_number_widths(file)

  for _, hunk in ipairs(file.hunks) do
    local pair_map, pair_diffs = hunk_word_diff_data(file, hunk)

    for line_idx, dl in ipairs(hunk.lines) do
      local display, gutter_len = format_diff_line(dl, number_width)
      table.insert(lines, display)
      local display_idx = #lines - 1
      add_diff_gutter_highlights(highlights, display_idx, gutter_len, dl)

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
          local ranges = pair_diffs[pair[1]]
          local old_ranges = ranges and ranges[1] or {}
          local new_ranges = ranges and ranges[2] or {}

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

  cache.unified_display = {
    lines = lines,
    highlights = highlights,
  }
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

  local _, _, new_to_display, old_to_display = file_line_maps(file)

  for _, note in ipairs(notes) do
    if not note.line then
      goto skip_sign
    end
    local display_line
    if note.side == "old" then
      display_line = old_to_display[note.line]
    else
      display_line = new_to_display[note.line]
    end

    if display_line then
      local sign, hl
      if note.status == "remote" and note.resolved then
        sign, hl = "○", HL.note_remote_resolved
      elseif note.status == "remote" then
        sign, hl = "●", HL.note_remote
      else
        sign, hl = "◆", HL.note_sign
      end
      vim.api.nvim_buf_set_extmark(buf, ns, display_line - 1, 0, {
        sign_text = sign,
        sign_hl_group = hl,
        priority = 100,
      })
    end
    ::skip_sign::
  end
end

--- Show/hide inline comment preview when cursor lands on a line with notes.
--- Uses virt_lines to render the conversation below the diff line.
local inline_ns = vim.api.nvim_create_namespace("review_inline")
local inline_last_buf = nil
local inline_last_note = nil

--- Clear any active inline preview.
local function clear_inline_preview()
  if inline_last_buf and vim.api.nvim_buf_is_valid(inline_last_buf) then
    vim.api.nvim_buf_clear_namespace(inline_last_buf, inline_ns, 0, -1)
  end
  inline_last_buf = nil
  inline_last_note = nil
end

--- Show inline comment preview for a note at the given display line.
---@param buf number
---@param display_line number  1-indexed
---@param note ReviewNote
local function show_inline_preview(buf, display_line, note)
  if not note.replies or #note.replies == 0 then
    -- For local notes just show the body
    local body = truncate_end_text((note.body or ""):match("^([^\n]*)") or "", 60)
    local prefix = note.author and ("@" .. note.author .. ": ") or ""
    vim.api.nvim_buf_set_extmark(buf, inline_ns, display_line - 1, 0, {
      virt_lines = {
        { { "  \u{2502} " .. prefix .. body, HL.note_author } },
      },
      virt_lines_above = false,
    })
    return
  end

  -- Build virt_lines for each reply (compact: one line per reply)
  local vlines = {}
  local max_replies = 5
  for i, reply in ipairs(note.replies) do
    if i > max_replies then
      table.insert(vlines, {
        { string.format("  \u{2502} ... and %d more", #note.replies - max_replies), HL.meta },
      })
      break
    end
    local body = truncate_end_text((reply.body or ""):match("^([^\n]*)") or "", 55)
    local line_hl = (i == 1) and HL.note_remote or HL.note_author
    table.insert(vlines, {
      { string.format("  \u{2502} @%s: %s", reply.author or "?", body), line_hl },
    })
  end

  -- Status line
  local status = note.resolved and "resolved" or "open"
  local reply_count = #note.replies
  local footer = string.format("  \u{2514} %s \u{00B7} %d replies \u{00B7} <CR> open thread", status, reply_count)
  table.insert(vlines, { { footer, HL.meta } })

  vim.api.nvim_buf_set_extmark(buf, inline_ns, display_line - 1, 0, {
    virt_lines = vlines,
    virt_lines_above = false,
  })
end

--- Update inline preview based on cursor position.
---@param buf number
function M.update_inline_preview(buf)
  local file = state.active_current_file()
  if not file then
    clear_inline_preview()
    return
  end

  local win = get_diff_win()
  if not win then
    clear_inline_preview()
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(win)
  local display_line = cursor[1]

  local dn, do_ = file_line_maps(file)
  local new_lnum = dn[display_line]
  local old_lnum = do_[display_line]

  local target_note = nil
  if new_lnum then
    target_note = state.find_note_at(file.path, new_lnum, "new")
  end
  if not target_note and old_lnum then
    target_note = state.find_note_at(file.path, old_lnum, "old")
  end

  if target_note and inline_last_note and target_note.id == inline_last_note.id then
    return
  end

  clear_inline_preview()

  if target_note then
    inline_last_buf = buf
    inline_last_note = target_note
    show_inline_preview(buf, display_line, target_note)
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
  local cache = file_cache(file)
  if cache.split_display then
    return cache.split_display.old_lines,
      cache.split_display.old_highlights,
      cache.split_display.new_lines,
      cache.split_display.new_highlights
  end

  local old_lines = {}
  local old_hl = {}
  local new_lines = {}
  local new_hl = {}
  local old_width, new_width = file_line_number_widths(file)

  for _, hunk in ipairs(file.hunks) do
    local _, pair_diffs = hunk_word_diff_data(file, hunk)

    -- Group lines into chunks: context lines go on both sides,
    -- del/add blocks need to be aligned side-by-side with padding.
    local i = 1
    while i <= #hunk.lines do
      local dl = hunk.lines[i]

      if dl.type == "ctx" then
        local old_num = format_line_number(dl.old_lnum, old_width)
        local new_num = format_line_number(dl.new_lnum, new_width)
        table.insert(old_lines, string.format("%s│ │%s", old_num, dl.text))
        table.insert(new_lines, string.format("%s│ │%s", new_num, dl.text))
        table.insert(old_hl, { line = #old_lines - 1, hl = HL.diff_gutter, col_start = 0, col_end = #old_num + 3 })
        table.insert(old_hl, { line = #old_lines - 1, hl = HL.diff_context, col_start = #old_num + 3, col_end = -1 })
        table.insert(new_hl, { line = #new_lines - 1, hl = HL.diff_gutter, col_start = 0, col_end = #new_num + 3 })
        table.insert(new_hl, { line = #new_lines - 1, hl = HL.diff_context, col_start = #new_num + 3, col_end = -1 })
        i = i + 1
      elseif dl.type == "del" then
        local dels = {}
        while i <= #hunk.lines and hunk.lines[i].type == "del" do
          table.insert(dels, { idx = i, line = hunk.lines[i] })
          i = i + 1
        end
        local adds = {}
        while i <= #hunk.lines and hunk.lines[i].type == "add" do
          table.insert(adds, { idx = i, line = hunk.lines[i] })
          i = i + 1
        end

        local num_pairs = math.min(#dels, #adds)
        local block_diffs = {}
        for j = 1, num_pairs do
          block_diffs[j] = pair_diffs[dels[j].idx]
        end

        local max_count = math.max(#dels, #adds)
        for j = 1, max_count do
          if j <= #dels then
            local d = dels[j]
            local num = format_line_number(d.line.old_lnum, old_width)
            local text = string.format("%s│-│%s", num, d.line.text)
            table.insert(old_lines, text)
            local line_idx = #old_lines - 1
            table.insert(old_hl, { line = line_idx, hl = HL.del, col_start = 0, col_end = -1 })
            table.insert(old_hl, { line = line_idx, hl = HL.diff_gutter, col_start = 0, col_end = #num + 3 })
            table.insert(old_hl, { line = line_idx, hl = HL.status_d, col_start = #num + 1, col_end = #num + 2 })

            if block_diffs[j] then
              local old_ranges = block_diffs[j][1]
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
            local num = format_line_number(a.line.new_lnum, new_width)
            local text = string.format("%s│+│%s", num, a.line.text)
            table.insert(new_lines, text)
            local line_idx = #new_lines - 1
            table.insert(new_hl, { line = line_idx, hl = HL.add, col_start = 0, col_end = -1 })
            table.insert(new_hl, { line = line_idx, hl = HL.diff_gutter, col_start = 0, col_end = #num + 3 })
            table.insert(new_hl, { line = line_idx, hl = HL.status_a, col_start = #num + 1, col_end = #num + 2 })

            if block_diffs[j] then
              local new_ranges = block_diffs[j][2]
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
        local num = format_line_number(dl.new_lnum, new_width)
        table.insert(old_lines, "")
        table.insert(new_lines, string.format("%s│+│%s", num, dl.text))
        table.insert(new_hl, { line = #new_lines - 1, hl = HL.add, col_start = 0, col_end = -1 })
        table.insert(new_hl, { line = #new_lines - 1, hl = HL.diff_gutter, col_start = 0, col_end = #num + 3 })
        table.insert(new_hl, { line = #new_lines - 1, hl = HL.status_a, col_start = #num + 1, col_end = #num + 2 })
        i = i + 1
      else
        i = i + 1
      end
    end
  end

  cache.split_display = {
    old_lines = old_lines,
    old_highlights = old_hl,
    new_lines = new_lines,
    new_highlights = new_hl,
  }
  return old_lines, old_hl, new_lines, new_hl
end

--- Render the split view (old left, new right) for the current file.
local function render_split(ui_state)
  local file = state.active_current_file()
  if not file then
    return
  end

  local old_lines, old_hl, new_lines, new_hl = build_split_display(file)

  vim.bo[ui_state.diff_buf].modifiable = true
  vim.api.nvim_buf_set_lines(ui_state.diff_buf, 0, -1, false, old_lines)
  vim.bo[ui_state.diff_buf].modifiable = false

  local ns_old = vim.api.nvim_create_namespace("review_diff")
  vim.api.nvim_buf_clear_namespace(ui_state.diff_buf, ns_old, 0, -1)
  for _, h in ipairs(old_hl) do
    vim.api.nvim_buf_add_highlight(ui_state.diff_buf, ns_old, h.hl, h.line, h.col_start, h.col_end)
  end

  vim.bo[ui_state.split_buf].modifiable = true
  vim.api.nvim_buf_set_lines(ui_state.split_buf, 0, -1, false, new_lines)
  vim.bo[ui_state.split_buf].modifiable = false

  local ns_new = vim.api.nvim_create_namespace("review_diff_new")
  vim.api.nvim_buf_clear_namespace(ui_state.split_buf, ns_new, 0, -1)
  for _, h in ipairs(new_hl) do
    vim.api.nvim_buf_add_highlight(ui_state.split_buf, ns_new, h.hl, h.line, h.col_start, h.col_end)
  end

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

    local split_buf = create_buf("review://diff-new", { filetype = "review-diff" })
    local left_width = ui_state.explorer_win
        and vim.api.nvim_win_is_valid(ui_state.explorer_win)
        and vim.api.nvim_win_get_width(ui_state.explorer_win)
      or ui_state.explorer_width
      or navigator_width()
    ui_state.explorer_width = left_width
    local diff_width = ui_state.diff_win
        and vim.api.nvim_win_is_valid(ui_state.diff_win)
        and vim.api.nvim_win_get_width(ui_state.diff_win)
      or nil
    local previous_equalalways = vim.o.equalalways

    -- Focus the diff window and split it
    if ui_state.explorer_win and vim.api.nvim_win_is_valid(ui_state.explorer_win) then
      vim.wo[ui_state.explorer_win].winfixwidth = true
      vim.api.nvim_win_set_width(ui_state.explorer_win, left_width)
    end
    vim.o.equalalways = false
    vim.api.nvim_set_current_win(ui_state.diff_win)
    vim.cmd("vsplit")
    vim.cmd("wincmd l")
    vim.api.nvim_set_current_buf(split_buf)
    vim.o.equalalways = previous_equalalways

    local split_win = vim.api.nvim_get_current_win()

    vim.wo[split_win].number = false
    vim.wo[split_win].relativenumber = false
    vim.wo[split_win].signcolumn = "yes"
    vim.wo[split_win].wrap = false
    vim.wo[split_win].cursorline = true
    vim.wo[split_win].cursorlineopt = "line"
    apply_review_window_style(split_win, "pane")

    if diff_width and vim.api.nvim_win_is_valid(ui_state.diff_win) and vim.api.nvim_win_is_valid(split_win) then
      local target = math.max(20, math.floor((diff_width - 1) / 2))
      vim.api.nvim_win_set_width(ui_state.diff_win, target)
    end

    ui_state.split_buf = split_buf
    ui_state.split_win = split_win

    setup_diff_keymaps(split_buf)
    attach_review_quit_guard(split_buf)

    render_split(ui_state)
    update_window_chrome()
    if ui_state.explorer_win and vim.api.nvim_win_is_valid(ui_state.explorer_win) then
      vim.wo[ui_state.explorer_win].winfixwidth = true
      vim.api.nvim_win_set_width(ui_state.explorer_win, left_width)
    end
  else
    ui_state.view_mode = "unified"

    vim.wo[ui_state.diff_win].scrollbind = false
    if ui_state.explorer_win and vim.api.nvim_win_is_valid(ui_state.explorer_win) then
      local left_width = vim.api.nvim_win_get_width(ui_state.explorer_win)
      ui_state.explorer_width = left_width
      vim.wo[ui_state.explorer_win].winfixwidth = true
      vim.api.nvim_win_set_width(ui_state.explorer_win, left_width)
    end

    if ui_state.split_win and vim.api.nvim_win_is_valid(ui_state.split_win) then
      vim.api.nvim_win_close(ui_state.split_win, true)
    end
    ui_state.split_buf = nil
    ui_state.split_win = nil

    render_diff(ui_state.diff_buf)
    update_window_chrome()
    if ui_state.explorer_win and vim.api.nvim_win_is_valid(ui_state.explorer_win) then
      local width = ui_state.explorer_width or navigator_width()
      vim.wo[ui_state.explorer_win].winfixwidth = true
      vim.api.nvim_win_set_width(ui_state.explorer_win, width)
    end
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

--- Toggle between the full stack/range view and a single selected commit.
function M.toggle_stack_view()
  local s = state.get()
  if not s or #s.commits == 0 then
    return
  end

  if s.current_commit_idx == nil then
    M.select_commit(1)
    return
  end

  if s.current_commit_idx >= #s.commits then
    M.select_commit(nil)
  else
    M.select_commit(s.current_commit_idx + 1)
  end
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
      local ui_state = state.get_ui()
      if ui_state and vim.api.nvim_win_is_valid(ui_state.diff_win) then
        vim.api.nvim_set_current_win(ui_state.diff_win)
      end
    elseif entry.type == "thread" then
      jump_to_file_location(entry.file_path, entry.line, entry.side)
    end
  end, opts)

  local km = require("review").config.keymaps

  vim.keymap.set("n", km.close, function()
    M.close()
  end, opts)

  vim.keymap.set("n", km.help, function()
    M.open_help()
  end, opts)

  vim.keymap.set("n", km.notes_list, function()
    M.open_notes_list()
  end, opts)

  vim.keymap.set("n", km.toggle_stack, function()
    M.toggle_stack_view()
  end, opts)

  vim.keymap.set("n", km.focus_files, function()
    M.focus_section("files")
  end, opts)

  vim.keymap.set("n", km.focus_threads, function()
    M.focus_section("threads")
  end, opts)
end

--- Get the diff window, preferring the current window if it's a diff window.
---@return number|nil win
get_diff_win = function()
  local ui_state = state.get_ui()
  if not ui_state then
    return nil
  end
  local cur_win = vim.api.nvim_get_current_win()
  if cur_win == ui_state.diff_win or cur_win == ui_state.split_win then
    return cur_win
  end
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

  local dn, do_ = file_line_maps(file)
  return {
    new_lnum = dn[display_line],
    old_lnum = do_[display_line],
  }
end

--- Set up keymaps for the diff buffer.
---@param buf number
setup_diff_keymaps = function(buf)
  local opts = { buffer = buf, noremap = true, silent = true }

  local km = require("review").config.keymaps

  vim.keymap.set("n", km.close, function()
    M.close()
  end, opts)

  vim.keymap.set("n", km.help, function()
    M.open_help()
  end, opts)

  vim.keymap.set("n", km.next_hunk, function()
    local file = state.active_current_file()
    if not file then
      return
    end
    local cursor = vim.api.nvim_win_get_cursor(0)
    local current_line = cursor[1]

    local display_line = 0
    for _, hunk in ipairs(file.hunks) do
      local hunk_start = display_line + 1
      if hunk_start > current_line then
        vim.api.nvim_win_set_cursor(0, { hunk_start, 0 })
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

    local hunk_positions = {}
    local display_line = 0
    for _, hunk in ipairs(file.hunks) do
      local hunk_start = display_line + 1
      table.insert(hunk_positions, hunk_start)
      display_line = display_line + #hunk.lines
    end

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

  vim.keymap.set("n", km.toggle_stack, function()
    M.toggle_stack_view()
  end, opts)

  vim.keymap.set("n", km.focus_files, function()
    M.focus_section("files")
  end, opts)

  vim.keymap.set("n", km.focus_threads, function()
    M.focus_section("threads")
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

  -- <CR>: open thread view for the note under cursor
  vim.keymap.set("n", "<CR>", function()
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
    local note = state.find_note_at(file.path, target_line, side)
    if not note then
      return
    end
    if note.status == "remote" and note.replies and #note.replies > 0 then
      clear_inline_preview()
      M.open_thread_view(note)
    elseif note.status ~= "remote" then
      M.edit_note_at_cursor()
    end
  end, opts)

  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = buf,
    callback = function()
      M.update_inline_preview(buf)
    end,
  })
end

--- Open the two-panel review layout.
function M.open()
  local s = state.get()
  if not s then
    vim.notify("No review session active", vim.log.levels.ERROR)
    return
  end

  review_closing = false

  local config = require("review").config
  M.setup_highlights(config.colorblind)
  local tab_name = "review"
  local info = state.get_forge_info()
  if info and info.pr_number then
    tab_name = string.format("review:%s#%d", info.forge, info.pr_number)
  end

  vim.cmd("tabnew")
  pcall(vim.cmd, "file " .. tab_name)
  local tab = vim.api.nvim_get_current_tabpage()

  local explorer_buf = create_buf("review://explorer", { filetype = "review-explorer" })
  local diff_buf = create_buf("review://diff", { filetype = "review-diff" })

  vim.api.nvim_set_current_buf(explorer_buf)
  vim.cmd("vsplit")
  local wins = vim.api.nvim_tabpage_list_wins(tab)
  table.sort(wins, function(a, b)
    local apos = vim.api.nvim_win_get_position(a)
    local bpos = vim.api.nvim_win_get_position(b)
    return apos[2] < bpos[2]
  end)

  local explorer_win = wins[1]
  local diff_win = wins[2]

  vim.api.nvim_win_set_buf(explorer_win, explorer_buf)
  vim.api.nvim_win_set_buf(diff_win, diff_buf)
  vim.api.nvim_set_current_win(explorer_win)
  vim.cmd("vertical resize " .. tostring(navigator_width()))

  for _, win in ipairs({ explorer_win, diff_win }) do
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].wrap = false
    apply_review_window_style(win, "pane")
  end
  vim.wo[explorer_win].signcolumn = "no"
  vim.wo[diff_win].signcolumn = "yes"
  vim.wo[explorer_win].winfixwidth = true
  vim.wo[diff_win].cursorline = true
  vim.wo[diff_win].cursorlineopt = "line"
  vim.wo[explorer_win].cursorline = true
  vim.wo[explorer_win].cursorlineopt = "line"

  state.set_ui({
    explorer_buf = explorer_buf,
    explorer_win = explorer_win,
    diff_buf = diff_buf,
    diff_win = diff_win,
    tab = tab,
    explorer_width = vim.api.nvim_win_get_width(explorer_win),
    view_mode = config.view or "unified",
  })

  setup_explorer_keymaps(explorer_buf)
  setup_diff_keymaps(diff_buf)
  attach_review_quit_guard(explorer_buf)
  attach_review_quit_guard(diff_buf)

  render_explorer(explorer_buf)
  render_diff(diff_buf)
  update_window_chrome()

  local selection_line = navigator_selection_line()
  if selection_line and vim.api.nvim_win_is_valid(explorer_win) then
    vim.api.nvim_win_set_cursor(explorer_win, { selection_line, 0 })
  end
  vim.api.nvim_set_current_win(diff_win)

  vim.api.nvim_create_autocmd("TabClosed", {
    callback = function(ev)
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
  review_closing = false
  clear_inline_preview()

  local ui = state.get_ui()
  if ui and ui.tab then
    local tabs = vim.api.nvim_list_tabpages()
    if #tabs <= 1 then
      for _, buf in ipairs({ ui.explorer_buf, ui.diff_buf, ui.split_buf }) do
        if buf and vim.api.nvim_buf_is_valid(buf) then
          vim.api.nvim_buf_delete(buf, { force = true })
        end
      end
    else
      for _, t in ipairs(tabs) do
        if t == ui.tab then
          if vim.api.nvim_get_current_tabpage() == ui.tab then
            vim.cmd("tabprevious")
          end
          vim.cmd("tabclose " .. vim.api.nvim_tabpage_get_number(ui.tab))
          break
        end
      end
    end
  end
  state.destroy()
end

---@param target table
---@param opts table|nil
function M.open_note_float_for_target(target, opts)
  opts = opts or {}
  if not target or not target.file_path or not target.line then
    vim.notify("Cannot add note without a file and line", vim.log.levels.WARN)
    return
  end

  local file_path = target.file_path
  local target_line = target.line
  local end_line = target.end_line
  local side = target.side or "new"
  local width, col = float_dimensions(0.5, 80)
  local height = math.min(10, vim.o.lines - 4)
  local row = math.floor((vim.o.lines - height) / 2)

  local is_suggestion = opts.suggestion or false
  local note_type = is_suggestion and "suggestion" or "comment"

  local note_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(note_buf, "review://note-" .. note_buf)

  local title = is_suggestion and " Add Suggestion " or " Add Note "

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
  apply_review_window_style(note_win, "float")

  vim.bo[note_buf].bufhidden = "wipe"

  if is_suggestion then
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
        state.add_draft(file_path, target_line, body, end_line, side == "old" and "LEFT" or "RIGHT")
      else
        state.add_note(file_path, target_line, body, end_line, side, note_type)
      end
    end
    M.refresh()
  end, function()
    vim.api.nvim_win_close(note_win, true)
  end)
end

--- Open a floating window to add a note on the current diff line.
---@param opts table|nil  {range: boolean}
function M.open_note_float(opts)
  opts = opts or {}
  local file = state.active_current_file()
  if not file then
    return
  end

  local dn, do_ = file_line_maps(file)
  local target_line, end_line, side

  if opts.range then
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

  M.open_note_float_for_target({
    file_path = file.path,
    line = target_line,
    end_line = end_line,
    side = side,
  }, opts)
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

  if note.status == "remote" then
    M.open_thread_view(note)
    return
  end

  local width, col = float_dimensions(0.5, 80)
  local height = math.min(10, vim.o.lines - 4)
  local row = math.floor((vim.o.lines - height) / 2)

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
    title = " Edit Note ",
    title_pos = "center",
  })
  apply_review_window_style(note_win, "float")

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

  local note, note_idx = state.find_note_at(file.path, target_line, side)
  if not note then
    vim.notify("No note on this line", vim.log.levels.INFO)
    return
  end
  if note.status == "remote" then
    vim.notify("Cannot delete remote comments", vim.log.levels.WARN)
    return
  end

  state.remove_note(note_idx)
  vim.notify("Note deleted", vim.log.levels.INFO)
  M.refresh()
end

--- Resolve a note to a display line in a file's diff.
---@param note ReviewNote
---@param file ReviewFile
---@return number|nil display_line
local function note_to_display_line(note, file)
  local _, _, new_to_display, old_to_display = file_line_maps(file)
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

  local entries = {}
  for fi, file in ipairs(files) do
    local file_notes = state.get_notes(file.path)
    if #file_notes > 0 then
      local _, _, ntd, otd = file_line_maps(file)
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

  local on_entry_idx = nil
  for i, e in ipairs(entries) do
    if e.fi == cur_fi and cur_line >= e.dl and cur_line <= e.dl_end then
      on_entry_idx = i
      break
    end
  end

  local target
  if on_entry_idx then
    if direction > 0 then
      target = entries[on_entry_idx < #entries and on_entry_idx + 1 or 1]
    else
      target = entries[on_entry_idx > 1 and on_entry_idx - 1 or #entries]
    end
  else
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

  if target.fi ~= cur_fi then
    state.set_file(target.fi)
    M.refresh()
  end

  local target_file = files[target.fi]
  local dl = note_to_display_line(target.note, target_file)
  if dl then
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_cursor(win, { dl, 0 })
  end
end

--- Open a thread view for a remote note, showing the full conversation.
---@param note ReviewNote
function M.open_thread_view(note)
  if not note.replies or #note.replies == 0 then
    vim.notify("No conversation on this comment", vim.log.levels.INFO)
    return
  end

  local width, col_offset = float_dimensions()

  local lines = {}
  local highlight_rows = {}
  local line_to_reply = {} -- maps display line -> reply index

  local location = string.format("%s:%s", note.file_path, tostring(note.line or "?"))
  local status_tag = note.resolved and "resolved" or "open"
  local reply_count = #note.replies
  local reply_label = reply_count == 1 and "reply" or "replies"
  table.insert(lines, " " .. truncate_middle_text(location, math.max(width - 2, 12)))
  highlight_rows[#lines] = { hl = HL.panel_title }
  table.insert(lines, string.format(" %s  \u{00B7}  %d %s", status_tag, reply_count, reply_label))
  highlight_rows[#lines] = { hl = note.resolved and HL.note_remote_resolved or HL.panel_meta }

  table.insert(lines, string.rep("\u{2500}", width - 2))
  highlight_rows[#lines] = { hl = HL.note_separator }

  for idx, reply in ipairs(note.replies) do
    local author_str = " @" .. reply.author
    if reply.created_at then
      local date = reply.created_at:match("^(%d%d%d%d%-%d%d%-%d%d)")
      if date then
        author_str = author_str .. " \u{00B7} " .. date
      end
    end
    table.insert(lines, author_str)
    highlight_rows[#lines] = { hl = HL.note_author }
    line_to_reply[#lines] = idx

    local body_lines = vim.split(reply.body or "", "\n")
    for _, body_line in ipairs(body_lines) do
      local indent = "   "
      local wrap_at = math.max(width - #indent - 2, 10)
      for _, wrapped in ipairs(wrap_display_text(body_line, wrap_at)) do
        table.insert(lines, indent .. wrapped)
      end
      line_to_reply[#lines] = idx
    end

    if idx < #note.replies then
      table.insert(lines, "")
    end
  end

  table.insert(lines, "")
  table.insert(lines, string.rep("\u{2500}", width - 2))
  highlight_rows[#lines] = { hl = HL.note_separator }
  local resolve_label = note.resolved and "x reopen" or "x resolve"
  for _, legend_line in
    ipairs(build_footer_legend({
      "e edit",
      "d delete",
      "r reply",
      resolve_label,
      "b browse",
      "q close",
      "? help",
    }, width))
  do
    table.insert(lines, legend_line)
    highlight_rows[#lines] = { hl = HL.meta }
  end

  local height = math.min(#lines, math.floor(vim.o.lines * 0.75))
  local row = math.floor((vim.o.lines - height) / 2)
  local col = col_offset

  local thread_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[thread_buf].buftype = "nofile"
  vim.bo[thread_buf].bufhidden = "wipe"
  vim.bo[thread_buf].filetype = "markdown"
  vim.api.nvim_buf_set_lines(thread_buf, 0, -1, false, lines)
  vim.bo[thread_buf].modifiable = false

  local thread_win = vim.api.nvim_open_win(thread_buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " Thread  ",
    title_pos = "center",
  })
  apply_review_window_style(thread_win, "float")

  vim.wo[thread_win].wrap = true
  vim.wo[thread_win].conceallevel = 2
  vim.wo[thread_win].concealcursor = "n"

  pcall(vim.treesitter.start, thread_buf, "markdown")

  local ns = vim.api.nvim_create_namespace("review_thread")
  for i, hr in pairs(highlight_rows) do
    vim.api.nvim_buf_add_highlight(thread_buf, ns, hr.hl, i - 1, 0, -1)
  end

  local buf_opts = { buffer = thread_buf, noremap = true, silent = true }

  vim.keymap.set("n", "b", function()
    if note.url then
      vim.ui.open(note.url)
    else
      vim.notify("No URL for this thread", vim.log.levels.INFO)
    end
  end, buf_opts)

  vim.keymap.set("n", "q", function()
    vim.api.nvim_win_close(thread_win, true)
    M.open_notes_list()
  end, buf_opts)
  vim.keymap.set("n", "<Esc>", function()
    vim.api.nvim_win_close(thread_win, true)
    M.open_notes_list()
  end, buf_opts)
  vim.keymap.set("n", "?", function()
    M.open_help()
  end, buf_opts)

  vim.keymap.set("n", "e", function()
    local cursor = vim.api.nvim_win_get_cursor(thread_win)
    local reply_idx = line_to_reply[cursor[1]]
    if not reply_idx then
      vim.notify("No comment under cursor", vim.log.levels.INFO)
      return
    end

    local reply = note.replies[reply_idx]
    if not reply or not reply.remote_id then
      vim.notify("Cannot edit this comment", vim.log.levels.WARN)
      return
    end

    local me = forge.current_user()
    if me and reply.author ~= me and reply.author ~= "you" then
      vim.notify("Can only edit your own comments (@" .. reply.author .. " is not you)", vim.log.levels.WARN)
      return
    end

    vim.api.nvim_win_close(thread_win, true)

    local edit_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[edit_buf].filetype = "markdown"
    vim.api.nvim_buf_set_name(edit_buf, "review://edit-comment-" .. edit_buf)
    vim.bo[edit_buf].bufhidden = "wipe"

    local edit_lines = vim.split(reply.body or "", "\n")
    vim.api.nvim_buf_set_lines(edit_buf, 0, -1, false, edit_lines)

    local ew, ec = float_dimensions(0.6, 70)
    local eh = math.min(12, vim.o.lines - 4)
    local er = math.floor((vim.o.lines - eh) / 2)

    local edit_win = vim.api.nvim_open_win(edit_buf, true, {
      relative = "editor",
      width = ew,
      height = eh,
      row = er,
      col = ec,
      style = "minimal",
      border = "rounded",
      title = " Edit Comment ",
      title_pos = "center",
    })
    apply_review_window_style(edit_win, "float")

    vim.cmd("startinsert!")

    setup_note_float_keymaps(edit_buf, edit_win, function()
      local new_lines = vim.api.nvim_buf_get_lines(edit_buf, 0, -1, false)
      local new_body = table.concat(new_lines, "\n")
      if not new_body:match("%S") then
        return
      end

      local info = state.get_forge_info()
      if not info then
        vim.notify("No PR/MR detected — cannot edit", vim.log.levels.ERROR)
        return
      end

      vim.notify("Updating comment...", vim.log.levels.INFO)
      local url, err = forge.edit_comment(info, reply.remote_id, new_body)
      if err then
        vim.notify("Edit failed: " .. err, vim.log.levels.ERROR)
      else
        vim.notify("Comment updated" .. (url and (": " .. url) or ""), vim.log.levels.INFO)
        reply.body = new_body
      end
    end, function()
      vim.api.nvim_win_close(edit_win, true)
      M.open_thread_view(note)
    end)
  end, buf_opts)

  vim.keymap.set("n", "d", function()
    local cursor = vim.api.nvim_win_get_cursor(thread_win)
    local reply_idx = line_to_reply[cursor[1]]
    if not reply_idx then
      vim.notify("No comment under cursor", vim.log.levels.INFO)
      return
    end

    local reply = note.replies[reply_idx]
    if not reply or not reply.remote_id then
      vim.notify("Cannot delete this comment", vim.log.levels.WARN)
      return
    end

    local me = forge.current_user()
    if me and reply.author ~= me and reply.author ~= "you" then
      vim.notify("Can only delete your own comments", vim.log.levels.WARN)
      return
    end

    vim.ui.select({ "Yes", "No" }, { prompt = "Delete this comment?" }, function(choice)
      if choice ~= "Yes" then
        return
      end

      local info = state.get_forge_info()
      if not info then
        vim.notify("No PR/MR detected", vim.log.levels.ERROR)
        return
      end

      vim.notify("Deleting comment...", vim.log.levels.INFO)
      local ok, err = forge.delete_comment(info, reply.remote_id)
      if not ok then
        vim.notify("Delete failed: " .. (err or "unknown"), vim.log.levels.ERROR)
        return
      end

      vim.notify("Comment deleted", vim.log.levels.INFO)
      table.remove(note.replies, reply_idx)

      if vim.api.nvim_win_is_valid(thread_win) then
        vim.api.nvim_win_close(thread_win, true)
      end
      if #note.replies > 0 then
        M.open_thread_view(note)
      else
        M.open_notes_list()
      end
    end)
  end, buf_opts)

  vim.keymap.set("n", "x", function()
    local info = state.get_forge_info()
    if not info then
      vim.notify("No PR/MR detected", vim.log.levels.ERROR)
      return
    end

    local new_resolved = not note.resolved
    local action = new_resolved and "Resolve" or "Unresolve"

    vim.ui.select({ "Yes", "No" }, { prompt = action .. " this thread?" }, function(choice)
      if choice ~= "Yes" then
        return
      end

      vim.notify(action .. " thread...", vim.log.levels.INFO)
      local ok, err = forge.resolve_thread(info, note, new_resolved)
      if not ok then
        vim.notify(action .. " failed: " .. (err or "unknown"), vim.log.levels.ERROR)
        return
      end

      vim.notify("Thread " .. (new_resolved and "resolved" or "reopened"), vim.log.levels.INFO)
      note.resolved = new_resolved

      if vim.api.nvim_win_is_valid(thread_win) then
        vim.api.nvim_win_close(thread_win, true)
      end
      M.open_thread_view(note)
    end)
  end, buf_opts)

  vim.keymap.set("n", "r", function()
    vim.api.nvim_win_close(thread_win, true)

    local reply_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[reply_buf].filetype = "markdown"
    vim.api.nvim_buf_set_name(reply_buf, "review://reply-" .. reply_buf)
    vim.bo[reply_buf].bufhidden = "wipe"

    local rw, rc = float_dimensions(0.6, 70)
    local rh = math.min(8, vim.o.lines - 4)
    local rr = math.floor((vim.o.lines - rh) / 2)

    local reply_win = vim.api.nvim_open_win(reply_buf, true, {
      relative = "editor",
      width = rw,
      height = rh,
      row = rr,
      col = rc,
      style = "minimal",
      border = "rounded",
      title = " Reply ",
      title_pos = "center",
    })
    apply_review_window_style(reply_win, "float")

    vim.cmd("startinsert")

    setup_note_float_keymaps(reply_buf, reply_win, function()
      local reply_lines = vim.api.nvim_buf_get_lines(reply_buf, 0, -1, false)
      local body = table.concat(reply_lines, "\n")
      if not body:match("%S") then
        return
      end

      local info = state.get_forge_info()
      if not info then
        vim.notify("No PR/MR detected — cannot reply", vim.log.levels.ERROR)
        return
      end

      vim.notify("Posting reply...", vim.log.levels.INFO)
      local url, err
      if note.is_general then
        url, err = forge.reply_to_pr(info, body)
      else
        url, err = forge.reply_to_thread(info, note.thread_id, body)
      end
      if err then
        vim.notify("Reply failed: " .. err, vim.log.levels.ERROR)
      else
        vim.notify("Reply posted" .. (url and (": " .. url) or ""), vim.log.levels.INFO)
        if note.replies then
          table.insert(note.replies, {
            author = "you",
            body = body,
            url = url,
            is_top = false,
          })
        end
      end
    end, function()
      vim.api.nvim_win_close(reply_win, true)
    end)
  end, buf_opts)
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

  local width, col_offset = float_dimensions()

  local function relative_time(iso_str)
    if not iso_str or type(iso_str) ~= "string" then
      return ""
    end
    local y, mo, d, h, mi = iso_str:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+)")
    if not y then
      return ""
    end
    local then_ts =
      os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = tonumber(h), min = tonumber(mi) })
    local diff = os.difftime(os.time(), then_ts)
    if diff < 0 then
      return ""
    end
    if diff < 3600 then
      return math.floor(diff / 60) .. "m"
    elseif diff < 86400 then
      return math.floor(diff / 3600) .. "h"
    elseif diff < 604800 then
      return math.floor(diff / 86400) .. "d"
    else
      return math.floor(diff / 604800) .. "w"
    end
  end

  local function last_activity(note)
    if not note.replies or #note.replies == 0 then
      return ""
    end
    local last = note.replies[#note.replies]
    return relative_time(last.created_at)
  end

  local active_files = state.active_files()
  local file_order = {}
  local files_by_path = {}
  for idx, f in ipairs(active_files) do
    file_order[f.path] = idx
    files_by_path[f.path] = f
  end

  local local_notes = {}
  local open_notes = {}
  local resolved_notes = {}
  local discussion_notes = {}
  for i, note in ipairs(all_notes) do
    local entry = { idx = i, note = note }
    if note.is_general then
      table.insert(discussion_notes, entry)
    elseif note.status == "draft" or note.status == "staged" then
      table.insert(local_notes, entry)
    elseif note.status == "remote" and note.resolved then
      table.insert(resolved_notes, entry)
    elseif note.status == "remote" then
      table.insert(open_notes, entry)
    end
  end

  local function sort_by_file_order(list)
    table.sort(list, function(a, b)
      local af = a.note.file_path and files_by_path[a.note.file_path] or nil
      local bf = b.note.file_path and files_by_path[b.note.file_path] or nil
      local ascore = af and file_focus_score(af) or 0
      local bscore = bf and file_focus_score(bf) or 0
      if ascore ~= bscore then
        return ascore > bscore
      end
      local oa = file_order[a.note.file_path] or 9999
      local ob = file_order[b.note.file_path] or 9999
      if oa ~= ob then
        return oa < ob
      end
      local al = type(a.note.line) == "number" and a.note.line or 0
      local bl = type(b.note.line) == "number" and b.note.line or 0
      return al < bl
    end)
  end

  local function sort_by_recent(list)
    table.sort(list, function(a, b)
      local a_last = a.note.replies and #a.note.replies > 0 and a.note.replies[#a.note.replies].created_at or ""
      local b_last = b.note.replies and #b.note.replies > 0 and b.note.replies[#b.note.replies].created_at or ""
      return a_last > b_last -- reverse chronological
    end)
  end

  sort_by_file_order(local_notes)
  sort_by_recent(discussion_notes)
  sort_by_recent(open_notes)
  sort_by_recent(resolved_notes)

  local extra_hls = {}
  local dw = vim.fn.strdisplaywidth

  local function render_note(entry)
    local note = entry.note

    local icon, hl
    if note.status == "staged" then
      icon, hl = "\u{25B2}", HL.note_published
    elseif note.status == "draft" then
      icon, hl = "\u{25CB}", HL.note_draft
    elseif note.resolved then
      icon, hl = "\u{2713}", HL.note_remote_resolved
    else
      icon, hl = "\u{25CF}", HL.note_remote
    end

    local lref
    if note.file_path then
      local fname = note.file_path:match("([^/]+)$") or note.file_path
      lref = fname .. ":" .. tostring(note.line or "?")
    else
      lref = "PR"
    end

    local meta_parts = {}
    if note.author then
      table.insert(meta_parts, "@" .. note.author)
    end
    local reply_count = note.replies and #note.replies or 0
    if reply_count > 1 then
      table.insert(meta_parts, tostring(reply_count) .. " replies")
    end
    local ago = last_activity(note)
    if ago ~= "" then
      table.insert(meta_parts, ago .. " ago")
    end
    if note.status == "staged" then
      table.insert(meta_parts, "staged")
    end
    local meta = table.concat(meta_parts, "  ")
    local meta_dw = #meta > 0 and (dw(meta) + 2) or 0

    local body = (note.body or ""):match("^([^\n]*)") or ""
    local min_body_width = body ~= "" and 12 or 0
    local max_lref_width = math.max(math.min(math.floor(width * 0.42), width - meta_dw - min_body_width - 6), 8)
    lref = truncate_middle_text(lref, max_lref_width)

    local left = "  " .. icon .. " " .. lref
    local left_dw = dw(left)
    local avail = math.max(width - left_dw - meta_dw - 1, 8)
    body = truncate_end_text(body, avail)

    local content = left .. "  " .. body
    local display
    if #meta > 0 then
      local pad = math.max(width - dw(content) - dw(meta), 2)
      display = content .. string.rep(" ", pad) .. meta
    else
      display = content
    end

    table.insert(lines, display)
    highlight_rows[#lines] = { hl = hl, col_start = 2, col_end = 2 + #icon }
    note_refs[#lines] = {
      idx = entry.idx,
      file_path = note.file_path,
      line = note.line,
      side = note.side,
      note_id = note.id,
      status = note.status,
    }

    if #meta > 0 then
      local meta_byte_start = #display - #meta
      table.insert(extra_hls, { #lines, HL.meta, meta_byte_start, #display })
    end
  end

  local function render_section(section, label, label_hl, separator)
    if #section == 0 then
      return
    end
    if separator and #lines > 0 then
      table.insert(lines, "")
      note_refs[#lines] = false
    end

    table.insert(lines, string.format(" %s (%d)", label, #section))
    highlight_rows[#lines] = { hl = label_hl }
    note_refs[#lines] = false

    for _, entry in ipairs(section) do
      render_note(entry)
    end
  end

  render_section(local_notes, "Your Notes", HL.note_draft, false)
  render_section(open_notes, "Open Threads", HL.note_remote, true)
  render_section(discussion_notes, "Discussion", HL.note_author, true)
  render_section(resolved_notes, "Resolved", HL.note_remote_resolved, true)

  table.insert(lines, "")
  note_refs[#lines] = false
  local sep = string.rep("\u{2500}", width - 2)
  table.insert(lines, sep)
  highlight_rows[#lines] = { hl = HL.note_separator }
  note_refs[#lines] = false
  for _, legend_line in
    ipairs(build_footer_legend({
      "<CR> open",
      "s stage",
      "P publish",
      "y clipboard",
      "Y local",
      "R refresh",
      "C clear local",
      "b url",
      "q close",
      "? help",
    }, width))
  do
    table.insert(lines, legend_line)
    highlight_rows[#lines] = { hl = HL.meta }
    note_refs[#lines] = false
  end

  local height = math.min(#lines, math.floor(vim.o.lines * 0.75))
  local row = math.floor((vim.o.lines - height) / 2)
  local col = col_offset

  local list_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[list_buf].buftype = "nofile"
  vim.bo[list_buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(list_buf, 0, -1, false, lines)
  vim.bo[list_buf].modifiable = false

  local title_parts = {}
  local compact_title_parts = {}
  if #local_notes > 0 then
    table.insert(title_parts, #local_notes .. " yours")
    table.insert(compact_title_parts, #local_notes .. "y")
  end
  if #open_notes > 0 then
    table.insert(title_parts, #open_notes .. " open")
    table.insert(compact_title_parts, #open_notes .. "o")
  end
  if #discussion_notes > 0 then
    table.insert(title_parts, #discussion_notes .. " discussion")
    table.insert(compact_title_parts, #discussion_notes .. "d")
  end
  if #resolved_notes > 0 then
    table.insert(title_parts, #resolved_notes .. " resolved")
    table.insert(compact_title_parts, #resolved_notes .. "r")
  end
  local title_variants = { title_parts, compact_title_parts, {} }
  if state.comments_loading() then
    local with_sync_full = vim.deepcopy(title_parts)
    local with_sync_compact = vim.deepcopy(compact_title_parts)
    table.insert(with_sync_full, "syncing")
    table.insert(with_sync_compact, "sync")
    title_variants = { with_sync_full, with_sync_compact, title_parts, compact_title_parts, {} }
  end
  local title = fit_float_title(" Notes", title_variants, width)

  local list_win = vim.api.nvim_open_win(list_buf, true, {
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
  apply_review_window_style(list_win, "float")

  vim.wo[list_win].cursorline = true

  local ns = vim.api.nvim_create_namespace("review_notes_list")
  for i, _ in ipairs(lines) do
    local hr = highlight_rows[i]
    if hr then
      vim.api.nvim_buf_add_highlight(list_buf, ns, hr.hl, i - 1, hr.col_start or 0, hr.col_end or -1)
    end
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

  for _, ehl in ipairs(extra_hls) do
    vim.api.nvim_buf_add_highlight(list_buf, ns, ehl[2], ehl[1] - 1, ehl[3], ehl[4])
  end

  local buf_opts = { buffer = list_buf, noremap = true, silent = true }

  vim.keymap.set("n", "q", function()
    vim.api.nvim_win_close(list_win, true)
  end, buf_opts)
  vim.keymap.set("n", "<Esc>", function()
    vim.api.nvim_win_close(list_win, true)
  end, buf_opts)
  vim.keymap.set("n", "?", function()
    M.open_help()
  end, buf_opts)

  vim.keymap.set("n", "s", function()
    local cursor = vim.api.nvim_win_get_cursor(list_win)
    local ref = note_refs[cursor[1]]
    if not ref or ref == false or not ref.note_id then
      return
    end
    if ref.status == "remote" then
      vim.notify("Cannot stage remote comments", vim.log.levels.WARN)
      return
    end
    state.toggle_staged(ref.note_id)
    vim.api.nvim_win_close(list_win, true)
    M.open_notes_list()
    M.refresh()
  end, buf_opts)

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

    local info = state.get_forge_info()

    if not info then
      -- No PR/MR detected, publish locally only
      local url_map = {}
      for _, note in ipairs(staged_notes) do
        url_map[note.id] = "local"
      end
      local count = state.publish_staged(url_map)
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
    require("review").refresh_comments()
  end, buf_opts)

  vim.keymap.set("n", "y", function()
    copy_review_export({ clipboard = true }, "Notes copied to clipboard register(s): ")
  end, buf_opts)

  vim.keymap.set("n", "Y", function()
    copy_review_export({ local_only = true }, "Local notes copied to clipboard register(s): ")
  end, buf_opts)

  vim.keymap.set("n", "C", function()
    local count = state.local_note_count()
    if count == 0 then
      vim.notify("No local notes to clear", vim.log.levels.INFO)
      return
    end

    local choice = vim.fn.confirm(
      string.format("Clear %d local note(s)?\nRemote GitHub/GitLab threads will be kept.", count),
      "&Clear\n&Cancel",
      2
    )
    if choice ~= 1 then
      return
    end

    local cleared = state.clear_local_notes()
    if cleared > 0 then
      vim.notify(cleared .. " local note(s) cleared", vim.log.levels.INFO)
      vim.api.nvim_win_close(list_win, true)
      M.refresh()
      if #state.get_notes() > 0 then
        M.open_notes_list()
      end
    end
  end, buf_opts)

  vim.keymap.set("n", "R", function()
    vim.api.nvim_win_close(list_win, true)
    vim.notify("Refreshing PR comments...", vim.log.levels.INFO)
    require("review").refresh_comments()
  end, buf_opts)

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

  vim.keymap.set("n", "<CR>", function()
    local cursor = vim.api.nvim_win_get_cursor(list_win)
    local line_nr = cursor[1]
    local ref = note_refs[line_nr]
    if not ref or ref == false then
      return
    end

    -- Remote discussion comments (no code position) — just open thread view
    if ref.status == "remote" and not ref.file_path then
      local note_obj = state.get_note_by_id(ref.note_id)
      if note_obj then
        vim.api.nvim_win_close(list_win, true)
        M.open_thread_view(note_obj)
      end
      return
    end

    local target_path = ref.file_path
    local target_line = ref.line
    local target_side = ref.side
    local is_remote = ref.status == "remote"
    local remote_note_id = is_remote and ref.note_id or nil

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

      local dl = note_to_display_line({ line = target_line, side = target_side }, file)
      if not dl then
        local other = target_side == "old" and "new" or "old"
        dl = note_to_display_line({ line = target_line, side = other }, file)
      end
      if dl then
        vim.api.nvim_win_set_cursor(ui_state.diff_win, { dl, 0 })
      end

      -- Open thread view for remote code comments after navigating
      if is_remote and remote_note_id then
        local note_obj = state.get_note_by_id(remote_note_id)
        if note_obj then
          M.open_thread_view(note_obj)
        end
      end
    end)
  end, buf_opts)

  vim.keymap.set("n", "dd", function()
    local cursor = vim.api.nvim_win_get_cursor(list_win)
    local ref = note_refs[cursor[1]]
    if not ref or ref == false then
      return
    end
    if ref.status == "remote" then
      vim.notify("Cannot delete remote comments", vim.log.levels.WARN)
      return
    end
    state.remove_note(ref.idx)
    vim.api.nvim_win_close(list_win, true)
    M.open_notes_list()
    M.refresh()
  end, buf_opts)

  vim.keymap.set("n", "b", function()
    local cursor = vim.api.nvim_win_get_cursor(list_win)
    local ref = note_refs[cursor[1]]
    if not ref or ref == false or not ref.note_id then
      return
    end
    local note_obj = state.get_note_by_id(ref.note_id)
    if not note_obj or not note_obj.url then
      vim.notify("No URL for this note", vim.log.levels.INFO)
      return
    end
    vim.ui.open(note_obj.url)
  end, buf_opts)

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

function M.open_help()
  local km = require("review").config.keymaps
  local width = math.min(92, vim.o.columns - 6)
  local lines = {}
  local content_width = math.max(width - 2, 20)

  local function wrap_text(text, indent)
    indent = indent or ""
    local indent_width = vim.fn.strdisplaywidth(indent)
    local max_width = math.max(content_width - indent_width, 8)
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
  add_item(":ReviewRefresh", "Refresh remote PR/MR comments")
  add_item(":ReviewComment", "Add a note")
  add_item(":ReviewSuggestion", "Add a suggestion")
  add_item(":ReviewExport [path]", "Export notes to markdown")

  add_section("Explorer")
  add_item(km.close, "Close the full review layout")
  add_item(km.help, "Open this help")
  add_item(km.notes_list, "Open notes list")
  add_item(km.focus_files, "Focus Files section")
  add_item(km.focus_threads, "Focus Threads section")
  add_item(km.toggle_stack, "Cycle stack/commit scope")
  add_item("<CR>", "Open file or thread row")

  add_section("Diff")
  add_item(km.add_note, "Add note")
  add_item(km.suggestion, "Add suggestion")
  add_item(km.edit_note, "Edit note")
  add_item(km.delete_note, "Delete note")
  add_item(km.next_hunk, "Next hunk")
  add_item(km.prev_hunk, "Previous hunk")
  add_item(km.next_file, "Next file")
  add_item(km.prev_file, "Previous file")
  add_item(km.next_note, "Next note")
  add_item(km.prev_note, "Previous note")
  add_item(km.toggle_split, "Toggle unified/split view")
  add_item(km.focus_files, "Focus Files section")
  add_item(km.focus_threads, "Focus Threads section")
  add_item(km.toggle_stack, "Cycle stack/commit scope")
  add_item(km.notes_list, "Open notes list")
  add_item(km.close, "Close the full review layout")
  add_item(km.help, "Open this help")
  add_item("<CR>", "Open thread or edit note under cursor")

  add_section("Notes List")
  add_item("<CR>", "Open note location or thread")
  add_item("s", "Toggle draft/staged")
  add_item("P", "Publish staged notes")
  add_item("y", "Copy local notes, open threads, and discussion")
  add_item("Y", "Copy only local notes to the clipboard")
  add_item("R", "Refresh remote comments")
  add_item("C", "Clear all local notes")
  add_item("gd", "Jump to #note references")
  add_item("b", "Open remote URL")
  add_item("q", "Close")
  add_item("?", "Open this help")

  open_centered_scratch(lines, " Review Help ", width, math.min(#lines, vim.o.lines - 6))
end

--- Refresh both panels (call after state changes).
function M.refresh()
  clear_inline_preview()
  local ui_state = state.get_ui()
  if not ui_state then
    return
  end
  if vim.api.nvim_buf_is_valid(ui_state.explorer_buf) then
    render_explorer(ui_state.explorer_buf)
    local selection_line = navigator_selection_line()
    if selection_line and ui_state.explorer_win and vim.api.nvim_win_is_valid(ui_state.explorer_win) then
      vim.api.nvim_win_set_cursor(ui_state.explorer_win, { selection_line, 0 })
    end
  end
  if ui_state.view_mode == "split" and ui_state.split_buf then
    render_split(ui_state)
  elseif vim.api.nvim_buf_is_valid(ui_state.diff_buf) then
    render_diff(ui_state.diff_buf)
  end
  update_window_chrome()
end

return M
