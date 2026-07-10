-- g:clipboard provider registration + end-to-end register round trip.
local H = dofile(vim.fs.dirname(arg[0]) .. "/helpers.lua")
H.setup_rtp()
local calls = H.stub_gui()

require("superlemon").setup(5)

local cb = vim.g.clipboard
H.ok(type(cb) == "table", "g:clipboard is set")
H.eq(type(cb) == "table" and cb.name or nil, "superlemon", 'provider named "superlemon"')
H.eq(require("superlemon.clipboard").active, true, "clipboard module reports active")

-- copy: setreg('+') must rpcrequest superlemon.clipboard_set(lines, regtype)
vim.fn.setreg("+", { "hello", "world" }, "V")
local req = calls.request[#calls.request]
H.ok(req ~= nil, "setreg('+') triggered an rpcrequest")
if req then
  H.eq(req.method, "superlemon.clipboard_set", "copy method")
  H.eq(req.chan, 5, "copy channel")
  -- nvim passes linewise registers to providers with a trailing "" entry
  H.eq(req.args[1], { "hello", "world", "" }, "copy lines (linewise trailing sentinel)")
  H.eq(req.args[2], "V", "copy regtype")
end

-- star register uses the same provider
vim.fn.setreg("*", { "star" }, "v")
req = calls.request[#calls.request]
H.eq(req and req.method, "superlemon.clipboard_set", "* register also routed to provider")
H.eq(req and req.args[1], { "star" }, "charwise copy lines exact")
H.eq(req and req.args[2], "v", "charwise regtype")

-- paste: getreg('+') must rpcrequest superlemon.clipboard_get and use its result
calls.request_result = { { "from-gui" }, "v" }
local got = vim.fn.getreg("+", 1, true)
req = calls.request[#calls.request]
H.eq(req and req.method, "superlemon.clipboard_get", "paste method")
H.eq(req and req.chan, 5, "paste channel")
H.eq(got, { "from-gui" }, "getreg('+') returns GUI-provided lines")

-- Idempotent re-setup keeps our provider without warning.
local notices = {}
local orig_notify = vim.notify
vim.notify = function(msg, ...) table.insert(notices, msg) end
require("superlemon.clipboard").setup()
vim.notify = orig_notify
H.eq(#notices, 0, "re-setup over our own provider does not warn")
H.eq(vim.g.clipboard.name, "superlemon", "provider still ours after re-setup")

H.finish()
