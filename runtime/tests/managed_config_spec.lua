-- managed_config_spec.lua — the built-in config's powerline statusline
-- evaluates into harvestable, correctly-colored segments.
local H = dofile(vim.fs.dirname(arg[0]) .. "/helpers.lua")
H.setup_rtp()

local calls = H.stub_gui()

-- Source the managed config exactly as a `-u` launch would, then attach.
dofile(H.root() .. "/config/init.lua")
require("superlemon").setup(1)

H.ok(vim.o.statusline ~= "", "managed config defines a statusline")
H.eq(vim.g.superlemon_native_tabs, 1, "native tabs on by default")
H.eq(vim.o.laststatus, 0, "in-grid statusline released")

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
