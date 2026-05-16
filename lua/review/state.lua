--- Centralized review session state.
local M = {}

local storage -- lazy-loaded to avoid circular require at parse time

---@type ReviewSession|nil
local session = nil
---@type table<number, ReviewSession>
local sessions = {}
---@type number|nil
local active_tab = nil

--- Auto-incrementing note ID counter.
local next_note_id = 1

--- Get the storage module (lazy-loaded once).
local function get_storage()
  if not storage then
    storage = require("review.storage")
  end
  return storage
end

---@return number
local function current_tab()
  local ok, tab = pcall(vim.api.nvim_get_current_tabpage)
  if ok and tab then
    return tab
  end
  return 1
end

---@param tab number|nil
---@return number
local function session_key(tab)
  return tab or current_tab()
end

---@param tab number|nil
---@return ReviewSession|nil
local function activate_session(tab)
  local key = session_key(tab)
  if sessions[key] then
    active_tab = key
    session = sessions[key]
  elseif active_tab ~= key then
    if session and not next(sessions) then
      sessions[key] = session
      active_tab = key
      return session
    end
    local only_tab, only_session
    for existing_tab, existing_session in pairs(sessions) do
      if only_session then
        only_session = nil
        break
      end
      only_tab = existing_tab
      only_session = existing_session
    end
    if only_session then
      sessions[key] = only_session
      active_tab = key
      session = only_session
    else
      active_tab = key
      session = nil
    end
  end
  return session
end

---@param file_path string|nil
---@param line number|nil
---@param side string
---@return string
local function note_location_key(file_path, line, side)
  return table.concat({ file_path, tostring(line), side }, "::")
end

local function rebuild_note_indexes()
  if not session then
    return
  end

  session.note_index_by_file = {}
  session.note_index_by_id = {}
  session.note_index_by_location = {}

  for idx, note in ipairs(session.notes) do
    if note.id then
      session.note_index_by_id[note.id] = { note = note, idx = idx }
    end

    if note.file_path then
      local by_file = session.note_index_by_file[note.file_path]
      if not by_file then
        by_file = {}
        session.note_index_by_file[note.file_path] = by_file
      end
      table.insert(by_file, note)

      if note.line and note.side then
        local key = note_location_key(note.file_path, note.line, note.side)
        session.note_index_by_location[key] = session.note_index_by_location[key] or {}
        table.insert(session.note_index_by_location[key], { note = note, idx = idx })
      end
    end
  end
end

---@class ReviewCommit
---@field sha string
---@field short_sha string
---@field message string
---@field author string
---@field files ReviewFile[]|nil  Lazily loaded per-commit files
---@field gitbutler table|nil

---@class ReviewSession
---@field mode "local"|"pr"
---@field vcs "git"|"gitbutler"|nil
---@field repo_root string|nil
---@field branch string|nil
---@field requested_ref string|nil
---@field base_ref string
---@field left_ref string|nil
---@field right_ref string|nil
---@field comparison_key string|nil
---@field previous_review table|nil
---@field head_ref string|nil
---@field merge_base_ref string|nil
---@field files ReviewFile[]             All files (full diff)
---@field untracked_files ReviewFile[]   Untracked working tree files
---@field commits ReviewCommit[]         Commits in the range
---@field scope_mode "all"|"current_commit"|"select_commit"
---@field current_commit_idx number|nil  nil = all changes, number = specific commit
---@field current_file_idx number
---@field remote_context_stale string|nil
---@field pr ReviewPR|nil
---@field provider ReviewProvider|nil
---@field notes ReviewNote[]
---@field draft_comments ReviewComment[]
---@field comments_loading boolean|nil
---@field local_refresh_loading boolean|nil
---@field remote_summary table|nil
---@field gitbutler table|nil
---@field ui_state ReviewUIState|nil
---@field workspace_signature string|nil
---@field file_review_status table<string,string>
---@field unit_review_status table<string,string>
---@field review_snapshot_ref string|nil
---@field review_snapshot_files table<string,string>|nil
---@field ui_prefs table

---@class ReviewPR
---@field number number
---@field title string
---@field owner string
---@field repo string
---@field base string
---@field head string
---@field diff_refs table|nil  {base_sha, head_sha, start_sha}

