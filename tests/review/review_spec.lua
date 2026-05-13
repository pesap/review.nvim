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

  it("parses windows-style path targets by matching from the end", function()
    local target, err = review.resolve_note_target({ [[C:\work\review.lua:33:old]] })

    assert.is_nil(err)
    assert.are.same({
      file_path = [[C:\work\review.lua]],
      line = 33,
      side = "old",
    }, target)
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
end)
