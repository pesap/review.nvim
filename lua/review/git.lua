--- Thin wrappers around git shell commands.
local M = {}

local cached_root = nil
local cached_head_exists = nil
local build_untracked_file

---@param cmd string[]
---@return string[]|nil out
---@return string|nil err
local function run_systemlist(cmd)
  local out = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then
    return nil, table.concat(out or {}, "\n")
  end
  return out, nil
end

---@param cmd string[]
---@return string|nil out
---@return string|nil err
local function run_system(cmd)
  local out = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    return nil, out
  end
  return out, nil
end

---@param section string
---@param entry table
---@return string
local function section_status(section, entry)
  if section == "staged" then
    return entry.index_status
  end
  if section == "unstaged" then
    return entry.worktree_status
  end
  return "?"
end

--- Get the git repository root for the current directory (cached).
---@return string|nil root  Absolute path, or nil if not in a git repo
function M.root()
  if cached_root then
    return cached_root
  end
  local out = run_systemlist({ "git", "rev-parse", "--show-toplevel" })
  if not out then
    return nil
  end
  cached_root = out[1]
  return cached_root
end

--- Get the current branch name.
---@return string|nil branch
function M.current_branch()
  local out = run_systemlist({ "git", "rev-parse", "--abbrev-ref", "HEAD" })
  if not out then
    return nil
  end
  return out[1]
end

local cached_default_branch = nil

--- Get the default remote branch (origin/main or origin/master, cached).
---@return string|nil ref
function M.default_branch()
  if cached_default_branch then
    return cached_default_branch
  end
  local out = run_systemlist({ "git", "symbolic-ref", "refs/remotes/origin/HEAD" })
  if out and out[1] then
    cached_default_branch = out[1]:match("refs/remotes/origin/(.+)")
    return cached_default_branch
  end
  local _ = run_systemlist({ "git", "rev-parse", "--verify", "origin/main" })
  if _ then
    cached_default_branch = "main"
    return cached_default_branch
  end
  _ = run_systemlist({ "git", "rev-parse", "--verify", "origin/master" })
  if _ then
    cached_default_branch = "master"
    return cached_default_branch
  end
  return nil
end

--- Get the unified diff text.
---@param ref string|nil  Git ref to diff against (default: HEAD)
---@return string diff_text
function M.diff(ref)
  local cmd = { "git", "diff" }
  if ref then
    table.insert(cmd, ref)
  end
  local out = run_system(cmd)
  if not out then
    return ""
  end
  return out
end

--- Get the remote URL for origin.
---@return string|nil url
function M.remote_url()
  local out = run_systemlist({ "git", "remote", "get-url", "origin" })
  if not out then
    return nil
  end
  return out[1]
end

--- Get the diff for a single commit.
---@param sha string  Commit SHA
---@return string diff_text
function M.commit_diff(sha)
  local out = run_system({ "git", "diff", sha .. "~1", sha })
  if not out then
    -- Might be the first commit (no parent), try show
    out = run_system({ "git", "show", "--format=", sha })
    if not out then
      return ""
    end
  end
  return out
end

---@return string[]
function M.untracked_paths()
  local out = run_systemlist({ "git", "ls-files", "--others", "--exclude-standard" })
  if not out then
    return {}
  end

  local result = {}
  for _, path in ipairs(out) do
    if path and path ~= "" then
      table.insert(result, path)
    end
  end
  return result
end

---@return boolean
function M.head_exists()
  if cached_head_exists ~= nil then
    return cached_head_exists
  end
  local out = run_systemlist({ "git", "rev-parse", "--verify", "HEAD" })
  cached_head_exists = out ~= nil
  return cached_head_exists
end

---@return table[]
function M.status_entries()
  local out = run_systemlist({ "git", "status", "--porcelain=v1", "--untracked-files=all" })
  if not out then
    return {}
  end

  local entries = {}
  for _, line in ipairs(out) do
    if line ~= "" then
      local xy = line:sub(1, 2)
      local raw_path = line:sub(4)
      local original_path, path = raw_path:match("^(.-) %-%> (.+)$")
      path = path or raw_path
      local index_status = xy:sub(1, 1)
      local worktree_status = xy:sub(2, 2)
      local untracked = xy == "??"
      local ignored = xy == "!!"
      if not ignored then
        table.insert(entries, {
          path = path,
          original_path = original_path,
          xy = xy,
          index_status = index_status,
          worktree_status = worktree_status,
          staged = not untracked and index_status ~= " ",
          unstaged = not untracked and worktree_status ~= " ",
          untracked = untracked,
          deleted = index_status == "D" or worktree_status == "D",
          renamed = index_status == "R" or worktree_status == "R",
        })
      end
    end
  end

  table.sort(entries, function(a, b)
    if a.path == b.path then
      return a.xy < b.xy
    end
    return a.path < b.path
  end)

  return entries