---@class ReviewFile
---@field path string
---@field status string  "M"|"A"|"D"|"R"|"?"
---@field untracked boolean|nil
---@field gitbutler table|nil
---@field gitbutler_unassigned boolean|nil
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
---@field id number
---@field file_path string|nil  nil for PR-level comments
---@field line number|nil  nil for PR-level comments
---@field end_line number|nil
---@field side string|nil  "old"|"new", nil for PR-level comments
---@field is_general boolean|nil  true for PR-level comments
---@field target_kind string|nil  "line"|"file"|"unit"|"discussion"
---@field body string
---@field note_type string  "comment"|"suggestion"
---@field status string  "draft"|"staged"|"remote"
---@field commit_sha string|nil
---@field commit_short_sha string|nil
---@field url string|nil  Link to the published comment (e.g. GitHub PR comment URL)
---@field author string|nil  Author of a remote comment
---@field replies ReviewReply[]|nil  Thread replies (remote comments only)
---@field thread_id number|string|nil  Forge thread ID for replying
---@field thread_node_id string|nil  GraphQL node ID for resolve/unresolve (GitHub)
---@field resolved boolean|nil  Whether the thread is resolved (remote only)
---@field outdated boolean|nil  Whether the remote thread is outdated
---@field gitbutler table|nil GitButler note scope metadata

---@class ReviewReply
---@field author string
---@field body string
---@field url string|nil
---@field created_at string|nil
---@field is_top boolean
---@field remote_id number|nil

---@class ReviewComment
---@field file_path string
---@field line number
---@field end_line number|nil
---@field side string  "LEFT"|"RIGHT"
---@field body string
---@field remote_id number|nil

---@class ReviewUIState
---@field files_buf number|nil
---@field files_win number|nil
---@field threads_buf number|nil
---@field threads_win number|nil
---@field explorer_buf number|nil
---@field explorer_win number|nil
---@field diff_buf number|nil
---@field diff_win number|nil
---@field split_buf number|nil
---@field split_win number|nil
---@field tab number|nil
---@field explorer_width number|nil
---@field view_mode string  "unified"|"split"
---@field previous_laststatus number|nil

--- Create a new review session.
---@param mode "local"|"pr"
---@param base_ref string
---@param files ReviewFile[]
---@param opts table|nil
---@return ReviewSession
function M.create(mode, base_ref, files, opts)
  opts = opts or {}
  local git = require("review.git")
  local key = session_key(opts.tab)
  session = {
    mode = mode,
    vcs = opts.vcs or "git",
    repo_root = opts.repo_root or git.root(),
    branch = opts.branch or git.current_branch() or "HEAD",
    requested_ref = opts.requested_ref,
    base_ref = base_ref,
    left_ref = opts.left_ref,
    right_ref = opts.right_ref,
    comparison_key = opts.comparison_key,
    previous_review = opts.previous_review,
    head_ref = opts.head_ref,
    merge_base_ref = opts.merge_base_ref,
    files = files,
    untracked_files = opts.untracked_files or {},
    commits = {},
    scope_mode = "all",
    current_commit_idx = nil, -- nil = all changes
    current_file_idx = 1,
    remote_context_stale = nil,
    pr = nil,
    provider = nil,
    notes = {},
    draft_comments = {},
    comments_loading = false,
    local_refresh_loading = false,
    remote_summary = nil,
    forge_info = nil,
    gitbutler = opts.gitbutler,
    ui_state = nil,
    file_review_status = {},
    unit_review_status = {},
    review_snapshot_ref = nil,
    review_snapshot_files = nil,
    ui_prefs = {},
    workspace_signature = opts.workspace_signature
      or (mode == "local" and git.workspace_signature and git.workspace_signature() or nil),
  }

  local loaded = get_storage().load()
  if #loaded > 0 then
    session.notes = loaded
    -- Advance the ID counter past any loaded note IDs
    for _, note in ipairs(loaded) do
      if note.id and note.id >= next_note_id then
        next_note_id = note.id + 1
      end
    end
  end
  if get_storage().load_workspace_state then
    local workspace_state = get_storage().load_workspace_state()
    if workspace_state then
      session.file_review_status = workspace_state.file_review_status or {}
      session.unit_review_status = workspace_state.unit_review_status or {}
      session.review_snapshot_ref = workspace_state.review_snapshot_ref
      session.review_snapshot_files = workspace_state.review_snapshot_files
      session.ui_prefs = workspace_state.ui_prefs or {}
    end
  end

  rebuild_note_indexes()
  sessions[key] = session
  active_tab = key

  return session
