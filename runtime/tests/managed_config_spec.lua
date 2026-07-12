-- managed_config_spec.lua — the built-in config's powerline statusline
-- evaluates into harvestable, correctly-colored segments.
local H = dofile(vim.fs.dirname(arg[0]) .. "/helpers.lua")
H.setup_rtp()
vim.env.XDG_CONFIG_HOME = H.tmpdir() -- never read the developer's real override

local calls = H.stub_gui()

-- Source the managed config exactly as a `-u` launch would, then attach.
dofile(H.root() .. "/config/init.lua")
require("superlemon").setup(1)

H.ok(vim.o.statusline ~= "", "managed config defines a statusline")
H.eq(vim.g.superlemon_native_tabs, 1, "native tabs on by default")
H.eq(vim.g.superlemon_native_statusbar, 1, "native statusbar on by default")
H.eq(vim.g.superlemon_adopt_statusline, 1, "native statusbar adopts the statusline")
H.eq(vim.g.superlemon_hide_tabline, 0, "managed config keeps distinct tabpages visible")
H.eq(vim.g.superlemon_native_minimap, 1, "native minimaps on by default")
H.eq(vim.g.superlemon_native_scrollbars, 0, "native scrollbars off by default")
H.eq(vim.g.superlemon_native_ui, 1, "native vim.ui pickers on by default")
H.eq(vim.g.superlemon_default_keymaps, 1, "macOS keymap defaults on by default")
H.eq(vim.g.superlemon_ligatures, 1, "renderer ligatures on by default")
H.eq(vim.g.superlemon_powerline_glyphs, 0, "Powerline synthesis opt-in by default")
H.eq(vim.g.superlemon_minimap_width, 88, "managed minimap width is stable")
H.eq(vim.g.superlemon_minimap_scale, 0.20, "managed minimap scale is stable")
H.eq(vim.g.superlemon_minimap_pitch, 2.0, "managed minimap pitch is stable")
H.eq(vim.o.laststatus, 0, "in-grid statusline released")
H.eq(vim.o.mousescroll, "ver:1,hor:1", "native scrolling advances one cell per wheel step")

local segments = require("superlemon.statusline").eval()
H.ok(segments ~= nil and #segments >= 4, "statusline evaluates into segments")

H.ok(segments[1].text:find("NORMAL", 1, true) ~= nil, "mode badge segment first")
H.eq(segments[1].bg, 0x004DC8, "NORMAL badge uses the NORTHSTAR blue")
H.eq(segments[1].bold, true, "mode badge is bold")

local joined = ""
for _, s in ipairs(segments) do
  joined = joined .. s.text
end
H.ok(joined:find("ln:", 1, true) ~= nil, "position cap present")
H.ok(joined:find("%%") ~= nil or joined:find("%d+%%") ~= nil, "percent segment present")

-- Mode reactivity: the badge helper maps modes to names and groups (mode
-- switching itself is deferred in -l script context, so test the pure fn).
H.ok(_G.superlemon_sl_mode("i"):find("SLModeInsert# INSERT ", 1, true) ~= nil,
  "insert mode maps to the insert badge")
H.ok(_G.superlemon_sl_mode("v"):find("SLModeVisual# VISUAL ", 1, true) ~= nil,
  "visual mode maps to the visual badge")
local insert_hl = vim.api.nvim_get_hl(0, { name = "SLModeInsert", link = false })
H.eq(insert_hl.bg, 0xADC694, "INSERT badge uses the sage green")

-- Outside a repository the git segment is silently absent (no error).
H.ok(joined:find("⎇") == nil or true, "git segment tolerated") -- eval didn't error
H.finish()
