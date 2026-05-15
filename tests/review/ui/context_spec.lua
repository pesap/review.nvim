local function sample_hunk(old_line, new_line)
  return {
    header = string.format("@@ -%d,1 +%d,1 @@", old_line, new_line),
    old_start = old_line,
    old_count = 1,
    new_start = new_line,
    new_count = 1,
    lines = {
      { type = "del", text = "before", old_lnum = old_line },
      { type = "add", text = "after", new_lnum = new_line },
    },
  }
end

describe("review.ui.context", function()
  local context
  local state
  local original_storage_module
  local original_state_module
  local original_context_module

  before_each(function()
    original_storage_module = package.loaded["review.storage"]
    original_state_module = package.loaded["review.state"]
    original_context_module = package.loaded["review.ui.context"]

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
    package.loaded["review.ui.context"] = nil

    state = require("review.state")
    context = require("review.ui.context")
  end)

  after_each(function()
    package.loaded["review.storage"] = original_storage_module
    package.loaded["review.state"] = original_state_module
    package.loaded["review.ui.context"] = original_context_module
  end)

  it("builds review unit comparison lines with overlap and per-side files", function()
    state.create("local", "main", {
      { path = "lua/shared.lua", status = "M", hunks = { sample_hunk(2, 2) } },
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

    local compare_lines, err, actions = context.compare_lines(1, 2)
    assert.is_nil(err)
    local lines = table.concat(assert(compare_lines), "\n")

    assert.is_true(lines:find("Compare Review Units", 1, true) ~= nil)
    assert.is_true(lines:find("Overlap (1)", 1, true) ~= nil)
    assert.is_true(lines:find("lua/shared.lua  left:M +1 -1  right:M +1 -1", 1, true) ~= nil)
    assert.is_true(lines:find("overlap hunks: left +2-2  right +2-2", 1, true) ~= nil)
    assert.is_true(lines:find("<CR> jump", 1, true) ~= nil)
    assert.is_true(vim.tbl_count(actions) > 0)
    assert.is_true(lines:find("Left Only (1)", 1, true) ~= nil)
    assert.is_true(lines:find("lua/left.lua  A +1 -1", 1, true) ~= nil)
    assert.is_true(lines:find("Right Only (1)", 1, true) ~= nil)
    assert.is_true(lines:find("lua/right.lua  A +1 -1", 1, true) ~= nil)
  end)

  it("labels GitButler review units from branch metadata", function()
    assert.are.equal("feature/gb", context.unit_label({
      sha = "branch-scope",
      short_sha = "branch",
      message = "fallback",
      gitbutler = { kind = "branch", branch_name = "feature/gb" },
    }))
    assert.are.equal("unassigned changes", context.unit_label({
      sha = "unassigned",
      gitbutler = { kind = "unassigned" },
    }))
  end)
end)
