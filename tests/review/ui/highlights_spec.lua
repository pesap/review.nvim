describe("review.ui.highlights", function()
  local original_module
  local highlights

  before_each(function()
    original_module = package.loaded["review.ui.highlights"]
    package.loaded["review.ui.highlights"] = nil
    highlights = require("review.ui.highlights")
  end)

  after_each(function()
    package.loaded["review.ui.highlights"] = original_module
  end)

  it("exposes stable highlight group names for renderers", function()
    assert.are.equal("ReviewDiffAdd", highlights.groups.add)
    assert.are.equal("ReviewExplorerActive", highlights.groups.explorer_active)
    assert.are.equal("ReviewExplorerFileReviewed", highlights.groups.explorer_file_reviewed)
    assert.are.equal("ReviewExplorerDir", highlights.groups.explorer_dir)
    assert.are.equal("ReviewExplorerDirMeta", highlights.groups.explorer_dir_meta)
    assert.are.equal("ReviewExplorerScopeValue", highlights.groups.explorer_scope_value)
    assert.are.equal("ReviewExplorerStatAdd", highlights.groups.explorer_stat_add)
    assert.are.equal("ReviewExplorerStatDel", highlights.groups.explorer_stat_del)
    assert.are.equal("ReviewNoteRemoteResolved", highlights.groups.note_remote_resolved)
  end)

  it("sets colorblind and default palettes through the extracted module", function()
    highlights.setup(true)
    local colorblind_add = vim.api.nvim_get_hl(0, { name = highlights.groups.status_a, link = false })
    local colorblind_delete = vim.api.nvim_get_hl(0, { name = highlights.groups.status_d, link = false })

    highlights.setup(false)
    local default_add = vim.api.nvim_get_hl(0, { name = highlights.groups.status_a, link = false })
    local default_delete = vim.api.nvim_get_hl(0, { name = highlights.groups.status_d, link = false })

    assert.is_not_nil(colorblind_add.fg)
    assert.is_not_nil(colorblind_delete.fg)
    assert.is_not_nil(default_add.fg)
    assert.is_not_nil(default_delete.fg)
    assert.are_not.equal(colorblind_add.fg, default_add.fg)
    assert.are_not.equal(colorblind_delete.fg, default_delete.fg)
  end)
end)
