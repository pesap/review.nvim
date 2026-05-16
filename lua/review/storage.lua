--- Persistence layer for review notes.
--- Notes are stored as JSON in vim.fn.stdpath("data")/review/.
local M = {}

local cached_path = nil
local cached_path_key = nil
local cached_remote_path = nil
local cached_remote_path_key = nil
local last_loaded_workspace_state = nil

---@param value any
---@return string|nil
local function key_part(value)
  if value == nil or value == "" then
    return nil
  end
  local text = tostring(value)
  if text:find("[\r\n]") or #text > 96 then
    return "sha256-" .. vim.fn.sha256(text):sub(1, 16)
  end
  return text
end

---@param parts string[]
---@param part any
local function add_key_part(parts, part)
  local value = key_part(part)
  if value then
    table.insert(parts, value)
  end
end

---@param key string
---@return string
local function sanitize_key(key)
  return key:gsub("[^%w%._%-]", "_")
end

---@param s ReviewSession|nil
---@return string
local function review_unit_key(s)
  if not s then
    return ""
  end
  local ids = {}
  for _, commit in ipairs(s.commits or {}) do
    if commit.gitbutler then
      table.insert(ids, commit.gitbutler.branch_cli_id or commit.gitbutler.branch_name or commit.gitbutler.kind or "")
    else
      table.insert(ids, commit.sha or commit.short_sha or "")
    end
  end
  table.sort(ids)
  return table.concat(ids, ",")
end

---@return string[]|nil
local function storage_keys()
  local git = require("review.git")
  local root = git.root()
  if not root then
    return nil
  end
  local branch = git.current_branch() or "HEAD"
  local branch_key = sanitize_key(root .. "::" .. branch)
  local keys = { branch_key }
  local ok, state = pcall(require, "review.state")
  if ok and state and type(state.get) == "function" then
    local s = state.get()
    local info = s and (s.forge_info or s.pr)
    local pr_number = info and (info.pr_number or info.number)
    if s then
      local v2_parts = { root, branch, tostring(s.mode or "local"), tostring(s.base_ref or "HEAD") }
      if pr_number then
        table.insert(v2_parts, "pr" .. tostring(pr_number))
      end

      local primary_parts = vim.deepcopy(v2_parts)
      add_key_part(primary_parts, "head")
      add_key_part(primary_parts, s.head_ref or s.requested_ref or s.workspace_signature or "worktree")
      local units = review_unit_key(s)
      if units ~= "" then
        add_key_part(primary_parts, "units")
        add_key_part(primary_parts, units)
      end

      keys = {
        sanitize_key(table.concat(primary_parts, "::")),
        sanitize_key(table.concat(v2_parts, "::")),
        branch_key,
      }
    end
  end
  return keys
end

---@return string|nil
local function storage_key()
  local keys = storage_keys()
  return keys and keys[1] or nil
end

---@return string
local function storage_dir()
  local dir = vim.fn.stdpath("data") .. "/review"
  vim.fn.mkdir(dir, "p")
  return dir
end

--- Get the storage file path for the current git repo (cached after first call).
---@return string|nil
local function storage_path()
  local key = storage_key()
  if not key then
    return nil
  end

  if cached_path and cached_path_key == key then
    return cached_path
  end

  cached_path = storage_dir() .. "/" .. key .. ".json"
  cached_path_key = key
  return cached_path
end

---@return string|nil
local function remote_cache_path()
  local key = storage_key()
  if not key then
    return nil
  end

  if cached_remote_path and cached_remote_path_key == key then
    return cached_remote_path
  end

  cached_remote_path = storage_dir() .. "/" .. key .. ".remote.json"
  cached_remote_path_key = key
  return cached_remote_path
end

