--- review.nvim — Minimal code review plugin for Neovim.
--- Entry point: setup(), config, command dispatch.
local M = {}

---@class ReviewConfig
local defaults = {
  view = "unified",
  colorblind = true,
  provider = nil, ---@type string|nil  "github"|"gitlab"|nil (nil = auto-detect from remote URL)
  keymaps = {
    add_note = "a",
    edit_note = "e",
    delete_note = "d",
    next_hunk = "]c",
    prev_hunk = "[c",
    next_file = "]f",
    prev_file = "[f",
    next_note = "]n",
    prev_note = "[n",
    toggle_split = "s",
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

--- Open a review session.
--- Usage:
---   :Review          — auto-detect: if on a branch with an open PR, open PR mode; otherwise diff against HEAD
---   :Review HEAD~3   — local diff against HEAD~3
---   :Review pr       — open PR for current branch
---   :Review pr 123   — open PR #123
---@param args string[]
function M.open(args)
  args = args or {}

  local git = require("review.git")
  local state = require("review.state")
  local ui = require("review.ui")

  -- Close any existing session
  if state.get() then
    ui.close()
  end

  -- Check we're in a git repo
  if not git.root() then
    vim.notify("Not in a git repository", vim.log.levels.ERROR)
    return
  end

  local forge = require("review.forge")

  if #args > 0 then
    local ref = args[1]
    M._open_with_ref(ref)
    return
  end

  -- Check if we have a cached forge detect result (instant)
  local cached = forge.get_cached_detect()
  if cached then
    local base = git.default_branch()
    if base then
      vim.notify(
        string.format("Reviewing %s PR #%d against %s", cached.forge, cached.pr_number, base),
        vim.log.levels.INFO
      )
      M._open_with_ref(base)
      state.set_forge_info(cached)
      M.refresh_comments()
      return
    end
  end

  -- No cache — open with default branch diff, detect PR in background
  local base = git.default_branch()
  if base then
    M._open_with_ref(base)

    forge.detect_async(function(info)
      if not state.get() then
        return
      end
      if info then
        state.set_forge_info(info)
        vim.notify(string.format("Detected %s PR #%d", info.forge, info.pr_number), vim.log.levels.INFO)
        M.refresh_comments()
      end
    end)
  else
    M._open_with_ref(nil)
  end
end

--- Internal: open the review UI with a given ref.
---@param ref string|nil
function M._open_with_ref(ref)
  local git = require("review.git")
  local diff_mod = require("review.diff")
  local state = require("review.state")
  local ui = require("review.ui")
  local diff_text = git.diff(ref)
  if diff_text == "" then
    vim.notify("No changes to review" .. (ref and (" against " .. ref) or ""), vim.log.levels.INFO)
    return
  end

  local files = diff_mod.parse(diff_text)
  if #files == 0 then
    vim.notify("No files changed", vim.log.levels.INFO)
    return
  end

  state.create("local", ref or "HEAD", files)

  if ref then
    local commits = git.log(ref)
    if #commits > 0 then
      state.set_commits(commits)
    end
  end

  ui.open()
end

--- Fetch (or re-fetch) remote PR comments and refresh the UI.
--- Runs asynchronously — UI updates when comments arrive.
function M.refresh_comments()
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

  -- Clear existing remote notes
  state.clear_remote_comments()

  -- Fetch asynchronously
  forge.fetch_comments_async(forge_info, function(comments, fetch_err)
    -- Verify session is still active
    if not state.get() then
      return
    end

    if fetch_err then
      vim.notify("Could not load PR comments: " .. fetch_err, vim.log.levels.WARN)
      return
    end

    if comments and #comments > 0 then
      state.load_remote_comments(comments)
      vim.notify(string.format("Loaded %d conversation(s) from PR", #comments), vim.log.levels.INFO)
    end

    local ui = require("review.ui")
    ui.refresh()
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

--- Export notes to markdown (local mode).
---@param path string|nil
function M.export(path)
  local state = require("review.state")
  local s = state.get()
  if not s then
    vim.notify("No active review session", vim.log.levels.ERROR)
    return
  end

  local notes = state.get_notes()
  if #notes == 0 then
    vim.notify("No notes to export", vim.log.levels.INFO)
    return
  end

  -- Build markdown
  local lines = { "# Code Review Notes", "" }

  -- Group by file
  local by_file = {}
  for _, note in ipairs(notes) do
    if not by_file[note.file_path] then
      by_file[note.file_path] = {}
    end
    table.insert(by_file[note.file_path], note)
  end

  for file_path, file_notes in pairs(by_file) do
    table.insert(lines, "## " .. file_path)
    table.insert(lines, "")
    for _, note in ipairs(file_notes) do
      local line_ref = tostring(note.line)
      if note.end_line then
        line_ref = line_ref .. "-" .. tostring(note.end_line)
      end
      local kind = (note.note_type == "suggestion") and "suggestion" or "comment"
      table.insert(lines, string.format("**Line %s** (%s, %s):", line_ref, note.side, kind))
      table.insert(lines, "")
      table.insert(lines, note.body)
      table.insert(lines, "")
    end
  end

  local content = table.concat(lines, "\n")
  path = path or "review-notes.md"

  vim.fn.writefile(vim.split(content, "\n"), path)
  vim.notify("Notes exported to " .. path, vim.log.levels.INFO)
end

return M
