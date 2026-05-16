--- Highlight groups for review.nvim UI.
local M = {}

M.groups = {
  add = "ReviewDiffAdd",
  del = "ReviewDiffDelete",
  add_text = "ReviewDiffAddText",
  del_text = "ReviewDiffDeleteText",
  diff_gutter = "ReviewDiffGutter",
  diff_context = "ReviewDiffContext",
  meta = "ReviewMeta",
  file_header = "ReviewFileHeader",
  panel_title = "ReviewPanelTitle",
  panel_meta = "ReviewPanelMeta",
  pane_bg = "ReviewPaneBg",
  float_bg = "ReviewFloatBg",
  cursorline = "ReviewCursorLine",
  window_edge = "ReviewWindowEdge",
  focus = "ReviewFocus",
  explorer_file = "ReviewExplorerFile",
  explorer_file_reviewed = "ReviewExplorerFileReviewed",
  explorer_dir = "ReviewExplorerDir",
  explorer_dir_marker = "ReviewExplorerDirMarker",
  explorer_dir_meta = "ReviewExplorerDirMeta",
  explorer_path = "ReviewExplorerPath",
  explorer_active = "ReviewExplorerActive",
  explorer_active_row = "ReviewExplorerActiveRow",
  explorer_scope = "ReviewExplorerScope",
  explorer_scope_value = "ReviewExplorerScopeValue",
  explorer_stat_add = "ReviewExplorerStatAdd",
  explorer_stat_del = "ReviewExplorerStatDel",
  status_m = "ReviewStatusM",
  status_a = "ReviewStatusA",
  status_d = "ReviewStatusD",
  status_a_dim = "ReviewStatusADim",
  status_d_dim = "ReviewStatusDDim",
  note_sign = "ReviewNoteSign",
  commit = "ReviewCommit",
  commit_active = "ReviewCommitActive",
  commit_author = "ReviewCommitAuthor",
  note_published = "ReviewNotePublished",
  note_draft = "ReviewNoteDraft",
  note_ref = "ReviewNoteRef",
  note_remote = "ReviewNoteRemote",
  note_remote_resolved = "ReviewNoteRemoteResolved",
  note_author = "ReviewNoteAuthor",
  note_separator = "ReviewNoteSeparator",
  threads_header = "ReviewThreadsHeader",
  vendor_group = "ReviewVendorGroup",
  local_group = "ReviewLocalGroup",
}

--- Set up highlight groups.
---@param colorblind boolean
function M.setup(colorblind)
  local set = vim.api.nvim_set_hl
  local HL = M.groups
  if colorblind then
    -- Okabe-Ito-inspired palette for better colorblind accessibility on dark backgrounds.
    set(0, HL.add, { bg = "#16384d" })
    set(0, HL.del, { bg = "#4d3410" })
    set(0, HL.add_text, { bg = "#215878", bold = true })
    set(0, HL.del_text, { bg = "#7a5318", bold = true })
    set(0, HL.status_a, { fg = "#56b4e9" })
    set(0, HL.status_d, { fg = "#e69f00" })
    set(0, HL.status_a_dim, { fg = "#4a90ba" })
    set(0, HL.status_d_dim, { fg = "#b78100" })
  else
    set(0, HL.add, { bg = "#2a4a2a" })
    set(0, HL.del, { bg = "#4a2a2a" })
    set(0, HL.add_text, { bg = "#3a6a3a", bold = true })
    set(0, HL.del_text, { bg = "#6a3a3a", bold = true })
    set(0, HL.status_a, { fg = "#98c379" })
    set(0, HL.status_d, { fg = "#e06c75" })
    set(0, HL.status_a_dim, { fg = "#70935a" })
    set(0, HL.status_d_dim, { fg = "#a85660" })
  end
  set(0, HL.pane_bg, { bg = "#101318" })
  set(0, HL.float_bg, { bg = "#141923" })
  set(0, HL.cursorline, { bg = "#1b2330" })
  set(0, HL.window_edge, { fg = "#303846", bg = "#101318" })
  set(0, HL.focus, { fg = colorblind and "#ebcb8b" or "#e5c07b", bold = true })
  set(0, HL.diff_gutter, { fg = "#5c6370" })
  set(0, HL.diff_context, { fg = "#9aa3b2" })
  set(0, HL.meta, { fg = "#888888", italic = true })
  set(0, HL.file_header, { fg = colorblind and "#d8dee9" or "#8fb6d8", bold = true })
  set(0, HL.panel_title, { fg = colorblind and "#d8dee9" or "#d8dee9", bold = true })
  set(0, HL.panel_meta, { fg = "#7b8494" })
  set(0, HL.explorer_file, { fg = "#c2c8d3" })
  set(0, HL.explorer_file_reviewed, { fg = "#7d8796" })
  set(0, HL.explorer_dir, { fg = colorblind and "#a9c7df" or "#9dbad5", bold = true })
  set(0, HL.explorer_dir_marker, { fg = "#566070" })
  set(0, HL.explorer_dir_meta, { fg = "#697385" })
  set(0, HL.explorer_path, { fg = "#7b8494", italic = true })
  set(0, HL.explorer_active, { fg = colorblind and "#dce6f2" or "#dce6f2" })
  set(0, HL.explorer_active_row, { bg = "#1a2430" })
  set(0, HL.explorer_scope, { fg = "#8f98a8" })
  set(0, HL.explorer_scope_value, { fg = colorblind and "#ebcb8b" or "#e5c07b", bold = true })
  set(0, HL.explorer_stat_add, { fg = colorblind and "#56b4e9" or "#98c379" })
  set(0, HL.explorer_stat_del, { fg = colorblind and "#e69f00" or "#e06c75" })
  set(0, HL.status_m, { fg = colorblind and "#d8c14a" or "#e5c07b" })
  set(0, HL.note_sign, { fg = colorblind and "#cc79a7" or "#c678dd", bold = true })
  set(0, HL.commit, { fg = colorblind and "#d9a441" or "#d19a66" })
  set(0, HL.commit_active, { fg = colorblind and "#ebcb8b" or "#e5c07b", bold = true })
  set(0, HL.commit_author, { fg = "#888888", italic = true })
  set(0, HL.note_published, { fg = colorblind and "#4db6ac" or "#98c379" })
  set(0, HL.note_draft, { fg = colorblind and "#ebcb8b" or "#e5c07b" })
  set(0, HL.note_ref, { fg = colorblind and "#56b4e9" or "#61afef", underline = true })
  set(0, HL.note_remote, { fg = colorblind and "#4db6ac" or "#56b6c2" })
  set(0, HL.note_remote_resolved, { fg = "#5c6370" })
  set(0, HL.note_author, { fg = colorblind and "#cc79a7" or "#c678dd" })
  set(0, HL.note_separator, { fg = "#3e4452" })
  set(0, HL.threads_header, { fg = colorblind and "#c7a252" or "#e5c07b", bold = true })
  set(0, HL.vendor_group, { fg = colorblind and "#4db6ac" or "#56b6c2", bold = true })
  set(0, HL.local_group, { fg = colorblind and "#cc79a7" or "#c678dd", bold = true })
end

return M
