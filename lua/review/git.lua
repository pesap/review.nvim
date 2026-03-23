--- Thin wrappers around git shell commands.
local M = {}

local cached_root = nil

--- Get the git repository root for the current directory (cached).
---@return string|nil root  Absolute path, or nil if not in a git repo
function M.root()
  if cached_root then
    return cached_root
  end
  local out = vim.fn.systemlist({ "git", "rev-parse", "--show-toplevel" })
  if vim.v.shell_error ~= 0 then
    return nil
  end
  cached_root = out[1]
  return cached_root
end

--- Get the current branch name.
---@return string|nil branch
function M.current_branch()
  local out = vim.fn.systemlist({ "git", "rev-parse", "--abbrev-ref", "HEAD" })
  if vim.v.shell_error ~= 0 then
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
  local out = vim.fn.systemlist({ "git", "symbolic-ref", "refs/remotes/origin/HEAD" })
  if vim.v.shell_error == 0 and out[1] then
    cached_default_branch = out[1]:match("refs/remotes/origin/(.+)")
    return cached_default_branch
  end
  local _ = vim.fn.systemlist({ "git", "rev-parse", "--verify", "origin/main" })
  if vim.v.shell_error == 0 then
    cached_default_branch = "main"
    return cached_default_branch
  end
  _ = vim.fn.systemlist({ "git", "rev-parse", "--verify", "origin/master" })
  if vim.v.shell_error == 0 then
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
  local out = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    return ""
  end
  return out
end

--- Get the remote URL for origin.
---@return string|nil url
function M.remote_url()
  local out = vim.fn.systemlist({ "git", "remote", "get-url", "origin" })
  if vim.v.shell_error ~= 0 then
    return nil
  end
  return out[1]
end

--- Get the diff for a single commit.
---@param sha string  Commit SHA
---@return string diff_text
function M.commit_diff(sha)
  local out = vim.fn.system({ "git", "diff", sha .. "~1", sha })
  if vim.v.shell_error ~= 0 then
    -- Might be the first commit (no parent), try show
    out = vim.fn.system({ "git", "show", "--format=", sha })
    if vim.v.shell_error ~= 0 then
      return ""
    end
  end
  return out
end

--- List commits in a range.
---@param base_ref string  Base ref (e.g. "main", "HEAD~5")
---@param head_ref string|nil  Head ref (default: "HEAD")
---@return ReviewCommit[]
function M.log(base_ref, head_ref)
  head_ref = head_ref or "HEAD"
  local range = base_ref .. ".." .. head_ref
  -- Format: sha<TAB>short_msg<TAB>author_name
  local out = vim.fn.systemlist({
    "git",
    "log",
    "--format=%H\t%s\t%an",
    range,
  })
  if vim.v.shell_error ~= 0 then
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
end

return M
