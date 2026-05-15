local git = require("review.git")
require("review.diff")

describe("parse_remote", function()
  local original_remote_url

  before_each(function()
    original_remote_url = git.remote_url
    -- Ensure config is initialized
    require("review").setup({})
  end)

  after_each(function()
    git.remote_url = original_remote_url
  end)

  -- GitHub URLs
  it("parses GitHub SSH URL", function()
    git.remote_url = function()
      return "git@github.com:owner/repo.git"
    end
    local remote = git.parse_remote()
    assert.are.same({
      forge = "github",
      owner = "owner",
      repo = "repo",
      host = "github.com",
    }, remote)
  end)

  it("parses GitHub SSH URL without .git", function()
    git.remote_url = function()
      return "git@github.com:owner/repo"
    end
    local remote = git.parse_remote()
    assert.are.same({
      forge = "github",
      owner = "owner",
      repo = "repo",
      host = "github.com",
    }, remote)
  end)

  it("parses GitHub HTTPS URL", function()
    git.remote_url = function()
      return "https://github.com/owner/repo.git"
    end
    local remote = git.parse_remote()
    assert.are.same({
      forge = "github",
      owner = "owner",
      repo = "repo",
      host = "github.com",
    }, remote)
  end)

  it("parses GitHub HTTPS URL without .git", function()
    git.remote_url = function()
      return "https://github.com/owner/repo"
    end
    local remote = git.parse_remote()
    assert.are.same({
      forge = "github",
      owner = "owner",
      repo = "repo",
      host = "github.com",
    }, remote)
  end)

  -- GitLab URLs
  it("parses GitLab SSH URL", function()
    git.remote_url = function()
      return "git@gitlab.com:owner/repo.git"
    end
    local remote = git.parse_remote()
    assert.are.same({
      forge = "gitlab",
      owner = "owner",
      repo = "repo",
      host = "gitlab.com",
    }, remote)
  end)

  it("parses GitLab HTTPS URL", function()
    git.remote_url = function()
      return "https://gitlab.com/owner/repo.git"
    end
    local remote = git.parse_remote()
    assert.are.same({
      forge = "gitlab",
      owner = "owner",
      repo = "repo",
      host = "gitlab.com",
    }, remote)
  end)

  it("parses GitLab subgroup SSH URL", function()
    git.remote_url = function()
      return "git@gitlab.com:group/subgroup/repo.git"
    end
    local remote = git.parse_remote()
    assert.are.same({
      forge = "gitlab",
      owner = "group/subgroup",
      repo = "repo",
      host = "gitlab.com",
    }, remote)
  end)

  it("parses GitLab subgroup HTTPS URL", function()
    git.remote_url = function()
      return "https://gitlab.com/group/subgroup/repo.git"
    end
    local remote = git.parse_remote()
    assert.are.same({
      forge = "gitlab",
      owner = "group/subgroup",
      repo = "repo",
      host = "gitlab.com",
    }, remote)
  end)

  -- Self-hosted GitLab
  it("detects self-hosted GitLab from hostname", function()
    git.remote_url = function()
      return "git@gitlab.company.com:team/project.git"
    end
    local remote = git.parse_remote()
    assert.are.same({
      forge = "gitlab",
      owner = "team",
      repo = "project",
      host = "gitlab.company.com",
    }, remote)
  end)

  -- Config override
  it("uses config provider override for unknown hosts", function()
    require("review").setup({ provider = "gitlab" })
    git.remote_url = function()
      return "git@code.company.com:team/project.git"
    end
    local remote = git.parse_remote()
    assert.are.same({
      forge = "gitlab",
      owner = "team",
      repo = "project",
      host = "code.company.com",
    }, remote)
  end)

  -- Edge cases
  it("returns nil for missing remote", function()
    git.remote_url = function()
      return nil
    end
    assert.is_nil(git.parse_remote())
  end)

  it("returns nil for unknown host without config override", function()
    require("review").setup({})
    git.remote_url = function()
      return "git@code.company.com:team/project.git"
    end
    assert.is_nil(git.parse_remote())
  end)
end)

