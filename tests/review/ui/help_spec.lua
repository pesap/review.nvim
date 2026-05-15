local review = require("review")

describe("review.ui.help", function()
  local help
  local git
  local original_help_module
  local original_git_module
  local original_parse_remote
  local original_executable

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
    original_help_module = package.loaded["review.ui.help"]
    original_git_module = package.loaded["review.git"]
    original_executable = vim.fn.executable

    package.loaded["review.ui.help"] = nil
    help = require("review.ui.help")
    git = require("review.git")
    original_parse_remote = git.parse_remote

    review.setup({})
  end)

  after_each(function()
    close_current_float()
    vim.fn.executable = original_executable
    if git then
      git.parse_remote = original_parse_remote
    end
    package.loaded["review.ui.help"] = original_help_module
    package.loaded["review.git"] = original_git_module
  end)

  it("renders current commands and read-only review keymaps", function()
    git.parse_remote = function()
      return { forge = "github", owner = "pesap", repo = "review.nvim" }
    end
    vim.fn.executable = function(name)
      return name == "git" and 1 or 0
    end

    help.open()

    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false)
    local joined = table.concat(lines, "\n")
    assert.is_true(joined:find(":ReviewChangeBase", 1, true) ~= nil)
    assert.is_true(joined:find("Toggle tree/flat file layout", 1, true) ~= nil)
    assert.is_true(joined:find("Open blame side panel", 1, true) ~= nil)
    assert.is_true(joined:find("Toggle blame between base and head", 1, true) ~= nil)
    assert.is_true(joined:find("Fugitive stage", 1, true) == nil)
  end)

  it("wraps long entries to the help popup width", function()
    local original_columns = vim.o.columns
    vim.o.columns = 58
    git.parse_remote = function()
      return nil
    end
    vim.fn.executable = function(name)
      return name == "git" and 1 or 0
    end

    help.open()

    local cfg = vim.api.nvim_win_get_config(vim.api.nvim_get_current_win())
    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false)
    for _, line in ipairs(lines) do
      assert.is_true(vim.fn.strdisplaywidth(line) <= cfg.width)
    end

    vim.o.columns = original_columns
  end)
end)
