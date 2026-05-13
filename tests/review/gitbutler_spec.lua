local gitbutler = require("review.gitbutler")
local git = require("review.git")

describe("gitbutler adapter", function()
  local original_executable
  local original_branch
  local original_root

  local status_json = vim.fn.json_encode({
    unassignedChanges = {
      { cliId = "aa", filePath = "scratch.lua", changeType = "added" },
    },
    stacks = {
      {
        cliId = "s1",
        branches = {
          {
            cliId = "br",
            name = "feature/gb",
            branchStatus = "completelyUnpushed",
            reviewId = vim.NIL,
            commits = {
              {
                commitId = "1234567890abcdef",
                message = "feat: gb",
                authorName = "pesap",
              },
            },
          },
        },
      },
    },
    mergeBase = { commitId = "abcdef1234567890" },
    upstreamState = { behind = 2 },
  })

  local branch_diff_json = vim.fn.json_encode({
    changes = {
      {
        path = "lua/review.lua",
        status = "modified",
        diff = {
          type = "patch",
          hunks = {
            {
              oldStart = 1,
              oldLines = 1,
              newStart = 1,
              newLines = 1,
              diff = "@@ -1,1 +1,1 @@\n-old\n+new\n",
            },
          },
        },
      },
    },
  })

  local unassigned_diff_json = vim.fn.json_encode({
    changes = {
      {
        path = "scratch.lua",
        status = "modified",
        diff = {
          type = "patch",
          hunks = {
            {
              oldStart = 0,
              oldLines = 0,
              newStart = 1,
              newLines = 1,
              diff = "@@ -0,0 +1,1 @@\n+scratch\n",
            },
          },
        },
      },
    },
  })

  before_each(function()
    gitbutler.invalidate_cache()
    original_executable = vim.fn.executable
    original_branch = git.current_branch
    original_root = git.root

    vim.fn.executable = function(name)
      return name == "but" and 1 or original_executable(name)
    end
    git.current_branch = function()
      return "gitbutler/workspace"
    end
    git.root = function()
      return "/repo"
    end
    gitbutler._set_runner(function(cmd)
      local joined = table.concat(cmd, " ")
      if joined == "but -j status" then
        return status_json, 0
      end
      if joined == "but -j diff br" then
        return branch_diff_json, 0
      end
      if joined == "but -j diff" then
        return unassigned_diff_json, 0
      end
      return "unexpected command: " .. joined, 1
    end)
  end)

  after_each(function()
    gitbutler._set_runner(nil)
    vim.fn.executable = original_executable
    git.current_branch = original_branch
    git.root = original_root
    gitbutler.invalidate_cache()
  end)

  it("detects an active GitButler workspace", function()
    assert.is_true(gitbutler.is_workspace())
  end)

  it("builds review files and branch/unassigned scopes", function()
    local review_data = assert(gitbutler.workspace_review())
    assert.are.equal(2, #review_data.files)
    assert.are.equal(2, #review_data.commits)

    local branch_scope = review_data.commits[1]
    assert.are.equal("feature/gb", branch_scope.gitbutler.branch_name)
    assert.is_true(branch_scope.gitbutler.unpublished)
    assert.are.equal("lua/review.lua", branch_scope.files[1].path)
    assert.are.equal("del", branch_scope.files[1].hunks[1].lines[1].type)
    assert.are.equal("add", branch_scope.files[1].hunks[1].lines[2].type)

    local unassigned = review_data.commits[2]
    assert.are.equal("unassigned", unassigned.gitbutler.kind)
    assert.is_true(unassigned.gitbutler.unpublished)
    assert.are.equal("scratch.lua", unassigned.files[1].path)
    assert.are.equal("A", unassigned.files[1].status)
  end)

  it("surfaces GitButler diff failures", function()
    gitbutler._set_runner(function(cmd)
      local joined = table.concat(cmd, " ")
      if joined == "but -j status" then
        return status_json, 0
      end
      if joined == "but -j diff br" then
        return "diff failed", 1
      end
      return unassigned_diff_json, 0
    end)

    local review_data, err = gitbutler.workspace_review()

    assert.is_nil(review_data)
    assert.are.equal("diff failed", err)
  end)

  it("uses unknown status for unrecognized GitButler change types", function()
    local diff_json = vim.fn.json_encode({
      changes = {
        { path = "mystery.lua", status = "conflicted", diff = { hunks = {} } },
      },
    })
    gitbutler._set_runner(function(cmd)
      local joined = table.concat(cmd, " ")
      if joined == "but -j status" then
        return status_json, 0
      end
      if joined == "but -j diff br" then
        return diff_json, 0
      end
      return unassigned_diff_json, 0
    end)

    local review_data = assert(gitbutler.workspace_review())

    assert.are.equal("?", review_data.commits[1].files[1].status)
  end)
end)
