--- Checkhealth for review.nvim
--- Run with :checkhealth review
local M = {}

function M.check()
  vim.health.start("review.nvim")

  -- Check git
  if vim.fn.executable("git") == 1 then
    vim.health.ok("git is installed")
  else
    vim.health.error("git is not installed", { "Install git: https://git-scm.com/" })
    return
  end

  -- Check gh CLI
  if vim.fn.executable("gh") == 1 then
    vim.health.ok("gh CLI is installed")
  else
    vim.health.error("gh CLI is not installed", {
      "Install gh: https://cli.github.com/",
      "Required for PR review features",
    })
  end

  -- Check gh authentication
  if vim.fn.executable("gh") == 1 then
    local result = vim.fn.system({ "gh", "auth", "status" })
    if vim.v.shell_error == 0 then
      vim.health.ok("gh is authenticated")
    else
      vim.health.warn("gh is not authenticated", {
        "Run: gh auth login",
        "Required for PR review features (local diff review works without auth)",
      })
    end
  end

  -- Check if current directory is a git repo
  local git = require("review.git")
  if git.root() then
    vim.health.ok("Current directory is a git repository")
  else
    vim.health.info("Current directory is not a git repository")
  end
end

return M
