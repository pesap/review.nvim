local review = require("review")

local function sample_hunk(old_line, new_line)
  return {
    header = string.format("@@ -%d,1 +%d,1 @@", old_line, new_line),
    old_start = old_line,
    old_count = 1,
    new_start = new_line,
    new_count = 1,
    lines = {
      { type = "ctx", text = "context", old_lnum = old_line - 1, new_lnum = new_line - 1 },
      { type = "del", text = "before", old_lnum = old_line },
      { type = "add", text = "after", new_lnum = new_line },
    },
  }
end

local function sample_git_file(path, status, section, old_line, new_line)
	return {
	  path = path,
	  status = status,
	  git_status = status,
	  git_section = section,
	  hunks = { sample_hunk(old_line, new_line) },
	}
end

local function close_current_float()
  local win = vim.api.nvim_get_current_win()
  if win and vim.api.nvim_win_is_valid(win) then
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg and cfg.relative ~= "" then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
end

local function send_keys(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

describe("review.ui explorer rail", function()
  local state
  local ui
  local git
  local original_storage_module
  local original_state_module
	  local original_ui_module
	  local original_git_module
	  local original_branch
	  local original_workspace_signature
  local original_blame
  local original_blame_async
  local original_file_history
  local original_file_history_async
  local original_commit_diff_async

  before_each(function()
    original_storage_module = package.loaded["review.storage"]
    original_state_module = package.loaded["review.state"]
    original_ui_module = package.loaded["review.ui"]
    original_git_module = package.loaded["review.git"]

    package.loaded["review.storage"] = {
      load = function()
        return {}
      end,
      save = function() end,
      load_remote_bundle = function()
        return nil
      end,
      save_remote_bundle = function() end,
    }
    package.loaded["review.state"] = nil
    package.loaded["review.ui"] = nil
    package.loaded["review.git"] = nil

    state = require("review.state")
    ui = require("review.ui")
	    git = require("review.git")
	    original_branch = git.current_branch
	    original_workspace_signature = git.workspace_signature
    original_blame = git.blame
    original_blame_async = git.blame_async
    original_file_history = git.file_history
    original_file_history_async = git.file_history_async
    original_commit_diff_async = git.commit_diff_async
	    git.current_branch = function()
	      return "feature/rail-polish"
	    end
	    local signature_calls = 0
    git.workspace_signature = function()
      signature_calls = signature_calls + 1
      return "## feature/rail-polish"
    end

    review.setup({})
  end)

  after_each(function()
    if state and state.get() then
      pcall(ui.close)
    end

	    if git then
	      git.current_branch = original_branch
	      git.workspace_signature = original_workspace_signature
      git.blame = original_blame
      git.blame_async = original_blame_async
      git.file_history = original_file_history
      git.file_history_async = original_file_history_async
      git.commit_diff_async = original_commit_diff_async
    end

    package.loaded["review.storage"] = original_storage_module
    package.loaded["review.state"] = original_state_module
    package.loaded["review.ui"] = original_ui_module
    package.loaded["review.git"] = original_git_module
  end)

  it("renders the cleaned rail header and grouped thread sections", function()
    state.create("local", "main", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
      { path = "lua/ui.lua", status = "A", hunks = { sample_hunk(4, 4) } },
      { path = "lua/long_filename_for_alignment.lua", status = "M", hunks = { sample_hunk(8, 8) } },
    })
    state.set_forge_info({ forge = "github", pr_number = 7 })

    state.add_note("lua/review.lua", 2, "local draft", nil, "new")
    state.load_remote_comments({
      {
        file_path = "lua/ui.lua",
        line = 4,
        side = "new",
        replies = {
          { body = "remote one", author = "octocat" },
        },
        resolved = false,
      },
      {
        file_path = "lua/long_filename_for_alignment.lua",
        line = 8,
        side = "new",
        replies = {
          { body = "remote two", author = "octocat" },
        },
        resolved = false,
      },
    })

    ui.open()

    local lines = vim.api.nvim_buf_get_lines(state.get_ui().explorer_buf, 0, -1, false)
    local thread_lines = vim.api.nvim_buf_get_lines(state.get_ui().threads_buf, 0, -1, false)

    assert.is_true(lines[1]:find("[F] Files", 1, true) ~= nil)
    local explorer_text = table.concat(lines, "\n")
    assert.is_nil(explorer_text:find("feature/rail-polish", 1, true))
    assert.is_nil(explorer_text:find("against main", 1, true))
    assert.is_nil(explorer_text:find("Scope", 1, true))
    assert.is_nil(explorer_text:find("<Tab> scope", 1, true))
    local files_header
    for _, line in ipairs(lines) do
      if line:find("[F]", 1, true) then
        files_header = line
        break
      end
    end
    assert.is_not_nil(files_header)
    assert.is_true(files_header:find("+", 1, true) ~= nil and files_header:find("-", 1, true) ~= nil)
    assert.is_nil(explorer_text:find("▶", 1, true))
    assert.are.equal("no", vim.wo[state.get_ui().explorer_win].signcolumn)
    local has_lua_dir = false
    for _, line in ipairs(lines) do
      if line:find("0/3 reviewed", 1, true) then
        has_lua_dir = true
        break
      end
    end
    assert.is_true(has_lua_dir)
    assert.is_true(table.concat(lines, "\n"):match("~%s+revi.*lua") ~= nil)
    assert.is_true(vim.wo[state.get_ui().diff_win].winbar:find("lua/review.lua", 1, true) ~= nil)
    assert.is_true(thread_lines[1]:match("^ %[T%] Threads") ~= nil)
    assert.is_true(table.concat(thread_lines, "\n"):match("github/") ~= nil)
    assert.is_true(table.concat(thread_lines, "\n"):match("local/") ~= nil)
    assert.is_true(table.concat(thread_lines, "\n"):match("long.*lua %[%d+%]") ~= nil)
    assert.is_true(table.concat(thread_lines, "\n"):match("revi.*lua %[%d+%]") ~= nil)
  end)

  it("opens without a configured refresh keymap", function()
    review.config.keymaps.refresh = nil
    state.create("local", "main", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
    })

    assert.has_no.errors(function()
      ui.open()
    end)
  end)

  it("does not embed a git mutation pane for worktree reviews", function()
    state.create("local", "HEAD", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
    })

    ui.open()

    local ui_state = state.get_ui()
    local explorer_lines = vim.api.nvim_buf_get_lines(ui_state.explorer_buf, 0, -1, false)
    local diff_pos = vim.api.nvim_win_get_position(ui_state.diff_win)

    assert.is_nil(ui_state.git_win)
    assert.is_nil(ui_state.git_buf)
    assert.is_false(vim.tbl_contains(explorer_lines, " Staged"))
    assert.is_false(vim.tbl_contains(explorer_lines, " Unstaged"))
    assert.is_true(diff_pos[2] > vim.api.nvim_win_get_position(ui_state.explorer_win)[2])
  end)

  it("closes the whole review tab when one pane is quit", function()
    state.create("local", "HEAD", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
    })

    ui.open()

    local ui_state = state.get_ui()
    local review_tab = ui_state.tab
    vim.api.nvim_set_current_win(ui_state.explorer_win)
    vim.cmd("quit")

    vim.wait(200, function()
      return state.get() == nil
    end)

    assert.is_nil(state.get())
    local still_open = false
    for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
      if tab == review_tab then
        still_open = true
        break
      end
    end
    assert.is_false(still_open)
  end)

  it("does not embed a GitButler mutation pane for GitButler sessions", function()
    state.create("local", "gitbutler/workspace", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
    }, {
      vcs = "gitbutler",
      repo_root = "/tmp/review-nvim",
      branch = "gitbutler/workspace",
      gitbutler = {
        unassignedChanges = {
          { cliId = "aa", changeType = "added", filePath = "scratch.lua" },
        },
        stacks = {
          {
            cliId = "s1",
            branches = {
              {
                cliId = "br",
                name = "feature/gb",
                branchStatus = "completelyUnpushed",
                commits = {
                  { commitId = "123456789", message = "feat: gb" },
                },
              },
            },
          },
        },
        mergeBase = { commitId = "abcdef1234567890" },
        upstreamState = { behind = 2 },
      },
    })

    ui.open()

    local ui_state = state.get_ui()
    assert.is_nil(ui_state.git_win)
    assert.is_nil(ui_state.git_buf)
  end)

  it("separates unassigned GitButler changes from branch files", function()
    git.current_branch = function()
      return "gitbutler/workspace"
    end
    state.create("local", "gitbutler/workspace", {
      {
        path = "lua/review.lua",
        status = "M",
        hunks = { sample_hunk(2, 2) },
        gitbutler = { kind = "branch", branch_name = "feature/gb" },
      },
      {
        path = ".nvimlog",
        status = "A",
        hunks = { sample_hunk(1, 1) },
        gitbutler = { kind = "unassigned" },
      },
      {
        path = "mystery.lua",
        status = "?",
        hunks = { sample_hunk(1, 1) },
        gitbutler = { kind = "branch", branch_name = "feature/gb" },
      },
    }, {
      vcs = "gitbutler",
      repo_root = "/tmp/review-nvim",
      branch = "gitbutler/workspace",
      gitbutler = {},
      untracked_files = {
        { path = "scratch.tmp", status = "?", untracked = true, hunks = {} },
      },
    })

    state.set_commits({
      {
        sha = "gitbutler-unassigned",
        short_sha = "unassgn",
        message = "unassigned changes",
        files = {
          {
            path = ".nvimlog",
            status = "A",
            hunks = { sample_hunk(1, 1) },
            gitbutler = { kind = "unassigned" },
          },
        },
        gitbutler = { kind = "unassigned" },
      },
      {
        sha = "branch-scope",
        short_sha = "branch",
        message = "feature/gb",
        files = {
          {
            path = "lua/review.lua",
            status = "M",
            hunks = { sample_hunk(2, 2) },
            gitbutler = { kind = "branch", branch_name = "feature/gb" },
          },
        },
        gitbutler = { kind = "branch", branch_name = "feature/gb" },
      },
    })

    ui.toggle_stack_view()
    assert.are.equal(1, state.get().current_commit_idx)
    assert.are.equal("current_commit", state.scope_mode())
    assert.are.equal("unassigned", state.current_commit().gitbutler.kind)

    ui.toggle_stack_view()
    assert.are.equal(2, state.get().current_commit_idx)
    assert.are.equal("current_commit", state.scope_mode())
    assert.are.equal("feature/gb", state.current_commit().gitbutler.branch_name)

    ui.toggle_stack_view()
    assert.is_nil(state.get().current_commit_idx)
    assert.are.equal("all", state.scope_mode())
    assert.is_nil(state.current_commit())

    ui.toggle_stack_view()
    assert.are.equal(1, state.get().current_commit_idx)
    assert.are.equal("current_commit", state.scope_mode())
    assert.are.equal("unassigned", state.current_commit().gitbutler.kind)

    state.set_scope_mode("all")
    ui.open()

    local lines = vim.api.nvim_buf_get_lines(state.get_ui().files_buf, 0, -1, false)
    local joined = table.concat(lines, "\n")
    assert.is_true(joined:find("Branch feature/gb", 1, true) ~= nil)
    assert.is_true(joined:match("~%s+revi.*lua") ~= nil)
    assert.is_true(joined:find("Unassigned", 1, true) ~= nil)
    assert.is_true(joined:match("+%s+%.nvimlog") ~= nil)
    assert.is_true(joined:match("%?%s+myst.*lua") ~= nil)
    assert.is_true(joined:find("Untracked", 1, true) ~= nil)
  end)

  it("opens GitButler commit details from a selected scope row", function()
    git.current_branch = function()
      return "gitbutler/workspace"
    end

    state.create("local", "gitbutler/workspace", {
      {
        path = "lua/review.lua",
        status = "M",
        hunks = { sample_hunk(2, 2) },
        gitbutler = { kind = "branch", branch_name = "feature/gb" },
      },
    }, {
      vcs = "gitbutler",
      repo_root = "/tmp/review-nvim",
      branch = "gitbutler/workspace",
      gitbutler = {},
      workspace_signature = "## feature/rail-polish",
    })

    state.set_commits({
      {
        sha = "branch-scope",
        short_sha = "branch",
        message = "feature/gb",
        author = "Reviewer",
        files = {
          {
            path = "lua/review.lua",
            status = "M",
            hunks = { sample_hunk(2, 2) },
            gitbutler = { kind = "branch", branch_name = "feature/gb" },
          },
        },
        gitbutler = {
          kind = "branch",
          branch_cli_id = "br",
          branch_name = "feature/gb",
        },
      },
    })

    state.set_scope_mode("select_commit")
    ui.open()
    ui.focus_section("scope")

    local ui_state = state.get_ui()
    vim.api.nvim_set_current_win(ui_state.explorer_win)
    local lines = vim.api.nvim_buf_get_lines(ui_state.explorer_buf, 0, -1, false)
    local commit_line
    for i, line in ipairs(lines) do
      if line:find("Scope", 1, true) then
        commit_line = i + 3
        break
      end
    end
    assert.is_not_nil(commit_line)

    vim.api.nvim_win_set_cursor(ui_state.explorer_win, { commit_line, 0 })
    send_keys("K")

    local float_buf = vim.api.nvim_get_current_buf()
    local detail_lines = table.concat(vim.api.nvim_buf_get_lines(float_buf, 0, -1, false), "\n")
    assert.is_true(detail_lines:find("commit branch%-scope") ~= nil)
    assert.is_true(detail_lines:find("Author: Reviewer", 1, true) ~= nil)
    assert.is_true(detail_lines:find("feature/gb", 1, true) ~= nil)
    assert.is_true(detail_lines:find("M lua/review.lua", 1, true) ~= nil)
    close_current_float()
  end)

  it("compares the selected review unit with another unit", function()
    state.create("local", "main", {
      { path = "lua/shared.lua", status = "M", hunks = { sample_hunk(2, 2) } },
      { path = "lua/left.lua", status = "A", hunks = { sample_hunk(4, 4) } },
      { path = "lua/right.lua", status = "A", hunks = { sample_hunk(6, 6) } },
    })
    state.set_commits({
      {
        sha = "left111",
        short_sha = "left111",
        message = "agent left",
        files = {
          { path = "lua/shared.lua", status = "M", hunks = { sample_hunk(2, 2) } },
          { path = "lua/left.lua", status = "A", hunks = { sample_hunk(4, 4) } },
        },
      },
      {
        sha = "right222",
        short_sha = "right22",
        message = "agent right",
        files = {
          { path = "lua/shared.lua", status = "M", hunks = { sample_hunk(2, 2) } },
          { path = "lua/right.lua", status = "A", hunks = { sample_hunk(6, 6) } },
        },
      },
    })
    state.set_commit(1)
    state.set_scope_mode("current_commit")

    ui.open_unit_compare(2)

    local lines = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false), "\n")
    assert.is_true(lines:find("Compare Review Units", 1, true) ~= nil)
    assert.is_true(lines:find("Overlap (1)", 1, true) ~= nil)
    assert.is_true(lines:find("lua/shared.lua", 1, true) ~= nil)
    assert.is_true(lines:find("Left Only (1)", 1, true) ~= nil)
    assert.is_true(lines:find("lua/left.lua", 1, true) ~= nil)
    assert.is_true(lines:find("Right Only (1)", 1, true) ~= nil)
    assert.is_true(lines:find("lua/right.lua", 1, true) ~= nil)
    close_current_float()
  end)

  it("loads missing commit files asynchronously when selecting a commit", function()
    local pending
    git.commit_diff_async = function(sha, callback)
      assert.are.equal("async111", sha)
      pending = callback
    end

    state.create("local", "main", {
      { path = "lua/all.lua", status = "M", hunks = { sample_hunk(2, 2) } },
    })
    state.set_commits({
      {
        sha = "async111",
        short_sha = "async1",
        message = "async commit",
        author = "Reviewer",
      },
    })
    ui.open()

    ui.select_commit(1)

    assert.are.equal(1, state.get().current_commit_idx)
    assert.are.equal("current_commit", state.scope_mode())
    assert.are.same({}, state.active_files())
    assert.is_function(pending)
    assert.is_true(state.get().commits[1].loading)

    pending(table.concat({
      "diff --git a/lua/async.lua b/lua/async.lua",
      "--- a/lua/async.lua",
      "+++ b/lua/async.lua",
      "@@ -1,1 +1,1 @@",
      "-old",
      "+new",
    }, "\n"), nil)

    assert.are.equal("lua/async.lua", state.active_files()[1].path)
    assert.is_false(state.get().commits[1].loading)
  end)

  it("queues blame and history rows as context for the next note", function()
    git.blame_async = function(ref, path, callback)
      assert.are.equal("main", ref)
      assert.are.equal("lua/review.lua", path)
      callback({
        "abc123456789 (Reviewer 2026-05-15 12:00:00 -0600 2) old code",
      }, nil)
    end
    git.file_history_async = function(path, callback)
      assert.are.equal("lua/review.lua", path)
      callback({
        "def67890\t2026-05-15\tReviewer\tfix context",
      }, nil)
    end

    state.create("local", "main", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
    })
    ui.open()

    ui.toggle_blame_panel()
    local ui_state = state.get_ui()
    vim.api.nvim_set_current_win(ui_state.blame_win)
    vim.api.nvim_win_set_cursor(ui_state.blame_win, { 2, 0 })
    send_keys("a")
    assert.is_true(ui_state.pending_note_context.blame_context:find("abc12345", 1, true) ~= nil)
    ui.close_blame_panel()

    vim.api.nvim_set_current_win(ui_state.diff_win)
    ui.open_file_history()
    local history_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_cursor(history_win, { 3, 0 })
    send_keys("a")
    assert.is_true(ui_state.pending_note_context.log_context:find("def67890", 1, true) ~= nil)
    close_current_float()
  end)

  it("leaves g free when no git pane is configured", function()
    review.setup({
      keymaps = {
        focus_git = "g",
      },
    })

    state.create("local", "HEAD", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
    })

    ui.open()

    local ui_state = state.get_ui()
    vim.api.nvim_set_current_win(ui_state.explorer_win)
    send_keys("g")
    assert.are.equal(ui_state.explorer_win, vim.api.nvim_get_current_win())

    vim.api.nvim_set_current_win(ui_state.diff_win)
    send_keys("g")
    assert.are.equal(ui_state.diff_win, vim.api.nvim_get_current_win())
  end)

  it("uses n to focus threads from the navigator", function()
    review.setup({
      keymaps = {
        focus_threads = "n",
      },
    })

    state.create("local", "HEAD", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
    })
    state.add_note("lua/review.lua", 2, "local draft", nil, "new")

    ui.open()

    local ui_state = state.get_ui()
    vim.api.nvim_set_current_win(ui_state.explorer_win)
    send_keys("n")
    assert.are.equal(ui_state.threads_win, vim.api.nvim_get_current_win())
  end)

  it("focuses the first actionable file and thread rows", function()
    review.setup({
      keymaps = {
        focus_files = "F",
        focus_threads = "T",
      },
    })

    state.create("local", "HEAD", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
      { path = "lua/ui.lua", status = "A", hunks = { sample_hunk(4, 4) } },
    })
    state.add_note("lua/review.lua", 2, "local draft", nil, "new")

    ui.open()

    local ui_state = state.get_ui()
    vim.api.nvim_set_current_win(ui_state.diff_win)

    send_keys("F")
    assert.are.equal(ui_state.explorer_win, vim.api.nvim_get_current_win())
    local file_line = vim.api.nvim_buf_get_lines(
      ui_state.explorer_buf,
      vim.api.nvim_win_get_cursor(ui_state.explorer_win)[1] - 1,
      vim.api.nvim_win_get_cursor(ui_state.explorer_win)[1],
      false
    )[1]
    assert.is_true(file_line:find("~", 1, true) ~= nil and file_line:match("revi.*lua") ~= nil)

    vim.api.nvim_set_current_win(ui_state.diff_win)
    send_keys("T")
    assert.are.equal(ui_state.threads_win, vim.api.nvim_get_current_win())
    local thread_line = vim.api.nvim_buf_get_lines(
      ui_state.threads_buf,
      vim.api.nvim_win_get_cursor(ui_state.threads_win)[1] - 1,
      vim.api.nvim_win_get_cursor(ui_state.threads_win)[1],
      false
    )[1]
    assert.is_true(thread_line:match("^     ") ~= nil)
  end)

  it("toggles tree and flat file layouts and cycles review status", function()
    review.setup({
      keymaps = {
        focus_threads = "T",
        toggle_file_tree = "t",
      },
    })
    state.create("local", "main", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
      { path = "README.md", status = "A", hunks = { sample_hunk(1, 1) } },
    })

    ui.open()

    local ui_state = state.get_ui()
    local lines = vim.api.nvim_buf_get_lines(ui_state.explorer_buf, 0, -1, false)
    assert.is_false(table.concat(lines, "\n"):find(" - ./", 1, true) ~= nil)
    assert.is_true(table.concat(lines, "\n"):match("%- lu.*0/1 reviewed") ~= nil)
    assert.is_true(table.concat(lines, "\n"):match("+%s+REA.*md") ~= nil)
    assert.is_true(table.concat(lines, "\n"):find(" L ", 1, true) == nil)

    local lua_dir_line
    for idx, line in ipairs(lines) do
      if line:match("%- lu.*0/1 reviewed") then
        lua_dir_line = idx
        break
      end
    end
    assert.is_not_nil(lua_dir_line)
    vim.api.nvim_set_current_win(ui_state.explorer_win)
    vim.api.nvim_win_set_cursor(ui_state.explorer_win, { lua_dir_line, 0 })
    send_keys("za")
    lines = vim.api.nvim_buf_get_lines(ui_state.explorer_buf, 0, -1, false)
    assert.is_true(table.concat(lines, "\n"):match("%+ lu.*0/1 reviewed") ~= nil)
    assert.is_false(table.concat(lines, "\n"):find("review.lua", 1, true) ~= nil)
    send_keys("za")
    lines = vim.api.nvim_buf_get_lines(ui_state.explorer_buf, 0, -1, false)
    assert.is_true(table.concat(lines, "\n"):match("%- lu.*0/1 reviewed") ~= nil)

    vim.api.nvim_set_current_win(ui_state.explorer_win)
    send_keys("t")
    lines = vim.api.nvim_buf_get_lines(ui_state.explorer_buf, 0, -1, false)
    assert.is_false(table.concat(lines, "\n"):match("%- lu.*0/1 reviewed") ~= nil)
    assert.is_true(table.concat(lines, "\n"):match("revi.*lua") ~= nil)
    assert.are.equal("flat", state.get_ui_prefs().file_tree_mode)

    send_keys("r")
    assert.are.equal("reviewed", state.get_file_review_status("lua/review.lua"))
  end)

  it("aligns root file and directory markers in tree mode", function()
    state.create("local", "main", {
      { path = "README.md", status = "M", hunks = { sample_hunk(2, 2) } },
      { path = "docs/guide.md", status = "D", hunks = { sample_hunk(4, 4) } },
    })

    ui.open()

    local lines = vim.api.nvim_buf_get_lines(state.get_ui().explorer_buf, 0, -1, false)
    local file_marker_col
    local dir_marker_col
    for _, line in ipairs(lines) do
      if line:find("READ", 1, true) then
        file_marker_col = line:find("~", 1, true)
      elseif line:find("reviewed", 1, true) then
        dir_marker_col = line:find("-", 1, true)
      end
    end

    assert.is_not_nil(file_marker_col)
    assert.is_not_nil(dir_marker_col)
    assert.are.equal(file_marker_col, dir_marker_col)
  end)

  it("keeps the cursor on the file row and column when toggling review status", function()
    state.create("local", "main", {
      { path = "a.lua", status = "M", hunks = { sample_hunk(2, 2) } },
      { path = "b.lua", status = "M", hunks = { sample_hunk(4, 4) } },
    })

    ui.open()

    local ui_state = state.get_ui()
    local lines = vim.api.nvim_buf_get_lines(ui_state.explorer_buf, 0, -1, false)
    local target_line
    for idx, line in ipairs(lines) do
      if line:find("b.lua", 1, true) then
        target_line = idx
        break
      end
    end
    assert.is_not_nil(target_line)

    vim.api.nvim_set_current_win(ui_state.explorer_win)
    vim.api.nvim_win_set_cursor(ui_state.explorer_win, { target_line, 3 })
    send_keys("r")

    assert.are.equal("reviewed", state.get_file_review_status("b.lua"))
    local cursor_line = vim.api.nvim_win_get_cursor(ui_state.explorer_win)[1]
    local cursor_col = vim.api.nvim_win_get_cursor(ui_state.explorer_win)[2]
    local cursor_text = vim.api.nvim_buf_get_lines(ui_state.explorer_buf, cursor_line - 1, cursor_line, false)[1]
    assert.is_true(cursor_text:find("b.lua", 1, true) ~= nil)
    assert.are.equal(3, cursor_col)

    send_keys("r")
    assert.are.equal("unreviewed", state.get_file_review_status("b.lua"))
    assert.are.equal(cursor_line, vim.api.nvim_win_get_cursor(ui_state.explorer_win)[1])
    assert.are.equal(3, vim.api.nvim_win_get_cursor(ui_state.explorer_win)[2])
  end)

  it("keeps the cursor on a directory row after collapsing it", function()
    state.create("local", "main", {
      { path = "nested/a.lua", status = "M", hunks = { sample_hunk(2, 2) } },
      { path = "nested/b.lua", status = "M", hunks = { sample_hunk(4, 4) } },
    })
    state.update_ui_prefs({ file_tree_mode = "tree" })

    ui.open()

    local ui_state = state.get_ui()
    local lines = vim.api.nvim_buf_get_lines(ui_state.explorer_buf, 0, -1, false)
    local dir_line
    for idx, line in ipairs(lines) do
      if line:find("0/2 reviewed", 1, true) and line:find("-", 1, true) then
        dir_line = idx
        break
      end
    end
    assert.is_not_nil(dir_line)

    vim.api.nvim_set_current_win(ui_state.explorer_win)
    vim.api.nvim_win_set_cursor(ui_state.explorer_win, { dir_line, 0 })
    send_keys("za")

    local cursor_line = vim.api.nvim_win_get_cursor(ui_state.explorer_win)[1]
    local cursor_text = vim.api.nvim_buf_get_lines(ui_state.explorer_buf, cursor_line - 1, cursor_line, false)[1]
    assert.is_true(cursor_text:find("0/2 reviewed", 1, true) ~= nil and cursor_text:find("+", 1, true) ~= nil)
  end)

  it("keeps T focused on threads when tree toggle is configured to T", function()
    review.setup({
      keymaps = {
        focus_threads = "T",
        toggle_file_tree = "T",
      },
    })
    state.create("local", "HEAD", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
    })
    state.add_note("lua/review.lua", 2, "local draft", nil, "new")

    ui.open()

    local ui_state = state.get_ui()
    vim.api.nvim_set_current_win(ui_state.explorer_win)
    send_keys("T")

    assert.are.equal(ui_state.threads_win, vim.api.nvim_get_current_win())
    assert.are.equal("tree", state.get_ui().file_tree_mode)
  end)

  it("focuses the diff pane directly from the navigator", function()
    review.setup({
      keymaps = {
        focus_diff = "D",
      },
    })
    state.create("local", "HEAD", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
    })

    ui.open()

    local ui_state = state.get_ui()
    vim.api.nvim_set_current_win(ui_state.explorer_win)
    send_keys("D")

    assert.are.equal(ui_state.diff_win, vim.api.nvim_get_current_win())
  end)

  it("does not bind D as the default diff focus key", function()
    state.create("local", "HEAD", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
    })

    ui.open()

    local has_buffer_d_map = false
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(state.get_ui().explorer_buf, "n")) do
      if map.lhs == "D" then
        has_buffer_d_map = true
        break
      end
    end
    assert.is_false(has_buffer_d_map)
  end)

  it("uses B for blame and leaves b available for normal navigation", function()
    state.create("local", "HEAD", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
    })

    ui.open()

    local diff_buf = state.get_ui().diff_buf
    local has_upper_blame = false
    local has_lower_blame = false
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(diff_buf, "n")) do
      if map.lhs == "B" then
        has_upper_blame = true
      elseif map.lhs == "b" then
        has_lower_blame = true
      end
    end
    assert.is_true(has_upper_blame)
    assert.is_false(has_lower_blame)
  end)

  it("leaves V available for visual-line selections", function()
    state.create("local", "HEAD", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
    })

    ui.open()

    local diff_buf = state.get_ui().diff_buf
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(diff_buf, "n")) do
      assert.is_false(map.lhs == "V")
    end
  end)

  it("uses t for threads and leaves tree view as the default without a tree toggle key", function()
    state.create("local", "HEAD", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
    })
    state.add_note("lua/review.lua", 2, "local draft", nil, "new")

    ui.open()

    local ui_state = state.get_ui()
    vim.api.nvim_set_current_win(ui_state.explorer_win)
    send_keys("t")

    assert.are.equal(ui_state.threads_win, vim.api.nvim_get_current_win())
    assert.are.equal("tree", state.get_ui().file_tree_mode)
  end)

  it("uses tab to cycle note rows inside the threads pane", function()
    state.create("local", "HEAD", {
      { path = "lua/one.lua", status = "M", hunks = { sample_hunk(2, 2) } },
      { path = "lua/two.lua", status = "M", hunks = { sample_hunk(4, 4) } },
    })
    state.add_note("lua/one.lua", 2, "first", nil, "new")
    state.add_note("lua/two.lua", 4, "second", nil, "new")

    ui.open()
    ui.focus_section("threads")

    local ui_state = state.get_ui()
    local first_line = vim.api.nvim_win_get_cursor(ui_state.threads_win)[1]
    send_keys("<Tab>")
    local second_line = vim.api.nvim_win_get_cursor(ui_state.threads_win)[1]

    assert.is_true(second_line > first_line)
    send_keys("<S-Tab>")
    assert.are.equal(first_line, vim.api.nvim_win_get_cursor(ui_state.threads_win)[1])
  end)

  it("keeps tab scope cycling on the same file when scope headers appear", function()
    state.create("local", "main", {
      { path = "lua/a.lua", status = "M", hunks = { sample_hunk(2, 2) } },
      { path = "lua/b.lua", status = "M", hunks = { sample_hunk(4, 4) } },
    })
    state.set_commits({
      {
        sha = "abc123456789",
        short_sha = "abc1234",
        message = "unit",
        files = {
          { path = "lua/a.lua", status = "M", hunks = { sample_hunk(2, 2) } },
          { path = "lua/b.lua", status = "M", hunks = { sample_hunk(4, 4) } },
        },
      },
    })

    ui.open()

    local ui_state = state.get_ui()
    local lines = vim.api.nvim_buf_get_lines(ui_state.explorer_buf, 0, -1, false)
    local b_line
    for idx, line in ipairs(lines) do
      if line:find("b.lua", 1, true) then
        b_line = idx
        break
      end
    end
    assert.is_not_nil(b_line)

    vim.api.nvim_set_current_win(ui_state.explorer_win)
    vim.api.nvim_win_set_cursor(ui_state.explorer_win, { b_line, 0 })
    send_keys("<Tab>")

    assert.are.equal(ui_state.explorer_win, vim.api.nvim_get_current_win())
    local cursor_line = vim.api.nvim_win_get_cursor(ui_state.explorer_win)[1]
    local cursor_text = vim.api.nvim_buf_get_lines(ui_state.explorer_buf, cursor_line - 1, cursor_line, false)[1]
    assert.is_true(cursor_text:find("b.lua", 1, true) ~= nil)
    assert.are.equal("lua/b.lua", state.active_files()[state.get().current_file_idx].path)
  end)

  it("keeps tab scope cycling in the diff pane", function()
    state.create("local", "main", {
      { path = "lua/a.lua", status = "M", hunks = { sample_hunk(2, 2) } },
    })
    state.set_commits({
      {
        sha = "abc123456789",
        short_sha = "abc1234",
        message = "unit",
        files = { { path = "lua/a.lua", status = "M", hunks = { sample_hunk(2, 2) } } },
      },
    })

    ui.open()

    local ui_state = state.get_ui()
    vim.api.nvim_set_current_win(ui_state.diff_win)
    send_keys("<Tab>")

    assert.are.equal(ui_state.diff_win, vim.api.nvim_get_current_win())
  end)

  it("returns to the previous file row when focusing files from split diff", function()
    review.setup({
      keymaps = {
        focus_files = "F",
      },
    })
    state.create("local", "HEAD", {
      { path = "a.lua", status = "M", hunks = { sample_hunk(2, 2) } },
      { path = "nested/b.lua", status = "M", hunks = { sample_hunk(4, 4) } },
    })

    ui.open()

    local ui_state = state.get_ui()
    local lines = vim.api.nvim_buf_get_lines(ui_state.explorer_buf, 0, -1, false)
    local target_line
    for idx, line in ipairs(lines) do
      if line:find("b.lua", 1, true) then
        target_line = idx
        break
      end
    end
    assert.is_not_nil(target_line)

    vim.api.nvim_set_current_win(ui_state.explorer_win)
    vim.api.nvim_win_set_cursor(ui_state.explorer_win, { target_line, 0 })
    ui.toggle_split()
    vim.api.nvim_set_current_win(ui_state.split_win)

    send_keys("F")

    assert.are.equal(ui_state.explorer_win, vim.api.nvim_get_current_win())
    assert.are.equal(target_line, vim.api.nvim_win_get_cursor(ui_state.explorer_win)[1])
  end)

  it("returns to the same split diff pane after focusing files", function()
    review.setup({
      keymaps = {
        focus_files = "F",
        focus_diff = "<BS>",
      },
    })
    state.create("local", "HEAD", {
      { path = "a.lua", status = "M", hunks = { sample_hunk(2, 2) } },
    })

    ui.open()
    ui.toggle_split()

    local ui_state = state.get_ui()
    vim.api.nvim_set_current_win(ui_state.split_win)
    send_keys("F")
    send_keys("<BS>")

    assert.are.equal(ui_state.split_win, vim.api.nvim_get_current_win())
  end)

  it("uses s from files and threads to return to the last diff split position", function()
    state.create("local", "HEAD", {
      { path = "a.lua", status = "M", hunks = { sample_hunk(2, 2) } },
    })
    state.add_note("a.lua", 2, "thread", nil, "new")

    ui.open()
    ui.toggle_split()

    local ui_state = state.get_ui()
    vim.api.nvim_set_current_win(ui_state.split_win)
    vim.api.nvim_win_set_cursor(ui_state.split_win, { 2, 0 })

    ui.focus_section("files")
    send_keys("s")

    assert.are.equal(ui_state.split_win, vim.api.nvim_get_current_win())
    assert.are.equal(2, vim.api.nvim_win_get_cursor(ui_state.split_win)[1])

    vim.api.nvim_win_set_cursor(ui_state.split_win, { 1, 0 })
    ui.focus_section("threads")
    send_keys("s")

    assert.are.equal(ui_state.split_win, vim.api.nvim_get_current_win())
    assert.are.equal(1, vim.api.nvim_win_get_cursor(ui_state.split_win)[1])
  end)

  it("places the split cursor below the first two lines when opening split view", function()
    state.create("local", "HEAD", {
      {
        path = "a.lua",
        status = "M",
        hunks = {
          {
            header = "@@ -1,3 +1,3 @@",
            old_start = 1,
            old_count = 3,
            new_start = 1,
            new_count = 3,
            lines = {
              { type = "ctx", text = "line one", old_lnum = 1, new_lnum = 1 },
              { type = "ctx", text = "line two", old_lnum = 2, new_lnum = 2 },
              { type = "del", text = "before", old_lnum = 3 },
              { type = "add", text = "after", new_lnum = 3 },
            },
          },
        },
      },
    })

    ui.open()
    ui.toggle_split()

    local ui_state = state.get_ui()
    local cursor_line = vim.api.nvim_win_get_cursor(ui_state.split_win)[1]
    assert.are.equal(3, cursor_line)
  end)

  it("toggles split view repeatedly from the split pane without closing review", function()
    state.create("local", "HEAD", {
      {
        path = "a.lua",
        status = "M",
        hunks = { sample_hunk(2, 2) },
      },
    })

    ui.open()
    ui.toggle_split()

    local ui_state = state.get_ui()
    vim.api.nvim_set_current_win(ui_state.split_win)
    send_keys("s")

    assert.is_not_nil(state.get())
    assert.are.equal("unified", ui_state.view_mode)
    assert.is_nil(ui_state.split_win)
    assert.is_true(vim.api.nvim_win_is_valid(ui_state.diff_win))

    send_keys("s")

    assert.is_not_nil(state.get())
    assert.are.equal("split", ui_state.view_mode)
    assert.is_true(vim.api.nvim_win_is_valid(ui_state.split_win))
  end)

  it("cycles review unit status from scope rows and shows unit progress", function()
    state.create("local", "main", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
      { path = "lua/other.lua", status = "M", hunks = { sample_hunk(4, 4) } },
    })
    state.set_file_review_status("lua/review.lua", "reviewed")
    state.set_commits({
      {
        sha = "abc123456789",
        short_sha = "abc1234",
        message = "Review unit",
        author = "psanchez",
        files = {
          { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
          { path = "lua/other.lua", status = "M", hunks = { sample_hunk(4, 4) } },
        },
      },
    })
    state.set_scope_mode("select_commit")

    ui.open()

    local ui_state = state.get_ui()
    local lines = vim.api.nvim_buf_get_lines(ui_state.explorer_buf, 0, -1, false)
    local commit_line
    for idx, line in ipairs(lines) do
      if line:find("abc1234", 1, true) and line:find("1/2", 1, true) then
        commit_line = idx
        break
      end
    end
    assert.is_not_nil(commit_line)

    vim.api.nvim_set_current_win(ui_state.explorer_win)
    vim.api.nvim_win_set_cursor(ui_state.explorer_win, { commit_line, 0 })
    send_keys("r")

    assert.are.equal("reviewed", state.get_unit_review_status("abc123456789"))
    lines = vim.api.nvim_buf_get_lines(ui_state.explorer_buf, 0, -1, false)
    assert.is_true(lines[commit_line]:find("v", 1, true) ~= nil)
  end)

  it("keeps review unit rows out of the normal review rail", function()
    local original_columns = vim.o.columns
    vim.o.columns = 170

    state.create("local", "main", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
      { path = "lua/other.lua", status = "A", hunks = { sample_hunk(4, 4) } },
    })
    state.add_note("lua/review.lua", 2, "needs follow-up", nil, "new")
    state.set_commits({
      {
        sha = "abc123456789",
        short_sha = "abc1234",
        message = "Review unit",
        author = "psanchez",
        files = {
          { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
          { path = "lua/other.lua", status = "A", hunks = { sample_hunk(4, 4) } },
        },
      },
    })
    state.set_commit(1)
    state.set_scope_mode("current_commit")

    ui.open()

    local lines = vim.api.nvim_buf_get_lines(state.get_ui().explorer_buf, 0, -1, false)
    local joined = table.concat(lines, "\n")
    assert.is_nil(joined:find("Scope", 1, true))
    assert.is_nil(joined:find("workspace f2", 1, true))
    assert.is_nil(joined:find("abc1234", 1, true))
    assert.is_nil(joined:find("commit f2", 1, true))
    assert.is_true(lines[1]:find("feature/rail-polish", 1, true) ~= nil)
    assert.is_true(joined:find("[F] Files", 1, true) ~= nil)

    vim.o.columns = original_columns
  end)

  it("filters and sorts review unit rows with navigator controls", function()
    local original_columns = vim.o.columns
    vim.o.columns = 170

    state.create("local", "main", {
      { path = "lua/aaa.lua", status = "M", hunks = { sample_hunk(2, 2) } },
      { path = "lua/zzz.lua", status = "M", hunks = { sample_hunk(4, 4) } },
    })
    state.add_note("lua/zzz.lua", 4, "priority note", nil, "new")
    state.set_commits({
      {
        sha = "aaa111",
        short_sha = "aaa111",
        message = "aaa unit",
        author = "psanchez",
        files = { { path = "lua/aaa.lua", status = "M", hunks = { sample_hunk(2, 2) } } },
      },
      {
        sha = "zzz222",
        short_sha = "zzz222",
        message = "zzz unit",
        author = "psanchez",
        files = { { path = "lua/zzz.lua", status = "M", hunks = { sample_hunk(4, 4) } } },
      },
    })
    state.set_scope_mode("select_commit")
    state.update_ui_prefs({ file_sort_mode = "notes" })

    ui.open()

    local lines = vim.api.nvim_buf_get_lines(state.get_ui().explorer_buf, 0, -1, false)
    local zzz_row
    local aaa_row
    for idx, line in ipairs(lines) do
      if line:match("^%s+zzz222") then
        zzz_row = idx
      elseif line:match("^%s+aaa111") then
        aaa_row = idx
      end
    end
    assert.is_not_nil(zzz_row)
    assert.is_not_nil(aaa_row)
    assert.is_true(zzz_row < aaa_row)

    state.update_ui_prefs({ file_search_query = "zzz unit" })
    state.get_ui().file_search_query = "zzz unit"
    ui.refresh()

    lines = vim.api.nvim_buf_get_lines(state.get_ui().explorer_buf, 0, -1, false)
    local found_zzz = false
    local found_aaa = false
    for _, line in ipairs(lines) do
      if line:match("^%s+zzz222") then
        found_zzz = true
      elseif line:match("^%s+aaa111") then
        found_aaa = true
      end
    end
    assert.is_true(found_zzz)
    assert.is_false(found_aaa)

    vim.o.columns = original_columns
  end)

  it("sorts by risk and hides reviewed files", function()
    review.setup({
      keymaps = {
        sort_files = "o",
        toggle_reviewed = "H",
      },
    })
    local big_hunk = sample_hunk(2, 2)
    for i = 1, 80 do
      table.insert(big_hunk.lines, { type = "add", text = "line " .. i, new_lnum = i + 2 })
    end
    state.create("local", "main", {
      { path = "aaa_small.lua", status = "M", hunks = { sample_hunk(2, 2) } },
      { path = "zzz_big.lua", status = "M", hunks = { big_hunk } },
    })

    ui.open()

    local ui_state = state.get_ui()
    vim.api.nvim_set_current_win(ui_state.explorer_win)
    send_keys("o")
    local lines = vim.api.nvim_buf_get_lines(ui_state.explorer_buf, 0, -1, false)
    local joined = table.concat(lines, "\n")
    assert.are.equal("risk", ui_state.file_sort_mode)
    assert.are.equal("risk", state.get_ui_prefs().file_sort_mode)
    assert.is_true(joined:find("zzz_", 1, true) < joined:find("aaa_", 1, true))

    state.set_file_review_status("zzz_big.lua", "reviewed")
    send_keys("H")
    lines = vim.api.nvim_buf_get_lines(ui_state.explorer_buf, 0, -1, false)
    joined = table.concat(lines, "\n")
    assert.is_true(ui_state.hide_reviewed_files)
    assert.is_true(state.get_ui_prefs().hide_reviewed_files)
    assert.is_nil(joined:match("zzz_"))
    assert.is_true(joined:match("aaa_") ~= nil)
  end)

  it("marks attention flags and sorts by overlap", function()
    local original_columns = vim.o.columns
    vim.o.columns = 170
    review.setup({
      keymaps = {
        sort_files = "o",
        filter_attention = "A",
      },
    })
    local big_hunk = sample_hunk(2, 2)
    for i = 1, 120 do
      table.insert(big_hunk.lines, { type = "add", text = "line " .. i, new_lnum = i + 2 })
    end
    state.create("local", "main", {
      { path = "lua/shared.lua", status = "M", hunks = { sample_hunk(2, 2) } },
      { path = "generated.lock", status = "M", hunks = { big_hunk } },
    })
    state.load_remote_comments({
      {
        file_path = "lua/shared.lua",
        line = 2,
        side = "new",
        replies = {
          { body = "open thread", author = "octocat" },
        },
        resolved = false,
      },
    })
    state.set_commits({
      {
        sha = "left111",
        short_sha = "left111",
        message = "left",
        files = { { path = "lua/shared.lua", status = "M", hunks = { sample_hunk(2, 2) } } },
      },
      {
        sha = "right222",
        short_sha = "right22",
        message = "right",
        files = { { path = "lua/shared.lua", status = "M", hunks = { sample_hunk(2, 2) } } },
      },
    })
    state.update_ui_prefs({ file_tree_mode = "flat" })

    ui.open()
    local ui_state = state.get_ui()
    local joined = table.concat(vim.api.nvim_buf_get_lines(ui_state.explorer_buf, 0, -1, false), "\n")
    assert.is_true(joined:match("shared%.lua") ~= nil)
    assert.is_true(joined:match("generated%.lock") ~= nil)

    vim.api.nvim_set_current_win(ui_state.explorer_win)
    send_keys("o")
    assert.are.equal("risk", state.get_ui().file_sort_mode)
    send_keys("o")
    assert.are.equal("overlap", state.get_ui().file_sort_mode)
    joined = table.concat(vim.api.nvim_buf_get_lines(ui_state.explorer_buf, 0, -1, false), "\n")
    assert.is_true(joined:find("shared", 1, true) < joined:find("generated", 1, true))

    send_keys("A")
    assert.are.equal("overlap", state.get_ui().file_attention_filter)
    joined = table.concat(vim.api.nvim_buf_get_lines(ui_state.explorer_buf, 0, -1, false), "\n")
    assert.is_true(state.get_ui().file_attention_filter == "overlap")
    assert.is_true(joined:find("shared", 1, true) ~= nil)
    assert.is_nil(joined:find("generated", 1, true))
    send_keys("c")
    assert.are.equal("all", state.get_ui().file_attention_filter)
    assert.are.equal("all", state.get_ui_prefs().file_attention_filter)

    vim.o.columns = original_columns
  end)

  it("marks and filters files changed since the review baseline", function()
    state.create("local", "main", {
      { path = "lua/changed.lua", status = "M", hunks = { sample_hunk(2, 2) } },
      { path = "lua/unchanged.lua", status = "M", hunks = { sample_hunk(4, 4) } },
    })
    state.mark_review_snapshot("before-sha")
    state.get().files = {
      { path = "lua/changed.lua", status = "M", hunks = { sample_hunk(8, 8) } },
      { path = "lua/unchanged.lua", status = "M", hunks = { sample_hunk(4, 4) } },
      { path = "lua/added.lua", status = "A", hunks = { sample_hunk(1, 1) } },
    }
    state.update_ui_prefs({ file_tree_mode = "flat" })

    ui.open()

    local ui_state = state.get_ui()
    local joined = table.concat(vim.api.nvim_buf_get_lines(ui_state.explorer_buf, 0, -1, false), "\n")
    assert.is_true(joined:match("chan.*lua") ~= nil)
    assert.is_true(joined:match("adde.*lua") ~= nil)

    state.update_ui_prefs({ file_attention_filter = "changed" })
    ui_state.file_attention_filter = "changed"
    ui.refresh()

    joined = table.concat(vim.api.nvim_buf_get_lines(ui_state.explorer_buf, 0, -1, false), "\n")
    assert.is_true(joined:match("chan.*lua") ~= nil)
    assert.is_true(joined:match("adde.*lua") ~= nil)
    assert.is_nil(joined:match("unch.*lua"))
  end)

  it("filters navigator files by path, note body, and commit message", function()
    state.create("local", "main", {
      { path = "lua/path_match.lua", status = "M", hunks = { sample_hunk(2, 2) } },
      { path = "lua/note_match.lua", status = "M", hunks = { sample_hunk(4, 4) } },
      { path = "lua/commit_match.lua", status = "M", hunks = { sample_hunk(6, 6) } },
      { path = "lua/hidden.lua", status = "M", hunks = { sample_hunk(8, 8) } },
    })
    state.add_note("lua/note_match.lua", 4, "contains needle text", nil, "new")
    state.set_commits({
      {
        sha = "abc123456789",
        short_sha = "abc1234",
        message = "ship needle commit",
        author = "psanchez",
        files = {
          { path = "lua/commit_match.lua", status = "M", hunks = { sample_hunk(6, 6) } },
        },
      },
    })
    state.update_ui_prefs({ file_search_query = "needle" })

    ui.open()

    local ui_state = state.get_ui()
    assert.are.equal("needle", ui_state.file_search_query)
    local joined = table.concat(vim.api.nvim_buf_get_lines(ui_state.explorer_buf, 0, -1, false), "\n")
    assert.is_true(joined:find("note", 1, true) ~= nil)
    assert.is_true(joined:find("comm", 1, true) ~= nil)
    assert.is_nil(joined:find("path_", 1, true))
    assert.is_nil(joined:find("hidden", 1, true))

    ui.clear_file_search()
    assert.are.equal("", state.get_ui_prefs().file_search_query)
    joined = table.concat(vim.api.nvim_buf_get_lines(ui_state.explorer_buf, 0, -1, false), "\n")
    assert.is_true(joined:find("hidd", 1, true) ~= nil)
  end)

  it("restores persisted navigator and thread filters", function()
    state.create("local", "main", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
      { path = "lua/old.lua", status = "M", hunks = { sample_hunk(4, 4) } },
    })
    state.set_file_review_status("lua/old.lua", "reviewed")
    state.load_remote_comments({
      {
        file_path = "lua/review.lua",
        line = 2,
        side = "new",
        replies = {
          { body = "open thread", author = "octocat" },
        },
        resolved = false,
      },
      {
        file_path = "lua/old.lua",
        line = 4,
        side = "new",
        replies = {
          { body = "resolved thread", author = "octocat" },
        },
        resolved = true,
      },
    })
    state.update_ui_prefs({
      file_tree_mode = "flat",
      file_sort_mode = "notes",
      file_attention_filter = "threads",
      hide_reviewed_files = true,
      file_search_query = "review",
      thread_filter = "resolved",
    })

    ui.open()

    local ui_state = state.get_ui()
    assert.are.equal("flat", ui_state.file_tree_mode)
    assert.are.equal("notes", ui_state.file_sort_mode)
    assert.are.equal("threads", ui_state.file_attention_filter)
    assert.is_true(ui_state.hide_reviewed_files)
    assert.are.equal("review", ui_state.file_search_query)
    assert.are.equal("resolved", ui_state.thread_filter)

    local explorer = table.concat(vim.api.nvim_buf_get_lines(ui_state.explorer_buf, 0, -1, false), "\n")
    assert.is_nil(explorer:find(" old.lua", 1, true))

    local threads = table.concat(vim.api.nvim_buf_get_lines(ui_state.threads_buf, 0, -1, false), "\n")
    assert.is_true(threads:find("filter:resolved", 1, true) ~= nil)
    assert.is_true(threads:find("1 thread", 1, true) ~= nil)
  end)

  it("shows compare sessions even when previous file filters would hide them", function()
    state.create("local", "v1.0.0", {
      { path = "lua/compare.lua", status = "M", hunks = { sample_hunk(2, 2) } },
    }, {
      left_ref = "v1.0.0",
      right_ref = "v1.1.0",
      requested_ref = "v1.0.0..v1.1.0",
      comparison_key = "git::v1.0.0::v1.1.0",
    })
    state.set_file_review_status("lua/compare.lua", "reviewed")
    state.update_ui_prefs({
      file_attention_filter = "threads",
      hide_reviewed_files = true,
      file_search_query = "will-not-match",
    })

    ui.open()

    local ui_state = state.get_ui()
    assert.are.equal("all", ui_state.file_attention_filter)
    assert.is_false(ui_state.hide_reviewed_files)
    assert.are.equal("", ui_state.file_search_query)

    local explorer = table.concat(vim.api.nvim_buf_get_lines(ui_state.explorer_buf, 0, -1, false), "\n")
    assert.is_true(explorer:find("compare", 1, true) ~= nil)
    assert.is_nil(explorer:find("(no files)", 1, true))
  end)

  it("renders compare context as readable base and head rows", function()
    state.create("local", "main", {
      { path = "README.md", status = "M", hunks = { sample_hunk(2, 2) } },
      { path = "docs/git-tour.md", status = "D", hunks = { sample_hunk(4, 4) } },
    }, {
      left_ref = "main",
      right_ref = "bugfix/input-validation",
      requested_ref = "main..bugfix/input-validation",
      comparison_key = "git::main::bugfix/input-validation",
    })

    ui.open()

    local lines = vim.api.nvim_buf_get_lines(state.get_ui().explorer_buf, 0, 6, false)
    assert.are.equal(" compare", lines[1])
    assert.are.equal("   base main", lines[2])
    assert.are.equal("   head bugfix/", lines[3])
    assert.are.equal("  input-validation", lines[4])
    assert.is_false(vim.tbl_contains(lines, " bugfix/input-validation"))
  end)

  it("shows how to leave a compare session", function()
    state.create("local", "main", {
      { path = "README.md", status = "M", hunks = { sample_hunk(2, 2) } },
    }, {
      left_ref = "main",
      right_ref = "bugfix/input-validation",
      requested_ref = "main..bugfix/input-validation",
      comparison_key = "git::main::bugfix/input-validation",
      previous_review = { kind = "default" },
    })

    ui.open()

    local explorer = table.concat(vim.api.nvim_buf_get_lines(state.get_ui().explorer_buf, 0, -1, false), "\n")
    assert.is_true(explorer:find("back", 1, true) ~= nil)
    assert.is_true(explorer:find(":ReviewBack", 1, true) ~= nil)
  end)

  it("makes tab in compare sessions open commit scope instead of changing files silently", function()
    state.create("local", "main", {
      { path = "README.md", status = "M", hunks = { sample_hunk(2, 2) } },
      { path = "docs/git-tour.md", status = "D", hunks = { sample_hunk(4, 4) } },
    }, {
      left_ref = "main",
      right_ref = "bugfix/input-validation",
      requested_ref = "main..bugfix/input-validation",
      comparison_key = "git::main::bugfix/input-validation",
    })
    state.set_commits({
      {
        sha = "abc123456789",
        short_sha = "abc1234",
        message = "tighten validation",
        files = { { path = "README.md", status = "M", hunks = { sample_hunk(2, 2) } } },
      },
    })

    ui.open()
    local ui_state = state.get_ui()
    vim.api.nvim_set_current_win(ui_state.explorer_win)
    send_keys("<Tab>")

    assert.are.equal("select_commit", state.scope_mode())
    assert.is_nil(state.get().current_commit_idx)
    local explorer = table.concat(vim.api.nvim_buf_get_lines(ui_state.explorer_buf, 0, -1, false), "\n")
    assert.is_true(explorer:find("scope", 1, true) ~= nil)
    assert.is_true(explorer:find("pick", 1, true) ~= nil)
  end)

  it("shows a persistent stale context banner in the navigator", function()
    state.create("local", "main", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
    })
    state.set_remote_context_stale("PR is closed")

    ui.open()

    local lines = vim.api.nvim_buf_get_lines(state.get_ui().explorer_buf, 0, -1, false)
    assert.is_true(vim.tbl_contains(lines, " stale  PR is closed"))
  end)

  it("does not create a git mutation pane for explicit ref reviews", function()
    state.create("local", "main", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
    }, {
      requested_ref = "main",
    })

    ui.open()

    assert.is_nil(state.get_ui().git_win)
    assert.is_nil(state.get_ui().git_buf)
  end)

  it("shows open, resolved, and outdated unresolved remote threads", function()
    state.create("local", "main", {
      { path = "lua/open.lua", status = "M", hunks = { sample_hunk(2, 2) } },
      { path = "lua/resolved.lua", status = "M", hunks = { sample_hunk(4, 4) } },
      { path = "lua/outdated.lua", status = "M", hunks = { sample_hunk(6, 6) } },
    })
    state.set_forge_info({ forge = "github", pr_number = 9 })

    state.load_remote_comments({
      {
        file_path = "lua/open.lua",
        line = 2,
        side = "new",
        replies = {
          { body = "open", author = "octocat" },
        },
        resolved = false,
      },
      {
        file_path = "lua/resolved.lua",
        line = 4,
        side = "new",
        replies = {
          { body = "resolved", author = "octocat" },
        },
        resolved = true,
      },
      {
        file_path = "lua/outdated.lua",
        line = 6,
        side = "new",
        replies = {
          { body = "outdated", author = "octocat" },
        },
        resolved = false,
        outdated = true,
      },
    })

    ui.open()
    state.get_ui().thread_filter = "all"
    ui.refresh()

    local lines = vim.api.nvim_buf_get_lines(state.get_ui().threads_buf, 0, -1, false)
    local joined = table.concat(lines, "\n")
    assert.is_true(joined:match("github/ %[%d+%]") ~= nil)
    assert.is_true(joined:match("open%.lua.*%[%d+%]") ~= nil)
    assert.is_true(joined:match("outd.*lua.*%[%d+%]") ~= nil)
    assert.is_true(joined:match("reso.*lua.*%[%d+%]") ~= nil)
  end)

  it("shows PR timeline and approval context as a distinct threads section", function()
    state.create("local", "main", {
      { path = "lua/open.lua", status = "M", hunks = { sample_hunk(2, 2) } },
    })
    state.set_forge_info({ forge = "github", pr_number = 9 })
    state.set_remote_summary({
      approvals = {
        { author = "alice", state = "APPROVED" },
      },
      changes_requested = {
        { author = "bob", state = "CHANGES_REQUESTED" },
      },
      timeline = {
        { label = "labeled review", actor = "carol" },
        { label = "ready", actor = "erin" },
      },
    })

    ui.open()

    local lines = vim.api.nvim_buf_get_lines(state.get_ui().threads_buf, 0, -1, false)
    local joined = table.concat(lines, "\n")
    assert.is_true(joined:find("PR/MR ctx", 1, true) ~= nil)
    assert.is_true(joined:find("a1", 1, true) ~= nil)
    assert.is_true(joined:find("c1", 1, true) ~= nil)
    assert.is_true(joined:find("ready", 1, true) ~= nil)
  end)

  it("filters, collapses, and expands thread rows", function()
    state.create("local", "main", {
      { path = "lua/open.lua", status = "M", hunks = { sample_hunk(2, 2) } },
      { path = "lua/resolved.lua", status = "M", hunks = { sample_hunk(4, 4) } },
    })
    state.set_forge_info({ forge = "github", pr_number = 9 })
    state.load_remote_comments({
      {
        file_path = "lua/open.lua",
        line = 2,
        side = "new",
        replies = {
          { body = "open body", author = "octocat", created_at = "2026-05-11T10:00:00Z" },
        },
        resolved = false,
      },
      {
        file_path = "lua/resolved.lua",
        line = 4,
        side = "new",
        replies = {
          { body = "resolved body", author = "octocat", created_at = "2026-05-11T10:00:00Z" },
        },
        resolved = true,
      },
    })

    ui.open()

    local ui_state = state.get_ui()
    vim.api.nvim_set_current_win(ui_state.threads_win)
    vim.api.nvim_win_set_cursor(ui_state.threads_win, { 2, 0 })
    send_keys("<Tab>")
    local lines = vim.api.nvim_buf_get_lines(ui_state.threads_buf, 0, -1, false)
    local joined = table.concat(lines, "\n")
    assert.is_true(lines[2]:find("filter:resolved", 1, true) ~= nil)
    assert.is_true(lines[3]:find("1 thread", 1, true) ~= nil)
    assert.is_true(joined:match("resolved%.lua") ~= nil or joined:match("reso.*lua") ~= nil)
    assert.is_nil(joined:match("open%.lua"))

    vim.api.nvim_win_set_cursor(ui_state.threads_win, { 2, 0 })
    send_keys("<Tab>")
    lines = vim.api.nvim_buf_get_lines(ui_state.threads_buf, 0, -1, false)
    joined = table.concat(lines, "\n")
    assert.is_true(lines[2]:find("filter:stale", 1, true) ~= nil)
    assert.is_nil(joined:match("open%.lua"))
    assert.is_nil(joined:match("resolved%.lua"))

    vim.api.nvim_win_set_cursor(ui_state.threads_win, { 2, 0 })
    send_keys("<Tab>")
    lines = vim.api.nvim_buf_get_lines(ui_state.threads_buf, 0, -1, false)
    joined = table.concat(lines, "\n")
    assert.is_true(lines[2]:find("filter:all", 1, true) ~= nil)
    assert.is_true(joined:match("open%.lua") ~= nil)
    assert.is_true(joined:match("resolved%.lua") ~= nil or joined:match("reso.*lua") ~= nil)

    local open_group_line
    for idx, line in ipairs(lines) do
      if line:find("github/", 1, true) and line:find("%[1%]") then
        open_group_line = idx
        break
      end
    end
    assert.is_not_nil(open_group_line)
    vim.api.nvim_win_set_cursor(ui_state.threads_win, { open_group_line, 0 })
    send_keys("za")
    lines = vim.api.nvim_buf_get_lines(ui_state.threads_buf, 0, -1, false)
    assert.is_true(table.concat(lines, "\n"):match("%+ github/") ~= nil)
    assert.is_nil(table.concat(lines, "\n"):match("open%.lua"))

    vim.api.nvim_win_set_cursor(ui_state.threads_win, { open_group_line, 0 })
    send_keys("za")
    lines = vim.api.nvim_buf_get_lines(ui_state.threads_buf, 0, -1, false)
    local open_file_line
    for idx, line in ipairs(lines) do
      if line:find("open%.lua") then
        open_file_line = idx
        break
      end
    end
    assert.is_not_nil(open_file_line)
    vim.api.nvim_win_set_cursor(ui_state.threads_win, { open_file_line, 0 })
    send_keys("za")
    lines = vim.api.nvim_buf_get_lines(ui_state.threads_buf, 0, -1, false)
    assert.is_true(table.concat(lines, "\n"):match("%* O") ~= nil)
  end)

  it("aligns thread badges within a section", function()
    state.create("local", "main", {
      { path = "lua/a.lua", status = "M", hunks = { sample_hunk(2, 2) } },
      { path = "lua/very_long_filename_here.lua", status = "M", hunks = { sample_hunk(4, 4) } },
    })
    state.set_forge_info({ forge = "github", pr_number = 9 })

    state.load_remote_comments({
      {
        file_path = "lua/a.lua",
        line = 2,
        side = "new",
        replies = {
          { body = "one", author = "octocat" },
        },
        resolved = false,
      },
      {
        file_path = "lua/very_long_filename_here.lua",
        line = 4,
        side = "new",
        replies = {
          { body = "two", author = "octocat" },
        },
        resolved = false,
      },
    })

    ui.open()

    local lines = vim.api.nvim_buf_get_lines(state.get_ui().threads_buf, 0, -1, false)
    local thread_rows = {}
    for _, line in ipairs(lines) do
      if line:match("^     %+ .+%[%d+%]") then
        table.insert(thread_rows, line)
      end
    end

    assert.are.equal(2, #thread_rows)
    local prefix_one = thread_rows[1]:match("^(.-)%[%d+%]$")
    local prefix_two = thread_rows[2]:match("^(.-)%[%d+%]$")
    assert.are.equal(vim.fn.strdisplaywidth(prefix_one), vim.fn.strdisplaywidth(prefix_two))
  end)

  it("applies colored highlights to header counts and thread badges", function()
    state.create("local", "main", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
      { path = "lua/ui.lua", status = "A", hunks = { sample_hunk(4, 4) } },
    })
    state.set_forge_info({ forge = "github", pr_number = 7 })

    state.add_note("lua/review.lua", 2, "local draft", nil, "new")
    state.load_remote_comments({
      {
        file_path = "lua/ui.lua",
        line = 4,
        side = "new",
        replies = {
          { body = "remote one", author = "octocat" },
        },
        resolved = false,
      },
    })

    ui.open()

    local files_buf = state.get_ui().explorer_buf
    local files_ns = vim.api.nvim_create_namespace("review_explorer")
    local marks = vim.api.nvim_buf_get_extmarks(files_buf, files_ns, 0, -1, { details = true })
    local thread_marks = vim.api.nvim_buf_get_extmarks(
      state.get_ui().threads_buf,
      vim.api.nvim_create_namespace("review_threads"),
      0,
      -1,
      { details = true }
    )
    local groups = {}
    local add_mark
    local del_mark
    for _, mark in ipairs(marks) do
      groups[mark[4].hl_group] = true
      if mark[4].hl_group == "ReviewStatusADim" then
        add_mark = mark
      elseif mark[4].hl_group == "ReviewStatusDDim" then
        del_mark = mark
      end
    end

    assert.is_true(groups.ReviewStatusADim)
    assert.is_true(groups.ReviewStatusDDim)
    assert.is_not_nil(add_mark)
    assert.is_not_nil(del_mark)
    assert.is_true(add_mark[4].end_col > add_mark[3])
    assert.is_true(del_mark[4].end_col > del_mark[3])
    local thread_groups = {}
    for _, mark in ipairs(thread_marks) do
      thread_groups[mark[4].hl_group] = true
    end
    assert.is_true(thread_groups.ReviewNoteRemote)
    assert.is_true(thread_groups.ReviewNoteSign)
  end)

  it("truncates branch and base context to fit the narrow rail", function()
    local original_columns = vim.o.columns
    vim.o.columns = 80

    git.current_branch = function()
      return "feature/some/extremely/long/branch/name/for-review-testing"
    end

    state.create("local", "origin/main-with-a-very-long-name", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
    })
    state.set_scope_mode("select_commit")

    ui.open()
    state.get_ui().thread_filter = "stale"
    ui.refresh()

    local lines = vim.api.nvim_buf_get_lines(state.get_ui().explorer_buf, 0, -1, false)
    local thread_lines = vim.api.nvim_buf_get_lines(state.get_ui().threads_buf, 0, -1, false)
    assert.is_true(vim.fn.strdisplaywidth(lines[1]) <= 20)
    assert.is_true(vim.fn.strdisplaywidth(lines[2]) <= 20)
    assert.is_true(lines[1]:match("…") ~= nil)
    assert.is_true(lines[2]:match("…") ~= nil)

    vim.o.columns = original_columns
  end)

  it("shows a compact total thread count below the thread filter on narrow rails", function()
    local original_columns = vim.o.columns
    vim.o.columns = 80

    state.create("local", "main", {
      { path = "lua/open.lua", status = "M", hunks = { sample_hunk(2, 2) } },
      { path = "lua/resolved.lua", status = "M", hunks = { sample_hunk(4, 4) } },
      { path = "lua/stale.lua", status = "M", hunks = { sample_hunk(6, 6) } },
    })
    state.load_remote_comments({
      {
        file_path = "lua/open.lua",
        line = 2,
        side = "new",
        replies = { { body = "open", author = "octocat" } },
        resolved = false,
      },
      {
        file_path = "lua/resolved.lua",
        line = 4,
        side = "new",
        replies = { { body = "done", author = "octocat" } },
        resolved = true,
      },
    })
    state.add_note("lua/stale.lua", 6, "stale", nil, "new")
    local stale = state.get_notes("lua/stale.lua")[1]
    stale.commit_sha = "deadbeef"
    stale.commit_short_sha = "deadbee"

    ui.open()

    local thread_lines = vim.api.nvim_buf_get_lines(state.get_ui().threads_buf, 0, 3, false)
    local header = thread_lines[1]
    assert.is_true(vim.fn.strdisplaywidth(header) <= vim.api.nvim_win_get_width(state.get_ui().threads_win))
    assert.is_nil(header:find("…", 1, true))
    assert.is_true(thread_lines[2]:find("filter:open", 1, true) ~= nil)
    assert.is_true(thread_lines[3]:find("1 thread", 1, true) ~= nil)

    vim.o.columns = original_columns
  end)

  it("shows dirty worktree counts in the navigator context", function()
    local original_columns = vim.o.columns
    vim.o.columns = 170
    state.create("local", "HEAD", {
      sample_git_file("lua/staged.lua", "M", "staged", 2, 2),
      sample_git_file("lua/unstaged.lua", "M", "unstaged", 4, 4),
    }, {
      requested_ref = nil,
      untracked_files = {
        sample_git_file("lua/new.lua", "?", "untracked", 1, 1),
      },
    })
    state.set_scope_mode("select_commit")

    ui.open()
    state.get_ui().thread_filter = "stale"
    ui.refresh()

    local lines = vim.api.nvim_buf_get_lines(state.get_ui().explorer_buf, 0, -1, false)
    local joined = table.concat(lines, "\n")
    assert.is_true(joined:find("dirty", 1, true) ~= nil)
    assert.is_true(joined:find("S1", 1, true) ~= nil or joined:find("staged 1", 1, true) ~= nil)
    assert.is_true(joined:find("U1", 1, true) ~= nil or joined:find("unstaged 1", 1, true) ~= nil)
    assert.is_true(joined:find("?1", 1, true) ~= nil or joined:find("untracked 1", 1, true) ~= nil)

    vim.o.columns = original_columns
  end)

  it("shows merge-base context when available", function()
    state.create("local", "main", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
    }, {
      merge_base_ref = "1234567890abcdef1234567890abcdef12345678",
    })
    state.set_scope_mode("select_commit")

    ui.open()

    local lines = vim.api.nvim_buf_get_lines(state.get_ui().explorer_buf, 0, -1, false)
    assert.is_true(table.concat(lines, "\n"):find("merge  1234567890ab", 1, true) ~= nil)
  end)

  it("uses fibonacci rail widths across common column sizes", function()
    local original_columns = vim.o.columns

    local cases = {
      { columns = 80, expected = 21 },
      { columns = 96, expected = 21 },
      { columns = 170, expected = 34 },
    }

    for _, case in ipairs(cases) do
      if state and state.get() then
        pcall(ui.close)
      end
      vim.o.columns = case.columns
      state.create("local", "main", {
        { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
      })

      ui.open()

      assert.are.equal(case.expected, vim.api.nvim_win_get_width(state.get_ui().explorer_win))
    end

    vim.o.columns = original_columns
  end)

  it("uses the live explorer width after a manual resize", function()
    local original_columns = vim.o.columns
    vim.o.columns = 80

    git.current_branch = function()
      return "feature/really-long-branch"
    end

    state.create("local", "main", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
    })

    ui.open()
    vim.api.nvim_win_set_width(state.get_ui().explorer_win, 29)
    ui.refresh()

    local lines = vim.api.nvim_buf_get_lines(state.get_ui().explorer_buf, 0, -1, false)
    assert.is_nil(lines[1]:match("…"))
    assert.is_true(vim.fn.strdisplaywidth(lines[1]) <= 28)

    vim.o.columns = original_columns
  end)

  it("resizes the left rail when the terminal grows", function()
    local original_columns = vim.o.columns
    vim.o.columns = 80

    state.create("local", "main", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
    })

    ui.open()
    local narrow_width = vim.api.nvim_win_get_width(state.get_ui().explorer_win)

    vim.o.columns = 170
    vim.api.nvim_exec_autocmds("VimResized", {})
    vim.wait(100, function()
      return vim.api.nvim_win_get_width(state.get_ui().explorer_win) > narrow_width
    end)

    assert.are.equal(34, vim.api.nvim_win_get_width(state.get_ui().explorer_win))
    vim.o.columns = original_columns
  end)

  it("resizes the diff area from files and threads panes", function()
    local original_columns = vim.o.columns
    vim.o.columns = 120

    state.create("local", "main", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
    })

    ui.open()

    local ui_state = state.get_ui()
    local initial_rail_width = vim.api.nvim_win_get_width(ui_state.explorer_win)
    local initial_diff_width = vim.api.nvim_win_get_width(ui_state.diff_win)

    vim.api.nvim_set_current_win(ui_state.explorer_win)
    send_keys("<C-w>>")

    assert.is_true(vim.api.nvim_win_get_width(ui_state.explorer_win) < initial_rail_width)
    assert.is_true(vim.api.nvim_win_get_width(ui_state.diff_win) > initial_diff_width)

    local expanded_diff_width = vim.api.nvim_win_get_width(ui_state.diff_win)
    vim.api.nvim_set_current_win(ui_state.threads_win)
    send_keys("<C-w><")

    assert.is_true(vim.api.nvim_win_get_width(ui_state.diff_win) < expanded_diff_width)

    vim.o.columns = original_columns
  end)

  it("limits blank scroll space below navigator panes", function()
    local files = {}
    for i = 1, 24 do
      table.insert(files, sample_git_file(string.format("lua/file_%02d.lua", i), "M", "unstaged", i, i))
    end
    state.create("local", "main", files)

    ui.open()

    local ui_state = state.get_ui()
    vim.api.nvim_win_set_height(ui_state.explorer_win, 8)
    local line_count = vim.api.nvim_buf_line_count(ui_state.explorer_buf)
    local max_topline = math.max(line_count - vim.api.nvim_win_get_height(ui_state.explorer_win) + 1, 1)

    vim.api.nvim_win_call(ui_state.explorer_win, function()
      vim.fn.winrestview({ topline = line_count })
    end)
    vim.api.nvim_exec_autocmds("WinScrolled", {})
    vim.wait(100, function()
      local view
      vim.api.nvim_win_call(ui_state.explorer_win, function()
        view = vim.fn.winsaveview()
      end)
      return view.topline <= max_topline
    end)

    vim.api.nvim_win_call(ui_state.explorer_win, function()
      assert.is_true(vim.fn.winsaveview().topline <= max_topline)
    end)
  end)

	  it("shows untracked files only in all scope and exposes stale notes separately", function()
	    state.create("local", "main", {
	      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
    }, {
      repo_root = git.root(),
      branch = "feature/rail-polish",
      requested_ref = nil,
      untracked_files = {
        { path = "lua/scratch.lua", status = "?", untracked = true, hunks = { sample_hunk(1, 1) } },
      },
    })
    state.add_note("lua/missing.lua", 3, "stale", nil, "new")
    local stale = state.get_notes("lua/missing.lua")[1]
    stale.commit_sha = "deadbeef"
    stale.commit_short_sha = "deadbee"

    ui.open()
    state.get_ui().thread_filter = "stale"
    ui.refresh()

    local lines = vim.api.nvim_buf_get_lines(state.get_ui().explorer_buf, 0, -1, false)
    local thread_lines = vim.api.nvim_buf_get_lines(state.get_ui().threads_buf, 0, -1, false)
    assert.is_true(vim.tbl_contains(lines, " Untracked"))
    local scratch_count = 0
    for _, line in ipairs(lines) do
      if line:match("%?%s+scra.*lua") then
        scratch_count = scratch_count + 1
      end
    end
    assert.are.equal(1, scratch_count)
    local thread_text = table.concat(thread_lines, "\n")
    assert.is_true(thread_text:find("filter:stale", 1, true) ~= nil)
    assert.is_true(thread_text:find("1 thread", 1, true) ~= nil)

    state.set_commits({
      {
        sha = "abcdef123456",
        short_sha = "abcdef1",
        message = "Polish UI",
        author = "psanchez",
        files = {
          { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
        },
      },
    })
    state.set_scope_mode("current_commit")
    state.set_commit(1)
    ui.refresh()

    lines = vim.api.nvim_buf_get_lines(state.get_ui().explorer_buf, 0, -1, false)
    assert.is_false(vim.tbl_contains(lines, " Untracked"))
  end)

  it("hydrates lazy untracked files only when rendering their diff", function()
    local git_module = require("review.git")
    local original_hydrate = git_module.hydrate_untracked_file
    local hydrate_count = 0
    git_module.hydrate_untracked_file = function(file)
      hydrate_count = hydrate_count + 1
      file.untracked_lazy = false
      file.hunks = { sample_hunk(1, 1) }
      file._review_cache = nil
      return file
    end

    state.create("local", "main", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
    }, {
      untracked_files = {
        { path = "lua/new.lua", status = "?", untracked = true, untracked_lazy = true, hunks = {} },
      },
    })

    ui.open()
    assert.are.equal(0, hydrate_count)

    ui.select_file(2)
    assert.are.equal(1, hydrate_count)
    assert.is_false(state.active_current_file().untracked_lazy)

    git_module.hydrate_untracked_file = original_hydrate
  end)

  it("shows stale remote threads when forge context becomes outdated", function()
    state.create("local", "main", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
    }, {
      repo_root = git.root(),
      branch = "feature/rail-polish",
      requested_ref = nil,
      untracked_files = {},
    })
    state.set_forge_info({ forge = "github", pr_number = 7 })
    state.load_remote_comments({
      {
        file_path = "lua/review.lua",
        line = 2,
        side = "new",
        replies = {
          { body = "remote one", author = "octocat" },
        },
        resolved = false,
      },
    })
    state.set_remote_context_stale("PR is closed")

    ui.open()
    state.get_ui().thread_filter = "stale"
    ui.refresh()

    local lines = vim.api.nvim_buf_get_lines(state.get_ui().threads_buf, 0, -1, false)
    local joined = table.concat(lines, "\n")
    assert.is_true(joined:match("github/") ~= nil)
    assert.is_true(joined:match("revi.*lua.*%[%d+%]") ~= nil or joined:match("review%.lua.*%[%d+%]") ~= nil)
  end)

  it("notifies when cycling stack with no commits in range", function()
    local original_notify = vim.notify
    local notified

    vim.notify = function(msg, level)
      notified = { msg = msg, level = level }
    end

    state.create("local", "main", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
    })

    ui.open()
    vim.api.nvim_set_current_win(state.get_ui().explorer_win)
    send_keys("<Tab>")

    vim.notify = original_notify

    assert.are.same({
      msg = "No commits in the current review range",
      level = vim.log.levels.INFO,
    }, notified)
  end)

  it("reopens the session when the git branch changes under the active UI", function()
    state.create("local", "main", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
    }, {
      repo_root = "/tmp/review-nvim",
      branch = "feature/rail-polish",
      requested_ref = nil,
      untracked_files = {},
    })

    ui.open()

    local called = false
    local original_reopen = review.reopen_session
    review.reopen_session = function()
      called = true
    end
    git.current_branch = function()
      return "feature/changed-branch"
    end

    ui.refresh()

    review.reopen_session = original_reopen
    assert.is_true(called)
  end)
