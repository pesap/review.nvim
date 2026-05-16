--- Thin wrappers around git shell commands.
local M = {}

local cached_root = nil
local cached_head_exists = nil
local context_cache = {
  diff = {},
  log = {},
  merge_base = {},
  commit_diff = {},
  blame = {},
  file_history = {},
  file_show = {},
  commit_details = {},
}
local context_cache_signature = nil
local pending_context = {
  diff = {},
  log = {},
  merge_base = {},
  blame = {},
  commit_diff = {},
  file_history = {},
  file_show = {},
  commit_details = {},
}
local build_untracked_file

---@param cmd string[]
---@return string[]|nil out
---@return string|nil err
local function run_systemlist(cmd)
  if not cmd[1] or vim.fn.executable(cmd[1]) ~= 1 then
    return nil, string.format("%s is not executable", cmd[1] or "command")
  end
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
  if not cmd[1] or vim.fn.executable(cmd[1]) ~= 1 then
    return nil, string.format("%s is not executable", cmd[1] or "command")
  end
  local out = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    return nil, out
  end
  return out, nil
end

---@param stdout string|nil
---@return string[]
local function stdout_lines(stdout)
  if not stdout or stdout == "" then
    return {}
  end
  local lines = vim.split(stdout, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

---@param clear_pending boolean|nil
local function reset_context_cache(clear_pending)
  context_cache = {
    diff = {},
    log = {},
    merge_base = {},
    commit_diff = {},
    blame = {},
    file_history = {},
    file_show = {},
    commit_details = {},
  }
  if clear_pending then
    pending_context = {
      diff = {},
      log = {},
      merge_base = {},
      blame = {},
      commit_diff = {},
      file_history = {},
      file_show = {},
      commit_details = {},
    }
  end
end

---@param bucket table<string, function[]>
---@param key string
---@param callback function
---@return boolean already_pending
local function queue_pending(bucket, key, callback)
  if bucket[key] then
    table.insert(bucket[key], callback)
    return true
  end
  bucket[key] = { callback }
  return false
end

---@param bucket table<string, function[]>
---@param key string
---@return function[]
local function take_pending(bucket, key)
  local callbacks = bucket[key] or {}
  bucket[key] = nil
  return callbacks
end

---@return string
local function context_signature()
  local status = run_systemlist({ "git", "status", "--porcelain=v1", "--branch", "--untracked-files=normal" }) or {}
  local head = run_systemlist({ "git", "rev-parse", "--verify", "HEAD" })
  return table.concat(status, "\n") .. "\nHEAD:" .. tostring(head and head[1] or "")
end

---@return string
local function ensure_context_cache_current()
  local signature = context_signature()
  if context_cache_signature == nil then
    context_cache_signature = signature
    return signature
  end
  if context_cache_signature ~= signature then
    reset_context_cache(false)
    context_cache_signature = signature
  end
  return signature
end

---@param ref string|nil
---@return string
local function resolved_ref(ref)
  local target = ref or "HEAD"
  local out = run_systemlist({ "git", "rev-parse", "--verify", target })
  return out and out[1] or target
end

---@param lines string[]|nil
---@return string[]
local function parse_blame_porcelain(lines)
  local out = {}
  local current = nil
  for _, line in ipairs(lines or {}) do
    local sha, _orig_lnum, final_lnum = line:match("^(%S+)%s+(%d+)%s+(%d+)")
    if sha then
      current = {
        sha = sha,
        line = tonumber(final_lnum) or 0,
        author = "",
        date = "",
        summary = "",
      }
    elseif current then
      local author = line:match("^author (.*)$")
      if author then
        current.author = author
      end

      local author_time = tonumber(line:match("^author%-time (%d+)$") or "")
      if author_time then
        current.date = os.date("%Y-%m-%d", author_time) or ""
      end

      local summary = line:match("^summary (.*)$")
      if summary then
        current.summary = summary
      end

      local code = line:match("^\t(.*)$")
      if code then
        local summary_prefix = current.summary ~= "" and (current.summary .. " | ") or ""
        table.insert(
          out,
          string.format(
            "%s (%s %s %d) %s%s",
            current.sha,
            current.author,
            current.date,
            current.line,
            summary_prefix,
            code
          )
        )
        current = nil
      end
    end
  end
  return out
end

---@param cmd string[]
---@param callback fun(lines: string[]|nil, err: string|nil)
local function run_systemlist_async(cmd, callback)
  if not cmd[1] or vim.fn.executable(cmd[1]) ~= 1 then
    callback(nil, string.format("%s is not executable", cmd[1] or "command"))
    return
  end
  vim.system(
    cmd,
    { text = true },
    vim.schedule_wrap(function(obj)
      if obj.code ~= 0 then
        callback(nil, obj.stderr ~= "" and obj.stderr or obj.stdout)
        return
      end
      callback(stdout_lines(obj.stdout), nil)
    end)
  )
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

--- Return a cheap signature for the current workspace state.
---@return string
function M.workspace_signature()
  local out = run_systemlist({ "git", "status", "--porcelain=v1", "--branch", "--untracked-files=normal" })
  if not out then
    return ""
  end
  return table.concat(out, "\n")
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
  _ = run_systemlist({ "git", "rev-parse", "--verify", "main" })
  if _ then
    cached_default_branch = "main"
    return cached_default_branch
  end
  _ = run_systemlist({ "git", "rev-parse", "--verify", "master" })
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

--- Get the unified diff text between two refs.
---@param left_ref string
---@param right_ref string
---@return string diff_text
---@return string|nil err
function M.diff_range(left_ref, right_ref)
  local out, err = run_system({ "git", "diff", left_ref, right_ref })
  if not out then
    return "", err
  end
  return out, nil
end

---@param ref string|nil
---@param callback fun(diff_text: string, err: string|nil)
function M.diff_async(ref, callback)
  local key = tostring(ref or "HEAD")
  if queue_pending(pending_context.diff, key, callback) then
    return
  end
  local cmd = { "git", "diff" }
  if ref then
    table.insert(cmd, ref)
  end
  if not cmd[1] or vim.fn.executable(cmd[1]) ~= 1 then
    local err = string.format("%s is not executable", cmd[1] or "command")
    for _, cb in ipairs(take_pending(pending_context.diff, key)) do
      cb("", err)
    end
    return
  end
  vim.system(
    cmd,
    { text = true },
    vim.schedule_wrap(function(obj)
      if obj.code ~= 0 then
        local err = obj.stderr ~= "" and obj.stderr or obj.stdout
        for _, cb in ipairs(take_pending(pending_context.diff, key)) do
          cb("", err)
        end
        return
      end
      for _, cb in ipairs(take_pending(pending_context.diff, key)) do
        cb(obj.stdout or "", nil)
      end
    end)
  )
end

---@param left_ref string
---@param right_ref string
---@param callback fun(diff_text: string, err: string|nil)
function M.diff_range_async(left_ref, right_ref, callback)
  local key = tostring(left_ref or "") .. ".." .. tostring(right_ref or "")
  if queue_pending(pending_context.diff, key, callback) then
    return
  end
  if vim.fn.executable("git") ~= 1 then
    local err = "git is not executable"
    for _, cb in ipairs(take_pending(pending_context.diff, key)) do
      cb("", err)
    end
    return
  end
  vim.system(
    { "git", "diff", left_ref, right_ref },
    { text = true },
    vim.schedule_wrap(function(obj)
      if obj.code ~= 0 then
        local err = obj.stderr ~= "" and obj.stderr or obj.stdout
        for _, cb in ipairs(take_pending(pending_context.diff, key)) do
          cb("", err)
        end
        return
      end
      for _, cb in ipairs(take_pending(pending_context.diff, key)) do
        cb(obj.stdout or "", nil)
      end
    end)
  )
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
  local key = tostring(sha or "")
  if context_cache.commit_diff[key] ~= nil then
    return context_cache.commit_diff[key]
  end
  local out = run_system({ "git", "diff", sha .. "~1", sha })
  if not out then
    -- Might be the first commit (no parent), try show
    out = run_system({ "git", "show", "--format=", sha })
    if not out then
      context_cache.commit_diff[key] = ""
      return ""
    end
  end
  context_cache.commit_diff[key] = out
  return out
end

---@param sha string
---@param callback fun(diff_text: string, err: string|nil)
function M.commit_diff_async(sha, callback)
  local key = tostring(sha or "")
  if context_cache.commit_diff[key] ~= nil then
    callback(context_cache.commit_diff[key], nil)
    return
  end
  if queue_pending(pending_context.commit_diff, key, callback) then
    return
  end
  if vim.fn.executable("git") ~= 1 then
    local err = "git is not executable"
    context_cache.commit_diff[key] = ""
    for _, cb in ipairs(take_pending(pending_context.commit_diff, key)) do
      cb("", err)
    end
    return
  end

  vim.system(
    { "git", "diff", sha .. "~1", sha },
    { text = true },
    vim.schedule_wrap(function(obj)
      if obj.code == 0 then
        context_cache.commit_diff[key] = obj.stdout or ""
        for _, cb in ipairs(take_pending(pending_context.commit_diff, key)) do
          cb(context_cache.commit_diff[key], nil)
        end
        return
      end

      vim.system(
        { "git", "show", "--format=", sha },
        { text = true },
        vim.schedule_wrap(function(show_obj)
          if show_obj.code ~= 0 then
            context_cache.commit_diff[key] = ""
            local err = show_obj.stderr ~= "" and show_obj.stderr or show_obj.stdout
            for _, cb in ipairs(take_pending(pending_context.commit_diff, key)) do
              cb("", err)
            end
            return
          end
          context_cache.commit_diff[key] = show_obj.stdout or ""
          for _, cb in ipairs(take_pending(pending_context.commit_diff, key)) do
            cb(context_cache.commit_diff[key], nil)
          end
        end)
      )
    end)
  )
end

---@param ref string|nil
---@param path string
---@return string[]|nil lines, string|nil err
function M.blame(ref, path)
  local signature = ensure_context_cache_current()
  local key = table.concat({ signature, tostring(ref or "HEAD"), resolved_ref(ref), tostring(path or "") }, "::")
  if context_cache.blame[key] then
    return vim.deepcopy(context_cache.blame[key].lines), context_cache.blame[key].err
  end
  local cmd = { "git", "blame", "--line-porcelain" }
  if ref and ref ~= "" then
    table.insert(cmd, ref)
  end
  table.insert(cmd, "--")
  table.insert(cmd, path)
  local lines, err = run_systemlist(cmd)
  local parsed = lines and parse_blame_porcelain(lines) or nil
  context_cache.blame[key] = { lines = parsed and vim.deepcopy(parsed) or nil, err = err }
  return parsed, err
end

---@param ref string|nil
---@param path string
---@param callback fun(lines: string[]|nil, err: string|nil)
function M.blame_async(ref, path, callback)
  local signature = ensure_context_cache_current()
  local key = table.concat({ signature, tostring(ref or "HEAD"), resolved_ref(ref), tostring(path or "") }, "::")
  if context_cache.blame[key] then
    callback(vim.deepcopy(context_cache.blame[key].lines), context_cache.blame[key].err)
    return
  end
  if queue_pending(pending_context.blame, key, callback) then
    return
  end
  local cmd = { "git", "blame", "--line-porcelain" }
  if ref and ref ~= "" then
    table.insert(cmd, ref)
  end
  table.insert(cmd, "--")
  table.insert(cmd, path)
  run_systemlist_async(cmd, function(lines, err)
    local parsed = lines and parse_blame_porcelain(lines) or nil
    context_cache.blame[key] = { lines = parsed and vim.deepcopy(parsed) or nil, err = err }
    for _, cb in ipairs(take_pending(pending_context.blame, key)) do
      cb(parsed and vim.deepcopy(parsed) or nil, err)
    end
  end)
end

---@param path string
---@return string[]|nil lines, string|nil err
function M.file_history(path)
  local signature = ensure_context_cache_current()
  local key = table.concat({ signature, resolved_ref("HEAD"), tostring(path or "") }, "::")
  if context_cache.file_history[key] then
    return vim.deepcopy(context_cache.file_history[key].lines), context_cache.file_history[key].err
  end
  local lines, err = run_systemlist({
    "git",
    "log",
    "--follow",
    "--date=short",
    "--pretty=format:%h%x09%ad%x09%an%x09%s",
    "--",
    path,
  })
  context_cache.file_history[key] = { lines = lines and vim.deepcopy(lines) or nil, err = err }
  return lines, err
end

---@param path string
---@param callback fun(lines: string[]|nil, err: string|nil)
function M.file_history_async(path, callback)
  local signature = ensure_context_cache_current()
  local key = table.concat({ signature, resolved_ref("HEAD"), tostring(path or "") }, "::")
  if context_cache.file_history[key] then
    callback(vim.deepcopy(context_cache.file_history[key].lines), context_cache.file_history[key].err)
    return
  end
  if queue_pending(pending_context.file_history, key, callback) then
    return
  end
  run_systemlist_async({
    "git",
    "log",
    "--follow",
    "--date=short",
    "--pretty=format:%h%x09%ad%x09%an%x09%s",
    "--",
    path,
  }, function(lines, err)
    context_cache.file_history[key] = { lines = lines and vim.deepcopy(lines) or nil, err = err }
    for _, cb in ipairs(take_pending(pending_context.file_history, key)) do
      cb(lines and vim.deepcopy(lines) or nil, err)
    end
  end)
end

---@param sha string
---@param path string
---@return string|nil diff_text, string|nil err
function M.file_show(sha, path)
  local key = table.concat({ tostring(sha or ""), tostring(path or "") }, "::")
  if context_cache.file_show[key] ~= nil then
    return context_cache.file_show[key]
  end
  local diff_text, err = run_system({ "git", "show", "--format=", "--patch", sha, "--", path })
  context_cache.file_show[key] = diff_text
  return diff_text, err
end

---@param sha string
---@param path string
---@param callback fun(diff_text: string|nil, err: string|nil)
function M.file_show_async(sha, path, callback)
  local key = table.concat({ tostring(sha or ""), tostring(path or "") }, "::")
  if context_cache.file_show[key] ~= nil then
    callback(context_cache.file_show[key], nil)
    return
  end
  if queue_pending(pending_context.file_show, key, callback) then
    return
  end
  if vim.fn.executable("git") ~= 1 then
    local err = "git is not executable"
    for _, cb in ipairs(take_pending(pending_context.file_show, key)) do
      cb(nil, err)
    end
    return
  end
  vim.system(
    { "git", "show", "--format=", "--patch", sha, "--", path },
    { text = true },
    vim.schedule_wrap(function(obj)
      if obj.code ~= 0 then
        local err = obj.stderr ~= "" and obj.stderr or obj.stdout
        for _, cb in ipairs(take_pending(pending_context.file_show, key)) do
          cb(nil, err)
        end
        return
      end
      context_cache.file_show[key] = obj.stdout or ""
      for _, cb in ipairs(take_pending(pending_context.file_show, key)) do
        cb(context_cache.file_show[key], nil)
      end
    end)
  )
end

---@param sha string
---@return string[]|nil lines, string|nil err
function M.commit_details(sha)
  local key = tostring(sha or "")
  if context_cache.commit_details[key] then
    return vim.deepcopy(context_cache.commit_details[key].lines), context_cache.commit_details[key].err
  end
  local lines, err = run_systemlist({
    "git",
    "show",
    "--stat",
    "--name-status",
    "--date=short",
    "--format=commit %H%nAuthor: %an <%ae>%nDate:   %ad%n%n%B",
    sha,
  })
  context_cache.commit_details[key] = { lines = lines and vim.deepcopy(lines) or nil, err = err }
  return lines, err
end

---@param sha string
---@param callback fun(lines: string[]|nil, err: string|nil)
function M.commit_details_async(sha, callback)
  local key = tostring(sha or "")
  if context_cache.commit_details[key] then
    callback(vim.deepcopy(context_cache.commit_details[key].lines), context_cache.commit_details[key].err)
    return
  end
  if queue_pending(pending_context.commit_details, key, callback) then
    return
  end
  run_systemlist_async({
    "git",
    "show",
    "--stat",
    "--name-status",
    "--date=short",
    "--format=commit %H%nAuthor: %an <%ae>%nDate:   %ad%n%n%B",
    sha,
  }, function(lines, err)
    context_cache.commit_details[key] = { lines = lines and vim.deepcopy(lines) or nil, err = err }
    for _, cb in ipairs(take_pending(pending_context.commit_details, key)) do
      cb(lines and vim.deepcopy(lines) or nil, err)
    end
  end)
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

---@return string|nil
function M.current_head()
  local out = run_systemlist({ "git", "rev-parse", "--verify", "HEAD" })
  return out and out[1] or nil
end

---@param ref string
---@return boolean
function M.ref_exists(ref)
  if not ref or ref == "" then
    return false
  end
  return run_systemlist({ "git", "rev-parse", "--verify", ref }) ~= nil
end

---@return string[]
function M.local_branches()
  local out = run_systemlist({ "git", "for-each-ref", "--format=%(refname:short)", "refs/heads" })
  return out or {}
end

---@return string[]
function M.tags()
  local out = run_systemlist({ "git", "tag", "--list", "--sort=-creatordate" })
  return out or {}
end

---@param base_ref string|nil
---@param head_ref string|nil
---@return string|nil sha
function M.merge_base(base_ref, head_ref)
  if not base_ref or base_ref == "" then
    return nil
  end
  head_ref = head_ref or "HEAD"
  local signature = ensure_context_cache_current()
  local key = table.concat({ signature, resolved_ref(base_ref), resolved_ref(head_ref) }, "::")
  if context_cache.merge_base[key] ~= nil then
    return context_cache.merge_base[key] ~= false and context_cache.merge_base[key] or nil
  end
  local out = run_systemlist({ "git", "merge-base", base_ref, head_ref })
  local sha = out and out[1] or nil
  context_cache.merge_base[key] = sha or false
  return sha
end

---@param base_ref string|nil
---@param head_ref string|nil
---@param callback fun(sha: string|nil, err: string|nil)
function M.merge_base_async(base_ref, head_ref, callback)
  if not base_ref or base_ref == "" then
    callback(nil, nil)
    return
  end
  head_ref = head_ref or "HEAD"
  local signature = ensure_context_cache_current()
  local key = table.concat({ signature, resolved_ref(base_ref), resolved_ref(head_ref) }, "::")
  if context_cache.merge_base[key] ~= nil then
    callback(context_cache.merge_base[key] ~= false and context_cache.merge_base[key] or nil, nil)
    return
  end
  if queue_pending(pending_context.merge_base, key, callback) then
    return
  end
  run_systemlist_async({ "git", "merge-base", base_ref, head_ref }, function(lines, err)
    local sha = lines and lines[1] or nil
    context_cache.merge_base[key] = sha or false
    for _, cb in ipairs(take_pending(pending_context.merge_base, key)) do
      cb(sha, err)
    end
  end)
end

---@param path string
---@return ReviewFile
function M.untracked_file_placeholder(path)
  return {
    path = path,
    status = "?",
    untracked = true,
    untracked_lazy = true,
    hunks = {},
  }
end

---@param path string
---@return ReviewFile
function M.build_untracked_file(path)
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
    untracked_lazy = false,
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

build_untracked_file = M.build_untracked_file

---@param file ReviewFile
---@return ReviewFile
function M.hydrate_untracked_file(file)
  if not file or not file.untracked or not file.untracked_lazy then
    return file
  end
  local hydrated = M.build_untracked_file(file.path)
  for key, value in pairs(hydrated) do
    file[key] = value
  end
  file._review_cache = nil
  return file
end

---@return ReviewFile[]
function M.untracked_files()
  local result = {}
  for _, path in ipairs(M.untracked_paths()) do
    table.insert(result, M.untracked_file_placeholder(path))
  end
  return result
end

--- List commits in a range.
---@param base_ref string  Base ref (e.g. "main", "HEAD~5")
---@param head_ref string|nil  Head ref (default: "HEAD")
---@return ReviewCommit[]
local function parse_log_lines(out)
  local commits = {}
  for _, line in ipairs(out or {}) do
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

function M.log(base_ref, head_ref)
  head_ref = head_ref or "HEAD"
  local signature = ensure_context_cache_current()
  local range = base_ref .. ".." .. head_ref
  local key = table.concat({ signature, range, resolved_ref(base_ref), resolved_ref(head_ref) }, "::")
  if context_cache.log[key] then
    return vim.deepcopy(context_cache.log[key])
  end
  -- Format: sha<TAB>short_msg<TAB>author_name
  local out = run_systemlist({
    "git",
    "log",
    "--format=%H\t%s\t%an",
    range,
  })
  if not out then
    context_cache.log[key] = {}
    return {}
  end

  local commits = parse_log_lines(out)
  context_cache.log[key] = vim.deepcopy(commits)
  return commits
end

---@param limit number|nil
---@return ReviewCommit[]
function M.recent_commits(limit)
  limit = limit or 20
  local out = run_systemlist({
    "git",
    "log",
    "--format=%H\t%s\t%an",
    "-n",
    tostring(limit),
    "--all",
  })
  return parse_log_lines(out or {})
end

---@param base_ref string
---@param head_ref string|nil
---@param callback fun(commits: table[], err: string|nil)
function M.log_async(base_ref, head_ref, callback)
  head_ref = head_ref or "HEAD"
  local signature = ensure_context_cache_current()
  local range = base_ref .. ".." .. head_ref
  local key = table.concat({ signature, range, resolved_ref(base_ref), resolved_ref(head_ref) }, "::")
  if context_cache.log[key] then
    callback(vim.deepcopy(context_cache.log[key]), nil)
    return
  end
  if queue_pending(pending_context.log, key, callback) then
    return
  end
  run_systemlist_async({
    "git",
    "log",
    "--format=%H\t%s\t%an",
    range,
  }, function(lines, err)
    if not lines then
      context_cache.log[key] = {}
      for _, cb in ipairs(take_pending(pending_context.log, key)) do
        cb({}, err)
      end
      return
    end
    local commits = parse_log_lines(lines)
    context_cache.log[key] = vim.deepcopy(commits)
    for _, cb in ipairs(take_pending(pending_context.log, key)) do
      cb(vim.deepcopy(commits), nil)
    end
  end)
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
  context_cache_signature = nil
  reset_context_cache(true)
end

return M
