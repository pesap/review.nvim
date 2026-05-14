--- GitButler CLI adapter.
local M = {}

local cached_status = nil
local cached_root = nil
local test_runner = nil

local function run_system(cmd)
  if test_runner then
    local out, code = test_runner(cmd)
    if code and code ~= 0 then
      return nil, out
    end
    return out, nil
  end
  local out = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    return nil, out
  end
  return out, nil
end

---@param runner fun(cmd:string[]): string, integer|nil
function M._set_runner(runner)
  test_runner = runner
  M.invalidate_cache()
end

local function run_json(cmd)
  local out, err = run_system(cmd)
  if not out then
    return nil, err
  end
  local ok, data = pcall(vim.fn.json_decode, out)
  if not ok or type(data) ~= "table" then
    return nil, "Failed to parse GitButler JSON"
  end
  return data, nil
end

local function current_root()
  local git = require("review.git")
  return git.root()
end

local function denull(value)
  if value == vim.NIL then
    return nil
  end
  return value
end

---@return boolean
function M.available()
  return vim.fn.executable("but") == 1
end

---@return table|nil status, string|nil err
function M.status()
  local root = current_root()
  if cached_status and cached_root == root then
    return cached_status, nil
  end
  if not M.available() then
    return nil, "GitButler CLI is not installed"
  end
  local data, err = run_json({ "but", "-j", "status" })
  if not data then
    return nil, err
  end
  cached_root = root
  cached_status = data
  return cached_status, nil
end

---@return boolean
function M.is_workspace()
  if not M.available() then
    return false
  end
  local branch = require("review.git").current_branch()
  if branch ~= "gitbutler/workspace" then
    return false
  end
  return M.status() ~= nil
end

---@param value string|nil
---@return string
local function status_code(value)
  if value == "added" then
    return "A"
  end
  if value == "deleted" then
    return "D"
  end
  if value == "renamed" then
    return "R"
  end
  if value == "modified" then
    return "M"
  end
  return "?"
end

---@param hunk table
---@return ReviewHunk
local function parse_json_hunk(hunk)
  local lines = {}
  local old_lnum = tonumber(hunk.oldStart) or 0
  local new_lnum = tonumber(hunk.newStart) or 0
  local raw = hunk.diff or ""
  local header = raw:match("^([^\n]+)")
    or string.format(
      "@@ -%d,%d +%d,%d @@",
      old_lnum,
      tonumber(hunk.oldLines) or 0,
      new_lnum,
      tonumber(hunk.newLines) or 0
    )

  for line in (raw .. "\n"):gmatch("([^\n]*)\n") do
    if line ~= "" and not line:match("^@@") then
      local prefix = line:sub(1, 1)
      local text = line:sub(2)
      if prefix == "+" then
        table.insert(lines, { type = "add", text = text, old_lnum = nil, new_lnum = new_lnum })
        new_lnum = new_lnum + 1
      elseif prefix == "-" then
        table.insert(lines, { type = "del", text = text, old_lnum = old_lnum, new_lnum = nil })
        old_lnum = old_lnum + 1
      elseif prefix == " " then
        table.insert(lines, { type = "ctx", text = text, old_lnum = old_lnum, new_lnum = new_lnum })
        old_lnum = old_lnum + 1
        new_lnum = new_lnum + 1
      elseif line:match("^\\ No newline") then
        -- Ignore diff metadata lines.
      else
        table.insert(lines, { type = "ctx", text = line, old_lnum = old_lnum, new_lnum = new_lnum })
        old_lnum = old_lnum + 1
        new_lnum = new_lnum + 1
      end
    end
  end

  return {
    header = header,
    old_start = tonumber(hunk.oldStart) or 0,
    old_count = tonumber(hunk.oldLines) or 0,
    new_start = tonumber(hunk.newStart) or 0,
    new_count = tonumber(hunk.newLines) or 0,
    lines = lines,
  }
end

---@param change table
---@param opts table|nil
---@return ReviewFile
local function change_to_file(change, opts)
  opts = opts or {}
  local path = change.path or change.filePath or ""
  local change_type = opts.change_types_by_path and opts.change_types_by_path[path]
  local file = {
    path = path,
    status = status_code(change_type or change.status or change.changeType),
    hunks = {},
    gitbutler = opts.gitbutler,
  }
  if opts.unassigned then
    file.gitbutler_unassigned = true
  end
  local diff = change.diff or {}
  for _, hunk in ipairs(diff.hunks or {}) do
    table.insert(file.hunks, parse_json_hunk(hunk))
  end
  return file
