--- All window/buffer/layout management for review.nvim
local state = require("review.state")
local diff_mod = require("review.diff")
local forge = require("review.forge")
local highlights = require("review.ui.highlights")

local M = {}

local get_diff_win
local review_closing = false
local file_line_maps
local file_stats
local setup_diff_keymaps
local choose_note_at
local navigator_width
local current_navigator_width
local truncate_end_text
local notes_list_win
local update_window_chrome
local NOTE_STATUS_ORDER = { "unreviewed", "reviewed", "needs-agent", "blocked", "resolved" }
local FILE_SORT_ORDER = { "path", "risk", "overlap", "notes", "size", "unreviewed" }
local FILE_ATTENTION_FILTER_ORDER =
  { "all", "overlap", "changed", "threads", "large", "generated", "deleted", "conflicts", "unreviewed" }
local HL = highlights.groups

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

---@param session ReviewSession
---@param note ReviewNote
---@return string
local function note_unit_label(session, note)
  return require("review.handoff").note_unit_label(session, note)
end

---@param session ReviewSession
---@param commit table|nil
---@return string|nil
local function commit_unit_label(session, commit)
  if not session or not commit then
    return nil
  end
  if commit.gitbutler then
    if commit.gitbutler.kind == "unassigned" then
      return "unassigned"
    end
    return commit.gitbutler.branch_name or commit.gitbutler.branch_cli_id or "gitbutler"
  end
  return commit.short_sha or commit.sha or session.branch or "workspace"
end

--- Set up highlight groups (called once).
---@param colorblind boolean
function M.setup_highlights(colorblind)
  highlights.setup(colorblind)
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
local files_line_map = nil
local threads_line_map = nil
local pending_local_sync_signature = nil
local commit_diff_request_seq = 0
local equalize_split_diff_widths
local last_local_sync_check_ms = nil
local last_local_sync_session = nil
local LOCAL_SYNC_CHECK_INTERVAL_MS = 2000

---@return ReviewFile|nil
local function current_display_file()
  local file = state.active_current_file()
  if file and file.untracked and file.untracked_lazy then
    local ok, git = pcall(require, "review.git")
    if ok and git.hydrate_untracked_file then
      git.hydrate_untracked_file(file)
    end
  end
  return file
end

---@return boolean
local function worktree_git_enabled()
  local s = state.get()
  return s ~= nil and s.mode == "local" and s.requested_ref == nil
end

local function sync_local_review_state()
  if not worktree_git_enabled() then
    return
  end
  local session = state.get()
  if not session then
    return
  end
  local uv = vim.uv or vim.loop
  local now_ms = math.floor(uv.hrtime() / 1000000)
  local same_session = last_local_sync_session == session
  if pending_local_sync_signature then
    return
  end
  if same_session and last_local_sync_check_ms and now_ms - last_local_sync_check_ms < LOCAL_SYNC_CHECK_INTERVAL_MS then
    return
  end
  last_local_sync_check_ms = now_ms
  last_local_sync_session = session
  local git = require("review.git")
  local workspace_signature = git.workspace_signature and git.workspace_signature() or nil
  if session.workspace_signature == workspace_signature then
    pending_local_sync_signature = nil
    return
  end
  if pending_local_sync_signature == workspace_signature then
    return
  end
  pending_local_sync_signature = workspace_signature
  local review = require("review")
  local function done(ok, err)
    if pending_local_sync_signature == workspace_signature then
      pending_local_sync_signature = nil
    end
    if ok then
      M.refresh()
    elseif err ~= "superseded" then
      vim.notify("Could not refresh local review", vim.log.levels.WARN)
    end
  end
  if type(review.refresh_local_session_async) == "function" then
    review.refresh_local_session_async(workspace_signature, done)
  else
    done(review.refresh_local_session(workspace_signature), nil)
  end
end

---@param kind "blame_context"|"log_context"
---@param value string
local function queue_note_context(kind, value)
  local ui_state = state.get_ui()
  if not ui_state then
    return
  end
  value = vim.trim(value or "")
  if value == "" then
    return
  end
  ui_state.pending_note_context = ui_state.pending_note_context or {}
  ui_state.pending_note_context[kind] = value
  vim.notify("Context will attach to the next local note", vim.log.levels.INFO)
end

---@return table
local function consume_note_context()
  local ui_state = state.get_ui()
  if not ui_state or not ui_state.pending_note_context then
    return {}
  end
  local context = ui_state.pending_note_context
  ui_state.pending_note_context = nil
  return context
end

---@return table|nil
local function pending_note_context()
  local ui_state = state.get_ui()
  return ui_state and ui_state.pending_note_context or nil
end

---@return number|nil
local function next_context_request_token()
  local ui_state = state.get_ui()
  if not ui_state then
    return nil
  end
  ui_state.context_request_seq = (ui_state.context_request_seq or 0) + 1
  return ui_state.context_request_seq
end

---@param token number|nil
---@return boolean
local function context_request_is_current(token)
  local ui_state = state.get_ui()
  return token ~= nil and ui_state ~= nil and ui_state.context_request_seq == token
end

---@param ui_state ReviewUIState
local function rebalance_left_rail(ui_state)
  local wins = {}
  if ui_state.files_win and vim.api.nvim_win_is_valid(ui_state.files_win) then
    table.insert(wins, { win = ui_state.files_win, weight = 5, min_height = 6 })
  end
  if ui_state.threads_win and vim.api.nvim_win_is_valid(ui_state.threads_win) then
    table.insert(wins, { win = ui_state.threads_win, weight = 3, min_height = 5 })
  end
  if #wins < 2 then
    return
  end

  local total_height = 0
  local total_weight = 0
  local reserved_min = 0
  for _, entry in ipairs(wins) do
    total_height = total_height + vim.api.nvim_win_get_height(entry.win)
    total_weight = total_weight + entry.weight
    reserved_min = reserved_min + entry.min_height
  end

  local slack = math.max(total_height - reserved_min, 0)
  local assigned = 0
  for i, entry in ipairs(wins) do
    local target = entry.min_height
    if i < #wins then
      local extra = math.floor(slack * entry.weight / total_weight)
      target = target + extra
      assigned = assigned + target
    else
      target = math.max(entry.min_height, total_height - assigned)
    end
    vim.wo[entry.win].winfixheight = true
    vim.api.nvim_win_set_height(entry.win, target)
  end
end

