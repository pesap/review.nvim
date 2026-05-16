describe("review.ui.blame", function()
  local blame
  local state
  local git
  local original_blame_module
  local original_state_module
  local original_storage_module
  local original_git_module

  before_each(function()
    original_blame_module = package.loaded["review.ui.blame"]
    original_state_module = package.loaded["review.state"]
    original_storage_module = package.loaded["review.storage"]
    original_git_module = package.loaded["review.git"]

    package.loaded["review.ui.blame"] = nil
    package.loaded["review.state"] = nil
    package.loaded["review.git"] = nil
    package.loaded["review.storage"] = {
      load = function()
        return {}
      end,
      save = function() end,
    }

    state = require("review.state")
    git = require("review.git")
    blame = require("review.ui.blame")

    git.root = function()
      return "/tmp/review-blame-spec"
    end
    git.current_branch = function()
      return "feature/blame"
    end
    git.blame_async = function(ref, _, callback)
      local label = ref == nil and "head" or "base"
      callback({
        "abc123456789 (Reviewer 2026-05-15 12:00:00 -0600 2) " .. label .. " code",
      }, nil)
    end

    local diff_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, diff_buf)
    state.create("local", "main", {
      { path = "lua/review.lua", status = "M", hunks = {} },
    }, {
      repo_root = "/tmp/review-blame-spec",
      branch = "feature/blame",
    })
    state.set_ui({
      diff_buf = diff_buf,
      diff_win = vim.api.nvim_get_current_win(),
      view_mode = "unified",
    })
  end)

  after_each(function()
    pcall(blame.close)
    if state then
      state.destroy()
    end
    package.loaded["review.ui.blame"] = original_blame_module
    package.loaded["review.state"] = original_state_module
    package.loaded["review.storage"] = original_storage_module
    package.loaded["review.git"] = original_git_module
  end)

  it("opens a side panel and queues selected blame context", function()
    local queued
    blame.toggle({ path = "lua/review.lua" }, {
      next_request_token = function()
        return 1
      end,
      request_is_current = function(token)
        return token == 1
      end,
      queue_context = function(kind, value)
        queued = { kind = kind, value = value }
      end,
    })

    local ui_state = state.get_ui()
    assert.is_true(vim.api.nvim_win_is_valid(ui_state.blame_win))
    assert.is_true(vim.api.nvim_buf_is_valid(ui_state.blame_buf))

    vim.api.nvim_set_current_win(ui_state.blame_win)
    vim.api.nvim_win_set_cursor(ui_state.blame_win, { 2, 0 })
    vim.api.nvim_feedkeys("a", "x", false)

    assert.are.equal("blame_context", queued.kind)
    assert.is_true(queued.value:find("abc12345", 1, true) ~= nil)
  end)

  it("closes an open blame side panel", function()
    blame.toggle({ path = "lua/review.lua" }, {
      next_request_token = function()
        return 1
      end,
      request_is_current = function()
        return true
      end,
    })

    local win = state.get_ui().blame_win
    assert.is_true(vim.api.nvim_win_is_valid(win))

    blame.close()

    assert.is_false(vim.api.nvim_win_is_valid(win))
    assert.is_nil(state.get_ui().blame_win)
  end)

  it("preserves the left rail width across repeated opens", function()
    local ui_state = state.get_ui()
    vim.api.nvim_set_current_win(ui_state.diff_win)
    vim.cmd("leftabove vertical new")
    local rail_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_width(rail_win, 24)
    ui_state.files_win = rail_win
    ui_state.explorer_win = rail_win
    ui_state.explorer_width = 24
    vim.api.nvim_set_current_win(ui_state.diff_win)

    blame.toggle({ path = "lua/review.lua" }, {
      next_request_token = function()
        return 1
      end,
      request_is_current = function()
        return true
      end,
    })

    local initial_width = vim.api.nvim_win_get_width(ui_state.files_win)
    blame.close()
    blame.toggle({ path = "lua/review.lua" }, {
      next_request_token = function()
        return 2
      end,
      request_is_current = function()
        return true
      end,
    })

    assert.are.equal(initial_width, vim.api.nvim_win_get_width(ui_state.files_win))
  end)

  it("scrollbinds blame with the unified diff and clears it on close", function()
    blame.toggle({ path = "lua/review.lua" }, {
      next_request_token = function()
        return 1
      end,
      request_is_current = function()
        return true
      end,
    })

    local ui_state = state.get_ui()
    assert.is_true(vim.wo[ui_state.blame_win].scrollbind)
    assert.is_true(vim.wo[ui_state.diff_win].scrollbind)

    blame.close()

    assert.is_false(vim.wo[ui_state.diff_win].scrollbind)
  end)

  it("keeps split diff panes scrollbound when blame closes", function()
    local split_buf = vim.api.nvim_create_buf(false, true)
    vim.cmd("rightbelow vsplit")
    local split_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(split_win, split_buf)
    local ui_state = state.get_ui()
    ui_state.split_buf = split_buf
    ui_state.split_win = split_win
    ui_state.view_mode = "split"

    blame.toggle({ path = "lua/review.lua" }, {
      next_request_token = function()
        return 1
      end,
      request_is_current = function()
        return true
      end,
    })

    assert.is_true(vim.wo[ui_state.blame_win].scrollbind)
    assert.is_true(vim.wo[ui_state.diff_win].scrollbind)
    assert.is_true(vim.wo[ui_state.split_win].scrollbind)

    blame.close()

    assert.is_true(vim.wo[ui_state.diff_win].scrollbind)
    assert.is_true(vim.wo[ui_state.split_win].scrollbind)
  end)

  it("does not repeat unchanged blame metadata on contiguous lines", function()
    git.blame_async = function(_, _, callback)
      callback({
        "abc123456789 (Reviewer 2026-05-15 12:00:00 -0600 2) same commit | first line",
        "abc123456789 (Reviewer 2026-05-15 12:00:00 -0600 3) same commit | second line",
        "def987654321 (Reviewer 2026-05-16 12:00:00 -0600 4) next commit | third line",
      }, nil)
    end

    blame.toggle({ path = "lua/review.lua" }, {
      next_request_token = function()
        return 1
      end,
      request_is_current = function()
        return true
      end,
    })

    local lines = vim.api.nvim_buf_get_lines(state.get_ui().blame_buf, 0, -1, false)
    assert.is_true(lines[2]:find("abc12345", 1, true) ~= nil)
    assert.is_true(lines[3]:find("abc12345", 1, true) == nil)
    assert.is_true(lines[3]:find("second line", 1, true) ~= nil)
    assert.is_true(lines[4]:find("def98765", 1, true) ~= nil)
  end)

  it("toggles blame between base and head refs", function()
    local refs = {}
    git.blame_async = function(ref, path, callback)
      table.insert(refs, { ref = ref, path = path })
      local label = ref == nil and "head" or "base"
      callback({
        "abc123456789 (Reviewer 2026-05-15 12:00:00 -0600 2) " .. label .. " code",
      }, nil)
    end

    blame.toggle({ path = "lua/review.lua" }, {
      next_request_token = function()
        return #refs + 1
      end,
      request_is_current = function()
        return true
      end,
    })

    local ui_state = state.get_ui()
    local lines = vim.api.nvim_buf_get_lines(ui_state.blame_buf, 0, -1, false)
    assert.are.equal(" Blame base: main", lines[1])
    assert.is_true(lines[2]:find("base code", 1, true) ~= nil)

    vim.api.nvim_set_current_win(ui_state.blame_win)
    vim.api.nvim_feedkeys("t", "x", false)

    ui_state = state.get_ui()
    lines = vim.api.nvim_buf_get_lines(ui_state.blame_buf, 0, -1, false)
    assert.are.equal(" Blame head: HEAD", lines[1])
    assert.is_true(lines[2]:find("head code", 1, true) ~= nil)
    assert.are.equal("main", refs[1].ref)
    assert.is_nil(refs[2].ref)
    assert.are.equal("lua/review.lua", refs[2].path)
  end)
end)
