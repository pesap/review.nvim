--- review.nvim — Minimal code review plugin for Neovim.
--- Entry point: setup(), config, command dispatch.
local M = {}

---@class ReviewConfig
local defaults = {
  view = "unified",
  render = {
    word_diff = {
      enabled = true,
      max_line_length = 300,
      max_pairs_per_hunk = 64,
      max_hunk_lines = 200,
      max_file_lines = 1500,
    },
  },
  notifications = {
    context = false,
  },
  colorblind = true,
  provider = nil, ---@type string|nil  "github"|"gitlab"|nil (nil = auto-detect from remote URL)
  keymaps = {
    add_note = "a",
    edit_note = "e",
    delete_note = "d",
    help = "?",
    next_hunk = "]c",
    prev_hunk = "[c",
    next_file = "]f",
    prev_file = "[f",
    next_note = "]n",
    prev_note = "[n",
    toggle_split = "s",
    toggle_stack = "T",
    focus_files = "f",
    focus_threads = "t",
    notes_list = "N",
    suggestion = "S",
    close = "q",
  },
}

---@type ReviewConfig
M.config = vim.deepcopy(defaults)

--- Plugin setup.
---@param opts ReviewConfig|nil
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", defaults, opts or {})
end

---@param msg string
---@param level integer
---@param enabled boolean|nil
local function notify(msg, level, enabled)
  if enabled == false then
    return
  end
  vim.notify(msg, level)
end

---@param base_ref string|nil
local function hydrate_cached_remote_bundle(base_ref)
  local state = require("review.state")
  local storage = require("review.storage")
  local ui = require("review.ui")

  local bundle = storage.load_remote_bundle(base_ref)
  if not bundle or not bundle.info then
    return false
  end

  state.set_forge_info(bundle.info)
  state.clear_remote_comments()
  if bundle.comments and #bundle.comments > 0 then
    state.load_remote_comments(bundle.comments)
  end

  if state.get_ui() then
    ui.refresh()
  end
  return true
end

---@param ref string|nil
---@param opts table|nil
---@return boolean
function M._open_with_ref(ref, opts)
  opts = opts or {}

  local git = require("review.git")
  local diff_mod = require("review.diff")
  local state = require("review.state")
  local ui = require("review.ui")
  local diff_text = git.diff(ref)
  if diff_text == "" then
    vim.notify("No changes to review" .. (ref and (" against " .. ref) or ""), vim.log.levels.INFO)
    return false
  end

  local files = diff_mod.parse(diff_text)
  if #files == 0 then
    vim.notify("No files changed", vim.log.levels.INFO)
    return false
  end

  state.create("local", ref or "HEAD", files)

  if ref then
    local commits = git.log(ref)
    if #commits > 0 then
      state.set_commits(commits)
    end
  end

  if opts.open_ui ~= false then
    ui.open()
  end

  return true
end

--- Open a review session.
--- Usage:
---   :Review          — auto-detect: if on a branch with an open PR, review against default branch; otherwise diff against HEAD
---   :Review HEAD~3   — local diff against HEAD~3
---@param args string[]
function M.open(args)
  args = args or {}

  local git = require("review.git")
  local state = require("review.state")
  local ui = require("review.ui")

  -- Close any existing session
  if state.get() then
    ui.close()
  end

  -- Check we're in a git repo
  if not git.root() then
    vim.notify("Not in a git repository", vim.log.levels.ERROR)
    return
  end

  local forge = require("review.forge")

  if #args > 0 then
    M._open_with_ref(args[1])
    return
  end

  -- Check if we have a cached forge detect result (instant)
  local cached = forge.get_cached_detect()
  if cached then
    local base = git.default_branch()
    if base then
      notify(
        string.format("Reviewing %s PR #%d against %s", cached.forge, cached.pr_number, base),
        vim.log.levels.INFO,
        M.config.notifications and M.config.notifications.context
      )
      if not M._open_with_ref(base) then
        return
      end
      state.set_forge_info(cached)
      hydrate_cached_remote_bundle(base)
      M.refresh_comments()
      return
    end
  end

  -- No cache — open with default branch diff, detect PR in background
  local base = git.default_branch()
  if base then
    local opened = M._open_with_ref(base)
    if not opened then
      return
    end

    local hydrated = hydrate_cached_remote_bundle(base)
    if hydrated then
      M.refresh_comments()
    end

    forge.detect_async(function(info)
      if not state.get() then
        return
      end
      if info then
        local previous = state.get_forge_info()
        local had_info = previous ~= nil
        local changed = not previous
          or previous.forge ~= info.forge
          or previous.owner ~= info.owner
          or previous.repo ~= info.repo
          or previous.pr_number ~= info.pr_number
        state.set_forge_info(info)
        if not had_info then
          hydrate_cached_remote_bundle(base)
        end
        if changed or not hydrated then
          notify(
            string.format("Detected %s PR #%d", info.forge, info.pr_number),
            vim.log.levels.INFO,
            M.config.notifications and M.config.notifications.context
          )
          M.refresh_comments()
        end
      end
    end)
  else
    M._open_with_ref(nil)
  end
