--- Forge abstraction for posting review comments to GitHub/GitLab.
local M = {}

local git = require("review.git")

--- Enhance a raw API error message with actionable hints for common HTTP codes.
---@param raw string  Raw error output
---@param forge_label string  "GitHub" or "GitLab"
---@param tool_name string  "gh" or "glab"
---@return string
local function format_api_error(raw, forge_label, tool_name)
  local msg = raw or "unknown"
  if msg:match("404") then
    msg = "Not found — verify the file path exists in the PR diff and your commits are pushed."
  elseif msg:match("422") then
    msg = "Invalid position — the line number may not exist in the PR diff for this commit."
  elseif msg:match("403") then
    msg = string.format("Permission denied — check that your %s token has write access.", tool_name)
  end
  return forge_label .. " API: " .. msg
end

local cached_user = nil

--- Get the current authenticated user's login (cached after first call).
---@return string|nil
function M.current_user()
  if cached_user then
    return cached_user
  end
  local out = vim.fn.systemlist({ "gh", "api", "user", "-q", ".login" })
  if vim.v.shell_error == 0 and out[1] then
    cached_user = out[1]
    return cached_user
  end
  return nil
end

local cached_detect = nil
local cached_detect_root = nil

--- Get cached detect result without running any shell commands.
---@return table|nil
function M.get_cached_detect()
  local root = git.root()
  if root and root == cached_detect_root and cached_detect then
    return cached_detect
  end
  return nil
end

--- Detect the forge asynchronously (non-blocking).
---@param callback fun(info: table|nil)
function M.detect_async(callback)
  local remote = git.parse_remote()
  if not remote then
    callback(nil)
    return
  end

  if remote.forge == "github" then
    vim.system(
      { "gh", "pr", "view", "--json", "number", "-q", ".number" },
      {},
      vim.schedule_wrap(function(obj)
        if obj.code ~= 0 or not obj.stdout then
          callback(nil)
          return
        end
        local pr_number = tonumber(vim.trim(obj.stdout))
        if not pr_number then
          callback(nil)
          return
        end
        local root = git.root()
        cached_detect_root = root
        cached_detect = {
          forge = remote.forge,
          owner = remote.owner,
          repo = remote.repo,
          pr_number = pr_number,
        }
        callback(cached_detect)
      end)
    )
  elseif remote.forge == "gitlab" then
    vim.system(
      { "glab", "mr", "view", "--output", "json" },
      {},
      vim.schedule_wrap(function(obj)
        if obj.code ~= 0 or not obj.stdout then
          callback(nil)
          return
        end
        local ok, data = pcall(vim.fn.json_decode, obj.stdout)
        if not ok or not data or not data.iid then
          callback(nil)
          return
        end
        local root = git.root()
        cached_detect_root = root
        cached_detect = {
          forge = remote.forge,
          owner = remote.owner,
          repo = remote.repo,
          pr_number = data.iid,
        }
        callback(cached_detect)
      end)
    )
  else
    callback(nil)
  end
end

--- Invalidate all cached data (e.g. after switching branches or repos).
function M.invalidate_cache()
  cached_detect = nil
  cached_detect_root = nil
  cached_user = nil
  git.invalidate_cache()
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
    return nil, format_api_error(out, "GitHub", "gh")
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
    return nil, format_api_error(out, "GitLab", "glab")
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
    })
    if vim.v.shell_error ~= 0 then
      return nil, "Failed to get MR diff refs"
    end
    local ok, data = pcall(vim.fn.json_decode, out)
    if not ok or not data then
      return nil, "Failed to parse MR response"
    end
    local diff_refs = data.diff_refs
    if not diff_refs then
      return nil, "MR response missing diff_refs"
    end
    return { diff_refs = diff_refs }, nil
  end
  return nil, "Unknown forge: " .. info.forge
end

