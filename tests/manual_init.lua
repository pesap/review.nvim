-- Minimal init for manual testing. Usage:
--   nvim --clean -u tests/manual_init.lua
vim.opt.rtp:prepend(".")
vim.cmd("runtime plugin/review.lua")

require("review").setup()