end

---@return string|nil
function M.comparison_key()
  if not session then
    return nil
  end
  if session.comparison_key then
    return session.comparison_key
  end
  if session.left_ref and session.right_ref then
    return table.concat({ session.vcs or "git", session.left_ref, session.right_ref }, "::")
  end
  return nil
end

--- Get the current session.
---@param tab number|nil
---@return ReviewSession|nil
function M.get(tab)
  if tab then
    return sessions[tab]
  end
  return activate_session(current_tab())
end

--- Destroy the current session.
---@param tab number|nil
function M.destroy(tab)
  local key = tab or active_tab or current_tab()
  local target = sessions[key] or session
  if target then
    get_storage().save(target)
  end
  sessions[key] = nil
  if session == target then
    session = nil
    active_tab = nil
  end
end

---@param tab number|nil
---@return ReviewSession|nil
function M.activate(tab)
  return activate_session(tab)
end

---@param tab number
---@param target ReviewSession|nil
---@return ReviewSession|nil
function M.bind(tab, target)
  target = target or session
  if not tab or not target then
    return nil
  end
  sessions[tab] = target
  active_tab = tab
  session = target
  return target
end

---@return table<number, ReviewSession>
function M.sessions()
  return sessions
end

--- Store forge info for the session (avoids repeated shell calls).
---@param info table|nil
function M.set_forge_info(info)
  if session then
    session.forge_info = info
  end
end

--- Get cached forge info.
---@return table|nil
function M.get_forge_info()
  if session then
    return session.forge_info
  end
  return nil
end

---@param loading boolean
function M.set_comments_loading(loading)
  if session then
    session.comments_loading = loading and true or false
  end
end

---@return boolean
function M.comments_loading()
  return session and session.comments_loading == true or false
end

---@param loading boolean
function M.set_local_refresh_loading(loading)
  if session then
    session.local_refresh_loading = loading and true or false
  end
end

---@return boolean
function M.local_refresh_loading()
  return session and session.local_refresh_loading == true or false
end

---@param summary table|nil
function M.set_remote_summary(summary)
  if session then
    session.remote_summary = summary
  end
end

---@return table|nil
function M.remote_summary()
  return session and session.remote_summary or nil
end

--- Set the current file index.
---@param idx number
function M.set_file(idx)
  if not session then
    return
  end
  local files = M.active_files()
  if idx >= 1 and idx <= #files then
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

---@return "all"|"current_commit"|"select_commit"
function M.scope_mode()
  if not session then
    return "all"
  end
  return session.scope_mode or "all"
end

---@param mode "all"|"current_commit"|"select_commit"
---@param opts table|nil
function M.set_scope_mode(mode, opts)
  if not session then
    return
  end
  opts = opts or {}
  session.scope_mode = mode
  if mode == "all" then
    session.current_commit_idx = nil
    session.current_file_idx = 1
  elseif mode == "select_commit" and opts.keep_all_files then
    session.current_commit_idx = nil
    session.current_file_idx = 1
  elseif not session.current_commit_idx and #session.commits > 0 then
    session.current_commit_idx = 1
    session.current_file_idx = 1
  end
end

---@return boolean
function M.uses_commit_scope()
  return session ~= nil
    and session.scope_mode ~= "all"
    and session.current_commit_idx ~= nil
    and session.commits[session.current_commit_idx] ~= nil
end

--- Get the currently selected commit (nil = all changes).
---@return ReviewCommit|nil
function M.current_commit()
  if not session or not session.current_commit_idx then
    return nil
  end
  return session.commits[session.current_commit_idx]
end

---@return boolean
function M.is_gitbutler()
  return session ~= nil and session.vcs == "gitbutler"
end

--- Select a commit by index (nil = show all changes).
---@param idx number|nil
function M.set_commit(idx)
  if not session then
    return
  end
  if idx == nil then
    session.current_commit_idx = nil
    session.scope_mode = "all"
    session.current_file_idx = 1
  elseif idx >= 1 and idx <= #session.commits then
    session.current_commit_idx = idx
    session.scope_mode = session.scope_mode == "select_commit" and "select_commit" or "current_commit"
    session.current_file_idx = 1
  end
