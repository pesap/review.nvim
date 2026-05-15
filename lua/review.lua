--- review.nvim — Minimal code review plugin for Neovim.
--- Entry point: setup(), config, command dispatch.
local M = {}
local comments_request_seq = 0
local local_refresh_seq = 0

---@class ReviewConfig
local defaults = {
  view = "unified",
  render = {
    word_diff = {
      enabled = true,
      max_line_length = 300,
      max_pairs_per_hunk = 64,
      max_hunk_lines = 200,
      max_file_lines = 1500,
    },
  },
  notifications = {
    context = false,
  },
  colorblind = true,
  provider = nil, ---@type string|nil  "github"|"gitlab"|nil (nil = auto-detect from remote URL)
  keymaps = {
    add_note = "a",
    edit_note = "e",
    delete_note = "d",
    help = "?",
    next_hunk = "]c",
    prev_hunk = "[c",
    next_file = "]f",
    prev_file = "[f",
    next_note_short = nil,
    next_note = "]n",
    prev_note = "[n",
    toggle_split = "s",
    toggle_stack = "<Tab>",
    refresh = "R",
    focus_files = "f",
    focus_diff = "<leader>d",
    focus_git = nil,
    focus_threads = "T",
    toggle_file_tree = "t",
    sort_files = "o",
    toggle_reviewed = "H",
    filter_attention = "A",
    change_base = "B",
    mark_baseline = "M",
    compare_baseline = "V",
    compare_unit = "C",
    commit_details = "K",
    blame = "b",
    file_history = "L",
    notes_list = "N",
    suggestion = "S",
    close = "q",
  },
}

---@type ReviewConfig
M.config = vim.deepcopy(defaults)

--- Plugin setup.
---@param opts ReviewConfig|nil
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", defaults, opts or {})
end

---@param msg string
---@param level integer
---@param enabled boolean|nil
local function notify(msg, level, enabled)
  if enabled == false then
    return
  end
  vim.notify(msg, level)
end

---@param base_ref string|nil
local function hydrate_cached_remote_bundle(base_ref)
  local state = require("review.state")
  local storage = require("review.storage")
  local ui = require("review.ui")

  local bundle = storage.load_remote_bundle(base_ref)
  if not bundle or not bundle.info then
    return false
  end

  state.set_forge_info(bundle.info)
  state.clear_remote_comments()
  if bundle.comments and #bundle.comments > 0 then
    state.load_remote_comments(bundle.comments)
  end
  state.set_remote_summary(bundle.summary)

  if state.get_ui() then
    ui.refresh()
  end
  return true
end

---@param opts table|nil
---@return boolean
local function open_gitbutler_workspace(opts)
  opts = opts or {}
  local git = require("review.git")
  local gitbutler = require("review.gitbutler")
  local state = require("review.state")
  local ui = require("review.ui")

  local review_data, err = gitbutler.workspace_review()
  if not review_data then
    vim.notify("Could not read GitButler workspace: " .. (err or "unknown"), vim.log.levels.WARN)
    return false
  end
  if #review_data.files == 0 then
    vim.notify("No GitButler changes to review", vim.log.levels.INFO)
    return false
  end

  local base_ref = review_data.metadata and review_data.metadata.mergeBase and review_data.metadata.mergeBase.commitId
    or "gitbutler/workspace"
  state.create("local", base_ref, review_data.files, {
    vcs = "gitbutler",
    repo_root = git.root(),
    branch = git.current_branch() or "gitbutler/workspace",
    requested_ref = opts.requested_ref,
    untracked_files = review_data.untracked_files or {},
    gitbutler = review_data.metadata,
  })
  state.set_commits(review_data.commits or {})

  local review_ids = {}
  for _, commit in ipairs(review_data.commits or {}) do
    local gb = commit.gitbutler
    if gb and gb.review_id then
      review_ids[tostring(gb.review_id)] = gb.review_id
    end
  end
  local single_review_id = nil
  local review_count = 0
  for _, review_id in pairs(review_ids) do
    single_review_id = review_id
    review_count = review_count + 1
  end
  local remote = git.parse_remote()
  local has_single_forge_review = false
  local numeric_review_id = tonumber(single_review_id)
  if review_count == 1 and remote and numeric_review_id then
    state.set_forge_info({
      forge = remote.forge,
      owner = remote.owner,
      repo = remote.repo,
      pr_number = numeric_review_id,
    })
    has_single_forge_review = true
    hydrate_cached_remote_bundle(base_ref)
  end

  if opts.open_ui ~= false then
    ui.open()
    if has_single_forge_review then
      M.refresh_comments()
    end
  end

  return true