--- Build the GraphQL query for fetching PR review threads.
---@param info table
---@return string
local function github_threads_query(info)
  return string.format(
    [[
query {
  repository(owner: "%s", name: "%s") {
    pullRequest(number: %d) {
      reviewThreads(first: 100) {
        nodes {
          id
          isResolved
          comments(first: 100) {
            nodes {
              id
              databaseId
              body
              path
              line
              originalLine
              startLine
              author { login }
              url
              createdAt
            }
          }
        }
      }
      comments(first: 100) {
        nodes {
          id
          databaseId
          body
          author { login }
          url
          createdAt
        }
      }
      reviews(first: 50) {
        nodes {
          databaseId
          body
          state
          author { login }
          url
          createdAt
        }
      }
    }
  }
}]],
    info.owner,
    info.repo,
    info.pr_number
  )
end

--- Convert vim.NIL (from json_decode of JSON null) to real nil.
---@param v any
---@return any
local function denull(v)
  if v == vim.NIL then
    return nil
  end
  return v
end

--- Parse raw GitHub GraphQL response into comments.
---@param raw string  Raw JSON output
---@return table[] comments, string|nil err
local function parse_github_threads(raw)
  local ok, result = pcall(vim.fn.json_decode, raw)
  if not ok or not result or not result.data then
    return {}, "Failed to parse PR threads response"
  end

  local threads_data = result.data.repository
    and result.data.repository.pullRequest
    and result.data.repository.pullRequest.reviewThreads
    and result.data.repository.pullRequest.reviewThreads.nodes
  if not threads_data then
    return {}, nil
  end

  local comments = {}
  for _, thread in ipairs(threads_data) do
    local nodes = thread.comments and thread.comments.nodes
    if not nodes or #nodes == 0 then
      goto continue
    end

    local top = nodes[1]
    if not top.path then
      goto continue
    end

    local d_line = denull(top.line)
    local d_originalLine = denull(top.originalLine)
    local d_startLine = denull(top.startLine)

    local side = (not d_line and d_originalLine) and "old" or "new"
    local line = d_startLine or d_line or d_originalLine
    local end_line = nil
    if d_startLine and d_line and d_startLine ~= d_line then
      end_line = d_line
    end

    local replies = {}
    for i, c in ipairs(nodes) do
      table.insert(replies, {
        author = c.author and c.author.login or "unknown",
        body = c.body or "",
        url = c.url,
        created_at = c.createdAt,
        is_top = (i == 1),
        remote_id = c.databaseId,
      })
    end

    table.insert(comments, {
      file_path = top.path,
      line = line,
      end_line = end_line,
      side = side,
      replies = replies,
      thread_id = top.databaseId,
      thread_node_id = thread.id,
      url = top.url,
      resolved = thread.isResolved or false,
    })
    ::continue::
  end

  -- Parse general PR comments (not attached to code)
  local pr = result.data.repository and result.data.repository.pullRequest
  local general_nodes = pr and pr.comments and pr.comments.nodes
  if general_nodes then
    for _, c in ipairs(general_nodes) do
      table.insert(comments, {
        file_path = nil,
        line = nil,
        end_line = nil,
        side = nil,
        replies = {
          {
            author = c.author and c.author.login or "unknown",
            body = c.body or "",
            url = c.url,
            created_at = c.createdAt,
            is_top = true,
            remote_id = c.databaseId,
          },
        },
        thread_id = c.databaseId,
        url = c.url,
        resolved = nil,
        is_general = true,
      })
    end
  end

  -- Parse review summaries (approve/request changes/copilot reviews with body)
  local review_nodes = pr and pr.reviews and pr.reviews.nodes
  if review_nodes then
    for _, r in ipairs(review_nodes) do
      if r.body and r.body ~= "" then
        local state_label = ""
        if r.state == "APPROVED" then
          state_label = "[approved] "
        elseif r.state == "CHANGES_REQUESTED" then
          state_label = "[changes requested] "
        end
        table.insert(comments, {
          file_path = nil,
          line = nil,
          end_line = nil,
          side = nil,
          replies = {
            {
              author = r.author and r.author.login or "unknown",
              body = state_label .. r.body,
              url = r.url,
              created_at = r.createdAt,
              is_top = true,
              remote_id = r.databaseId,
            },
          },
          thread_id = r.databaseId,
          url = r.url,
          resolved = nil,
          is_general = true,
        })
      end
    end
  end

  return comments, nil
