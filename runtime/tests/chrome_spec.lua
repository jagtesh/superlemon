-- chrome_spec.lua — native-chrome toggles + buffer pusher (CONTRACT.md).
local H = dofile(vim.fs.dirname(arg[0]) .. "/helpers.lua")
H.setup_rtp()

local calls = H.stub_gui()

local function notifies(method)
  return vim.tbl_filter(function(c)
    return c.method == method
  end, calls.notify)
end

local function last_notify(method)
  local list = notifies(method)
  return list[#list] and list[#list].args[1] or nil
end

-- Seed from g: vars: statusbar on, tabs off.
vim.g.superlemon_native_statusbar = 1
local user_laststatus = vim.o.laststatus
local user_cmdheight = vim.o.cmdheight
require("superlemon").setup(1)

local chrome = last_notify("superlemon.chrome")
H.ok(chrome ~= nil, "chrome state pushed at setup")
H.eq(chrome, { native_tabs = false, native_statusbar = true }, "g: vars seed the state")

-- FAITHFULNESS (CONTRACT.md): toggles never touch user options — the user's
-- own statusline/cmdline stay exactly as their config set them.
H.eq(vim.o.laststatus, user_laststatus, "laststatus untouched by native statusbar")
H.eq(vim.o.cmdheight, user_cmdheight, "cmdheight untouched by native statusbar")

vim.cmd("SuperlemonChrome statusbar off")
H.eq(last_notify("superlemon.chrome").native_statusbar, false, "off state pushed")
H.eq(vim.o.laststatus, user_laststatus, "laststatus still untouched after toggling")

-- Same-state set is a no-op (no extra push).
local pushes = #notifies("superlemon.chrome")
require("superlemon.chrome").set("statusbar", false)
H.eq(#notifies("superlemon.chrome"), pushes, "same-state set pushes nothing")

-- Tabs on: immediate buffer seed with the current buffer listed.
local dir = H.tmpdir()
vim.cmd("cd " .. dir)
vim.fn.writefile({ "hello" }, dir .. "/a.txt")
vim.cmd("edit a.txt")
vim.cmd("SuperlemonChrome tabs on")

local bufs = last_notify("superlemon.buffers")
H.ok(bufs ~= nil, "buffers pushed when tabs turn on")
H.eq(bufs.current, vim.api.nvim_get_current_buf(), "current buffer id")
local entry
for _, b in ipairs(bufs.buffers) do
  if b.bufnr == bufs.current then
    entry = b
  end
end
H.eq(entry and entry.name, "a.txt", "cwd-relative buffer name")
H.eq(entry and entry.modified, false, "unmodified flag")

-- Debounce: a burst of buffer events yields one push.
local before = #notifies("superlemon.buffers")
vim.cmd("edit b.txt")
vim.cmd("edit c.txt")
vim.cmd("edit d.txt")
vim.wait(200, function()
  return #notifies("superlemon.buffers") > before
end)
vim.wait(120) -- allow any stragglers to (incorrectly) fire
H.eq(#notifies("superlemon.buffers"), before + 1, "buffer burst debounced to one push")
local names = vim.tbl_map(function(b)
  return b.name
end, last_notify("superlemon.buffers").buffers)
H.ok(vim.tbl_contains(names, "d.txt"), "latest buffer present after debounce")

-- chrome_toggle entry point used by the GUI menu.
require("superlemon").chrome_toggle("tabs")
H.eq(last_notify("superlemon.chrome").native_tabs, false, "chrome_toggle flips tabs off")

-- Re-setup stays idempotent with the chrome module in play.
require("superlemon").setup(1)
H.ok(true, "re-setup with chrome module does not error")

H.finish()
