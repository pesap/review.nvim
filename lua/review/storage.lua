--- Persistence layer for review notes.
--- Notes are stored as JSON in vim.fn.stdpath("data")/review/.
local M = {}

local cached_path = nil

--- Get the storage file path for the current git repo (cached after first call).
---@return string|nil
local function storage_path()
  if cached_path then
    return cached_path
  end

  local git = require("review.git")
  local root = git.root()
  if not root then
    return nil
  end

  local dir = vim.fn.stdpath("data") .. "/review"
  vim.fn.mkdir(dir, "p")

  local key = root:gsub("[/\\:]", "_")
  cached_path = dir .. "/" .. key .. ".json"
  return cached_path
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

  if #to_save == 0 then
    vim.fn.delete(path)
    return
  end

  local json = vim.fn.json_encode(to_save)
  vim.fn.writefile({ json }, path)
end

--- Load persisted notes from disk.
---@return ReviewNote[]
function M.load()
  local path = storage_path()
  if not path or vim.fn.filereadable(path) ~= 1 then
    return {}
  end

  local lines = vim.fn.readfile(path)
  if #lines == 0 then
    return {}
  end

  local ok, data = pcall(vim.fn.json_decode, table.concat(lines, "\n"))
  if not ok or type(data) ~= "table" then
    return {}
  end

  local valid_status = { draft = true, staged = true }
  local result = {}
  for _, note in ipairs(data) do
    note.id = note.id or 0
    note.note_type = note.note_type or "comment"
    note.side = note.side or "new"
    note.status = note.status or "draft"
    -- Drop notes with stale statuses (e.g. "published" from old versions)
    if valid_status[note.status] then
      table.insert(result, note)
    end
  end

  return result
end

return M
