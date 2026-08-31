-- superlemon.ui — the component framework (CONTRACT.md "superlemon.ui",
-- DESIGN.md §15). The public API ANY nvim plugin uses to drive Superlemon's
-- native macOS components: sidebar decorations, the command palette, toasts,
-- statusbar segments and the input prompt.
--
-- Wire shape (nvim → GUI): one generic notification
--   vim.rpcnotify(chan, "superlemon.ui", component, method, namespace, args)
-- Callbacks (GUI → nvim): Lua functions live in a registry keyed by int id;
-- the GUI invokes them via a blocking
--   nvim_exec_lua("return require('superlemon.ui')._dispatch(...)", {id, payload})
--
-- Everything no-ops silently when the GUI is not attached, so plugins may
-- call this API unconditionally under plain terminal nvim.

local M = {}

local function active()
  return require("superlemon").active()
end

--- Fire one `superlemon.ui` notification. Args is always a map; pass
--- vim.empty_dict() for "no args" so msgpack encodes {} as a map, not a list.
---@param component string
---@param method string
---@param ns string namespace (isolates plugins from each other)
---@param args table map of method arguments
local function send(component, method, ns, args)
  if not active() then
    return
  end
  vim.rpcnotify(vim.g.superlemon_channel, "superlemon.ui", component, method, ns, args)
end

---------------------------------------------------------------------------
-- callback registry
---------------------------------------------------------------------------

-- Monotonically increasing ids → functions. Ids are never reused within a
-- session, so a stale id held by the GUI after a close can only miss (and
-- get vim.NIL back), never hit the wrong callback.
local registry = {}
local next_id = 0

---@param fn function
---@return integer id
local function register(fn)
  next_id = next_id + 1
  registry[next_id] = fn
  return next_id
end

--- Mint a callback id in this module's shared registry — surface.lua uses
--- this so surface events flow through the same blocking `_dispatch` path
--- as every other `superlemon.ui` component.
---@param fn function
---@return integer id
function M._register(fn)
  return register(fn)
end

-- Components with open/close lifecycles (palette, input) group their ids
-- into a session; the session's ids are freed together when it ends —
-- close/select/submit, or a new open replacing it.
local sessions = { palette = nil, input = nil }
-- The active palette's close handler (fires on_close + frees), kept so a
-- PROGRAMMATIC M.palette.close() honors vim.ui.select's exactly-once
-- on_choice contract — the GUI's own close round-trip would otherwise hit
-- already-freed ids.
local palette_close_fn = nil

---@param component '"palette"'|'"input"'
local function free_session(component)
  local ids = sessions[component]
  if component == "palette" then
    palette_close_fn = nil
  end
  if ids then
    sessions[component] = nil
    for _, id in ipairs(ids) do
      registry[id] = nil
    end
  end
end

--- Entry point the GUI calls (blocking nvim_exec_lua). Returns the
--- callback's result — for query callbacks the GUI awaits the items list.
--- Unknown ids (freed session, stale GUI state) return vim.NIL without
--- erroring; callback errors are reported and swallowed so the GUI's
--- blocking request never fails.
---@param id integer callback id
---@param payload any
---@return any
function M._dispatch(id, payload)
  local fn = registry[id]
  if not fn then
    return vim.NIL
  end
  local ok, result = pcall(fn, payload)
  if not ok then
    vim.notify("superlemon.ui callback error: " .. tostring(result), vim.log.levels.ERROR)
    return vim.NIL
  end
  if result == nil then
    return vim.NIL
  end
  return result
end

---------------------------------------------------------------------------
-- sidebar — namespaced file decorations
---------------------------------------------------------------------------

local Namespace = {}
Namespace.__index = Namespace

--- Badge on a file/dir row. `opts.text` required, `opts.color` "#RRGGBB".
--- Decorations live in the navbar model (docs/design/surface-navbar-v1.md
--- §5): the merge happens in navbar.lua and reaches the GUI inside the
--- tree render, not as a separate notification.
---@param path string cwd-relative path
---@param opts { text: string, color?: string }
function Namespace:set_badge(path, opts)
  require("superlemon.navbar").decorations(self.name, "set_badge", {
    path = path,
    text = opts.text,
    color = opts.color,
  })
