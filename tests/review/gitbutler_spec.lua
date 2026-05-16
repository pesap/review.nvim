local gitbutler = require("review.gitbutler")
local git = require("review.git")

describe("gitbutler adapter", function()
  local original_executable
  local original_branch
  local original_root
  local original_parse_remote

  local status_json = vim.fn.json_encode({
    unassignedChanges = {
      { cliId = "aa", filePath = "scratch.lua", changeType = "added" },
    },
    stacks = {
      {
        cliId = "s1",
        assignedChanges = {
          { cliId = "st", filePath = "lua/staged.lua", changeType = "modified" },
        },
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
          {
            cliId = "br2",
            name = "feature/other",
            branchStatus = "completelyUnpushed",
            reviewId = vim.NIL,
            commits = {
              {
                commitId = "abcdef1234567890",
                message = "feat: other",
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

  local stack_diff_json = vim.fn.json_encode({
    changes = {
      {
        path = "lua/staged.lua",
        status = "modified",
        diff = {
          type = "patch",
          hunks = {
            {
              oldStart = 2,
              oldLines = 1,
              newStart = 2,
              newLines = 1,
              diff = "@@ -2,1 +2,1 @@\n-before\n+staged\n",
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
      {
        path = "scratch.lua",
        status = "modified",
        diff = {
          type = "patch",
          hunks = {
            {
              oldStart = 3,
              oldLines = 1,
              newStart = 3,
              newLines = 1,
              diff = "@@ -3,1 +3,1 @@\n-old scratch\n+new scratch\n",
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
    original_parse_remote = git.parse_remote

    vim.fn.executable = function(name)
      return name == "but" and 1 or original_executable(name)
    end
    git.current_branch = function()
      return "gitbutler/workspace"
    end
    git.root = function()
      return "/repo"
    end
    git.parse_remote = function()
      return { forge = "github", owner = "pesap", repo = "review.nvim" }
    end
    gitbutler._set_runner(function(cmd)
      local joined = table.concat(cmd, " ")
      if joined == "but -j status" then
        return status_json, 0
      end
      if joined == "but -j diff br" then
        return branch_diff_json, 0
      end
      if joined == "but -j diff br2" then
        return branch_diff_json, 0
      end
      if joined == "but -j diff s1" then
        return stack_diff_json, 0
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
    git.parse_remote = original_parse_remote
    gitbutler.invalidate_cache()
  end)

  it("detects an active GitButler workspace", function()
    assert.is_true(gitbutler.is_workspace())
  end)

  it("builds review files and branch/unassigned scopes", function()
    local review_data = assert(gitbutler.workspace_review())
    assert.are.equal(4, #review_data.files)
    assert.are.equal(3, #review_data.commits)

    local unassigned = review_data.commits[1]
    assert.are.equal("unassigned", unassigned.gitbutler.kind)
    assert.is_true(unassigned.gitbutler.unpublished)
    assert.are.equal("scratch.lua", unassigned.files[1].path)
    assert.are.equal("A", unassigned.files[1].status)
    assert.are.equal(2, #unassigned.files[1].hunks)

    local branch_scope = review_data.commits[2]
    assert.are.equal("feature/gb", branch_scope.gitbutler.branch_name)
    assert.is_true(branch_scope.gitbutler.unpublished)
    assert.are.equal("lua/review.lua", branch_scope.files[1].path)
    assert.are.equal("del", branch_scope.files[1].hunks[1].lines[1].type)
    assert.are.equal("add", branch_scope.files[1].hunks[1].lines[2].type)

    local duplicate_branch_scope = review_data.commits[3]
    assert.are.equal("feature/other", duplicate_branch_scope.gitbutler.branch_name)
    assert.are.equal("lua/review.lua", duplicate_branch_scope.files[1].path)
    assert.are.equal("lua/staged.lua", duplicate_branch_scope.files[2].path)
    assert.is_true(duplicate_branch_scope.files[2].gitbutler.assigned)
  end)

  it("builds review files asynchronously", function()
    local done
    gitbutler.workspace_review_async(function(review_data, err)
      done = { review_data = review_data, err = err }
    end)

    assert.is_nil(done.err)
    assert.are.equal(4, #done.review_data.files)
    assert.are.equal(3, #done.review_data.commits)
    assert.are.equal("unassigned changes", done.review_data.commits[1].message)
    assert.are.equal("feature/gb", done.review_data.commits[2].gitbutler.branch_name)
  end)

  it("rebuilds scopes when a GitButler branch disappears mid-review", function()
    local deleted_branch_status = vim.fn.json_encode({
      unassignedChanges = {},
      stacks = {
        {
          cliId = "s1",
          branches = {
            {
              cliId = "br2",
              name = "feature/other",
              branchStatus = "fullyPushed",
              reviewId = 44,
              commits = {
                {
                  commitId = "abcdef1234567890",
                  message = "feat: other",
                  authorName = "pesap",
                },
              },
            },
          },
        },
      },
      mergeBase = { commitId = "abcdef1234567890" },
    })

    gitbutler._set_runner(function(cmd)
      local joined = table.concat(cmd, " ")
      if joined == "but -j status" then
        return deleted_branch_status, 0
      end
      if joined == "but -j diff br2" then
        return branch_diff_json, 0
      end
      if joined == "but -j diff" then
        return vim.fn.json_encode({ changes = {} }), 0
      end
      return "unexpected command: " .. joined, 1
    end)

    local review_data = assert(gitbutler.workspace_review())

    assert.are.equal(1, #review_data.commits)
    assert.are.equal("feature/other", review_data.commits[1].gitbutler.branch_name)
    assert.are.equal(44, review_data.commits[1].gitbutler.review_id)
    assert.are.equal("lua/review.lua", review_data.files[1].path)
  end)

  it("reassigns stack-level changes when GitButler branch order changes", function()
    local reordered_status = vim.fn.json_encode({
      unassignedChanges = {},
      stacks = {
        {
          cliId = "s1",
          assignedChanges = {
            { cliId = "st", filePath = "lua/staged.lua", changeType = "modified" },
          },
          branches = {
            {
              cliId = "br2",
              name = "feature/other",
              branchStatus = "fullyPushed",
              reviewId = 45,
              commits = {
                {
                  commitId = "abcdef1234567890",
                  message = "feat: other",
                  authorName = "pesap",
                },
              },
            },
            {
              cliId = "br",
              name = "feature/gb",
              branchStatus = "fullyPushed",
              reviewId = 46,
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
    })

    gitbutler._set_runner(function(cmd)
      local joined = table.concat(cmd, " ")
      if joined == "but -j status" then
        return reordered_status, 0
      end
      if joined == "but -j diff br" or joined == "but -j diff br2" then
        return branch_diff_json, 0
      end
      if joined == "but -j diff s1" then
        return stack_diff_json, 0
      end
      if joined == "but -j diff" then
        return vim.fn.json_encode({ changes = {} }), 0
      end
      return "unexpected command: " .. joined, 1
    end)

    local review_data = assert(gitbutler.workspace_review())

    assert.are.equal("feature/other", review_data.commits[1].gitbutler.branch_name)
    assert.are.equal("feature/gb", review_data.commits[2].gitbutler.branch_name)
    assert.are.equal("lua/staged.lua", review_data.commits[2].files[2].path)
    assert.is_true(review_data.commits[2].files[2].gitbutler.assigned)
  end)

  it("resolves GitButler review targets from review IDs and branch PR lookup", function()
    assert.are.equal(17, gitbutler._parse_review_id("(#17)"))

    local info = assert(gitbutler.resolve_review_target({
      kind = "branch",
      branch_name = "feature/gb",
      review_id = "(#17)",
    }))
    assert.are.equal(17, info.pr_number)
    assert.are.equal("feature/gb", info.branch_name)

    gitbutler._set_runner(function(cmd)
      local joined = table.concat(cmd, " ")
      if joined == "gh pr list --state open --head feature/lookup --json number,headRefName,baseRefName" then
        return vim.fn.json_encode({ { number = 23, headRefName = "feature/lookup", baseRefName = "main" } }), 0
      end
      return "unexpected command: " .. joined, 1
    end)

    local looked_up = assert(gitbutler.resolve_review_target({
      kind = "branch",
      branch_name = "feature/lookup",
    }))
    assert.are.equal(23, looked_up.pr_number)
  end)

  it("blocks GitButler review target resolution without an open PR", function()
    local info, err = gitbutler.resolve_review_target({ kind = "unassigned" })
    assert.is_nil(info)
    assert.is_true(err:find("unassigned", 1, true) ~= nil)

    gitbutler._set_runner(function(cmd)
      local joined = table.concat(cmd, " ")
      if joined == "gh pr list --state open --head feature/no-pr --json number,headRefName,baseRefName" then
        return vim.fn.json_encode({}), 0
      end
      return "unexpected command: " .. joined, 1
    end)

    info, err = gitbutler.resolve_review_target({ kind = "branch", branch_name = "feature/no-pr" })
    assert.is_nil(info)
    assert.is_true(err:find("no open PR/MR", 1, true) ~= nil)
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

    assert.are.equal("?", review_data.commits[2].files[1].status)
  end)
end)