end

--- Get the active file list (filtered by commit if one is selected).
---@return ReviewFile[]
function M.active_files()
  if not session then
    return {}
  end
  if M.uses_commit_scope() then
    local commit = session.commits[session.current_commit_idx]
    if commit and commit.files then
      return commit.files
    end
    return {}
  end
  local result = {}
  for _, file in ipairs(session.files) do
    table.insert(result, file)
  end
  for _, file in ipairs(session.untracked_files or {}) do
    table.insert(result, file)
  end
  return result
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

---@return ReviewFile[]
function M.all_tracked_files()
  if not session then
    return {}
  end
  return session.files
end

---@return ReviewFile[]
function M.untracked_files()
  if not session then
    return {}
  end
  return session.untracked_files or {}
end

---@return ReviewFile[]
function M.all_files()
  if not session then
    return {}
  end
  local result = {}
  for _, file in ipairs(session.files) do
    table.insert(result, file)
  end
  for _, file in ipairs(session.untracked_files or {}) do
    table.insert(result, file)
  end
  return result
end

---@param sha string
---@return boolean
function M.has_commit(sha)
  if not session or not sha then
    return false
  end
  for _, commit in ipairs(session.commits) do
    if commit.sha == sha then
      return true
    end
  end
  return false
end

---@param note ReviewNote
---@return boolean
local function has_gitbutler_scope(note)
  if not session or not note.gitbutler then
    return true
  end
  local note_gb = note.gitbutler
  for _, commit in ipairs(session.commits or {}) do
    local gb = commit.gitbutler or {}
    if note_gb.kind == gb.kind then
      if note_gb.kind == "unassigned" then
        return true
      end
      if note_gb.branch_cli_id and note_gb.branch_cli_id == gb.branch_cli_id then
        return true
      end
      if note_gb.branch_name and note_gb.branch_name == gb.branch_name then
        return true
      end
    end
    if note.commit_sha and commit.sha == note.commit_sha then
      return true
    end
  end
  return false
end

---@return string|nil, string|nil
function M.context_signature()
  if not session then
    return nil, nil
  end
  return session.repo_root, session.branch
end

---@return boolean
function M.session_matches_git()
  if not session then
    return true
  end
  local git = require("review.git")
  return session.repo_root == git.root() and session.branch == (git.current_branch() or "HEAD")
end

---@return boolean
function M.session_matches_vcs()
  if not session then
    return true
  end
  if session.vcs == "gitbutler" then
    local gitbutler = require("review.gitbutler")
    return session.repo_root == require("review.git").root() and gitbutler.is_workspace()
  end
  return M.session_matches_git()
end

---@param reason string|nil
function M.set_remote_context_stale(reason)
  if session then
    session.remote_context_stale = reason
  end
end

---@return string|nil
function M.remote_context_stale_reason()
  return session and session.remote_context_stale or nil
end

--- Add a local note.
---@param file_path string
---@param line number
---@param body string
---@param end_line number|nil
---@param side string|nil  "old"|"new", defaults to "new"
---@param note_type string|nil  "comment"|"suggestion", defaults to "comment"
---@param opts table|nil
function M.add_note(file_path, line, body, end_line, side, note_type, opts)
  if not session then
    return
  end
  opts = opts or {}
  local commit = M.uses_commit_scope() and M.current_commit() or nil
  local note = {
    id = next_note_id,
    file_path = file_path,
    line = line,
    end_line = end_line,
    side = side or "new",
    is_general = opts.is_general or false,
    target_kind = opts.target_kind
      or (opts.is_general and "discussion")
      or (file_path and line and "line")
      or (file_path and "file")
      or "unit",
    body = body,
    note_type = note_type or "comment",
    status = "draft",
    commit_sha = commit and commit.sha or nil,
    commit_short_sha = commit and commit.short_sha or nil,
    gitbutler = commit and commit.gitbutler and vim.deepcopy(commit.gitbutler) or nil,
    blame_context = opts.blame_context,
    log_context = opts.log_context,
    requested_action = opts.requested_action or opts.action,
    validation = opts.validation,
    url = nil,
  }
  local comparison_key = M.comparison_key()
  if comparison_key then
    note.comparison_key = comparison_key
    note.comparison = {
      vcs = session.vcs or "git",
      left_ref = session.left_ref or session.base_ref,
      right_ref = session.right_ref or session.head_ref,
      requested_ref = session.requested_ref,
    }
  end
  next_note_id = next_note_id + 1
  table.insert(session.notes, note)
  rebuild_note_indexes()
  get_storage().save(session)
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
  return session.note_index_by_file[file_path] or {}