end

---@param target string|nil
---@param opts table|nil
---@return ReviewFile[]|nil files
---@return string|nil err
function M.diff_files(target, opts)
  local cmd = { "but", "-j", "diff" }
  if target then
    table.insert(cmd, target)
  end
  local data, err = run_json(cmd)
  if not data then
    return nil, err
  end
  if type(data.changes) ~= "table" then
    return nil, "GitButler diff output is missing changes"
  end
  local files = {}
  for _, change in ipairs(data.changes) do
    table.insert(files, change_to_file(change, opts))
  end
  return files, nil
end

local function change_key(file)
  local gb = file.gitbutler or {}
  local branch_key = gb.kind == "branch" and (gb.branch_cli_id or gb.branch_name or "branch") or (gb.kind or "")
  return table.concat({ file.path or "", file.status or "", branch_key }, "::")
end

local function merge_files(target, files)
  local seen = {}
  for _, existing in ipairs(target) do
    seen[change_key(existing)] = true
  end
  for _, file in ipairs(files) do
    local key = change_key(file)
    if not seen[key] then
      table.insert(target, file)
      seen[key] = true
    end
  end
end

---@param branch table
---@return table|nil scope
---@return string|nil err
local function branch_scope(branch)
  local files, err = M.diff_files(branch.cliId or branch.name, {
    gitbutler = {
      kind = "branch",
      branch_name = branch.name,
      branch_cli_id = branch.cliId,
      branch_status = branch.branchStatus,
      review_id = denull(branch.reviewId),
    },
  })
  if not files then
    return nil, err
  end
  if #files == 0 then
    return nil, nil
  end
  local first = branch.commits and branch.commits[1]
  local sha = first and first.commitId or branch.cliId or branch.name
  return {
    sha = sha,
    short_sha = (sha or branch.name):sub(1, 7),
    message = branch.name,
    author = first and first.authorName or "",
    files = files,
    gitbutler = {
      kind = "branch",
      branch_name = branch.name,
      branch_cli_id = branch.cliId,
      branch_status = branch.branchStatus,
      review_id = denull(branch.reviewId),
      unpublished = branch.branchStatus == "completelyUnpushed" or denull(branch.reviewId) == nil,
    },
  }
end

---@return {files: ReviewFile[], untracked_files: ReviewFile[], commits: ReviewCommit[], metadata: table}|nil result
---@return string|nil err
function M.workspace_review()
  local status, err = M.status()
  if not status then
    return nil, err
  end

  local files = {}
  local commits = {}
  for _, stack in ipairs(status.stacks or {}) do
    for _, branch in ipairs(stack.branches or {}) do
      local scope, scope_err = branch_scope(branch)
      if scope_err then
        return nil, scope_err
      end
      if scope then
        scope.gitbutler.stack_cli_id = stack.cliId
        table.insert(commits, scope)
        merge_files(files, scope.files)
      end
    end
  end

  local unassigned_change_types = {}
  for _, change in ipairs(status.unassignedChanges or {}) do
    local path = change.filePath or change.path
    if path then
      unassigned_change_types[path] = change.changeType or change.status
    end
  end
  local unassigned, unassigned_err = M.diff_files(nil, {
    unassigned = true,
    gitbutler = { kind = "unassigned" },
    change_types_by_path = unassigned_change_types,
  })
  if not unassigned then
    return nil, unassigned_err
  end
  if #unassigned > 0 then
    merge_files(files, unassigned)
    table.insert(commits, {
      sha = "gitbutler-unassigned",
      short_sha = "unassgn",
      message = "unassigned changes",
      author = "",
      files = unassigned,
      gitbutler = {
        kind = "unassigned",
        unpublished = true,
      },
    })
  end

  return {
    files = files,
    untracked_files = {},
    commits = commits,
    metadata = status,
  }, nil
end

---@param commit ReviewCommit|nil
---@return boolean
function M.scope_is_unpublished(commit)
  return commit and commit.gitbutler and commit.gitbutler.unpublished == true or false
end

function M.invalidate_cache()
  cached_status = nil
  cached_root = nil
end

return M
