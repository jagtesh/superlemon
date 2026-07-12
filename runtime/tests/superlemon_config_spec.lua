-- The annotated managed settings file is independently sourceable, complete,
-- and safe to source again while iterating on a configuration.
local H = dofile(vim.fs.dirname(arg[0]) .. "/helpers.lua")
H.setup_rtp()

local settings = H.root() .. "/config/superlemon.vim"
local source = "source " .. vim.fn.fnameescape(settings)
local ok, err = pcall(vim.cmd, source)
H.ok(ok, "superlemon.vim sources directly" .. (ok and "" or (": " .. tostring(err))))

H.eq(vim.g.superlemon_native_tabs, 1, "native tabs setting documented and enabled")
H.eq(vim.g.superlemon_native_statusbar, 1, "native statusbar setting documented and enabled")
H.eq(vim.g.superlemon_adopt_statusline, 1, "statusline adoption setting explicit")
H.eq(vim.g.superlemon_hide_tabline, 0, "tabline hiding setting explicit")
H.eq(vim.g.superlemon_native_minimap, 1, "native minimap documented and enabled")
H.eq(vim.g.superlemon_native_scrollbars, 0, "native scrollbars documented and disabled")
H.eq(vim.g.superlemon_native_ui, 1, "native picker setting explicit")
H.eq(vim.g.superlemon_default_keymaps, 1, "default keymap setting explicit")
H.eq(vim.g.superlemon_powerline_glyphs, 0, "Powerline synthesis setting explicit")
H.eq(vim.g.superlemon_ligatures, 1, "ligature setting explicit")
H.eq(vim.g.superlemon_use_symbol_font, 0, "symbol companion setting explicit")
H.eq(vim.g.superlemon_force_glyph_fallback, 0, "glyph fallback setting explicit")
H.eq(vim.g.superlemon_minimap_width, 88, "minimap width setting explicit")
H.eq(vim.g.superlemon_minimap_scale, 0.20, "minimap scale setting explicit")
H.eq(vim.g.superlemon_minimap_pitch, 2.0, "minimap pitch setting explicit")

H.eq(vim.o.mousescroll, "ver:1,hor:1", "one-cell native scrolling configured")
H.eq(vim.o.laststatus, 0, "native statusbar reclaims the statusline row")
H.eq(vim.o.cmdheight, 0, "native command line reclaims the command row")
H.eq(vim.o.showmode, false, "native mode badge avoids duplicate showmode text")
H.ok(vim.o.statusline ~= "", "native statusbar has a harvestable statusline")

local ok_again, err_again = pcall(vim.cmd, source)
H.ok(ok_again, "superlemon.vim can be re-sourced" ..
  (ok_again and "" or (": " .. tostring(err_again))))

-- The shortcut master switch is consumed by runtime code; individual user
-- mappings continue to be covered by keymaps_spec.lua.
vim.g.superlemon_default_keymaps = 0
H.stub_gui()
require("superlemon").setup(1)
H.eq(require("superlemon.keymaps").installed, 0, "default keymaps can be disabled")
H.eq(vim.fn.maparg("<D-s>", "n"), "", "keymap opt-out installs no Command-S map")

H.finish()
