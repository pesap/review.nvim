--- Hunk CLI integration.
--- Uses Hunk as the diff surface and review.nvim as the command/controller layer.
local M = {}

local function notify_missing()
  vim.notify("hunk executable not found. Install with: npm i -g hunkdiff", vim.log.levels.ERROR)
end

---@param args string[]
---@return string[]
local function hunk_diff_cmd(args)
  local cmd = { "hunk", "diff" }
  vim.list_extend(cmd, args or {})
  return cmd
end

---@param root string
---@param args string[]
---@return boolean
local function reload_existing_session(root, args)
  local cmd = { "hunk", "session", "reload", "--repo", root, "--", "diff" }
  vim.list_extend(cmd, args or {})

  local out = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    return false
  end

  local msg = vim.trim(out)
  if msg ~= "" then
    vim.notify(msg, vim.log.levels.INFO)
  else
    vim.notify("Reloaded Hunk review session", vim.log.levels.INFO)
  end
  return true
end

---@param root string
---@param args string[]
local function open_terminal_session(root, args)
  vim.cmd("tabnew")
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].bufhidden = "wipe"
  vim.fn.termopen(hunk_diff_cmd(args), { cwd = root })
  vim.cmd("startinsert")
end

--- Open or reload a Hunk-backed review session.
---@param args string[]|nil
function M.open(args)
  args = args or {}

  if vim.fn.executable("hunk") ~= 1 then
    notify_missing()
    return
  end

  local git = require("review.git")
  local root = git.root()
  if not root then
    vim.notify("Not in a git repository", vim.log.levels.ERROR)
    return
  end

  if reload_existing_session(root, args) then
    return
  end

  open_terminal_session(root, args)
end

return M