end

---@param note ReviewNote
---@return boolean
local function note_has_active_file(note)
  if not note.file_path then
    return true
  end
  for _, file in ipairs(M.active_files()) do
    if file.path == note.file_path then
      return true
    end
  end
  return false
end

---@param note ReviewNote
---@return boolean
local function note_has_known_file(note)
  if not note.file_path then
    return true
  end
  for _, file in ipairs(M.all_files()) do
    if file.path == note.file_path then
      return true
    end
  end
  return false
end

---@param note ReviewNote
---@return boolean
function M.note_is_stale(note)
  if not session then
    return false
  end
  local active_comparison_key = M.comparison_key()
  if note.comparison_key and active_comparison_key and note.comparison_key ~= active_comparison_key then
    return true
  end
  local gitbutler_scope_matches = session.vcs == "gitbutler" and has_gitbutler_scope(note)
  if session.vcs == "gitbutler" and not gitbutler_scope_matches then
    return true
  end
  if note.commit_sha and not M.has_commit(note.commit_sha) and not gitbutler_scope_matches then
    return true
  end
  if note.status == "remote" then
    return session.remote_context_stale ~= nil
  end
  if not note_has_known_file(note) then
    return true
  end
  return false
end

---@param note ReviewNote
---@return boolean
function M.note_in_scope(note)
  if not session then
    return false
  end
  if M.note_is_stale(note) then
    return false
  end

  if note.status == "remote" then
    return true
  end

  if session.scope_mode == "all" then
    return true
  end

  local commit = M.current_commit()
  if not commit then
    return false
  end

  if session.vcs == "gitbutler" and note.gitbutler and commit.gitbutler then
    local note_gb = note.gitbutler
    local commit_gb = commit.gitbutler
    if note_gb.kind == commit_gb.kind then
      if note_gb.kind == "unassigned" then
        return true
      end
      if note_gb.branch_cli_id and note_gb.branch_cli_id == commit_gb.branch_cli_id then
        return true
      end
      if note_gb.branch_name and note_gb.branch_name == commit_gb.branch_name then
        return true
      end
    end
  end

  return note.commit_sha == commit.sha
end

---@return ReviewNote[], ReviewNote[]
function M.scoped_notes()
  if not session then
    return {}, {}
  end
  local scoped = {}
  local stale = {}
  for _, note in ipairs(session.notes) do
    if M.note_is_stale(note) then
      table.insert(stale, note)
    elseif M.note_in_scope(note) then
      table.insert(scoped, note)
    end
  end
  return scoped, stale
end

--- Remove a note by index in the session notes list.
---@param idx number
function M.remove_note(idx)
  if session and idx >= 1 and idx <= #session.notes then
    table.remove(session.notes, idx)
    rebuild_note_indexes()
    get_storage().save(session)
  end
end

--- Remove a note by ID.
---@param note_id number
function M.remove_note_by_id(note_id)
  local _, idx = M.get_note_by_id(note_id)
  if idx then
    M.remove_note(idx)
  end
end

--- Clear only draft notes, keeping remote and staged.
---@return number count  Number of drafts removed
function M.clear_drafts()
  if not session then
    return 0
  end
  local remaining = {}
  local count = 0
  for _, note in ipairs(session.notes) do
    if note.status == "draft" then
      count = count + 1
    else
      table.insert(remaining, note)
    end
  end
  if count > 0 then
    session.notes = remaining
    rebuild_note_indexes()
    get_storage().save(session)
  end
  return count
end

--- Count local notes (draft or staged), excluding remote comments.
---@return number
function M.local_note_count()
  if not session then
    return 0
  end
  local count = 0
  for _, note in ipairs(session.notes) do
    if note.status ~= "remote" then
      count = count + 1
    end
  end
  return count
