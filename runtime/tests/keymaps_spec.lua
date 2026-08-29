-- Default <D-...> keymaps: user maps win; font_bump notifies superlemon.font.
local H = dofile(vim.fs.dirname(arg[0]) .. "/helpers.lua")
H.setup_rtp()
local calls = H.stub_gui()

-- User mapping defined BEFORE setup (as user config would be).
vim.keymap.set("n", "<D-s>", "<Cmd>echo 'user-save'<CR>", { desc = "user mapping" })
vim.keymap.set("n", "<ScrollWheelDown>", "<Cmd>echo 'user-scroll'<CR>", { desc = "user mapping" })

-- Opt out of scroll-homing for the FIRST setup() call, so we can prove no
-- default ScrollWheel map gets installed anywhere while it is off.
vim.g.superlemon_scroll_homes_cursor = 0

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

-- superlemon_scroll_homes_cursor=0 installs no default ScrollWheel map at all
-- (in any of the three modes), leaving Neovim's own wheel handling in place.
H.eq(vim.fn.maparg("<ScrollWheelUp>", "n"), "", "opt-out installs no default ScrollWheelUp map (n)")
H.eq(vim.fn.maparg("<ScrollWheelDown>", "x"), "", "opt-out installs no default ScrollWheelDown map (x)")
H.eq(vim.fn.maparg("<ScrollWheelDown>", "i"), "", "opt-out installs no default ScrollWheelDown map (i)")

--- Build a 200-line buffer, taller than the window, with the cursor parked
--- mid-line so wheel-homing (or its absence) is visible in the column.
---@param cursor_col integer
local function make_scroll_buffer(cursor_col)
  vim.cmd("enew!")
  local lines = {}
  for i = 1, 200 do
    lines[i] = ("    call(arg) -- line %d"):format(i)
  end
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim.o.mouse = "a"
  vim.o.mousescroll = "ver:1,hor:1"
  vim.cmd("resize 10")
  vim.api.nvim_win_set_cursor(0, { 8, cursor_col })
end

-- CRITICAL VERIFICATION NOTE: the app delivers wheel events to Neovim via
-- nvim_input_mouse("wheel", "down", ...), not keyboard input. Empirically,
-- nvim_input_mouse (and even plain nvim_input, e.g. for "j") is NEVER
-- processed inside a `nvim --headless -l script.lua` run: per `:help -l`
-- such scripts run "non-interactively (no UI) ... then exits" and never
-- enter the state-machine loop that drains the async input queue — this was
-- confirmed by waiting up to 2s (vim.wait) after nvim_input('j') with a
-- predicate polling the cursor position, which never moved. This is a
-- harness limitation, not evidence about mapping routing: mouse events are
-- ordinary Nvim keys (":help <ScrollWheelDown>"), and nvim_input_mouse's own
-- documented job is to synthesize the same <ScrollWheelDown>/<ScrollWheelUp>
-- keycodes a terminal or GUI's raw scroll would produce, which are then
-- pushed through the identical input/mapping pipeline as any other key —
-- this is why `:noremap <ScrollWheelDown> ...` has always been meaningful in
-- Vim/Neovim. So the synchronously-testable proxy used below is
-- nvim_feedkeys(<termcode>, "x", ...) with that same termcode: it is
-- byte-for-byte what nvim_input_mouse enqueues, and — unlike nvim_input — it
-- runs mapping resolution immediately within the call.
local scroll_down = vim.api.nvim_replace_termcodes("<ScrollWheelDown>", true, false, true)
local scroll_up = vim.api.nvim_replace_termcodes("<ScrollWheelUp>", true, false, true)

-- Opt-out functional check: with no mapping installed, wheel-down still
-- performs Nvim's native scroll (view moves) but leaves the column alone.
make_scroll_buffer(8)
vim.cmd("normal! v")
vim.api.nvim_feedkeys(scroll_down, "x", false)
vim.cmd("normal! \27")
H.eq(vim.api.nvim_win_get_cursor(0)[2], 8, "scroll_homes_cursor=0: column stays at 8")
H.ok(vim.fn.line("w0") > 1, "scroll_homes_cursor=0: the wheel scroll itself still moves the view")