describe("git repository context", function()
  local tempdir
  local original_cwd

  local function git_ok(args)
    local out = vim.fn.system(args)
    assert.are.equal(0, vim.v.shell_error, out)
    return out
  end

  local function write_file(path, lines)
    local abs_path = tempdir .. "/" .. path
    vim.fn.mkdir(vim.fn.fnamemodify(abs_path, ":h"), "p")
    vim.fn.writefile(lines, abs_path)
  end

  before_each(function()
    original_cwd = vim.fn.getcwd()
    tempdir = vim.fn.tempname()
    vim.fn.mkdir(tempdir, "p")
    vim.cmd("cd " .. vim.fn.fnameescape(tempdir))
    git_ok({ "git", "init" })
    git_ok({ "git", "config", "user.name", "Review Test" })
    git_ok({ "git", "config", "user.email", "review@test.local" })
    git_ok({ "git", "config", "commit.gpgsign", "false" })
    write_file("lua/staged.lua", { "before staged" })
    write_file("lua/unstaged.lua", { "before unstaged" })
    write_file("lua/both.lua", { "before both", "after both" })
    write_file("old/name.lua", { "rename me" })
    git_ok({ "git", "add", "." })
    git_ok({ "git", "commit", "-m", "initial" })
    git.invalidate_cache()
  end)

  after_each(function()
    vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
    vim.fn.delete(tempdir, "rf")
    git.invalidate_cache()
  end)

  it("resolves the current HEAD commit", function()
    local expected = vim.trim(git_ok({ "git", "rev-parse", "HEAD" }))
    assert.are.equal(expected, git.current_head())
  end)

  it("resolves merge-base synchronously and asynchronously", function()
    local expected = vim.trim(git_ok({ "git", "merge-base", "HEAD", "HEAD" }))
    assert.are.equal(expected, git.merge_base("HEAD", "HEAD"))

    local done = false
    git.merge_base_async("HEAD", "HEAD", function(sha, err)
      assert.is_nil(err)
      assert.are.equal(expected, sha)
      done = true
    end)
    vim.wait(1000, function()
      return done
    end)
    assert.is_true(done)
  end)

  it("invalidates cached diffs when the workspace signature changes", function()
    write_file("lua/unstaged.lua", { "first cached diff" })
    local first = git.diff("HEAD")
    assert.is_true(first:find("first cached diff", 1, true) ~= nil)

    write_file("lua/unstaged.lua", { "second cached diff" })
    local second = git.diff("HEAD")

    assert.is_true(second:find("second cached diff", 1, true) ~= nil)
    assert.is_nil(second:find("first cached diff", 1, true))
  end)
end)

