describe("review.handoff", function()
  local handoff
  local original_handoff_module
  local original_state_module
  local original_git_module

  before_each(function()
    original_handoff_module = package.loaded["review.handoff"]
    original_state_module = package.loaded["review.state"]
    original_git_module = package.loaded["review.git"]

    package.loaded["review.handoff"] = nil
    package.loaded["review.state"] = {
      get = function()
        return {
          base_ref = "main",
          merge_base_ref = "merge-base-sha",
          branch = "feature/handoff",
          files = {
            {
              path = "lua/review.lua",
              hunks = {
                {
                  header = "@@ -1,1 +1,1 @@",
                  old_start = 1,
                  old_count = 1,
                  new_start = 1,
                  new_count = 1,
                  lines = {
                    { type = "del", text = "old" },
                    { type = "add", text = "new" },
                  },
                },
              },
            },
          },
          notes = {
            {
              id = 1,
              file_path = "lua/review.lua",
              line = 1,
              side = "new",
              status = "draft",
              note_type = "comment",
              body = "Fix this",
              blame_context = "abc12345 reviewer old line",
            },
          },
        }
      end,
      get_notes = function()
        return {
          {
            id = 1,
            file_path = "lua/review.lua",
            line = 1,
            side = "new",
            status = "draft",
            note_type = "comment",
            body = "Fix this",
            blame_context = "abc12345 reviewer old line",
          },
        }
      end,
      note_is_stale = function()
        return false
      end,
    }
    package.loaded["review.git"] = {
      current_branch = function()
        return "feature/handoff"
      end,
    }

    handoff = require("review.handoff")
  end)

  after_each(function()
    package.loaded["review.handoff"] = original_handoff_module
    package.loaded["review.state"] = original_state_module
    package.loaded["review.git"] = original_git_module
  end)

  it("builds enriched handoff content directly from the extracted module", function()
    local content = assert(handoff.export_content())

    assert.is_true(content:find("# Review Notes", 1, true) ~= nil)
    assert.is_true(content:find("- unit: `feature/handoff`", 1, true) ~= nil)
    assert.is_true(content:find("```diff", 1, true) ~= nil)
    assert.is_true(content:find("+new", 1, true) ~= nil)
    assert.is_true(content:find("- blame: abc12345 reviewer old line", 1, true) ~= nil)
  end)

  it("uses the same unit labels for GitButler notes as UI callers", function()
    local label = handoff.note_unit_label({ branch = "workspace" }, {
      gitbutler = {
        kind = "branch",
        branch_name = "agent/fix-cache",
      },
    })

    assert.are.equal("agent/fix-cache", label)
  end)
end)
