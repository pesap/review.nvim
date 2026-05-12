describe("review note export and clearing", function()
  local review
  local state
  local git
  local original_review_module
  local original_state_module
  local original_git_module
  local original_storage_module
  local original_confirm
  local original_setreg
  local copied

  before_each(function()
    original_review_module = package.loaded["review"]
    original_state_module = package.loaded["review.state"]
    original_git_module = package.loaded["review.git"]
    original_storage_module = package.loaded["review.storage"]
    original_confirm = vim.fn.confirm
    original_setreg = vim.fn.setreg
    copied = {}

    package.loaded["review"] = nil
    package.loaded["review.state"] = nil
    package.loaded["review.git"] = nil
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

    review = require("review")
    state = require("review.state")
    git = require("review.git")
    review.setup({})
    git.current_branch = function()
      return "feature/export-notes"
    end
    state.create("local", "main", {})
    state.set_forge_info({ forge = "github", pr_number = 12 })
  end)

  after_each(function()
    vim.fn.confirm = original_confirm
    vim.fn.setreg = original_setreg
    if state then
      state.destroy()
    end
    package.loaded["review"] = original_review_module
    package.loaded["review.state"] = original_state_module
    package.loaded["review.git"] = original_git_module
    package.loaded["review.storage"] = original_storage_module
  end)

  it("builds clipboard export content for local notes, open threads, and discussion only", function()
    state.add_note("lua/review.lua", 12, "Local draft body", nil, "new")
    local local_note = state.get_notes("lua/review.lua")[1]
    state.toggle_staged(local_note.id)
    state.load_remote_comments({
      {
        file_path = "lua/ui.lua",
        line = 4,
        side = "new",
        url = "https://example.com/thread",
        replies = {
          { body = "Remote top-level body", author = "octocat", created_at = "2026-05-11T10:00:00Z" },
          { body = "Follow-up reply", author = "psanchez", created_at = "2026-05-11T11:00:00Z" },
        },
        resolved = false,
      },
      {
        file_path = "lua/resolved.lua",
        line = 8,
        side = "new",
        replies = {
          { body = "Resolved body", author = "octocat", created_at = "2026-05-11T09:00:00Z" },
        },
        resolved = true,
      },
      {
        file_path = nil,
        line = nil,
        side = nil,
        is_general = true,
        replies = {
          { body = "General discussion body", author = "octocat", created_at = "2026-05-11T08:00:00Z" },
        },
        resolved = false,
      },
    })

    local content, err = review.export_content({ clipboard = true })
    assert.is_nil(err)
    assert.is_true(content:match("# Review Queue for github #12") ~= nil)
    assert.is_true(content:match("- branch: `feature/export%-notes`") ~= nil)
    assert.is_true(content:match("## Your Notes") ~= nil)
    assert.is_true(content:match("### lua/review.lua:12 new") ~= nil)
    assert.is_true(content:match("- meta: staged, comment") ~= nil)
    assert.is_true(content:match("Local draft body") ~= nil)
    assert.is_true(content:match("## Open Threads") ~= nil)
    assert.is_true(content:match("- meta: remote, comment, open, by @octocat") ~= nil)
    assert.is_true(content:match("- url: https://example.com/thread") ~= nil)
    assert.is_true(content:match("Replies:") ~= nil)
    assert.is_true(content:match("@psanchez %(2026%-05%-11%)") ~= nil)
    assert.is_true(content:match("## Discussion") ~= nil)
    assert.is_true(content:match("General discussion body") ~= nil)
    assert.is_nil(content:match("Resolved body"))
  end)

  it("copies exported notes to clipboard registers", function()
    state.add_note("lua/review.lua", 12, "Clipboard body", nil, "new")
    vim.fn.setreg = function(register, value)
      copied[register] = value
    end

    review.copy_notes_to_clipboard()

    assert.are.same(copied['"'], copied["+"])
    assert.are.same(copied['"'], copied["*"])
    assert.is_true(copied['"']:match("Clipboard body") ~= nil)
  end)

  it("copies only local notes to clipboard registers", function()
    state.add_note("lua/review.lua", 12, "Local only body", nil, "new")
    state.load_remote_comments({
      {
        file_path = "lua/ui.lua",
        line = 4,
        side = "new",
        replies = {
          { body = "Remote top-level body", author = "octocat" },
        },
        resolved = false,
      },
    })
    vim.fn.setreg = function(register, value)
      copied[register] = value
    end

    review.copy_local_notes_to_clipboard()

    assert.are.same(copied['"'], copied["+"])
    assert.are.same(copied['"'], copied["*"])
    assert.is_true(copied['"']:match("Local only body") ~= nil)
    assert.is_true(copied['"']:match("## Your Notes") ~= nil)
    assert.is_nil(copied['"']:match("Open Threads"))
    assert.is_nil(copied['"']:match("Remote top%-level body"))
  end)

  it("requires confirmation before clearing local notes", function()
    state.add_note("lua/review.lua", 12, "draft", nil, "new")
    state.add_note("lua/review.lua", 18, "staged", nil, "new")
    local staged = state.get_notes("lua/review.lua")[2]
    state.toggle_staged(staged.id)
    state.load_remote_comments({
      {
        file_path = "lua/ui.lua",
        line = 4,
        side = "new",
        replies = {
          { body = "remote", author = "octocat" },
        },
        resolved = false,
      },
    })

    vim.fn.confirm = function()
      return 2
    end
    review.clear_local_notes()
    assert.are.equal(3, #state.get_notes())

    vim.fn.confirm = function()
      return 1
    end
    review.clear_local_notes()
    assert.are.equal(1, #state.get_notes())
    assert.are.equal("remote", state.get_notes()[1].status)
  end)
end)
