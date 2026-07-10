-- ui_spec.lua — superlemon.ui component framework (CONTRACT.md
-- "superlemon.ui", DESIGN.md §15): transport tuple shapes, the callback
-- registry/dispatcher lifecycle, and the vim.ui.select/input adapters.
local H = dofile(vim.fs.dirname(arg[0]) .. "/helpers.lua")
H.setup_rtp()

local calls = H.stub_gui()

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

local ui = require("superlemon.ui")

---------------------------------------------------------------------------
-- inert without setup: no channel → send no-ops, nothing errors
---------------------------------------------------------------------------

ui.toast({ text = "hello" })
ui.statusbar.segment("p", { text = "x" })
ui.statusbar.clear("p")
local inert_ns = ui.sidebar.namespace("inert")
inert_ns:set_badge("a.txt", { text = "M" })
inert_ns:set_dot("a.txt", { color = "#FFFFFF" })
inert_ns:clear()
ui.palette.open({ on_query = function()
  return {}
end })
ui.palette.close()
ui.input({ prompt = "?", on_submit = function() end })
H.eq(#calls.notify, 0, "no channel: every send is a silent no-op")
H.eq(ui._dispatch(9999, {}), vim.NIL, "unknown callback id returns vim.NIL without erroring")

---------------------------------------------------------------------------
-- g:superlemon_native_ui = 0 leaves vim.ui.* untouched
---------------------------------------------------------------------------

local stock_select = vim.ui.select
local stock_input = vim.ui.input

vim.g.superlemon_native_ui = 0
require("superlemon").setup(1)
H.ok(vim.ui.select == stock_select, "native_ui=0: vim.ui.select untouched")
H.ok(vim.ui.input == stock_input, "native_ui=0: vim.ui.input untouched")

-- Opt back in: overrides installed over the stock implementations.
vim.g.superlemon_native_ui = nil
ui.setup()
H.ok(vim.ui.select ~= stock_select, "setup installs the vim.ui.select override")
H.ok(vim.ui.input ~= stock_input, "setup installs the vim.ui.input override")
H.ok(ui._orig_select == stock_select, "original vim.ui.select stashed")
H.ok(ui._orig_input == stock_input, "original vim.ui.input stashed")

---------------------------------------------------------------------------
-- sidebar namespaces
---------------------------------------------------------------------------

local git_ns = ui.sidebar.namespace("git")
git_ns:set_badge("Sources/a.swift", { text = "M", color = "#E0B268" })
H.eq(
  last_ui(),
  { "sidebar", "set_badge", "git", { path = "Sources/a.swift", text = "M", color = "#E0B268" } },
  "set_badge sends the 4-tuple"
)

git_ns:set_badge("new.txt", { text = "?" })
H.eq(last_ui()[4], { path = "new.txt", text = "?" }, "badge color is optional")

git_ns:set_dot("Sources", { color = "#ADC694" })
H.eq(
  last_ui(),
  { "sidebar", "set_dot", "git", { path = "Sources", color = "#ADC694" } },
  "set_dot sends the 4-tuple"
)

local lint_ns = ui.sidebar.namespace("lint")
lint_ns:clear()
H.eq(last_ui(), { "sidebar", "clear", "lint", {} }, "clear names only its own namespace")

---------------------------------------------------------------------------
-- palette: registration, dispatch round trip, session lifecycle
---------------------------------------------------------------------------

local queries, selects, closes = {}, {}, 0
ui.palette.open({
  placeholder = "Files…",
  on_query = function(q)
    table.insert(queries, q)
    return { { id = 1, title = "a" }, { id = 3, title = "ab", subtitle = "dir" } }
  end,
  on_select = function(id)
    table.insert(selects, id)
  end,
  on_close = function()
    closes = closes + 1
  end,
})

local ev = last_ui()
H.eq({ ev[1], ev[2], ev[3] }, { "palette", "open", "palette" }, "palette open tuple")
local args = ev[4]
H.eq(args.placeholder, "Files…", "palette placeholder forwarded")
H.ok(
  type(args.query_cb) == "number" and type(args.select_cb) == "number" and type(args.close_cb) == "number",
  "palette open carries int callback ids"
)
H.ok(
  args.query_cb ~= args.select_cb and args.select_cb ~= args.close_cb and args.query_cb ~= args.close_cb,
  "callback ids are distinct"
)

local items = ui._dispatch(args.query_cb, { query = "ab" })
H.eq(queries, { "ab" }, "query payload unwrapped to the query string")
H.eq(
  items,
  { { id = 1, title = "a" }, { id = 3, title = "ab", subtitle = "dir" } },
  "_dispatch returns on_query's items list"
)

ui._dispatch(args.select_cb, { id = 3 })
H.eq(selects, { 3 }, "select payload unwrapped to the id")
H.eq(ui._dispatch(args.query_cb, { query = "x" }), vim.NIL, "select ends the session: ids freed")
H.eq(ui._dispatch(args.close_cb, {}), vim.NIL, "close_cb also freed after select")
H.eq(closes, 0, "on_close not fired by select")

-- GUI-side dismissal fires on_close then frees.
ui.palette.open({
  on_close = function()
    closes = closes + 1
  end,
})
local dismissed = last_ui()[4]
H.eq(ui._dispatch(dismissed.query_cb, {}), {}, "missing on_query yields an empty items list")
ui._dispatch(dismissed.close_cb, {})
H.eq(closes, 1, "GUI dismissal fires on_close")
H.eq(ui._dispatch(dismissed.select_cb, { id = 1 }), vim.NIL, "dismissal frees the session ids")

-- A second open replaces the first session, freeing its ids.
ui.palette.open({ on_query = function(q)
  return { { id = 1, title = "first " .. q } }
end })
local first = last_ui()[4]
ui.palette.open({ on_query = function(q)
  return { { id = 2, title = "second " .. q } }
end })
local second = last_ui()[4]
H.eq(ui._dispatch(first.query_cb, { query = "q" }), vim.NIL, "second open frees the first session's ids")
H.eq(ui._dispatch(second.query_cb, { query = "q" }), { { id = 2, title = "second q" } }, "second session live")

-- Lua-side close sends the tuple and frees.
ui.palette.close()
H.eq(last_ui(), { "palette", "close", "palette", {} }, "palette.close sends close tuple")
H.eq(ui._dispatch(second.query_cb, { query = "q" }), vim.NIL, "palette.close frees the session ids")

-- A crashing callback is contained: _dispatch returns vim.NIL, no error.
ui.palette.open({ on_query = function()
  error("boom")
end })
local crashy = last_ui()[4]
local notify_saved = vim.notify
vim.notify = function() end
H.eq(ui._dispatch(crashy.query_cb, { query = "" }), vim.NIL, "callback errors swallowed → vim.NIL")
vim.notify = notify_saved
ui.palette.close()

---------------------------------------------------------------------------
-- toast / statusbar payload shapes
---------------------------------------------------------------------------

ui.toast({ text = "Build failed", kind = "error" })
H.eq(last_ui(), { "toast", "show", "toast", { text = "Build failed", kind = "error" } }, "toast tuple")

ui.toast({ text = "saved" })
H.eq(last_ui()[4], { text = "saved", kind = "info" }, "toast kind defaults to info")

ui.statusbar.segment("my-plugin", { text = "⚡ 3", color = "#E0B268" })
H.eq(
  last_ui(),
  { "statusbar", "set_segment", "my-plugin", { text = "⚡ 3", color = "#E0B268" } },
  "statusbar segment tuple"
)

ui.statusbar.clear("my-plugin")
H.eq(last_ui(), { "statusbar", "clear", "my-plugin", {} }, "statusbar clear names only its namespace")

---------------------------------------------------------------------------
-- input: round trip, Esc → nil, session lifecycle
---------------------------------------------------------------------------

local submitted = {}
ui.input({
  prompt = "Name: ",
  default = "old",
  on_submit = function(text)
    table.insert(submitted, text == nil and vim.NIL or text)
  end,
})
ev = last_ui()
H.eq({ ev[1], ev[2], ev[3] }, { "input", "open", "input" }, "input open tuple")
H.eq(ev[4].prompt, "Name: ", "input prompt forwarded")
H.eq(ev[4].default, "old", "input default forwarded")
H.ok(type(ev[4].submit_cb) == "number", "input carries an int submit_cb")

ui._dispatch(ev[4].submit_cb, { text = "new" })
H.eq(submitted, { "new" }, "submit delivers the text")
H.eq(ui._dispatch(ev[4].submit_cb, { text = "again" }), vim.NIL, "submit frees the callback id")

ui.input({
  on_submit = function(text)
    table.insert(submitted, text == nil and vim.NIL or text)
  end,
})
ui._dispatch(last_ui()[4].submit_cb, { text = vim.NIL })
H.eq(submitted, { "new", vim.NIL }, "Esc: payload.text vim.NIL → on_submit(nil)")

---------------------------------------------------------------------------
-- vim.ui.select override → palette
---------------------------------------------------------------------------

local choices = {}
vim.ui.select({ "alpha", "beta" }, {
  prompt = "Pick",
  format_item = function(s)
    return s:upper()
  end,
}, function(item, idx)
  table.insert(choices, { item = item, idx = idx })
end)

ev = last_ui()
H.eq({ ev[1], ev[2], ev[3] }, { "palette", "open", "palette" }, "vim.ui.select routes through the palette")
args = ev[4]
H.eq(args.placeholder, "Pick", "opts.prompt becomes the placeholder")

items = ui._dispatch(args.query_cb, { query = "" })
H.eq(
  items,
  { { id = 1, title = "ALPHA" }, { id = 2, title = "BETA" } },
  "empty query lists every item via format_item"
)
items = ui._dispatch(args.query_cb, { query = "bet" })
H.eq(
  items,
  { { id = 2, title = "BETA", positions = { 1, 2, 3 } } },
  "query filters items and marks match positions"
)

ui._dispatch(args.select_cb, { id = 2 })
H.eq(choices, { { item = "beta", idx = 2 } }, "on_choice(item, idx) fired on select")
ui._dispatch(args.close_cb, {})
H.eq(#choices, 1, "on_choice called exactly once (close after select is inert)")

-- Dismissal path: on_choice(nil, nil), exactly once.
local cancel_count, cancel_item, cancel_idx = 0, "sentinel", "sentinel"
vim.ui.select({ 10, 20 }, {}, function(item, idx)
  cancel_count, cancel_item, cancel_idx = cancel_count + 1, item, idx
end)
args = last_ui()[4]
H.eq(
  ui._dispatch(args.query_cb, { query = "" }),
  { { id = 1, title = "10" }, { id = 2, title = "20" } },
  "format_item falls back to tostring"
)
ui._dispatch(args.close_cb, {})
H.eq(cancel_count, 1, "on_choice fired once on close")
H.ok(cancel_item == nil and cancel_idx == nil, "on_choice(nil, nil) on close")
H.eq(ui._dispatch(args.select_cb, { id = 1 }), vim.NIL, "select id freed after close")
H.eq(cancel_count, 1, "no second on_choice after the session ended")

---------------------------------------------------------------------------
-- vim.ui.input override → input
---------------------------------------------------------------------------

local confirmed = "sentinel"
vim.ui.input({ prompt = "Rename: ", default = "a.txt" }, function(text)
  confirmed = text
end)
ev = last_ui()
H.eq({ ev[1], ev[2], ev[3] }, { "input", "open", "input" }, "vim.ui.input routes through input")
H.eq(ev[4].prompt, "Rename: ", "vim.ui.input prompt forwarded")
H.eq(ev[4].default, "a.txt", "vim.ui.input default forwarded")
ui._dispatch(ev[4].submit_cb, { text = "b.txt" })
H.eq(confirmed, "b.txt", "vim.ui.input round trip")

vim.ui.input({ prompt = "?" }, function(text)
  confirmed = text
end)
ui._dispatch(last_ui()[4].submit_cb, { text = vim.NIL })
H.ok(confirmed == nil, "vim.ui.input Esc → on_confirm(nil)")

---------------------------------------------------------------------------
-- setup idempotency + user replacements win
---------------------------------------------------------------------------

local our_select = vim.ui.select
ui.setup()
H.ok(vim.ui.select == our_select, "re-setup keeps our override (idempotent)")

local user_select = function() end
vim.ui.select = user_select
ui.setup()
H.ok(vim.ui.select == user_select, "a user-replaced vim.ui.select is never clobbered")

-- Programmatic palette.close() fires on_close exactly once (the live-test
-- regression: vim.ui.select's on_choice(nil) must run on this path too).
local prog_closed = 0
ui.palette.open({
  on_query = function() return {} end,
  on_select = function() end,
  on_close = function() prog_closed = prog_closed + 1 end,
})
ui.palette.close()
H.eq(prog_closed, 1, "programmatic close fires on_close")
ui.palette.close()
H.eq(prog_closed, 1, "second close is a no-op (exactly once)")

H.finish()
