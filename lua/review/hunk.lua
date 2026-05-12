--- Hunk CLI integration.
--- Uses Hunk as the diff surface and review.nvim as the session/comment controller.
local M = {}

local MANAGED_AUTHOR = "review.nvim"

local function notify_missing()
  vim.notify("hunk executable not found. Install with: npm i -g hunkdiff", vim.log.levels.ERROR)
end

local function is_no_session_error(err)
  return err and err:match("No active Hunk sessions")
end

---@return string|nil
local function repo_root()
  return require("review.git").root()
end

---@return boolean
function M.is_available()
  return vim.fn.executable("hunk") == 1
end

---@param value string|nil
---@return string|nil
local function trim_to_nil(value)
  if not value then
    return nil
  end
  local trimmed = vim.trim(value)
  if trimmed == "" then
    return nil
  end
  return trimmed
end

---@param cmd string[]
---@param input string|nil
---@return string|nil out, string|nil err
local function run(cmd, input)
  local out = vim.fn.system(cmd, input)
  local exit_code = vim.v.shell_error

  if type(out) == "table" then
    exit_code = out.code or exit_code
    out = out.stdout or out.stderr or ""
  end

  if exit_code ~= 0 then
    return nil, trim_to_nil(out) or ("Command failed: " .. table.concat(cmd, " "))
  end
  return out, nil
end

---@param raw string|nil
---@return table|nil
local function decode_json(raw)
  if not raw then
    return nil
  end
  local ok, data = pcall(vim.fn.json_decode, raw)
  if not ok or type(data) ~= "table" then
    return nil
  end
  return data
end

---@param args string[]
---@return string[]
local function hunk_diff_cmd(args)
  local cmd = { "hunk", "diff" }
  vim.list_extend(cmd, args or {})
  return cmd
end

---@param root string
---@param subcommand string[]
---@return string[]
local function session_cmd(root, subcommand)
  local cmd = { "hunk", "session" }
  vim.list_extend(cmd, subcommand)
  vim.list_extend(cmd, { "--repo", root })
  return cmd
end

---@param note ReviewNote
---@return string
local function note_summary(note)
  local body = trim_to_nil(note.body) or ""
  local first = body:match("([^\n]+)") or ""
  if first ~= "" then
    return first
  end
  local location = note.file_path or "general"
  return string.format("%s:%s", location, tostring(note.line or "?"))
end

