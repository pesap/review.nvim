--- Handoff packet and clipboard export builders.
local M = {}

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

---@param session ReviewSession
---@param note ReviewNote
---@return string
function M.note_unit_label(session, note)
  if note.gitbutler then
    if note.gitbutler.kind == "unassigned" then
      return "unassigned"
    end
    return note.gitbutler.branch_name or note.gitbutler.branch_cli_id or "gitbutler"
  end
  if note.commit_short_sha then
    return note.commit_short_sha
  end
  if session.forge_info and session.forge_info.pr_number then
    return string.format("%s PR #%d", session.forge_info.forge, session.forge_info.pr_number)
  end
  return session.branch or "workspace"
end

---@param session ReviewSession
---@param notes ReviewNote[]
---@return table<string, ReviewNote[]>
local function notes_by_unit(session, notes)
  local grouped = {}
  for _, note in ipairs(notes) do
    local key = M.note_unit_label(session, note)
    grouped[key] = grouped[key] or {}
    table.insert(grouped[key], note)
  end
  return grouped
end

---@param session ReviewSession
---@param note ReviewNote
---@return ReviewFile|nil
local function find_note_file(session, note)
  if not note.file_path then
    return nil
  end
  local lists = { session.files or {}, session.untracked_files or {} }
  for _, commit in ipairs(session.commits or {}) do
    if commit.files then
      table.insert(lists, commit.files)
    end
  end
  for _, files in ipairs(lists) do
    for _, file in ipairs(files) do
      if file.path == note.file_path then
        return file
      end
    end
  end
  return nil
end

---@param note ReviewNote
---@param file ReviewFile|nil
---@return string[]|nil
local function note_hunk_lines(note, file)
  if not note.line or not file then
    return nil
  end
  for _, hunk in ipairs(file.hunks or {}) do
    local old_last = hunk.old_start + math.max(hunk.old_count - 1, 0)
    local new_last = hunk.new_start + math.max(hunk.new_count - 1, 0)
    local in_old = note.side == "old" and note.line >= hunk.old_start and note.line <= old_last
    local in_new = note.side ~= "old" and note.line >= hunk.new_start and note.line <= new_last
    if in_old or in_new then
      local out = { hunk.header }
      for _, dl in ipairs(hunk.lines or {}) do
        local prefix = dl.type == "add" and "+" or dl.type == "del" and "-" or " "
        table.insert(out, prefix .. (dl.text or ""))
      end
      return out
    end
  end
  return nil
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
  if note.gitbutler and (note.gitbutler.unpublished == true or note.gitbutler.kind == "unassigned") then
    table.insert(meta, "unpublished")
  end
  if note.author then
    table.insert(meta, "by @" .. note.author)
  end
  return meta
end

---@param lines string[]
---@param session ReviewSession
---@param note ReviewNote
---@param opts table|nil
local function append_enriched_note(lines, session, note, opts)
  opts = opts or {}
  table.insert(lines, "### " .. export_note_heading(note))
  table.insert(lines, "- id: #" .. tostring(note.id or "?"))
  table.insert(lines, "- unit: `" .. M.note_unit_label(session, note) .. "`")
  table.insert(lines, "- meta: " .. table.concat(export_note_meta(note), ", "))
  if note.file_path then
    local range = tostring(note.line or "?")
    if note.end_line then
      range = range .. "-" .. tostring(note.end_line)
    end
    table.insert(lines, string.format("- target: `%s:%s:%s`", note.file_path, range, note.side or "new"))
  end
  if note.commit_short_sha then
    table.insert(lines, "- commit: `" .. note.commit_short_sha .. "`")
  end
  if opts.include_scope_details and note.gitbutler then
    table.insert(lines, "- gitbutler: `" .. vim.fn.json_encode(note.gitbutler) .. "`")
  end
  if note.url then
    table.insert(lines, "- url: " .. note.url)
  end
  if note.requested_action then
    table.insert(lines, "- action: " .. tostring(note.requested_action))
  end
  if note.validation then
    table.insert(lines, "- validation: `" .. tostring(note.validation) .. "`")
  end

  if opts.include_hunks then
    local hunk = note_hunk_lines(note, find_note_file(session, note))
    if hunk then
      table.insert(lines, "```diff")
      vim.list_extend(lines, hunk)
      table.insert(lines, "```")
    end
  end

  if note.note_type == "suggestion" and (note.body or ""):match("```suggestion") then
    table.insert(lines, note.body)
  else
    table.insert(lines, note.body or "")
  end

  if note.blame_context then
    table.insert(lines, "- blame: " .. tostring(note.blame_context))
  end
  if note.log_context then
    table.insert(lines, "- log: " .. tostring(note.log_context))
  end

  if note.status == "remote" and note.replies and #note.replies > 1 then
    table.insert(lines, "Replies:")
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
  end
end