end

--- Fetch (or re-fetch) remote PR comments and refresh the UI.
--- Runs asynchronously — UI updates when comments arrive.
function M.refresh_comments()
  local state = require("review.state")
  local s = state.get()
  if not s then
    return
  end

  local forge_info = state.get_forge_info()
  if not forge_info then
    vim.notify("No PR/MR detected for this session", vim.log.levels.WARN)
    return
  end

  local forge = require("review.forge")
  state.set_comments_loading(true)
  require("review.ui").refresh()

  -- Fetch asynchronously
  forge.fetch_comments_async(forge_info, function(comments, fetch_err)
    -- Verify session is still active
    if not state.get() then
      return
    end

    state.set_comments_loading(false)

    if fetch_err then
      vim.notify("Could not load PR comments: " .. fetch_err, vim.log.levels.WARN)
      require("review.ui").refresh()
      return
    end

    state.clear_remote_comments()
    if comments and #comments > 0 then
      state.load_remote_comments(comments)
    end
    require("review.storage").save_remote_bundle(forge_info, s.base_ref, comments or {})

    require("review.ui").refresh()
  end)
end

--- Close the current review session.
function M.close()
  local ui = require("review.ui")
  ui.close()
end

--- Toggle the review panel open/closed.
function M.toggle()
  local state = require("review.state")
  if state.get() then
    M.close()
  else
    M.open({})
  end
end

function M.open_notes()
  local state = require("review.state")
  if not state.get() then
    vim.notify("No active review session", vim.log.levels.ERROR)
    return
  end
  require("review.ui").open_notes_list()
end

function M.open_help()
  require("review.ui").open_help()
end

---@param notes ReviewNote[]
---@return table<string, ReviewNote[]>
local function notes_by_file(notes)
  local grouped = {}
  for _, note in ipairs(notes) do
    local file_key = note.file_path or "(general)"
    if not grouped[file_key] then
      grouped[file_key] = {}
    end
    table.insert(grouped[file_key], note)
  end
  return grouped
end

---@param note ReviewNote
---@return string
local function note_sort_key(note)
  local file_path = note.file_path or ""
  local line = note.line or 0
  local side = note.side or ""
  return table.concat({ file_path, string.format("%08d", line), side, tostring(note.id or 0) }, "::")
end

---@param notes ReviewNote[]
local function sort_notes(notes)
  table.sort(notes, function(a, b)
    return note_sort_key(a) < note_sort_key(b)
  end)
end

---@param note ReviewNote
---@return string
local function export_note_heading(note)
  if note.is_general or not note.file_path then
    return "PR/MR"
  end

  local line_ref = tostring(note.line or "?")
  if note.end_line then
    line_ref = line_ref .. "-" .. tostring(note.end_line)
  end

  local side = note.side and (" " .. note.side) or ""
  return string.format("%s:%s%s", note.file_path, line_ref, side)
end

---@param note ReviewNote
---@return string[]
local function export_note_meta(note)
  local meta = {}
  table.insert(meta, note.status or "draft")
  table.insert(meta, note.note_type == "suggestion" and "suggestion" or "comment")
  if note.status == "remote" then
    table.insert(meta, note.resolved and "resolved" or "open")
  end
  if note.author then
    table.insert(meta, "by @" .. note.author)
  end
  return meta
end