end

---@param ref string|nil
---@param opts table|nil
---@return boolean
function M._open_with_ref(ref, opts)
  opts = opts or {}

  local git = require("review.git")
  local gitbutler = require("review.gitbutler")
  local diff_mod = require("review.diff")
  local state = require("review.state")
  local ui = require("review.ui")

  if not ref and gitbutler.is_workspace() then
    return open_gitbutler_workspace(opts)
  end

  local diff_text = git.diff(ref)
  if diff_text == "" then
    vim.notify("No changes to review" .. (ref and (" against " .. ref) or ""), vim.log.levels.INFO)
    return false
  end

  local files = diff_mod.parse(diff_text)
  local untracked_files = git.untracked_files()
  if #files == 0 then
    if #untracked_files == 0 then
      vim.notify("No files changed", vim.log.levels.INFO)
      return false
    end
  end

  state.create("local", ref or "HEAD", files, {
    repo_root = git.root(),
    branch = git.current_branch() or "HEAD",
    head_ref = git.current_head and git.current_head() or nil,
    merge_base_ref = ref and git.merge_base and git.merge_base(ref, "HEAD") or nil,
    requested_ref = opts.requested_ref,
    untracked_files = untracked_files,
    workspace_signature = git.workspace_signature and git.workspace_signature() or nil,
  })

  if ref then
    local commits = git.log(ref)
    if #commits > 0 then
      state.set_commits(commits)
    end
  end

  if opts.open_ui ~= false then
    ui.open()
  end

  return true
end

--- Open a review session.
--- Usage:
---   :Review          — auto-detect: if on a branch with an open PR, review against default branch; otherwise diff against HEAD
---   :Review HEAD~3   — local diff against HEAD~3
---@param args string[]
function M.open(args)
  args = args or {}

  local git = require("review.git")
  local state = require("review.state")
  local ui = require("review.ui")

  git.invalidate_cache()
  require("review.gitbutler").invalidate_cache()

  -- Close any existing session
  if state.get() then
    ui.close()
  end

  -- Check we're in a git repo
  if not git.root() then
    vim.notify("Not in a git repository", vim.log.levels.ERROR)
    return
  end

  local gitbutler = require("review.gitbutler")
  local forge = require("review.forge")

  if #args > 0 then
    M._open_with_ref(args[1], { requested_ref = args[1] })
    return
  end

  if gitbutler.is_workspace() then
    M._open_with_ref(nil, { requested_ref = nil })
    return
  end

  -- Check if we have a cached forge detect result (instant)
  local cached = forge.get_cached_detect()
  if cached then
    local base = git.default_branch()
    if base then
      notify(
        string.format("Reviewing %s PR #%d against %s", cached.forge, cached.pr_number, base),
        vim.log.levels.INFO,
        M.config.notifications and M.config.notifications.context
      )
      if not M._open_with_ref(base, { requested_ref = nil }) then
        return
      end
      state.set_forge_info(cached)
      hydrate_cached_remote_bundle(base)
      M.refresh_comments()
      return
    end
  end

  -- No cache — open with default branch diff, detect PR in background
  local base = git.default_branch()
  if base then
    local opened = M._open_with_ref(base, { requested_ref = nil })
    if not opened then
      return
    end

    local hydrated = hydrate_cached_remote_bundle(base)
    if hydrated then
      M.refresh_comments()
    end

    forge.detect_async(function(info)
      if not state.get() then
        return
      end
      if info then
        local previous = state.get_forge_info()
        local had_info = previous ~= nil
        local changed = not previous
          or previous.forge ~= info.forge
          or previous.owner ~= info.owner
          or previous.repo ~= info.repo
          or previous.pr_number ~= info.pr_number
        state.set_forge_info(info)
        if not had_info then
          hydrate_cached_remote_bundle(base)
        end
        if changed or not hydrated then
          notify(
            string.format("Detected %s PR #%d", info.forge, info.pr_number),
            vim.log.levels.INFO,
            M.config.notifications and M.config.notifications.context
          )
          M.refresh_comments()
        end
      end
    end)
  else
    M._open_with_ref(nil, { requested_ref = nil })
  end