end

---@param path string
---@return table|nil
function M.status_entry(path)
  if not path or path == "" then
    return nil
  end
  for _, entry in ipairs(M.status_entries()) do
    if entry.path == path then
      return entry
    end
  end
  return nil
end

---@return {staged: table[], unstaged: table[], untracked: table[]}
function M.status_sections()
  local diff_mod = require("review.diff")
  local sections = {
    staged = {},
    unstaged = {},
    untracked = {},
  }

  for _, entry in ipairs(M.status_entries()) do
    if entry.untracked then
      local file = build_untracked_file(entry.path)
      file.git_section = "untracked"
      file.git_status = "?"
      file.git_status_entry = entry
      table.insert(sections.untracked, file)
    else
      for _, section in ipairs({ "staged", "unstaged" }) do
        local include = (section == "staged" and entry.staged) or (section == "unstaged" and entry.unstaged)
        if include then
          local cmd = { "git", "diff" }
          if section == "staged" then
            table.insert(cmd, "--cached")
          end
          table.insert(cmd, "--")
          table.insert(cmd, entry.path)
          local diff_text = run_system(cmd) or ""
          local parsed = diff_mod.parse(diff_text)
          local file = parsed[1]
            or {
              path = entry.path,
              status = section_status(section, entry),
              hunks = {},
            }
          file.path = file.path ~= "" and file.path or entry.path
          file.status = section_status(section, entry)
          file.git_section = section
          file.git_status = section_status(section, entry)
          file.git_status_entry = entry
          table.insert(sections[section], file)
        end
      end
    end
  end

  return sections
end

---@param path string
---@return ReviewFile
build_untracked_file = function(path)
  local root = M.root()
  local abs_path = root and (root .. "/" .. path) or path
  local ok, lines = pcall(vim.fn.readfile, abs_path)
  if not ok or type(lines) ~= "table" then
    lines = { "[unreadable file]" }
  end

  local hunk_lines = {}
  for idx, text in ipairs(lines) do
    table.insert(hunk_lines, {
      type = "add",
      text = text,
      old_lnum = nil,
      new_lnum = idx,
    })
  end

  local line_count = #hunk_lines
  return {
    path = path,
    status = "?",
    untracked = true,
    hunks = {
      {
        header = string.format("@@ -0,0 +1,%d @@", line_count),
        old_start = 0,
        old_count = 0,
        new_start = 1,
        new_count = line_count,
        lines = hunk_lines,
      },
    },
  }
end

---@return ReviewFile[]
function M.untracked_files()
  local result = {}
  for _, path in ipairs(M.untracked_paths()) do
    table.insert(result, build_untracked_file(path))
  end
  return result
end

---@return boolean
function M.has_fugitive()
  return vim.fn.exists(":Git") == 2
end

---@return {buf:number, win:number}|nil
---@return string|nil
function M.open_fugitive_status()
  if not M.has_fugitive() then
    return nil, "vim-fugitive is not installed"
  end

  local tab = vim.api.nvim_get_current_tabpage()

  local ok, err = pcall(vim.cmd, "silent keepalt Git")
  if not ok then
    return nil, tostring(err)
  end

  local current_buf = vim.api.nvim_get_current_buf()
  local current_name = vim.api.nvim_buf_get_name(current_buf)
  local current_ft = vim.bo[current_buf].filetype
  if current_name:match("^fugitive://") or current_ft == "fugitive" then
    return {
      buf = current_buf,
      win = vim.api.nvim_get_current_win(),
    }, nil
  end

  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if vim.api.nvim_win_is_valid(win) then
      local buf = vim.api.nvim_win_get_buf(win)
      local name = vim.api.nvim_buf_get_name(buf)
      local ft = vim.bo[buf].filetype
      if name:match("^fugitive://") or ft == "fugitive" then
        return {
          buf = buf,
          win = win,
        }, nil
      end
    end
  end

  return {
    buf = current_buf,
    win = vim.api.nvim_get_current_win(),
  }, nil
end

