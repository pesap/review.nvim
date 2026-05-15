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
  local original_workspace_signature
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
    original_workspace_signature = git.workspace_signature
    git.current_branch = function()
      return "feature/export-notes"
    end
    git.workspace_signature = function()
      return "branch feature/export-notes"
    end
    state.create("local", "main", {})
    state.set_forge_info({ forge = "github", pr_number = 12 })
  end)

  after_each(function()
    vim.fn.confirm = original_confirm
    vim.fn.setreg = original_setreg
    if git then
      git.workspace_signature = original_workspace_signature
    end
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

  it("exports durable handoff packets with ids, units, refs, and hunk context", function()
    state.destroy()
    state.create("local", "main", {
      {
        path = "lua/review.lua",
        status = "M",
        hunks = {
          {
            header = "@@ -10,1 +10,1 @@",
            old_start = 10,
            old_count = 1,
            new_start = 10,
            new_count = 1,
            lines = {
              { type = "del", text = "old", old_lnum = 10 },
              { type = "add", text = "new", new_lnum = 10 },
            },
          },
        },
      },
    }, {
      branch = "feature/export-notes",
      repo_root = "/tmp/review-nvim",
      merge_base_ref = "merge-base-sha",
    })
    state.add_note("lua/review.lua", 10, "Fix this", nil, "new", "comment", {
      blame_context = "abc12345 reviewer old line",
      log_context = "def67890 2026-05-15 reviewer fix context",
      requested_action = "Update the nil guard",
      validation = "make test",
    })

    local content = assert(review.export_content())
    assert.is_true(content:match("- id: #") ~= nil)
    assert.is_true(content:match("- unit: `feature/export%-notes`") ~= nil)
    assert.is_true(content:match("- base: `main`") ~= nil)
    assert.is_true(content:match("- head: `feature/export%-notes`") ~= nil)
    assert.is_true(content:match("- merge%-base: `merge%-base%-sha`") ~= nil)
    assert.is_true(content:match("```diff") ~= nil)
    assert.is_true(content:match("@@ %-10,1 %+10,1 @@") ~= nil)
    assert.is_true(content:match("%+new") ~= nil)
    assert.is_true(content:find("- action: Update the nil guard", 1, true) ~= nil)
    assert.is_true(content:find("- validation: `make test`", 1, true) ~= nil)
    assert.is_true(content:find("- blame: abc12345 reviewer old line", 1, true) ~= nil)
    assert.is_true(content:find("- log: def67890 2026-05-15 reviewer fix context", 1, true) ~= nil)
  end)

  it("filters exports by stale notes and review unit", function()
    state.destroy()
    state.create("local", "main", {
      { path = "lua/a.lua", status = "M", hunks = {} },
      { path = "lua/b.lua", status = "M", hunks = {} },
    }, {
      branch = "feature/export-notes",
      repo_root = "/tmp/review-nvim",
    })
    state.add_note("lua/a.lua", 1, "A", nil, "new")
    state.add_note("lua/b.lua", 1, "B", nil, "new")
    local stale = state.get_notes("lua/b.lua")[1]
    stale.commit_sha = "missing"
    stale.commit_short_sha = "missing"

    local stale_content = assert(review.export_content({ stale_only = true }))
    assert.is_true(stale_content:match("B") ~= nil)
    assert.is_nil(stale_content:match("A"))

    local unit_content = assert(review.export_content({ unit = "feature/export-notes" }))
    assert.is_true(unit_content:match("A") ~= nil)
  end)

  it("excludes resolved local notes from clipboard queue by default", function()
    state.add_note("lua/review.lua", 12, "done", nil, "new")
    local note = state.get_notes("lua/review.lua")[1]
    state.toggle_resolved(note.id)

    local content = assert(review.export_content({ clipboard = true }))
    assert.is_nil(content:match("done"))
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

describe("review note targets", function()
  local review
  local original_review_module

  before_each(function()
    original_review_module = package.loaded["review"]
    package.loaded["review"] = nil
    review = require("review")
    review.setup({})
  end)

  after_each(function()
    package.loaded["review"] = original_review_module
  end)

  it("parses path:line[:side] notation", function()
    local target, err = review.resolve_note_target({ "README.md:33:old" })

    assert.is_nil(err)
    assert.are.same({
      file_path = "README.md",
      line = 33,
      side = "old",
      target_kind = "line",
    }, target)
  end)

  it("parses positional path line side arguments", function()
    local target, err = review.resolve_note_target({ "lua/review.lua", "21", "new" })

    assert.is_nil(err)
    assert.are.same({
      file_path = "lua/review.lua",
      line = 21,
      side = "new",
      target_kind = "line",
    }, target)
  end)

  it("parses windows-style path targets by matching from the end", function()
    local target, err = review.resolve_note_target({ [[C:\work\review.lua:33:old]] })

    assert.is_nil(err)
    assert.are.same({
      file_path = [[C:\work\review.lua]],
      line = 33,
      side = "old",
      target_kind = "line",
    }, target)
  end)

  it("parses file-level targets", function()
    local target, err = review.resolve_note_target({ "file", "lua/review.lua" })

    assert.is_nil(err)
    assert.are.same({
      file_path = "lua/review.lua",
      target_kind = "file",
    }, target)
  end)

  it("treats a bare path as a file-level target", function()
    local target, err = review.resolve_note_target({ "lua/review.lua" })

    assert.is_nil(err)
    assert.are.same({
      file_path = "lua/review.lua",
      target_kind = "file",
    }, target)
  end)

  it("parses unit and discussion targets", function()
    local unit, unit_err = review.resolve_note_target({ "unit" })
    local discussion, discussion_err = review.resolve_note_target({ "discussion" })

    assert.is_nil(unit_err)
    assert.are.same({
      target_kind = "unit",
    }, unit)
    assert.is_nil(discussion_err)
    assert.are.same({
      target_kind = "discussion",
      is_general = true,
    }, discussion)
  end)
end)

describe("review open session metadata", function()
  local review
  local state
  local original_review_module
  local original_state_module
  local original_git_module
  local original_ui_module
  local original_forge_module
  local original_storage_module

  before_each(function()
    original_review_module = package.loaded["review"]
    original_state_module = package.loaded["review.state"]
    original_git_module = package.loaded["review.git"]
    original_ui_module = package.loaded["review.ui"]
    original_forge_module = package.loaded["review.forge"]
    original_storage_module = package.loaded["review.storage"]

    package.loaded["review"] = nil
    package.loaded["review.state"] = nil
    package.loaded["review.git"] = {
      invalidate_cache = function() end,
      root = function()
        return "/tmp/review-spec"
      end,
      default_branch = function()
        return "main"
      end,
      current_branch = function()
        return "feature/git-rail"
      end,
      current_head = function()
        return "head-sha"
      end,
      merge_base = function()
        return "merge-base-sha"
      end,
      diff = function(ref)
        if ref == "main" then
          return table.concat({
            "diff --git a/lua/review.lua b/lua/review.lua",
            "index 1111111..2222222 100644",
            "--- a/lua/review.lua",
            "+++ b/lua/review.lua",
            "@@ -1 +1 @@",
            "-before",
            "+after",
            "",
          }, "\n")
        end
        return ""
      end,
      untracked_files = function()
        return {}
      end,
      log = function()
        return {}
      end,
    }
    package.loaded["review.ui"] = {
      open = function() end,
      close = function() end,
    }
    package.loaded["review.forge"] = {
      get_cached_detect = function()
        return nil
      end,
      detect_async = function() end,
    }
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
    review.setup({})
  end)

  after_each(function()
    if state and state.get() then
      state.destroy()
    end
    package.loaded["review"] = original_review_module
    package.loaded["review.state"] = original_state_module
    package.loaded["review.git"] = original_git_module
    package.loaded["review.ui"] = original_ui_module
    package.loaded["review.forge"] = original_forge_module
    package.loaded["review.storage"] = original_storage_module
  end)

  it("keeps requested_ref nil for implicit local reviews against the default branch", function()
    local opened = review.open({})

    assert.is_nil(opened)
    assert.are.equal("main", state.get().base_ref)
    assert.is_nil(state.get().requested_ref)
    assert.are.equal("head-sha", state.get().head_ref)
    assert.are.equal("merge-base-sha", state.get().merge_base_ref)
  end)

  it("opens GitButler workspace mode before default-branch diff mode", function()
    local git_module = package.loaded["review.git"]
    local gitbutler = require("review.gitbutler")
    local ui = require("review.ui")
    local original_ui_open = ui.open
    local original_git_root = git_module.root
    local original_default_branch = git_module.default_branch
    local original_parse_remote = git_module.parse_remote
    local original_gitbutler_is_workspace = gitbutler.is_workspace
    local original_workspace_review = gitbutler.workspace_review

    state.destroy()
    git_module.root = function()
      return "/tmp/review-spec"
    end
    git_module.current_branch = function()
      return "gitbutler/workspace"
    end
    git_module.default_branch = function()
      return "main"
    end
    git_module.parse_remote = function()
      return nil
    end
    gitbutler.is_workspace = function()
      return true
    end
    gitbutler.workspace_review = function()
      return {
        files = {
          { path = "lua/gb.lua", status = "M", hunks = {} },
        },
        untracked_files = {},
        commits = {
          {
            sha = "gitbutler-unassigned",
            short_sha = "unassgn",
            message = "unassigned changes",
            files = {},
            gitbutler = { kind = "unassigned" },
          },
        },
        metadata = { mergeBase = { commitId = "base123" } },
      }
    end
    ui.open = function() end

    local ok, err = pcall(function()
      review.open({})

      assert.are.equal("gitbutler", state.get().vcs)
      assert.are.equal("base123", state.get().base_ref)
      assert.are.equal("gitbutler-unassigned", state.get().commits[1].sha)
    end)

    ui.open = original_ui_open
    git_module.root = original_git_root
    git_module.default_branch = original_default_branch
    git_module.parse_remote = original_parse_remote
    gitbutler.is_workspace = original_gitbutler_is_workspace
    gitbutler.workspace_review = original_workspace_review
    assert.is_true(ok, err)
  end)

  it("refreshes a local session in place without changing the requested ref semantics", function()
    local git_module = package.loaded["review.git"]

    state.create("local", "main", {
      { path = "lua/old.lua", status = "M", hunks = {} },
    }, {
      requested_ref = nil,
      branch = "feature/git-rail",
      repo_root = "/tmp/review-spec",
      untracked_files = {},
    })

    git_module.invalidate_cache = function() end
    git_module.root = function()
      return "/tmp/review-spec"
    end
    git_module.current_branch = function()
      return "feature/git-rail"
    end
    git_module.workspace_signature = function()
      return "branch feature/export-notes"
    end
    git_module.diff = function(ref)
      assert.are.equal("main", ref)
      return table.concat({
        "diff --git a/lua/new.lua b/lua/new.lua",
        "index 1111111..2222222 100644",
        "--- a/lua/new.lua",
        "+++ b/lua/new.lua",
        "@@ -1 +1 @@",
        "-before",
        "+after",
        "",
      }, "\n")
    end
    git_module.untracked_files = function()
      return {}
    end
    git_module.log = function(ref)
      assert.are.equal("main", ref)
      return {
        { sha = "abc123456789", short_sha = "abc1234", message = "Refresh commit", author = "psanchez" },
      }
    end

    assert.is_true(review.refresh_local_session())
    assert.are.equal("main", state.get().base_ref)
    assert.is_nil(state.get().requested_ref)
    assert.are.equal("lua/new.lua", state.get().files[1].path)
    assert.are.equal(1, #state.get().commits)
    assert.are.equal("branch feature/export-notes", state.get().workspace_signature)
  end)

  it("refreshes a local session asynchronously with async diff and log calls", function()
    local git_module = package.loaded["review.git"]
    local callbacks = {}

    state.create("local", "main", {
      { path = "lua/old.lua", status = "M", hunks = {} },
    }, {
      requested_ref = nil,
      branch = "feature/git-rail",
      repo_root = "/tmp/review-spec",
      untracked_files = {},
    })

    git_module.invalidate_cache = function() end
    git_module.root = function()
      return "/tmp/review-spec"
    end
    git_module.current_branch = function()
      return "feature/git-rail"
    end
    git_module.workspace_signature = function()
      return "async-signature"
    end
    git_module.untracked_files = function()
      return {}
    end
    git_module.diff_async = function(ref, callback)
      assert.are.equal("main", ref)
      callbacks.diff = callback
    end
    git_module.log_async = function(ref, head_ref, callback)
      assert.are.equal("main", ref)
      assert.is_nil(head_ref)
      callbacks.log = callback
    end

    local done
    review.refresh_local_session_async(nil, function(ok, err)
      done = { ok = ok, err = err }
    end)

    assert.is_true(state.local_refresh_loading())
    assert.is_not_nil(callbacks.diff)
    assert.is_not_nil(callbacks.log)
    callbacks.log({
      { sha = "abc123456789", short_sha = "abc1234", message = "Async commit", author = "psanchez" },
    }, nil)
    assert.is_nil(done)
    callbacks.diff(table.concat({
      "diff --git a/lua/async.lua b/lua/async.lua",
      "index 1111111..2222222 100644",
      "--- a/lua/async.lua",
      "+++ b/lua/async.lua",
      "@@ -1 +1 @@",
      "-before",
      "+after",
      "",
    }, "\n"), nil)

    assert.is_true(done.ok)
    assert.is_nil(done.err)
    assert.is_false(state.local_refresh_loading())
    assert.are.equal("lua/async.lua", state.get().files[1].path)
    assert.are.equal("abc123456789", state.get().commits[1].sha)
    assert.are.equal("async-signature", state.get().workspace_signature)
  end)

  it("refreshes a GitButler session asynchronously", function()
    local git_module = package.loaded["review.git"]
    local gitbutler = require("review.gitbutler")
    local original_workspace_review_async = gitbutler.workspace_review_async
    local callbacks = {}

    state.create("local", "gitbutler/workspace", {
      { path = "lua/old.lua", status = "M", hunks = {} },
    }, {
      vcs = "gitbutler",
      requested_ref = nil,
      branch = "gitbutler/workspace",
      repo_root = "/tmp/review-spec",
      untracked_files = {},
      gitbutler = {},
    })

    git_module.invalidate_cache = function() end
    git_module.root = function()
      return "/tmp/review-spec"
    end
    git_module.current_branch = function()
      return "gitbutler/workspace"
    end
    gitbutler.workspace_review_async = function(callback)
      callbacks.workspace = callback
    end

    local done
    review.refresh_local_session_async(nil, function(ok, err)
      done = { ok = ok, err = err }
    end)

    assert.is_true(state.local_refresh_loading())
    assert.is_not_nil(callbacks.workspace)
    callbacks.workspace({
      files = {
        { path = "lua/gb.lua", status = "M", hunks = {} },
      },
      untracked_files = {},
      commits = {
        {
          sha = "branch-a",
          short_sha = "brancha",
          message = "feature/a",
          files = { { path = "lua/gb.lua", status = "M", hunks = {} } },
          gitbutler = { kind = "branch", branch_name = "feature/a" },
        },
      },
      metadata = { mergeBase = { commitId = "base123" } },
    }, nil)

    gitbutler.workspace_review_async = original_workspace_review_async
    assert.is_true(done.ok)
    assert.is_nil(done.err)
    assert.is_false(state.local_refresh_loading())
    assert.are.equal("lua/gb.lua", state.get().files[1].path)
    assert.are.equal("branch-a", state.get().commits[1].sha)
  end)

  it("ignores superseded local async refresh callbacks", function()
    local git_module = package.loaded["review.git"]
    local requests = {}

    state.create("local", "main", {
      { path = "lua/current.lua", status = "M", hunks = {} },
    }, {
      requested_ref = nil,
      branch = "feature/git-rail",
      repo_root = "/tmp/review-spec",
      untracked_files = {},
    })

    git_module.invalidate_cache = function() end
    git_module.root = function()
      return "/tmp/review-spec"
    end
    git_module.current_branch = function()
      return "feature/git-rail"
    end
    git_module.workspace_signature = function()
      return "latest-signature"
    end
    git_module.untracked_files = function()
      return {}
    end
    git_module.diff_async = function(_, callback)
      local request = requests[#requests]
      request.diff = callback
    end
    git_module.log_async = function(_, _, callback)
      local request = requests[#requests]
      request.log = callback
    end

    local first
    table.insert(requests, {})
    review.refresh_local_session_async(nil, function(ok, err)
      first = { ok = ok, err = err }
    end)
    assert.is_true(state.local_refresh_loading())

    local second
    table.insert(requests, {})
    review.refresh_local_session_async(nil, function(ok, err)
      second = { ok = ok, err = err }
    end)

    requests[1].log({}, nil)
    requests[1].diff("diff --git a/lua/old.lua b/lua/old.lua\n--- a/lua/old.lua\n+++ b/lua/old.lua\n@@ -1 +1 @@\n-a\n+b\n", nil)
    assert.is_false(first.ok)
    assert.are.equal("superseded", first.err)
    assert.are.equal("lua/current.lua", state.get().files[1].path)

    requests[2].log({}, nil)
    requests[2].diff("diff --git a/lua/new.lua b/lua/new.lua\n--- a/lua/new.lua\n+++ b/lua/new.lua\n@@ -1 +1 @@\n-a\n+b\n", nil)
    assert.is_true(second.ok)
    assert.is_false(state.local_refresh_loading())
    assert.are.equal("lua/new.lua", state.get().files[1].path)
  end)

  it("changes the base ref for an active local review in place", function()
    local git_module = package.loaded["review.git"]
    local original_save = package.loaded["review.storage"].save
    local saved_sessions = 0

    state.create("local", "main", {
      { path = "lua/old.lua", status = "M", hunks = {} },
    }, {
      requested_ref = nil,
      branch = "feature/git-rail",
      repo_root = "/tmp/review-spec",
      untracked_files = {},
    })
    state.add_note("lua/old.lua", 1, "keep this note", nil, "new")

    git_module.invalidate_cache = function() end
    git_module.root = function()
      return "/tmp/review-spec"
    end
    git_module.current_branch = function()
      return "feature/git-rail"
    end
    git_module.workspace_signature = function()
      return "changed-base-signature"
    end
    git_module.diff = function(ref)
      assert.are.equal("HEAD~2", ref)
      return table.concat({
        "diff --git a/lua/new-base.lua b/lua/new-base.lua",
        "index 1111111..2222222 100644",
        "--- a/lua/new-base.lua",
        "+++ b/lua/new-base.lua",
        "@@ -1 +1 @@",
        "-before",
        "+after",
        "",
      }, "\n")
    end
    git_module.untracked_files = function()
      return {}
    end
    git_module.log = function(ref)
      assert.are.equal("HEAD~2", ref)
      return {
        { sha = "basechange123", short_sha = "basecha", message = "Changed base commit", author = "psanchez" },
      }
    end
    package.loaded["review.storage"].save = function()
      saved_sessions = saved_sessions + 1
    end

    local ok, err = pcall(function()
      assert.is_true(review.change_base("HEAD~2"))
      assert.are.equal("HEAD~2", state.get().base_ref)
      assert.are.equal("HEAD~2", state.get().requested_ref)
      assert.are.equal("lua/new-base.lua", state.get().files[1].path)
      assert.are.equal("keep this note", state.get_notes()[1].body)
      assert.are.equal("changed-base-signature", state.get().workspace_signature)
      assert.are.equal(1, saved_sessions)
    end)
    package.loaded["review.storage"].save = original_save
    assert.is_true(ok, err)
  end)

  it("rejects base changes for GitButler review sessions", function()
    state.create("local", "gitbutler/workspace", {
      { path = "lua/gb.lua", status = "M", hunks = {} },
    }, {
      vcs = "gitbutler",
      requested_ref = nil,
      branch = "gitbutler/workspace",
      repo_root = "/tmp/review-spec",
      untracked_files = {},
    })

    assert.is_false(review.change_base("HEAD~2"))
    assert.are.equal("gitbutler/workspace", state.get().base_ref)
  end)

  it("marks and compares against a before-fix baseline", function()
    local git_module = package.loaded["review.git"]
    local baseline = "abc123456789abc123456789abc123456789abcd"

    state.create("local", "main", {
      { path = "lua/before.lua", status = "M", hunks = {} },
    }, {
      requested_ref = nil,
      branch = "feature/git-rail",
      repo_root = "/tmp/review-spec",
      untracked_files = {},
    })

    git_module.current_head = function()
      return baseline
    end
    git_module.invalidate_cache = function() end
    git_module.root = function()
      return "/tmp/review-spec"
    end
    git_module.current_branch = function()
      return "feature/git-rail"
    end
    git_module.workspace_signature = function()
      return "after-fix-signature"
    end
    git_module.diff = function(ref)
      assert.are.equal(baseline, ref)
      return table.concat({
        "diff --git a/lua/after.lua b/lua/after.lua",
        "index 1111111..2222222 100644",
        "--- a/lua/after.lua",
        "+++ b/lua/after.lua",
        "@@ -1 +1 @@",
        "-before",
        "+after",
        "",
      }, "\n")
    end
    git_module.untracked_files = function()
      return {}
    end
    git_module.log = function(ref)
      assert.are.equal(baseline, ref)
      return {}
    end

    assert.is_true(review.mark_baseline())
    assert.are.equal(baseline, state.get().review_baseline_ref)
    assert.are.equal(baseline, state.get_ui_prefs().review_baseline_ref)
    assert.are.equal("unchanged", state.review_snapshot_file_state(state.get().files[1]))

    assert.is_true(review.compare_baseline())
    assert.are.equal(baseline, state.get().base_ref)
    assert.are.equal("lua/after.lua", state.get().files[1].path)
    assert.are.equal("new", state.review_snapshot_file_state(state.get().files[1]))
  end)

  it("preserves commit identity and cached commit files across local refreshes", function()
    local git_module = require("review.git")

    state.create("local", "main", {
      { path = "lua/review.lua", status = "M", hunks = {} },
    }, {
      requested_ref = nil,
      branch = "feature/git-rail",
      repo_root = "/tmp/review-spec",
      untracked_files = {},
    })
    state.set_commits({
      {
        sha = "abc123456789",
        short_sha = "abc1234",
        message = "Older commit",
        author = "psanchez",
        files = {
          { path = "lua/kept.lua", status = "M", hunks = {} },
        },
      },
      {
        sha = "def987654321",
        short_sha = "def9876",
        message = "Newer commit",
        author = "psanchez",
      },
    })
    state.set_scope_mode("current_commit")
    state.set_commit(1)

    git_module.invalidate_cache = function() end
    git_module.root = function()
      return "/tmp/review-spec"
    end
    git_module.current_branch = function()
      return "feature/git-rail"
    end
    git_module.workspace_signature = function()
      return "branch feature/git-rail\n M lua/review.lua"
    end
    git_module.diff = function(ref)
      assert.are.equal("main", ref)
      return ""
    end
    git_module.untracked_files = function()
      return {}
    end
    git_module.log = function(ref)
      assert.are.equal("main", ref)
      return {
        { sha = "zzz000000000", short_sha = "zzz0000", message = "Newest commit", author = "psanchez" },
        { sha = "abc123456789", short_sha = "abc1234", message = "Older commit", author = "psanchez" },
      }
    end

    assert.is_true(review.refresh_local_session())
    assert.are.equal(2, state.get().current_commit_idx)
    assert.are.equal("abc123456789", state.get().commits[2].sha)
    assert.are.equal("lua/kept.lua", state.get().commits[2].files[1].path)
  end)

  it("ignores stale remote comment refresh callbacks after a newer refresh starts", function()
    local forge = require("review.forge")
    local ui = require("review.ui")
    local callbacks = {}
    local refreshes = 0

    state.create("local", "main", {
      { path = "lua/review.lua", status = "M", hunks = {} },
    }, {
      requested_ref = nil,
      branch = "feature/git-rail",
      repo_root = "/tmp/review-spec",
      untracked_files = {},
    })
    state.set_forge_info({
      forge = "github",
      owner = "pesap",
      repo = "review.nvim",
      pr_number = 42,
    })

    forge.fetch_comments_async = function(_, callback)
      table.insert(callbacks, callback)
    end
    ui.refresh = function()
      refreshes = refreshes + 1
    end

    review.refresh_comments()
    review.refresh_comments()

    assert.are.equal(2, #callbacks)
    callbacks[1]({
      {
        file_path = "lua/review.lua",
        line = 1,
        side = "new",
        replies = { { body = "old callback", author = "octocat" } },
      },
    }, nil, nil)
    assert.is_true(state.comments_loading())
    assert.are.equal(0, #state.get_notes("lua/review.lua"))

    callbacks[2]({
      {
        file_path = "lua/review.lua",
        line = 2,
        side = "new",
        replies = { { body = "new callback", author = "octocat" } },
      },
    }, nil, nil)

    assert.is_false(state.comments_loading())
    assert.are.equal(1, #state.get_notes("lua/review.lua"))
    assert.are.equal("new callback", state.get_notes("lua/review.lua")[1].body)
    assert.is_true(refreshes >= 3)
  end)
end)
