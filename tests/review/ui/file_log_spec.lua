describe("review.ui.file_log", function()
  local file_log
  local git
  local original_file_log_module
  local original_git_module

  local function close_current_float()
    local win = vim.api.nvim_get_current_win()
    if win and vim.api.nvim_win_is_valid(win) then
      local cfg = vim.api.nvim_win_get_config(win)
      if cfg and cfg.relative ~= "" then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
  end

  before_each(function()
    original_file_log_module = package.loaded["review.ui.file_log"]
    original_git_module = package.loaded["review.git"]

    package.loaded["review.ui.file_log"] = nil
    file_log = require("review.ui.file_log")
    git = require("review.git")

    git.file_history_async = function(_, callback)
      callback({
        "def67890\t2026-05-15\tReviewer\tfix context",
      }, nil)
    end
    git.file_show = function(sha, path)
      return table.concat({
        "commit " .. sha,
        "diff --git a/" .. path .. " b/" .. path,
        "+changed line",
      }, "\n")
    end
    git.file_show_async = function(sha, path, callback)
      callback(git.file_show(sha, path), nil)
    end
  end)

  after_each(function()
    close_current_float()
    package.loaded["review.ui.file_log"] = original_file_log_module
    package.loaded["review.git"] = original_git_module
  end)

  it("opens file history, queues selected context, and drills into a commit diff", function()
    local queued
    file_log.open({ path = "lua/review.lua" }, {
      next_request_token = function()
        return 7
      end,
      request_is_current = function(token)
        return token == 7
      end,
      queue_context = function(kind, value)
        queued = { kind = kind, value = value }
      end,
    })

    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_get_current_buf()
    assert.are_not.equal("", vim.api.nvim_win_get_config(win).relative)

    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert.are.equal(" File history: lua/review.lua", lines[1])
    assert.is_true(lines[3]:find("def67890", 1, true) ~= nil)

    vim.api.nvim_win_set_cursor(win, { 3, 0 })
    vim.api.nvim_feedkeys("a", "x", false)

    assert.are.equal("log_context", queued.kind)
    assert.is_true(queued.value:find("def67890", 1, true) ~= nil)

    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)

    local diff_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert.are.equal("commit def67890", diff_lines[1])
    assert.are.equal("diff --git a/lua/review.lua b/lua/review.lua", diff_lines[2])
    assert.are.equal("+changed line", diff_lines[3])
  end)
end)
