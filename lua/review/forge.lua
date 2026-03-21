--- Forge abstraction for posting review comments to GitHub/GitLab.
local M = {}

local git = require("review.git")

--- Detect the current forge, repo info, and PR/MR number.
---@return {forge: string, owner: string, repo: string, pr_number: number}|nil
function M.detect()
  local remote = git.parse_remote()
  if not remote then
    return nil
  end

  local pr_number
  if remote.forge == "github" then
    local out = vim.fn.systemlist({ "gh", "pr", "view", "--json", "number", "-q", ".number" })
    if vim.v.shell_error == 0 and out[1] then
      pr_number = tonumber(out[1])
    end
  elseif remote.forge == "gitlab" then
    local out = vim.fn.system({ "glab", "mr", "view", "--output", "json" })
    if vim.v.shell_error == 0 then
      local ok, data = pcall(vim.fn.json_decode, out)
      if ok and data then
        pr_number = data.iid
      end
    end
  end

  if not pr_number then
    return nil
  end

  return {
    forge = remote.forge,
    owner = remote.owner,
    repo = remote.repo,
    pr_number = pr_number,
  }
end

--- Post a single note as a line comment on a GitHub PR.
---@param info table  Forge info from detect()
---@param note ReviewNote
---@param ctx table  {commit_id: string}
---@return string|nil url, string|nil err
local function github_post(info, note, ctx)
  local side = note.side == "old" and "LEFT" or "RIGHT"

  local payload = {
    body = note.body,
    path = note.file_path,
    line = note.end_line or note.line,
    side = side,
    commit_id = ctx.commit_id,
  }

  if note.end_line and note.end_line ~= note.line then
    payload.start_line = note.line
    payload.start_side = side
  end

  local json = vim.fn.json_encode(payload)
  local endpoint = string.format("repos/%s/%s/pulls/%d/comments", info.owner, info.repo, info.pr_number)

  local out = vim.fn.system({
    "gh",
    "api",
    endpoint,
    "-X",
    "POST",
    "--input",
    "-",
  }, json)

  if vim.v.shell_error ~= 0 then
    local msg = out or "unknown"
    -- Provide actionable hints for common HTTP errors
    if msg:match("404") then
      msg = "Not found — verify the file path exists in the PR diff and your commits are pushed."
    elseif msg:match("422") then
      msg = "Invalid position — the line number may not exist in the PR diff for this commit."
    elseif msg:match("403") then
      msg = "Permission denied — check that your gh token has write access to this repo."
    end
    return nil, "GitHub API: " .. msg
  end

  local ok, data = pcall(vim.fn.json_decode, out)
  if ok and data and data.html_url then
    return data.html_url, nil
  end

  return nil, "Failed to parse GitHub response"
end

--- Post a single note as a discussion on a GitLab MR.
---@param info table  Forge info from detect()
---@param note ReviewNote
---@param ctx table  {diff_refs: table}
---@return string|nil url, string|nil err
local function gitlab_post(info, note, ctx)
  local project_id = info.owner .. "/" .. info.repo

  local position = {
    position_type = "text",
    base_sha = ctx.diff_refs.base_sha,
    head_sha = ctx.diff_refs.head_sha,
    start_sha = ctx.diff_refs.start_sha,
    old_path = note.file_path,
    new_path = note.file_path,
  }

  if note.side == "old" then
    position.old_line = note.end_line or note.line
  else
    position.new_line = note.end_line or note.line
  end

  local json = vim.fn.json_encode({ body = note.body, position = position })
  local endpoint =
    string.format("projects/%s/merge_requests/%d/discussions", vim.fn.fnameescape(project_id), info.pr_number)

  local out = vim.fn.system({
    "glab",
    "api",
    endpoint,
    "-X",
    "POST",
    "--input",
    "-",
  }, json)

  if vim.v.shell_error ~= 0 then
    local msg = out or "unknown"
    if msg:match("404") then
      msg = "Not found — verify the file path exists in the MR diff and your commits are pushed."
    elseif msg:match("422") then
      msg = "Invalid position — the line number may not exist in the MR diff for this commit."
    elseif msg:match("403") then
      msg = "Permission denied — check that your glab token has write access to this project."
    end
    return nil, "GitLab API: " .. msg
  end

  local ok, data = pcall(vim.fn.json_decode, out)
  if ok and data and data.notes and data.notes[1] and data.notes[1].web_url then
    return data.notes[1].web_url, nil
  end

  return nil, "Failed to parse GitLab response"
end

--- Resolve forge-specific context needed for posting (called once before a batch).
---@param info table  Forge info from detect()
---@return table|nil ctx, string|nil err
function M.resolve_context(info)
  if info.forge == "github" then
    local out = vim.fn.systemlist({ "gh", "pr", "view", "--json", "headRefOid", "-q", ".headRefOid" })
    if vim.v.shell_error ~= 0 or not out[1] then
      return nil, "Failed to resolve PR head commit"
    end
    local remote_head = out[1]
    -- Check if the local HEAD matches the remote PR head
    local local_head = vim.fn.systemlist({ "git", "rev-parse", "HEAD" })
    if vim.v.shell_error == 0 and local_head[1] and local_head[1] ~= remote_head then
      return nil, "Local HEAD differs from remote PR head. Push your commits before publishing."
    end
    return { commit_id = remote_head }, nil
  elseif info.forge == "gitlab" then
    local project_id = info.owner .. "/" .. info.repo
    local out = vim.fn.system({
      "glab",
      "api",
      string.format("projects/%s/merge_requests/%d", vim.fn.fnameescape(project_id), info.pr_number),
      "--jq",
      ".diff_refs",
    })
    if vim.v.shell_error ~= 0 then
      return nil, "Failed to get MR diff refs"
    end
    local ok, diff_refs = pcall(vim.fn.json_decode, out)
    if not ok or not diff_refs then
      return nil, "Failed to parse diff refs"
    end
    return { diff_refs = diff_refs }, nil
  end
  return nil, "Unknown forge: " .. info.forge
end

--- Post a review note as a line comment on the current PR/MR.
---@param info table  Forge info from detect()
---@param note ReviewNote
---@param ctx table  Context from resolve_context()
---@return string|nil url, string|nil err
function M.post_comment(info, note, ctx)
  if info.forge == "github" then
    return github_post(info, note, ctx)
  elseif info.forge == "gitlab" then
    return gitlab_post(info, note, ctx)
  end
  return nil, "Unknown forge: " .. info.forge
end

return M