end

--- Colored dot on a file/dir row.
---@param path string cwd-relative path
---@param opts { color: string }
function Namespace:set_dot(path, opts)
  require("superlemon.navbar").decorations(self.name, "set_dot", { path = path, color = opts.color })
end

--- Remove every decoration in THIS namespace; other namespaces untouched.
function Namespace:clear()
  require("superlemon.navbar").decorations(self.name, "clear", {})
end

M.sidebar = {}

--- Claim a decoration namespace (conventionally the plugin's name). The GUI
--- merges namespaces deterministically (sorted by name).
---@param name string
---@return table ns with :set_badge / :set_dot / :clear
function M.sidebar.namespace(name)
  return setmetatable({ name = name }, Namespace)
end

---------------------------------------------------------------------------
-- palette — the generic fuzzy-picker component (⌘P is just one user)
---------------------------------------------------------------------------

M.palette = {}

--- Open the native palette. Replaces any palette already open (the previous
--- session's callback ids are freed first).
---
--- on_query(query:string) → items list of
---   { id, title, subtitle?, positions? }  (positions: 1-based indices into
---   title, rendered bold). on_select(id) fire-and-forget; on_close() when
--- the palette is dismissed without a selection. select/close both end the
--- session and free its ids.
---@param opts { placeholder?: string, on_query: fun(query: string): table, on_select?: fun(id: any), on_close?: fun() }
function M.palette.open(opts)
  opts = opts or {}
  free_session("palette")

  local ids = {}
  local function reg(fn)
    local id = register(fn)
    table.insert(ids, id)
    return id
  end

  local query_cb = reg(function(payload)
    local query = payload and payload.query
    if query == nil or query == vim.NIL then
      query = ""
    end
    local items = opts.on_query and opts.on_query(query)
    return items or {}
  end)

  local select_cb = reg(function(payload)
    local on_select = opts.on_select
    free_session("palette") -- before the callback, so it may re-open freely
    if on_select then
      on_select(payload and payload.id)
    end
  end)

  local close_fn = function()
    local on_close = opts.on_close
    free_session("palette")
    if on_close then
      on_close()
    end
  end
  local close_cb = reg(close_fn)

  sessions.palette = ids
  palette_close_fn = close_fn
  send("palette", "open", "palette", {
    placeholder = opts.placeholder,
    query_cb = query_cb,
    select_cb = select_cb,
    close_cb = close_cb,
  })
end

--- Close the palette from the Lua side. Fires the session's close handler
--- (so on_close / vim.ui.select's on_choice(nil) run exactly once), frees
--- the ids, and dismisses the GUI panel.
function M.palette.close()
  local fn = palette_close_fn
  if fn then
    fn() -- frees the session and clears palette_close_fn via free_session
  else
    free_session("palette")
  end
  send("palette", "close", "palette", vim.empty_dict())
end

---------------------------------------------------------------------------
-- toast
---------------------------------------------------------------------------

--- Transient message toast.
---@param opts { text: string, kind?: '"info"'|'"warn"'|'"error"' }
function M.toast(opts)
  send("toast", "show", "toast", {
    text = opts.text,
    kind = opts.kind or "info",
  })
end

---------------------------------------------------------------------------
-- statusbar — plugin-owned segments in the native bar
---------------------------------------------------------------------------

M.statusbar = {}

--- Set (create or replace) this namespace's segment.
---@param ns string namespace (conventionally the plugin's name)
---@param opts { text: string, color?: string }
function M.statusbar.segment(ns, opts)
  send("statusbar", "set_segment", ns, { text = opts.text, color = opts.color })
end

--- Remove this namespace's segment; other namespaces untouched.
---@param ns string
function M.statusbar.clear(ns)
  send("statusbar", "clear", ns, vim.empty_dict())
end

---------------------------------------------------------------------------
-- input — native single-line prompt
---------------------------------------------------------------------------

--- Open the native input prompt. Enter → on_submit(text), Esc →
--- on_submit(nil). Replaces any input already open. The submit callback
--- ends the session and frees its id.
---@param opts { prompt?: string, default?: string, on_submit: fun(text: string|nil) }
function M.input(opts)
  opts = opts or {}
  free_session("input")

  local submit_cb = register(function(payload)
    local on_submit = opts.on_submit
    free_session("input")
    local text = payload and payload.text
    if text == vim.NIL then
      text = nil -- Esc: the GUI sends vim.NIL over msgpack
    end
    if on_submit then
      on_submit(text)
    end
  end)

  sessions.input = { submit_cb }
  send("input", "open", "input", {
    prompt = opts.prompt,
    default = opts.default,
    submit_cb = submit_cb,
  })
end

---------------------------------------------------------------------------
-- vim.ui.select / vim.ui.input adapters
---------------------------------------------------------------------------

--- Case-insensitive substring filter over the formatted items; positions
--- mark the matched span for bold rendering. Item ids are the ORIGINAL
--- indices into `items`, so selection maps back regardless of filtering.
local function select_items(items, format_item, query)
  local q = (query or ""):lower()
  local out = {}
  for i, item in ipairs(items) do
    local title = format_item(item)
    if q == "" then
      table.insert(out, { id = i, title = title })
    else
      local s, e = title:lower():find(q, 1, true)
      if s then
        local positions = {}
        for p = s, e do
          table.insert(positions, p)
        end
        table.insert(out, { id = i, title = title, positions = positions })
      end
    end
  end
  return out
end

--- vim.ui.select routed through the native palette. Calls on_choice exactly
--- once: (item, idx) on selection, (nil, nil) on dismissal.
local function select_override(items, opts, on_choice)
  opts = opts or {}
  local format_item = opts.format_item or tostring

  local done = false
  local function choose(item, idx)
    if done then
      return
    end
    done = true
    on_choice(item, idx)
  end

  M.palette.open({
    placeholder = opts.prompt,
    on_query = function(query)
      return select_items(items, format_item, query)
    end,
    on_select = function(id)
      choose(items[id], id)
    end,
    on_close = function()
      choose(nil, nil)
    end,
  })
end

--- vim.ui.input routed through the native prompt. on_confirm(nil) on Esc,
--- matching the built-in's abort semantics.
local function input_override(opts, on_confirm)
  opts = opts or {}
  M.input({
    prompt = opts.prompt,
    default = opts.default,
    on_submit = on_confirm,
  })
end

--- True when `fn` is (as far as we can tell) nvim's stock implementation
--- from runtime/lua/vim/ui.lua. When debug info is unavailable we treat it
--- as stock — "if in doubt, override and stash the original".
---@param fn function
---@return boolean
local function is_stock(fn)
  if type(fn) ~= "function" then
    return true
  end
  local ok, info = pcall(debug.getinfo, fn, "S")
  if not ok or type(info) ~= "table" or type(info.source) ~= "string" then
    return true
  end
  return info.source:find("vim/ui.lua", 1, true) ~= nil
end

--- Install the vim.ui.select / vim.ui.input overrides. Idempotent (our own
--- override is recognized and left alone). Skipped entirely with
--- g:superlemon_native_ui = 0, and per-function when the user's config has
--- already replaced the built-in — their picker wins.
function M.setup()
  if vim.g.superlemon_native_ui == 0 or vim.g.superlemon_native_ui == false then
    return
  end

  if vim.ui.select ~= select_override and is_stock(vim.ui.select) then
    M._orig_select = vim.ui.select -- stashed so a future un-setup can restore
    vim.ui.select = select_override
  end
  if vim.ui.input ~= input_override and is_stock(vim.ui.input) then
    M._orig_input = vim.ui.input
    vim.ui.input = input_override
  end
end

return M
