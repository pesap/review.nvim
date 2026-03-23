--- Provider abstraction for GitHub/GitLab forge APIs.
local M = {}

---@param cmd string[]
---@return table|nil data, string|nil err
local function run_json(cmd)
  local out = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    return nil, vim.trim(out)
  end
  local ok, data = pcall(vim.json.decode, out)
  if not ok then
    return nil, "Failed to parse JSON: " .. tostring(data)
  end
  return data, nil
end

-- ---------------------------------------------------------------------------
-- GitHub provider
-- ---------------------------------------------------------------------------

---@type ReviewProvider
local github = {
  name = "github",
  cli = "gh",
}

---@param owner string
---@param repo string
---@param number number|nil
---@return ReviewPR|nil pr, string|nil err
function github.fetch_mr(owner, repo, number)
  local cmd = { "gh", "pr", "view" }
  if number then
    table.insert(cmd, tostring(number))
  end
  vim.list_extend(cmd, {
    "--repo",
    owner .. "/" .. repo,
    "--json",
    "number,title,baseRefOid,headRefOid,baseRefName,headRefName",
  })
  local data, err = run_json(cmd)
  if not data then
    return nil, err
  end
  return {
    number = data.number,
    title = data.title,
    owner = owner,
    repo = repo,
    base = data.baseRefName,
    head = data.headRefName,
    diff_refs = {
      base_sha = data.baseRefOid,
      head_sha = data.headRefOid,
      start_sha = data.baseRefOid,
    },
  },
    nil
end

---@param pr ReviewPR
---@param comments ReviewComment[]
---@return boolean ok, string|nil err
function github.submit_comments(pr, comments)
  -- TODO: implement with gh api (Phase 4 GitHub side)
  return false, "GitHub submit not yet implemented"
end

-- ---------------------------------------------------------------------------
-- GitLab provider
-- ---------------------------------------------------------------------------

---@type ReviewProvider
local gitlab = {
  name = "gitlab",
  cli = "glab",
}

---@param owner string
---@param repo string
---@return string
local function gl_project_id(owner, repo)
  return vim.uri_encode(owner .. "/" .. repo, "rfc2396")
end

---@param data table  Raw MR JSON from GitLab API
---@param owner string
---@param repo string
---@return ReviewPR|nil pr, string|nil err
local function parse_gitlab_mr(data, owner, repo)
  local diff_refs = data.diff_refs
  if not diff_refs then
    return nil, "Failed to get MR diff refs"
  end
  return {
    number = data.iid,
    title = data.title,
    owner = owner,
    repo = repo,
    base = data.target_branch,
    head = data.source_branch,
    diff_refs = {
      base_sha = diff_refs.base_sha,
      head_sha = diff_refs.head_sha,
      start_sha = diff_refs.start_sha,
    },
  },
    nil
end

---@param owner string
---@param repo string
---@param number number|nil
---@return ReviewPR|nil pr, string|nil err
function gitlab.fetch_mr(owner, repo, number)
  local mr_base = "projects/" .. gl_project_id(owner, repo) .. "/merge_requests"

  if number then
    local data, err = run_json({ "glab", "api", mr_base .. "/" .. tostring(number) })
    if not data then
      return nil, err
    end
    return parse_gitlab_mr(data, owner, repo)
  end

  -- glab mr view --json may not expose diffRefs, so use the API directly.
  local branch = require("review.git").current_branch()
  if not branch then
    return nil, "Could not determine current branch"
  end
  local list_data, list_err = run_json({
    "glab",
    "api",
    mr_base .. "?source_branch=" .. vim.uri_encode(branch, "rfc2396") .. "&state=opened",
  })
  if not list_data or #list_data == 0 then
    return nil, list_err or ("No open MR found for branch: " .. branch)
  end
  -- The list endpoint returns full MR objects including diff_refs.
  return parse_gitlab_mr(list_data[1], owner, repo)
end

---@param pr ReviewPR
---@param comments ReviewComment[]
---@return boolean ok, string|nil err
function gitlab.submit_comments(pr, comments)
  if not pr.diff_refs then
    return false, "Missing diff refs — cannot submit positioned comments"
  end

  local mr_path = "projects/"
    .. gl_project_id(pr.owner, pr.repo)
    .. "/merge_requests/"
    .. tostring(pr.number)
    .. "/discussions"
  local refs = pr.diff_refs
  local errors = {}

  for _, c in ipairs(comments) do
    local cmd = {
      "glab",
      "api",
      "--method",
      "POST",
      mr_path,
      "-f",
      "body=" .. c.body,
      "-f",
      "position[position_type]=text",
      "-f",
      "position[base_sha]=" .. refs.base_sha,
      "-f",
      "position[head_sha]=" .. refs.head_sha,
      "-f",
      "position[start_sha]=" .. refs.start_sha,
      "-f",
      "position[new_path]=" .. c.file_path,
      "-f",
      "position[old_path]=" .. c.file_path,
    }

    if c.side == "LEFT" then
      table.insert(cmd, "-f")
      table.insert(cmd, "position[old_line]=" .. tostring(c.line))
    else
      table.insert(cmd, "-f")
      table.insert(cmd, "position[new_line]=" .. tostring(c.line))
    end

    local _, err = run_json(cmd)
    if err then
      table.insert(errors, c.file_path .. ":" .. c.line .. " — " .. err)
    end
  end

  if #errors > 0 then
    return false, table.concat(errors, "\n")
  end
  return true, nil
end

-- ---------------------------------------------------------------------------
-- Provider registry
-- ---------------------------------------------------------------------------

local providers = {
  github = github,
  gitlab = gitlab,
}

---@param name string|nil  "github"|"gitlab"
---@return ReviewProvider|nil
function M.get(name)
  if not name then
    return nil
  end
  return providers[name]
end

return M