end)

describe("review.ui thread view", function()
  local ui
  local original_ui_module

  before_each(function()
    original_ui_module = package.loaded["review.ui"]
    package.loaded["review.ui"] = nil
    ui = require("review.ui")
  end)

  after_each(function()
    close_current_float()
    package.loaded["review.ui"] = original_ui_module
  end)

  it("renders a compact thread header without duplicate title text", function()
    ui.open_thread_view({
      id = 17,
      file_path = "lua/review/ui.lua",
      line = 42,
      resolved = false,
      replies = {
        {
          author = "octocat",
          body = "First reply",
          created_at = "2026-05-11T10:00:00Z",
        },
        {
          author = "psanchez",
          body = "Second reply",
          created_at = "2026-05-11T11:00:00Z",
        },
      },
    })

    local buf = vim.api.nvim_get_current_buf()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, 8, false)

    assert.are_not.equal(" Thread", lines[1])
    assert.are.equal(" #17 lua/review/ui.lua:42", lines[1])
    assert.are.equal(" open  ·  2 replies", lines[2])
    assert.are.equal(string.rep("─", vim.fn.strdisplaywidth(lines[3])), lines[3])
    assert.are.equal(" @octocat · 2026-05-11", lines[4])
    assert.are.equal("   First reply", lines[5])
    assert.are.equal("", lines[6])
    assert.are.equal(" @psanchez · 2026-05-11", lines[7])
  end)

  it("wraps the thread footer legend on narrow terminals", function()
    local original_columns = vim.o.columns
    vim.o.columns = 58

    ui.open_thread_view({
      file_path = "lua/review/ui.lua",
      line = 42,
      resolved = false,
      replies = {
        {
          author = "octocat",
          body = "First reply",
          created_at = "2026-05-11T10:00:00Z",
        },
      },
    })

    local buf = vim.api.nvim_get_current_buf()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local footer_one = lines[#lines - 1]
    local footer_two = lines[#lines]

    assert.are.equal(" e edit  d delete  r reply  x resolve  b browse", footer_one)
    assert.are.equal(" q close  ? help", footer_two)

    vim.o.columns = original_columns
  end)

  it("shows reopen instead of resolve for resolved threads", function()
    ui.open_thread_view({
      file_path = "lua/review/ui.lua",
      line = 42,
      resolved = true,
      replies = {
        {
          author = "octocat",
          body = "First reply",
          created_at = "2026-05-11T10:00:00Z",
        },
      },
    })

    local buf = vim.api.nvim_get_current_buf()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local footer = table.concat({ lines[#lines - 1], lines[#lines] }, " ")

    assert.is_true(footer:match("x reopen") ~= nil)
    assert.is_nil(footer:match("x resolve"))
  end)

  it("wraps long reply bodies by display width", function()
    local original_columns = vim.o.columns
    vim.o.columns = 58

    ui.open_thread_view({
      file_path = "lua/review/ui.lua",
      line = 42,
      resolved = false,
      replies = {
        {
          author = "octocat",
          body = "This is a fairly long reply body that should wrap cleanly without relying on raw byte counts.",
          created_at = "2026-05-11T10:00:00Z",
        },
      },
    })

    local win = vim.api.nvim_get_current_win()
    local cfg = vim.api.nvim_win_get_config(win)
    local buf = vim.api.nvim_get_current_buf()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, 10, false)

    assert.are.equal("   This is a fairly long reply body that should", lines[5])
    assert.are.equal("   wrap cleanly without relying on raw byte counts.", lines[6])
    assert.is_true(vim.fn.strdisplaywidth(lines[5]) <= cfg.width)
    assert.is_true(vim.fn.strdisplaywidth(lines[6]) <= cfg.width)

    vim.o.columns = original_columns
  end)
end)

describe("review.ui help", function()
  local ui
  local git
  local original_ui_module
  local original_git_module
  local original_executable
  local original_parse_remote

  before_each(function()
    original_ui_module = package.loaded["review.ui"]
    original_git_module = package.loaded["review.git"]
    original_executable = vim.fn.executable
    package.loaded["review.ui"] = nil
    ui = require("review.ui")
    git = require("review.git")
    original_parse_remote = git.parse_remote
  end)

  after_each(function()
    close_current_float()
    vim.fn.executable = original_executable
    if git then
      git.parse_remote = original_parse_remote
    end
    package.loaded["review.ui"] = original_ui_module
    package.loaded["review.git"] = original_git_module
  end)

  it("keeps help focused on commands and keymaps", function()
    ui.open_help()

    local buf = vim.api.nvim_get_current_buf()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local joined = table.concat(lines, "\n")

    assert.is_true(lines[1]:find("review.nvim", 1, true) ~= nil)
    assert.is_true(joined:match("NAVIGATOR") ~= nil)
    assert.is_true(joined:match("DIFF") ~= nil)
    assert.is_true(joined:match("COMMANDS") ~= nil)
    assert.is_true(joined:match("TOOLS") ~= nil)
    assert.is_true(joined:match("open file, thread") ~= nil)
    assert.is_nil(joined:match("tree/flat files"))
    assert.is_true(joined:match("unified/split") ~= nil)
    assert.is_nil(joined:match("AI Review Focus"))
    assert.is_true(joined:find("*review-help*", 1, true) ~= nil)
  end)

  it("explains unavailable forge and GitButler tools", function()
    git.parse_remote = function()
      return { forge = "github", owner = "pesap", repo = "review.nvim" }
    end
    vim.fn.executable = function(name)
      if name == "git" then
        return 1
      end
      return 0
    end

    ui.open_help()

    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false)
    local joined = table.concat(lines, "\n")
    assert.is_true(joined:find("GitHub", 1, true) ~= nil)
    assert.is_true(joined:find("missing: install gh", 1, true) ~= nil)
    assert.is_true(joined:find("GitButler", 1, true) ~= nil)
    assert.is_true(joined:find("install but", 1, true) ~= nil)
    assert.is_nil(joined:find("GitLab", 1, true))
  end)

  it("avoids local session resync during refresh when the workspace is unchanged", function()
    local review = require("review")
    local state = require("review.state")
	    local git = require("review.git")
	    local original_refresh_local_session = review.refresh_local_session
	    local original_workspace_signature = git.workspace_signature
	    local original_session_matches_vcs = state.session_matches_vcs
	    state.session_matches_vcs = function()
	      return true
	    end

    state.create("local", "main", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
    }, {
      requested_ref = nil,
      branch = "feature/rail-polish",
	      repo_root = git.root(),
      untracked_files = {},
    })
    local signature_calls = 0
    git.workspace_signature = function()
      signature_calls = signature_calls + 1
      return "## feature/rail-polish"
    end
    state.get().workspace_signature = "## feature/rail-polish"

	    ui.open()
	    local signature_calls_before_refresh = signature_calls

	    local calls = 0
	    review.refresh_local_session = function()
	      calls = calls + 1
      return true
    end

    ui.refresh()
    ui.refresh()

	    assert.are.equal(0, calls)
	    assert.are.equal(signature_calls_before_refresh + 1, signature_calls)

	    review.refresh_local_session = original_refresh_local_session
	    git.workspace_signature = original_workspace_signature
	    state.session_matches_vcs = original_session_matches_vcs
    if state.get() then
      pcall(ui.close)
    end
  end)

  it("resyncs changed local workspaces asynchronously without duplicate refresh jobs", function()
    local review = require("review")
    local state = require("review.state")
    local git = require("review.git")
    local original_refresh_local_session_async = review.refresh_local_session_async
    local original_workspace_signature = git.workspace_signature
    local original_root = git.root
    local original_session_matches_vcs = state.session_matches_vcs

    local workspace_signature = "old-signature"
    git.root = function()
      return "/tmp/review-ui-spec"
    end
    state.session_matches_vcs = function()
      return true
    end
    state.create("local", "main", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
    }, {
      requested_ref = nil,
      branch = "feature/rail-polish",
      repo_root = "/tmp/review-ui-spec",
      untracked_files = {},
      workspace_signature = "old-signature",
    })
    git.workspace_signature = function()
      return workspace_signature
    end

    ui.open()

    local calls = 0
    local pending_callback
    review.refresh_local_session_async = function(signature, callback)
      calls = calls + 1
      assert.are.equal("new-signature", signature)
      pending_callback = callback
    end

    local ok, err = pcall(function()
      workspace_signature = "new-signature"
      assert.is_nil(state.get().requested_ref)
      assert.are.equal("old-signature", state.get().workspace_signature)
      assert.are.equal("new-signature", git.workspace_signature())
      ui.refresh()
      ui.refresh()

      assert.are.equal(1, calls)
      assert.is_not_nil(pending_callback)

      state.get().workspace_signature = "new-signature"
      pending_callback(true, nil)
      assert.are.equal(1, calls)
    end)

    review.refresh_local_session_async = original_refresh_local_session_async
    git.workspace_signature = original_workspace_signature
    git.root = original_root
    state.session_matches_vcs = original_session_matches_vcs
    if state.get() then
      pcall(ui.close)
    end
    assert.is_true(ok, err)
  end)

  it("refreshes remote comments after a local refresh when forge context exists", function()
    local review = require("review")
    local state = require("review.state")
    local original_refresh_local_session = review.refresh_local_session
    local original_refresh_local_session_async = review.refresh_local_session_async
    local original_refresh_comments = review.refresh_comments
    local original_refresh = ui.refresh

    state.create("local", "main", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
    })
    state.set_forge_info({ forge = "github", pr_number = 19 })

    local local_calls = 0
    local comment_calls = 0
    local ui_refresh_calls = 0
    review.refresh_local_session = function()
      local_calls = local_calls + 1
      return true
    end
    review.refresh_local_session_async = function(_, callback)
      local_calls = local_calls + 1
      callback(true, nil)
    end
    review.refresh_comments = function()
      comment_calls = comment_calls + 1
    end
    ui.refresh = function()
      ui_refresh_calls = ui_refresh_calls + 1
    end

    local ok, err = pcall(function()
      ui.refresh_session()

      assert.are.equal(1, local_calls)
      assert.are.equal(1, comment_calls)
      assert.are.equal(0, ui_refresh_calls)
    end)

    review.refresh_local_session = original_refresh_local_session
    review.refresh_local_session_async = original_refresh_local_session_async
    review.refresh_comments = original_refresh_comments
    ui.refresh = original_refresh
    assert.is_true(ok, err)
  end)

  it("wraps long help entries on narrow terminals", function()
    local original_columns = vim.o.columns
    vim.o.columns = 58

    ui.open_help()

    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_get_current_buf()
    local cfg = vim.api.nvim_win_get_config(win)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local joined = table.concat(lines, "\n")

    assert.is_true(lines[1]:find("review.nvim", 1, true) ~= nil)
    assert.is_true(joined:find(":ReviewClipboard", 1, true) ~= nil)
    assert.is_true(joined:find("copy all review notes", 1, true) ~= nil)
    assert.is_true(joined:match(":ReviewRefresh") ~= nil)
    assert.is_true(joined:match("refresh") ~= nil)

    for _, line in ipairs(lines) do
      assert.is_true(vim.fn.strdisplaywidth(line) <= cfg.width)
    end

    vim.o.columns = original_columns
  end)