end

--- Clear all local notes, keeping remote comments.
---@return number count  Number of local notes removed
function M.clear_local_notes()
  if not session then
    return 0
  end
  local remaining = {}
  local count = 0
  for _, note in ipairs(session.notes) do
    if note.status == "remote" then
      table.insert(remaining, note)
    else
      count = count + 1
    end
  end
  if count > 0 then
    session.notes = remaining
    rebuild_note_indexes()
    get_storage().save(session)
  end
  return count
end

--- Remove all remote comments from the session (before re-fetching).
function M.clear_remote_comments()
  if not session then
    return
  end
  local remaining = {}
  for _, note in ipairs(session.notes) do
    if note.status ~= "remote" then
      table.insert(remaining, note)
    end
  end
  session.notes = remaining
  rebuild_note_indexes()
end

--- Load remote comments (from forge) into the session.
---@param comments table[]  Raw comments from forge.fetch_comments_async()
function M.load_remote_comments(comments)
  if not session then
    return
  end
  for _, c in ipairs(comments) do
    -- Use the first reply's body as the note body for display
    local top_reply = c.replies and c.replies[1]
    local body = top_reply and top_reply.body or ""
    local author = top_reply and top_reply.author or "unknown"
    table.insert(session.notes, {
      id = next_note_id,
      file_path = c.file_path,
      line = c.line,
      end_line = c.end_line,
      side = c.side,
      body = body,
      note_type = "comment",
      status = "remote",
      url = c.url,
      author = author,
      replies = c.replies,
      thread_id = c.thread_id,
      thread_node_id = c.thread_node_id,
      resolved = c.resolved,
      outdated = c.outdated,
      is_general = c.is_general or false,
    })
    next_note_id = next_note_id + 1
  end
  rebuild_note_indexes()
end

--- Toggle a note between draft and staged by its ID.
---@param note_id number
function M.toggle_staged(note_id)
  if not session then
    return
  end
  for _, note in ipairs(session.notes) do
    if note.id == note_id then
      if note.status == "draft" then
        note.status = "staged"
      elseif note.status == "staged" then
        note.status = "draft"
      end
      rebuild_note_indexes()
      get_storage().save(session)
      return
    end
  end
end

--- Toggle a local note between unresolved and resolved.
---@param note_id number
function M.toggle_resolved(note_id)
  if not session then
    return
  end
  for _, note in ipairs(session.notes) do
    if note.id == note_id and note.status ~= "remote" then
      note.resolved = not note.resolved
      rebuild_note_indexes()
      get_storage().save(session)
      return
    end
  end
end

--- Publish staged notes: remove successfully posted ones from the session.
--- They will appear as remote comments on the next session open.
---@param url_map table|nil  Map of note_id -> url string
---@return number count  Number of successfully published notes
function M.publish_staged(url_map)
  if not session then
    return 0
  end
  url_map = url_map or {}
  local count = 0
  local remaining = {}
  for _, note in ipairs(session.notes) do
    if note.status == "staged" and url_map[note.id] then
      count = count + 1
      -- Don't keep — will show as remote on next open
    else
      table.insert(remaining, note)
    end
  end
  if count > 0 then
    session.notes = remaining
    rebuild_note_indexes()
    get_storage().save(session)
  end
  return count
end

--- Find a note by its ID.
---@param note_id number
---@return ReviewNote|nil, number|nil
function M.get_note_by_id(note_id)
  if not session then
    return nil, nil
  end
  local entry = session.note_index_by_id[note_id]
  return entry and entry.note or nil, entry and entry.idx or nil
end

---@param note_id number
---@param context table
---@return boolean
function M.attach_context_to_note(note_id, context)
  if not session or type(context) ~= "table" then
    return false
  end
  local note = M.get_note_by_id(note_id)
  if not note or note.status == "remote" then
    return false
  end
  local changed = false
  if context.blame_context and context.blame_context ~= "" then
    note.blame_context = context.blame_context
    changed = true
  end
  if context.log_context and context.log_context ~= "" then
    note.log_context = context.log_context
    changed = true
  end
  if changed then
    rebuild_note_indexes()
    get_storage().save(session)
  end
  return changed
end

