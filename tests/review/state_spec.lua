describe("review.state note indexes", function()
  local state
  local git
  local original_state_module
  local original_storage_module
  local original_git_module

  before_each(function()
    original_state_module = package.loaded["review.state"]
    original_storage_module = package.loaded["review.storage"]
    original_git_module = package.loaded["review.git"]

    package.loaded["review.state"] = nil
    package.loaded["review.git"] = nil
    package.loaded["review.storage"] = {
      load = function()
        return {}
      end,
      save = function() end,
    }

    state = require("review.state")
    git = require("review.git")
    git.root = function()
      return "/tmp/review-nvim"
    end
    git.current_branch = function()
      return "feature/state-spec"
    end
    state.create("local", "HEAD", {}, {
      repo_root = "/tmp/review-nvim",
      branch = "feature/state-spec",
      requested_ref = nil,
      untracked_files = {},
    })
  end)

  after_each(function()
    if state then
      state.destroy()
    end
    package.loaded["review.state"] = original_state_module
    package.loaded["review.storage"] = original_storage_module
    package.loaded["review.git"] = original_git_module
  end)

  it("indexes notes by file, id, and location", function()
    state.add_note("lua/review.lua", 12, "first", nil, "new")
    state.add_note("lua/review.lua", 18, "second", nil, "old")
    state.add_note("README.md", 5, "third", nil, "new")

    local file_notes = state.get_notes("lua/review.lua")
    assert.are.equal(2, #file_notes)
    assert.are.equal("first", file_notes[1].body)
    assert.are.equal("second", file_notes[2].body)

    local note, idx = state.find_note_at("lua/review.lua", 18, "old")
    assert.are.equal("second", note.body)
    assert.are.equal(2, idx)

    local by_id, by_id_idx = state.get_note_by_id(file_notes[1].id)
    assert.are.equal("first", by_id.body)
    assert.are.equal(1, by_id_idx)
  end)

  it("rebuilds indexes after note removal", function()
    state.add_note("lua/review.lua", 12, "first", nil, "new")
    state.add_note("lua/review.lua", 18, "second", nil, "old")

    state.remove_note(1)

    local missing = state.find_note_at("lua/review.lua", 12, "new")
    assert.is_nil(missing)

    local note, idx = state.find_note_at("lua/review.lua", 18, "old")
    assert.are.equal("second", note.body)
    assert.are.equal(1, idx)
    assert.are.equal(1, #state.get_notes("lua/review.lua"))
  end)

  it("clears all local notes while preserving remote comments", function()
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

    assert.are.equal(2, state.local_note_count())

    local cleared = state.clear_local_notes()
    assert.are.equal(2, cleared)
    assert.are.equal(0, state.local_note_count())
    assert.are.equal(1, #state.get_notes())
    assert.are.equal("remote", state.get_notes()[1].status)
  end)

  it("stamps local notes with commit metadata in commit scope", function()
    state.create("local", "main", {
      { path = "lua/review.lua", status = "M", hunks = {} },
    }, {
      repo_root = "/tmp/review-nvim",
      branch = "feature/state-spec",
      requested_ref = nil,
      untracked_files = {},
    })
    state.set_commits({
      { sha = "abcdef123456", short_sha = "abcdef1", message = "Polish UI", author = "psanchez", files = {
        { path = "lua/review.lua", status = "M", hunks = {} },
      } },
    })
    state.set_scope_mode("current_commit")
    state.set_commit(1)

    state.add_note("lua/review.lua", 12, "commit scoped", nil, "new")

    local note = state.get_notes("lua/review.lua")[1]
    assert.are.equal("abcdef123456", note.commit_sha)
    assert.are.equal("abcdef1", note.commit_short_sha)
  end)

  it("filters scoped notes by commit and keeps stale notes separate", function()
    state.create("local", "main", {
      { path = "lua/review.lua", status = "M", hunks = {} },
    }, {
      repo_root = "/tmp/review-nvim",
      branch = "feature/state-spec",
      requested_ref = nil,
      untracked_files = {},
    })
    state.set_commits({
      { sha = "abcdef123456", short_sha = "abcdef1", message = "Polish UI", author = "psanchez", files = {
        { path = "lua/review.lua", status = "M", hunks = {} },
      } },
    })
    state.set_scope_mode("current_commit")
    state.set_commit(1)

    state.add_note("lua/review.lua", 12, "commit scoped", nil, "new")
    state.set_scope_mode("all")
    state.add_note("lua/missing.lua", 3, "stale", nil, "new")
    local stale = state.get_notes("lua/missing.lua")[1]
    stale.commit_sha = "deadbeef"
    stale.commit_short_sha = "deadbee"

    state.set_scope_mode("current_commit")
    local scoped, stale_notes = state.scoped_notes()

    assert.are.equal(1, #scoped)
    assert.are.equal("commit scoped", scoped[1].body)
    assert.are.equal(1, #stale_notes)
    assert.are.equal("stale", stale_notes[1].body)
  end)

  it("marks remote threads stale when the review context is outdated", function()
    state.create("local", "main", {
      { path = "lua/review.lua", status = "M", hunks = {} },
    }, {
      repo_root = "/tmp/review-nvim",
      branch = "feature/state-spec",
      requested_ref = nil,
      untracked_files = {},
    })
    state.load_remote_comments({
      {
        file_path = "lua/review.lua",
        line = 12,
        side = "new",
        replies = {
          { body = "remote", author = "octocat" },
        },
        resolved = false,
      },
    })
    state.set_remote_context_stale("PR is closed")

    local scoped, stale_notes = state.scoped_notes()

    assert.are.equal(0, #scoped)
    assert.are.equal(1, #stale_notes)
    assert.are.equal("remote", stale_notes[1].status)
  end)

  it("keeps outdated unresolved remote threads visible", function()
    state.create("local", "main", {
      { path = "lua/review.lua", status = "M", hunks = {} },
    }, {
      repo_root = "/tmp/review-nvim",
      branch = "feature/state-spec",
      requested_ref = nil,
      untracked_files = {},
    })
    state.load_remote_comments({
      {
        file_path = "lua/review.lua",
        line = 12,
        side = "new",
        replies = {
          { body = "outdated", author = "octocat" },
        },
        resolved = false,
        outdated = true,
      },
    })

    local scoped, stale_notes = state.scoped_notes()

    assert.are.equal(1, #scoped)
    assert.are.equal(0, #stale_notes)
    assert.is_true(scoped[1].outdated)
  end)

  it("keeps remote notes visible across scope changes", function()
    state.create("local", "main", {
      { path = "lua/review.lua", status = "M", hunks = {} },
    }, {
      repo_root = "/tmp/review-nvim",
      branch = "feature/state-spec",
      requested_ref = nil,
      untracked_files = {},
    })
    state.set_commits({
      { sha = "abcdef123456", short_sha = "abcdef1", message = "Polish UI", author = "psanchez", files = {
        { path = "lua/review.lua", status = "M", hunks = {} },
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
          { body = "remote", author = "octocat" },
        },
        resolved = false,
      },
      {
        file_path = nil,
        line = nil,
        side = nil,
        replies = {
          { body = "discussion", author = "octocat" },
        },
        resolved = nil,
        is_general = true,
      },
    })

    local scoped, stale_notes = state.scoped_notes()

    assert.are.equal(2, #scoped)
    assert.are.equal(0, #stale_notes)
  end)

  it("detects when the live git branch no longer matches the session", function()
    assert.is_true(state.session_matches_git())

    git.current_branch = function()
      return "feature/other-branch"
    end

    assert.is_false(state.session_matches_git())
  end)
end)