---@param win number|nil
local function clamp_navigator_scroll(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end

  vim.api.nvim_win_call(win, function()
    local buf = vim.api.nvim_win_get_buf(win)
    local line_count = math.max(vim.api.nvim_buf_line_count(buf), 1)
    local height = math.max(vim.api.nvim_win_get_height(win), 1)
    local max_topline = math.max(line_count - height + 1, 1)
    local view = vim.fn.winsaveview()
    if view.topline > max_topline then
      view.topline = max_topline
      vim.fn.winrestview(view)
    end
  end)
end

local function clamp_left_rail_scroll()
  local ui_state = state.get_ui()
  if not ui_state then
    return
  end
  clamp_navigator_scroll(ui_state.files_win or ui_state.explorer_win)
  clamp_navigator_scroll(ui_state.threads_win)
end

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

---@param files ReviewFile[]
---@return number additions, number deletions
local function aggregate_file_stats(files)
  local additions, deletions = 0, 0
  for _, file in ipairs(files) do
    local fadd, fdel = file_stats(file)
    additions = additions + fadd
    deletions = deletions + fdel
  end
  return additions, deletions
end

---@param additions number
---@param deletions number
---@return string
local function diffstat_bar(additions, deletions)
  local total = additions + deletions
  if total == 0 then
    return "....."
  end
  local add_count = math.floor((additions / total) * 5 + 0.5)
  if additions > 0 and add_count == 0 then
    add_count = 1
  end
  if deletions > 0 and add_count == 5 then
    add_count = 4
  end
  return string.rep("▪", add_count) .. string.rep("▪", 5 - add_count)
end

---@param additions number
---@param deletions number
---@return string
local function diffstat_label(additions, deletions)
  return string.format("+%d -%d %s", additions, deletions, diffstat_bar(additions, deletions))
end

---@param highlights table[]
---@param line_nr number
---@param line string
---@param additions number
---@param deletions number
local function add_diffstat_highlights(highlights, line_nr, line, additions, deletions)
  local plus_str = "+" .. tostring(additions)
  local minus_str = "-" .. tostring(deletions)
  local plus_start = line:find(plus_str, 1, true)
  if plus_start then
    plus_start = plus_start - 1
    table.insert(highlights, {
      line = line_nr,
      hl = HL.status_a_dim,
      col_start = plus_start,
      col_end = plus_start + #plus_str,
    })
  end
  local minus_start = line:find(minus_str, plus_start and (plus_start + #plus_str + 1) or 1, true)
  if minus_start then
    minus_start = minus_start - 1
    table.insert(highlights, {
      line = line_nr,
      hl = HL.status_d_dim,
      col_start = minus_start,
      col_end = minus_start + #minus_str,
    })
  end
  local total = additions + deletions
  local bar = diffstat_bar(additions, deletions)
  local bar_start = line:find(bar, 1, true)
  if not bar_start or total == 0 then
    return
  end
  bar_start = bar_start - 1
  local add_count = math.floor((additions / total) * 5 + 0.5)
  if additions > 0 and add_count == 0 then
    add_count = 1
  end
  if deletions > 0 and add_count == 5 then
    add_count = 4
  end
  for idx = 1, 5 do
    local square_col = bar_start + ((idx - 1) * #"▪")
    table.insert(highlights, {
      line = line_nr,
      hl = idx <= add_count and HL.explorer_stat_add or HL.explorer_stat_del,
      col_start = square_col,
      col_end = square_col + #"▪",
    })
  end
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

---@param status string
---@return string
local function review_status_mark(status)
  if status == "reviewed" then
    return "v"
  elseif status == "needs-agent" then
    return "!"
  elseif status == "blocked" then
    return "x"
  elseif status == "resolved" then
    return "o"
  end
  return " "
end

---@param commit table|nil
---@return string
local function review_unit_id(commit)
  if not commit then
    return "workspace"
  end
  if commit.gitbutler then
    if commit.gitbutler.kind == "unassigned" then
      return "unassigned"
    end
    return commit.gitbutler.branch_cli_id
      or commit.gitbutler.branch_name
      or commit.sha
      or commit.short_sha
      or "gitbutler"
  end
  return commit.sha or commit.short_sha or "commit"
end

---@param files ReviewFile[]
---@return number
local function reviewed_file_count(files)
  local reviewed = 0
  for _, file in ipairs(files or {}) do
    if state.get_file_review_status(file.path) == "reviewed" then
      reviewed = reviewed + 1
    end
  end
  return reviewed
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

---@param file ReviewFile
---@return number
local function file_overlap_count(file)
  local s = state.get()
  if not s or not file or not file.path then
    return 0
  end
  local seen = {}
  for _, commit in ipairs(s.commits or {}) do
    for _, commit_file in ipairs(commit.files or {}) do
      if commit_file.path == file.path then
        local key = commit.gitbutler and (commit.gitbutler.branch_cli_id or commit.gitbutler.branch_name) or commit.sha
        seen[key or tostring(commit)] = true
      end
    end
  end
  local count = 0
  for _ in pairs(seen) do
    count = count + 1
  end
  return count
end

---@param file ReviewFile
---@return number
local function file_risk_score(file)
  local additions, deletions, line_count = file_stats(file)
  local score = file_focus_score(file)
  if file.status == "D" then
    score = score + 3
  end
  if file.status == "?" then
    score = score + 1
  end
  if additions + deletions >= 300 then
    score = score + 3
  elseif additions + deletions >= 100 then
    score = score + 2
  end
  if line_count >= 500 then
    score = score + 2
  end
  if file_overlap_count(file) > 1 then
    score = score + 3
  end
  local path = file.path:lower()
  if path:match("lock$") or path:match("%.min%.") or path:match("generated") then
    score = score + 2
  end
  return score
end

---@param file ReviewFile
---@return boolean
local function file_has_open_thread(file)
  for _, note in ipairs(state.get_notes(file.path)) do
    if note.status == "remote" and not note.resolved and not note.outdated then
      return true
    end
  end
  return false
end

---@param file ReviewFile
---@return boolean
local function file_is_large(file)
  local additions, deletions, line_count = file_stats(file)
  return additions + deletions >= 100 or line_count >= 500
end

---@param file ReviewFile
---@return boolean
local function file_is_generated(file)
  local path = tostring(file.path or ""):lower()
  return path:match("lock$") ~= nil or path:match("%.min%.") ~= nil or path:match("generated") ~= nil
end

---@param file ReviewFile
---@return boolean
local function file_is_conflict(file)
  local status = tostring(file.status or "")
  return status:find("U", 1, true) ~= nil or status == "AA" or status == "DD"
end

---@param file ReviewFile
---@param filter string|nil
---@return boolean
local function file_matches_attention_filter(file, filter)
  filter = filter or "all"
  if filter == "all" or filter == "" then
    return true
  elseif filter == "overlap" then
    return file_overlap_count(file) > 1
  elseif filter == "changed" then
    local snapshot_state = state.review_snapshot_file_state(file)
    return snapshot_state == "changed" or snapshot_state == "new"
  elseif filter == "threads" then
    return file_has_open_thread(file)
  elseif filter == "large" then
    return file_is_large(file)
  elseif filter == "generated" then
    return file_is_generated(file)
  elseif filter == "deleted" then
    return file.status == "D"
  elseif filter == "conflicts" then
    return file_is_conflict(file)
  elseif filter == "unreviewed" then
    return state.get_file_review_status(file.path) == "unreviewed"
  end
  return true
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
  if session and session.vcs == "gitbutler" then
    local max_width = math.max(current_navigator_width() - 1, 8)
    local branch_line = format_context_line(" ", "GitButler workspace", max_width)
    local upstream = session.gitbutler and session.gitbutler.upstreamState
    if upstream and upstream.behind then
      return branch_line, format_context_line(" behind ", tostring(upstream.behind) .. " upstream commit(s)", max_width)
    end
    return branch_line, nil
  end
  local branch = git.current_branch() or "HEAD"
  local base = session and session.base_ref or nil
  local max_width = math.max(current_navigator_width() - 1, 8)
  local branch_line = format_context_line(" ", branch, max_width)

  if base and base ~= "" and base ~= "HEAD" and branch ~= base then
    return branch_line, format_context_line(" against ", base, max_width)
  end
  return branch_line, nil
end

---@param session ReviewSession
---@param max_width number
---@return string|nil
local function worktree_context_line(session, max_width)
  if not session or session.mode ~= "local" or session.vcs == "gitbutler" or session.requested_ref then
    return nil
  end

  local counts = {
    staged = 0,
    unstaged = 0,
    untracked = 0,
  }
  local seen_untracked = {}

  for _, file in ipairs(session.files or {}) do
    if file.git_section == "staged" or file.staged then
      counts.staged = counts.staged + 1
    elseif file.git_section == "unstaged" or file.unstaged then
      counts.unstaged = counts.unstaged + 1
    elseif file.git_section == "untracked" or file.untracked or file.status == "?" then
      counts.untracked = counts.untracked + 1
      if file.path then
        seen_untracked[file.path] = true
      end
    end
  end

  for _, file in ipairs(session.untracked_files or {}) do
    if file.path and not seen_untracked[file.path] then
      counts.untracked = counts.untracked + 1
    end
  end

  local parts = {}
  if counts.staged > 0 then
    table.insert(parts, "staged " .. counts.staged)
  end
  if counts.unstaged > 0 then
    table.insert(parts, "unstaged " .. counts.unstaged)
  end
  if counts.untracked > 0 then
    table.insert(parts, "untracked " .. counts.untracked)
  end
  if #parts == 0 then
    return nil
  end
  local full = table.concat(parts, " · ")
  local prefix = " dirty  "
  if vim.fn.strdisplaywidth(prefix .. full) <= max_width then
    return prefix .. full
  end

  local compact = {}
  if counts.staged > 0 then
    table.insert(compact, "S" .. tostring(counts.staged))
  end
  if counts.unstaged > 0 then
    table.insert(compact, "U" .. tostring(counts.unstaged))
  end
  if counts.untracked > 0 then
    table.insert(compact, "?" .. tostring(counts.untracked))
  end
  return format_context_line(prefix, table.concat(compact, " "), max_width)
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
  if state.is_gitbutler() then
    base = "GitButler"
    head = "workspace"
  end
  if commit then
    if commit.gitbutler and commit.gitbutler.kind == "branch" then
      head = commit.gitbutler.branch_name or commit.message
    elseif commit.gitbutler and commit.gitbutler.kind == "unassigned" then
      head = "unassigned"
    else
      head = commit.short_sha
    end
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
      state.is_gitbutler() and "GitButler stack" or "Current stack",
      state.is_gitbutler() and "gb stack" or "stack",
    }
  elseif commit.gitbutler and commit.gitbutler.kind == "branch" then
    variants = {
      string.format("branch %s", commit.gitbutler.branch_name or commit.message),
      commit.gitbutler.branch_name or commit.message,
    }
  elseif commit.gitbutler and commit.gitbutler.kind == "unassigned" then
    variants = {
      "unassigned changes",
      "unassigned",
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

---@param text string
---@return string
local function statusline_escape(text)
  return tostring(text or ""):gsub("%%", "%%%%")
end

---@param file ReviewFile
---@return string
---@param side string|nil
local function build_diff_winbar(file, side)
  local ui_state = state.get_ui()
  local mode_hint = ui_state and ui_state.view_mode == "split" and "[S] unified" or "[S] split"
  local prefix = "[Diff] "
  if side == "old" then
    prefix = "[S] Old "
  elseif side == "new" then
    prefix = "New "
  end
  local parts = {
    "%#",
    HL.panel_meta,
    "#",
    prefix,
    "%#",
    HL.explorer_path,
    "#",
    statusline_escape(file.path),
    " ",
  }
  if not side then
    vim.list_extend(parts, {
      "%#",
      HL.panel_meta,
      "#",
      mode_hint,
      " ",
    })
  end
  return table.concat(parts)
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
  local loading_suffix = (state.comments_loading() or state.local_refresh_loading()) and "  •  sync" or ""
  local right_text = compare_label .. "  •  " .. commit_label .. loading_suffix
  local right_width = vim.fn.strdisplaywidth(right_text)
  local counts_width = vim.fn.strdisplaywidth(" +" .. additions .. " -" .. deletions .. " ")
  local left_budget = math.max(width - right_width - counts_width - 6, 12)
  local path_label = statusline_escape(truncate_middle_text(file.path, left_budget))

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
  local target = math.max(math.floor(cols * 0.25), 21)
  local a, b = 13, 21

  while b <= target do
    a, b = b, a + b
  end

  return a
end

current_navigator_width = function()
  local ui = state.get_ui()
  if ui then
    local files_win = ui.files_win or ui.explorer_win
    if files_win and vim.api.nvim_win_is_valid(files_win) then
      return vim.api.nvim_win_get_width(files_win)
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
  local ui_state = state.get_ui()
  local sort_mode = ui_state and ui_state.file_sort_mode or "path"
  local hide_reviewed = ui_state and ui_state.hide_reviewed_files or false
  local attention_filter = ui_state and ui_state.file_attention_filter or "all"
  local search_query = ui_state and vim.trim(tostring(ui_state.file_search_query or "")):lower() or ""
  local s = state.get()

  local function file_matches_search(file)
    if search_query == "" then
      return true
    end
    local parts = { file.path or "", file.status or "" }
    for _, note in ipairs(state.get_notes(file.path)) do
      table.insert(parts, note.body or "")
      table.insert(parts, note.author or "")
      table.insert(parts, tostring(note.id or ""))
      if note.replies then
        for _, reply in ipairs(note.replies) do
          table.insert(parts, reply.body or "")
          table.insert(parts, reply.author or "")
        end
      end
    end
    if s then
      for _, commit in ipairs(s.commits or {}) do
        for _, commit_file in ipairs(commit.files or {}) do
          if commit_file.path == file.path then
            table.insert(parts, commit.message or "")
            table.insert(parts, commit.short_sha or commit.sha or "")
            table.insert(parts, commit.author or "")
            break
          end
        end
      end
    end
    return table.concat(parts, " "):lower():find(search_query, 1, true) ~= nil
  end

  for idx, file in ipairs(files) do
    if
      (not hide_reviewed or state.get_file_review_status(file.path) ~= "reviewed")
      and file_matches_attention_filter(file, attention_filter)
      and file_matches_search(file)
    then
      table.insert(entries, {
        idx = idx,
        file = file,
      })
    end
  end

  table.sort(entries, function(a, b)
    if sort_mode == "risk" then
      local ar, br = file_risk_score(a.file), file_risk_score(b.file)
      if ar ~= br then
        return ar > br
      end
    elseif sort_mode == "overlap" then
      local ao, bo = file_overlap_count(a.file), file_overlap_count(b.file)
      if ao ~= bo then
        return ao > bo
      end
    elseif sort_mode == "notes" then
      local an, bn = visible_note_count(a.file), visible_note_count(b.file)
      if an ~= bn then
        return an > bn
      end
    elseif sort_mode == "size" then
      local aa, ad = file_stats(a.file)
      local ba, bd = file_stats(b.file)
      local asize, bsize = aa + ad, ba + bd
      if asize ~= bsize then
        return asize > bsize
      end
    elseif sort_mode == "unreviewed" then
      local ar = state.get_file_review_status(a.file.path) == "unreviewed" and 1 or 0
      local br = state.get_file_review_status(b.file.path) == "unreviewed" and 1 or 0
      if ar ~= br then
        return ar > br
      end
    end
    return a.file.path:lower() < b.file.path:lower()
  end)
  return entries
end

---@return string
local function active_scope_label()
  local mode = state.scope_mode()
  if mode == "all" then
    return "all"
  end

  local commit = state.current_commit()
  if not commit then
    return mode == "select_commit" and "select" or "current"
  end

  if commit.gitbutler and commit.gitbutler.kind == "branch" then
    local detail = commit.gitbutler.branch_name or commit.message
    if mode == "select_commit" then
      return "select branch · " .. detail
    end
    return "branch · " .. detail
  end
  if commit.gitbutler and commit.gitbutler.kind == "unassigned" then
    return mode == "select_commit" and "select · unassigned" or "unassigned"
  end

  local detail = string.format("%s %s", commit.short_sha, commit.message)
  if mode == "select_commit" then
    return "select · " .. detail
  end
  return "current · " .. detail
end

---@return table[]
local function scope_picker_rows()
  local s = state.get()
  if not s or not s.commits or #s.commits == 0 then
    return {}
  end
  local ui_state = state.get_ui()
  local sort_mode = ui_state and ui_state.file_sort_mode or "path"
  local attention_filter = ui_state and ui_state.file_attention_filter or "all"
  local search_query = ui_state and vim.trim(tostring(ui_state.file_search_query or "")):lower() or ""

  local function unit_note_count(files)
    local total = 0
    for _, file in ipairs(files or {}) do
      total = total + visible_note_count(file)
    end
    return total
  end

  local function unit_risk(files)
    local total = 0
    for _, file in ipairs(files or {}) do
      total = total + file_risk_score(file)
    end
    return total
  end

  local function unit_matches_search(row)
    if search_query == "" then
      return true
    end
    local parts = {
      row.label or "",
      row.source or "",
      row.commit and row.commit.sha or "",
      row.commit and row.commit.short_sha or "",
      row.commit and row.commit.message or "",
      row.commit and row.commit.author or "",
    }
    for _, file in ipairs(row.files or {}) do
      table.insert(parts, file.path or "")
      table.insert(parts, file.status or "")
      for _, note in ipairs(state.get_notes(file.path)) do
        table.insert(parts, note.body or "")
        table.insert(parts, note.author or "")
        table.insert(parts, tostring(note.id or ""))
      end
    end
    return table.concat(parts, " "):lower():find(search_query, 1, true) ~= nil
  end

  local function unit_matches_attention(row)
    if attention_filter == "all" or attention_filter == "" then
      return true
    end
    for _, file in ipairs(row.files or {}) do
      if file_matches_attention_filter(file, attention_filter) then
        return true
      end
    end
    return false
  end

  local rows = {
    {
      type = "scope_all",
      label = "all",
      source = "workspace",
      unit_id = review_unit_id(nil),
      files = state.all_files(),
    },
  }
  local commit_rows = {}
  for idx, commit in ipairs(s.commits) do
    local label
    local source
    if commit.gitbutler and commit.gitbutler.kind == "branch" then
      source = "gb"
      label = string.format(
        "%s  %s",
        commit.gitbutler.branch_cli_id or commit.short_sha,
        commit.gitbutler.branch_name or commit.message
      )
    elseif commit.gitbutler and commit.gitbutler.kind == "unassigned" then
      source = "gb"
      label = "unassigned  changes"
    else
      source = "commit"
      label = string.format("%s  %s", commit.short_sha, commit.message)
    end
    table.insert(commit_rows, {
      type = "commit",
      idx = idx,
      commit = commit,
      source = source,
      loading = commit.loading == true,
      unit_id = review_unit_id(commit),
      files = commit.files or {},
      label = label,
    })
  end
  table.sort(commit_rows, function(a, b)
    if sort_mode == "risk" then
      local ar, br = unit_risk(a.files), unit_risk(b.files)
      if ar ~= br then
        return ar > br
      end
    elseif sort_mode == "overlap" then
      local ao, bo = 0, 0
      for _, file in ipairs(a.files or {}) do
        ao = ao + file_overlap_count(file)
      end
      for _, file in ipairs(b.files or {}) do
        bo = bo + file_overlap_count(file)
      end
      if ao ~= bo then
        return ao > bo
      end
    elseif sort_mode == "notes" then
      local an, bn = unit_note_count(a.files), unit_note_count(b.files)
      if an ~= bn then
        return an > bn
      end
    elseif sort_mode == "size" then
      local aa, ad = aggregate_file_stats(a.files or {})
      local ba, bd = aggregate_file_stats(b.files or {})
      local asize, bsize = aa + ad, ba + bd
      if asize ~= bsize then
        return asize > bsize
      end
    elseif sort_mode == "unreviewed" then
      local ar = reviewed_file_count(a.files or {})
      local br = reviewed_file_count(b.files or {})
      if ar ~= br then
        return ar < br
      end
    end
    return tostring(a.label):lower() < tostring(b.label):lower()
  end)
  for _, row in ipairs(commit_rows) do
    if unit_matches_attention(row) and unit_matches_search(row) then
      table.insert(rows, row)
    end
  end
  return rows
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

---@param note ReviewNote
---@return boolean
local function note_is_gitbutler_unpublished(note)
  return note and note.gitbutler and (note.gitbutler.unpublished == true or note.gitbutler.kind == "unassigned")
    or false
end

---@param files ReviewFile[]
---@return number
local function unit_visible_note_count(files)
  local total = 0
  for _, file in ipairs(files or {}) do
    total = total + visible_note_count(file)
  end
  return total
end

---@param iso_str string|nil
---@return string
local function relative_time_label(iso_str)
  if not iso_str or iso_str == "" then
    return ""
  end
  local y, m, d, hh, mm, ss = iso_str:match("^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)")
  if not y then
    return ""
  end
  local then_ts = os.time({
    year = tonumber(y),
    month = tonumber(m),
    day = tonumber(d),
    hour = tonumber(hh),
    min = tonumber(mm),
    sec = tonumber(ss),
  })
  local diff = math.max(os.time() - then_ts, 0)
  if diff < 60 then
    return tostring(diff) .. "s"
  end
  if diff < 3600 then
    return tostring(math.floor(diff / 60)) .. "m"
  end
  if diff < 86400 then
    return tostring(math.floor(diff / 3600)) .. "h"
  end
  return tostring(math.floor(diff / 86400)) .. "d"
end

---@param note ReviewNote
---@return string
local function thread_status(note)
  if note.resolved then
    return "resolved"
  end
  if note.outdated then
    return "stale"
  end
  return "open"
end

---@param note ReviewNote
---@return string
local function latest_note_preview(note)
  local body = note.body or ""
  if note.replies and #note.replies > 0 then
    body = note.replies[#note.replies].body or body
  end
  return (body:match("^([^\n]*)") or "")
end

---@param note ReviewNote
---@return string
local function latest_note_author(note)
  if note.replies and #note.replies > 0 then
    return note.replies[#note.replies].author or note.author or "?"
  end
  return note.author or "you"
end

---@param note ReviewNote
---@return string
local function latest_note_time(note)
  if note.replies and #note.replies > 0 then
    return relative_time_label(note.replies[#note.replies].created_at)
  end
  return ""
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
      vendor_notes = {},
      local_notes = {},
    }
  end

  local scoped_notes = state.scoped_notes()
  for _, note in ipairs(scoped_notes) do
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
      table.insert(entry.vendor_notes, note)
    else
      table.insert(entry.local_notes, note)
    end
    ::continue::
  end

  local vendor_rows = {}
  local local_rows = {}
  for path, entry in pairs(by_path) do
    if #entry.vendor_notes > 0 then
      table.insert(vendor_rows, {
        source = "vendor",
        label = vendor_label,
        path = path,
        idx = entry.idx,
        count = #entry.vendor_notes,
        notes = entry.vendor_notes,
        note = entry.vendor_notes[1],
      })
    end
    if #entry.local_notes > 0 then
      table.insert(local_rows, {
        source = "local",
        label = "local/",
        path = path,
        idx = entry.idx,
        count = #entry.local_notes,
        notes = entry.local_notes,
        note = entry.local_notes[1],
        commit_short_sha = entry.local_notes[1] and entry.local_notes[1].commit_short_sha or nil,
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

---@return table[]
local function build_stale_sections()
  local _, stale_notes = state.scoped_notes()
  if #stale_notes == 0 then
    return {}
  end

  local info = state.get_forge_info()
  local vendor_label = (info and info.forge or "vendor") .. "/"
  local grouped = {}

  for _, note in ipairs(stale_notes) do
    local source = note.status == "remote" and vendor_label or "local/"
    local path = note.file_path or "(discussion)"
    local key = source .. "::" .. path
    local entry = grouped[key]
    if not entry then
      entry = {
        label = source,
        path = path,
        count = 0,
        note = note,
        notes = {},
        commit_short_sha = note.commit_short_sha,
      }
      grouped[key] = entry
    end
    entry.count = entry.count + 1
    table.insert(entry.notes, note)
  end

  local sections_by_label = {}
  for _, entry in pairs(grouped) do
    sections_by_label[entry.label] = sections_by_label[entry.label] or {}
    table.insert(sections_by_label[entry.label], entry)
  end

  local sections = {}
  for _, label in ipairs({ vendor_label, "local/" }) do
    local rows = sections_by_label[label]
    if rows and #rows > 0 then
      table.sort(rows, function(a, b)
        return a.path < b.path
      end)
      table.insert(sections, { label = label, rows = rows })
    end
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

  local active = state.active_files()
  local file_idx, file
  for i, f in ipairs(active) do
    if f.path == file_path then
      file_idx = i
      file = f
      break
    end
  end
  if (not file_idx or not file) and sess.current_commit_idx then
    state.set_commit(nil)
    active = state.active_files()
    for i, f in ipairs(active) do
      if f.path == file_path then
        file_idx = i
        file = f
        break
      end
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
  if not s or not files_line_map then
    return nil
  end

  for line_nr, entry in ipairs(files_line_map) do
    if entry.type == "file" and entry.idx == s.current_file_idx then
      return line_nr
    end
  end

  for line_nr, entry in ipairs(files_line_map) do
    if entry.type == "commit" and entry.idx == s.current_commit_idx then
      return line_nr
    end
  end

  return nil
end

---@param section string
---@return number|nil
local function section_line(section)
  local line_map = (section == "threads" or section == "stale") and threads_line_map or files_line_map
  if not line_map then
    return nil
  end
  for line_nr, entry in ipairs(line_map) do
    local actionable = (section == "threads" or section == "stale")
        and (entry.type == "thread_file" or entry.type == "thread_note" or entry.type == "stale")
      or entry.type == "file"
      or (section == "scope" and (entry.type == "scope_all" or entry.type == "commit"))
    if entry.section == section and actionable then
      return line_nr
    end
  end
  for line_nr, entry in ipairs(line_map) do
    if entry.type == "header" and entry.section == section then
      return line_nr
    end
  end
  return nil
end

---@param section string
function M.focus_section(section)
  local ui_state = state.get_ui()
  local target_win = (section == "threads" or section == "stale") and ui_state and ui_state.threads_win
    or ui_state and ui_state.files_win
  if not target_win and ui_state then
    target_win = ui_state.explorer_win
  end
  if not ui_state or not target_win or not vim.api.nvim_win_is_valid(target_win) then
    return
  end

  local line_nr
  if section == "files" then
    local current_line = vim.api.nvim_win_get_cursor(target_win)[1]
    local current_entry = files_line_map and files_line_map[current_line]
    if current_entry and current_entry.section == "files" and current_entry.type == "file" then
      line_nr = current_line
    else
      line_nr = navigator_selection_line()
    end
  end
  line_nr = line_nr or section_line(section)
  if not line_nr then
    return
  end
  vim.api.nvim_set_current_win(target_win)
  vim.api.nvim_win_set_cursor(target_win, { line_nr, 0 })
end

function M.focus_diff()
  local ui_state = state.get_ui()
  if not ui_state then
    return
  end
  local current = vim.api.nvim_get_current_win()
  local target = ui_state.diff_win
  if
    ui_state.view_mode == "split"
    and ui_state.split_win
    and vim.api.nvim_win_is_valid(ui_state.split_win)
    and current == ui_state.diff_win
  then
    target = ui_state.split_win
  end
  if target and vim.api.nvim_win_is_valid(target) then
    vim.api.nvim_set_current_win(target)
  end
end

function M.focus_git()
  vim.notify("Git status panes are no longer embedded; use :Git outside review.nvim", vim.log.levels.INFO)
end

---@param delta number Positive expands the diff area, negative shrinks it.
local function resize_diff_area(delta)
  local ui_state = state.get_ui()
  if not ui_state then
    return
  end
  local rail_win = ui_state.explorer_win or ui_state.files_win
  local diff_win = ui_state.diff_win
  if
    not rail_win
    or not vim.api.nvim_win_is_valid(rail_win)
    or not diff_win
    or not vim.api.nvim_win_is_valid(diff_win)
  then
    return
  end

  local original = vim.api.nvim_get_current_win()
  local current_width = vim.api.nvim_win_get_width(rail_win)
  local min_rail = 18
  local min_diff = 30
  local max_rail = math.max(min_rail, vim.o.columns - min_diff)
  local next_width = math.min(math.max(current_width - delta, min_rail), max_rail)
  if next_width == current_width then
    return
  end

  vim.api.nvim_set_current_win(rail_win)
  vim.cmd("vertical resize " .. tostring(next_width))
  ui_state.explorer_width = vim.api.nvim_win_get_width(rail_win)
  if original and vim.api.nvim_win_is_valid(original) then
    vim.api.nvim_set_current_win(original)
  end
  equalize_split_diff_widths(ui_state)
  update_window_chrome()
end

local function resize_left_rail_to_screen()
  local ui_state = state.get_ui()
  if not ui_state then
    return
  end
  local rail_win = ui_state.explorer_win or ui_state.files_win
  if not rail_win or not vim.api.nvim_win_is_valid(rail_win) then
    return
  end
  local original = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(rail_win)
  vim.cmd("vertical resize " .. tostring(navigator_width()))
  ui_state.explorer_width = vim.api.nvim_win_get_width(rail_win)
  if original and vim.api.nvim_win_is_valid(original) then
    vim.api.nvim_set_current_win(original)
  end
  M.refresh()
end

update_window_chrome = function()
  local ui_state = state.get_ui()
  if not ui_state then
    return
  end

  local file = current_display_file()

  if ui_state.explorer_win and vim.api.nvim_win_is_valid(ui_state.explorer_win) then
    vim.wo[ui_state.explorer_win].winbar = ""
    vim.api.nvim_set_option_value("statusline", " ", { scope = "local", win = ui_state.explorer_win })
  end
  if ui_state.threads_win and vim.api.nvim_win_is_valid(ui_state.threads_win) then
    vim.wo[ui_state.threads_win].winbar = ""
    vim.api.nvim_set_option_value("statusline", " ", { scope = "local", win = ui_state.threads_win })
  end

  if ui_state.diff_win and vim.api.nvim_win_is_valid(ui_state.diff_win) then
    if file then
      vim.wo[ui_state.diff_win].winbar = build_diff_winbar(file, ui_state.view_mode == "split" and "old" or nil)
      vim.wo[ui_state.diff_win].statusline = build_diff_statusline(file, vim.api.nvim_win_get_width(ui_state.diff_win))
    else
      vim.wo[ui_state.diff_win].winbar = ""
      vim.wo[ui_state.diff_win].statusline = ""
    end
  end
  if ui_state.split_win and vim.api.nvim_win_is_valid(ui_state.split_win) then
    if file then
      vim.wo[ui_state.split_win].winbar = build_diff_winbar(file, "new")
      vim.wo[ui_state.split_win].statusline =
        build_diff_statusline(file, vim.api.nvim_win_get_width(ui_state.split_win))
    else
      vim.wo[ui_state.split_win].winbar = ""
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
local function render_files_pane(buf)
  local s = state.get()
  if not s then
    return
  end

  local lines = {}
  local highlights = {}
  files_line_map = {}

  local active_files = state.active_files()
  local explorer_width = current_navigator_width()
  local branch_line, base_line = navigator_context_lines()
  local worktree_line = worktree_context_line(s, math.max(explorer_width - 1, 8))
  local header_indent = " "
  local file_indent = "  "
  local scope_indent = "  "
  local row_budget = math.max(explorer_width - 7, 10)
  local ui_state = state.get_ui()
  if ui_state then
    ui_state.file_tree_mode = ui_state.file_tree_mode or "tree"
    ui_state.file_sort_mode = ui_state.file_sort_mode or "path"
    ui_state.file_attention_filter = ui_state.file_attention_filter or "all"
    ui_state.file_search_query = ui_state.file_search_query or ""
    ui_state.expanded_files = ui_state.expanded_files or {}
    ui_state.collapsed_dirs = ui_state.collapsed_dirs or {}
  end
  local tracked_files = {}
  local untracked_files = {}
  for _, entry in ipairs(sorted_file_entries(active_files)) do
    if entry.file.untracked or (entry.file.status == "?" and not entry.file.gitbutler) then
      table.insert(untracked_files, entry)
    else
      table.insert(tracked_files, entry)
    end
  end
  local additions, deletions = aggregate_file_stats(active_files)

  local function add_separator(section)
    table.insert(lines, " " .. string.rep("─", math.max(8, explorer_width - 3)))
    table.insert(files_line_map, { type = "separator", section = section })
    table.insert(highlights, { line = #lines - 1, hl = HL.note_separator, col_start = 1, col_end = -1 })
  end

  local function add_section_header(section, label, hl)
    table.insert(lines, header_indent .. label)
    table.insert(files_line_map, { type = "header", section = section })
    table.insert(highlights, { line = #lines - 1, hl = hl, col_start = 1, col_end = -1 })
  end

  local function note_badge(file)
    local count = visible_note_count(file)
    if count == 0 then
      return ""
    end
    return string.format(" (%d)", count)
  end

  local function review_mark(file)
    return review_status_mark(state.get_file_review_status(file.path))
  end

  local function dir_of(path)
    local dir = path:match("^(.*)/[^/]+$")
    if not dir or dir == "" then
      return "./"
    end
    return dir .. "/"
  end

  local function basename(path)
    return path:match("([^/]+)$") or path
  end

  local function directory_note_count(entries)
    local total = 0
    local reviewed = 0
    for _, entry in ipairs(entries) do
      total = total + visible_note_count(entry.file)
      if state.get_file_review_status(entry.file.path) == "reviewed" then
        reviewed = reviewed + 1
      end
    end
    return total, reviewed
  end

  ---@param status string
  ---@return string
  local function status_highlight(status)
    if status == "A" or status == "?" then
      return HL.status_a
    end
    if status == "D" then
      return HL.status_d
    end
    return HL.status_m
  end

  local function status_marker(status)
    if status == "A" then
      return "+"
    end
    if status == "?" then
      return "?"
    end
    if status == "D" then
      return "-"
    end
    if status == "R" or status == "C" then
      return "="
    end
    return "~"
  end

  local function add_file_row(section, entry, label, indent)
    local file = entry.file
    local is_active = (entry.idx == s.current_file_idx)
    local badge = note_badge(file)
    local mark = review_mark(file)
    local is_reviewed = mark ~= " "
    local label_budget = math.max(row_budget - vim.fn.strdisplaywidth(indent) - vim.fn.strdisplaywidth(badge) - 6, 8)
    local path_label = truncate_middle_text(label, label_budget)
    local display_status = status_marker(file.status)
    local line = string.format("%s%s %s%s", indent, display_status, path_label, badge)

    table.insert(lines, line)
    table.insert(files_line_map, { type = "file", idx = entry.idx, section = section, file_path = file.path })
    local li = #lines - 1
    if is_active then
      table.insert(highlights, {
        line = li,
        hl = HL.explorer_active_row,
        col_start = 0,
        col_end = -1,
      })
    end

    local status_col = vim.fn.stridx(line, display_status)
    table.insert(highlights, {
      line = li,
      hl = status_highlight(file.status),
      col_start = math.max(status_col, 0),
      col_end = math.max(status_col, 0) + 1,
    })

    local path_col = line:find(path_label, 1, true)
    if path_col then
      table.insert(highlights, {
        line = li,
        hl = is_active and HL.explorer_active or is_reviewed and HL.explorer_file_reviewed or HL.explorer_file,
        col_start = path_col - 1,
        col_end = path_col - 1 + #path_label,
      })
    end

    if ui_state and ui_state.expanded_files and ui_state.expanded_files[file.path] then
      local file_notes = state.get_notes(file.path)
      for _, note in ipairs(file_notes) do
        local first = (note.body or ""):match("^([^\n]*)") or ""
        local note_label = string.format("    #%s %s", tostring(note.id or "?"), first)
        table.insert(lines, truncate_end_text(note_label, math.max(explorer_width - 1, 8)))
        table.insert(files_line_map, { type = "note", section = section, note_id = note.id, file_path = file.path })
        table.insert(highlights, { line = #lines - 1, hl = HL.note_sign, col_start = 4, col_end = -1 })
      end
    end
  end

  local function add_file_rows(section, entries)
    if not ui_state or ui_state.file_tree_mode == "flat" then
      for _, entry in ipairs(entries) do
        local path = entry.file.path
        local dir = dir_of(path)
        local label = basename(path)
        if dir ~= "./" then
          label = label .. "  " .. dir:gsub("/$", "")
        end
        add_file_row(section, entry, label, file_indent)
      end
      return
    end

    local function new_dir_node(name, path)
      return {
        name = name,
        path = path,
        dirs = {},
        dir_order = {},
        files = {},
        total = 0,
        reviewed = 0,
        notes = 0,
      }
    end

    local root = new_dir_node("./", "")
    for _, entry in ipairs(entries) do
      local parts = {}
      for part in entry.file.path:gmatch("[^/]+") do
        table.insert(parts, part)
      end
      local node = root
      for idx = 1, math.max(#parts - 1, 0) do
        local name = parts[idx]
        local parent_path = node.path
        local path = parent_path == "" and (name .. "/") or (parent_path .. name .. "/")
        if not node.dirs[name] then
          node.dirs[name] = new_dir_node(name, path)
          table.insert(node.dir_order, name)
        end
        node = node.dirs[name]
      end
      table.insert(node.files, entry)
    end

    local function compute_dir_totals(node)
      local notes, reviewed = directory_note_count(node.files)
      local total = #node.files
      table.sort(node.dir_order)
      for _, name in ipairs(node.dir_order) do
        local child = node.dirs[name]
        compute_dir_totals(child)
        notes = notes + child.notes
        reviewed = reviewed + child.reviewed
        total = total + child.total
      end
      node.notes = notes
      node.reviewed = reviewed
      node.total = total
    end

    local function render_dir(node, indent, label)
      if node.total == 0 then
        return
      end
      local suffix = node.notes > 0 and string.format("  %d note%s", node.notes, node.notes == 1 and "" or "s") or ""
      local meta = string.format("  %d/%d reviewed%s", node.reviewed, node.total, suffix)
      local dir_key = section .. "::" .. (node.path ~= "" and node.path or "./")
      local collapsed = ui_state.collapsed_dirs and ui_state.collapsed_dirs[dir_key] == true
      local marker = collapsed and "+" or "-"
      local left = indent .. marker .. " " .. label
      local available = math.max(explorer_width - vim.fn.strdisplaywidth(indent), 8)
      local meta_width = vim.fn.strdisplaywidth(meta)
      local left_budget = math.max(available - meta_width, 4)
      left = indent .. truncate_end_text(marker .. " " .. label, left_budget)
      local gap = math.max(explorer_width - vim.fn.strdisplaywidth(left) - meta_width, 1)
      local line = left .. string.rep(" ", gap) .. meta
      table.insert(lines, line)
      table.insert(files_line_map, { type = "dir", section = section, dir_key = dir_key })
      local li = #lines - 1
      local marker_col = #indent
      local name_col = marker_col + 2
      local meta_start =
        line:find("  " .. tostring(node.reviewed) .. "/" .. tostring(node.total) .. " reviewed", 1, true)
      table.insert(highlights, {
        line = li,
        hl = HL.explorer_dir_marker,
        col_start = marker_col,
        col_end = marker_col + 1,
      })
      table.insert(highlights, {
        line = li,
        hl = HL.explorer_dir,
        col_start = name_col,
        col_end = meta_start and (meta_start - 1) or -1,
      })
      if meta_start then
        table.insert(highlights, {
          line = li,
          hl = HL.explorer_dir_meta,
          col_start = meta_start - 1,
          col_end = -1,
        })
      end
      if not collapsed then
        local child_indent = indent .. "  "
        for _, entry in ipairs(node.files) do
          add_file_row(section, entry, basename(entry.file.path), child_indent)
        end
        for _, name in ipairs(node.dir_order) do
          local child = node.dirs[name]
          render_dir(child, child_indent, name .. "/")
        end
      end
    end

    compute_dir_totals(root)
    if #root.files > 0 then
      for _, entry in ipairs(root.files) do
        add_file_row(section, entry, basename(entry.file.path), file_indent)
      end
    end
    for _, name in ipairs(root.dir_order) do
      local child = root.dirs[name]
      render_dir(child, header_indent, name .. "/")
    end
  end

  table.insert(lines, branch_line)
  table.insert(files_line_map, { type = "header", section = "context" })
  table.insert(highlights, { line = #lines - 1, hl = HL.explorer_active, col_start = 1, col_end = -1 })
  if base_line then
    table.insert(lines, base_line)
    table.insert(files_line_map, { type = "header", section = "context" })
    table.insert(highlights, { line = #lines - 1, hl = HL.panel_meta, col_start = 1, col_end = 9 })
    table.insert(highlights, { line = #lines - 1, hl = HL.panel_title, col_start = 9, col_end = -1 })
  end
  if worktree_line then
    table.insert(lines, worktree_line)
    table.insert(files_line_map, { type = "header", section = "context" })
    table.insert(highlights, { line = #lines - 1, hl = HL.panel_meta, col_start = 1, col_end = 8 })
    table.insert(highlights, { line = #lines - 1, hl = HL.panel_title, col_start = 8, col_end = -1 })
  end
  if s.merge_base_ref then
    local merge_line = format_context_line(" merge  ", s.merge_base_ref:sub(1, 12), math.max(explorer_width - 1, 8))
    table.insert(lines, merge_line)
    table.insert(files_line_map, { type = "header", section = "context" })
    table.insert(highlights, { line = #lines - 1, hl = HL.panel_meta, col_start = 1, col_end = 8 })
    table.insert(highlights, { line = #lines - 1, hl = HL.panel_title, col_start = 8, col_end = -1 })
  end
  local stale_reason = state.remote_context_stale_reason()
  if stale_reason then
    local stale_line = format_context_line(" stale  ", stale_reason, math.max(explorer_width - 1, 8))
    table.insert(lines, stale_line)
    table.insert(files_line_map, { type = "header", section = "context" })
    table.insert(highlights, { line = #lines - 1, hl = HL.note_separator, col_start = 1, col_end = -1 })
  end

  local scope_prefix = header_indent .. "Scope  "
  local scope_value =
    truncate_end_text(active_scope_label(), math.max(explorer_width - vim.fn.strdisplaywidth(scope_prefix), 8))
  local scope_line = scope_prefix .. scope_value
  table.insert(lines, scope_line)
  table.insert(files_line_map, { type = "header", section = "scope" })
  table.insert(highlights, { line = #lines - 1, hl = HL.explorer_scope, col_start = 1, col_end = #scope_prefix })
  table.insert(highlights, { line = #lines - 1, hl = HL.explorer_scope_value, col_start = #scope_prefix, col_end = -1 })

  local km = require("review").config.keymaps
  local scope_hint = string.format(
    "%s%s scope  %s cmp  %s base",
    header_indent,
    km.toggle_stack or "<Tab>",
    km.compare_unit or "C",
    km.change_base or "B"
  )
  table.insert(lines, truncate_end_text(scope_hint, math.max(explorer_width - 1, 8)))
  table.insert(files_line_map, { type = "header", section = "scope" })
  table.insert(highlights, { line = #lines - 1, hl = HL.panel_meta, col_start = 1, col_end = -1 })

  for _, row in ipairs(scope_picker_rows()) do
    local unit_status = state.get_unit_review_status(row.unit_id)
    local unit_mark = review_status_mark(unit_status)
    local total = #(row.files or {})
    local reviewed = reviewed_file_count(row.files or {})
    local note_count = unit_visible_note_count(row.files or {})
    local progress = total > 0 and string.format("%d/%d", reviewed, total) or ""
    local meta = row.loading and string.format("%s loading", row.source or "unit")
      or string.format("%s f%d", row.source or "unit", total)
    if note_count > 0 and not row.loading then
      meta = meta .. string.format(" (%d)", note_count)
    end
    local suffix = progress ~= "" and (progress .. " " .. meta) or meta
    local label_budget =
      math.max(explorer_width - vim.fn.strdisplaywidth(scope_indent) - vim.fn.strdisplaywidth(suffix) - 4, 8)
    local is_active = (row.type == "scope_all" and state.scope_mode() == "all")
      or (row.type == "commit" and s.current_commit_idx == row.idx)
    local left = string.format("%s%s %s", scope_indent, unit_mark, truncate_end_text(row.label, label_budget))
    local gap = math.max(explorer_width - vim.fn.strdisplaywidth(left) - vim.fn.strdisplaywidth(suffix), 1)
    local line = left .. string.rep(" ", gap) .. suffix
    table.insert(lines, line)
    table.insert(files_line_map, {
      type = row.type,
      idx = row.idx,
      commit = row.commit,
      unit_id = row.unit_id,
      section = "scope",
    })
    local li = #lines - 1
    if is_active then
      table.insert(highlights, {
        line = li,
        hl = HL.explorer_active_row,
        col_start = 0,
        col_end = -1,
      })
    end
    table.insert(highlights, {
      line = li,
      hl = is_active and HL.explorer_active or HL.panel_meta,
      col_start = 2,
      col_end = -1,
    })
  end

  local filter_bits = {}
  if ui_state and ui_state.file_sort_mode and ui_state.file_sort_mode ~= "path" then
    table.insert(filter_bits, "sort:" .. ui_state.file_sort_mode)
  end
  if ui_state and ui_state.hide_reviewed_files then
    table.insert(filter_bits, "hide reviewed")
  end
  if ui_state and ui_state.file_attention_filter and ui_state.file_attention_filter ~= "all" then
    table.insert(filter_bits, "attention:" .. ui_state.file_attention_filter)
  end
  if ui_state and vim.trim(tostring(ui_state.file_search_query or "")) ~= "" then
    table.insert(filter_bits, "search:" .. ui_state.file_search_query)
  end
  local filter_suffix = #filter_bits > 0 and ("  [" .. table.concat(filter_bits, " · ") .. "]") or ""
  local files_reviewed = reviewed_file_count(active_files)
  local files_width = math.max(explorer_width - 1, 12)
  local base_files_left = header_indent .. "[F] Files"
  local stat_variants = {
    diffstat_label(additions, deletions),
    string.format("+%d -%d", additions, deletions),
    "",
  }
  local files_stat = stat_variants[#stat_variants]
  for _, variant in ipairs(stat_variants) do
    local gap_width = variant ~= "" and 1 or 0
    if vim.fn.strdisplaywidth(base_files_left) + gap_width + vim.fn.strdisplaywidth(variant) <= files_width then
      files_stat = variant
      break
    end
  end
  local file_header_variants = {
    string.format("%s[F] Files %d/%d%s", header_indent, files_reviewed, #active_files, filter_suffix),
    string.format("%s[F] Files%s", header_indent, filter_suffix),
  }
  local files_left = file_header_variants[#file_header_variants]
  for _, variant in ipairs(file_header_variants) do
    local gap_width = files_stat ~= "" and 1 or 0
    if vim.fn.strdisplaywidth(variant) + gap_width + vim.fn.strdisplaywidth(files_stat) <= files_width then
      files_left = variant
      break
    end
  end
  files_left =
    truncate_end_text(files_left, math.max(files_width - vim.fn.strdisplaywidth(files_stat) - 1, #base_files_left))
  local files_gap = files_stat ~= ""
      and math.max(files_width - vim.fn.strdisplaywidth(files_left) - vim.fn.strdisplaywidth(files_stat), 1)
    or 0
  local files_header = files_left .. string.rep(" ", files_gap) .. files_stat
  table.insert(lines, files_header)
  table.insert(files_line_map, { type = "header", section = "files" })
  table.insert(highlights, { line = #lines - 1, hl = HL.file_header, col_start = 1, col_end = 10 })
  add_diffstat_highlights(highlights, #lines - 1, files_header, additions, deletions)

  if state.is_gitbutler() and state.scope_mode() == "all" then
    local branch_groups = {}
    local branch_order = {}
    local unassigned_entries = {}
    for _, entry in ipairs(tracked_files) do
      if entry.file.gitbutler and entry.file.gitbutler.kind == "unassigned" then
        table.insert(unassigned_entries, entry)
      else
        local gb = entry.file.gitbutler or {}
        local label = gb.branch_name or gb.branch_cli_id or "assigned"
        if not branch_groups[label] then
          branch_groups[label] = {}
          table.insert(branch_order, label)
        end
        table.insert(branch_groups[label], entry)
      end
    end
    for _, label in ipairs(branch_order) do
      add_section_header("files", "Branch " .. label, HL.panel_meta)
      add_file_rows("files", branch_groups[label])
    end
    if #unassigned_entries > 0 then
      add_section_header("files", "Unassigned", HL.panel_meta)
      add_file_rows("files", unassigned_entries)
    end
    if #untracked_files > 0 then
      add_section_header("files", "Untracked", HL.panel_meta)
      add_file_rows("files", untracked_files)
    end
  else
    add_file_rows("files", tracked_files)
    if state.scope_mode() == "all" and #untracked_files > 0 then
      add_section_header("files", "Untracked", HL.panel_meta)
      add_file_rows("files", untracked_files)
    end
  end

  if #tracked_files + #untracked_files == 0 then
    table.insert(lines, "  (no files)")
    table.insert(files_line_map, { type = "separator", section = "files" })
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

local function render_threads_pane(buf)
  local s = state.get()
  if not s then
    return
  end

  local lines = {}
  local highlights = {}
  threads_line_map = {}
  local explorer_width = current_navigator_width()
  local row_budget = math.max(explorer_width - 7, 10)
  local thread_group_indent = "   "
  local thread_row_indent = "     "
  local thread_note_indent = "    "
  local active_files = state.active_files()
  local ui_state = state.get_ui()
  if ui_state then
    ui_state.thread_filter = ui_state.thread_filter or "all"
    ui_state.collapsed_thread_groups = ui_state.collapsed_thread_groups or {}
    ui_state.expanded_thread_files = ui_state.expanded_thread_files or {}
  end
  local filter = ui_state and ui_state.thread_filter or "all"
  local filters = {
    { id = "all", label = "all" },
    { id = "open", label = "open" },
    { id = "resolved", label = "done" },
    { id = "stale", label = "stale" },
  }

  local function note_matches_filter(note, stale_section)
    if filter == "all" then
      return true
    end
    if filter == "stale" then
      return stale_section or thread_status(note) == "stale"
    end
    if stale_section then
      return false
    end
    return thread_status(note) == filter
  end

  local function filtered_notes(notes, stale_section)
    local out = {}
    for _, note in ipairs(notes or {}) do
      if note_matches_filter(note, stale_section) then
        table.insert(out, note)
      end
    end
    return out
  end

  local function all_thread_notes()
    local notes = {}
    local scoped, stale = state.scoped_notes()
    vim.list_extend(notes, scoped)
    vim.list_extend(notes, stale)
    return scoped, stale
  end

  local scoped_notes, stale_notes = all_thread_notes()
  local open_count, resolved_count, stale_count = 0, 0, #stale_notes
  for _, note in ipairs(scoped_notes) do
    if note.file_path then
      if thread_status(note) == "resolved" then
        resolved_count = resolved_count + 1
      elseif thread_status(note) == "stale" then
        stale_count = stale_count + 1
      else
        open_count = open_count + 1
      end
    end
  end

  local header_width = math.max(explorer_width, 12)
  local header_variants = {
    string.format(" [T] Threads  %d open · %d done · %d stale", open_count, resolved_count, stale_count),
    string.format(" [T] Threads  %d open %d done %d stale", open_count, resolved_count, stale_count),
    string.format(" [T] Threads o%d d%d s%d", open_count, resolved_count, stale_count),
    string.format(" [T] Thrd o%d d%d s%d", open_count, resolved_count, stale_count),
    string.format(" [T] %d/%d/%d", open_count, resolved_count, stale_count),
  }
  local header = header_variants[#header_variants]
  for _, variant in ipairs(header_variants) do
    if vim.fn.strdisplaywidth(variant) <= header_width then
      header = variant
      break
    end
  end
  table.insert(lines, truncate_end_text(header, header_width))
  table.insert(threads_line_map, { type = "header", section = "threads" })
  table.insert(highlights, { line = #lines - 1, hl = HL.threads_header, col_start = 1, col_end = -1 })

  local filter_line = " "
  for _, item in ipairs(filters) do
    filter_line = filter_line .. (item.id == filter and "[" .. item.label .. "] " or item.label .. " ")
  end
  table.insert(lines, truncate_end_text(filter_line:gsub("%s+$", ""), math.max(explorer_width - 1, 12)))
  table.insert(threads_line_map, { type = "filter", section = "threads" })
  table.insert(highlights, { line = #lines - 1, hl = HL.panel_meta, col_start = 1, col_end = -1 })

  local function actor_suffix(entry)
    if not entry or not entry.actor or entry.actor == "" or entry.actor == "unknown" then
      return ""
    end
    return " @" .. entry.actor
  end

  local summary = state.remote_summary()
  if summary then
    local approvals = summary.approvals or {}
    local changes_requested = summary.changes_requested or {}
    local timeline = summary.timeline or {}
    if #approvals > 0 or #changes_requested > 0 or #timeline > 0 then
      local context_line = string.format("   PR/MR ctx  a%d c%d", #approvals, #changes_requested)
      table.insert(lines, truncate_end_text(context_line, math.max(explorer_width - 1, 12)))
      table.insert(threads_line_map, { type = "remote_summary", section = "context" })
      table.insert(highlights, { line = #lines - 1, hl = HL.vendor_group, col_start = 3, col_end = -1 })

      local shown = 0
      for idx = #timeline, 1, -1 do
        local entry = timeline[idx]
        if entry and entry.label and entry.label ~= "" then
          local line = "     · " .. entry.label .. actor_suffix(entry)
          table.insert(lines, truncate_end_text(line, math.max(explorer_width - 1, 12)))
          table.insert(threads_line_map, { type = "remote_summary", section = "context" })
          table.insert(highlights, { line = #lines - 1, hl = HL.panel_meta, col_start = 5, col_end = -1 })
          shown = shown + 1
          if shown >= 3 then
            break
          end
        end
      end
    end
  end

  local rendered_thread_count = 0

  local function add_thread_sections(section_name, sections, row_type)
    if #sections == 0 then
      return
    end

    for _, section in ipairs(sections) do
      local rendered_rows = {}
      for _, row in ipairs(section.rows) do
        local notes = filtered_notes(row.notes or { row.note }, section_name == "stale")
        if #notes > 0 then
          local copy = vim.deepcopy(row)
          copy.notes = notes
          copy.note = notes[1]
          copy.count = #notes
          table.insert(rendered_rows, copy)
        end
      end
      if #rendered_rows == 0 then
        goto continue_section
      end

      local group_count = 0
      for _, row in ipairs(rendered_rows) do
        group_count = group_count + row.count
      end
      rendered_thread_count = rendered_thread_count + group_count
      local collapsed = ui_state
        and ui_state.collapsed_thread_groups
        and ui_state.collapsed_thread_groups[section_name .. "::" .. section.label]
      local group_prefix = collapsed and "+ " or "- "
      local group_line = string.format("%s%s%s [%d]", thread_group_indent, group_prefix, section.label, group_count)
      table.insert(lines, truncate_end_text(group_line, math.max(explorer_width - 1, 12)))
      table.insert(threads_line_map, {
        type = "thread_group",
        section = section_name,
        group = section.label,
      })
      local group_hl = section.label == "local/" and HL.local_group
        or section_name == "stale" and HL.note_separator
        or HL.vendor_group
      table.insert(highlights, {
        line = #lines - 1,
        hl = HL.explorer_dir_marker,
        col_start = 3,
        col_end = 4,
      })
      table.insert(highlights, {
        line = #lines - 1,
        hl = group_hl,
        col_start = 5,
        col_end = -1,
      })
      if collapsed then
        goto continue_section
      end

      local max_badge_width = 0
      for _, row in ipairs(rendered_rows) do
        max_badge_width = math.max(max_badge_width, #string.format("[%d]", row.count))
      end

      for _, row in ipairs(rendered_rows) do
        local fname = row.path:match("([^/]+)$") or row.path
        local badge = string.format("[%d]", row.count)
        local commit_suffix = ""
        if row.commit_short_sha and state.scope_mode() == "all" then
          commit_suffix = " @" .. row.commit_short_sha
        end
        local latest = row.notes[#row.notes] or row.note
        local preview = latest and latest_note_preview(latest) or ""
        local expanded_key = section_name .. "::" .. section.label .. "::" .. row.path
        local expanded = ui_state and ui_state.expanded_thread_files and ui_state.expanded_thread_files[expanded_key]
        local prefix = expanded and "- " or "+ "
        local preview_budget = math.max(math.floor(row_budget * 0.35), 8)
        local preview_text = preview ~= "" and (" " .. truncate_end_text(preview, preview_budget)) or ""
        local name_budget =
          math.max(row_budget - max_badge_width - #thread_row_indent - #commit_suffix - #preview_text - 3, 8)
        local short_name = truncate_middle_text(fname, name_budget)
        local gap = math.max(1, name_budget - vim.fn.strdisplaywidth(short_name) + 1)
        local thread_line = string.format(
          "%s%s%s%s%s%s%s",
          thread_row_indent,
          prefix,
          short_name,
          string.rep(" ", gap),
          badge,
          preview_text,
          commit_suffix
        )
        table.insert(lines, thread_line)
        table.insert(threads_line_map, {
          type = "thread_file",
          file_path = row.path,
          line = row.note and row.note.line or nil,
          side = row.note and row.note.side or "new",
          source = row.note and row.note.status or row.source,
          note_id = row.note and row.note.id or nil,
          section = section_name,
          group = section.label,
          expanded_key = expanded_key,
        })
        local li = #lines - 1
        local source_hl = HL.note_sign
        if row.note and row.note.status == "remote" then
          source_hl = row.note.resolved and HL.note_remote_resolved or HL.note_remote
        end
        local marker_start = thread_line:find(prefix, 1, true)
        if marker_start then
          table.insert(highlights, {
            line = li,
            hl = HL.explorer_dir_marker,
            col_start = marker_start - 1,
            col_end = marker_start,
          })
        end
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
        if expanded then
          for _, note in ipairs(row.notes) do
            local status = thread_status(note)
            local status_icon = status == "resolved" and "x" or status == "stale" and "o" or "*"
            local author = truncate_end_text((latest_note_author(note):sub(1, 1)):upper(), 1)
            local replies = note.replies and math.max(#note.replies - 1, 0) or 0
            local time = latest_note_time(note)
            local note_preview = truncate_end_text(latest_note_preview(note), math.max(row_budget - 18, 8))
            local note_line = string.format(
              "%s%s %s %-6s [%d] %s",
              thread_note_indent,
              status_icon,
              author,
              time,
              replies,
              note_preview
            )
            table.insert(lines, truncate_end_text(note_line, math.max(explorer_width - 1, 12)))
            table.insert(threads_line_map, {
              type = row_type == "stale" and "stale" or "thread_note",
              file_path = row.path,
              line = note.line,
              side = note.side or "new",
              source = note.status,
              note_id = note.id,
              note = note,
              section = section_name,
            })
            table.insert(highlights, {
              line = #lines - 1,
              hl = note.status == "remote" and (note.resolved and HL.note_remote_resolved or HL.note_remote)
                or HL.note_sign,
              col_start = 4,
              col_end = -1,
            })
          end
        end
      end
      ::continue_section::
    end
  end

  add_thread_sections("threads", build_thread_sections(active_files), "thread")
  add_thread_sections("stale", build_stale_sections(), "stale")

  if rendered_thread_count == 0 then
    table.insert(lines, "  (no threads)")
    table.insert(threads_line_map, { type = "separator", section = "threads" })
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  local ns = vim.api.nvim_create_namespace("review_threads")
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
  local file = current_display_file()
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
  local file = current_display_file()
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

  local marks = {}
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
      marks[display_line] = marks[display_line] or { count = 0, remote = false, resolved = false }
      marks[display_line].count = marks[display_line].count + 1
      if note.status == "remote" then
        marks[display_line].remote = true
        marks[display_line].resolved = note.resolved == true
      end
    end
    ::skip_sign::
  end

  for display_line, mark in pairs(marks) do
    local sign, hl
    if mark.count > 1 then
      sign, hl = tostring(math.min(mark.count, 9)), HL.note_sign
    elseif mark.remote and mark.resolved then
      sign, hl = "○", HL.note_remote_resolved
    elseif mark.remote then
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
---@param note_count number|nil
local function show_inline_preview(buf, display_line, note, note_count)
  if not note.replies or #note.replies == 0 then
    -- For local notes just show the body
    local body = truncate_end_text((note.body or ""):match("^([^\n]*)") or "", 60)
    local prefix = note.id and ("#" .. tostring(note.id) .. " ") or ""
    prefix = prefix .. (note.author and ("@" .. note.author .. ": ") or "")
    if note_count and note_count > 1 then
      prefix = string.format("%d notes · %s", note_count, prefix)
    end
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
  local id_prefix = note.id and ("#" .. tostring(note.id) .. " ") or ""
  for i, reply in ipairs(note.replies) do
    if i > max_replies then
      table.insert(vlines, {
        { string.format("  \u{2502} ... and %d more", #note.replies - max_replies), HL.meta },
      })
      break
    end
    local body = truncate_end_text((reply.body or ""):match("^([^\n]*)") or "", 55)
    local line_hl = (i == 1) and HL.note_remote or HL.note_author
    local reply_prefix = i == 1 and id_prefix or ""
    table.insert(vlines, {
      { string.format("  \u{2502} %s@%s: %s", reply_prefix, reply.author or "?", body), line_hl },
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
  local file = current_display_file()
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
  local target_count = 0
  if new_lnum then
    local entries = state.find_notes_at(file.path, new_lnum, "new")
    target_count = #entries
    target_note = entries[1] and entries[1].note or nil
  end
  if not target_note and old_lnum then
    local entries = state.find_notes_at(file.path, old_lnum, "old")
    target_count = #entries
    target_note = entries[1] and entries[1].note or nil
  end

  if target_note and inline_last_note and target_note.id == inline_last_note.id then
    return
  end

  clear_inline_preview()

  if target_note then
    inline_last_buf = buf
    inline_last_note = target_note
    show_inline_preview(buf, display_line, target_note, target_count)
  end
end

---@param ui_state ReviewUIState
equalize_split_diff_widths = function(ui_state)
  if
    not ui_state
    or ui_state.view_mode ~= "split"
    or not ui_state.diff_win
    or not ui_state.split_win
    or not vim.api.nvim_win_is_valid(ui_state.diff_win)
    or not vim.api.nvim_win_is_valid(ui_state.split_win)
  then
    return
  end

  local total = vim.api.nvim_win_get_width(ui_state.diff_win) + vim.api.nvim_win_get_width(ui_state.split_win)
  if total < 2 then
    return
  end
  local old_width = math.floor(total / 2)
  vim.wo[ui_state.diff_win].winfixwidth = false
  vim.wo[ui_state.split_win].winfixwidth = false
  local original = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(ui_state.diff_win)
  pcall(vim.cmd, "vertical resize " .. tostring(old_width))
  if original and vim.api.nvim_win_is_valid(original) then
    vim.api.nvim_set_current_win(original)
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
  local file = current_display_file()
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
  equalize_split_diff_widths(ui_state)
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
    local previous_equalalways = vim.o.equalalways

    -- Focus the diff window and split it
    if ui_state.explorer_win and vim.api.nvim_win_is_valid(ui_state.explorer_win) then
      vim.wo[ui_state.explorer_win].winfixwidth = false
      vim.api.nvim_win_set_width(ui_state.explorer_win, left_width)
    end
    vim.o.equalalways = false
    vim.api.nvim_set_current_win(ui_state.diff_win)
    vim.cmd("rightbelow vsplit")
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

    ui_state.split_buf = split_buf
    ui_state.split_win = split_win

    setup_diff_keymaps(split_buf)
    attach_review_quit_guard(split_buf)

    render_split(ui_state)
    update_window_chrome()
    if ui_state.explorer_win and vim.api.nvim_win_is_valid(ui_state.explorer_win) then
      vim.wo[ui_state.explorer_win].winfixwidth = false
      vim.api.nvim_win_set_width(ui_state.explorer_win, left_width)
    end
    equalize_split_diff_widths(ui_state)
  else
    ui_state.view_mode = "unified"

    vim.wo[ui_state.diff_win].scrollbind = false
    if ui_state.explorer_win and vim.api.nvim_win_is_valid(ui_state.explorer_win) then
      local left_width = vim.api.nvim_win_get_width(ui_state.explorer_win)
      ui_state.explorer_width = left_width
      vim.wo[ui_state.explorer_win].winfixwidth = false
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
      vim.wo[ui_state.explorer_win].winfixwidth = false
      vim.api.nvim_win_set_width(ui_state.explorer_win, width)
    end
  end
end

function M.close_blame_panel()
  require("review.ui.blame").close()
end

function M.toggle_blame_panel()
  require("review.ui.blame").toggle(current_display_file(), {
    next_request_token = next_context_request_token,
    request_is_current = context_request_is_current,
    queue_context = queue_note_context,
  })
end

function M.open_file_history()
  require("review.ui.file_log").open(current_display_file(), {
    next_request_token = next_context_request_token,
    request_is_current = context_request_is_current,
    queue_context = queue_note_context,
  })
end

---@param idx number|nil
function M.open_commit_details(idx)
  require("review.ui.context").open_commit_details(idx, {
    next_request_token = next_context_request_token,
    request_is_current = context_request_is_current,
  })
end

---@param idx number|nil
function M.open_unit_compare(idx)
  require("review.ui.context").open_unit_compare(idx)
end

--- Select a commit (nil = all changes) and refresh the view.
---@param idx number|nil  Commit index, or nil for all changes
---@param opts table|nil
function M.select_commit(idx, opts)
  local s = state.get()
  if not s then
    return
  end
  opts = opts or {}
  commit_diff_request_seq = commit_diff_request_seq + 1
  local request_seq = commit_diff_request_seq

  -- If selecting a specific commit, lazily load its files
  if idx ~= nil then
    local commit = s.commits[idx]
    if commit and not commit.files and not commit.gitbutler then
      local git = require("review.git")
      if git.commit_diff_async then
        commit.loading = true
        state.set_commit(idx)
        if opts.scope_mode then
          state.set_scope_mode(opts.scope_mode)
        else
          state.set_scope_mode("current_commit")
        end
        vim.notify("Loading commit diff...", vim.log.levels.INFO)
        if state.get_ui() then
          M.refresh()
        end
        git.commit_diff_async(commit.sha, function(diff_text, err)
          if request_seq ~= commit_diff_request_seq then
            return
          end
          commit.loading = false
          if err then
            vim.notify("Could not load commit diff: " .. err, vim.log.levels.WARN)
            if state.get_ui() then
              M.refresh()
            end
            return
          end
          commit.files = diff_mod.parse(diff_text or "")
          if state.get_ui() then
            M.refresh()
          end
        end)
        return
      else
        local diff_text = git.commit_diff(commit.sha)
        commit.files = diff_mod.parse(diff_text)
        commit.loading = false
      end
    end
  end

  state.set_commit(idx)
  if idx == nil then
    state.set_scope_mode("all")
  elseif opts.scope_mode then
    state.set_scope_mode(opts.scope_mode)
  else
    state.set_scope_mode("current_commit")
  end

  if state.get_ui() then
    M.refresh()
  end
end

--- Toggle between all, current-commit, and commit-picker scope modes.
function M.toggle_stack_view()
  local s = state.get()
  if not s then
    return
  end
  if #s.commits == 0 then
    vim.notify("No commits in the current review range", vim.log.levels.INFO)
    return
  end

  local mode = state.scope_mode()
  if state.is_gitbutler() then
    local next_idx = mode == "all" and 1 or ((s.current_commit_idx or 0) + 1)
    if next_idx > #s.commits then
      M.select_commit(nil)
    else
      M.select_commit(next_idx, { scope_mode = "current_commit" })
    end
    return
  end

  if mode == "all" then
    M.select_commit(s.current_commit_idx or 1, { scope_mode = "current_commit" })
    return
  end

  if mode == "current_commit" then
    state.set_scope_mode("select_commit")
    M.refresh()
    M.focus_section("scope")
    return
  end

  M.select_commit(nil)
end

function M.refresh_session()
  local review = require("review")
  local s = state.get()
  if not s then
    return
  end
  if s.mode == "local" then
    local function after_refresh(ok, err)
      if ok then
        if state.get_forge_info() then
          review.refresh_comments()
        else
          M.refresh()
        end
      elseif err ~= "superseded" then
        vim.notify("Could not refresh local review", vim.log.levels.WARN)
      end
    end
    if type(review.refresh_local_session_async) == "function" then
      review.refresh_local_session_async(nil, after_refresh)
    else
      after_refresh(review.refresh_local_session(), nil)
    end
    return
  end
  review.refresh_comments()
end

--- Select a file in the explorer and render its diff.
---@param idx number
function M.select_file(idx)
  state.set_file(idx)
  M.refresh()
end

function M.toggle_file_tree()
  local ui_state = state.get_ui()
  if not ui_state then
    return
  end
  ui_state.file_tree_mode = ui_state.file_tree_mode == "flat" and "tree" or "flat"
  state.update_ui_prefs({ file_tree_mode = ui_state.file_tree_mode })
  M.refresh()
end

function M.cycle_file_sort()
  local ui_state = state.get_ui()
  if not ui_state then
    return
  end
  ui_state.file_sort_mode = ui_state.file_sort_mode or FILE_SORT_ORDER[1]
  local next_sort = FILE_SORT_ORDER[1]
  for idx, sort_name in ipairs(FILE_SORT_ORDER) do
    if sort_name == ui_state.file_sort_mode then
      next_sort = FILE_SORT_ORDER[(idx % #FILE_SORT_ORDER) + 1]
      break
    end
  end
  ui_state.file_sort_mode = next_sort
  state.update_ui_prefs({ file_sort_mode = ui_state.file_sort_mode })
  M.refresh()
end

function M.toggle_hide_reviewed_files()
  local ui_state = state.get_ui()
  if not ui_state then
    return
  end
  ui_state.hide_reviewed_files = not ui_state.hide_reviewed_files
  state.update_ui_prefs({ hide_reviewed_files = ui_state.hide_reviewed_files })
  M.refresh()
end

function M.cycle_attention_filter()
  local ui_state = state.get_ui()
  if not ui_state then
    return
  end
  ui_state.file_attention_filter = ui_state.file_attention_filter or FILE_ATTENTION_FILTER_ORDER[1]
  local next_filter = FILE_ATTENTION_FILTER_ORDER[1]
  for idx, filter_name in ipairs(FILE_ATTENTION_FILTER_ORDER) do
    if filter_name == ui_state.file_attention_filter then
      next_filter = FILE_ATTENTION_FILTER_ORDER[(idx % #FILE_ATTENTION_FILTER_ORDER) + 1]
      break
    end
  end
  ui_state.file_attention_filter = next_filter
  state.update_ui_prefs({ file_attention_filter = ui_state.file_attention_filter })
  M.refresh()
end

function M.toggle_file_notes_under_cursor()
  local ui_state = state.get_ui()
  if not ui_state or not files_line_map then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  local entry = files_line_map[cursor[1]]
  if not entry or entry.type ~= "file" or not entry.file_path then
    return
  end
  ui_state.expanded_files = ui_state.expanded_files or {}
  ui_state.expanded_files[entry.file_path] = not ui_state.expanded_files[entry.file_path]
  M.refresh()
end

function M.toggle_dir_under_cursor()
  local ui_state = state.get_ui()
  if not ui_state or not files_line_map then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  local entry = files_line_map[cursor[1]]
  if not entry or entry.type ~= "dir" or not entry.dir_key then
    return
  end
  ui_state.collapsed_dirs = ui_state.collapsed_dirs or {}
  ui_state.collapsed_dirs[entry.dir_key] = not ui_state.collapsed_dirs[entry.dir_key]
  M.refresh()
end

local function restore_files_cursor(ref)
  if not ref or not files_line_map then
    return
  end
  local ui_state = state.get_ui()
  local win = ui_state and (ui_state.files_win or ui_state.explorer_win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  for line_nr, entry in ipairs(files_line_map) do
    local matches = false
    if ref.type == "file" then
      matches = entry.type == "file" and entry.file_path == ref.file_path
    elseif ref.type == "unit" then
      matches = (entry.type == "commit" or entry.type == "scope_all") and entry.unit_id == ref.unit_id
    end
    if matches then
      vim.api.nvim_win_set_cursor(win, { line_nr, 0 })
      return
    end
  end
end

function M.cycle_file_review_status_under_cursor()
  if not files_line_map then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  local entry = files_line_map[cursor[1]]
  if not entry then
    return
  end
  local current
  local apply
  local restore_ref
  if entry.type == "file" and entry.file_path then
    current = state.get_file_review_status(entry.file_path)
    restore_ref = { type = "file", file_path = entry.file_path }
    apply = function(status)
      state.set_file_review_status(entry.file_path, status)
    end
  elseif (entry.type == "commit" or entry.type == "scope_all") and entry.unit_id then
    current = state.get_unit_review_status(entry.unit_id)
    restore_ref = { type = "unit", unit_id = entry.unit_id }
    apply = function(status)
      state.set_unit_review_status(entry.unit_id, status)
    end
  else
    return
  end
  local next_status = NOTE_STATUS_ORDER[1]
  for idx, status in ipairs(NOTE_STATUS_ORDER) do
    if status == current then
      next_status = NOTE_STATUS_ORDER[(idx % #NOTE_STATUS_ORDER) + 1]
      break
    end
  end
  apply(next_status)
  M.refresh()
  restore_files_cursor(restore_ref)
end

function M.search_files_prompt()
  local ui_state = state.get_ui()
  if not ui_state then
    return
  end
  vim.ui.input({ prompt = "Search files: ", default = ui_state.file_search_query or "" }, function(input)
    if input == nil then
      return
    end
    ui_state.file_search_query = vim.trim(input)
    state.update_ui_prefs({ file_search_query = ui_state.file_search_query })
    M.refresh()
  end)
end

function M.clear_file_search()
  local ui_state = state.get_ui()
  if not ui_state then
    return
  end
  ui_state.file_search_query = ""
  ui_state.file_attention_filter = "all"
  state.update_ui_prefs({ file_search_query = "", file_attention_filter = "all" })
  M.refresh()
end

function M.cycle_thread_filter()
  local ui_state = state.get_ui()
  if not ui_state then
    return
  end
  local order = { "all", "open", "resolved", "stale" }
  ui_state.thread_filter = ui_state.thread_filter or "all"
  local next_filter = order[1]
  for idx, value in ipairs(order) do
    if value == ui_state.thread_filter then
      next_filter = order[(idx % #order) + 1]
      break
    end
  end
  ui_state.thread_filter = next_filter
  state.update_ui_prefs({ thread_filter = ui_state.thread_filter })
  M.refresh()
end

function M.toggle_thread_row_under_cursor()
  local ui_state = state.get_ui()
  if not ui_state or not threads_line_map then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  local entry = threads_line_map[cursor[1]]
  if not entry then
    return
  end
  if entry.type == "filter" then
    M.cycle_thread_filter()
    return
  end
  if entry.type == "thread_group" then
    local key = entry.section .. "::" .. entry.group
    ui_state.collapsed_thread_groups = ui_state.collapsed_thread_groups or {}
    ui_state.collapsed_thread_groups[key] = not ui_state.collapsed_thread_groups[key]
    M.refresh()
    return
  end
  if entry.type == "thread_file" and entry.expanded_key then
    ui_state.expanded_thread_files = ui_state.expanded_thread_files or {}
    ui_state.expanded_thread_files[entry.expanded_key] = not ui_state.expanded_thread_files[entry.expanded_key]
    M.refresh()
  end
end

---@param buf number
---@return table[]|nil
local function line_map_for_buffer(buf)
  local ui_state = state.get_ui()
  if not ui_state then
    return nil
  end
  if buf == ui_state.files_buf or buf == ui_state.explorer_buf then
    return files_line_map
  end
  if buf == ui_state.threads_buf then
    return threads_line_map
  end
  return nil
end

--- Set up keymaps for a navigation buffer.
---@param buf number
local function setup_nav_keymaps(buf)
  local opts = { buffer = buf, noremap = true, silent = true }

  vim.keymap.set("n", "<CR>", function()
    local line_map = line_map_for_buffer(buf)
    if not line_map then
      return
    end
    local cursor = vim.api.nvim_win_get_cursor(0)
    local entry = line_map[cursor[1]]
    if not entry then
      return
    end

    if entry.type == "scope_all" then
      M.select_commit(nil)
    elseif entry.type == "commit" then
      M.select_commit(entry.idx, { scope_mode = "current_commit" })
    elseif entry.type == "file" then
      M.select_file(entry.idx)
      local ui_state = state.get_ui()
      if ui_state and vim.api.nvim_win_is_valid(ui_state.diff_win) then
        vim.api.nvim_set_current_win(ui_state.diff_win)
      end
    elseif entry.type == "dir" then
      M.toggle_dir_under_cursor()
    elseif entry.type == "filter" or entry.type == "thread_group" then
      M.toggle_thread_row_under_cursor()
    elseif entry.type == "thread_file" then
      jump_to_file_location(entry.file_path, entry.line, entry.side)
    elseif entry.type == "thread_note" then
      local note = entry.note_id and state.get_note_by_id(entry.note_id) or entry.note
      if note and note.status == "remote" and note.replies and #note.replies > 0 then
        M.open_thread_view(note)
      elseif note then
        jump_to_file_location(entry.file_path, entry.line, entry.side)
      end
    elseif entry.type == "stale" then
      local note = entry.note_id and state.get_note_by_id(entry.note_id) or entry.note
      if note and note.status == "remote" and note.replies and #note.replies > 0 then
        M.open_thread_view(note)
      else
        M.open_notes_list()
      end
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

  vim.keymap.set("n", "u", function()
    local line_map = line_map_for_buffer(buf)
    local cursor = vim.api.nvim_win_get_cursor(0)
    local entry = line_map and line_map[cursor[1]]
    M.copy_unit_notes_for_scope_entry(entry)
  end, opts)

  if km.toggle_stack and km.toggle_stack ~= km.focus_threads and km.toggle_stack ~= km.focus_diff then
    vim.keymap.set("n", km.toggle_stack, function()
      M.toggle_stack_view()
    end, opts)
  end

  if km.commit_details then
    vim.keymap.set("n", km.commit_details, function()
      local line_map = line_map_for_buffer(buf)
      local cursor = vim.api.nvim_win_get_cursor(0)
      local entry = line_map and line_map[cursor[1]]
      if entry and entry.type == "commit" then
        M.open_commit_details(entry.idx)
      else
        M.open_commit_details()
      end
    end, opts)
  end

  if km.refresh then
    vim.keymap.set("n", km.refresh, function()
      M.refresh_session()
    end, opts)
  end

  vim.keymap.set("n", km.focus_files, function()
    M.focus_section("files")
  end, opts)

  if km.focus_diff then
    vim.keymap.set("n", km.focus_diff, function()
      M.focus_diff()
    end, opts)
  end

  if km.focus_git then
    vim.keymap.set("n", km.focus_git, function()
      M.focus_git()
    end, opts)
  end

  if km.focus_threads then
    vim.keymap.set("n", km.focus_threads, function()
      M.focus_section("threads")
    end, opts)
  end

  if km.toggle_file_tree and km.toggle_file_tree ~= km.focus_threads and km.toggle_file_tree ~= km.focus_diff then
    vim.keymap.set("n", km.toggle_file_tree, function()
      M.toggle_file_tree()
    end, opts)
  end

  if km.sort_files then
    vim.keymap.set("n", km.sort_files, function()
      M.cycle_file_sort()
    end, opts)
  end

  if km.toggle_reviewed then
    vim.keymap.set("n", km.toggle_reviewed, function()
      M.toggle_hide_reviewed_files()
    end, opts)
  end

  if km.filter_attention then
    vim.keymap.set("n", km.filter_attention, function()
      M.cycle_attention_filter()
    end, opts)
  end

  vim.keymap.set("n", "/", function()
    M.search_files_prompt()
  end, opts)

  vim.keymap.set("n", "c", function()
    M.clear_file_search()
  end, opts)

  if km.change_base then
    vim.keymap.set("n", km.change_base, function()
      require("review").change_base()
    end, opts)
  end

  if km.mark_baseline then
    vim.keymap.set("n", km.mark_baseline, function()
      require("review").mark_baseline()
    end, opts)
  end

  if km.compare_baseline then
    vim.keymap.set("n", km.compare_baseline, function()
      require("review").compare_baseline()
    end, opts)
  end

  if km.compare_unit then
    vim.keymap.set("n", km.compare_unit, function()
      local line_map = line_map_for_buffer(buf)
      local cursor = vim.api.nvim_win_get_cursor(0)
      local entry = line_map and line_map[cursor[1]]
      if entry and entry.type == "commit" then
        M.open_unit_compare(entry.idx)
      else
        M.open_unit_compare()
      end
    end, opts)
  end

  vim.keymap.set("n", "za", function()
    if buf == (state.get_ui() and state.get_ui().threads_buf) then
      M.toggle_thread_row_under_cursor()
    else
      local line_map = line_map_for_buffer(buf)
      local cursor = vim.api.nvim_win_get_cursor(0)
      local entry = line_map and line_map[cursor[1]]
      if entry and entry.type == "dir" then
        M.toggle_dir_under_cursor()
      else
        M.toggle_file_notes_under_cursor()
      end
    end
  end, opts)

  vim.keymap.set("n", "<LeftMouse>", function()
    local pos = vim.fn.getmousepos()
    if not pos or pos.winid == 0 or pos.line <= 0 then
      return
    end
    pcall(vim.api.nvim_set_current_win, pos.winid)
    pcall(vim.api.nvim_win_set_cursor, pos.winid, { pos.line, math.max(pos.column - 1, 0) })
    local line_map = line_map_for_buffer(buf)
    local entry = line_map and line_map[pos.line]
    if entry and entry.type == "dir" then
      M.toggle_dir_under_cursor()
    end
  end, opts)

  vim.keymap.set("n", "r", function()
    M.cycle_file_review_status_under_cursor()
  end, opts)

  vim.keymap.set("n", "<C-w>>", function()
    resize_diff_area(5)
  end, opts)

  vim.keymap.set("n", "<C-w><", function()
    resize_diff_area(-5)
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
  local file = current_display_file()
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
    local file = current_display_file()
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
    local file = current_display_file()
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

  if km.next_note_short then
    vim.keymap.set("n", km.next_note_short, function()
      M.jump_to_note(1)
    end, opts)
  end

  vim.keymap.set("n", km.prev_note, function()
    M.jump_to_note(-1)
  end, opts)

  vim.keymap.set("n", km.toggle_split, function()
    M.toggle_split()
  end, opts)

  if km.blame then
    vim.keymap.set("n", km.blame, function()
      M.toggle_blame_panel()
    end, opts)
  end

  if km.file_history then
    vim.keymap.set("n", km.file_history, function()
      M.open_file_history()
    end, opts)
  end

  if km.toggle_stack and km.toggle_stack ~= km.focus_threads and km.toggle_stack ~= km.focus_diff then
    vim.keymap.set("n", km.toggle_stack, function()
      M.toggle_stack_view()
    end, opts)
  end

  if km.refresh then
    vim.keymap.set("n", km.refresh, function()
      M.refresh_session()
    end, opts)
  end

  if km.change_base then
    vim.keymap.set("n", km.change_base, function()
      require("review").change_base()
    end, opts)
  end

  vim.keymap.set("n", "/", function()
    M.search_files_prompt()
  end, opts)

  vim.keymap.set("n", "c", function()
    M.clear_file_search()
  end, opts)

  if km.filter_attention then
    vim.keymap.set("n", km.filter_attention, function()
      M.cycle_attention_filter()
    end, opts)
  end

  if km.mark_baseline then
    vim.keymap.set("n", km.mark_baseline, function()
      require("review").mark_baseline()
    end, opts)
  end

  if km.compare_baseline then
    vim.keymap.set("n", km.compare_baseline, function()
      require("review").compare_baseline()
    end, opts)
  end

  if km.compare_unit then
    vim.keymap.set("n", km.compare_unit, function()
      M.open_unit_compare()
    end, opts)
  end

  vim.keymap.set("n", km.focus_files, function()
    M.focus_section("files")
  end, opts)

  if km.focus_diff then
    vim.keymap.set("n", km.focus_diff, function()
      M.focus_diff()
    end, opts)
  end

  if km.focus_git then
    vim.keymap.set("n", km.focus_git, function()
      M.focus_git()
    end, opts)
  end

  if km.focus_threads then
    vim.keymap.set("n", km.focus_threads, function()
      M.focus_section("threads")
    end, opts)
  end

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
    local file = current_display_file()
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
    choose_note_at(file.path, target_line, side, function(note)
      if note.status == "remote" and note.replies and #note.replies > 0 then
        clear_inline_preview()
        M.open_thread_view(note)
      elseif note.status ~= "remote" then
        M.edit_note_at_cursor()
      end
    end)
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
  pcall(vim.cmd, "file " .. vim.fn.fnameescape(tab_name))
  local tab = vim.api.nvim_get_current_tabpage()
  state.bind(tab, s)

  local files_buf = create_buf("review://files", { filetype = "review-explorer" })
  local threads_buf = create_buf("review://threads", { filetype = "review-explorer" })
  local diff_buf = create_buf("review://diff", { filetype = "review-diff" })

  vim.api.nvim_set_current_buf(files_buf)
  vim.cmd("vsplit")
  local wins = vim.api.nvim_tabpage_list_wins(tab)
  table.sort(wins, function(a, b)
    local apos = vim.api.nvim_win_get_position(a)
    local bpos = vim.api.nvim_win_get_position(b)
    return apos[2] < bpos[2]
  end)

  local files_win = wins[1]
  local diff_win = wins[2]

  vim.api.nvim_win_set_buf(files_win, files_buf)
  vim.api.nvim_win_set_buf(diff_win, diff_buf)
  vim.api.nvim_set_current_win(files_win)
  vim.cmd("belowright split")

  local wins = vim.api.nvim_tabpage_list_wins(tab)
  table.sort(wins, function(a, b)
    local apos = vim.api.nvim_win_get_position(a)
    local bpos = vim.api.nvim_win_get_position(b)
    if apos[2] == bpos[2] then
      return apos[1] < bpos[1]
    end
    return apos[2] < bpos[2]
  end)

  local threads_win = wins[2]

  vim.api.nvim_win_set_buf(threads_win, threads_buf)
  vim.api.nvim_set_current_win(files_win)
  vim.cmd("vertical resize " .. tostring(navigator_width()))

  for _, win in ipairs({ files_win, threads_win, diff_win }) do
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].wrap = false
    apply_review_window_style(win, "pane")
  end
  vim.wo[files_win].signcolumn = "no"
  vim.wo[threads_win].signcolumn = "no"
  vim.wo[diff_win].signcolumn = "yes"
  vim.wo[files_win].winfixwidth = false
  vim.wo[threads_win].winfixwidth = false
  vim.wo[files_win].winfixheight = true
  vim.wo[threads_win].winfixheight = true
  vim.wo[files_win].scrolloff = 0
  vim.wo[threads_win].scrolloff = 0
  vim.wo[files_win].sidescrolloff = 0
  vim.wo[threads_win].sidescrolloff = 0
  vim.wo[diff_win].cursorline = true
  vim.wo[diff_win].cursorlineopt = "line"
  vim.wo[files_win].cursorline = true
  vim.wo[files_win].cursorlineopt = "line"
  vim.api.nvim_set_option_value("statusline", " ", { scope = "local", win = files_win })
  vim.wo[threads_win].cursorline = true
  vim.wo[threads_win].cursorlineopt = "line"
  vim.api.nvim_set_option_value("statusline", " ", { scope = "local", win = threads_win })

  local previous_laststatus = vim.o.laststatus
  vim.o.laststatus = 3
  local ui_prefs = state.get_ui_prefs()

  state.set_ui({
    files_buf = files_buf,
    files_win = files_win,
    threads_buf = threads_buf,
    threads_win = threads_win,
    explorer_buf = files_buf,
    explorer_win = files_win,
    diff_buf = diff_buf,
    diff_win = diff_win,
    tab = tab,
    explorer_width = vim.api.nvim_win_get_width(files_win),
    view_mode = config.view or "unified",
    file_tree_mode = ui_prefs.file_tree_mode or "tree",
    file_sort_mode = ui_prefs.file_sort_mode or "path",
    file_attention_filter = ui_prefs.file_attention_filter or "all",
    hide_reviewed_files = ui_prefs.hide_reviewed_files == true,
    file_search_query = ui_prefs.file_search_query or "",
    thread_filter = ui_prefs.thread_filter or "all",
    expanded_files = {},
    collapsed_dirs = {},
    previous_laststatus = previous_laststatus,
  })
  rebalance_left_rail(state.get_ui())

  setup_nav_keymaps(files_buf)
  setup_nav_keymaps(threads_buf)
  setup_diff_keymaps(diff_buf)
  attach_review_quit_guard(files_buf)
  attach_review_quit_guard(threads_buf)
  attach_review_quit_guard(diff_buf)

  render_files_pane(files_buf)
  render_threads_pane(threads_buf)
  render_diff(diff_buf)
  update_window_chrome()
  clamp_left_rail_scroll()

  local selection_line = navigator_selection_line()
  if selection_line and vim.api.nvim_win_is_valid(files_win) then
    vim.api.nvim_win_set_cursor(files_win, { selection_line, 0 })
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

  vim.api.nvim_create_autocmd("VimResized", {
    group = vim.api.nvim_create_augroup("review_resize_" .. tostring(tab), { clear = true }),
    callback = function()
      local ui_state = state.get_ui()
      if not ui_state or ui_state.tab ~= tab then
        return
      end
      vim.schedule(function()
        resize_left_rail_to_screen()
      end)
    end,
  })

  vim.api.nvim_create_autocmd("WinScrolled", {
    group = vim.api.nvim_create_augroup("review_scroll_limit_" .. tostring(tab), { clear = true }),
    callback = function()
      local ui_state = state.get_ui()
      if not ui_state or ui_state.tab ~= tab then
        return
      end
      vim.schedule(clamp_left_rail_scroll)
    end,
  })
end

--- Close the review layout.
function M.close()
  if review_closing then
    return
  end
  review_closing = true

  local ok, err = pcall(function()
    clear_inline_preview()

    local ui = state.get_ui()
    if ui and ui.tab then
      local tabs = vim.api.nvim_list_tabpages()
      if #tabs <= 1 then
        for _, buf in ipairs({ ui.files_buf, ui.threads_buf, ui.explorer_buf, ui.diff_buf, ui.split_buf, ui.blame_buf }) do
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
    if ui and ui.previous_laststatus ~= nil then
      vim.o.laststatus = ui.previous_laststatus
    end
    state.destroy()
  end)

  review_closing = false
  if not ok then
    error(err)
  end
end

---@param target table
---@param opts table|nil
function M.open_note_float_for_target(target, opts)
  opts = opts or {}
  if not target then
    vim.notify("Cannot add note without a target", vim.log.levels.WARN)
    return
  end

  if opts.suggestion and not (target.file_path and target.line) then
    vim.notify("Cannot add a suggestion without a file and line", vim.log.levels.WARN)
    return
  end

  if target.file_path then
    local target_file = nil
    local files = target.line and state.active_files() or state.all_files()
    for _, file in ipairs(files) do
      if file.path == target.file_path then
        target_file = file
        break
      end
    end
    if not target_file then
      local scope = target.line and "current review file set" or "review file set"
      vim.notify("Cannot add note outside the " .. scope, vim.log.levels.WARN)
      return
    end
  end

  local s = state.get()
  if s and s.mode == "pr" and (not target.file_path or not target.line) then
    vim.notify("PR publishing requires a file and line target", vim.log.levels.WARN)
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
        local context = consume_note_context()
        context.is_general = target.is_general or target.target_kind == "discussion" or false
        context.target_kind = target.target_kind
          or (context.is_general and "discussion")
          or (file_path and target_line and "line")
          or (file_path and "file")
          or "unit"
        state.add_note(file_path, target_line, body, end_line, side, note_type, context)
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
  local file = current_display_file()
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

---@param file_path string
---@param line number
---@param side string
---@param action fun(note: ReviewNote, idx: number)
---@return boolean
choose_note_at = function(file_path, line, side, action)
  local entries = state.find_notes_at(file_path, line, side)
  if #entries == 0 then
    return false
  end
  if #entries == 1 then
    action(entries[1].note, entries[1].idx)
    return true
  end
  local items = {}
  for _, entry in ipairs(entries) do
    local note = entry.note
    local first = (note.body or ""):match("^([^\n]*)") or ""
    table.insert(items, {
      label = string.format("#%s %s %s", tostring(note.id or "?"), note.status or "draft", first),
      entry = entry,
    })
  end
  vim.ui.select(items, {
    prompt = string.format("Choose note at %s:%d:%s", file_path, line, side),
    format_item = function(item)
      return item.label
    end,
  }, function(item)
    if item then
      action(item.entry.note, item.entry.idx)
    end
  end)
  return true
end

--- Edit the note at the current cursor position.
function M.edit_note_at_cursor()
  local file = current_display_file()
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

  local handled = choose_note_at(file.path, target_line, side, function(note, note_idx)
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
  end)
  if not handled then
    vim.notify("No note on this line", vim.log.levels.INFO)
  end
end

--- Delete the note at the current cursor position.
function M.delete_note_at_cursor()
  local file = current_display_file()
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

  local handled = choose_note_at(file.path, target_line, side, function(note, note_idx)
    if note.status == "remote" then
      vim.notify("Cannot delete remote comments", vim.log.levels.WARN)
      return
    end

    state.remove_note(note_idx)
    vim.notify("Note #" .. tostring(note.id) .. " deleted", vim.log.levels.INFO)
    M.refresh()
  end)
  if not handled then
    vim.notify("No note on this line", vim.log.levels.INFO)
  end
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
  if note.id then
    location = "#" .. tostring(note.id) .. " " .. location
  end
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

local function close_notes_list_window(win)
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
  if notes_list_win == win then
    notes_list_win = nil
  end
end

function M.refresh_notes_list()
  if not notes_list_win or not vim.api.nvim_win_is_valid(notes_list_win) then
    notes_list_win = nil
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(notes_list_win)
  close_notes_list_window(notes_list_win)
  M.open_notes_list({ cursor_line = cursor[1] })
end

---@param win number
---@param opts table|nil
local function reopen_notes_list(win, opts)
  close_notes_list_window(win)
  M.open_notes_list(opts)
end

---@param note_id number
function M.copy_unit_notes_for_note(note_id)
  local s = state.get()
  if not s then
    return
  end
  local note_obj = state.get_note_by_id(note_id)
  if not note_obj then
    return
  end
  local unit = note_unit_label(s, note_obj)
  copy_review_export({ unit = unit }, "Unit notes copied to clipboard register(s): ")
end

---@param entry table|nil
function M.copy_unit_notes_for_scope_entry(entry)
  local s = state.get()
  if not s then
    return
  end

  if entry and entry.type == "scope_all" then
    copy_review_export({ clipboard = true }, "Notes copied to clipboard register(s): ")
    return
  end

  local commit = entry and (entry.commit or (entry.idx and s.commits and s.commits[entry.idx]))
  local unit = commit_unit_label(s, commit)
  if not unit then
    vim.notify("Place the cursor on a review unit row to copy its handoff packet", vim.log.levels.INFO)
    return
  end

  copy_review_export({ unit = unit }, "Unit notes copied to clipboard register(s): ")
end

local function publish_gitbutler_notes(staged_notes, list_win)
  local gitbutler = require("review.gitbutler")
  local groups = {}
  local order = {}
  local blocked = {}

  local function note_id_list(notes)
    local ids = {}
    for _, note in ipairs(notes or {}) do
      table.insert(ids, "#" .. tostring(note.id or "?"))
    end
    return table.concat(ids, ", ")
  end

  for _, note in ipairs(staged_notes) do
    local info, err = gitbutler.resolve_review_target(note.gitbutler)
    if info then
      local key = string.format("%s:%s/%s#%s", info.forge, info.owner, info.repo, tostring(info.pr_number))
      if not groups[key] then
        groups[key] = { info = info, notes = {} }
        table.insert(order, key)
      end
      table.insert(groups[key].notes, note)
    else
      table.insert(blocked, string.format("#%d: %s", note.id, err or "no remote review target"))
    end
  end

  local url_map = {}
  local errors = {}
  for _, key in ipairs(order) do
    local group = groups[key]
    vim.notify(
      string.format("Publishing %d note(s) to %s PR #%d...", #group.notes, group.info.forge, group.info.pr_number),
      vim.log.levels.INFO
    )
    local ctx, ctx_err = forge.resolve_context(group.info)
    if not ctx then
      table.insert(
        errors,
        string.format(
          "%s PR #%d (%s): %s",
          group.info.forge,
          group.info.pr_number,
          note_id_list(group.notes),
          ctx_err or "unknown"
        )
      )
    else
      for _, note in ipairs(group.notes) do
        local url, err = forge.post_comment(group.info, note, ctx)
        if url then
          url_map[note.id] = url
        elseif err then
          table.insert(errors, string.format("#%d: %s", note.id, err))
        end
      end
    end
  end

  local count = state.publish_staged(url_map)
  local messages = {}
  if count > 0 then
    table.insert(messages, count .. " note(s) published")
  end
  for _, msg in ipairs(blocked) do
    table.insert(messages, msg)
  end
  for _, msg in ipairs(errors) do
    table.insert(messages, msg)
  end

  if #messages == 0 then
    vim.notify("No GitButler notes were published", vim.log.levels.INFO)
  elseif #blocked > 0 or #errors > 0 then
    vim.notify(table.concat(messages, "\n"), vim.log.levels.WARN)
  else
    vim.notify(table.concat(messages, "\n"), vim.log.levels.INFO)
  end

  reopen_notes_list(list_win)
  M.refresh()
end

--- Open a floating window listing all notes across all files.
--- Pressing <CR> on a note jumps to that file and line.
---@param opts table|nil
function M.open_notes_list(opts)
  opts = opts or {}
  if not state.session_matches_git() then
    require("review").reopen_session()
    return
  end
  local s = state.get()
  if not s then
    return
  end

  local scoped_notes, stale_notes = state.scoped_notes()
  if #scoped_notes == 0 and #stale_notes == 0 then
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
  local ui_prefs = state.get_ui_prefs()
  local query = opts.query
  if query == nil then
    query = ui_prefs.notes_query or ""
  end
  query = tostring(query or "")
  local status_filter = opts.status_filter or ui_prefs.notes_status_filter or "all"

  local function note_search_text(note)
    local parts = {
      tostring(note.id or ""),
      note.file_path or "",
      tostring(note.line or ""),
      note.side or "",
      note.status or "",
      note.body or "",
      note.author or "",
    }
    if note.replies then
      for _, reply in ipairs(note.replies) do
        table.insert(parts, reply.body or "")
        table.insert(parts, reply.author or "")
      end
    end
    return table.concat(parts, " "):lower()
  end

  local normalized_query = vim.trim(query):lower()

  local function include_entry(entry, bucket)
    if status_filter == "local" and bucket ~= "local" then
      return false
    end
    if status_filter == "open" and bucket ~= "open" then
      return false
    end
    if status_filter == "discussion" and bucket ~= "discussion" then
      return false
    end
    if status_filter == "resolved" and bucket ~= "resolved" then
      return false
    end
    if status_filter == "stale" and bucket ~= "stale" then
      return false
    end
    if normalized_query ~= "" and not note_search_text(entry.note):find(normalized_query, 1, true) then
      return false
    end
    return true
  end

  local function maybe_insert(list, entry, bucket)
    if include_entry(entry, bucket) then
      table.insert(list, entry)
    end
  end

  for i, note in ipairs(scoped_notes) do
    local entry = { idx = i, note = note }
    if note.is_general then
      maybe_insert(discussion_notes, entry, "discussion")
    elseif note.status ~= "remote" and note.resolved then
      maybe_insert(resolved_notes, entry, "resolved")
    elseif note.status == "draft" or note.status == "staged" then
      maybe_insert(local_notes, entry, "local")
    elseif note.status == "remote" and note.resolved then
      maybe_insert(resolved_notes, entry, "resolved")
    elseif note.status == "remote" then
      maybe_insert(open_notes, entry, "open")
    end
  end
  local stale_entries = {}
  for i, note in ipairs(stale_notes) do
    maybe_insert(stale_entries, { idx = i + #scoped_notes, note = note }, "stale")
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
  sort_by_file_order(stale_entries)

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
    local id_label = note.id and ("#" .. tostring(note.id)) or "#?"

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
    if note.resolved then
      table.insert(meta_parts, "fixed")
    elseif note.file_path and files_by_path[note.file_path] then
      local snapshot_state = state.review_snapshot_file_state(files_by_path[note.file_path])
      if snapshot_state == "new" then
        table.insert(meta_parts, "new since baseline")
      elseif snapshot_state == "changed" then
        table.insert(meta_parts, "changed since baseline")
      elseif snapshot_state == "unchanged" then
        table.insert(meta_parts, "unchanged since baseline")
      end
    end
    if note_is_gitbutler_unpublished(note) then
      table.insert(meta_parts, "unpublished")
    end
    local meta = table.concat(meta_parts, "  ")
    local meta_dw = #meta > 0 and (dw(meta) + 2) or 0

    local body = (note.body or ""):match("^([^\n]*)") or ""
    local min_body_width = body ~= "" and 12 or 0
    local max_lref_width =
      math.max(math.min(math.floor(width * 0.42), width - meta_dw - min_body_width - #id_label - 8), 8)
    lref = truncate_middle_text(lref, max_lref_width)

    local left = "  " .. icon .. " " .. id_label .. " " .. lref
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
    table.insert(extra_hls, { #lines, HL.note_ref, 4, 4 + #id_label })
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

  local active_filter_parts = {}
  if status_filter ~= "all" then
    table.insert(active_filter_parts, "status=" .. status_filter)
  end
  if normalized_query ~= "" then
    table.insert(active_filter_parts, "search=" .. query)
  end
  if #active_filter_parts > 0 then
    local filter_line = " Filters: " .. table.concat(active_filter_parts, "  ")
    table.insert(lines, truncate_end_text(filter_line, width))
    highlight_rows[#lines] = { hl = HL.meta }
    note_refs[#lines] = false
    table.insert(lines, "")
    note_refs[#lines] = false
  end

  render_section(local_notes, "Your Notes", HL.note_draft, false)
  render_section(open_notes, "Open Threads", HL.note_remote, true)
  render_section(discussion_notes, "Discussion", HL.note_author, true)
  render_section(resolved_notes, "Resolved", HL.note_remote_resolved, true)
  render_section(stale_entries, "Stale", HL.note_separator, true)

  if #local_notes + #open_notes + #discussion_notes + #resolved_notes + #stale_entries == 0 then
    table.insert(lines, " No notes match filters")
    highlight_rows[#lines] = { hl = HL.meta }
    note_refs[#lines] = false
  end

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
      "u unit",
      "Y local",
      "x resolve",
      "a attach",
      "R refresh",
      "/ search",
      "f filter",
      "c clear filters",
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
  if status_filter ~= "all" then
    table.insert(title_parts, status_filter)
    table.insert(compact_title_parts, status_filter:sub(1, 1))
  end
  if normalized_query ~= "" then
    table.insert(title_parts, "search")
    table.insert(compact_title_parts, "/")
  end
  local title_variants = { title_parts, compact_title_parts, {} }
  if state.comments_loading() or state.local_refresh_loading() then
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
  notes_list_win = list_win

  vim.wo[list_win].cursorline = true
  local initial_cursor = math.min(math.max(opts.cursor_line or 1, 1), #lines)
  vim.api.nvim_win_set_cursor(list_win, { initial_cursor, 0 })

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
    close_notes_list_window(list_win)
  end, buf_opts)
  vim.keymap.set("n", "<Esc>", function()
    close_notes_list_window(list_win)
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
    reopen_notes_list(list_win)
    M.refresh()
  end, buf_opts)

  vim.keymap.set("n", "P", function()
    local staged_notes = {}
    for _, note in ipairs(state.get_notes()) do
      if note.status == "staged" then
        table.insert(staged_notes, note)
      end
    end

    if #staged_notes == 0 then
      vim.notify("No staged notes to publish", vim.log.levels.INFO)
      return
    end

    if state.is_gitbutler() then
      publish_gitbutler_notes(staged_notes, list_win)
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
      reopen_notes_list(list_win)
      M.refresh()
      return
    end

    vim.notify(
      string.format("Publishing %d note(s) to %s PR #%d...", #staged_notes, info.forge, info.pr_number),
      vim.log.levels.INFO
    )

    local ctx, ctx_err = forge.resolve_context(info)
    if not ctx then
      local ids = {}
      for _, note in ipairs(staged_notes) do
        table.insert(ids, "#" .. tostring(note.id or "?"))
      end
      vim.notify(
        string.format("Failed to resolve context for %s: %s", table.concat(ids, ", "), ctx_err or "unknown"),
        vim.log.levels.ERROR
      )
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

    reopen_notes_list(list_win)
    M.refresh()
    require("review").refresh_comments()
  end, buf_opts)

  vim.keymap.set("n", "x", function()
    local cursor = vim.api.nvim_win_get_cursor(list_win)
    local ref = note_refs[cursor[1]]
    if not ref or ref == false or not ref.note_id then
      return
    end
    if ref.status == "remote" then
      vim.notify("Open the thread view to resolve or reopen remote threads", vim.log.levels.INFO)
      return
    end
    state.toggle_resolved(ref.note_id)
    reopen_notes_list(list_win)
    M.refresh()
  end, buf_opts)

  vim.keymap.set("n", "a", function()
    local context = pending_note_context()
    if not context then
      vim.notify("No queued blame/history context to attach", vim.log.levels.INFO)
      return
    end
    local cursor = vim.api.nvim_win_get_cursor(list_win)
    local ref = note_refs[cursor[1]]
    if not ref or ref == false or not ref.note_id then
      return
    end
    if ref.status == "remote" then
      vim.notify("Cannot attach local context to remote comments", vim.log.levels.WARN)
      return
    end
    if state.attach_context_to_note(ref.note_id, context) then
      consume_note_context()
      vim.notify("Context attached to note #" .. tostring(ref.note_id), vim.log.levels.INFO)
      reopen_notes_list(list_win)
      M.refresh()
    end
  end, buf_opts)

  vim.keymap.set("n", "y", function()
    copy_review_export({ clipboard = true }, "Notes copied to clipboard register(s): ")
  end, buf_opts)

  vim.keymap.set("n", "u", function()
    local cursor = vim.api.nvim_win_get_cursor(list_win)
    local ref = note_refs[cursor[1]]
    if not ref or ref == false or not ref.note_id then
      return
    end
    M.copy_unit_notes_for_note(ref.note_id)
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
      close_notes_list_window(list_win)
      M.refresh()
      if #state.get_notes() > 0 then
        M.open_notes_list()
      end
    end
  end, buf_opts)

  vim.keymap.set("n", "R", function()
    vim.notify("Refreshing PR comments...", vim.log.levels.INFO)
    require("review").refresh_comments({ preserve_notes_list = true })
  end, buf_opts)

  vim.keymap.set("n", "/", function()
    vim.ui.input({ prompt = "Search notes: ", default = query }, function(input)
      if input == nil then
        return
      end
      state.update_ui_prefs({ notes_query = vim.trim(input) })
      reopen_notes_list(list_win)
    end)
  end, buf_opts)

  vim.keymap.set("n", "f", function()
    local order = { "all", "local", "open", "discussion", "resolved", "stale" }
    local next_filter = order[1]
    for idx, value in ipairs(order) do
      if value == status_filter then
        next_filter = order[(idx % #order) + 1]
        break
      end
    end
    state.update_ui_prefs({ notes_status_filter = next_filter })
    reopen_notes_list(list_win)
  end, buf_opts)

  vim.keymap.set("n", "c", function()
    state.update_ui_prefs({ notes_query = "", notes_status_filter = "all" })
    reopen_notes_list(list_win)
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
        close_notes_list_window(list_win)
        M.open_thread_view(note_obj)
      end
      return
    end

    local target_path = ref.file_path
    local target_line = ref.line
    local target_side = ref.side
    local is_remote = ref.status == "remote"
    local remote_note_id = is_remote and ref.note_id or nil

    close_notes_list_window(list_win)

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
    reopen_notes_list(list_win)
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
  vim.keymap.set("n", "n", function()
    jump_in_list(1)
  end, buf_opts)
  vim.keymap.set("n", "j", function()
    jump_in_list(1)
  end, buf_opts)
  vim.keymap.set("n", "k", function()
    jump_in_list(-1)
  end, buf_opts)
end

function M.open_help()
  require("review.ui.help").open()
end

--- Refresh both panels (call after state changes).
function M.refresh()
  if not state.session_matches_vcs() then
    require("review").reopen_session()
    return
  end
  sync_local_review_state()
  clear_inline_preview()
  local ui_state = state.get_ui()
  if not ui_state then
    return
  end
  if ui_state.files_buf and vim.api.nvim_buf_is_valid(ui_state.files_buf) then
    render_files_pane(ui_state.files_buf)
    local selection_line = navigator_selection_line()
    local files_win = ui_state.files_win or ui_state.explorer_win
    if selection_line and files_win and vim.api.nvim_win_is_valid(files_win) then
      vim.api.nvim_win_set_cursor(files_win, { selection_line, 0 })
    end
  end
  if ui_state.threads_buf and vim.api.nvim_buf_is_valid(ui_state.threads_buf) then
    render_threads_pane(ui_state.threads_buf)
  end
  if ui_state.view_mode == "split" and ui_state.split_buf then
    render_split(ui_state)
  elseif ui_state.diff_buf and vim.api.nvim_buf_is_valid(ui_state.diff_buf) then
    render_diff(ui_state.diff_buf)
  end
  update_window_chrome()
  clamp_left_rail_scroll()
end

return M