--- Save session notes to disk.
---@param session ReviewSession
function M.save(session)
  local path = storage_path()
  if not path then
    return
  end

  -- Filter out remote notes — they come from the forge each session
  local to_save = {}
  if session then
    for _, note in ipairs(session.notes) do
      if note.status ~= "remote" then
        table.insert(to_save, note)
      end
    end
  end

  local payload = {
    version = 2,
    notes = to_save,
    file_review_status = session and session.file_review_status or {},
    unit_review_status = session and session.unit_review_status or {},
    review_snapshot_ref = session and session.review_snapshot_ref or nil,
    review_snapshot_files = session and session.review_snapshot_files or nil,
    ui_prefs = session and session.ui_prefs or {},
  }

  if
    #to_save == 0
    and vim.tbl_isempty(payload.file_review_status)
    and vim.tbl_isempty(payload.unit_review_status)
    and not payload.review_snapshot_ref
    and not payload.review_snapshot_files
    and vim.tbl_isempty(payload.ui_prefs)
  then
    vim.fn.delete(path)
    return
  end

  if vim.fn.filereadable(path) == 1 then
    pcall(vim.fn.writefile, vim.fn.readfile(path), path .. ".bak")
  end
  local json = vim.fn.json_encode(payload)
  vim.fn.writefile({ json }, path)
end

--- Load persisted notes from disk.
---@return ReviewNote[]
function M.load()
  local path
  local keys = storage_keys()
  if keys then
    for _, key in ipairs(keys) do
      local candidate = storage_dir() .. "/" .. key .. ".json"
      if vim.fn.filereadable(candidate) == 1 then
        path = candidate
        break
      end
    end
  else
    path = storage_path()
  end
  if not path or vim.fn.filereadable(path) ~= 1 then
    last_loaded_workspace_state = nil
    return {}
  end

  local lines = vim.fn.readfile(path)
  if #lines == 0 then
    return {}
  end

  local ok, data = pcall(vim.fn.json_decode, table.concat(lines, "\n"))
  if not ok or type(data) ~= "table" then
    last_loaded_workspace_state = nil
    pcall(vim.notify, "review.nvim note storage is corrupt: " .. path, vim.log.levels.WARN)
    return {}
  end

  local raw_notes = data.notes or data
  last_loaded_workspace_state = data.notes
      and {
        file_review_status = data.file_review_status or {},
        unit_review_status = data.unit_review_status or {},
        review_snapshot_ref = data.review_snapshot_ref,
        review_snapshot_files = data.review_snapshot_files,
        ui_prefs = data.ui_prefs or {},
      }
    or nil

  local valid_status = { draft = true, staged = true }
  local result = {}
  for _, note in ipairs(raw_notes) do
    note.id = note.id or 0
    note.note_type = note.note_type or "comment"
    note.side = note.side or "new"
    note.status = note.status or "draft"
    note.commit_sha = note.commit_sha or nil
    note.commit_short_sha = note.commit_short_sha or nil
    -- Drop notes with stale statuses (e.g. "published" from old versions)
    if valid_status[note.status] then
      table.insert(result, note)
    end
  end

  return result
end

---@return table|nil
function M.load_workspace_state()
  return last_loaded_workspace_state
end

---@param info table
---@param base_ref string|nil
---@param comments table[]
---@param summary table|nil
function M.save_remote_bundle(info, base_ref, comments, summary)
  local path = remote_cache_path()
  if not path or not info then
    return
  end

  local git = require("review.git")
  local payload = {
    branch = git.current_branch(),
    base_ref = base_ref,
    info = info,
    comments = comments or {},
    summary = summary,
    saved_at = os.time(),
  }

  local json = vim.fn.json_encode(payload)
  vim.fn.writefile({ json }, path)
end

---@param base_ref string|nil
---@return table|nil
function M.load_remote_bundle(base_ref)
  local path = remote_cache_path()
  if not path or vim.fn.filereadable(path) ~= 1 then
    return nil
  end

  local lines = vim.fn.readfile(path)
  if #lines == 0 then
    return nil
  end

  local ok, data = pcall(vim.fn.json_decode, table.concat(lines, "\n"))
  if not ok or type(data) ~= "table" or type(data.info) ~= "table" then
    return nil
  end

  local git = require("review.git")
  local current_branch = git.current_branch()
  if data.branch and current_branch and data.branch ~= current_branch then
    return nil
  end
  if base_ref and data.base_ref and data.base_ref ~= base_ref then
    return nil
  end

  data.comments = type(data.comments) == "table" and data.comments or {}
  data.summary = type(data.summary) == "table" and data.summary or nil
  return data
end

return M
