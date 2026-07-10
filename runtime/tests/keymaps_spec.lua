-- Default <D-...> keymaps: user maps win; font_bump notifies superlemon.font.
local H = dofile(vim.fs.dirname(arg[0]) .. "/helpers.lua")
H.setup_rtp()
local calls = H.stub_gui()

-- User mapping defined BEFORE setup (as user config would be).
vim.keymap.set("n", "<D-s>", "<Cmd>echo 'user-save'<CR>", { desc = "user mapping" })

require("superlemon").setup(4)

-- The user's map survived.
local user_map = vim.fn.maparg("<D-s>", "n")
H.ok(user_map:find("user%-save") ~= nil, "pre-existing user <D-s> (n) mapping preserved")

-- Defaults installed where the user had nothing.
H.ok(vim.fn.maparg("<D-s>", "i") ~= "", "default <D-s> installed in insert mode")
H.ok(vim.fn.maparg("<D-a>", "n") ~= "", "default <D-a> installed")
H.ok(vim.fn.maparg("<D-c>", "x") ~= "", "default <D-c> installed (visual)")
H.ok(vim.fn.maparg("<D-x>", "x") ~= "", "default <D-x> installed (visual)")
H.ok(vim.fn.maparg("<D-z>", "n") ~= "", "default <D-z> installed")
H.ok(vim.fn.maparg("<D-S-z>", "n") ~= "", "default <D-S-z> installed")
H.ok(vim.fn.maparg("<D-n>", "n") ~= "", "default <D-n> installed")
H.ok(vim.fn.maparg("<D-=>", "n") ~= "", "default <D-=> installed")
H.ok(vim.fn.maparg("<D-->", "n") ~= "", "default <D--> installed")
H.ok(vim.fn.maparg("<D-0>", "n") ~= "", "default <D-0> installed")

local keymaps = require("superlemon.keymaps")
H.ok(keymaps.installed > 0, "keymaps.installed count > 0")

-- Idempotent re-setup keeps our maps and still skips the user's.
require("superlemon").setup(4)
H.ok(vim.fn.maparg("<D-s>", "n"):find("user%-save") ~= nil, "user map still wins after re-setup")
H.ok(vim.fn.maparg("<D-n>", "n") ~= "", "our defaults survive re-setup")

-- font_bump → rpcnotify superlemon.font {delta=n}
local before = #calls.notify
keymaps.font_bump(1)
keymaps.font_bump(-1)
keymaps.font_bump(0)
H.eq(#calls.notify, before + 3, "font_bump notifies each call")
H.eq(calls.notify[before + 1].method, "superlemon.font", "font notify method")
H.eq(calls.notify[before + 1].chan, 4, "font notify channel")
H.eq(calls.notify[before + 1].args[1], { delta = 1 }, "font_bump(1) payload")
H.eq(calls.notify[before + 2].args[1], { delta = -1 }, "font_bump(-1) payload")
H.eq(calls.notify[before + 3].args[1], { delta = 0 }, "font_bump(0) payload")

-- The <D-=> mapping actually triggers font_bump when invoked.
local before_map = #calls.notify
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<D-=>", true, false, true), "x", false)
H.eq(#calls.notify, before_map + 1, "<D-=> mapping fires font_bump")
H.eq(calls.notify[#calls.notify].args[1], { delta = 1 }, "<D-=> sends {delta=1}")

H.finish()