local keymaps = require("superlemon.keymaps")
H.ok(keymaps.installed > 0, "keymaps.installed count > 0")

-- The default save flow delegates an unnamed buffer to the native sheet.
local before_save = #calls.notify
keymaps.save()
H.eq(#calls.notify, before_save + 1, "unnamed save requests native Save As")
H.eq(calls.notify[#calls.notify].method, "superlemon.save_as", "Save As notification method")
H.eq(calls.notify[#calls.notify].chan, 4, "Save As notification channel")

-- Idempotent re-setup keeps our maps and still skips the user's. This is
-- also the first time scroll_homes_cursor is enabled, so it doubles as the
-- "turn the feature on" step for the scroll-homing checks below.
vim.g.superlemon_scroll_homes_cursor = 1
require("superlemon").setup(4)
H.ok(vim.fn.maparg("<D-s>", "n"):find("user%-save") ~= nil, "user map still wins after re-setup")
H.ok(vim.fn.maparg("<D-n>", "n") ~= "", "our defaults survive re-setup")

-- A pre-existing user <ScrollWheelDown> (n) mapping, defined before any
-- setup() call ever ran, is never overridden — same rule as <D-s> above.
H.ok(vim.fn.maparg("<ScrollWheelDown>", "n"):find("user%-scroll") ~= nil,
  "pre-existing user <ScrollWheelDown> (n) mapping preserved")

-- Defaults installed on every other mode/key the user left unmapped.
H.ok(vim.fn.maparg("<ScrollWheelDown>", "x") ~= "", "default ScrollWheelDown installed (visual)")
H.ok(vim.fn.maparg("<ScrollWheelDown>", "i") ~= "", "default ScrollWheelDown installed (insert)")
H.ok(vim.fn.maparg("<ScrollWheelUp>", "n") ~= "", "default ScrollWheelUp installed (normal)")
H.ok(vim.fn.maparg("<ScrollWheelUp>", "x") ~= "", "default ScrollWheelUp installed (visual)")
H.ok(vim.fn.maparg("<ScrollWheelUp>", "i") ~= "", "default ScrollWheelUp installed (insert)")

-- Functional: visual-mode wheel-down scrolls the view AND homes the column.
make_scroll_buffer(8)
vim.cmd("normal! v")
vim.api.nvim_feedkeys(scroll_down, "x", false)
vim.cmd("normal! \27")
H.eq(vim.api.nvim_win_get_cursor(0)[2], 0, "visual-mode wheel-down homes cursor to column 0")
H.ok(vim.fn.line("w0") > 1, "visual-mode wheel-down actually scrolled the view")

-- Functional: normal-mode wheel-up also homes the column (from a scrolled
-- position, so the upward scroll has somewhere to go).
make_scroll_buffer(8)
vim.api.nvim_win_set_cursor(0, { 50, 8 })
vim.cmd("normal! zt")
local line_before_up = vim.fn.line("w0")
vim.api.nvim_feedkeys(scroll_up, "x", false)
H.eq(vim.api.nvim_win_get_cursor(0)[2], 0, "normal-mode wheel-up homes cursor to column 0")
H.ok(vim.fn.line("w0") < line_before_up, "normal-mode wheel-up actually scrolled the view")

-- Functional: insert-mode wheel-down uses <C-o>0 and must not drop out of
-- Insert. A single combined feedkeys batch avoids feedkeys('x')'s own
-- forced Insert->Normal revert between separate calls; typing a literal "X"
-- right after the scroll proves both that the cursor homed to column 0 and
-- that we were still in Insert (an accidental mode exit would make "X"
-- execute as the Normal-mode delete-char command instead of inserting).
make_scroll_buffer(8)
local enter_insert = vim.api.nvim_replace_termcodes("i", true, false, true)
local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
vim.api.nvim_feedkeys(enter_insert .. scroll_down .. "X" .. esc, "x", false)
local scrolled_line = vim.api.nvim_buf_get_lines(0, 7, 8, false)[1]
H.eq(scrolled_line:sub(1, 1), "X",
  "insert-mode wheel-down homed to column 0 before the typed X landed there")
H.eq(vim.api.nvim_win_get_cursor(0)[2], 0,
  "insert-mode wheel-down leaves the cursor at column 0 (Esc stepped back from the X)")

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
