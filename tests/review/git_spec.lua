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

describe("git status actions", function()
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

  it("builds staged, unstaged, and untracked status sections", function()
    write_file("lua/staged.lua", { "after staged" })
    git_ok({ "git", "add", "lua/staged.lua" })

    write_file("lua/unstaged.lua", { "after unstaged" })

    write_file("lua/both.lua", { "after staged both", "after both" })
    git_ok({ "git", "add", "lua/both.lua" })
    write_file("lua/both.lua", { "after staged both", "after unstaged both" })

    git_ok({ "git", "mv", "old/name.lua", "lua/renamed.lua" })
    write_file("lua/new.lua", { "first", "second" })

    local sections = git.status_sections()

    assert.are.equal(3, #sections.staged)
    assert.are.equal(2, #sections.unstaged)
    assert.are.equal(1, #sections.untracked)

    assert.are.same({ "lua/both.lua", "lua/renamed.lua", "lua/staged.lua" }, vim.tbl_map(function(file)
      return file.path
    end, sections.staged))
    assert.are.same({ "M", "R", "M" }, vim.tbl_map(function(file)
      return file.git_status
    end, sections.staged))

    assert.are.same({ "lua/both.lua", "lua/unstaged.lua" }, vim.tbl_map(function(file)
      return file.path
    end, sections.unstaged))
    assert.are.same({ "M", "M" }, vim.tbl_map(function(file)
      return file.git_status
    end, sections.unstaged))

    assert.are.equal("lua/new.lua", sections.untracked[1].path)
    assert.are.equal("untracked", sections.untracked[1].git_section)
    assert.are.equal("?", sections.untracked[1].git_status)
    assert.are.equal(2, #sections.untracked[1].hunks[1].lines)
  end)

  it("uses git reset to unstage tracked files", function()
    write_file("lua/staged.lua", { "after staged" })
    git_ok({ "git", "add", "lua/staged.lua" })

    local ok, err = git.unstage_path("lua/staged.lua")
    local status = vim.fn.systemlist({ "git", "status", "--porcelain", "--", "lua/staged.lua" })

    assert.is_true(ok)
    assert.is_nil(err)
    assert.are.same({ " M lua/staged.lua" }, status)
  end)

  it("uses git rm --cached to unstage new files", function()
    write_file("lua/new.lua", { "brand new" })
    git_ok({ "git", "add", "lua/new.lua" })

    local ok, err = git.unstage_path("lua/new.lua", { new_file = true })
    local status = vim.fn.systemlist({ "git", "status", "--porcelain", "--", "lua/new.lua" })

    assert.is_true(ok)
    assert.is_nil(err)
    assert.are.same({ "?? lua/new.lua" }, status)
  end)

  it("runs commit, amend, and fixup commands", function()
    write_file("lua/staged.lua", { "commit one" })
    git_ok({ "git", "add", "lua/staged.lua" })
    assert.is_true(git.commit("ship it"))
    local ship_sha = vim.trim(git_ok({ "git", "rev-parse", "HEAD" }))

    write_file("lua/staged.lua", { "commit amend" })
    git_ok({ "git", "add", "lua/staged.lua" })
    assert.is_true(git.commit(nil, { amend = true }))
    assert.are.equal("ship it", vim.trim(git_ok({ "git", "log", "-1", "--pretty=%s" })))

    write_file("lua/staged.lua", { "commit fixup" })
    git_ok({ "git", "add", "lua/staged.lua" })
    assert.is_true(git.fixup_commit(ship_sha))
    assert.are.equal("fixup! ship it", vim.trim(git_ok({ "git", "log", "-1", "--pretty=%s" })))
  end)

  it("deletes files relative to the repo root", function()
    write_file("lua/obsolete.lua", { "remove me" })

    local ok, err = git.remove_path("lua/obsolete.lua")

    assert.is_true(ok)
    assert.is_nil(err)
    assert.are.equal(0, vim.fn.filereadable(tempdir .. "/lua/obsolete.lua"))
  end)
end)

describe("gitbutler detection", function()
  local original_executable

  before_each(function()
    original_executable = vim.fn.executable
  end)

  after_each(function()
    vim.fn.executable = original_executable
    git.invalidate_cache()
  end)

  it("treats missing but as a non-GitButler repo", function()
    vim.fn.executable = function(cmd)
      if cmd == "but" then
        return 0
      end
      return original_executable(cmd)
    end

    assert.is_false(git.is_gitbutler_workspace())

    local lines, err = git.gitbutler_status_lines()
    assert.is_nil(lines)
    assert.are.equal("but is not executable", err)
  end)
end)

describe("open_fugitive_status", function()
  local original_has_fugitive
  local original_cmd
  local original_get_current_tabpage
  local original_get_current_buf
  local original_get_current_win
  local original_buf_get_name
  local original_tabpage_list_wins
  local original_win_is_valid
  local original_win_get_buf
  local original_filetype

  before_each(function()
    original_has_fugitive = git.has_fugitive
    original_cmd = vim.cmd
    original_get_current_tabpage = vim.api.nvim_get_current_tabpage
    original_get_current_buf = vim.api.nvim_get_current_buf
    original_get_current_win = vim.api.nvim_get_current_win
    original_buf_get_name = vim.api.nvim_buf_get_name
    original_tabpage_list_wins = vim.api.nvim_tabpage_list_wins
    original_win_is_valid = vim.api.nvim_win_is_valid
    original_win_get_buf = vim.api.nvim_win_get_buf
    original_filetype = vim.bo.filetype
  end)

  after_each(function()
    git.has_fugitive = original_has_fugitive
    vim.cmd = original_cmd
    vim.api.nvim_get_current_tabpage = original_get_current_tabpage
    vim.api.nvim_get_current_buf = original_get_current_buf
    vim.api.nvim_get_current_win = original_get_current_win
    vim.api.nvim_buf_get_name = original_buf_get_name
    vim.api.nvim_tabpage_list_wins = original_tabpage_list_wins
    vim.api.nvim_win_is_valid = original_win_is_valid
    vim.api.nvim_win_get_buf = original_win_get_buf
  end)

  it("returns an error when :Git does not open a fugitive buffer", function()
    local current_buf = vim.api.nvim_create_buf(false, true)
    local other_buf = vim.api.nvim_create_buf(false, true)

    git.has_fugitive = function()
      return true
    end
    vim.cmd = function() end
    vim.api.nvim_get_current_tabpage = function()
      return 1
    end
    vim.api.nvim_get_current_buf = function()
      return current_buf
    end
    vim.api.nvim_get_current_win = function()
      return 22
    end
    vim.api.nvim_buf_get_name = function(buf)
      if buf == current_buf then
        return "regular-buffer"
      end
      if buf == other_buf then
        return "other-regular-buffer"
      end
      return ""
    end
    vim.bo[current_buf].filetype = ""
    vim.bo[other_buf].filetype = ""
    vim.api.nvim_tabpage_list_wins = function()
      return { 22, 33 }
    end
    vim.api.nvim_win_is_valid = function()
      return true
    end
    vim.api.nvim_win_get_buf = function(win)
      return win == 22 and current_buf or other_buf
    end

    local opened, err = git.open_fugitive_status()

    assert.is_nil(opened)
    assert.are.equal("vim-fugitive did not open a Fugitive buffer", err)
  end)
end)
