local git = require("review.git")
local hunk = require("review.hunk")
local review = require("review")

describe("hunk integration", function()
  local original_root
  local original_executable
  local original_system

  before_each(function()
    original_root = git.root
    original_executable = vim.fn.executable
    original_system = vim.fn.system

    git.root = function()
      return "/tmp/review-nvim"
    end

    vim.fn.executable = function(bin)
      if bin == "hunk" then
        return 1
      end
      return original_executable(bin)
    end

    review.setup({})
  end)

  after_each(function()
    git.root = original_root
    vim.fn.executable = original_executable
    vim.fn.system = original_system
  end)

  it("extracts a new-side target from hunk context", function()
    local target, err = hunk.context_target({
      focus = {
        filePath = "lua/review.lua",
        newLine = 42,
      },
    })

    assert.is_nil(err)
    assert.are.same({
      file_path = "lua/review.lua",
      line = 42,
      side = "new",
    }, target)
  end)

  it("extracts an old-side target from hunk context", function()
    local target, err = hunk.context_target({
      location = {
        path = "README.md",
        oldLine = 19,
      },
    })

    assert.is_nil(err)
    assert.are.same({
      file_path = "README.md",
      line = 19,
      side = "old",
    }, target)
  end)

  it("extracts a target from the real selectedFile/selectedHunk context shape", function()
    local target, err = hunk.context_target({
      selectedFile = {
        path = "README.md",
      },
      selectedHunk = {
        oldRange = { 14, 19 },
        newRange = { 14, 20 },
      },
    })

    assert.is_nil(err)
    assert.are.same({
      file_path = "README.md",
      line = 14,
      side = "new",
    }, target)
  end)

  it("syncs review notes into the active hunk session", function()
    local calls = {}

    vim.fn.system = function(cmd, input)
      table.insert(calls, {
        cmd = vim.deepcopy(cmd),
        input = input,
      })
      if cmd[3] == "get" then
        return { code = 0, stdout = "{}" }
      end
      return { code = 0, stdout = "" }
    end

    local ok, err = hunk.sync_comments({
      {
        file_path = "README.md",
        line = 12,
        side = "new",
        body = "Tighten this wording\nExplain why this matters.",
        author = "octocat",
      },
      {
        file_path = "lua/review.lua",
        line = 8,
        side = "old",
        body = "Remove this branch",
      },
      {
        body = "general comment without location",
      },
    })

    assert.is_true(ok)
    assert.is_nil(err)
    assert.are.equal(3, #calls)
    assert.are.same({
      "hunk",
      "session",
      "get",
      "--json",
      "--repo",
      "/tmp/review-nvim",
    }, calls[1].cmd)
    assert.are.same({
      "hunk",
      "session",
      "comment",
      "clear",
      "--yes",
      "--repo",
      "/tmp/review-nvim",
    }, calls[2].cmd)
    assert.are.same({
      "hunk",
      "session",
      "comment",
      "apply",
      "--stdin",
      "--repo",
      "/tmp/review-nvim",
    }, calls[3].cmd)

    local payload = vim.fn.json_decode(calls[3].input)
    assert.are.same({
      comments = {
        {
          filePath = "README.md",
          newLine = 12,
          summary = "Tighten this wording",
          rationale = "Explain why this matters.",
          author = "octocat",
        },
        {
          filePath = "lua/review.lua",
          oldLine = 8,
          summary = "Remove this branch",
          author = "review.nvim",
        },
      },
    }, payload)
  end)

  it("skips syncing when no hunk session is active in non-strict mode", function()
    local calls = {}

    vim.fn.system = function(cmd, input)
      table.insert(calls, {
        cmd = vim.deepcopy(cmd),
        input = input,
      })
      return {
        code = 1,
        stdout = "hunk: No active Hunk sessions are registered with the daemon.",
      }
    end

    local ok, err = hunk.sync_comments({
      {
        file_path = "README.md",
        line = 12,
        side = "new",
        body = "Tighten this wording",
      },
    })

    assert.is_true(ok)
    assert.is_nil(err)
    assert.are.equal(1, #calls)
    assert.are.same({
      "hunk",
      "session",
      "get",
      "--json",
      "--repo",
      "/tmp/review-nvim",
    }, calls[1].cmd)
  end)
end)

describe("review note targets", function()
  before_each(function()
    review.setup({})
  end)

  it("parses path:line[:side] notation", function()
    local target, err = review.resolve_note_target({ "README.md:33:old" })

    assert.is_nil(err)
    assert.are.same({
      file_path = "README.md",
      line = 33,
      side = "old",
    }, target)
  end)

  it("parses positional path line side arguments", function()
    local target, err = review.resolve_note_target({ "lua/review.lua", "21", "new" })

    assert.is_nil(err)
    assert.are.same({
      file_path = "lua/review.lua",
      line = 21,
      side = "new",
    }, target)
  end)
end)
