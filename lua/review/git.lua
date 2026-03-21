--- Thin wrappers around git shell commands.
local M = {}

--- Get the git repository root for the current directory.
---@return string|nil root  Absolute path, or nil if not in a git repo
function M.root()
  local out = vim.fn.systemlist({ "git", "rev-parse", "--show-toplevel" })
  if vim.v.shell_error ~= 0 then
    return nil
  end
  return out[1]
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

--- Get the default remote branch (origin/main or origin/master).
---@return string|nil ref
function M.default_branch()
  -- Try to get the remote HEAD reference
  local out = vim.fn.systemlist({ "git", "symbolic-ref", "refs/remotes/origin/HEAD" })
  if vim.v.shell_error == 0 and out[1] then
    -- Returns something like "refs/remotes/origin/main"
    return out[1]:match("refs/remotes/origin/(.+)")
  end
  -- Fallback: check if main or master exists
  local check_main = vim.fn.systemlist({ "git", "rev-parse", "--verify", "origin/main" })
  if vim.v.shell_error == 0 then
    return "main"
  end
  local check_master = vim.fn.systemlist({ "git", "rev-parse", "--verify", "origin/master" })
  if vim.v.shell_error == 0 then
    return "master"
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
    "--reverse",
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

--- Parse forge, owner, and repo from the remote URL.
---@return {forge: string, owner: string, repo: string}|nil
function M.parse_remote()
  local url = M.remote_url()
  if not url then
    return nil
  end

  -- GitHub SSH: git@github.com:owner/repo.git
  local owner, repo = url:match("git@github%.com:([^/]+)/([^/%.]+)")
  if owner then
    return { forge = "github", owner = owner, repo = repo }
  end
  -- GitHub HTTPS: https://github.com/owner/repo.git
  owner, repo = url:match("github%.com/([^/]+)/([^/%.]+)")
  if owner then
    return { forge = "github", owner = owner, repo = repo }
  end

  -- GitLab SSH: git@gitlab.com:owner/repo.git (or self-hosted)
  local host
  host, owner, repo = url:match("git@([^:]*gitlab[^:]*):([^/]+)/([^/%.]+)")
  if owner then
    return { forge = "gitlab", owner = owner, repo = repo, host = host }
  end
  -- GitLab HTTPS: https://gitlab.com/owner/repo.git (or self-hosted)
  host, owner, repo = url:match("https?://([^/]*gitlab[^/]*)/([^/]+)/([^/%.]+)")
  if owner then
    return { forge = "gitlab", owner = owner, repo = repo, host = host }
  end

  return nil
end

return M
