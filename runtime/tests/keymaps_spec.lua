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
-- Keep the navbar window out of this spec: the scroll/cursor scenarios
-- below assert exact cursor rows in a single-window layout.
vim.g.superlemon_native_sidebar = 0

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

--- Build a scroll buffer like make_scroll_buffer, but with custom per-line
--- text (used to exercise column clamping against a short destination
--- line).
---@param line_text fun(i: integer): string
---@param cursor_col integer
local function make_custom_scroll_buffer(line_text, cursor_col)
  vim.cmd("enew!")
  local lines = {}
  for i = 1, 200 do
    lines[i] = line_text(i)
  end
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim.o.mouse = "a"
  vim.o.mousescroll = "ver:1,hor:1"
  vim.cmd("resize 10")
  vim.api.nvim_win_set_cursor(0, { 8, cursor_col })
end

-- Empirically (see the geometry walk this was derived from): starting on
-- line 8 in a freshly (re)opened 10-row window at topline 1, Neovim can
-- satisfy <ScrollWheelDown> by moving only the topline for the first 7
-- steps (line 8 stays inside the growing window); the 8th step is the first
-- one it cannot satisfy without dragging the cursor down to line 9. This is
-- pure row arithmetic, independent of line content or starting column, so
-- every scenario below that starts from make_scroll_buffer(8)/
-- make_custom_scroll_buffer(_, col) shares the same step count.
local NON_DRAG_STEPS = 7

--- Run fn() and count how many times CursorMoved fires during it.
---@param fn fun()
---@return integer
local function count_cursor_moves(fn)
  local moved = 0
  local group = vim.api.nvim_create_augroup("wheel_spec_cursor_moved", { clear = true })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    callback = function() moved = moved + 1 end,
  })
  fn()
  vim.api.nvim_del_augroup_by_id(group)
  return moved
end

-- Every scenario below reuses the same window, so a gesture left in flight
-- by one scenario (e.g. the timer/guard scenarios, which end it in
-- non-standard ways) must not bleed into the next one's "is this a new
-- gesture" check.
local function reset_gesture()
  keymaps.wheel_gesture_end()
end

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

local enter_insert = vim.api.nvim_replace_termcodes("i", true, false, true)
local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
local enter_visual = vim.api.nvim_replace_termcodes("v", true, false, true)

-- Scenarios (a)-(d), (f) and (g) below drive <ScrollWheelDown> in Visual
-- mode rather than Normal: a pre-existing user mapping for
-- <ScrollWheelDown> in Normal mode only (set up at the very top of this
-- spec, and asserted still intact just below) intentionally shadows our
-- default there, so Normal mode never runs wheel_step() in this file.
-- Visual gets the real default mapping and drives the identical
-- wheel_step()/wheel_gesture_end() logic (mode-agnostic), so it exercises
-- the same behavior. (e) uses Insert instead, which is unaffected either
-- way.

-- (a) Steps that never drag the cursor to a new line must not touch the
-- cursor at all: no column change, no CursorMoved firing (the old `0`-every-
-- step behavior fired CursorMoved on every wheel step even when nvim itself
-- never moved the cursor).
make_scroll_buffer(8)
reset_gesture()
vim.api.nvim_feedkeys(enter_visual, "x", false)
local moved_a = count_cursor_moves(function()
  for _ = 1, NON_DRAG_STEPS do
    vim.api.nvim_feedkeys(scroll_down, "x", false)
  end
end)
H.eq(vim.api.nvim_win_get_cursor(0), { 8, 8 }, "non-dragging wheel steps leave the cursor untouched")
H.eq(moved_a, 0, "non-dragging wheel steps fire no CursorMoved")
vim.api.nvim_feedkeys(esc, "x", false)

-- (b)/(c) The step that actually drags the cursor to a new line parks it at
-- column 0 for the rest of the gesture; ending the gesture then restores
-- the remembered column (curswant captured at gesture start), clamped to
-- the dragged-to line's length, and restores curswant itself too (not just
-- the visible column) — checked here against a destination line ("abcde",
-- 5 chars) shorter than the starting curswant (21), so the clamp is real.
local function line_text_short_line9(i)
  if i == 9 then
    return "abcde"
  end
  return ("    call(arg) -- line %d"):format(i)
end
make_custom_scroll_buffer(line_text_short_line9, 20)
reset_gesture()
H.eq(vim.fn.getcurpos()[5], 21, "sanity: curswant captured from the starting column (21 = col 20 + 1)")
vim.api.nvim_feedkeys(enter_visual, "x", false)
for _ = 1, NON_DRAG_STEPS do
  vim.api.nvim_feedkeys(scroll_down, "x", false)
end
H.eq(vim.api.nvim_win_get_cursor(0), { 8, 20 }, "non-dragging steps: cursor still at the starting line/column")
vim.api.nvim_feedkeys(scroll_down, "x", false) -- the dragging step
H.eq(vim.api.nvim_win_get_cursor(0), { 9, 0 }, "the dragging step parks the cursor at column 0 (mid-gesture)")
vim.api.nvim_feedkeys(esc, "x", false)

keymaps.wheel_gesture_end()
H.eq(vim.api.nvim_win_get_cursor(0), { 9, 4 },
  'gesture end clamps the restored column to the dragged-to line\'s length ("abcde", 5 chars)')
H.eq(vim.fn.getcurpos()[5], 21, "gesture end restores curswant itself, not just the visible column")
H.ok(keymaps._gesture() == nil, "gesture is cleared once it ends")

