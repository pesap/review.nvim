--- Checkhealth for review.nvim
--- Run with :checkhealth review
local M = {}

local function check_cli(name, install_url, purpose, is_detected_forge)
  if vim.fn.executable(name) == 1 then
    vim.health.ok(name .. " CLI is installed")
    vim.fn.system({ name, "auth", "status" })
    if vim.v.shell_error == 0 then
      vim.health.ok(name .. " is authenticated")
    else
      vim.health.warn(name .. " is not authenticated", {
        "Run: " .. name .. " auth login",
        purpose,
      })
    end
  else
    if is_detected_forge then
      vim.health.error(name .. " CLI is not installed", { "Install: " .. install_url, purpose })
    else
      vim.health.info(name .. " CLI is not installed (" .. install_url .. ")")
    end
  end
end

function M.check()
  vim.health.start("review.nvim")

  if vim.fn.executable("git") == 1 then
    vim.health.ok("git is installed")
  else
    vim.health.error("git is not installed", { "Install git: https://git-scm.com/" })
    return
  end

  local git = require("review.git")
  local remote = git.parse_remote()
  local forge = remote and remote.forge or nil

  check_cli(
    "gh",
    "https://cli.github.com/",
    "Required for publishing notes to GitHub PRs",
    forge == "github" or not forge
  )
  check_cli(
    "glab",
    "https://gitlab.com/gitlab-org/cli",
    "Required for publishing notes to GitLab MRs",
    forge == "gitlab"
  )

  if git.root() then
    vim.health.ok("Current directory is a git repository")
    local gitbutler = require("review.gitbutler")
    if gitbutler.available() then
      vim.health.ok("but CLI is installed")
      if gitbutler.is_workspace() then
        vim.health.ok("GitButler workspace detected")
      else
        vim.health.info("GitButler workspace not detected")
      end
    else
      vim.health.info("but CLI is not installed")
    end
    if remote then
      vim.health.ok("Detected forge: " .. remote.forge .. " (" .. remote.owner .. "/" .. remote.repo .. ")")
    else
      vim.health.info("Could not detect forge from remote URL")
    end
  else
    vim.health.info("Current directory is not a git repository")
  end
end

return M