describe("async git context", function()
  local original_executable
  local original_system

  before_each(function()
    original_executable = vim.fn.executable
    original_system = vim.system
    git.invalidate_cache()
  end)

  after_each(function()
    vim.fn.executable = original_executable
    vim.system = original_system
    git.invalidate_cache()
  end)

  it("loads file history asynchronously and caches the result", function()
    local calls = 0
    vim.fn.executable = function(cmd)
      return cmd == "git" and 1 or original_executable(cmd)
    end
    vim.system = function(cmd, opts, callback)
      calls = calls + 1
      assert.are.equal("git", cmd[1])
      assert.are.equal("lua/review.lua", cmd[#cmd])
      callback({ code = 0, stdout = "abc1234\t2026-05-15\tps\tmessage\n", stderr = "" })
    end

    local first
    git.file_history_async("lua/review.lua", function(lines, err)
      assert.is_nil(err)
      first = lines
    end)
    vim.wait(100, function()
      return first ~= nil
    end)
    assert.are.equal("abc1234\t2026-05-15\tps\tmessage", first[1])

    local second
    git.file_history_async("lua/review.lua", function(lines)
      second = lines
    end)
    assert.are.equal("abc1234\t2026-05-15\tps\tmessage", second[1])
    assert.are.equal(1, calls)
  end)

  it("loads diffs asynchronously without reusing stale worktree output", function()
    local calls = 0
    vim.fn.executable = function(cmd)
      return cmd == "git" and 1 or original_executable(cmd)
    end
    vim.system = function(cmd, opts, callback)
      calls = calls + 1
      assert.are.same({ "git", "diff", "main" }, cmd)
      callback({ code = 0, stdout = "diff --git a/a b/a\n", stderr = "" })
    end

    local first
    git.diff_async("main", function(diff_text, err)
      assert.is_nil(err)
      first = diff_text
    end)
    vim.wait(100, function()
      return first ~= nil
    end)
    assert.are.equal("diff --git a/a b/a\n", first)

    local second
    git.diff_async("main", function(diff_text)
      second = diff_text
    end)
    vim.wait(100, function()
      return second ~= nil
    end)
    assert.are.equal(first, second)
    assert.are.equal(2, calls)
  end)

  it("coalesces duplicate in-flight async diff requests", function()
    local calls = 0
    local pending
    vim.fn.executable = function(cmd)
      return cmd == "git" and 1 or original_executable(cmd)
    end
    vim.system = function(cmd, opts, callback)
      calls = calls + 1
      assert.are.same({ "git", "diff", "main" }, cmd)
      pending = callback
    end

    local first
    local second
    git.diff_async("main", function(diff_text, err)
      assert.is_nil(err)
      first = diff_text
    end)
    git.diff_async("main", function(diff_text, err)
      assert.is_nil(err)
      second = diff_text
    end)

    assert.are.equal(1, calls)
    assert.is_nil(first)
    assert.is_nil(second)

    pending({ code = 0, stdout = "diff --git a/a b/a\n", stderr = "" })
    vim.wait(100, function()
      return first ~= nil and second ~= nil
    end)

    assert.are.equal("diff --git a/a b/a\n", first)
    assert.are.equal(first, second)
  end)

  it("loads file show asynchronously and coalesces duplicate requests", function()
    local calls = 0
    local pending
    vim.fn.executable = function(cmd)
      return cmd == "git" and 1 or original_executable(cmd)
    end
    vim.system = function(cmd, opts, callback)
      calls = calls + 1
      assert.are.same({ "git", "show", "--format=", "--patch", "abc1234", "--", "lua/review.lua" }, cmd)
      pending = callback
    end

    local first
    local second
    git.file_show_async("abc1234", "lua/review.lua", function(diff_text, err)
      assert.is_nil(err)
      first = diff_text
    end)
    git.file_show_async("abc1234", "lua/review.lua", function(diff_text, err)
      assert.is_nil(err)
      second = diff_text
    end)

    assert.are.equal(1, calls)
    pending({ code = 0, stdout = "diff --git a/lua/review.lua b/lua/review.lua\n", stderr = "" })
    vim.wait(100, function()
      return first ~= nil and second ~= nil
    end)

    assert.are.equal(first, second)
    assert.is_true(first:find("diff --git", 1, true) ~= nil)

    local cached
    git.file_show_async("abc1234", "lua/review.lua", function(diff_text)
      cached = diff_text
    end)
    assert.are.equal(first, cached)
    assert.are.equal(1, calls)
  end)

  it("loads commit diffs asynchronously and coalesces duplicate requests", function()
    local calls = 0
    local pending
    vim.fn.executable = function(cmd)
      return cmd == "git" and 1 or original_executable(cmd)
    end
    vim.system = function(cmd, opts, callback)
      calls = calls + 1
      assert.are.same({ "git", "diff", "abc1234~1", "abc1234" }, cmd)
      pending = callback
    end

    local first
    local second
    git.commit_diff_async("abc1234", function(diff_text, err)
      assert.is_nil(err)
      first = diff_text
    end)
    git.commit_diff_async("abc1234", function(diff_text, err)
      assert.is_nil(err)
      second = diff_text
    end)

    assert.are.equal(1, calls)
    pending({ code = 0, stdout = "diff --git a/a b/a\n", stderr = "" })
    vim.wait(100, function()
      return first ~= nil and second ~= nil
    end)

    assert.are.equal(first, second)
    assert.is_true(first:find("diff --git", 1, true) ~= nil)
  end)

  it("loads blame asynchronously with commit summaries", function()
    local author_time = os.time({ year = 2026, month = 5, day = 15, hour = 12, min = 0, sec = 0 })
    vim.fn.executable = function(cmd)
      return cmd == "git" and 1 or original_executable(cmd)
    end
    vim.system = function(cmd, opts, callback)
      assert.are.same({ "git", "blame", "--line-porcelain", "main", "--", "lua/review.lua" }, cmd)
      callback({
        code = 0,
        stdout = table.concat({
          "abc123456789 2 2 1",
          "author Reviewer",
          "author-time " .. tostring(author_time),
          "summary Explain old behavior",
          "filename lua/review.lua",
          "\told code",
          "",
        }, "\n"),
        stderr = "",
      })
    end

    local result
    git.blame_async("main", "lua/review.lua", function(lines, err)
      assert.is_nil(err)
      result = lines
    end)
    vim.wait(100, function()
      return result ~= nil
    end)

    assert.is_true(result[1]:find("Reviewer 2026-05-15 2", 1, true) ~= nil)
    assert.is_true(result[1]:find("Explain old behavior | old code", 1, true) ~= nil)
  end)

  it("loads commit logs asynchronously and caches the result", function()
    local calls = 0
    vim.fn.executable = function(cmd)
      return cmd == "git" and 1 or original_executable(cmd)
    end
    vim.system = function(cmd, opts, callback)
      calls = calls + 1
      assert.are.same({ "git", "log", "--format=%H\t%s\t%an", "main..HEAD" }, cmd)
      callback({ code = 0, stdout = "abcdef1234567890\tPolish review\tpsanchez\n", stderr = "" })
    end

    local first
    git.log_async("main", nil, function(commits, err)
      assert.is_nil(err)
      first = commits
    end)
    vim.wait(100, function()
      return first ~= nil
    end)
    assert.are.equal("abcdef1234567890", first[1].sha)
    assert.are.equal("abcdef1", first[1].short_sha)
    assert.are.equal("Polish review", first[1].message)

    local second
    git.log_async("main", nil, function(commits)
      second = commits
    end)
    assert.are.equal("abcdef1234567890", second[1].sha)
    assert.are.equal(1, calls)
  end)
end)
