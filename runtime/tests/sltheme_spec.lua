-- sltheme_spec.lua — built-in native status bar themes (CONTRACT.md
-- `superlemon.statusline`): powerline by default, colorscheme-reload
-- resilience, user 'statusline' precedence, and theme retraction.
local H = dofile(vim.fs.dirname(arg[0]) .. "/helpers.lua")
H.setup_rtp()

local sltheme = require("superlemon.sltheme")

-- Default: powerline installs its expression and colored groups.
H.eq(sltheme.apply(), true, "powerline is the default theme")
H.ok(vim.o.statusline:find("superlemon_sl_mode", 1, true) ~= nil,
  "powerline statusline installed")
local normal_badge = vim.api.nvim_get_hl(0, { name = "SLModeNormal" })
H.eq(normal_badge.bg, 0x004DC8, "NORMAL badge keeps the NORTHSTAR blue")
H.eq(normal_badge.bold, true, "mode badge is bold")

-- The regression this module exists for: a colorscheme reload (what an
-- Appearance-driven 'background' change triggers) clears user-defined
-- groups; the theme must reinstall its palette.
vim.o.background = "light"
vim.cmd.colorscheme("default")
local after_reload = vim.api.nvim_get_hl(0, { name = "SLModeNormal" })
H.eq(after_reload.bg, 0x004DC8, "powerline palette survives colorscheme reload")
H.eq(vim.api.nvim_get_hl(0, { name = "SLPos" }).bg, 0x005A37,
  "informational segments survive too")

-- Re-setup is idempotent while our expression is installed.
H.eq(sltheme.apply(), true, "reapply over our own expression")

-- Theme "default" retracts the managed statusline back to Neovim's own
-- built-in default (non-empty since 0.10).
vim.g.superlemon_statusline_theme = "default"
H.eq(sltheme.apply(), false, "default theme installs nothing")
H.eq(vim.o.statusline,
  vim.api.nvim_get_option_info2("statusline", {}).default,
  "managed expression retracted to the built-in default")

-- And powerline can return after a retraction in the same session.
vim.g.superlemon_statusline_theme = "powerline"
H.eq(sltheme.apply(), true, "powerline reapplies after retraction")

-- A user 'statusline' is never touched: not replaced by powerline, not
-- cleared by the default theme.
vim.g.superlemon_statusline_theme = "powerline"
vim.o.statusline = "%f mine"
H.eq(sltheme.apply(), false, "user statusline wins over powerline")
H.eq(vim.o.statusline, "%f mine", "user statusline untouched")
vim.g.superlemon_statusline_theme = "default"
H.eq(sltheme.apply(), false, "default theme with user statusline")
H.eq(vim.o.statusline, "%f mine", "user statusline still untouched")

H.finish()