end

--- Fetch existing review threads from a GitHub PR using GraphQL.
---@param info table  Forge info from detect()
---@return table[] comments, string|nil err
local function github_fetch(info)
  local json = vim.fn.json_encode({ query = github_threads_query(info) })
  local out = vim.fn.system({ "gh", "api", "graphql", "--input", "-" }, json)
  if vim.v.shell_error ~= 0 then
    return {}, "Failed to fetch PR threads: " .. (out or "unknown")
  end
  return parse_github_threads(out)
end

--- Fetch existing review comments from a GitLab MR.
---@param info table  Forge info from detect()
---@return table[] comments, string|nil err
--- Parse raw GitLab discussions JSON into comments.
---@param raw string
---@return table[] comments, string|nil err
local function parse_gitlab_discussions(raw)
  local ok, disc_data = pcall(vim.fn.json_decode, raw)
  if not ok or type(disc_data) ~= "table" then
    return {}, "Failed to parse MR discussions response"
  end

  local comments = {}
  for _, disc in ipairs(disc_data) do
    if not disc.notes or #disc.notes == 0 then
      goto continue
    end

    local top = disc.notes[1]

    -- Build replies for all note types
    local replies = {}
    for i, n in ipairs(disc.notes) do
      table.insert(replies, {
        author = n.author and n.author.username or "unknown",
        body = n.body or "",
        url = n.web_url,
        created_at = n.created_at,
        is_top = (i == 1),
        remote_id = n.id,
      })
    end

    if top.position and top.position.new_path then
      -- Diff-attached note
      local pos = top.position
      local side = pos.old_line and not pos.new_line and "old" or "new"
      local line = (side == "old") and pos.old_line or pos.new_line
      table.insert(comments, {
        file_path = pos.new_path or pos.old_path,
        line = line,
        end_line = nil,
        side = side,
        replies = replies,
        thread_id = disc.id,
        url = top.web_url,
        resolved = top.resolved or false,
      })
    elseif not top.system then
      -- General MR comment (skip system notes)
      table.insert(comments, {
        file_path = nil,
        line = nil,
        end_line = nil,
        side = nil,
        replies = replies,
        thread_id = disc.id,
        url = top.web_url,
        resolved = nil,
        is_general = true,
      })
    end
    ::continue::
  end
  return comments, nil
end

local function gitlab_fetch(info)
  local project_id = info.owner .. "/" .. info.repo
  local endpoint =
    string.format("projects/%s/merge_requests/%d/discussions", vim.fn.fnameescape(project_id), info.pr_number)
  local out = vim.fn.system({ "glab", "api", endpoint, "--paginate" })
  if vim.v.shell_error ~= 0 then
    return {}, "Failed to fetch MR discussions: " .. (out or "unknown")
  end
  return parse_gitlab_discussions(out)
end

--- Post a general comment on a PR/MR (not attached to code).
---@param info table  Forge info from detect()
---@param body string
---@return string|nil url, string|nil err
function M.reply_to_pr(info, body)
  if info.forge == "github" then
    local endpoint = string.format("repos/%s/%s/issues/%d/comments", info.owner, info.repo, info.pr_number)
    local json = vim.fn.json_encode({ body = body })
    local out = vim.fn.system({ "gh", "api", endpoint, "-X", "POST", "--input", "-" }, json)
    if vim.v.shell_error ~= 0 then
      return nil, format_api_error(out, "GitHub", "gh")
    end
    local ok, data = pcall(vim.fn.json_decode, out)
    if ok and data and data.html_url then
      return data.html_url, nil
    end
    return nil, "Failed to parse response"
  elseif info.forge == "gitlab" then
    local project_id = info.owner .. "/" .. info.repo
    local endpoint =
      string.format("projects/%s/merge_requests/%d/notes", vim.fn.fnameescape(project_id), info.pr_number)
    local json = vim.fn.json_encode({ body = body })
    local out = vim.fn.system({ "glab", "api", endpoint, "-X", "POST", "--input", "-" }, json)
    if vim.v.shell_error ~= 0 then
      return nil, format_api_error(out, "GitLab", "glab")
    end
    local ok, data = pcall(vim.fn.json_decode, out)
    if ok and data and data.web_url then
      return data.web_url, nil
    end
    return nil, "Failed to parse response"
  end
  return nil, "Unknown forge: " .. info.forge
