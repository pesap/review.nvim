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

local function close_current_float()
  local win = vim.api.nvim_get_current_win()
  if win and vim.api.nvim_win_is_valid(win) then
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg and cfg.relative ~= "" then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
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
      return "feature/rail-polish"
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

    assert.are.equal(" feature/rail-polish", lines[1])
    assert.are.equal(" against main", lines[2])
    assert.are.equal(" Files  +3  -3", lines[3])
    assert.are.equal("no", vim.wo[state.get_ui().explorer_win].signcolumn)
    assert.is_true(lines[4]:match("^  M [^…].*….*lua$") ~= nil)
    assert.is_true(vim.tbl_contains(lines, " Threads"))
    assert.is_true(vim.tbl_contains(lines, "   github/"))
    assert.is_true(vim.tbl_contains(lines, "   local/"))
    assert.is_true(vim.tbl_contains(lines, "     long…lua [1]"))
    assert.is_true(vim.tbl_contains(lines, "     revi…lua [1]"))
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

    local lines = vim.api.nvim_buf_get_lines(state.get_ui().explorer_buf, 0, -1, false)
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

    local buf = state.get_ui().explorer_buf
    local ns = vim.api.nvim_create_namespace("review_explorer")
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    local groups = {}
    local add_mark
    local del_mark
    for _, mark in ipairs(marks) do
      groups[mark[4].hl_group] = true
      if mark[2] == 2 and mark[4].hl_group == "ReviewStatusADim" then
        add_mark = mark
      elseif mark[2] == 2 and mark[4].hl_group == "ReviewStatusDDim" then
        del_mark = mark
      end
    end

    assert.is_true(groups.ReviewStatusADim)
    assert.is_true(groups.ReviewStatusDDim)
    assert.is_true(groups.ReviewNoteRemote)
    assert.is_true(groups.ReviewNoteSign)
    assert.are.same({ 8, 10 }, { add_mark[3], add_mark[4].end_col })
    assert.are.same({ 12, 14 }, { del_mark[3], del_mark[4].end_col })
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
    assert.is_true(vim.fn.strdisplaywidth(lines[1]) <= 20)
    assert.is_true(vim.fn.strdisplaywidth(lines[2]) <= 20)
    assert.is_true(lines[1]:match("…") ~= nil)
    assert.is_true(lines[2]:match("…") ~= nil)

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
    assert.are.equal(string.rep("─", #lines[3]), lines[3])
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
    assert.is_nil(joined:match("AI Review Focus"))
    assert.is_nil(joined:match("review.nvim"))
  end)

  it("wraps long help entries on narrow terminals", function()
    local original_columns = vim.o.columns
    vim.o.columns = 58

    ui.open_help()

    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_get_current_buf()
    local cfg = vim.api.nvim_win_get_config(win)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, 14, false)

    assert.are.equal("  :Review [ref]", lines[2])
    assert.are.equal("      Open review for working tree or ref", lines[3])
    assert.are.equal("  :ReviewRefresh", lines[9])
    assert.are.equal("      Refresh remote PR/MR comments", lines[10])

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

    assert.is_true(lines[2]:match("^  ○ very_long_file…gnment%.lua:42  body text here$") ~= nil)
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

    assert.are.equal(" <CR> open  s stage  P publish  y clipboard", lines[#lines - 1])
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
