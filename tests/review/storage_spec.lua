describe("review.storage", function()
  local storage
  local original_storage_module
  local original_state_module
  local original_git_module
  local original_stdpath
  local temp_root
  local fake_session

  local function storage_file(root, branch, suffix)
    local key = (root .. "::" .. branch .. suffix):gsub("[^%w%._%-]", "_")
    return temp_root .. "/review/" .. key .. ".json"
  end

  before_each(function()
    original_storage_module = package.loaded["review.storage"]
    original_state_module = package.loaded["review.state"]
    original_git_module = package.loaded["review.git"]
    original_stdpath = vim.fn.stdpath

    temp_root = vim.fn.tempname()
    vim.fn.mkdir(temp_root, "p")

    fake_session = {
      mode = "local",
      base_ref = "main",
      forge_info = { pr_number = 42 },
    }

    package.loaded["review.storage"] = nil
    package.loaded["review.state"] = {
      get = function()
        return fake_session
      end,
    }
    package.loaded["review.git"] = {
      root = function()
        return "/tmp/review-storage"
      end,
      current_branch = function()
        return "feature/storage"
      end,
    }
    vim.fn.stdpath = function(name)
      if name == "data" then
        return temp_root
      end
      return original_stdpath(name)
    end

    storage = require("review.storage")
  end)

  after_each(function()
    vim.fn.stdpath = original_stdpath
    package.loaded["review.storage"] = original_storage_module
    package.loaded["review.state"] = original_state_module
    package.loaded["review.git"] = original_git_module
    if temp_root then
      vim.fn.delete(temp_root, "rf")
    end
  end)

  it("loads old branch-key note storage when the evolved key is absent", function()
    local legacy_path = storage_file("/tmp/review-storage", "feature/storage", "")
    vim.fn.mkdir(vim.fn.fnamemodify(legacy_path, ":h"), "p")
    vim.fn.writefile({
      vim.fn.json_encode({
        {
          id = 7,
          file_path = "lua/review.lua",
          line = 12,
          side = "new",
          status = "draft",
          body = "legacy note",
        },
      }),
    }, legacy_path)

    local notes = storage.load()

    assert.are.equal(1, #notes)
    assert.are.equal("legacy note", notes[1].body)
    assert.is_nil(storage.load_workspace_state())
  end)

  it("loads v2 workspace storage when the head/unit key is absent", function()
    local v2_path = storage_file("/tmp/review-storage", "feature/storage", "::local::main::pr42")
    vim.fn.mkdir(vim.fn.fnamemodify(v2_path, ":h"), "p")
    vim.fn.writefile({
      vim.fn.json_encode({
        version = 2,
        notes = {
          {
            id = 8,
            file_path = "lua/review.lua",
            line = 12,
            side = "new",
            status = "draft",
            body = "v2 note",
          },
        },
        ui_prefs = { file_tree_mode = "flat" },
      }),
    }, v2_path)

    local notes = storage.load()

    assert.are.equal(1, #notes)
    assert.are.equal("v2 note", notes[1].body)
    assert.are.equal("flat", storage.load_workspace_state().ui_prefs.file_tree_mode)
  end)

  it("saves v2 workspace state under the mode/base/pr/head/unit key and keeps a backup", function()
    fake_session.head_ref = "head-sha"
    fake_session.commits = {
      { sha = "aaa111", short_sha = "aaa111" },
      { gitbutler = { kind = "branch", branch_cli_id = "branch-id", branch_name = "feature/storage" } },
    }
    local session = {
      notes = {
        { id = 1, file_path = "lua/local.lua", line = 3, side = "new", status = "draft", body = "local" },
        { id = 2, file_path = "lua/remote.lua", line = 4, side = "new", status = "remote", body = "remote" },
      },
      file_review_status = { ["lua/local.lua"] = "reviewed" },
      unit_review_status = { ["feature/storage"] = "needs-agent" },
      review_snapshot_ref = "before-sha",
      review_snapshot_files = { ["lua/local.lua"] = "snapshot-hash" },
      ui_prefs = { file_tree_mode = "tree" },
    }
    local path =
      storage_file("/tmp/review-storage", "feature/storage", "::local::main::pr42::head::head-sha::units::aaa111,branch-id")

    storage.save(session)
    storage.save(session)

    assert.are.equal(1, vim.fn.filereadable(path))
    assert.are.equal(1, vim.fn.filereadable(path .. ".bak"))

    local data = vim.fn.json_decode(table.concat(vim.fn.readfile(path), "\n"))
    assert.are.equal(2, data.version)
    assert.are.equal(1, #data.notes)
    assert.are.equal("local", data.notes[1].body)
    assert.are.equal("reviewed", data.file_review_status["lua/local.lua"])
    assert.are.equal("needs-agent", data.unit_review_status["feature/storage"])
    assert.are.equal("before-sha", data.review_snapshot_ref)
    assert.are.equal("snapshot-hash", data.review_snapshot_files["lua/local.lua"])
    assert.are.equal("tree", data.ui_prefs.file_tree_mode)

    storage.load()
    local workspace_state = storage.load_workspace_state()
    assert.are.equal("before-sha", workspace_state.review_snapshot_ref)
    assert.are.equal("snapshot-hash", workspace_state.review_snapshot_files["lua/local.lua"])
  end)

  it("hashes multiline workspace identities before using them in file names", function()
    fake_session.head_ref = nil
    fake_session.commits = nil
    fake_session.workspace_signature = table.concat({
      "## gitbutler/workspace",
      " M README.md",
      "?? lua/review/ui.lua",
    }, "\n")

    storage.save({
      notes = {
        { id = 1, file_path = "README.md", line = 1, side = "new", status = "draft", body = "local" },
      },
    })

    local files = vim.fn.glob(temp_root .. "/review/*.json", false, true)
    assert.are.equal(1, #files)
    assert.is_true(files[1]:find("\n", 1, true) == nil)
    assert.is_true(files[1]:find("sha256%-", 1, false) ~= nil)
  end)
end)