end)

describe("review.ui notes list", function()
  local review = require("review")
  local state
  local ui
  local original_storage_module
  local original_state_module
  local original_ui_module

  before_each(function()
    original_storage_module = package.loaded["review.storage"]
    original_state_module = package.loaded["review.state"]
    original_ui_module = package.loaded["review.ui"]

    package.loaded["review.storage"] = {
      load = function()
        return {}
      end,
      save = function() end,
    }
    package.loaded["review.state"] = nil
    package.loaded["review.ui"] = nil

    state = require("review.state")
    ui = require("review.ui")
    review.setup({})
  end)

  after_each(function()
    close_current_float()
    if state and state.get() then
      state.destroy()
    end
    package.loaded["review.storage"] = original_storage_module
    package.loaded["review.state"] = original_state_module
    package.loaded["review.ui"] = original_ui_module
  end)

  it("opens directly into note sections without a duplicated queue summary", function()
    state.create("local", "main", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
      { path = "lua/ui.lua", status = "A", hunks = { sample_hunk(4, 4) } },
    })
    state.add_note("lua/review.lua", 2, "local draft note body", nil, "new")
    state.load_remote_comments({
      {
        file_path = "lua/ui.lua",
        line = 4,
        side = "new",
        replies = {
          { body = "remote thread first line", author = "octocat", created_at = "2026-05-11T10:00:00Z" },
          { body = "follow up", author = "psanchez", created_at = "2026-05-11T11:00:00Z" },
        },
        resolved = false,
      },
    })

    ui.open_notes_list()

    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_get_current_buf()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local cfg = vim.api.nvim_win_get_config(win)
    local title = cfg.title and cfg.title[1] and cfg.title[1][1] or ""

    assert.are.equal(" Your Notes (1)", lines[1])
    assert.are.equal(" Open Threads (1)", lines[4])
    assert.is_nil(lines[1]:match("Review Queue"))
    assert.is_nil(lines[1]:match("1 local"))
    assert.are.equal(" Notes │ 1 yours  1 open ", title)
  end)

  it("truncates long note locations without crowding out the body", function()
    state.create("local", "main", {
      { path = "lua/very_long_filename_for_notes_alignment.lua", status = "M", hunks = { sample_hunk(42, 42) } },
    })
    state.add_note("lua/very_long_filename_for_notes_alignment.lua", 42, "body text here", nil, "new")

    ui.open_notes_list()

    local buf = vim.api.nvim_get_current_buf()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

    assert.is_true(lines[2]:match("^  ○ #%d+ .+  body text here$") ~= nil)
    assert.is_true(lines[2]:match("very_long") ~= nil)
    assert.is_true(lines[2]:match("42") ~= nil)
  end)

  it("shows note ids in the notes list", function()
    state.create("local", "main", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
    })
    state.add_note("lua/review.lua", 2, "local draft note body", nil, "new")
    local note_id = state.get_notes()[1].id

    ui.open_notes_list()

    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false)
    assert.is_true(lines[2]:find("#" .. tostring(note_id), 1, true) ~= nil)
  end)

  it("deletes local notes from the notes list", function()
    state.create("local", "main", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
    })
    state.add_note("lua/review.lua", 2, "delete me", nil, "new")

    local original_confirm = vim.fn.confirm
    vim.fn.confirm = function()
      return 1
    end

    ui.open_notes_list()
    vim.api.nvim_win_set_cursor(vim.api.nvim_get_current_win(), { 2, 0 })
    send_keys("d")

    vim.fn.confirm = original_confirm
    assert.are.equal(0, #state.get_notes())
  end)

  it("filters the notes list by search text and status", function()
    state.create("local", "main", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
      { path = "lua/ui.lua", status = "M", hunks = { sample_hunk(4, 4) } },
    })
    state.add_note("lua/review.lua", 2, "local draft note body", nil, "new")
    state.load_remote_comments({
      {
        file_path = "lua/ui.lua",
        line = 4,
        side = "new",
        replies = {
          { body = "remote thread needle", author = "octocat", created_at = "2026-05-11T10:00:00Z" },
        },
        resolved = false,
      },
      {
        file_path = "lua/review.lua",
        line = 2,
        side = "new",
        replies = {
          { body = "resolved needle", author = "octocat", created_at = "2026-05-11T10:00:00Z" },
        },
        resolved = true,
      },
    })

    ui.open_notes_list({ query = "needle", status_filter = "open" })

    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false)
    assert.are.equal(" Filters: status=open  search=needle", lines[1])
    assert.is_true(vim.tbl_contains(lines, " Open Threads (1)"))
    assert.is_false(vim.tbl_contains(lines, " Your Notes (1)"))
    assert.is_false(vim.tbl_contains(lines, " Resolved (1)"))
    assert.is_true(table.concat(lines, "\n"):find("remote thread needle", 1, true) ~= nil)
  end)

  it("cycles and clears persisted notes list filters", function()
    state.create("local", "main", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
      { path = "lua/ui.lua", status = "M", hunks = { sample_hunk(4, 4) } },
    })
    state.add_note("lua/review.lua", 2, "local draft note body", nil, "new")
    state.load_remote_comments({
      {
        file_path = "lua/ui.lua",
        line = 4,
        side = "new",
        replies = {
          { body = "remote thread first line", author = "octocat", created_at = "2026-05-11T10:00:00Z" },
        },
        resolved = false,
      },
    })

    ui.open_notes_list()
    send_keys("f")

    assert.are.equal("local", state.get_ui_prefs().notes_status_filter)
    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false)
    assert.are.equal(" Filters: status=local", lines[1])
    assert.is_true(vim.tbl_contains(lines, " Your Notes (1)"))
    assert.is_false(vim.tbl_contains(lines, " Open Threads (1)"))

    state.update_ui_prefs({ notes_query = "remote" })
    ui.refresh_notes_list()
    send_keys("c")

    assert.are.equal("", state.get_ui_prefs().notes_query)
    assert.are.equal("all", state.get_ui_prefs().notes_status_filter)
  end)

  it("attaches queued blame/history context to an existing local note", function()
    state.create("local", "main", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
    })
    state.add_note("lua/review.lua", 2, "local draft note body", nil, "new")

    state.set_ui({
      pending_note_context = {
      blame_context = "abc12345 reviewer old line",
      log_context = "def67890 2026-05-15 reviewer fix context",
      },
    })
    ui.open_notes_list()

    vim.api.nvim_win_set_cursor(vim.api.nvim_get_current_win(), { 2, 0 })
    send_keys("a")

    local note = state.get_notes("lua/review.lua")[1]
    assert.are.equal("abc12345 reviewer old line", note.blame_context)
    assert.are.equal("def67890 2026-05-15 reviewer fix context", note.log_context)
    assert.is_nil(state.get_ui().pending_note_context)
  end)

  it("wraps the notes footer legend on narrow terminals", function()
    local original_columns = vim.o.columns
    vim.o.columns = 58

    state.create("local", "main", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
    })
    state.add_note("lua/review.lua", 2, "local draft note body", nil, "new")

    ui.open_notes_list()

    local buf = vim.api.nvim_get_current_buf()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

    local footer = table.concat(lines, " ")
    assert.is_true(footer:match("<CR> open") ~= nil)
    assert.is_true(footer:match("x resolve") ~= nil)
    assert.is_true(footer:match("/ search") ~= nil)
    assert.is_true(footer:match("f filter") ~= nil)
    assert.is_true(footer:match("q close") ~= nil)

    vim.o.columns = original_columns
  end)

  it("compacts the notes title to fit narrow floats", function()
    local original_columns = vim.o.columns
    vim.o.columns = 58

    state.create("local", "main", {
      { path = "lua/a.lua", status = "M", hunks = { sample_hunk(2, 2) } },
      { path = "lua/b.lua", status = "M", hunks = { sample_hunk(4, 4) } },
      { path = "lua/c.lua", status = "M", hunks = { sample_hunk(6, 6) } },
    })
    state.add_note("lua/a.lua", 2, "draft", nil, "new")
    local notes = state.get_notes()
    notes[1].status = "staged"
    state.add_note("lua/b.lua", 4, "draft2", nil, "new")
    state.load_remote_comments({
      {
        file_path = "lua/c.lua",
        line = 6,
        side = "new",
        replies = {
          { body = "open", author = "octocat", created_at = "2026-05-11T10:00:00Z" },
        },
        resolved = false,
      },
      {
        file_path = nil,
        line = nil,
        side = nil,
        replies = {
          { body = "disc", author = "octocat", created_at = "2026-05-11T10:00:00Z" },
        },
        resolved = false,
        is_general = true,
      },
      {
        file_path = "lua/a.lua",
        line = 2,
        side = "new",
        replies = {
          { body = "res", author = "octocat", created_at = "2026-05-11T10:00:00Z" },
        },
        resolved = true,
      },
    })
    state.set_comments_loading(true)

    ui.open_notes_list()

    local win = vim.api.nvim_get_current_win()
    local cfg = vim.api.nvim_win_get_config(win)
    local title = cfg.title and cfg.title[1] and cfg.title[1][1] or ""

    assert.are.equal(" Notes │ 2y  1o  1d  1r  sync ", title)
    assert.is_true(vim.fn.strdisplaywidth(title) <= cfg.width)

    vim.o.columns = original_columns
  end)

  it("shows remote discussions and remote file comments regardless of current commit scope", function()
    state.create("local", "main", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
    })
    state.set_commits({
      {
        sha = "abcdef123456",
        short_sha = "abcdef1",
        message = "Polish UI",
        author = "psanchez",
        files = {
          { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
        },
      },
    })
    state.set_scope_mode("current_commit")
    state.set_commit(1)
    state.load_remote_comments({
      {
        file_path = "ROADMAP.md",
        line = 16,
        side = "new",
        replies = {
          { body = "remote file comment", author = "octocat", created_at = "2026-05-11T10:00:00Z" },
        },
        resolved = false,
      },
      {
        file_path = nil,
        line = nil,
        side = nil,
        replies = {
          { body = "discussion body", author = "copilot-pull-request-reviewer", created_at = "2026-05-11T10:00:00Z" },
        },
        resolved = nil,
        is_general = true,
      },
    })

    ui.open_notes_list()

    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false)
    assert.is_true(vim.tbl_contains(lines, " Open Threads (1)"))
    assert.is_true(vim.tbl_contains(lines, " Discussion (1)"))
  end)

  it("publishes GitButler notes to their branch PR targets only", function()
    local gitbutler = require("review.gitbutler")
    local forge = require("review.forge")
    local original_resolve_target = gitbutler.resolve_review_target
    local original_resolve_context = forge.resolve_context
    local original_post_comment = forge.post_comment
    local original_refresh = ui.refresh

    state.create("local", "gitbutler/workspace", {
      { path = "lua/a.lua", status = "M", hunks = { sample_hunk(2, 2) } },
      { path = "lua/b.lua", status = "M", hunks = { sample_hunk(4, 4) } },
      { path = "scratch.lua", status = "A", hunks = { sample_hunk(1, 1) } },
    }, {
      vcs = "gitbutler",
      repo_root = require("review.git").root(),
      branch = require("review.git").current_branch() or "HEAD",
      gitbutler = {},
    })
    state.set_commits({
      {
        sha = "branch-a",
        short_sha = "brancha",
        message = "feature/a",
        files = { { path = "lua/a.lua", status = "M", hunks = { sample_hunk(2, 2) } } },
        gitbutler = { kind = "branch", branch_name = "feature/a", review_id = "(#11)" },
      },
      {
        sha = "branch-b",
        short_sha = "branchb",
        message = "feature/b",
        files = { { path = "lua/b.lua", status = "M", hunks = { sample_hunk(4, 4) } } },
        gitbutler = { kind = "branch", branch_name = "feature/b" },
      },
      {
        sha = "gitbutler-unassigned",
        short_sha = "unassgn",
        message = "unassigned changes",
        files = { { path = "scratch.lua", status = "A", hunks = { sample_hunk(1, 1) } } },
        gitbutler = { kind = "unassigned" },
      },
    })

    state.set_commit(1)
    state.set_scope_mode("current_commit")
    state.add_note("lua/a.lua", 2, "note a", nil, "new")
    state.toggle_staged(state.get_notes()[1].id)
    state.set_commit(2)
    state.add_note("lua/b.lua", 4, "note b", nil, "new")
    state.toggle_staged(state.get_notes()[2].id)
    state.set_commit(3)
    state.add_note("scratch.lua", 1, "note unassigned", nil, "new")
    state.toggle_staged(state.get_notes()[3].id)

    gitbutler.resolve_review_target = function(scope)
      if scope.kind == "unassigned" then
        return nil, "unassigned GitButler changes do not have a remote review target"
      end
      if scope.branch_name == "feature/a" then
        return { forge = "github", owner = "pesap", repo = "review.nvim", pr_number = 11, branch_name = "feature/a" }
      end
      if scope.branch_name == "feature/b" then
        return { forge = "github", owner = "pesap", repo = "review.nvim", pr_number = 12, branch_name = "feature/b" }
      end
      return nil, "unexpected scope"
    end
    forge.resolve_context = function(info)
      return { commit_id = "head" .. tostring(info.pr_number) }, nil
    end
    local posted = {}
    forge.post_comment = function(info, note, ctx)
      table.insert(posted, { pr = info.pr_number, note = note.body, commit = ctx.commit_id })
      return "https://example.test/" .. tostring(info.pr_number) .. "/" .. tostring(note.id), nil
    end
    ui.refresh = function() end

    local ok, err = pcall(function()
      ui.open_notes_list()
      send_keys("P")

      assert.are.equal(2, #posted)
      assert.are.equal(11, posted[1].pr)
      assert.are.equal(12, posted[2].pr)
      local remaining = state.get_notes()
      assert.are.equal(1, #remaining)
      assert.are.equal("note unassigned", remaining[1].body)
      assert.are.equal("staged", remaining[1].status)
    end)

    gitbutler.resolve_review_target = original_resolve_target
    forge.resolve_context = original_resolve_context
    forge.post_comment = original_post_comment
    ui.refresh = original_refresh
    assert.is_true(ok, err)
  end)

  it("includes note ids when publish context resolution fails", function()
    local forge = require("review.forge")
    local original_resolve_context = forge.resolve_context
    local original_notify = vim.notify

    state.create("local", "main", {
      { path = "lua/a.lua", status = "M", hunks = { sample_hunk(2, 2) } },
      { path = "lua/b.lua", status = "M", hunks = { sample_hunk(4, 4) } },
    })
    state.set_forge_info({ forge = "github", owner = "pesap", repo = "review.nvim", pr_number = 22 })
    state.add_note("lua/a.lua", 2, "note a", nil, "new")
    state.add_note("lua/b.lua", 4, "note b", nil, "new")
    local first_id = state.get_notes()[1].id
    local second_id = state.get_notes()[2].id
    state.toggle_staged(first_id)
    state.toggle_staged(second_id)

    local notified
    vim.notify = function(msg, level)
      notified = { msg = msg, level = level }
    end
    forge.resolve_context = function()
      return nil, "missing head commit"
    end

    ui.open_notes_list()
    send_keys("P")

    forge.resolve_context = original_resolve_context
    vim.notify = original_notify

    assert.are.equal(vim.log.levels.ERROR, notified.level)
    assert.is_true(notified.msg:find("#" .. tostring(first_id), 1, true) ~= nil)
    assert.is_true(notified.msg:find("#" .. tostring(second_id), 1, true) ~= nil)
    assert.is_true(notified.msg:find("missing head commit", 1, true) ~= nil)
  end)

  it("copies a handoff packet for the selected note's review unit", function()
    state.create("local", "main", {
      { path = "lua/a.lua", status = "M", hunks = { sample_hunk(2, 2) } },
      { path = "lua/b.lua", status = "M", hunks = { sample_hunk(4, 4) } },
    }, {
      branch = "feature/rail-polish",
    })
    state.set_commits({
      {
        sha = "aaaaaaa111111",
        short_sha = "aaaaaaa",
        message = "agent a",
        files = { { path = "lua/a.lua", status = "M", hunks = { sample_hunk(2, 2) } } },
      },
      {
        sha = "bbbbbbb222222",
        short_sha = "bbbbbbb",
        message = "agent b",
        files = { { path = "lua/b.lua", status = "M", hunks = { sample_hunk(4, 4) } } },
      },
    })

    state.set_commit(1)
    state.add_note("lua/a.lua", 2, "note a", nil, "new")
    state.set_commit(2)
    state.add_note("lua/b.lua", 4, "note b", nil, "new")
    state.set_commit(nil)

    ui.copy_unit_notes_for_note(state.get_notes()[1].id)
    local content = vim.fn.getreg('"')
    assert.is_true(content:find("## aaaaaaa", 1, true) ~= nil)
    assert.is_true(content:find("note a", 1, true) ~= nil)
    assert.is_true(content:find("note b", 1, true) == nil)
  end)

  it("copies a handoff packet from the selected review unit row", function()
    state.create("local", "main", {
      { path = "lua/a.lua", status = "M", hunks = { sample_hunk(2, 2) } },
      { path = "lua/b.lua", status = "M", hunks = { sample_hunk(4, 4) } },
    }, {
      branch = "feature/rail-polish",
    })
    state.set_commits({
      {
        sha = "aaaaaaa111111",
        short_sha = "aaaaaaa",
        message = "agent a",
        files = { { path = "lua/a.lua", status = "M", hunks = { sample_hunk(2, 2) } } },
      },
      {
        sha = "bbbbbbb222222",
        short_sha = "bbbbbbb",
        message = "agent b",
        files = { { path = "lua/b.lua", status = "M", hunks = { sample_hunk(4, 4) } } },
      },
    })

    state.set_commit(1)
    state.add_note("lua/a.lua", 2, "note a", nil, "new")
    state.set_commit(2)
    state.add_note("lua/b.lua", 4, "note b", nil, "new")
    state.set_commit(nil)
    state.set_scope_mode("select_commit")
    vim.fn.setreg('"', "")

    ui.open()
    local ui_state = state.get_ui()
    local lines = vim.api.nvim_buf_get_lines(ui_state.explorer_buf, 0, -1, false)
    local commit_line
    for idx, line in ipairs(lines) do
      if line:match("^%s+aaaaaaa") then
        commit_line = idx
        break
      end
    end
    assert.is_not_nil(commit_line)

    vim.api.nvim_set_current_win(ui_state.explorer_win)
    vim.api.nvim_win_set_cursor(ui_state.explorer_win, { commit_line, 0 })
    send_keys("u")

    local content = vim.fn.getreg('"')
    assert.is_true(content:find("## aaaaaaa", 1, true) ~= nil)
    assert.is_true(content:find("note a", 1, true) ~= nil)
    assert.is_true(content:find("note b", 1, true) == nil)
    ui.close()
  end)

  it("keeps the notes list open while refreshing remote comments", function()
    local original_refresh_comments = review.refresh_comments

    state.create("local", "main", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
    })
    state.load_remote_comments({
      {
        file_path = "lua/review.lua",
        line = 2,
        side = "new",
        replies = {
          { body = "resolved", author = "octocat", created_at = "2026-05-11T10:00:00Z" },
        },
        resolved = true,
      },
    })

    local calls = 0
    review.refresh_comments = function(opts)
      calls = calls + 1
      assert.is_true(opts.preserve_notes_list)
      state.set_comments_loading(true)
      ui.refresh_notes_list()
      state.set_comments_loading(false)
      ui.refresh_notes_list()
    end

    ui.open_notes_list()
    local original_win = vim.api.nvim_get_current_win()

    send_keys("R")

    assert.are.equal(1, calls)
    assert.is_true(vim.api.nvim_win_is_valid(vim.api.nvim_get_current_win()))
    assert.are_not.equal(original_win, 0)
    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false)
    assert.is_true(vim.tbl_contains(lines, " Resolved (1)"))

    review.refresh_comments = original_refresh_comments
  end)

  it("falls back to a minimal notes title on extremely narrow floats", function()
    local original_columns = vim.o.columns
    vim.o.columns = 24

    state.create("local", "main", {
      { path = "lua/a.lua", status = "M", hunks = { sample_hunk(2, 2) } },
      { path = "lua/b.lua", status = "M", hunks = { sample_hunk(4, 4) } },
      { path = "lua/c.lua", status = "M", hunks = { sample_hunk(6, 6) } },
    })
    state.add_note("lua/a.lua", 2, "draft", nil, "new")
    local notes = state.get_notes()
    notes[1].status = "staged"
    state.add_note("lua/b.lua", 4, "draft2", nil, "new")
    state.load_remote_comments({
      {
        file_path = "lua/c.lua",
        line = 6,
        side = "new",
        replies = {
          { body = "open", author = "octocat", created_at = "2026-05-11T10:00:00Z" },
        },
        resolved = false,
      },
      {
        file_path = nil,
        line = nil,
        side = nil,
        replies = {
          { body = "disc", author = "octocat", created_at = "2026-05-11T10:00:00Z" },
        },
        resolved = false,
        is_general = true,
      },
      {
        file_path = "lua/a.lua",
        line = 2,
        side = "new",
        replies = {
          { body = "res", author = "octocat", created_at = "2026-05-11T10:00:00Z" },
        },
        resolved = true,
      },
    })
    state.set_comments_loading(true)

    ui.open_notes_list()

    local win = vim.api.nvim_get_current_win()
    local cfg = vim.api.nvim_win_get_config(win)
    local title = cfg.title and cfg.title[1] and cfg.title[1][1] or ""

    assert.are.equal(" Notes ", title)
    assert.is_true(vim.fn.strdisplaywidth(title) <= cfg.width)

    vim.o.columns = original_columns
  end)
