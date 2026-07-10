-- superlemon.status payload shape + debounce behavior.
local H = dofile(vim.fs.dirname(arg[0]) .. "/helpers.lua")
H.setup_rtp()
local calls = H.stub_gui()

require("superlemon").setup(9)

local dir = H.tmpdir()
vim.cmd.cd(dir)
vim.fn.writefile({ "one", "two", "three" }, dir .. "/foo.txt")
vim.cmd.edit("foo.txt") -- fires BufEnter → immediate push

local last = calls.notify[#calls.notify]
H.eq(last.method, "superlemon.status", "BufEnter pushes superlemon.status")
H.eq(last.chan, 9, "notification targets channel 9")

local p = last.args[1]
H.eq(p.mode, "n", "mode is raw nvim_get_mode() value")
H.eq(p.file, "foo.txt", "file is relative to cwd")
H.eq(p.modified, false, "modified false on fresh buffer")
H.eq(p.line, 1, "line 1-based")
H.eq(p.col, 1, "col 1-based")
H.eq(p.total_lines, 3, "total_lines")
H.eq(p.branch, "", "branch empty outside a repo")
H.eq(p.project, vim.fs.basename(dir), "project is basename of cwd")

-- Cursor position reflected (via an immediate event).
vim.api.nvim_win_set_cursor(0, { 2, 2 })
vim.api.nvim_exec_autocmds("BufEnter", {})
p = calls.notify[#calls.notify].args[1]
H.eq(p.line, 2, "line follows cursor")
H.eq(p.col, 3, "col is 1-based (API col 2 → payload 3)")

-- Modified flag flips via BufModifiedSet. (nvim does not dispatch
-- BufModifiedSet in a headless -l script context, so we modify the buffer
-- and fire the event explicitly to exercise our handler + payload.)
vim.api.nvim_buf_set_lines(0, 0, 0, false, { "zero" })
vim.api.nvim_exec_autocmds("BufModifiedSet", {})
p = calls.notify[#calls.notify].args[1]
H.eq(p.modified, true, "modified true after edit (BufModifiedSet)")
H.eq(p.total_lines, 4, "total_lines tracks edits")

-- Unnamed buffer → file == "".
vim.cmd.enew()
p = calls.notify[#calls.notify].args[1]
H.eq(p.file, "", 'unnamed buffer reports file == ""')

-- DirChanged pushes and re-reads project.
local dir2 = H.tmpdir()
vim.cmd.cd(dir2)
p = calls.notify[#calls.notify].args[1]
H.eq(p.project, vim.fs.basename(dir2), "DirChanged pushes fresh project")

---------------------------------------------------------------------------
-- Debounce: burst of CursorMoved → exactly one push, ~100ms later.
---------------------------------------------------------------------------

-- Drain any pending debounce timer from the activity above.
vim.wait(250, function() return false end)

local before = #calls.notify
vim.api.nvim_exec_autocmds("CursorMoved", {})
vim.api.nvim_exec_autocmds("CursorMoved", {})
vim.api.nvim_exec_autocmds("CursorMovedI", {})
H.eq(#calls.notify, before, "cursor events do not push immediately")

vim.wait(1000, function() return #calls.notify > before end)
H.eq(#calls.notify, before + 1, "burst of cursor events yields exactly one push")

-- And nothing else trickles in afterwards.
vim.wait(250, function() return #calls.notify > before + 1 end)
H.eq(#calls.notify, before + 1, "no stray second push after debounce window")

-- Each new event resets the single timer: event, wait 50ms (< debounce),
-- event again → still only one push total.
local base2 = #calls.notify
vim.api.nvim_exec_autocmds("CursorMoved", {})
vim.wait(50, function() return false end)
vim.api.nvim_exec_autocmds("CursorMoved", {})
vim.wait(1000, function() return #calls.notify > base2 end)
vim.wait(250, function() return #calls.notify > base2 + 1 end)
H.eq(#calls.notify, base2 + 1, "timer resets on each event (one push for spaced burst)")

H.finish()
