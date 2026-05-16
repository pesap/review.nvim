describe("review.state note indexes", function()
  local state
  local git
  local original_state_module
  local original_storage_module
  local original_git_module

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

  it("keeps independent sessions keyed by tab", function()
    state.create("local", "main", {
      { path = "lua/one.lua", status = "M", hunks = {} },
    }, {
      tab = 101,
      repo_root = "/tmp/review-nvim",
      branch = "feature/one",
    })
    state.add_note("lua/one.lua", 1, "first tab", nil, "new")

    state.create("local", "develop", {
      { path = "lua/two.lua", status = "M", hunks = {} },
    }, {
      tab = 202,
      repo_root = "/tmp/review-nvim",
      branch = "feature/two",
    })
    state.add_note("lua/two.lua", 2, "second tab", nil, "new")

    assert.are.equal("main", state.get(101).base_ref)
    assert.are.equal("develop", state.get(202).base_ref)
    assert.are.equal("second tab", state.get_notes("lua/two.lua")[1].body)

    state.activate(101)
    assert.are.equal("first tab", state.get_notes("lua/one.lua")[1].body)
    assert.is_nil(state.get_notes("lua/two.lua")[1])

    state.destroy(101)
    assert.is_nil(state.get(101))
    assert.is_not_nil(state.get(202))
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

  it("indexes multiple notes at the same location", function()
    state.add_note("lua/review.lua", 12, "first", nil, "new")
    state.add_note("lua/review.lua", 12, "second", nil, "new")

    local entries = state.find_notes_at("lua/review.lua", 12, "new")
    assert.are.equal(2, #entries)
    assert.are.equal("first", entries[1].note.body)
    assert.are.equal("second", entries[2].note.body)

    local note = state.find_note_at("lua/review.lua", 12, "new")
    assert.are.equal("first", note.body)
  end)

  it("tracks file review statuses", function()
    assert.are.equal("unreviewed", state.get_file_review_status("lua/review.lua"))
    state.set_file_review_status("lua/review.lua", "needs-agent")
    assert.are.equal("needs-agent", state.get_file_review_status("lua/review.lua"))
  end)

  it("tracks review unit statuses", function()
    assert.are.equal("unreviewed", state.get_unit_review_status("workspace"))
    state.set_unit_review_status("workspace", "blocked")
    assert.are.equal("blocked", state.get_unit_review_status("workspace"))
  end)

  it("tracks review snapshots for changed-since-baseline files", function()
    state.get().files = {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(12, 12) } },
      { path = "lua/new.lua", status = "A", hunks = { sample_hunk(1, 1) } },
    }

    state.mark_review_snapshot("before")
    assert.are.equal("unchanged", state.review_snapshot_file_state(state.get().files[1]))

    state.get().files = {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(18, 18) } },
      { path = "lua/added.lua", status = "A", hunks = { sample_hunk(1, 1) } },
    }

    assert.are.equal("changed", state.review_snapshot_file_state(state.get().files[1]))
    assert.are.equal("new", state.review_snapshot_file_state(state.get().files[2]))
  end)

  it("tracks local refresh loading state", function()
    assert.is_false(state.local_refresh_loading())
    state.set_local_refresh_loading(true)
    assert.is_true(state.local_refresh_loading())
    state.set_local_refresh_loading(false)
    assert.is_false(state.local_refresh_loading())
  end)

  it("resolves and reopens local notes without deleting them", function()
    state.add_note("lua/review.lua", 12, "first", nil, "new")
    local note = state.get_notes("lua/review.lua")[1]

    state.toggle_resolved(note.id)
    assert.is_true(state.get_notes("lua/review.lua")[1].resolved)

    state.toggle_resolved(note.id)
    assert.is_false(state.get_notes("lua/review.lua")[1].resolved)
    assert.are.equal(1, #state.get_notes("lua/review.lua"))
  end)

  it("stores attached blame and log context on local notes", function()
    state.add_note("lua/review.lua", 12, "draft", nil, "new", "comment", {
      blame_context = "abc12345 reviewer old line",
      log_context = "def67890 2026-05-15 reviewer fix context",
    })

    local note = state.get_notes("lua/review.lua")[1]
    assert.are.equal("abc12345 reviewer old line", note.blame_context)
    assert.are.equal("def67890 2026-05-15 reviewer fix context", note.log_context)
  end)

  it("tags local notes with the active comparison pair", function()
    state.create("local", "v1.0.0", {
      { path = "lua/review.lua", status = "M", hunks = { sample_hunk(10, 10) } },
    }, {
      repo_root = "/tmp/review-nvim",
      branch = "feature/state-spec",
      left_ref = "v1.0.0",
      right_ref = "v1.1.0",
      requested_ref = "v1.0.0..v1.1.0",
      comparison_key = "git::v1.0.0::v1.1.0",
    })

    state.add_note("lua/review.lua", 12, "compare note", nil, "new")

    local note = state.get_notes("lua/review.lua")[1]
    assert.are.equal("git::v1.0.0::v1.1.0", note.comparison_key)
    assert.are.equal("v1.0.0", note.comparison.left_ref)
    assert.are.equal("v1.1.0", note.comparison.right_ref)
  end)

  it("attaches blame and log context to an existing local note", function()
    state.add_note("lua/review.lua", 12, "draft", nil, "new")
    local note = state.get_notes("lua/review.lua")[1]

    assert.is_true(state.attach_context_to_note(note.id, {
      blame_context = "abc12345 reviewer old line",
      log_context = "def67890 2026-05-15 reviewer fix context",
    }))

    local updated = state.get_notes("lua/review.lua")[1]
    assert.are.equal("abc12345 reviewer old line", updated.blame_context)
    assert.are.equal("def67890 2026-05-15 reviewer fix context", updated.log_context)
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

  it("keeps GitButler branch-scoped notes visible when branch commit shas change", function()
    state.create("local", "main", {
      { path = "lua/review.lua", status = "M", hunks = {} },
    }, {
      repo_root = "/tmp/review-nvim",
      branch = "gitbutler/workspace",
      requested_ref = nil,
      untracked_files = {},
      vcs = "gitbutler",
    })
    state.set_commits({
      {
        sha = "oldsha123456",
        short_sha = "oldsha1",
        message = "feature/a",
        author = "psanchez",
        files = { { path = "lua/review.lua", status = "M", hunks = {} } },
        gitbutler = { kind = "branch", branch_name = "feature/a", branch_cli_id = "at" },
      },
    })
    state.set_scope_mode("current_commit")
    state.set_commit(1)

    state.add_note("lua/review.lua", 12, "branch scoped", nil, "new")

    state.set_commits({
      {
        sha = "newsha654321",
        short_sha = "newsha6",
        message = "feature/a",
        author = "psanchez",
        files = { { path = "lua/review.lua", status = "M", hunks = {} } },
        gitbutler = { kind = "branch", branch_name = "feature/a", branch_cli_id = "at" },
      },
    })
    state.set_commit(1)

    local scoped, stale_notes = state.scoped_notes()

    assert.are.equal(1, #scoped)
    assert.are.equal("branch scoped", scoped[1].body)
    assert.are.equal(0, #stale_notes)
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
