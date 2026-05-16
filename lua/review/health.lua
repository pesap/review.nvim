--- Checkhealth for review.nvim
--- Run with :checkhealth review
local M = {}

local function check_nvim_version()
  if vim.fn.has("nvim-0.10") == 1 then
    vim.health.ok("Neovim >= 0.10 is available")
  else
    vim.health.error("Neovim >= 0.10 is required", {
      "review.nvim uses vim.system() for async git and forge operations.",
      "Upgrade Neovim to 0.10 or newer.",
    })
  end
end

local function command_output(cmd)
  local ok, result = pcall(vim.fn.system, cmd)
  if not ok or vim.v.shell_error ~= 0 then
    return nil
  end
  return vim.trim(result or "")
end

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
  check_nvim_version()

  if vim.fn.executable("git") == 1 then
    local version = command_output({ "git", "--version" })
    vim.health.ok("git is installed" .. (version and (": " .. version) or ""))
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
      local version = command_output({ "but", "--version" })
      vim.health.ok("but CLI is installed" .. (version and (": " .. version) or ""))
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
