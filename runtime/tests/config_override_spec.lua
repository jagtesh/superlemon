-- The internal config loads the bundled baseline first and the Superlemon
-- home-directory init second, making the latter authoritative.
local H = dofile(vim.fs.dirname(arg[0]) .. "/helpers.lua")
H.setup_rtp()

local config_home = H.tmpdir() .. " config home"
vim.fn.mkdir(config_home, "p")
vim.env.XDG_CONFIG_HOME = config_home
local override_dir = vim.fs.joinpath(config_home, "superlemon")
vim.fn.mkdir(override_dir, "p")
vim.fn.writefile({
  'let g:superlemon_native_tabs = 0',
  'let g:superlemon_powerline_glyphs = 1',
  'let g:superlemon_native_minimap = 0',
  'let g:superlemon_minimap_width = 112',
  'set mousescroll=ver:7,hor:5',
  'let g:superlemon_override_marker = "home-init"',
  'let g:superlemon_baseline_was_loaded = get(g:, "superlemon_native_statusbar", -1)',
  'let g:superlemon_override_sources = get(g:, "superlemon_override_sources", 0) + 1',
}, vim.fs.joinpath(override_dir, "init.vim"))

dofile(H.root() .. "/config/init.lua")

H.eq(vim.g.superlemon_override_marker, "home-init", "XDG Superlemon init is sourced")
H.eq(vim.g.superlemon_baseline_was_loaded, 1, "bundled baseline precedes personal config")
H.eq(vim.g.superlemon_native_tabs, 0, "home init overrides a bundled chrome value")
H.eq(vim.g.superlemon_powerline_glyphs, 1, "home init overrides a renderer value")
H.eq(vim.g.superlemon_native_minimap, 0, "home init overrides the minimap toggle")
H.eq(vim.g.superlemon_minimap_width, 112, "home init overrides minimap geometry")
H.eq(vim.o.mousescroll, "ver:7,hor:5", "home init overrides a native option")
H.eq(vim.g.superlemon_native_statusbar, 1, "unmentioned bundled defaults remain")
H.eq(vim.g.superlemon_ligatures, 1, "unmentioned renderer defaults remain")
H.eq(vim.g.superlemon_override_sources, 1, "internal init sources the override once")
H.eq(vim.g.superlemon_override_sources, 1, "source count remains one after bootstrap check")
H.eq(require("superlemon.settings").config_status(), {
  mode = "managed",
  path = vim.fs.joinpath(override_dir, "init.vim"),
  state = "loaded",
}, "managed startup exposes clean structured config diagnostics")

H.finish()