---@param session ReviewSession
---@param notes ReviewNote[]
---@return string
local function build_export_content(session, notes)
  local git = require("review.git")
  local branch = session.vcs == "gitbutler" and "GitButler workspace" or (git.current_branch() or "HEAD")
  local head = session.vcs == "gitbutler" and "workspace" or branch
  local merge_base = session.pr and session.pr.diff_refs and session.pr.diff_refs.start_sha
    or session.merge_base_ref
    or session.base_ref
  local title = session.forge_info
      and string.format("# Review Notes for %s #%d", session.forge_info.forge, session.forge_info.pr_number)
    or "# Review Notes"

  local lines = {
    title,
    "",
    string.format("- branch: `%s`", branch),
    string.format("- base: `%s`", session.base_ref or "HEAD"),
    string.format("- head: `%s`", head),
    string.format("- merge-base: `%s`", merge_base or session.base_ref or "HEAD"),
    string.format("- review units: %d", vim.tbl_count(notes_by_unit(session, notes))),
    string.format("- total notes: %d", #notes),
    "",
  }

  local unit_groups = notes_by_unit(session, notes)
  local unit_keys = {}
  for unit_key, _ in pairs(unit_groups) do
    table.insert(unit_keys, unit_key)
  end
  table.sort(unit_keys)

  for _, unit_key in ipairs(unit_keys) do
    local unit_notes = unit_groups[unit_key]
    sort_notes(unit_notes)
    table.insert(lines, "## " .. unit_key)
    table.insert(lines, "")
    for _, note in ipairs(unit_notes) do
      append_enriched_note(lines, session, note, { include_hunks = true, include_scope_details = true })
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
    elseif (note.status == "draft" or note.status == "staged") and not note.resolved then
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
---@param session ReviewSession
---@param title string
---@param notes ReviewNote[]
local function append_clipboard_section(lines, session, title, notes)
  if #notes == 0 then
    return
  end

  table.insert(lines, "## " .. title)
  table.insert(lines, "")

  for idx, note in ipairs(notes) do
    if idx > 1 then
      table.insert(lines, "")
    end
    append_enriched_note(lines, session, note)
  end
end

---@param lines string[]
---@return string[]
local function compact_empty_lines(lines)
  local out = {}
  local last_empty = false
  for _, line in ipairs(lines) do
    local is_empty = line == ""
    if not (is_empty and last_empty) then
      table.insert(out, line)
    end
    last_empty = is_empty
  end
  return out
end

---@param session ReviewSession
---@param notes ReviewNote[]
---@return string
local function build_clipboard_content(session, notes)
  local git = require("review.git")
  local branch = session.vcs == "gitbutler" and "GitButler workspace" or (git.current_branch() or "HEAD")
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

  append_clipboard_section(lines, session, "Your Notes", local_notes)
  append_clipboard_section(lines, session, "Open Threads", open_threads)
  append_clipboard_section(lines, session, "Discussion", discussion_notes)

  return table.concat(compact_empty_lines(lines), "\n")
end

---@param session ReviewSession
---@param notes ReviewNote[]
---@return string
local function build_local_notes_clipboard_content(session, notes)
  local git = require("review.git")
  local branch = session.vcs == "gitbutler" and "GitButler workspace" or (git.current_branch() or "HEAD")
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

  append_clipboard_section(lines, session, "Your Notes", local_notes)
  return table.concat(compact_empty_lines(lines), "\n")
end

---@param opts table|nil
---@return string|nil, string|nil
function M.export_content(opts)
  opts = opts or {}
  local state = require("review.state")
  local session = state.get()
  if not session then
    return nil, "No active review session"
  end

  local notes = state.get_notes()
  if #notes == 0 then
    return nil, "No notes to export"
  end

  if opts.stale_only then
    local stale = {}
    for _, note in ipairs(notes) do
      if state.note_is_stale(note) then
        table.insert(stale, note)
      end
    end
    notes = stale
    if #notes == 0 then
      return nil, "No stale notes to export"
    end
  end

  if opts.unit then
    local unit_notes = {}
    for _, note in ipairs(notes) do
      if M.note_unit_label(session, note) == opts.unit then
        table.insert(unit_notes, note)
      end
    end
    notes = unit_notes
    if #notes == 0 then
      return nil, "No notes for review unit " .. tostring(opts.unit)
    end
  end

  if opts.local_only then
    local has_local = false
    local local_notes = {}
    for _, note in ipairs(notes) do
      if note.status == "draft" or note.status == "staged" then
        has_local = true
        table.insert(local_notes, note)
      end
    end
    if not has_local then
      return nil, "No local notes to export"
    end
    return build_local_notes_clipboard_content(session, local_notes), nil
  end

  if opts.clipboard then
    return build_clipboard_content(session, notes), nil
  end

  return build_export_content(session, notes), nil
end

return M
