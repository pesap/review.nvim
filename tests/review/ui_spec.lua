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
    git_status_entry = {
      index_status = section == "staged" and status or " ",
      worktree_status = section == "unstaged" and status or " ",
    },
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
  local original_status_sections
  local original_open_fugitive_status
  local original_is_gitbutler_workspace
  local original_gitbutler_status_lines
  local original_workspace_signature

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
    original_status_sections = git.status_sections
    original_open_fugitive_status = git.open_fugitive_status
    original_is_gitbutler_workspace = git.is_gitbutler_workspace
    original_gitbutler_status_lines = git.gitbutler_status_lines
    original_workspace_signature = git.workspace_signature
    git.current_branch = function()
      return "feature/rail-polish"
    end
    git.status_sections = function()
      return {
        staged = {},
        unstaged = {},
        untracked = {},
      }
    end
    git.open_fugitive_status = function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_win_set_buf(0, buf)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
        "FugitiveStatus",
        "",
        " staged",
        " unstaged",
      })
      return {
        buf = buf,
        win = vim.api.nvim_get_current_win(),
      }, nil
    end
    git.is_gitbutler_workspace = function()
      return false
    end
    git.gitbutler_status_lines = function()
      return nil, "No GitButler project"
    end
    git.workspace_signature = function()
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
      git.status_sections = original_status_sections
      git.open_fugitive_status = original_open_fugitive_status
      git.is_gitbutler_workspace = original_is_gitbutler_workspace
      git.gitbutler_status_lines = original_gitbutler_status_lines
      git.workspace_signature = original_workspace_signature
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

    assert.are.equal(" feature/rail-polish", lines[1])
    assert.are.equal(" against main", lines[2])
    assert.are.equal(" Scope  all", lines[3])
    assert.are.equal(" Files  +3  -3", lines[4])
    assert.are.equal("no", vim.wo[state.get_ui().explorer_win].signcolumn)
    assert.is_true(lines[5]:match("^  M lua/.*….*lua$") ~= nil)
    assert.is_true(vim.wo[state.get_ui().diff_win].winbar:find("lua/review.lua", 1, true) ~= nil)
    assert.is_true(vim.tbl_contains(thread_lines, " Threads"))
    assert.is_true(vim.tbl_contains(thread_lines, "   github/"))
    assert.is_true(vim.tbl_contains(thread_lines, "   local/"))
    assert.is_true(vim.tbl_contains(thread_lines, "     long…lua [1]"))
    assert.is_true(vim.tbl_contains(thread_lines, "     revi…lua [1]"))
  end)

  it("opens an embedded fugitive pane for worktree reviews", function()
    state.create("local", "HEAD", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
    })

    ui.open()

    local ui_state = state.get_ui()
    local lines = vim.api.nvim_buf_get_lines(ui_state.git_buf, 0, -1, false)
    local explorer_lines = vim.api.nvim_buf_get_lines(ui_state.explorer_buf, 0, -1, false)
    local explorer_pos = vim.api.nvim_win_get_position(ui_state.explorer_win)
    local git_pos = vim.api.nvim_win_get_position(ui_state.git_win)
    local diff_pos = vim.api.nvim_win_get_position(ui_state.diff_win)

    assert.is_true(vim.api.nvim_win_is_valid(ui_state.git_win))
    assert.are.equal("FugitiveStatus", lines[1])
    assert.is_false(vim.tbl_contains(explorer_lines, " Staged"))
    assert.is_false(vim.tbl_contains(explorer_lines, " Unstaged"))
    assert.are.equal(explorer_pos[2], git_pos[2])
    assert.is_true(git_pos[1] > explorer_pos[1])
    assert.is_true(diff_pos[2] > git_pos[2])
  end)

  it("replaces fugitive with a read-only GitButler pane for GitButler sessions", function()
    local fugitive_called = false
    git.open_fugitive_status = function()
      fugitive_called = true
      return nil, "should not be called"
    end

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
    local lines = vim.api.nvim_buf_get_lines(ui_state.git_buf, 0, -1, false)
    assert.is_false(fugitive_called)
    assert.are.equal("review-gitbutler", vim.bo[ui_state.git_buf].filetype)
    assert.are.equal(" GitButler workspace", lines[1])
    assert.is_true(vim.tbl_contains(lines, " unassigned"))
    assert.is_true(vim.tbl_contains(lines, " stack s1"))
  end)

  it("focuses the fugitive pane from explorer and diff", function()
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
    assert.are.equal(ui_state.git_win, vim.api.nvim_get_current_win())

    vim.api.nvim_set_current_win(ui_state.diff_win)
    send_keys("g")
    assert.are.equal(ui_state.git_win, vim.api.nvim_get_current_win())
  end)

  it("does not override fugitive keys in the embedded pane", function()
    review.setup({
      keymaps = {
        focus_threads = "t",
      },
    })

    state.create("local", "HEAD", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
    })
    state.add_note("lua/review.lua", 2, "local draft", nil, "new")

    ui.open()

    local ui_state = state.get_ui()
    vim.api.nvim_set_current_win(ui_state.explorer_win)
    send_keys("g")
    assert.are.equal(ui_state.git_win, vim.api.nvim_get_current_win())

    send_keys("t")
    assert.are.equal(ui_state.git_win, vim.api.nvim_get_current_win())
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
    assert.is_true(file_line:match("^  [A-Z?] ") ~= nil)

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

  it("reuses the left-bottom pane when fugitive opens in another window", function()
    git.open_fugitive_status = function()
      vim.cmd("vsplit")
      local win = vim.api.nvim_get_current_win()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_win_set_buf(win, buf)
      vim.bo[buf].filetype = "fugitive"
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "FugitiveStatus" })
      return {
        buf = buf,
        win = win,
      }, nil
    end

    state.create("local", "HEAD", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
    })

    ui.open()

    local ui_state = state.get_ui()
    local explorer_pos = vim.api.nvim_win_get_position(ui_state.explorer_win)
    local git_pos = vim.api.nvim_win_get_position(ui_state.git_win)
    local wins = vim.api.nvim_tabpage_list_wins(ui_state.tab)

    assert.are.equal(explorer_pos[2], git_pos[2])
    assert.is_true(git_pos[1] > explorer_pos[1])
    assert.are.equal(4, #wins)
  end)

  it("skips the fugitive pane for explicit ref reviews", function()
    state.create("local", "main", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
    }, {
      requested_ref = "main",
    })

    ui.open()

    assert.is_nil(state.get_ui().git_win)
    assert.is_nil(state.get_ui().git_buf)
  end)

  it("renders a themed fallback pane when fugitive is unavailable", function()
    git.open_fugitive_status = function()
      return nil, "vim-fugitive is not installed"
    end

    state.create("local", "HEAD", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
    })

    ui.open()

    local lines = vim.api.nvim_buf_get_lines(state.get_ui().git_buf, 0, -1, false)

    assert.is_true(vim.tbl_contains(lines, " review.nvim could not open vim-fugitive."))
    assert.are.equal("no", vim.wo[state.get_ui().git_win].signcolumn)
  end)

  it("renders a GitButler status pane for GitButler worktrees", function()
    git.is_gitbutler_workspace = function()
      return true
    end
    git.gitbutler_status_lines = function()
      return {
        "╭┄fu [fugitive-left-rail-stack]",
        "┊● 1234567 feat(ui): split files and threads in left rail",
        "┊● abcdef0 (upstream)",
      }, nil
    end
    git.open_fugitive_status = function()
      error("fugitive should not open for GitButler workspaces")
    end

    review.setup({
      keymaps = {
        focus_threads = "t",
      },
    })

    state.create("local", "HEAD", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
    })
    state.add_note("lua/review.lua", 2, "local draft", nil, "new")

    ui.open()

    local ui_state = state.get_ui()
    local lines = vim.api.nvim_buf_get_lines(ui_state.git_buf, 0, -1, false)
    assert.are.equal("╭┄fu [fugitive-left-rail-stack]", lines[1])

    vim.api.nvim_set_current_win(ui_state.git_win)
    send_keys("t")
    assert.are.equal(ui_state.threads_win, vim.api.nvim_get_current_win())
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

    local lines = vim.api.nvim_buf_get_lines(state.get_ui().threads_buf, 0, -1, false)
    assert.is_true(vim.tbl_contains(lines, "   github/"))
    assert.is_true(vim.tbl_contains(lines, "   resolved/"))
    assert.is_true(vim.tbl_contains(lines, "     open.lua [1]"))
    assert.is_true(vim.tbl_contains(lines, "     outdated.lua [1]") or vim.tbl_contains(lines, "     outd…lua [1]"))
    assert.is_true(vim.tbl_contains(lines, "     resolved.lua [1]") or vim.tbl_contains(lines, "     reso…lua [1]"))
    assert.is_false(vim.tbl_contains(lines, " Stale"))
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
      if line:match("^     .+%[%d+%]$") then
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
    local thread_marks = vim.api.nvim_buf_get_extmarks(state.get_ui().threads_buf, vim.api.nvim_create_namespace("review_threads"), 0, -1, { details = true })
    local groups = {}
    local add_mark
    local del_mark
    for _, mark in ipairs(marks) do
      groups[mark[4].hl_group] = true
      if mark[2] == 3 and mark[4].hl_group == "ReviewStatusADim" then
        add_mark = mark
      elseif mark[2] == 3 and mark[4].hl_group == "ReviewStatusDDim" then
        del_mark = mark
      end
    end

    assert.is_true(groups.ReviewStatusADim)
    assert.is_true(groups.ReviewStatusDDim)
    assert.are.same({ 8, 10 }, { add_mark[3], add_mark[4].end_col })
    assert.are.same({ 12, 14 }, { del_mark[3], del_mark[4].end_col })
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

    ui.open()

    local lines = vim.api.nvim_buf_get_lines(state.get_ui().explorer_buf, 0, -1, false)
    local thread_lines = vim.api.nvim_buf_get_lines(state.get_ui().threads_buf, 0, -1, false)
    assert.is_true(vim.fn.strdisplaywidth(lines[1]) <= 20)
    assert.is_true(vim.fn.strdisplaywidth(lines[2]) <= 20)
    assert.is_true(lines[1]:match("…") ~= nil)
    assert.is_true(lines[2]:match("…") ~= nil)

    vim.o.columns = original_columns
  end)

  it("uses fibonacci rail widths across common column sizes", function()
    local original_columns = vim.o.columns

    local cases = {
      { columns = 80, expected = 21 },
      { columns = 96, expected = 34 },
      { columns = 170, expected = 55 },
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

  it("shows untracked files only in all scope and exposes stale notes separately", function()
    git.status_sections = function()
      return {
        staged = {},
        unstaged = {},
        untracked = { sample_git_file("lua/scratch.lua", "?", "untracked", 1, 1) },
      }
    end

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

    local lines = vim.api.nvim_buf_get_lines(state.get_ui().explorer_buf, 0, -1, false)
    local thread_lines = vim.api.nvim_buf_get_lines(state.get_ui().threads_buf, 0, -1, false)
    assert.is_true(vim.tbl_contains(lines, " Untracked"))
    local scratch_count = 0
    for _, line in ipairs(lines) do
      if line:match("^  %? lua/.*%.lua$") then
        scratch_count = scratch_count + 1
      end
    end
    assert.are.equal(1, scratch_count)
    assert.is_true(vim.tbl_contains(thread_lines, " Stale"))
    assert.is_true(vim.tbl_contains(thread_lines, "   local/"))
    assert.is_true(
      vim.tbl_contains(thread_lines, "     missing.lua [1]")
        or vim.tbl_contains(thread_lines, "     missing.lua [1] @deadbee")
        or vim.tbl_contains(thread_lines, "     miss…lua [1] @deadbee")
    )

    state.set_commits({
      { sha = "abcdef123456", short_sha = "abcdef1", message = "Polish UI", author = "psanchez", files = {
        { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
      } },
    })
    state.set_scope_mode("current_commit")
    state.set_commit(1)
    ui.refresh()

    lines = vim.api.nvim_buf_get_lines(state.get_ui().explorer_buf, 0, -1, false)
    assert.is_false(vim.tbl_contains(lines, " Untracked"))
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

    local lines = vim.api.nvim_buf_get_lines(state.get_ui().threads_buf, 0, -1, false)
    assert.is_true(vim.tbl_contains(lines, " Stale"))
    assert.is_true(vim.tbl_contains(lines, "   github/"))
    assert.is_true(vim.tbl_contains(lines, "     revi…lua [1]") or vim.tbl_contains(lines, "     review.lua [1]"))
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
    send_keys("T")

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
    assert.are.equal(" lua/review/ui.lua:42", lines[1])
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

  it("keeps help focused on commands and keymaps", function()
    ui.open_help()

    local buf = vim.api.nvim_get_current_buf()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local joined = table.concat(lines, "\n")

    assert.are.equal("Commands", lines[1])
    assert.is_true(joined:match("Commands") ~= nil)
    assert.is_true(joined:match("Explorer") ~= nil)
    assert.is_true(joined:match("Diff") ~= nil)
    assert.is_true(joined:match("Open file or thread") ~= nil)
    assert.is_true(joined:match("Focus Git/Fugitive/GitButler pane") ~= nil)
    assert.is_true(joined:match("Toggle unified/split view") ~= nil)
    assert.is_nil(joined:match("AI Review Focus"))
    assert.is_nil(joined:match("review.nvim"))
  end)

  it("avoids local session resync during refresh when the workspace is unchanged", function()
    local review = require("review")
    local state = require("review.state")
    local git = require("review.git")
    local original_refresh_local_session = review.refresh_local_session
    local original_workspace_signature = git.workspace_signature

    state.create("local", "main", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
    }, {
      requested_ref = nil,
      branch = "feature/rail-polish",
      repo_root = "/tmp/review-ui-spec",
      untracked_files = {},
    })
    git.workspace_signature = function()
      return "## feature/rail-polish"
    end
    state.get().workspace_signature = "## feature/rail-polish"

    ui.open()

    local calls = 0
    review.refresh_local_session = function()
      calls = calls + 1
      return true
    end

    ui.refresh()

    assert.are.equal(0, calls)

    review.refresh_local_session = original_refresh_local_session
    git.workspace_signature = original_workspace_signature
    if state.get() then
      pcall(ui.close)
    end
  end)

  it("wraps long help entries on narrow terminals", function()
    local original_columns = vim.o.columns
    vim.o.columns = 58

    ui.open_help()

    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_get_current_buf()
    local cfg = vim.api.nvim_win_get_config(win)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, 20, false)
    local joined = table.concat(lines, "\n")

    assert.are.equal("  :Review [ref]", lines[2])
    assert.are.equal("      Open review for working tree or ref", lines[3])
    assert.is_true(vim.tbl_contains(lines, "  :ReviewClipboard"))
    assert.is_true(vim.tbl_contains(lines, "      Copy local notes, open threads, and"))
    assert.is_true(vim.tbl_contains(lines, "      discussion"))
    assert.is_true(joined:match(":ReviewRefresh") ~= nil)
    assert.is_true(joined:match("Refresh remote PR/MR comments") ~= nil)

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

    assert.is_true(lines[2]:match("^  ○ .+  body text here$") ~= nil)
    assert.is_true(lines[2]:match("very_long") ~= nil)
    assert.is_true(lines[2]:match("42") ~= nil)
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

    assert.are.equal(" <CR> open  s stage  P publish  y clipboard  Y local", lines[#lines - 1])
    assert.are.equal(" R refresh  C clear local  b url  q close  ? help", lines[#lines])

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
      { sha = "abcdef123456", short_sha = "abcdef1", message = "Polish UI", author = "psanchez", files = {
        { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
      } },
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

    assert.is_true(statusline:match("lua/very_l…nment%.lua") ~= nil)
    assert.is_true(statusline:match("origi…→feature…  •  stack") ~= nil)
    assert.is_true(statusline:match("%%=") ~= nil)
    assert.is_nil(statusline:match("compare:"))

    vim.o.columns = original_columns
  end)

  it("suppresses inherited statuslines in the left rail", function()
    local original_global = vim.o.statusline
    vim.o.statusline = "GLOBAL-STATUSLINE"

    state.create("local", "origin/main", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(2, 2) } },
    })

    ui.open()

    local ui_state = state.get_ui()
    assert.are.equal(" ", vim.api.nvim_get_option_value("statusline", { scope = "local", win = ui_state.explorer_win }))
    if ui_state.git_win and vim.api.nvim_win_is_valid(ui_state.git_win) then
      local git_statusline = vim.api.nvim_get_option_value("statusline", { scope = "local", win = ui_state.git_win })
      assert.is_true(git_statusline == " " or git_statusline == "")
    end

    vim.o.statusline = original_global
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

    local old_lines = vim.api.nvim_buf_get_lines(state.get_ui().diff_buf, 0, -1, false)
    local new_lines = vim.api.nvim_buf_get_lines(state.get_ui().split_buf, 0, -1, false)
    local old_sep = old_lines[1]:find("│")
    local new_sep = new_lines[1]:find("│")

    assert.are.equal(old_sep, old_lines[2]:find("│"))
    assert.are.equal(new_sep, new_lines[2]:find("│"))
  end)
end)
