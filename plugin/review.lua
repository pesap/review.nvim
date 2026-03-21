if vim.g.loaded_review then
  return
end
vim.g.loaded_review = true

vim.api.nvim_create_user_command("Review", function(opts)
  require("review").open(opts.fargs)
end, {
  nargs = "*",
  desc = "Open code review",
  complete = function(_, cmdline, _)
    local args = vim.split(cmdline, "%s+")
    if #args == 2 then
      return { "pr" }
    end
    return {}
  end,
})

vim.api.nvim_create_user_command("ReviewClose", function()
  require("review").close()
end, {
  desc = "Close code review",
})

vim.api.nvim_create_user_command("ReviewSubmit", function()
  require("review").submit()
end, {
  desc = "Submit review comments",
})

vim.api.nvim_create_user_command("ReviewToggle", function()
  require("review").toggle()
end, {
  desc = "Toggle code review panel",
})

vim.api.nvim_create_user_command("ReviewExport", function(opts)
  require("review").export(opts.fargs[1])
end, {
  nargs = "?",
  desc = "Export review notes to markdown",
  complete = "file",
})