end

---@param callback fun(comments: table[], err: string|nil)
function M.fetch_comments_async(info, callback)
  if info.forge == "github" then
    local json_input = vim.fn.json_encode({ query = github_threads_query(info) })
    vim.system(
      { "gh", "api", "graphql", "--input", "-" },
      { stdin = json_input },
      vim.schedule_wrap(function(obj)
        if obj.code ~= 0 then
          callback({}, "Failed to fetch PR threads: " .. (obj.stderr or "unknown"))
          return
        end
        callback(parse_github_threads(obj.stdout))
      end)
    )
  elseif info.forge == "gitlab" then
    local project_id = info.owner .. "/" .. info.repo
    local endpoint =
      string.format("projects/%s/merge_requests/%d/discussions", vim.fn.fnameescape(project_id), info.pr_number)
    vim.system(
      { "glab", "api", endpoint, "--paginate" },
      {},
      vim.schedule_wrap(function(obj)
        if obj.code ~= 0 then
          callback({}, "Failed to fetch MR discussions: " .. (obj.stderr or "unknown"))
          return
        end
        callback(parse_gitlab_discussions(obj.stdout))
      end)
    )
  else
    callback({}, "Unknown forge: " .. info.forge)
  end
end

--- Reply to an existing thread on a GitHub PR.
---@param info table  Forge info from detect()
---@param thread_id number  The top-level comment ID to reply to
---@param body string
---@return string|nil url, string|nil err
function M.reply_to_thread(info, thread_id, body)
  if info.forge == "github" then
    local endpoint =
      string.format("repos/%s/%s/pulls/%d/comments/%d/replies", info.owner, info.repo, info.pr_number, thread_id)
    local json = vim.fn.json_encode({ body = body })
    local out = vim.fn.system({ "gh", "api", endpoint, "-X", "POST", "--input", "-" }, json)
    if vim.v.shell_error ~= 0 then
      return nil, format_api_error(out, "GitHub", "gh")
    end
    local ok, data = pcall(vim.fn.json_decode, out)
    if ok and data and data.html_url then
      return data.html_url, nil
    end
    return nil, "Failed to parse reply response"
  elseif info.forge == "gitlab" then
    local project_id = info.owner .. "/" .. info.repo
    local endpoint = string.format(
      "projects/%s/merge_requests/%d/discussions/%s/notes",
      vim.fn.fnameescape(project_id),
      info.pr_number,
      thread_id
    )
    local json = vim.fn.json_encode({ body = body })
    local out = vim.fn.system({ "glab", "api", endpoint, "-X", "POST", "--input", "-" }, json)
    if vim.v.shell_error ~= 0 then
      return nil, format_api_error(out, "GitLab", "glab")
    end
    local ok, data = pcall(vim.fn.json_decode, out)
    if ok and data and data.web_url then
      return data.web_url, nil
    end
    return nil, "Failed to parse reply response"
  end
  return nil, "Unknown forge: " .. info.forge
end