end)

describe("review.ui editor titles", function()
  local review = require("review")
  local state
  local ui
  local original_storage_module
  local original_state_module
  local original_ui_module

  before_each(function()
    original_storage_module = package.loaded["review.storage"]
    original_state_module = package.loaded["review.state"]
    original_ui_module = package.loaded["review.ui"]

    package.loaded["review.storage"] = {
      load = function()
        return {}
      end,
      save = function() end,
    }
    package.loaded["review.state"] = nil
    package.loaded["review.ui"] = nil

    state = require("review.state")
    ui = require("review.ui")
    review.setup({})
  end)

  after_each(function()
    close_current_float()
    if state and state.get() then
      pcall(ui.close)
    end
    package.loaded["review.storage"] = original_storage_module
    package.loaded["review.state"] = original_state_module
    package.loaded["review.ui"] = original_ui_module
  end)

  it("uses a short title for the local note editor", function()
    state.create("local", "main", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
    })
    state.add_note("lua/review.lua", 2, "draft note body", nil, "new")

    ui.open()
    vim.api.nvim_win_set_cursor(state.get_ui().diff_win, { 3, 0 })
    ui.edit_note_at_cursor()

    local cfg = vim.api.nvim_win_get_config(vim.api.nvim_get_current_win())
    local title = cfg.title and cfg.title[1] and cfg.title[1][1] or cfg.title or ""

    assert.are.equal(" Edit Note ", title)
  end)

  it("uses a short title for the add note float", function()
    state.create("local", "main", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
    })

    ui.open()
    vim.api.nvim_win_set_cursor(state.get_ui().diff_win, { 3, 0 })
    ui.open_note_float()

    local cfg = vim.api.nvim_win_get_config(vim.api.nvim_get_current_win())
    local title = cfg.title and cfg.title[1] and cfg.title[1][1] or cfg.title or ""

    assert.are.equal(" Add Note ", title)
  end)

  it("uses a short title for the add suggestion float", function()
    state.create("local", "main", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
    })

    ui.open()
    vim.api.nvim_win_set_cursor(state.get_ui().diff_win, { 3, 0 })
    ui.open_note_float({ suggestion = true })

    local cfg = vim.api.nvim_win_get_config(vim.api.nvim_get_current_win())
    local title = cfg.title and cfg.title[1] and cfg.title[1][1] or cfg.title or ""

    assert.are.equal(" Add Suggestion ", title)
  end)

  it("saves explicit file-level notes", function()
    state.create("local", "main", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
    })

    ui.open_note_float_for_target({ file_path = "lua/review.lua", target_kind = "file" }, {})
    local note_buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(note_buf, 0, -1, false, { "review the whole file" })
    vim.cmd("write")

    local notes = state.get_notes()
    assert.are.equal(1, #notes)
    assert.are.equal("lua/review.lua", notes[1].file_path)
    assert.is_nil(notes[1].line)
    assert.are.equal("file", notes[1].target_kind)
  end)

  it("saves explicit unit and discussion notes", function()
    state.create("local", "main", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
    })

    ui.open_note_float_for_target({ target_kind = "unit" }, {})
    local unit_buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(unit_buf, 0, -1, false, { "unit note" })
    vim.cmd("write")
    close_current_float()

    ui.open_note_float_for_target({ target_kind = "discussion", is_general = true }, {})
    local discussion_buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(discussion_buf, 0, -1, false, { "discussion note" })
    vim.cmd("write")

    local notes = state.get_notes()
    assert.are.equal(2, #notes)
    assert.are.equal("unit", notes[1].target_kind)
    assert.is_nil(notes[1].file_path)
    assert.is_nil(notes[1].line)
    assert.are.equal("discussion", notes[2].target_kind)
    assert.is_true(notes[2].is_general)
    assert.is_nil(notes[2].file_path)
    assert.is_nil(notes[2].line)
  end)