--- Find a note by file path, line, and side.
---@param file_path string
---@param line number
---@param side string
---@return ReviewNote|nil, number|nil
function M.find_note_at(file_path, line, side)
  if not session then
    return nil, nil
  end
  local entries = session.note_index_by_location[note_location_key(file_path, line, side)]
  local entry = entries and entries[1] or nil
  return entry and entry.note or nil, entry and entry.idx or nil
end

--- Find all notes at file path, line, and side.
---@param file_path string
---@param line number
---@param side string
---@return table[]
function M.find_notes_at(file_path, line, side)
  if not session then
    return {}
  end
  return session.note_index_by_location[note_location_key(file_path, line, side)] or {}
end

---@param file_path string
---@param status string
function M.set_file_review_status(file_path, status)
  if not session or not file_path then
    return
  end
  session.file_review_status = session.file_review_status or {}
  session.file_review_status[file_path] = status
  get_storage().save(session)
end

---@param file_path string
---@return string
function M.get_file_review_status(file_path)
  if not session or not file_path then
    return "unreviewed"
  end
  session.file_review_status = session.file_review_status or {}
  return session.file_review_status[file_path] or "unreviewed"
end

---@param unit_id string
---@param status string
function M.set_unit_review_status(unit_id, status)
  if not session or not unit_id then
    return
  end
  session.unit_review_status = session.unit_review_status or {}
  session.unit_review_status[unit_id] = status
  get_storage().save(session)
end

---@param unit_id string
---@return string
function M.get_unit_review_status(unit_id)
  if not session or not unit_id then
    return "unreviewed"
  end
  session.unit_review_status = session.unit_review_status or {}
  return session.unit_review_status[unit_id] or "unreviewed"
end

---@param file ReviewFile
---@return string
local function file_review_signature(file)
  local parts = {
    path = file.path or "",
    status = file.status or "",
    hunks = {},
  }
  for _, hunk in ipairs(file.hunks or {}) do
    local hunk_parts = {
      header = hunk.header or "",
      old_start = hunk.old_start or 0,
      old_count = hunk.old_count or 0,
      new_start = hunk.new_start or 0,
      new_count = hunk.new_count or 0,
      lines = {},
    }
    for _, line in ipairs(hunk.lines or {}) do
      table.insert(hunk_parts.lines, {
        type = line.type or "",
        text = line.text or "",
        old_lnum = line.old_lnum or 0,
        new_lnum = line.new_lnum or 0,
      })
    end
    table.insert(parts.hunks, hunk_parts)
  end
  return vim.fn.sha256(vim.fn.json_encode(parts))
end

---@param files ReviewFile[]
---@return table<string,string>
local function snapshot_files(files)
  local snapshot = {}
  for _, file in ipairs(files or {}) do
    if file.path then
      snapshot[file.path] = file_review_signature(file)
    end
  end
  return snapshot
end

---@param ref string
function M.mark_review_snapshot(ref)
  if not session then
    return
  end
  session.review_snapshot_ref = ref
  session.review_snapshot_files = snapshot_files(M.all_files())
  get_storage().save(session)
end

---@param file ReviewFile
---@return "none"|"new"|"changed"|"unchanged"
function M.review_snapshot_file_state(file)
  if not session or not file or not file.path or not session.review_snapshot_files then
    return "none"
  end
  local previous = session.review_snapshot_files[file.path]
  if not previous then
    return "new"
  end
  if previous ~= file_review_signature(file) then
    return "changed"
  end
  return "unchanged"
end

---@return table
function M.get_ui_prefs()
  if not session then
    return {}
  end
  session.ui_prefs = session.ui_prefs or {}
  return session.ui_prefs
end

---@param prefs table
function M.update_ui_prefs(prefs)
  if not session or type(prefs) ~= "table" then
    return
  end
  session.ui_prefs = session.ui_prefs or {}
  for key, value in pairs(prefs) do
    session.ui_prefs[key] = value
  end
  get_storage().save(session)
end

--- Update a note's body by index and persist.
---@param idx number
---@param body string
function M.update_note_body(idx, body)
  if not session or not session.notes[idx] then
    return
  end
  session.notes[idx].body = body
  rebuild_note_indexes()
  get_storage().save(session)
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
    remote_id = nil,
  })
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