--- Edit an existing comment on a PR/MR.
---@param info table  Forge info from detect()
---@param comment_id number  The comment's database ID
---@param body string  New body text
---@return string|nil url, string|nil err
function M.edit_comment(info, comment_id, body)
  if info.forge == "github" then
    local endpoint = string.format("repos/%s/%s/pulls/comments/%d", info.owner, info.repo, comment_id)
    local json = vim.fn.json_encode({ body = body })
    local out = vim.fn.system({ "gh", "api", endpoint, "-X", "PATCH", "--input", "-" }, json)
    if vim.v.shell_error ~= 0 then
      return nil, format_api_error(out, "GitHub", "gh")
    end
    local ok, data = pcall(vim.fn.json_decode, out)
    if ok and data and data.html_url then
      return data.html_url, nil
    end
    return nil, "Failed to parse edit response"
  elseif info.forge == "gitlab" then
    local project_id = info.owner .. "/" .. info.repo
    local endpoint = string.format(
      "projects/%s/merge_requests/%d/notes/%d",
      vim.fn.fnameescape(project_id),
      info.pr_number,
      comment_id
    )
    local json = vim.fn.json_encode({ body = body })
    local out = vim.fn.system({ "glab", "api", endpoint, "-X", "PUT", "--input", "-" }, json)
    if vim.v.shell_error ~= 0 then
      return nil, format_api_error(out, "GitLab", "glab")
    end
    local ok, data = pcall(vim.fn.json_decode, out)
    if ok and data and data.web_url then
      return data.web_url, nil
    end
    return nil, "Failed to parse edit response"
  end
  return nil, "Unknown forge: " .. info.forge
end

--- Delete a comment on a PR/MR.
---@param info table  Forge info from detect()
---@param comment_id number  The comment's database ID
---@return boolean ok, string|nil err
function M.delete_comment(info, comment_id)
  if info.forge == "github" then
    local endpoint = string.format("repos/%s/%s/pulls/comments/%d", info.owner, info.repo, comment_id)
    local out = vim.fn.system({ "gh", "api", endpoint, "-X", "DELETE" })
    if vim.v.shell_error ~= 0 then
      return false, format_api_error(out, "GitHub", "gh")
    end
    return true, nil
  elseif info.forge == "gitlab" then
    local project_id = info.owner .. "/" .. info.repo
    local endpoint = string.format(
      "projects/%s/merge_requests/%d/notes/%d",
      vim.fn.fnameescape(project_id),
      info.pr_number,
      comment_id
    )
    local out = vim.fn.system({ "glab", "api", endpoint, "-X", "DELETE" })
    if vim.v.shell_error ~= 0 then
      return false, format_api_error(out, "GitLab", "glab")
    end
    return true, nil
  end
  return false, "Unknown forge: " .. info.forge
end

--- Resolve or unresolve a review thread.
---@param info table  Forge info from detect()
---@param note ReviewNote  The remote note (needs thread_node_id for GitHub, thread_id for GitLab)
---@param resolved boolean  true to resolve, false to unresolve
---@return boolean ok, string|nil err
function M.resolve_thread(info, note, resolved)
  if info.forge == "github" then
    local node_id = note.thread_node_id
    if not node_id then
      return false, "Missing thread node ID — cannot resolve"
    end
    local mutation = string.format(
      [[mutation { %sReviewThread(input: {threadId: "%s"}) { thread { isResolved } } }]],
      resolved and "resolve" or "unresolve",
      node_id
    )
    local json = vim.fn.json_encode({ query = mutation })
    local out = vim.fn.system({ "gh", "api", "graphql", "--input", "-" }, json)
    if vim.v.shell_error ~= 0 then
      return false, format_api_error(out, "GitHub", "gh")
    end
    return true, nil
  elseif info.forge == "gitlab" then
    local project_id = info.owner .. "/" .. info.repo
    local endpoint = string.format(
      "projects/%s/merge_requests/%d/discussions/%s",
      vim.fn.fnameescape(project_id),
      info.pr_number,
      note.thread_id
    )
    local json = vim.fn.json_encode({ resolved = resolved })
    local out = vim.fn.system({ "glab", "api", endpoint, "-X", "PUT", "--input", "-" }, json)
    if vim.v.shell_error ~= 0 then
      return false, format_api_error(out, "GitLab", "glab")
    end
    return true, nil
  end
  return false, "Unknown forge: " .. info.forge
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
