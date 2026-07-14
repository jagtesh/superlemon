-- setup() idempotency + terminal-nvim no-op guard.
local H = dofile(vim.fs.dirname(arg[0]) .. "/helpers.lua")
H.setup_rtp()

-- Requiring without setup must have zero side effects.
local sl = require("superlemon")
local got_augroup = pcall(vim.api.nvim_get_autocmds, { group = "superlemon" })
H.ok(not got_augroup, "require alone creates no augroup")
H.eq(vim.g.superlemon_channel, nil, "require alone sets no channel")
H.eq(sl.active(), false, "active() is false before setup")

-- Bad input is rejected quietly.
H.ok(pcall(sl.setup), "setup() with no channel does not error")
H.ok(pcall(sl.setup, "3"), "setup() with non-number channel does not error")
H.eq(vim.g.superlemon_channel, nil, "bad setup stores no channel")

-- GUI attach.
local calls = H.stub_gui()
local setup1
local ok1, err1 = pcall(function() setup1 = sl.setup(3) end)
H.ok(ok1, "first setup() succeeds" .. (ok1 and "" or (": " .. tostring(err1))))
H.eq(setup1, {
  ready = true,
  runtime_api = 1,
  config = { mode = "external", state = "not_applicable" },
}, "setup returns structured bridge readiness")
H.eq(vim.g.superlemon_channel, 3, "channel stored in g:superlemon_channel")
H.eq(sl.active(), true, "active() true after setup with UI")

local aucmds1 = vim.api.nvim_get_autocmds({ group = "superlemon" })
H.ok(#aucmds1 > 0, "autocmds registered in augroup superlemon")

-- Idempotency: second setup must not error and must not duplicate autocmds.
local ok2, err2 = pcall(sl.setup, 3)
H.ok(ok2, "second setup() does not error" .. (ok2 and "" or (": " .. tostring(err2))))
local aucmds2 = vim.api.nvim_get_autocmds({ group = "superlemon" })
H.eq(#aucmds2, #aucmds1, "second setup leaves identical autocmd count (augroup cleared+recreated)")

-- setup() pushed an initial status (order among the setup-time pushes —
-- chrome state, status — is not part of the contract).
local status_call
for _, c in ipairs(calls.notify) do
  if c.method == "superlemon.status" then
    status_call = c
    break
  end
end
H.ok(status_call ~= nil, "setup pushes an initial superlemon.status")
H.eq(status_call and status_call.chan, 3, "initial push targets the stored channel")

-- DirChanged inside nvim notifies the GUI so the workspace re-roots
-- (CONTRACT.md `superlemon.cwd`).
local cwd_dir = H.tmpdir()
local cwd_before = #vim.tbl_filter(function(c)
  return c.method == "superlemon.cwd"
end, calls.notify)
vim.cmd("cd " .. cwd_dir)
local cwd_calls = vim.tbl_filter(function(c)
  return c.method == "superlemon.cwd"
end, calls.notify)
H.eq(#cwd_calls, cwd_before + 1, ":cd emits one superlemon.cwd notification")
H.eq(cwd_calls[#cwd_calls].args[1], { cwd = vim.fn.getcwd() },
  "superlemon.cwd carries the new working directory")

-- health module loads and runs.
local health_ok, health_err = pcall(function()
  vim.cmd("checkhealth superlemon")
end)
H.ok(health_ok, "checkhealth superlemon runs" .. (health_ok and "" or (": " .. tostring(health_err))))

H.finish()