--- List commits in a range.
---@param base_ref string  Base ref (e.g. "main", "HEAD~5")
---@param head_ref string|nil  Head ref (default: "HEAD")
---@return ReviewCommit[]
function M.log(base_ref, head_ref)
  head_ref = head_ref or "HEAD"
  local range = base_ref .. ".." .. head_ref
  -- Format: sha<TAB>short_msg<TAB>author_name
  local out = run_systemlist({
    "git",
    "log",
    "--format=%H\t%s\t%an",
    range,
  })
  if not out then
    return {}
  end

  local commits = {}
  for _, line in ipairs(out) do
    local sha, message, author = line:match("^(%S+)\t(.-)\t(.+)$")
    if sha then
      table.insert(commits, {
        sha = sha,
        short_sha = sha:sub(1, 7),
        message = message,
        author = author,
      })
    end
  end
  return commits
end

---@param path string
---@return boolean ok
---@return string|nil err
function M.stage_path(path)
  local _, err = run_system({ "git", "add", "--", path })
  return err == nil, err
end

---@param path string
---@param opts table|nil
---@return boolean ok
---@return string|nil err
function M.unstage_path(path, opts)
  opts = opts or {}
  if opts.new_file or not M.head_exists() then
    local _, err = run_system({ "git", "rm", "--cached", "--quiet", "--", path })
    return err == nil, err
  end
  local _, err = run_system({ "git", "reset", "--quiet", "HEAD", "--", path })
  return err == nil, err
end

---@param path string
---@return boolean ok
---@return string|nil err
function M.restore_path(path)
  local _, err = run_system({ "git", "restore", "--worktree", "--", path })
  return err == nil, err
end

---@param path string
---@return boolean ok
---@return string|nil err
function M.restore_staged_path(path)
  local _, err = run_system({ "git", "restore", "--staged", "--worktree", "--source=HEAD", "--", path })
  return err == nil, err
end

---@param path string
---@return boolean ok
---@return string|nil err
function M.remove_path(path)
  local root = M.root()
  local target = root and (root .. "/" .. path) or path
  local ok, err = pcall(vim.fn.delete, target)
  if not ok or err ~= 0 then
    return false, "Could not delete file"
  end
  return true, nil
end

---@param message string|nil
---@param opts table|nil
---@return boolean ok
---@return string|nil err
function M.commit(message, opts)
  opts = opts or {}
  local cmd = { "git", "commit" }
  if opts.amend then
    table.insert(cmd, "--amend")
  end

  if message and message:match("%S") then
    table.insert(cmd, "-m")
    table.insert(cmd, message)
  elseif opts.amend then
    table.insert(cmd, "--no-edit")
  end

  local _, err = run_system(cmd)
  return err == nil, err
end

---@param sha string
---@return boolean ok
---@return string|nil err
function M.fixup_commit(sha)
  local _, err = run_system({ "git", "commit", "--fixup=" .. sha })
  return err == nil, err
end

--- Detect the forge provider from a hostname.
---@param host string
---@return string|nil provider  "github"|"gitlab"
local function detect_provider(host)
  if not host then
    return nil
  end
  host = host:lower()
  if host:find("github") then
    return "github"
  end
  if host:find("gitlab") then
    return "gitlab"
  end
  return nil
end

--- Parse forge, owner, and repo from the remote URL.
--- Supports GitHub and GitLab, including subgroup paths.
--- For other self-hosted instances, set `provider` in the plugin config.
---@return {forge: string, owner: string, repo: string, host: string}|nil
function M.parse_remote()
  local url = M.remote_url()
  if not url then
    return nil
  end

  local clean = vim.trim(url):gsub("%.git%s*$", "")
  local host, path

  -- SSH: git@<host>:<path> (optionally with .git already stripped above)
  host, path = clean:match("^git@([^:]+):(.+)$")
  if not host then
    host, path = clean:match("^ssh://git@([^/]+)/(.+)$")
  end

  -- HTTPS: https://<host>/<path>
  if not host then
    host, path = clean:match("^https?://([^/]+)/(.+)$")
  end

  if not host or not path then
    return nil
  end

  local owner, repo = path:match("^(.+)/([^/]+)$")
  if not owner or not repo then
    return nil
  end

  -- Allow config override for self-hosted instances without "gitlab" in hostname
  local config = require("review").config or {}
  local provider = config.provider or detect_provider(host)
  if not provider then
    return nil
  end

  return {
    forge = provider,
    owner = owner,
    repo = repo,
    host = host,
  }
end

--- Invalidate all cached git values.
function M.invalidate_cache()
  cached_root = nil
  cached_default_branch = nil
  cached_head_exists = nil
end

return M
