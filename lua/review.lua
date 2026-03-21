--- review.nvim — Minimal code review plugin for Neovim.
--- Entry point: setup(), config, command dispatch.
local M = {}

---@class ReviewConfig
---@field view string  "unified" (default) — split view comes in Phase 2
local defaults = {
  view = "unified",
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
  local diff_mod = require("review.diff")
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

  local mode = "local"
  local ref = nil

  if #args > 0 and args[1] == "pr" then
    mode = "pr"
    -- PR mode will be implemented in Phase 4
    if #args > 1 then
      -- :Review pr 123
      vim.notify("PR mode coming soon. For now, use :Review [ref] for local diffs.", vim.log.levels.INFO)
      return
    else
      -- :Review pr — auto-detect
      vim.notify("PR mode coming soon. For now, use :Review [ref] for local diffs.", vim.log.levels.INFO)
      return
    end
  elseif #args > 0 then
    ref = args[1]
  end

  -- Local mode: get diff
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

  -- Create session and open UI
  state.create(mode, ref or "HEAD", files)

  -- Load commits in the range (if diffing against a ref)
  if ref then
    local commits = git.log(ref)
    if #commits > 0 then
      state.set_commits(commits)
    end
  end

  ui.open()
end

--- Close the current review session.
function M.close()
  local ui = require("review.ui")
  ui.close()
end

--- Submit draft comments (PR mode only).
function M.submit()
  local state = require("review.state")
  local s = state.get()
  if not s then
    vim.notify("No active review session", vim.log.levels.ERROR)
    return
  end
  if s.mode ~= "pr" then
    vim.notify("Submit is only available in PR mode", vim.log.levels.WARN)
    return
  end
  -- Will be implemented in Phase 4
  vim.notify("Submit coming in Phase 4", vim.log.levels.INFO)
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
      table.insert(lines, string.format("**Line %s** (%s):", line_ref, note.side))
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
