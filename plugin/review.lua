if vim.g.loaded_review then
  return
end
vim.g.loaded_review = true

---@param opts table|nil
---@param success_msg string
local function copy_review_export(opts, success_msg)
  local review = package.loaded["review"] or require("review")
  if type(review.export_content) ~= "function" then
    package.loaded["review"] = nil
    review = require("review")
  end

  if type(review.export_content) ~= "function" then
    vim.notify("Could not load review.nvim clipboard exporter", vim.log.levels.ERROR)
    return
  end

  local content, err = review.export_content(opts or {})
  if not content then
    vim.notify(err, err == "No active review session" and vim.log.levels.ERROR or vim.log.levels.INFO)
    return
  end

  vim.fn.setreg('"', content)
  local copied = {}
  local ok_plus = pcall(vim.fn.setreg, "+", content)
  if ok_plus then
    table.insert(copied, "+")
  end
  local ok_star = pcall(vim.fn.setreg, "*", content)
  if ok_star then
    table.insert(copied, "*")
  end
  local target = #copied == 0 and [["]] or table.concat(copied, ", ")
  vim.notify(success_msg .. target, vim.log.levels.INFO)
end

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
  require("review.ui").refresh_session()
end, {
  desc = "Refresh review data",
})

vim.api.nvim_create_user_command("ReviewChangeBase", function(opts)
  require("review").change_base(opts.fargs[1])
end, {
  nargs = "?",
  desc = "Re-diff the active local review against another base ref",
  complete = function()
    return {}
  end,
})

vim.api.nvim_create_user_command("ReviewMarkBaseline", function()
  require("review").mark_baseline()
end, {
  desc = "Mark current HEAD as the before-fix review baseline",
})

vim.api.nvim_create_user_command("ReviewCompareBaseline", function()
  require("review").compare_baseline()
end, {
  desc = "Compare current review against the marked before-fix baseline",
})

vim.api.nvim_create_user_command("ReviewCompareUnit", function(opts)
  require("review").compare_unit(opts.fargs[1])
end, {
  nargs = "?",
  desc = "Compare selected/current review unit with another unit",
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
  copy_review_export({ clipboard = true }, "Notes copied to clipboard register(s): ")
end, {
  desc = "Copy review notes to the clipboard",
})

vim.api.nvim_create_user_command("ReviewClipboardLocal", function()
  copy_review_export({ local_only = true }, "Local notes copied to clipboard register(s): ")
end, {
  desc = "Copy local review notes to the clipboard",
})

vim.api.nvim_create_user_command("ReviewClearLocal", function()
  require("review").clear_local_notes()
end, {
  desc = "Clear all local review notes with confirmation",
})