end

function M.reopen_session()
  local state = require("review.state")
  local s = state.get()
  if not s then
    return
  end
  local requested_ref = s.requested_ref
  M.open(requested_ref and { requested_ref } or {})
end

---@param ref string|nil
---@return boolean|nil
function M.change_base(ref)
  local state = require("review.state")
  local s = state.get()
  if not s then
    vim.notify("No active review session", vim.log.levels.ERROR)
    return false
  end
  if s.mode ~= "local" then
    vim.notify("Base can only be changed for local review sessions", vim.log.levels.WARN)
    return false
  end
  if s.vcs == "gitbutler" then
    vim.notify("GitButler review base comes from workspace metadata", vim.log.levels.WARN)
    return false
  end

  ref = ref and vim.trim(ref) or nil
  if not ref or ref == "" then
    vim.ui.input({ prompt = "Review base: ", default = s.base_ref or "HEAD" }, function(input)
      if input and vim.trim(input) ~= "" then
        M.change_base(input)
      end
    end)
    return nil
  end

  local old_base = s.base_ref
  local old_requested = s.requested_ref
  local old_commit_idx = s.current_commit_idx
  local old_scope_mode = s.scope_mode
  local old_file_idx = s.current_file_idx

  s.base_ref = ref
  s.requested_ref = ref
  s.current_commit_idx = nil
  s.scope_mode = "all"
  s.current_file_idx = 1

  if not M.refresh_local_session() then
    s.base_ref = old_base
    s.requested_ref = old_requested
    s.current_commit_idx = old_commit_idx
    s.scope_mode = old_scope_mode
    s.current_file_idx = old_file_idx
    vim.notify("Could not change review base to " .. ref, vim.log.levels.WARN)
    return false
  end

  require("review.storage").save(s)
  local ui = require("review.ui")
  if state.get_ui() then
    ui.refresh()
  end
  vim.notify("Review base changed to " .. ref, vim.log.levels.INFO)
  return true
end

---@return boolean
function M.mark_baseline()
  local state = require("review.state")
  local s = state.get()
  if not s then
    vim.notify("No active review session", vim.log.levels.ERROR)
    return false
  end
  if s.mode ~= "local" or s.vcs == "gitbutler" then
    vim.notify("Baselines are available for local git review sessions", vim.log.levels.WARN)
    return false
  end
  local head = require("review.git").current_head()
  if not head then
    vim.notify("Could not resolve HEAD for review baseline", vim.log.levels.WARN)
    return false
  end
  s.review_baseline_ref = head
  state.mark_review_snapshot(head)
  state.update_ui_prefs({ review_baseline_ref = head })
  vim.notify("Review baseline marked at " .. head:sub(1, 12), vim.log.levels.INFO)
  return true
end

---@return boolean
function M.compare_baseline()
  local state = require("review.state")
  local s = state.get()
  if not s then
    vim.notify("No active review session", vim.log.levels.ERROR)
    return false
  end
  local baseline = s.review_baseline_ref or state.get_ui_prefs().review_baseline_ref
  if not baseline or baseline == "" then
    vim.notify("No review baseline marked; run :ReviewMarkBaseline first", vim.log.levels.WARN)
    return false
  end
  return M.change_base(baseline) == true