-- (d) `$` before scrolling sets curswant to v:maxcol; ending the gesture
-- restores the cursor to the end of the dragged-to line, and curswant
-- itself back to v:maxcol (not a finite column), so subsequent j/k keep
-- tracking end-of-line the way they would without the scroll.
make_scroll_buffer(8)
reset_gesture()
vim.cmd("normal! $")
H.eq(vim.fn.getcurpos()[5], vim.v.maxcol, "sanity: $ sets curswant to v:maxcol")
vim.api.nvim_feedkeys(enter_visual, "x", false)
for _ = 1, NON_DRAG_STEPS + 1 do
  vim.api.nvim_feedkeys(scroll_down, "x", false)
end
H.eq(vim.api.nvim_win_get_cursor(0), { 9, 0 }, "dragging step parks the cursor at column 0 even from end-of-line")
vim.api.nvim_feedkeys(esc, "x", false)
keymaps.wheel_gesture_end()
local line9_d = vim.api.nvim_buf_get_lines(0, 8, 9, false)[1]
H.eq(vim.api.nvim_win_get_cursor(0), { 9, #line9_d - 1 },
  "gesture end restores to the end of the dragged-to line")
H.eq(vim.fn.getcurpos()[5], vim.v.maxcol, "gesture end restores curswant to v:maxcol, not a finite column")

-- (e) Insert-mode variant. A single combined feedkeys batch avoids
-- feedkeys('x')'s own forced Insert->Normal revert between separate calls,
-- so entering Insert, the dragging steps, the gesture-end call, and the
-- mode capture all run from inside the same batch. Plain `i` from Normal
-- after a `$` resets curswant to the literal column (verified separately),
-- so v:maxcol is set from *inside* Insert instead, via `<C-o>$` (which
-- preserves it on return to Insert) — this exercises Insert's own clamp,
-- one column past the last character, rather than the Normal-mode "last
-- character" clamp already covered by scenario (d).
make_scroll_buffer(8)
reset_gesture()
local line9_before_e = vim.api.nvim_buf_get_lines(0, 8, 9, false)[1]
local ctrlo_dollar = vim.api.nvim_replace_termcodes("<C-o>$", true, false, true)
local capture_mode = vim.api.nvim_replace_termcodes(
  "<Cmd>lua _G.__wheel_spec_mode = vim.fn.mode()<CR>", true, false, true)
local end_gesture_cmd = vim.api.nvim_replace_termcodes(
  "<Cmd>lua require('superlemon.keymaps').wheel_gesture_end()<CR>", true, false, true)
vim.api.nvim_feedkeys(
  enter_insert .. ctrlo_dollar .. scroll_down:rep(NON_DRAG_STEPS + 1) .. capture_mode .. end_gesture_cmd .. "Z" .. esc,
  "x", false)
H.eq(_G.__wheel_spec_mode, "i", "insert-mode wheel steps never leave Insert while dragging")
local line9_after_e = vim.api.nvim_buf_get_lines(0, 8, 9, false)[1]
H.eq(line9_after_e, line9_before_e .. "Z",
  "insert-mode gesture end restores to one past the last character (Insert's own clamp), so Z is appended")

-- (f) Letting the idle timer fire (instead of calling wheel_gesture_end
-- directly) restores the cursor the same way a manual call does. The timer
-- (wheel_gesture_end_ms) must actually be running and must stay well under
-- vim.wait's budget here.
make_scroll_buffer(8)
reset_gesture()
vim.api.nvim_feedkeys(enter_visual, "x", false)
for _ = 1, NON_DRAG_STEPS + 1 do
  vim.api.nvim_feedkeys(scroll_down, "x", false)
end
H.eq(vim.api.nvim_win_get_cursor(0), { 9, 0 }, "timer scenario: still parked at column 0 right after the drag")
H.ok(keymaps._gesture() ~= nil, "timer scenario: gesture still in flight immediately after the drag")
vim.api.nvim_feedkeys(esc, "x", false)
H.ok(vim.wait(200, function() return keymaps._gesture() == nil end),
  "the wheel_gesture_end_ms idle timer fires on its own and clears the gesture")
H.eq(vim.api.nvim_win_get_cursor(0), { 9, 8 }, "timer-driven gesture end restores the remembered column")

-- (g) If something else (a click, an edit) moves the cursor off column 0
-- during the gesture, ending it must not clobber that — "not at column 0
-- anymore" is treated as somebody else having taken over.
make_scroll_buffer(8)
reset_gesture()
vim.api.nvim_feedkeys(enter_visual, "x", false)
for _ = 1, NON_DRAG_STEPS + 1 do
  vim.api.nvim_feedkeys(scroll_down, "x", false)
end
H.eq(vim.api.nvim_win_get_cursor(0), { 9, 0 }, "guard scenario: parked at column 0 before the user moves it")
vim.api.nvim_feedkeys(esc, "x", false)
vim.api.nvim_win_set_cursor(0, { 9, 5 }) -- simulate a user-driven cursor move mid-gesture
keymaps.wheel_gesture_end()
H.eq(vim.api.nvim_win_get_cursor(0), { 9, 5 },
  "gesture end leaves a user-moved cursor alone instead of restoring curswant")
H.ok(keymaps._gesture() == nil, "gesture is still cleared even when the restore itself is skipped")

-- (h) Wheel scrolling still actually scrolls the view (opt-out case) and
-- still respects a pre-existing user mapping (both already covered above:
-- "scroll_homes_cursor=0: the wheel scroll itself still moves the view" and
-- "pre-existing user <ScrollWheelDown> (n) mapping preserved").

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
