--- Centralized session state singleton.
local M = {}

---@type ReviewSession|nil
local session = nil

---@class ReviewCommit
---@field sha string
---@field short_sha string
---@field message string
---@field author string
---@field files ReviewFile[]|nil  Lazily loaded per-commit files

---@class ReviewSession
---@field mode "local"|"pr"
---@field base_ref string
---@field files ReviewFile[]             All files (full diff)
---@field commits ReviewCommit[]         Commits in the range
---@field current_commit_idx number|nil  nil = all changes, number = specific commit
---@field current_file_idx number
---@field pr ReviewPR|nil
---@field notes ReviewNote[]
---@field draft_comments ReviewComment[]
---@field ui_state ReviewUIState|nil

---@class ReviewPR
---@field number number
---@field title string
---@field owner string
---@field repo string
---@field base string
---@field head string

---@class ReviewFile
---@field path string
---@field status string  "M"|"A"|"D"|"R"
---@field hunks ReviewHunk[]

---@class ReviewHunk
---@field header string
---@field old_start number
---@field old_count number
---@field new_start number
---@field new_count number
---@field lines ReviewDiffLine[]

---@class ReviewDiffLine
---@field type string  "add"|"del"|"ctx"
---@field text string
---@field old_lnum number|nil
---@field new_lnum number|nil

---@class ReviewNote
---@field file_path string
---@field line number
---@field end_line number|nil
---@field side string  "old"|"new"
---@field body string
---@field note_type string  "comment"|"suggestion"

---@class ReviewComment
---@field file_path string
---@field line number
---@field end_line number|nil
---@field side string  "LEFT"|"RIGHT"
---@field body string
---@field github_id number|nil

---@class ReviewUIState
---@field explorer_buf number|nil
---@field explorer_win number|nil
---@field diff_buf number|nil
---@field diff_win number|nil
---@field split_buf number|nil
---@field split_win number|nil
---@field tab number|nil
---@field view_mode string  "unified"|"split"

--- Create a new review session.
---@param mode "local"|"pr"
---@param base_ref string
---@param files ReviewFile[]
---@return ReviewSession
function M.create(mode, base_ref, files)
  session = {
    mode = mode,
    base_ref = base_ref,
    files = files,
    commits = {},
    current_commit_idx = nil, -- nil = all changes
    current_file_idx = 1,
    pr = nil,
    notes = {},
    draft_comments = {},
    ui_state = nil,
  }
  return session
end

--- Get the current session.
---@return ReviewSession|nil
function M.get()
  return session
end

--- Destroy the current session.
function M.destroy()
  session = nil
end

--- Set the current file index.
---@param idx number
function M.set_file(idx)
  if not session then
    return
  end
  if idx >= 1 and idx <= #session.files then
    session.current_file_idx = idx
  end
end

--- Set commits for the session.
---@param commits ReviewCommit[]
function M.set_commits(commits)
  if session then
    session.commits = commits
  end
end

--- Get the currently selected commit (nil = all changes).
---@return ReviewCommit|nil
function M.current_commit()
  if not session or not session.current_commit_idx then
    return nil
  end
  return session.commits[session.current_commit_idx]
end

--- Select a commit by index (nil = show all changes).
---@param idx number|nil
function M.set_commit(idx)
  if not session then
    return
  end
  if idx == nil then
    session.current_commit_idx = nil
    session.current_file_idx = 1
  elseif idx >= 1 and idx <= #session.commits then
    session.current_commit_idx = idx
    session.current_file_idx = 1
  end
end

--- Get the active file list (filtered by commit if one is selected).
---@return ReviewFile[]
function M.active_files()
  if not session then
    return {}
  end
  if session.current_commit_idx then
    local commit = session.commits[session.current_commit_idx]
    if commit and commit.files then
      return commit.files
    end
    return {}
  end
  return session.files
end

--- Get the currently selected file from the active file list.
---@return ReviewFile|nil
function M.active_current_file()
  local files = M.active_files()
  if #files == 0 then
    return nil
  end
  local idx = session.current_file_idx
  if idx < 1 or idx > #files then
    return nil
  end
  return files[idx]
end

--- Add a local note.
---@param file_path string
---@param line number
---@param body string
---@param end_line number|nil
---@param side string|nil  "old"|"new", defaults to "new"
function M.add_note(file_path, line, body, end_line, side, note_type)
  if not session then
    return
  end
  table.insert(session.notes, {
    file_path = file_path,
    line = line,
    end_line = end_line,
    side = side or "new",
    body = body,
    note_type = note_type or "comment",
  })
end

--- Get notes for a specific file (or all notes if no path given).
---@param file_path string|nil
---@return ReviewNote[]
function M.get_notes(file_path)
  if not session then
    return {}
  end
  if not file_path then
    return session.notes
  end
  local result = {}
  for _, note in ipairs(session.notes) do
    if note.file_path == file_path then
      table.insert(result, note)
    end
  end
  return result
end

--- Remove a note by index in the session notes list.
---@param idx number
function M.remove_note(idx)
  if session and idx >= 1 and idx <= #session.notes then
    table.remove(session.notes, idx)
  end
end

--- Add a draft comment (PR mode).
---@param file_path string
---@param line number
---@param body string
---@param end_line number|nil
---@param side string|nil  "LEFT"|"RIGHT", defaults to "RIGHT"
function M.add_draft(file_path, line, body, end_line, side)
  if not session then
    return
  end
  table.insert(session.draft_comments, {
    file_path = file_path,
    line = line,
    end_line = end_line,
    side = side or "RIGHT",
    body = body,
    github_id = nil,
  })
end

--- Get all draft comments.
---@return ReviewComment[]
function M.get_drafts()
  if not session then
    return {}
  end
  return session.draft_comments
end

--- Clear all draft comments (after successful submission).
function M.clear_drafts()
  if session then
    session.draft_comments = {}
  end
end

--- Set UI state.
---@param ui ReviewUIState
function M.set_ui(ui)
  if session then
    session.ui_state = ui
  end
end

--- Get UI state.
---@return ReviewUIState|nil
function M.get_ui()
  if session then
    return session.ui_state
  end
  return nil
end

return M
