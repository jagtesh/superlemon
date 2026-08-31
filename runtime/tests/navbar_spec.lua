-- navbar_spec.lua — the surface-mode file tree model, projection, mappings,
-- file ops, and decoration/chrome plumbing (docs/design/surface-navbar-v1.md
-- §4/§5/§6). Uses real temp directories; never the repo's own tree.
local H = dofile(vim.fs.dirname(arg[0]) .. "/helpers.lua")
H.setup_rtp()

local calls = H.stub_gui()

-- git.lua's refresh runs `git` via vim.system; stub it exactly like
-- git_spec.lua so navbar's git-badge merge can be driven synchronously.
local real_system = vim.system
local pending_git_callback
vim.system = function(_, _, callback)
  pending_git_callback = callback
  return {}
end

require("superlemon").setup(1)

local navbar = require("superlemon.navbar")
local ui = require("superlemon.ui")
local chrome = require("superlemon.chrome")
local git = require("superlemon.git")

local function surface_events(method)
  local out = {}
  for _, c in ipairs(calls.notify) do
    if c.method == "superlemon.ui" and c.args[1] == "surface" and c.args[2] == method then
      table.insert(out, c.args[4])
    end
  end
  return out
end
local function last_render()
  local list = surface_events("render")
  return list[#list]
end
local function last_open()
  local list = surface_events("open")
  return list[#list]
end
local function last_close()
  local list = surface_events("close")
  return list[#list]
end

local function row_by_label(rows, label)
  for _, row in ipairs(rows) do
    if row.label == label then
      return row
    end
  end
  return nil
end

local function wait_for_row(label, predicate)
  vim.wait(1500, function()
    local render = last_render()
    if not render then
      return false
    end
    local row = row_by_label(render.rows, label)
    if not row then
      return false
    end
    return predicate == nil or predicate(row)
  end)
end

---------------------------------------------------------------------------
-- Remote sessions: the menu offers ONLY "cd" (§6)
---------------------------------------------------------------------------

do
  local dir = H.tmpdir()
  vim.fn.mkdir(dir .. "/sub", "p")
  vim.cmd("cd " .. vim.fn.fnameescape(dir))
  local group = vim.api.nvim_create_augroup("navbar_test_remote", { clear = true })
  navbar.setup(group, { remote = true })

  local render = last_render()
  H.ok(render ~= nil, "remote setup renders immediately")
  H.eq(render.menu, {
    { id = "cd", title = "Change Working Directory", for_kinds = { "dir", "up" } },
  }, "remote sessions only offer the cd menu item")

  navbar.set_open(false) -- tear down before the main scenario re-roots
end

---------------------------------------------------------------------------
-- Main scenario: a real directory tree
---------------------------------------------------------------------------

local root = H.tmpdir()
vim.fn.mkdir(root .. "/zdir", "p")
vim.fn.mkdir(root .. "/Adir", "p")
vim.fn.mkdir(root .. "/noperm", "p")
vim.fn.writefile({ "1" }, root .. "/bravo.txt")
vim.fn.writefile({ "1" }, root .. "/Alpha.txt")
vim.fn.writefile({ "1" }, root .. "/zdir/inner.txt")
vim.fn.writefile({ "1" }, root .. "/noperm/secret.txt")

local main_win = vim.api.nvim_get_current_win()
vim.cmd("cd " .. vim.fn.fnameescape(root))

local group = vim.api.nvim_create_augroup("navbar_test_main", { clear = true })
navbar.setup(group, { remote = false })

local function root_loaded()
  local r = last_render()
  if not r then
    return false
  end
  for _, row in ipairs(r.rows) do
    if row.depth == 0 and row.kind == "loading" then
      return false
    end
  end
  return true
end
vim.wait(1500, root_loaded)

local render = last_render()
local open_args = last_open()

H.eq(open_args.control, "tree", "navbar surface control is \"tree\"")
H.eq(render.header, { title = vim.fs.basename(root) }, "header title is the root basename")
H.eq(render.rows[1].kind, "up", "the up row leads when root has a parent")

local labels = {}
for i = 2, #render.rows do
  labels[#labels + 1] = render.rows[i].label
end
H.eq(labels, { "Adir", "noperm", "zdir", "Alpha.txt", "bravo.txt" },
  "dirs first, then case-insensitive by name")

---------------------------------------------------------------------------
-- Projection invariant: buffer lines == rows, always
---------------------------------------------------------------------------

local lines = vim.api.nvim_buf_get_lines(open_args.buf, 0, -1, false)
H.eq(#lines, #render.rows, "buffer line count matches rows count")
for i, row in ipairs(render.rows) do
  H.eq(lines[i], string.rep("  ", row.depth) .. row.label,
    "line " .. i .. " is the indented label for its row")
end

---------------------------------------------------------------------------
-- Lazy expand: collapsed dir shows no children until toggled
---------------------------------------------------------------------------

local zdir_row = row_by_label(render.rows, "zdir")
H.ok(zdir_row ~= nil, "zdir row exists")
H.eq(zdir_row.expanded, false, "zdir starts collapsed")
H.ok(row_by_label(render.rows, "inner.txt") == nil, "collapsed dir's child is not rendered")

ui._dispatch(open_args.event_cb, { event = "toggle", id = zdir_row.id })
wait_for_row("inner.txt")

local expanded_render = last_render()
local inner_row = row_by_label(expanded_render.rows, "inner.txt")
H.ok(inner_row ~= nil, "toggling a dir lazily loads and shows its children")
H.eq(inner_row.depth, 1, "child depth is one more than its parent")
H.eq(row_by_label(expanded_render.rows, "zdir").expanded, true, "zdir now reports expanded=true")

---------------------------------------------------------------------------
-- Failed placeholder + retry (§5/§10 checklist item 1)
---------------------------------------------------------------------------

local noperm = root .. "/noperm"
local noperm_row = row_by_label(expanded_render.rows, "noperm")
vim.uv.fs_chmod(noperm, tonumber("000", 8))
ui._dispatch(open_args.event_cb, { event = "toggle", id = noperm_row.id })

vim.wait(1500, function()
  local r = last_render()
  for _, row in ipairs(r.rows) do
    if row.kind == "failed" then
      return true
    end
  end
  return false
end)
local failed_render = last_render()
local failed_row
for _, row in ipairs(failed_render.rows) do
  if row.kind == "failed" then
    failed_row = row
  end
end
H.ok(failed_row ~= nil, "an unreadable expanded directory renders a failed placeholder")

-- Activating the failed row retries the load.
vim.uv.fs_chmod(noperm, tonumber("755", 8))
ui._dispatch(open_args.event_cb, { event = "open", id = failed_row.id })
wait_for_row("secret.txt")
H.ok(row_by_label(last_render().rows, "secret.txt") ~= nil,
  "activating the failed row retries and loads once permission is restored")

---------------------------------------------------------------------------
-- Mapping dispatch: real keystrokes in the real navbar window
---------------------------------------------------------------------------

local nav_win = open_args.win

-- <CR> on a file: opens it AND moves focus into the editor window
-- (NerdTree-style keyboard-open behavior, §4).
local pre_cr_render = last_render()
local alpha_line
for i, row in ipairs(pre_cr_render.rows) do
  if row.label == "Alpha.txt" then
    alpha_line = i
  end
end
vim.api.nvim_set_current_win(nav_win)
vim.api.nvim_win_set_cursor(nav_win, { alpha_line, 0 })
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)

H.eq(vim.api.nvim_get_current_win(), main_win,
  "<CR> on a file moves focus to the last-used editor window")
H.eq(vim.api.nvim_buf_get_name(0), root .. "/Alpha.txt",
  "<CR> opened the file under the cursor")

-- GUI-originated "open" (a click): current window is already the editor,
-- so focus must NOT move.
local alpha_id = row_by_label(pre_cr_render.rows, "Alpha.txt").id
vim.api.nvim_set_current_win(main_win)
ui._dispatch(open_args.event_cb, { event = "open", id = alpha_id, permanent = false })
H.eq(vim.api.nvim_get_current_win(), main_win,
  "a GUI open event never moves focus out of the current editor window")

---------------------------------------------------------------------------
-- Rename: validation, success, and post-success selection
---------------------------------------------------------------------------

H.eq(
  ui._dispatch(open_args.event_cb, { event = "rename", id = alpha_id, name = "" }),
  { error = "Name cannot be empty" },
  "rename rejects an empty name"
)
H.eq(
  ui._dispatch(open_args.event_cb, { event = "rename", id = alpha_id, name = "a/b" }),
  { error = "Name cannot contain \"/\"" },
  "rename rejects a name containing '/'"
)
H.eq(
  ui._dispatch(open_args.event_cb, { event = "rename", id = alpha_id, name = "bravo.txt" }),
  { error = "\"bravo.txt\" already exists" },
  "rename rejects a colliding target"
)

local rename_result = ui._dispatch(open_args.event_cb, { event = "rename", id = alpha_id, name = "Renamed.txt" })
H.eq(rename_result, { ok = true }, "a valid rename succeeds")
H.ok(vim.uv.fs_stat(root .. "/Renamed.txt") ~= nil, "the file exists under its new name")
H.ok(vim.uv.fs_stat(root .. "/Alpha.txt") == nil, "the old name is gone")

wait_for_row("Renamed.txt")
local renamed_row = row_by_label(last_render().rows, "Renamed.txt")
local cursor_line = vim.api.nvim_win_get_cursor(nav_win)[1]
H.eq(last_render().rows[cursor_line].id, renamed_row.id,
  "the navbar cursor selects the renamed row once it exists (cursor is the selection channel)"
)

---------------------------------------------------------------------------
-- Create: validation, success, and post-success selection
---------------------------------------------------------------------------

H.eq(
  ui._dispatch(open_args.event_cb, { event = "create", dir = root, kind = "file", name = "" }),
  { error = "Name cannot be empty" },
  "create rejects an empty name"
)

local create_result = ui._dispatch(
  open_args.event_cb, { event = "create", dir = root, kind = "file", name = "New.txt" }
)
H.eq(create_result, { ok = true, path = root .. "/New.txt" }, "creating a file succeeds")
H.ok(vim.uv.fs_stat(root .. "/New.txt") ~= nil, "the new file exists on disk")

H.eq(
  ui._dispatch(open_args.event_cb, { event = "create", dir = root, kind = "file", name = "New.txt" }),
  { error = "\"New.txt\" already exists" },
  "create rejects a colliding target"
)

local create_folder_result = ui._dispatch(
  open_args.event_cb, { event = "create", dir = root, kind = "folder", name = "NewDir" }
)
H.eq(create_folder_result.ok, true, "creating a folder succeeds")
local stat = vim.uv.fs_stat(root .. "/NewDir")
H.ok(stat ~= nil and stat.type == "directory", "the new folder exists on disk")

wait_for_row("New.txt")
H.ok(row_by_label(last_render().rows, "New.txt") ~= nil, "created file appears in the tree")

---------------------------------------------------------------------------
-- Menu: new_file/new_folder/rename are silently ignored (GUI drives them);
-- reveal/delete/cd act; remote-only ops never touch the filesystem locally
---------------------------------------------------------------------------

local reveal_id = row_by_label(last_render().rows, "bravo.txt").id
ui._dispatch(open_args.event_cb, { event = "menu", id = reveal_id, item = "reveal" })
local reveal_notify
for _, c in ipairs(calls.notify) do
  if c.method == "superlemon.ui" and c.args[1] == "host" and c.args[2] == "reveal" then
    reveal_notify = c.args[4]
  end
end
H.eq(reveal_notify, { path = root .. "/bravo.txt" }, "menu reveal sends (host, reveal, {path})")

local before_menu_notify_count = #calls.notify
ui._dispatch(open_args.event_cb, { event = "menu", id = reveal_id, item = "new_file" })
ui._dispatch(open_args.event_cb, { event = "menu", id = reveal_id, item = "new_folder" })
ui._dispatch(open_args.event_cb, { event = "menu", id = reveal_id, item = "rename" })
H.eq(#calls.notify, before_menu_notify_count,
  "new_file/new_folder/rename menu items are no-ops here (the GUI drives them inline)")

---------------------------------------------------------------------------
-- Git badge merge (rel-cwd paths; dirty-ancestor dots)
---------------------------------------------------------------------------

git.refresh()
pending_git_callback({ code = 0, stdout = " M Alpha.txt\0 M zdir/inner.txt\0" })
-- Alpha.txt no longer exists (renamed above) but the porcelain path is
-- exactly what git.lua would report for whatever is dirty; use zdir/inner
-- (still present) as the durable assertion target, and bravo.txt for a
-- top-level badge.
wait_for_row("inner.txt", function(row)
  return row.badge ~= nil
end)

local git_render = last_render()
local inner = row_by_label(git_render.rows, "inner.txt")
H.eq(inner.badge, { text = "M", color = "#E0B268" }, "git badge merged onto the dirty file's row")
local zdir_after_git = row_by_label(git_render.rows, "zdir")
H.eq(zdir_after_git.dot, "#E0B268", "a dirty descendant marks its ancestor directory with a dot")

---------------------------------------------------------------------------
-- Decoration namespace merge (sorted by name, later wins; plugin > git)
---------------------------------------------------------------------------

local rel_inner = "zdir/inner.txt"
local ns_a = ui.sidebar.namespace("aaa")
local ns_z = ui.sidebar.namespace("zzz")
ns_a:set_badge(rel_inner, { text = "A", color = "#111111" })
ns_z:set_badge(rel_inner, { text = "Z", color = "#222222" })

vim.wait(1500, function()
  local row = row_by_label(last_render().rows, "inner.txt")
  return row and row.badge and row.badge.text == "Z"
end)
H.eq(row_by_label(last_render().rows, "inner.txt").badge, { text = "Z", color = "#222222" },
  "later (sorted) namespace wins over an earlier one for the same path")

ns_z:clear()
vim.wait(1500, function()
  local row = row_by_label(last_render().rows, "inner.txt")
  return row and row.badge and row.badge.text == "A"
end)
H.eq(row_by_label(last_render().rows, "inner.txt").badge, { text = "A", color = "#111111" },
  "clearing the winning namespace reveals the next one"
)

ns_a:clear()
vim.wait(1500, function()
  local row = row_by_label(last_render().rows, "inner.txt")
  return row and row.badge and row.badge.text == "M"
end)
H.eq(row_by_label(last_render().rows, "inner.txt").badge, { text = "M", color = "#E0B268" },
  "clearing every plugin namespace falls back to the git badge underneath"
)

---------------------------------------------------------------------------
-- Chrome sidebar delegation + recursion guard (§3/§10 checklist item 10)
---------------------------------------------------------------------------

H.eq(chrome.state().native_sidebar, true, "sidebar starts open (native_sidebar default)")

chrome.set("sidebar", false)
H.eq(chrome.state().native_sidebar, false, "chrome.set(sidebar,false) updates chrome state")
H.eq(last_close(), { surface_id = "navbar" }, "chrome.set(sidebar,false) closes the navbar window")

local before_reopen = #surface_events("open")
chrome.set("sidebar", true)
H.eq(#surface_events("open"), before_reopen + 1, "chrome.set(sidebar,true) reopens the navbar window")
local reopened = last_open()

-- User-driven close (:q / Ctrl-W o) must flip chrome state back WITHOUT
-- recursing infinitely through chrome.set <-> navbar.set_open.
vim.api.nvim_win_close(reopened.win, true)
vim.wait(200)
H.eq(chrome.state().native_sidebar, false,
  "closing the navbar window (as the user would) flips chrome's sidebar state off")
H.eq(last_close(), { surface_id = "navbar" }, "the user-driven close still sends the close notification")

vim.system = real_system
---------------------------------------------------------------------------
-- Re-rooting puts the cursor back on the top row
---------------------------------------------------------------------------

-- The chrome section above ends with the navbar closed (user-driven close
-- scenario); reopen and use the LATEST open payload's window.
require("superlemon.chrome").set("sidebar", true)
local reopened = last_open()
H.ok(vim.api.nvim_win_is_valid(reopened.win), "navbar reopened for the cursor scenario")
vim.api.nvim_win_set_cursor(reopened.win, { 4, 0 })
vim.cmd("cd " .. vim.fn.fnameescape(root .. "/zdir"))
wait_for_row("inner.txt", function(row)
  return row.depth == 0 -- depth 0 only once zdir IS the root
end)
H.eq(
  vim.api.nvim_win_get_cursor(reopened.win)[1],
  1,
  "cd re-roots the tree with the cursor on the top row"
)
vim.cmd("cd " .. vim.fn.fnameescape(root))

H.finish()