end)

describe("review.ui statusline", function()
  local review = require("review")
  local state
  local ui
  local git
  local original_storage_module
  local original_state_module
  local original_ui_module
  local original_git_module
  local original_branch

  before_each(function()
    original_storage_module = package.loaded["review.storage"]
    original_state_module = package.loaded["review.state"]
    original_ui_module = package.loaded["review.ui"]
    original_git_module = package.loaded["review.git"]

    package.loaded["review.storage"] = {
      load = function()
        return {}
      end,
      save = function() end,
    }
    package.loaded["review.state"] = nil
    package.loaded["review.ui"] = nil
    package.loaded["review.git"] = nil

    state = require("review.state")
    ui = require("review.ui")
    git = require("review.git")
    original_branch = git.current_branch
    git.current_branch = function()
      return "feature/some/extremely/long/branch/name"
    end

    review.setup({})
  end)

  after_each(function()
    if state and state.get() then
      pcall(ui.close)
    end
    if git then
      git.current_branch = original_branch
    end
    package.loaded["review.storage"] = original_storage_module
    package.loaded["review.state"] = original_state_module
    package.loaded["review.ui"] = original_ui_module
    package.loaded["review.git"] = original_git_module
  end)

  it("compacts the diff statusline on narrow windows", function()
    local original_columns = vim.o.columns
    vim.o.columns = 80

    state.create("local", "origin/main-with-a-very-long-name", {
      { path = "lua/very_long_filename_for_bottom_bar_alignment.lua", status = "M", hunks = { sample_hunk(2, 2) } },
    })

    ui.open()

    local statusline = vim.wo[state.get_ui().diff_win].statusline

    assert.is_true(statusline:match("lua/.*%.lua") ~= nil)
    assert.is_true(statusline:match("origi…→feature…%s+scope: all") ~= nil)
    assert.is_true(statusline:match("%%=") ~= nil)
    assert.is_nil(statusline:match("compare:"))

    vim.o.columns = original_columns
  end)

  it("keeps compare identity stable while stack scope changes", function()
    state.create("local", "main", {
      { path = "README.md", status = "M", hunks = { sample_hunk(2, 2) } },
    }, {
      left_ref = "main",
      right_ref = "bugfix/input-validation",
      requested_ref = "main..bugfix/input-validation",
      comparison_key = "git::main::bugfix/input-validation",
    })
    state.set_commits({
      {
        sha = "abc123456789",
        short_sha = "abc1234",
        message = "first commit message that should not take over the bar",
        files = { { path = "README.md", status = "M", hunks = { sample_hunk(2, 2) } } },
      },
    })

    ui.open()
    local before = vim.wo[state.get_ui().diff_win].statusline
    ui.select_commit(1, { scope_mode = "current_commit" })
    local after = vim.wo[state.get_ui().diff_win].statusline

    assert.is_true(before:find("main", 1, true) ~= nil and before:find("bugfix", 1, true) ~= nil)
    assert.is_true(after:find("main", 1, true) ~= nil and after:find("bugfix", 1, true) ~= nil)
    assert.is_true(after:find("scope: abc1234", 1, true) ~= nil)
    assert.is_nil(after:find("first commit message", 1, true))
  end)

  it("shows sync state while a local refresh is loading", function()
    state.create("local", "main", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
    })
    state.set_local_refresh_loading(true)

    ui.open()

    local statusline = vim.wo[state.get_ui().diff_win].statusline
    assert.is_true(statusline:match("sync") ~= nil)
  end)

  it("uses the shared review statusline in the left rail", function()
    local original_global = vim.o.statusline
    vim.o.statusline = "GLOBAL-STATUSLINE"

    state.create("local", "origin/main", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
    })

    ui.open()

    local ui_state = state.get_ui()
    local files_statusline = vim.api.nvim_get_option_value("statusline", { scope = "local", win = ui_state.explorer_win })
    assert.is_true(files_statusline:find("lua/review.lua", 1, true) ~= nil)
    assert.is_nil(files_statusline:find("GLOBAL-STATUSLINE", 1, true))

    vim.o.statusline = original_global
  end)

  it("shares one statusline value across split diff panes", function()
    state.create("local", "origin/main", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
    })

    ui.open()
    ui.toggle_split()

    local ui_state = state.get_ui()
    local files_statusline = vim.api.nvim_get_option_value("statusline", { scope = "local", win = ui_state.explorer_win })
    local old_statusline = vim.api.nvim_get_option_value("statusline", { scope = "local", win = ui_state.diff_win })
    local new_statusline = vim.api.nvim_get_option_value("statusline", { scope = "local", win = ui_state.split_win })

    assert.are.equal(files_statusline, old_statusline)
    assert.are.equal(old_statusline, new_statusline)
    assert.is_true(new_statusline:find("lua/review.lua", 1, true) ~= nil)
  end)