---@param note ReviewNote
---@return string|nil
local function note_rationale(note)
  local body = trim_to_nil(note.body)
  if not body then
    return nil
  end
  local first = body:match("([^\n]+)")
  if not first then
    return nil
  end
  local rest = trim_to_nil(body:sub(#first + 1))
  return rest
end

---@param root string
---@param args string[]
---@return boolean, string|nil
local function reload_existing_session(root, args)
  local cmd = session_cmd(root, { "reload", "--", "diff" })
  vim.list_extend(cmd, args or {})

  local out, err = run(cmd)
  if not out then
    return false, err
  end

  local msg = trim_to_nil(out)
  if msg then
    vim.notify(msg, vim.log.levels.INFO)
  else
    vim.notify("Reloaded Hunk review session", vim.log.levels.INFO)
  end
  return true, nil
end

---@param root string
---@param args string[]
local function open_terminal_session(root, args)
  vim.cmd("tabnew")
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "review-hunk"
  vim.fn.termopen(hunk_diff_cmd(args), { cwd = root })
  vim.cmd("startinsert")
end

---@return string|nil, string|nil
function M.ensure_root()
  if not M.is_available() then
    notify_missing()
    return nil, "hunk executable not found"
  end

  local root = repo_root()
  if not root then
    vim.notify("Not in a git repository", vim.log.levels.ERROR)
    return nil, "not in a git repository"
  end

  return root, nil
end

---@param args string[]|nil
---@return boolean, string|nil
function M.open(args)
  args = args or {}

  local root, err = M.ensure_root()
  if not root then
    return false, err
  end

  local reloaded = reload_existing_session(root, args)
  if reloaded then
    return true, nil
  end

  open_terminal_session(root, args)
  return true, nil
end

---@param opts table|nil
---@return boolean, string|nil
function M.session_exists(opts)
  opts = opts or {}
  local root, err = M.ensure_root()
  if not root then
    return false, err
  end

  local out, run_err = run(session_cmd(root, { "get", "--json" }))
  if not out then
    if not opts.strict and is_no_session_error(run_err) then
      return false, nil
    end
    return false, run_err
  end

  local data = decode_json(out)
  if not data then
    return false, "Failed to parse Hunk session metadata"
  end
  return true, nil
end

---@return table|nil, string|nil
function M.context()
  local root, err = M.ensure_root()
  if not root then
    return nil, err
  end

  local cmd = session_cmd(root, { "context", "--json" })
  local out, run_err = run(cmd)
  if not out then
    return nil, run_err
  end

  local data = decode_json(out)
  if not data then
    return nil, "Failed to parse hunk session context"
  end
  return data.context or data, nil
end

---@param context table
---@param keys string[]
---@return any
local function pick(context, keys)
  for _, key in ipairs(keys) do
    local value = context[key]
    if value ~= nil and value ~= vim.NIL then
      return value
    end
  end
  return nil
end

---@param context table
---@return table|nil, string|nil
function M.context_target(context)
  context = context or {}
  local focus = context.focus
  local location = context.location
  local diff = context.diff
  local selected_file = context.selectedFile
  local selected_hunk = context.selectedHunk

  local file_path = pick(context, { "filePath", "file", "path" })
    or (type(focus) == "table" and pick(focus, { "filePath", "file", "path" }))
    or (type(location) == "table" and pick(location, { "filePath", "file", "path" }))
    or (type(diff) == "table" and pick(diff, { "filePath", "file", "path" }))
    or (type(selected_file) == "table" and pick(selected_file, { "filePath", "file", "path" }))

  local new_line = pick(context, { "newLine", "new_line" })
    or (type(focus) == "table" and pick(focus, { "newLine", "new_line" }))
    or (type(location) == "table" and pick(location, { "newLine", "new_line" }))
    or (type(selected_hunk) == "table" and type(selected_hunk.newRange) == "table" and selected_hunk.newRange[1])

  local old_line = pick(context, { "oldLine", "old_line" })
    or (type(focus) == "table" and pick(focus, { "oldLine", "old_line" }))
    or (type(location) == "table" and pick(location, { "oldLine", "old_line" }))
    or (type(selected_hunk) == "table" and type(selected_hunk.oldRange) == "table" and selected_hunk.oldRange[1])

  local side = pick(context, { "side" })
    or (type(focus) == "table" and pick(focus, { "side" }))
    or (type(location) == "table" and pick(location, { "side" }))

  if not file_path then
    return nil, "Hunk context did not include a file path"
  end

  if not new_line and not old_line then
    local line = pick(context, { "line" })
      or (type(focus) == "table" and pick(focus, { "line" }))
      or (type(location) == "table" and pick(location, { "line" }))
    if side == "old" then
      old_line = line
    else
      new_line = line
    end
  end

  local target_line
  if old_line and not new_line then
    side = "old"
    target_line = tonumber(old_line)
  else
    side = "new"
    target_line = tonumber(new_line or old_line)
  end

  if not target_line then
    return nil, "Hunk context did not include a diff line"
  end

  return {
    file_path = file_path,
    line = target_line,
    side = side,
  }, nil
end

---@return table|nil, string|nil
function M.current_target()
  local context, err = M.context()
  if not context then
    return nil, err
  end
  return M.context_target(context)
end

---@param file_path string
---@param line number
---@param side string|nil
---@return boolean, string|nil
function M.navigate(file_path, line, side)
  local root, err = M.ensure_root()
  if not root then
    return false, err
  end

  local cmd = session_cmd(root, { "navigate", "--file", file_path })
  if side == "old" then
    vim.list_extend(cmd, { "--old-line", tostring(line) })
  else
    vim.list_extend(cmd, { "--new-line", tostring(line) })
  end

  local _, run_err = run(cmd)
  if run_err then
    return false, run_err
  end
  return true, nil
end

---@param comments table[]
---@param opts table|nil
---@return boolean, string|nil
function M.sync_comments(comments, opts)
  opts = opts or {}
  local root, err = M.ensure_root()
  if not root then
    return false, err
  end

  if not opts.skip_session_check then
    local exists, exists_err = M.session_exists({ strict = opts.strict_session })
    if exists_err then
      return false, exists_err
    end
    if not exists then
      return true, nil
    end
  end

  local clear_cmd = session_cmd(root, { "comment", "clear", "--yes" })
  local _, clear_err = run(clear_cmd)
  if clear_err then
    return false, clear_err
  end

  local batch = {}
  for _, note in ipairs(comments or {}) do
    if note.file_path and note.line then
      local item = {
        filePath = note.file_path,
        summary = note_summary(note),
        author = note.author or MANAGED_AUTHOR,
      }
      local rationale = note_rationale(note)
      if rationale then
        item.rationale = rationale
      end
      if note.side == "old" then
        item.oldLine = note.line
      else
        item.newLine = note.line
      end
      table.insert(batch, item)
    end
  end

  if #batch == 0 then
    return true, nil
  end

  local json = vim.fn.json_encode({ comments = batch })
  local apply_cmd = session_cmd(root, { "comment", "apply", "--stdin" })
  local _, apply_err = run(apply_cmd, json)
  if apply_err then
    return false, apply_err
  end
  return true, nil
end

return M
