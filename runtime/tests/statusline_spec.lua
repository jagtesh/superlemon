-- statusline_spec.lua — evaluated-statusline harvest (CONTRACT.md
-- superlemon.statusline) + the adopt-mode opt-in.
local H = dofile(vim.fs.dirname(arg[0]) .. "/helpers.lua")
H.setup_rtp()

local calls = H.stub_gui()

local function notifies(method)
  return vim.tbl_filter(function(c)
    return c.method == method
  end, calls.notify)
end

local function last_statusline()
  local list = notifies("superlemon.statusline")
  return list[#list] and list[#list].args[1] or nil
end

require("superlemon").setup(1)

-- Not pushed while the native bar is off.
require("superlemon.statusline").push()
H.eq(#notifies("superlemon.statusline"), 0, "no push while native bar is off")

-- A custom statusline with an explicit highlight group.
vim.api.nvim_set_hl(0, "SLTestSeg", { fg = 0x112233, bg = 0xAABBCC, bold = true })
vim.o.statusline = "%#SLTestSeg#LEFT%*-plain"
vim.cmd("SuperlemonChrome statusbar on")

local payload = last_statusline()
H.ok(payload ~= nil, "statusbar-on seeds a statusline push")
H.ok(type(payload.segments) == "table", "segments table present")

local first = payload.segments[1]
H.eq(first.text, "LEFT", "first segment text from %#Group# section")
H.eq(first.fg, 0x112233, "group fg resolved")
H.eq(first.bg, 0xAABBCC, "group bg resolved")
H.eq(first.bold, true, "bold attr resolved")

local joined = ""
for _, s in ipairs(payload.segments) do
  joined = joined .. s.text
end
H.eq(joined, "LEFT-plain", "segments cover the full evaluated string")

-- Resetting to the stock statusline still harvests (nvim 0.12's default
-- 'statusline' is a real expression — assigning "" restores it, so the
-- effective statusline is never empty; the GUI shows whatever it evaluates
-- to, default or powerline alike).
vim.o.statusline = ""
require("superlemon.statusline").push()
local stock = last_statusline()
H.ok(stock.segments ~= vim.NIL and #stock.segments >= 1, "default statusline still harvests")
H.ok(stock.segments[1].text:find("No Name", 1, true) ~= nil, "default statusline content evaluated")

-- Adopt mode is the DEFAULT: bar on relocated the statusline out of the
-- grid (laststatus=0); bar off restores the user's exact value.
H.eq(vim.o.laststatus, 0, "adopt-by-default releases the in-grid statusline")
vim.cmd("SuperlemonChrome statusbar off")
H.ok(vim.o.laststatus ~= 0, "laststatus restored when the bar goes away")
local restored = vim.o.laststatus

-- Opt-out keeps both bars: laststatus untouched with the flag set to 0.
vim.g.superlemon_adopt_statusline = 0
vim.cmd("SuperlemonChrome statusbar on")
H.eq(vim.o.laststatus, restored, "opt-out keeps the in-grid statusline")
vim.cmd("SuperlemonChrome statusbar off")
H.eq(vim.o.laststatus, restored, "opt-out never modifies laststatus")

H.finish()
