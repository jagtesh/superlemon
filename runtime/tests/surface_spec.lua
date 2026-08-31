-- surface_spec.lua — generic surface-window mechanics (docs/design/
-- surface-navbar-v1.md §4/§6): window/buffer lifecycle, the projection
-- invariant, WinClosed idempotence, and :mksession safety.
local H = dofile(vim.fs.dirname(arg[0]) .. "/helpers.lua")
H.setup_rtp()

local calls = H.stub_gui()
local surface = require("superlemon.surface")

local function ui_events()
  local out = {}
  for _, c in ipairs(calls.notify) do
    if c.method == "superlemon.ui" then
      table.insert(out, c.args)
    end
  end
  return out
end

local function last_ui()
  local events = ui_events()
  return events[#events]
end

---------------------------------------------------------------------------
-- inert without an active channel: mechanics still work, nothing is sent
---------------------------------------------------------------------------

local inert_closed = 0
local inert = surface.open({
  surface_id = "inert",
  control = "tree",
  filetype = "superlemon-navbar",
  on_event = function() end,
  on_closed = function()
    inert_closed = inert_closed + 1
  end,
})
H.ok(vim.api.nvim_win_is_valid(inert.win), "window mechanics work with no GUI attached")
H.eq(#calls.notify, 0, "no channel: surface.open sends nothing")
surface.close(inert)
H.eq(inert_closed, 1, "on_closed still fires locally without a channel")
H.eq(#calls.notify, 0, "no channel: surface.close sends nothing")

---------------------------------------------------------------------------
-- active GUI from here on
---------------------------------------------------------------------------

require("superlemon").setup(1)

---------------------------------------------------------------------------
-- open(): leftmost full-height fixed-width window, right options, no focus
-- steal, one "surface open" notification with the event callback id
---------------------------------------------------------------------------

local main_win = vim.api.nvim_get_current_win()
local events, closes = {}, 0
local s = surface.open({
  surface_id = "navbar",
  control = "tree",
  filetype = "superlemon-navbar",
  on_event = function(payload)
    table.insert(events, payload)
    return { ok = true }
  end,
  on_closed = function()
    closes = closes + 1
  end,
})

H.ok(vim.api.nvim_win_is_valid(s.win), "surface window is valid")
H.eq(vim.api.nvim_get_current_win(), main_win, "opening the surface does not steal focus")
H.ok(surface.is_leftmost_fullheight(s.win), "surface window is leftmost and full height")
H.eq(vim.api.nvim_win_get_width(s.win), 32, "default width is 32 columns")

H.eq(vim.bo[s.buf].buftype, "nofile", "buftype=nofile")
H.eq(vim.bo[s.buf].bufhidden, "hide", "bufhidden=hide")
H.eq(vim.bo[s.buf].swapfile, false, "noswapfile")
H.eq(vim.bo[s.buf].buflisted, false, "unlisted")
H.eq(vim.bo[s.buf].modifiable, false, "nomodifiable")
H.eq(vim.bo[s.buf].filetype, "superlemon-navbar", "filetype comes from opts")

H.eq(vim.wo[s.win].winfixwidth, true, "winfixwidth")
H.eq(vim.wo[s.win].winfixbuf, true, "winfixbuf")
H.eq(vim.wo[s.win].number, false, "nonumber")
H.eq(vim.wo[s.win].relativenumber, false, "norelativenumber")
H.eq(vim.wo[s.win].signcolumn, "no", "signcolumn=no")
H.eq(vim.wo[s.win].foldcolumn, "0", "foldcolumn=0")
H.eq(vim.wo[s.win].wrap, false, "nowrap")
H.eq(vim.wo[s.win].cursorline, false, "nocursorline")
H.eq(vim.wo[s.win].list, false, "nolist")

H.ok(surface.is_surface_win(s.win), "is_surface_win recognizes the open window")

local open_args = last_ui()
H.eq({ open_args[1], open_args[2], open_args[3] }, { "surface", "open", "navbar" },
  "surface open notification tuple")
H.eq(open_args[4].surface_id, "navbar", "open args carry surface_id")
H.eq(open_args[4].win, s.win, "open args carry the winid")
H.eq(open_args[4].buf, s.buf, "open args carry the bufnr")
H.eq(open_args[4].control, "tree", "open args carry control")
H.ok(type(open_args[4].event_cb) == "number", "open args carry an int event callback id")

-- The callback id round-trips through ui._dispatch exactly like every other
-- superlemon.ui component.
local ui = require("superlemon.ui")
local dispatched = ui._dispatch(open_args[4].event_cb, { event = "refresh" })
H.eq(dispatched, { ok = true }, "event_cb dispatches into on_event")
H.eq(events, { { event = "refresh" } }, "on_event received the payload")

---------------------------------------------------------------------------
-- render(): the projection invariant — lines and rows travel together,
-- atomically, from one call
---------------------------------------------------------------------------

local rows = {
  { id = "/a", label = "a.txt", depth = 0, kind = "file" },
  { id = "/b", label = "b", depth = 0, kind = "dir", expanded = false },
}
local lines = { "a.txt", "b" }
surface.render(s, { seq = 1, header = { title = "root" }, menu = {}, rows = rows }, lines)

H.eq(vim.api.nvim_buf_get_lines(s.buf, 0, -1, false), lines,
  "render writes the exact lines given")
H.eq(vim.bo[s.buf].modifiable, false, "modifiable is toggled back off after the write")

local render_args = last_ui()
H.eq({ render_args[1], render_args[2], render_args[3] }, { "surface", "render", "navbar" },
  "surface render notification tuple")
H.eq(render_args[4].seq, 1, "render seq forwarded")
H.eq(render_args[4].surface_id, "navbar", "render args carry surface_id")
H.eq(#render_args[4].rows, #lines, "notified rows count matches the written line count")

-- seq is monotonic across renders.
surface.render(s, { seq = 2, header = {}, menu = {}, rows = {} }, {})
H.eq(last_ui()[4].seq, 2, "seq is whatever the caller passes (navbar.lua owns monotonicity)")

-- Mismatched lines/rows lengths must never reach the buffer or the wire.
local before_notify_count = #calls.notify
local ok_mismatch = pcall(surface.render, s, { seq = 3, header = {}, menu = {}, rows = { { id = "/x" } } }, {})
H.eq(ok_mismatch, false, "render asserts #lines == #payload.rows")
H.eq(#calls.notify, before_notify_count, "a failed render assertion sends nothing")

---------------------------------------------------------------------------
-- WinClosed fires on_closed exactly once, whether via M.close or :q
---------------------------------------------------------------------------

H.eq(closes, 0, "on_closed not yet fired")
vim.api.nvim_win_close(s.win, true) -- simulates user :q / Ctrl-W o
vim.wait(50)
H.eq(closes, 1, "user-driven close fires on_closed exactly once")
H.ok(not vim.api.nvim_win_is_valid(s.win), "window is gone after user close")
H.ok(not surface.is_surface_win(s.win), "is_surface_win forgets a closed window")

local close_args = last_ui()
H.eq({ close_args[1], close_args[2], close_args[3], close_args[4] },
  { "surface", "close", "navbar", { surface_id = "navbar" } },
  "surface close notification tuple")

-- close() is idempotent: calling it again (as chrome.lua's guarded path
-- might) must not fire on_closed a second time or send a second close.
local notify_count_after_close = #calls.notify
surface.close(s)
H.eq(closes, 1, "calling close() on an already-closed surface is a no-op")
H.eq(#calls.notify, notify_count_after_close, "idempotent close sends nothing more")

---------------------------------------------------------------------------
-- Closing programmatically (M.close, not the user) also fires exactly once
---------------------------------------------------------------------------

local prog_closes = 0
local s2 = surface.open({
  surface_id = "navbar2",
  control = "tree",
  filetype = "superlemon-navbar",
  on_event = function() end,
  on_closed = function()
    prog_closes = prog_closes + 1
  end,
})
surface.close(s2)
H.eq(prog_closes, 1, "M.close fires on_closed exactly once")
H.ok(not vim.api.nvim_win_is_valid(s2.win), "M.close actually closes the window")
surface.close(s2)
H.eq(prog_closes, 1, "second M.close call is a no-op")

---------------------------------------------------------------------------
-- :mksession must not resurrect the projection buffer
---------------------------------------------------------------------------

local sess_surface = surface.open({
  surface_id = "navbar-session",
  control = "tree",
  filetype = "superlemon-navbar",
  on_event = function() end,
  on_closed = function() end,
})
local dir = H.tmpdir()
local sessfile = dir .. "/session.vim"
vim.cmd("mksession! " .. vim.fn.fnameescape(sessfile))
local content = table.concat(vim.fn.readfile(sessfile), "\n")
H.ok(not content:find("superlemon%-navbar", 1, true),
  ":mksession does not reference the navbar buffer's filetype (nofile+unlisted)")
surface.close(sess_surface)

H.finish()
