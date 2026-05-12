if vim.g.loaded_review then
  return
end
vim.g.loaded_review = true

vim.api.nvim_create_user_command("Review", function(opts)
  require("review").open(opts.fargs)
end, {
  nargs = "*",
  desc = "Open code review",
  complete = function()
    return {}
  end,
})

vim.api.nvim_create_user_command("ReviewClose", function()
  require("review").close()
end, {
  desc = "Close code review",
})

vim.api.nvim_create_user_command("ReviewToggle", function()
  require("review").toggle()
end, {
  desc = "Toggle code review panel",
})

vim.api.nvim_create_user_command("ReviewRefresh", function()
  require("review").refresh_comments()
end, {
  desc = "Re-fetch PR/MR comments from remote",
})

vim.api.nvim_create_user_command("ReviewNotes", function()
  require("review").open_notes()
end, {
  desc = "Open the review notes list",
})

vim.api.nvim_create_user_command("ReviewHelp", function()
  require("review").open_help()
end, {
  desc = "Open review help",
})

vim.api.nvim_create_user_command("ReviewComment", function(opts)
  require("review").add_note(opts.fargs)
end, {
  nargs = "*",
  desc = "Add a review note",
})

vim.api.nvim_create_user_command("ReviewSuggestion", function(opts)
  require("review").add_suggestion(opts.fargs)
end, {
  nargs = "*",
  desc = "Add a review suggestion",
})

vim.api.nvim_create_user_command("ReviewExport", function(opts)
  require("review").export(opts.fargs[1])
end, {
  nargs = "?",
  desc = "Export review notes to markdown",
  complete = "file",
})

vim.api.nvim_create_user_command("ReviewClipboard", function()
  require("review").copy_notes_to_clipboard()
end, {
  desc = "Copy review notes to the clipboard",
})

vim.api.nvim_create_user_command("ReviewClipboardLocal", function()
  require("review").copy_local_notes_to_clipboard()
end, {
  desc = "Copy local review notes to the clipboard",
})

vim.api.nvim_create_user_command("ReviewClearLocal", function()
  require("review").clear_local_notes()
end, {
  desc = "Clear all local review notes with confirmation",
})
