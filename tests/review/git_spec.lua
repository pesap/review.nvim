local git = require("review.git")

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
