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
  if not session or #session.notes == 0 then
    local path = storage_path()
    if path then
      vim.fn.delete(path)
    end
    return
  end

  local path = storage_path()
  if not path then
    return
  end

  local json = vim.fn.json_encode(session.notes)
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

  for _, note in ipairs(data) do
    note.id = note.id or 0
    note.note_type = note.note_type or "comment"
    note.side = note.side or "new"
    -- Migrate from old boolean published field
    if note.published ~= nil and not note.status then
      note.status = note.published and "published" or "draft"
      note.published = nil
    end
    note.status = note.status or "draft"
  end

  return data
end

--- Delete persisted notes for the current repo.
function M.clear()
  local path = storage_path()
  if path then
    vim.fn.delete(path)
  end
end

return M