---@param session ReviewSession
---@param notes ReviewNote[]
---@return string
local function build_export_content(session, notes)
  local git = require("review.git")
  local branch = git.current_branch() or "HEAD"
  local title = session.forge_info
      and string.format("# Review Notes for %s #%d", session.forge_info.forge, session.forge_info.pr_number)
    or "# Review Notes"

  local lines = {
    title,
    "",
    string.format("- branch: `%s`", branch),
    string.format("- base: `%s`", session.base_ref or "HEAD"),
    string.format("- total notes: %d", #notes),
    "",
  }

  local groups = notes_by_file(notes)
  local file_keys = {}
  for file_key, _ in pairs(groups) do
    table.insert(file_keys, file_key)
  end
  table.sort(file_keys)

  for _, file_key in ipairs(file_keys) do
    local file_notes = groups[file_key]
    sort_notes(file_notes)
    table.insert(lines, "## " .. file_key)
    table.insert(lines, "")

    for _, note in ipairs(file_notes) do
      table.insert(lines, "### " .. export_note_heading(note))
      table.insert(lines, "")
      table.insert(lines, "- meta: " .. table.concat(export_note_meta(note), ", "))
      if note.url then
        table.insert(lines, "- url: " .. note.url)
      end
      table.insert(lines, "")
      table.insert(lines, note.body)
      table.insert(lines, "")

      if note.status == "remote" and note.replies and #note.replies > 1 then
        table.insert(lines, "Replies:")
        table.insert(lines, "")
        for i = 2, #note.replies do
          local reply = note.replies[i]
          local header = "- @" .. (reply.author or "unknown")
          if reply.created_at then
            local date = reply.created_at:match("^(%d%d%d%d%-%d%d%-%d%d)")
            if date then
              header = header .. " (" .. date .. ")"
            end
          end
          table.insert(lines, header)
          table.insert(lines, "  " .. (reply.body or ""))
        end
        table.insert(lines, "")
      end
    end
  end

  return table.concat(lines, "\n")
end

---@param notes ReviewNote[]
---@return ReviewNote[], ReviewNote[], ReviewNote[]
local function clipboard_note_sections(notes)
  local local_notes = {}
  local open_threads = {}
  local discussion_notes = {}

  for _, note in ipairs(notes) do
    if note.is_general then
      table.insert(discussion_notes, note)
    elseif note.status == "draft" or note.status == "staged" then
      table.insert(local_notes, note)
    elseif note.status == "remote" and not note.resolved then
      table.insert(open_threads, note)
    end
  end

  sort_notes(local_notes)
  sort_notes(open_threads)
  sort_notes(discussion_notes)
  return local_notes, open_threads, discussion_notes
end

---@param lines string[]
---@param title string
---@param notes ReviewNote[]
local function append_clipboard_section(lines, title, notes)
  if #notes == 0 then
    return
  end

  table.insert(lines, "## " .. title)
  table.insert(lines, "")

  for _, note in ipairs(notes) do
    table.insert(lines, "### " .. export_note_heading(note))
    table.insert(lines, "")
    table.insert(lines, "- meta: " .. table.concat(export_note_meta(note), ", "))
    if note.url then
      table.insert(lines, "- url: " .. note.url)
    end
    table.insert(lines, "")
    table.insert(lines, note.body)
    table.insert(lines, "")

    if note.status == "remote" and note.replies and #note.replies > 1 then
      table.insert(lines, "Replies:")
      table.insert(lines, "")
      for i = 2, #note.replies do
        local reply = note.replies[i]
        local header = "- @" .. (reply.author or "unknown")
        if reply.created_at then
          local date = reply.created_at:match("^(%d%d%d%d%-%d%d%-%d%d)")
          if date then
            header = header .. " (" .. date .. ")"
          end
        end
        table.insert(lines, header)
        table.insert(lines, "  " .. (reply.body or ""))
      end
      table.insert(lines, "")
    end
  end
end

---@param session ReviewSession
---@param notes ReviewNote[]
---@return string
local function build_clipboard_content(session, notes)
  local git = require("review.git")
  local branch = git.current_branch() or "HEAD"
  local local_notes, open_threads, discussion_notes = clipboard_note_sections(notes)
  local total = #local_notes + #open_threads + #discussion_notes
  local title = session.forge_info
      and string.format("# Review Queue for %s #%d", session.forge_info.forge, session.forge_info.pr_number)
    or "# Review Queue"

  local lines = {
    title,
    "",
    string.format("- branch: `%s`", branch),
    string.format("- base: `%s`", session.base_ref or "HEAD"),
    string.format("- included: %d", total),
    "",
  }

  append_clipboard_section(lines, "Your Notes", local_notes)
  append_clipboard_section(lines, "Open Threads", open_threads)
  append_clipboard_section(lines, "Discussion", discussion_notes)

  return table.concat(lines, "\n")
end

---@param session ReviewSession
---@param notes ReviewNote[]
---@return string
local function build_local_notes_clipboard_content(session, notes)
  local git = require("review.git")
  local branch = git.current_branch() or "HEAD"
  local local_notes = {}
  for _, note in ipairs(notes) do
    if note.status == "draft" or note.status == "staged" then
      table.insert(local_notes, note)
    end
  end
  sort_notes(local_notes)

  local title = session.forge_info
      and string.format("# Local Review Notes for %s #%d", session.forge_info.forge, session.forge_info.pr_number)
    or "# Local Review Notes"

  local lines = {
    title,
    "",
    string.format("- branch: `%s`", branch),
    string.format("- base: `%s`", session.base_ref or "HEAD"),
    string.format("- included: %d", #local_notes),
    "",
  }

  append_clipboard_section(lines, "Your Notes", local_notes)
  return table.concat(lines, "\n")
end

---@param content string
---@return string
local function copy_to_clipboard(content)
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
  if #copied == 0 then
    return [["]]
  end
  return table.concat(copied, ", ")
end

---@param opts table|nil
---@return string|nil, string|nil
function M.export_content(opts)
  opts = opts or {}
  local state = require("review.state")
  local s = state.get()
  if not s then
    return nil, "No active review session"
  end

  local notes = state.get_notes()
  if #notes == 0 then
    return nil, "No notes to export"
  end

  if opts.local_only then
    local has_local = false
    for _, note in ipairs(notes) do
      if note.status == "draft" or note.status == "staged" then
        has_local = true
        break
      end
    end
    if not has_local then
      return nil, "No local notes to export"
    end
    return build_local_notes_clipboard_content(s, notes), nil
  end

  if opts.clipboard then
    return build_clipboard_content(s, notes), nil
  end

  return build_export_content(s, notes), nil
end

function M.copy_notes_to_clipboard()
  local content, err = M.export_content({ clipboard = true })
  if not content then
    vim.notify(err, err == "No active review session" and vim.log.levels.ERROR or vim.log.levels.INFO)
    return
  end

  local target = copy_to_clipboard(content)
  vim.notify("Notes copied to clipboard register(s): " .. target, vim.log.levels.INFO)
end

function M.copy_local_notes_to_clipboard()
  local content, err = M.export_content({ local_only = true })
  if not content then
    vim.notify(err, err == "No active review session" and vim.log.levels.ERROR or vim.log.levels.INFO)
    return
  end

  local target = copy_to_clipboard(content)
  vim.notify("Local notes copied to clipboard register(s): " .. target, vim.log.levels.INFO)
end

function M.clear_local_notes()
  local state = require("review.state")
  local s = state.get()
  if not s then
    vim.notify("No active review session", vim.log.levels.ERROR)
    return
  end

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
  if cleared == 0 then
    vim.notify("No local notes to clear", vim.log.levels.INFO)
    return
  end

  require("review.ui").refresh()
  vim.notify(cleared .. " local note(s) cleared", vim.log.levels.INFO)
end

---@param raw string
---@return table|nil
local function parse_note_target(raw)
  if not raw or raw == "" then
    return nil
  end

  local file_path, line, side = raw:match("^(.-):(%d+):(old)$")
  if not file_path then
    file_path, line, side = raw:match("^(.-):(%d+):(new)$")
  end
  if not file_path then
    file_path, line = raw:match("^(.-):(%d+)$")
  end
  if file_path and line then
    return {
      file_path = file_path,
      line = tonumber(line),
      side = side or "new",
    }
  end

  return nil
end

---@param args string[]
---@return table|nil, string|nil
function M.resolve_note_target(args)
  args = args or {}

  if #args > 0 then
    local target = parse_note_target(args[1])
    if target then
      return target, nil
    end

    if #args >= 2 then
      local line = tonumber(args[2])
      if line then
        return {
          file_path = args[1],
          line = line,
          side = args[3] == "old" and "old" or "new",
        }, nil
      end
    end

    return nil, "Use :ReviewComment path:line[:old|new] or :ReviewComment path line [old|new]"
  end
  return nil, "No explicit note target provided"
end

---@param args string[]|nil
function M.add_note(args)
  local state = require("review.state")
  if not state.get() then
    vim.notify("No active review session", vim.log.levels.ERROR)
    return
  end

  if not args or #args == 0 then
    require("review.ui").open_note_float()
    return
  end

  local target, err = M.resolve_note_target(args)
  if not target then
    vim.notify(err or "Could not determine note target", vim.log.levels.WARN)
    return
  end

  require("review.ui").open_note_float_for_target(target, {})
end

---@param args string[]|nil
function M.add_suggestion(args)
  local state = require("review.state")
  if not state.get() then
    vim.notify("No active review session", vim.log.levels.ERROR)
    return
  end

  if not args or #args == 0 then
    require("review.ui").open_note_float({ suggestion = true })
    return
  end

  local target, err = M.resolve_note_target(args)
  if not target then
    vim.notify(err or "Could not determine note target", vim.log.levels.WARN)
    return
  end

  require("review.ui").open_note_float_for_target(target, { suggestion = true })
end

--- Export notes to markdown (local mode).
---@param path string|nil
function M.export(path)
  local content, err = M.export_content()
  if not content then
    vim.notify(err, err == "No active review session" and vim.log.levels.ERROR or vim.log.levels.INFO)
    return
  end
  path = path or "review-notes.md"

  vim.fn.writefile(vim.split(content, "\n"), path)
  vim.notify("Notes exported to " .. path, vim.log.levels.INFO)
end

return M