end

---@param s ReviewSession
---@return string|nil
local function session_diff_ref(s)
  local diff_ref = s.requested_ref
  if diff_ref == nil and s.base_ref ~= "HEAD" then
    diff_ref = s.base_ref
  end
  return diff_ref
end

---@param previous_commits table[]
---@param previous_commit_sha string|nil
---@return table<string, table>, string|nil
local function previous_commit_state(previous_commits, previous_commit_sha)
  local previous_commit_by_sha = {}
  for _, commit in ipairs(previous_commits or {}) do
    previous_commit_by_sha[commit.sha] = commit
  end
  return previous_commit_by_sha, previous_commit_sha
end

---@param s ReviewSession
---@param diff_text string
---@param commits table[]
---@param workspace_signature string|nil
---@param previous_commit_by_sha table<string, table>
---@param previous_commit_sha string|nil
---@param merge_base_ref string|nil
local function apply_local_git_refresh(
  s,
  diff_text,
  commits,
  workspace_signature,
  previous_commit_by_sha,
  previous_commit_sha,
  merge_base_ref
)
  local state = require("review.state")
  local git = require("review.git")
  local diff_mod = require("review.diff")

  s.files = diff_mod.parse(diff_text or "")
  s.untracked_files = git.untracked_files()
  s.repo_root = git.root()
  s.branch = git.current_branch() or "HEAD"
  s.head_ref = git.current_head and git.current_head() or nil
  s.merge_base_ref = merge_base_ref
  s.commits = commits or {}
  s.workspace_signature = workspace_signature or (git.workspace_signature and git.workspace_signature() or nil)

  local remapped_commit_idx = nil
  for idx, commit in ipairs(s.commits) do
    local previous = previous_commit_by_sha[commit.sha]
    if previous and previous.files ~= nil then
      commit.files = previous.files
    end
    if previous_commit_sha and commit.sha == previous_commit_sha then
      remapped_commit_idx = idx
    end
  end

  if previous_commit_sha then
    s.current_commit_idx = remapped_commit_idx
    if not remapped_commit_idx then
      s.scope_mode = "all"
    end
  elseif s.current_commit_idx and not s.commits[s.current_commit_idx] then
    s.current_commit_idx = nil
    s.scope_mode = "all"
  end

  local active_files = state.active_files()
  if #active_files == 0 then
    s.current_file_idx = 1
  else
    s.current_file_idx = math.min(math.max(s.current_file_idx or 1, 1), #active_files)
  end
end

---@param s ReviewSession
---@return table<string, table>, string|nil
local function snapshot_commit_state(s)
  local previous_commits = s.commits or {}
  local previous_commit_sha = s.current_commit_idx
      and previous_commits[s.current_commit_idx]
      and previous_commits[s.current_commit_idx].sha
    or nil
  return previous_commit_state(previous_commits, previous_commit_sha)
end

---@param s ReviewSession
---@param review_data table
local function apply_gitbutler_refresh(s, review_data)
  local state = require("review.state")
  local git = require("review.git")

  s.files = review_data.files
  s.untracked_files = review_data.untracked_files or {}
  s.repo_root = git.root()
  s.branch = git.current_branch() or "gitbutler/workspace"
  s.gitbutler = review_data.metadata
  s.commits = review_data.commits or {}
  if s.current_commit_idx and not s.commits[s.current_commit_idx] then
    s.current_commit_idx = nil
    s.scope_mode = "all"
  end
  local active_files = state.active_files()
  if #active_files == 0 then
    s.current_file_idx = 1
  else
    s.current_file_idx = math.min(math.max(s.current_file_idx or 1, 1), #active_files)
  end
end

---@param workspace_signature string|nil
---@return boolean
function M.refresh_local_session(workspace_signature)
  local state = require("review.state")
  local s = state.get()
  if not s or s.mode ~= "local" then
    return false
  end

  local git = require("review.git")
  local gitbutler = require("review.gitbutler")

  git.invalidate_cache()
  gitbutler.invalidate_cache()
  local_refresh_seq = local_refresh_seq + 1

  if s.vcs == "gitbutler" then
    local review_data = gitbutler.workspace_review()
    if not review_data then
      return false
    end
    apply_gitbutler_refresh(s, review_data)
    return true
  end

  local previous_commit_by_sha, previous_commit_sha = snapshot_commit_state(s)
  local diff_ref = session_diff_ref(s)
  local diff_text = git.diff(diff_ref)
  local commits = diff_ref and git.log(diff_ref) or {}
  local merge_base_ref = diff_ref and git.merge_base and git.merge_base(diff_ref, "HEAD") or nil
  apply_local_git_refresh(
    s,
    diff_text,
    commits,
    workspace_signature,
    previous_commit_by_sha,
    previous_commit_sha,
    merge_base_ref
  )

  return true
end

---@param workspace_signature string|nil
---@param callback fun(ok: boolean, err: string|nil)
function M.refresh_local_session_async(workspace_signature, callback)
  local state = require("review.state")
  local s = state.get()
  if not s or s.mode ~= "local" then
    callback(false, "No active local review session")
    return
  end

  local git = require("review.git")
  local gitbutler = require("review.gitbutler")

  git.invalidate_cache()
  gitbutler.invalidate_cache()
  local_refresh_seq = local_refresh_seq + 1
  local request_token = local_refresh_seq
  state.set_local_refresh_loading(true)

  if s.vcs == "gitbutler" then
    if type(gitbutler.workspace_review_async) ~= "function" then
      local ok = M.refresh_local_session(workspace_signature)
      state.set_local_refresh_loading(false)
      callback(ok, nil)
      return
    end
    gitbutler.workspace_review_async(function(review_data, err)
      if request_token ~= local_refresh_seq or state.get() ~= s then
        callback(false, "superseded")
        return
      end
      if not review_data then
        state.set_local_refresh_loading(false)
        callback(false, err)
        return
      end
      apply_gitbutler_refresh(s, review_data)
      state.set_local_refresh_loading(false)
      callback(true, nil)
    end)
    return
  end

  local previous_commit_by_sha, previous_commit_sha = snapshot_commit_state(s)
  local diff_ref = session_diff_ref(s)
  local diff_done = false
  local log_done = diff_ref == nil
  local merge_base_done = diff_ref == nil
  local diff_text = ""
  local commits = {}
  local merge_base_ref = nil
  local first_err = nil

  local function finish()
    if not diff_done or not log_done or not merge_base_done then
      return
    end
    if request_token ~= local_refresh_seq or state.get() ~= s then
      callback(false, "superseded")
      return
    end
    apply_local_git_refresh(
      s,
      diff_text,
      commits,
      workspace_signature,
      previous_commit_by_sha,
      previous_commit_sha,
      merge_base_ref
    )
    state.set_local_refresh_loading(false)
    callback(true, first_err)
  end

  local function load_diff(callback)
    if git.diff_async then
      git.diff_async(diff_ref, callback)
    else
      callback(git.diff(diff_ref), nil)
    end
  end

  local function load_log(callback)
    if not diff_ref then
      callback({}, nil)
    elseif git.log_async then
      git.log_async(diff_ref, nil, callback)
    else
      callback(git.log(diff_ref), nil)
    end
  end

  load_diff(function(result, err)
    diff_text = result or ""
    first_err = first_err or err
    diff_done = true
    finish()
  end)

  load_log(function(result, err)
    commits = result or {}
    first_err = first_err or err
    log_done = true
    finish()
  end)
  if diff_ref and git.merge_base_async then
    git.merge_base_async(diff_ref, "HEAD", function(result, err)
      merge_base_ref = result
      first_err = first_err or err
      merge_base_done = true
      finish()
    end)
  else
    merge_base_ref = diff_ref and git.merge_base and git.merge_base(diff_ref, "HEAD") or nil
    merge_base_done = true
    finish()
  end
end

--- Fetch (or re-fetch) remote PR comments and refresh the UI.
--- Runs asynchronously — UI updates when comments arrive.
---@param opts table|nil
function M.refresh_comments(opts)
  opts = opts or {}
  local state = require("review.state")
  local s = state.get()
  if not s then
    return
  end

  local forge_info = state.get_forge_info()
  if not forge_info then
    vim.notify("No PR/MR detected for this session", vim.log.levels.WARN)
    return
  end

  local forge = require("review.forge")
  local git = require("review.git")
  git.invalidate_cache()
  require("review.gitbutler").invalidate_cache()
  if not state.session_matches_vcs() then
    M.reopen_session()
    return
  end
  local function refresh_ui()
    local ui = require("review.ui")
    ui.refresh()
    if opts.preserve_notes_list then
      ui.refresh_notes_list()
    end
  end

  state.set_comments_loading(true)
  comments_request_seq = comments_request_seq + 1
  local request_token = comments_request_seq
  refresh_ui()

  -- Fetch asynchronously
  forge.fetch_comments_async(forge_info, function(comments, fetch_err, summary)
    -- Verify session is still active
    if not state.get() or request_token ~= comments_request_seq then
      return
    end

    state.set_comments_loading(false)

    if fetch_err then
      state.set_remote_context_stale(fetch_err)
      vim.notify("Could not load PR comments: " .. fetch_err, vim.log.levels.WARN)
      refresh_ui()
      return
    end

    state.set_remote_context_stale(nil)
    state.clear_remote_comments()
    if comments and #comments > 0 then
      state.load_remote_comments(comments)
    end
    state.set_remote_summary(summary)
    require("review.storage").save_remote_bundle(forge_info, s.base_ref, comments or {}, summary)

    refresh_ui()
  end)
end

--- Close the current review session.
function M.close()
  local ui = require("review.ui")
  ui.close()
end

--- Toggle the review panel open/closed.
function M.toggle()
  local state = require("review.state")
  if state.get() then
    M.close()
  else
    M.open({})
  end
end

function M.open_notes()
  local state = require("review.state")
  if not state.get() then
    vim.notify("No active review session", vim.log.levels.ERROR)
    return
  end
  require("review.ui").open_notes_list()
end

function M.open_help()
  require("review.ui").open_help()
end

---@param idx string|number|nil
function M.compare_unit(idx)
  require("review.ui").open_unit_compare(idx and tonumber(idx) or nil)
end

---@param content string
---@return string
local function copy_to_clipboard(content)
  vim.fn.setreg('"', content)
  local copied = {}
  local ok_plus = pcall(vim.fn.setreg, "+", content)
  if ok_plus then
    table.insert(copied, "+")
  end
  local ok_star = pcall(vim.fn.setreg, "*", content)
  if ok_star then
    table.insert(copied, "*")
  end
  if #copied == 0 then
    return [["]]
  end
  return table.concat(copied, ", ")
end

---@param opts table|nil
---@return string|nil, string|nil
function M.export_content(opts)
  return require("review.handoff").export_content(opts)
end

function M.copy_notes_to_clipboard()
  local content, err = M.export_content({ clipboard = true })
  if not content then
    vim.notify(err, err == "No active review session" and vim.log.levels.ERROR or vim.log.levels.INFO)
    return
  end

  local target = copy_to_clipboard(content)
  vim.notify("Notes copied to clipboard register(s): " .. target, vim.log.levels.INFO)
end

function M.copy_local_notes_to_clipboard()
  local content, err = M.export_content({ local_only = true })
  if not content then
    vim.notify(err, err == "No active review session" and vim.log.levels.ERROR or vim.log.levels.INFO)
    return
  end

  local target = copy_to_clipboard(content)
  vim.notify("Local notes copied to clipboard register(s): " .. target, vim.log.levels.INFO)
end

function M.clear_local_notes()
  local state = require("review.state")
  local s = state.get()
  if not s then
    vim.notify("No active review session", vim.log.levels.ERROR)
    return
  end

  local count = state.local_note_count()
  if count == 0 then
    vim.notify("No local notes to clear", vim.log.levels.INFO)
    return
  end

  local choice = vim.fn.confirm(
    string.format("Clear %d local note(s)?\nRemote GitHub/GitLab threads will be kept.", count),
    "&Clear\n&Cancel",
    2
  )
  if choice ~= 1 then
    return
  end

  local cleared = state.clear_local_notes()
  if cleared == 0 then
    vim.notify("No local notes to clear", vim.log.levels.INFO)
    return
  end

  require("review.ui").refresh()
  vim.notify(cleared .. " local note(s) cleared", vim.log.levels.INFO)
end

---@param raw string
---@return table|nil
local function parse_note_target(raw)
  if not raw or raw == "" then
    return nil
  end

  local normalized = raw:lower()
  if normalized == "unit" or normalized == "scope" then
    return {
      target_kind = "unit",
    }
  end
  if normalized == "discussion" or normalized == "general" or normalized == "pr" then
    return {
      target_kind = "discussion",
      is_general = true,
    }
  end

  local file_path, line, side = raw:match("^(.*):(%d+):(old)$")
  if not file_path then
    file_path, line, side = raw:match("^(.*):(%d+):(new)$")
  end
  if not file_path then
    file_path, line = raw:match("^(.*):(%d+)$")
  end
  if file_path and line then
    return {
      file_path = file_path,
      line = tonumber(line),
      side = side or "new",
      target_kind = "line",
    }
  end

  return nil
end

---@param args string[]
---@return table|nil, string|nil
function M.resolve_note_target(args)
  args = args or {}

  if #args > 0 then
    local first = tostring(args[1] or ""):lower()
    if first == "file" then
      if args[2] and args[2] ~= "" then
        return {
          file_path = args[2],
          target_kind = "file",
        }, nil
      end
      return nil, "Use :ReviewComment file path"
    end

    local target = parse_note_target(args[1])
    if target then
      return target, nil
    end

    if #args >= 2 then
      local line = tonumber(args[2])
      if line then
        return {
          file_path = args[1],
          line = line,
          side = args[3] == "old" and "old" or "new",
          target_kind = "line",
        },
          nil
      end
    end

    return {
      file_path = args[1],
      target_kind = "file",
    }, nil
  end
  return nil,
    "Use :ReviewComment, :ReviewComment path[:line[:old|new]], :ReviewComment file path, :ReviewComment unit, or :ReviewComment discussion"
end

---@param args string[]|nil
function M.add_note(args)
  local state = require("review.state")
  if not state.get() then
    vim.notify("No active review session", vim.log.levels.ERROR)
    return
  end

  if not args or #args == 0 then
    require("review.ui").open_note_float()
    return
  end

  local target, err = M.resolve_note_target(args)
  if not target then
    vim.notify(err or "Could not determine note target", vim.log.levels.WARN)
    return
  end

  require("review.ui").open_note_float_for_target(target, {})
end

---@param args string[]|nil
function M.add_suggestion(args)
  local state = require("review.state")
  if not state.get() then
    vim.notify("No active review session", vim.log.levels.ERROR)
    return
  end

  if not args or #args == 0 then
    require("review.ui").open_note_float({ suggestion = true })
    return
  end

  local target, err = M.resolve_note_target(args)
  if not target then
    vim.notify(err or "Could not determine note target", vim.log.levels.WARN)
    return
  end

  require("review.ui").open_note_float_for_target(target, { suggestion = true })
end

--- Export notes to markdown (local mode).
---@param path string|nil
function M.export(path)
  local content, err = M.export_content()
  if not content then
    vim.notify(err, err == "No active review session" and vim.log.levels.ERROR or vim.log.levels.INFO)
    return
  end
  path = path or "review-notes.md"

  vim.fn.writefile(vim.split(content, "\n"), path)
  vim.notify("Notes exported to " .. path, vim.log.levels.INFO)
end

return M