end)

describe("review.ui highlights", function()
  local review = require("review")

  it("keeps modified files distinct from local note/thread accents in colorblind mode", function()
    review.setup({ colorblind = true })

    local status_m = vim.api.nvim_get_hl(0, { name = "ReviewStatusM", link = false })
    local note_sign = vim.api.nvim_get_hl(0, { name = "ReviewNoteSign", link = false })
    local local_group = vim.api.nvim_get_hl(0, { name = "ReviewLocalGroup", link = false })

    assert.is_not_nil(status_m.fg)
    assert.is_not_nil(note_sign.fg)
    assert.is_not_nil(local_group.fg)
    assert.are_not.equal(status_m.fg, note_sign.fg)
    assert.are_equal(note_sign.fg, local_group.fg)
  end)
end)

describe("review.ui diff gutters", function()
  local review = require("review")
  local state
  local ui
  local original_storage_module
  local original_state_module
  local original_ui_module

  before_each(function()
    original_storage_module = package.loaded["review.storage"]
    original_state_module = package.loaded["review.state"]
    original_ui_module = package.loaded["review.ui"]

    package.loaded["review.storage"] = {
      load = function()
        return {}
      end,
      save = function() end,
    }
    package.loaded["review.state"] = nil
    package.loaded["review.ui"] = nil

    state = require("review.state")
    ui = require("review.ui")
    review.setup({})
  end)

  after_each(function()
    if state and state.get() then
      pcall(ui.close)
    end
    package.loaded["review.storage"] = original_storage_module
    package.loaded["review.state"] = original_state_module
    package.loaded["review.ui"] = original_ui_module
  end)

  it("keeps unified gutter separators aligned for 5-digit line numbers", function()
    state.create("local", "main", {
      {
        path = "lua/big.lua",
        status = "M",
        hunks = {
          {
            header = "@@ -9999,2 +9999,2 @@",
            old_start = 9999,
            old_count = 2,
            new_start = 9999,
            new_count = 2,
            lines = {
              { type = "ctx", text = "context", old_lnum = 9999, new_lnum = 9999 },
              { type = "del", text = "before", old_lnum = 10000 },
              { type = "add", text = "after", new_lnum = 10000 },
            },
          },
        },
      },
    })

    ui.open()

    local lines = vim.api.nvim_buf_get_lines(state.get_ui().diff_buf, 0, -1, false)
    local first_sep = lines[1]:find("│")
    local second_sep = lines[1]:find("│", first_sep + 1)

    assert.are.equal(first_sep, lines[2]:find("│"))
    assert.are.equal(second_sep, lines[2]:find("│", first_sep + 1))
    assert.are.equal(first_sep, lines[3]:find("│"))
    assert.are.equal(second_sep, lines[3]:find("│", first_sep + 1))
  end)

  it("keeps split gutter separators aligned for 5-digit line numbers", function()
    state.create("local", "main", {
      {
        path = "lua/big.lua",
        status = "M",
        hunks = {
          {
            header = "@@ -9999,2 +9999,2 @@",
            old_start = 9999,
            old_count = 2,
            new_start = 9999,
            new_count = 2,
            lines = {
              { type = "ctx", text = "context", old_lnum = 9999, new_lnum = 9999 },
              { type = "del", text = "before", old_lnum = 10000 },
              { type = "add", text = "after", new_lnum = 10000 },
            },
          },
        },
      },
    })

    ui.open()
    ui.toggle_split()

    local ui_state = state.get_ui()
    assert.is_true(vim.wo[ui_state.diff_win].winbar:find("[S] Old", 1, true) ~= nil)
    assert.is_true(vim.wo[ui_state.diff_win].winbar:find("[S] unified", 1, true) == nil)
    assert.is_true(vim.wo[ui_state.split_win].winbar:find("New", 1, true) ~= nil)
    assert.is_true(vim.wo[ui_state.split_win].winbar:find("[S] unified", 1, true) == nil)
    assert.is_true(math.abs(vim.api.nvim_win_get_width(ui_state.diff_win) - vim.api.nvim_win_get_width(ui_state.split_win)) <= 1)

    local old_lines = vim.api.nvim_buf_get_lines(state.get_ui().diff_buf, 0, -1, false)
    local new_lines = vim.api.nvim_buf_get_lines(state.get_ui().split_buf, 0, -1, false)
    local old_sep = old_lines[1]:find("│")
    local new_sep = new_lines[1]:find("│")

    assert.are.equal(old_sep, old_lines[2]:find("│"))
    assert.are.equal(new_sep, new_lines[2]:find("│"))
  end)

  it("yanks diff visual selections without gutter line numbers", function()
    state.create("local", "HEAD", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(20000, 20000) } },
    })

    ui.open()

    local ui_state = state.get_ui()
    vim.api.nvim_set_current_win(ui_state.diff_win)
    vim.api.nvim_win_set_cursor(ui_state.diff_win, { 1, 0 })
    vim.fn.setreg('"', "")
    vim.cmd("normal! V")
    send_keys("y")

    local yanked = vim.fn.getreg('"')
    assert.are.equal("context", yanked)
    assert.is_nil(yanked:find("│", 1, true))
    assert.is_nil(yanked:find("19999", 1, true))
  end)

  it("keeps the unified diff cursor out of the gutter", function()
    state.create("local", "HEAD", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(20000, 20000) } },
    })

    ui.open()

    local ui_state = state.get_ui()
    vim.api.nvim_set_current_win(ui_state.diff_win)
    local line = vim.api.nvim_buf_get_lines(ui_state.diff_buf, 0, 1, false)[1]
    local _, gutter_end = line:find("│.│")

    vim.api.nvim_win_set_cursor(ui_state.diff_win, { 1, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = ui_state.diff_buf })

    assert.are.equal(gutter_end, vim.api.nvim_win_get_cursor(ui_state.diff_win)[2])
  end)

  it("starts visual block from the unified diff code column", function()
    state.create("local", "HEAD", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(20000, 20000) } },
    })

    ui.open()

    local ui_state = state.get_ui()
    vim.api.nvim_set_current_win(ui_state.diff_win)
    local line = vim.api.nvim_buf_get_lines(ui_state.diff_buf, 0, 1, false)[1]
    local _, gutter_end = line:find("│.│")

    vim.api.nvim_win_set_cursor(ui_state.diff_win, { 1, 0 })
    send_keys("<C-v>")

    assert.are.equal(gutter_end, vim.api.nvim_win_get_cursor(ui_state.diff_win)[2])
    assert.are.equal("\22", vim.fn.mode())
    send_keys("<Esc>")
  end)

  it("starts visual block from the split diff code column", function()
    state.create("local", "HEAD", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(20000, 20000) } },
    })

    ui.open()
    ui.toggle_split()

    local ui_state = state.get_ui()
    vim.api.nvim_set_current_win(ui_state.split_win)
    local line = vim.api.nvim_buf_get_lines(ui_state.split_buf, 0, 1, false)[1]
    local _, gutter_end = line:find("│.│")

    vim.api.nvim_win_set_cursor(ui_state.split_win, { 1, 0 })
    send_keys("<C-v>")

    assert.are.equal(gutter_end, vim.api.nvim_win_get_cursor(ui_state.split_win)[2])
    assert.are.equal("\22", vim.fn.mode())
    send_keys("<Esc>")
  end)

  it("yanks split diff visual selections without gutter line numbers or signs", function()
    state.create("local", "HEAD", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(20000, 20000) } },
    })

    ui.open()
    ui.toggle_split()

    local ui_state = state.get_ui()
    vim.api.nvim_set_current_win(ui_state.split_win)
    vim.api.nvim_win_set_cursor(ui_state.split_win, { 1, 0 })
    vim.fn.setreg('"', "")
    vim.cmd("normal! V")
    send_keys("y")

    local yanked = vim.fn.getreg('"')
    assert.are.equal("context", yanked)
    assert.is_nil(yanked:find("│", 1, true))
    assert.is_nil(yanked:find("+", 1, true))
    assert.is_nil(yanked:find("19999", 1, true))
  end)

  it("keeps split diff cursors out of the gutter", function()
    state.create("local", "HEAD", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(20000, 20000) } },
    })

    ui.open()
    ui.toggle_split()

    local ui_state = state.get_ui()
    vim.api.nvim_set_current_win(ui_state.split_win)
    local line = vim.api.nvim_buf_get_lines(ui_state.split_buf, 0, 1, false)[1]
    local _, gutter_end = line:find("│.│")

    vim.api.nvim_win_set_cursor(ui_state.split_win, { 1, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = ui_state.split_buf })

    assert.are.equal(gutter_end, vim.api.nvim_win_get_cursor(ui_state.split_win)[2])
  end)
end)
