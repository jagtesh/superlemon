-- superlemon.navbar — the surface-mode file tree (docs/design/
-- surface-navbar-v1.md §4/§5). Owns the tree model (lazy vim.uv.fs_scandir,
-- per-expanded-dir fs_event watchers, git + plugin decorations, expansion
-- state), the buffer projection and its normal-mode mappings (<CR>/o, go,
-- R, C, u), and file operations for local sessions (create/rename via
-- vim.uv; trash/reveal via the GUI "host" services).

local M = {}

---------------------------------------------------------------------------
-- module state
---------------------------------------------------------------------------

local enabled_flag = false
local closing_internally = false
local surface = nil -- the surface.lua handle, or nil while closed

local state = {
  root = nil,
  remote = false,
  git_status = {}, -- rel path -> one-letter status
  git_dirty_dirs = {}, -- rel dir path -> true
  by_id = {}, -- row id -> { kind, path?, rel?, target_dir? }
  last_ids = {}, -- buffer line -> row id
  pending_select = nil, -- row id to select once it appears in a render
}

local tree = {} -- abs dir path -> { status = "idle"|"loading"|"loaded"|"failed", entries, err }
local expanded = {} -- abs dir path -> true
local watchers = {} -- abs dir path -> { handle, timer }
local decoration_ns = {} -- namespace name -> { badges = {rel->{text,color}}, dots = {rel->color} }
local git_subscribed = false
local render_timer
local seq = 0

-- Same hex values FileTreeSidebarView/ShellPalette use for git badges
-- (dark-appearance variants — Lua has no notion of the current appearance,
-- so a single fixed set is used; the GUI may still restyle since color is
-- advisory per §6).
local GIT_BADGE_COLOR = {
  M = "#E0B268",
  A = "#ADC694",
  D = "#C79595",
  R = "#B4A7D6",
  C = "#B4A7D6",
  U = "#C79595",
  ["?"] = "#8B9196",
}
local DIRTY_DOT_COLOR = "#E0B268"

local FULL_MENU = {
  { id = "new_file", title = "New File", for_kinds = { "file", "dir", "root" } },
  { id = "new_folder", title = "New Folder", for_kinds = { "file", "dir", "root" } },
  { id = "rename", title = "Rename", for_kinds = { "file", "dir" } },
  { id = "delete", title = "Move to Trash", for_kinds = { "file", "dir" } },
  { id = "reveal", title = "Reveal in Finder", for_kinds = { "file", "dir", "root" } },
  { id = "cd", title = "Change Working Directory", for_kinds = { "dir", "up" } },
}
local REMOTE_MENU = {
  { id = "cd", title = "Change Working Directory", for_kinds = { "dir", "up" } },
}

--- True when surface-mode navbar is active this session (setup ran with
--- navbar_surface = true). Other modules (chrome, ui, git, minimap) gate
--- their routing on this at call time.
function M.enabled()
  return enabled_flag
end

local function notify_ui(component, method, ns, args)
  if not require("superlemon").active() then
    return
  end
  vim.rpcnotify(vim.g.superlemon_channel, "superlemon.ui", component, method, ns, args)
end

---------------------------------------------------------------------------
-- model: lazy scandir, sorting, watchers
---------------------------------------------------------------------------

local function sort_entries(entries)
  table.sort(entries, function(a, b)
    if a.is_dir ~= b.is_dir then
      return a.is_dir
    end
    return a.name:lower() < b.name:lower()
  end)
end

--- Async, non-blocking directory listing; resolves one level of symlink so
--- a link to a directory expands (mirrors workspace.list_dir). `cb` always
--- runs on the main loop (vim.schedule).
local function scan_dir(path, cb)
  local ok = pcall(vim.uv.fs_scandir, path, function(err, handle)
    if err or not handle then
      vim.schedule(function()
        cb(err or "could not read directory", nil)
      end)
      return
    end
    local entries = {}
    while true do
      local name, kind = vim.uv.fs_scandir_next(handle)
      if not name then
        break
      end
      if kind == "link" or kind == nil then
        local stat = vim.uv.fs_stat(vim.fs.joinpath(path, name))
        kind = stat and stat.type or kind
      end
      entries[#entries + 1] = { name = name, is_dir = kind == "directory" }
    end
    vim.schedule(function()
      cb(nil, entries)
    end)
  end)
  if not ok then
    vim.schedule(function()
      cb("could not read directory", nil)
    end)
  end
end

local schedule_render -- fwd decl

--- Kick off (if not already loading/loaded) an async scan of `path`.
--- Idempotent: repeated calls while a scan is in flight are no-ops.
local function ensure_loaded(path)
  local node = tree[path]
  if node == nil then
    node = { status = "idle" }
    tree[path] = node
  end
  if node.status ~= "idle" then
    return
  end
  node.status = "loading"
  scan_dir(path, function(err, entries)
    local cur = tree[path]
    if not cur then
      return -- collapsed/re-rooted while the scan was in flight
    end
    if err then
      cur.status = "failed"
      cur.err = tostring(err)
    else
      sort_entries(entries)
      cur.status = "loaded"
      cur.entries = entries
    end
    schedule_render()
  end)
end

--- Discard a directory's cached listing and reload it if it is still
--- relevant (root or expanded); used by fs_event watchers and refreshes.
local function invalidate_dir(path)
  tree[path] = nil
  if path == state.root or expanded[path] then
    ensure_loaded(path)
  end
end

local function unwatch_dir(path)
  local w = watchers[path]
  if not w then
    return
  end
  watchers[path] = nil
  if w.handle then
    pcall(function()
      w.handle:stop()
    end)
    pcall(function()
      w.handle:close()
    end)
  end
  if w.timer then
    pcall(function()
      w.timer:stop()
    end)
    pcall(function()
      w.timer:close()
    end)
  end
end

--- One non-recursive fs_event watcher per expanded directory (nvim-tree
--- pattern), 100ms debounced per directory.
local function watch_dir(path)
  if watchers[path] then
    return
  end
  local handle = vim.uv.new_fs_event()
  if not handle then
    return
  end
  local timer = vim.uv.new_timer()
  local entry = { handle = handle, timer = timer }
  watchers[path] = entry
  pcall(function()
    handle:start(path, {}, function(err)
      if err or watchers[path] ~= entry or not timer then
        return
      end
      timer:stop()
      timer:start(100, 0, vim.schedule_wrap(function()
        if watchers[path] == entry then
          invalidate_dir(path)
        end
      end))
    end)
  end)
end

local function teardown_all_watchers()
  for path in pairs(watchers) do
    unwatch_dir(path)
  end
end

---------------------------------------------------------------------------
-- projection: buffer lines == rows (the load-bearing invariant)
---------------------------------------------------------------------------

local function rel_of(path)
  if path == state.root then
    return ""
  end
  local prefix = state.root .. "/"
  if path:sub(1, #prefix) == prefix then
    return path:sub(#prefix + 1)
  end
  return path
end

local function collect(path, depth, wire_rows, by_id)
  ensure_loaded(path)
  local node = tree[path]

  if not node or node.status == "loading" then
    local id = path .. "\1loading"
    wire_rows[#wire_rows + 1] = { id = id, label = "Loading…", depth = depth, kind = "loading" }
    by_id[id] = { kind = "loading", target_dir = path }
    return
  end

  if node.status == "failed" then
    local id = path .. "\1failed"
    wire_rows[#wire_rows + 1] =
      { id = id, label = "Failed to load — retry", depth = depth, kind = "failed" }
    by_id[id] = { kind = "failed", target_dir = path }
    return
  end

  for _, e in ipairs(node.entries or {}) do
    local child = vim.fs.joinpath(path, e.name)
    if e.is_dir then
      local exp = expanded[child] == true
      wire_rows[#wire_rows + 1] =
        { id = child, label = e.name, depth = depth, kind = "dir", expanded = exp }
      by_id[child] = { kind = "dir", path = child, rel = rel_of(child) }
      if exp then
        collect(child, depth + 1, wire_rows, by_id)
      end
    else
      wire_rows[#wire_rows + 1] = { id = child, label = e.name, depth = depth, kind = "file" }
      by_id[child] = { kind = "file", path = child, rel = rel_of(child) }
    end
  end
end

local function apply_decorations(wire_rows, by_id)
  local names = {}
  for name in pairs(decoration_ns) do
    names[#names + 1] = name
  end
  table.sort(names)

  for _, row in ipairs(wire_rows) do
    local meta = by_id[row.id]
    if meta and meta.rel then
      if meta.kind == "file" then
        local status = state.git_status[meta.rel]
        if status then
          row.badge = { text = status, color = GIT_BADGE_COLOR[status] }
        end
      elseif meta.kind == "dir" then
        if state.git_dirty_dirs[meta.rel] then
          row.dot = DIRTY_DOT_COLOR
        end
      end

      for _, name in ipairs(names) do
        local store = decoration_ns[name]
        local badge = store.badges[meta.rel]
        if badge then
          row.badge = { text = badge.text, color = badge.color }
        end
        local dot = store.dots[meta.rel]
        if dot then
          row.dot = dot
        end
      end
    end
  end
end

local function compute_projection()
  local wire_rows, by_id = {}, {}
  local parent = vim.fn.fnamemodify(state.root, ":h")
  if parent ~= "" and parent ~= state.root then
    wire_rows[#wire_rows + 1] = { id = parent, label = "..", depth = 0, kind = "up" }
    by_id[parent] = { kind = "up", path = parent }
  end
  collect(state.root, 0, wire_rows, by_id)
  apply_decorations(wire_rows, by_id)
  return wire_rows, by_id
end

local function header_title()
  local base = vim.fs.basename(state.root)
  return (base and base ~= "") and base or state.root
end

local function do_render()
  if not surface then
    return
  end
  local wire_rows, by_id = compute_projection()
  state.by_id = by_id

  local ids, lines = {}, {}
  for i, row in ipairs(wire_rows) do
    ids[i] = row.id
    lines[i] = string.rep("  ", row.depth) .. row.label
  end
  state.last_ids = ids

  seq = seq + 1
  require("superlemon.surface").render(surface, {
    seq = seq,
    header = { title = header_title() },
    menu = state.remote and REMOTE_MENU or FULL_MENU,
    rows = wire_rows,
  }, lines)

  if state.pending_select then
    for i, id in ipairs(ids) do
      if id == state.pending_select then
        pcall(vim.api.nvim_win_set_cursor, surface.win, { i, 0 })
        state.pending_select = nil
        break
      end
    end
  end
end

--- Debounced (~30ms) re-render; monotonic seq is bumped in do_render.
schedule_render = function()
  if not surface then
    return
  end
  if not render_timer then
    render_timer = vim.uv.new_timer()
  end
  render_timer:stop()
  render_timer:start(30, 0, vim.schedule_wrap(do_render))
end

---------------------------------------------------------------------------
-- git subscription + plugin decorations
---------------------------------------------------------------------------

local function on_git_update(files)
  local status, dirty_dirs = {}, {}
  for _, f in ipairs(files) do
    status[f.path] = f.status
    local dir = vim.fs.dirname(f.path)
    while dir and dir ~= "." and dir ~= "" and dir ~= "/" do
      dirty_dirs[dir] = true
      dir = vim.fs.dirname(dir)
    end
  end
  state.git_status = status
  state.git_dirty_dirs = dirty_dirs
  schedule_render()
end

--- Plugin decoration entry point (ui.lua routes Namespace:set_badge /
--- set_dot / clear here when enabled()). Merge rule: namespaces sorted by
--- name, later wins per path — same as the GUI's SidebarDecorationStore.
---@param ns string
---@param method '"set_badge"'|'"set_dot"'|'"clear"'
---@param args table
function M.decorations(ns, method, args)
  if method == "clear" then
    decoration_ns[ns] = nil
  else
    local store = decoration_ns[ns]
    if not store then
      store = { badges = {}, dots = {} }
      decoration_ns[ns] = store
    end
    if method == "set_badge" then
      store.badges[args.path] = { text = args.text, color = args.color }
    elseif method == "set_dot" then
      store.dots[args.path] = args.color
    end
  end
  schedule_render()
end

---------------------------------------------------------------------------
-- expansion / re-root
---------------------------------------------------------------------------

local function toggle_expand(path)
  if expanded[path] then
    expanded[path] = nil
    unwatch_dir(path)
  else
    expanded[path] = true
    watch_dir(path)
    ensure_loaded(path)
  end
  schedule_render()
end

local function root_to_parent()
  local parent = vim.fn.fnamemodify(state.root, ":h")
  if parent == state.root then
    return
  end
  vim.api.nvim_set_current_dir(parent)
end

local function re_root(new_root)
  if new_root == state.root then
    return
  end
  teardown_all_watchers()
  tree = {}
  expanded = {}
  state.root = new_root
  state.pending_select = nil
  ensure_loaded(new_root)
  watch_dir(new_root)
  schedule_render()
end

local function full_refresh()
  tree = {}
  ensure_loaded(state.root)
  for path in pairs(expanded) do
    ensure_loaded(path)
  end
  schedule_render()
end

---------------------------------------------------------------------------
-- opening files (keyboard vs GUI-originated, per §4)
---------------------------------------------------------------------------

local function is_normal_win(win)
  if not vim.api.nvim_win_is_valid(win) then
    return false
  end
  local ok, cfg = pcall(vim.api.nvim_win_get_config, win)
  return ok and cfg.relative == "" and not cfg.external
end

--- Most-recently-used normal window that isn't the navbar itself —
--- NerdTree's "open into the last-used window" target.
local function recent_editor_win()
  local winnr = vim.fn.winnr("#")
  if winnr and winnr > 0 then
    local win = vim.fn.win_getid(winnr)
    if win ~= 0 and (not surface or win ~= surface.win) and is_normal_win(win) then
      return win
    end
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if (not surface or win ~= surface.win) and is_normal_win(win) then
      return win
    end
  end
  return nil
end

local function open_in_place(path, permanent)
  if permanent then
    require("superlemon.preview").open_permanent(path)
  else
    require("superlemon.preview").open(path)
  end
end

--- Keyboard opens: move to the last-used editor window first, then open —
--- focus lands there afterwards (NerdTree behavior).
local function open_via_recent_window(path, permanent)
  local target = recent_editor_win()
  if target and target ~= vim.api.nvim_get_current_win() then
    vim.api.nvim_set_current_win(target)
  end
  open_in_place(path, permanent)
end

--- GUI click/double-click: the editor window is already current, so open
--- without touching focus — unless the navbar window is somehow current
--- (edge case), in which case fall back to the keyboard dance.
local function handle_open_event(path, permanent)
  if surface and vim.api.nvim_get_current_win() == surface.win then
    open_via_recent_window(path, permanent)
  else
    open_in_place(path, permanent)
  end
end

---------------------------------------------------------------------------
-- buffer-local mappings (§4 table)
---------------------------------------------------------------------------

local function row_at_cursor()
  if not surface then
    return nil
  end
  local ok, cursor = pcall(vim.api.nvim_win_get_cursor, surface.win)
  if not ok then
    return nil
  end
  local id = state.last_ids[cursor[1]]
  if not id then
    return nil
  end
  return state.by_id[id]
end

local function map_open_permanent()
  local row = row_at_cursor()
  if not row then
    return
  end
  if row.kind == "file" then
    open_via_recent_window(row.path, true)
  elseif row.kind == "dir" then
    toggle_expand(row.path)
  elseif row.kind == "up" then
    root_to_parent()
  elseif row.kind == "failed" then
    invalidate_dir(row.target_dir)
  end
end

local function map_open_preview()
  local row = row_at_cursor()
  if not row then
    return
  end
  if row.kind == "file" then
    open_via_recent_window(row.path, false)
  elseif row.kind == "dir" then
    toggle_expand(row.path)
  end
end

local function map_refresh()
  full_refresh()
end

local function map_cd()
  local row = row_at_cursor()
  if not row then
    return
  end
  if row.kind == "dir" then
    vim.api.nvim_set_current_dir(row.path)
  elseif row.kind == "up" then
    root_to_parent()
  end
end

local function map_root_up()
  root_to_parent()
end

local function setup_mappings(buf)
  local opts = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set("n", "<CR>", map_open_permanent, opts)
  vim.keymap.set("n", "o", map_open_permanent, opts)
  vim.keymap.set("n", "go", map_open_preview, opts)
  vim.keymap.set("n", "R", map_refresh, opts)
  vim.keymap.set("n", "C", map_cd, opts)
  vim.keymap.set("n", "u", map_root_up, opts)
end

---------------------------------------------------------------------------
-- file ops (local sessions only) + blocking rename/create
---------------------------------------------------------------------------

local function validate_name(name)
  name = name and vim.trim(name) or ""
  if name == "" then
    return nil, "Name cannot be empty"
  end
  if name:find("/", 1, true) then
    return nil, "Name cannot contain \"/\""
  end
  return name, nil
end

local function handle_rename(id, name)
  local row = state.by_id[id]
  if not row or not row.path then
    return { error = "Unknown item" }
  end
  if state.remote then
    return { error = "Not supported on remote sessions" }
  end
  local clean, err = validate_name(name)
  if not clean then
    return { error = err }
  end
  local dir = vim.fs.dirname(row.path)
  local target = vim.fs.joinpath(dir, clean)
  if vim.uv.fs_stat(target) then
    return { error = "\"" .. clean .. "\" already exists" }
  end
  local ok, rename_err = vim.uv.fs_rename(row.path, target)
  if not ok then
    return { error = rename_err or "Rename failed" }
  end
  state.pending_select = target
  invalidate_dir(dir)
  schedule_render()
  return { ok = true }
end

local function handle_create(dir, kind, name)
  if state.remote then
    return { error = "Not supported on remote sessions" }
  end
  -- The GUI's flat row list has no explicit root row; an empty directory id
  -- means the root (same convention as menu/drop targets).
  if dir == nil or dir == "" then
    dir = state.root
  end
  local clean, err = validate_name(name)
  if not clean then
    return { error = err }
  end
  local target = vim.fs.joinpath(dir, clean)
  if vim.uv.fs_stat(target) then
    return { error = "\"" .. clean .. "\" already exists" }
  end
  if kind == "folder" then
    local ok = vim.uv.fs_mkdir(target, 493) -- 0755
    if not ok then
      return { error = "Could not create folder" }
    end
  else
    local fd, open_err = vim.uv.fs_open(target, "w", 420) -- 0644
    if not fd then
      return { error = open_err or "Could not create file" }
    end
    vim.uv.fs_close(fd)
  end
  state.pending_select = target
  invalidate_dir(dir)
  schedule_render()
  return { ok = true, path = target }
end

local function resolve_menu_path(id)
  local row = state.by_id[id]
  if row and row.path then
    return row.path, row.kind
  end
  -- "" is the GUI's id for the root (header/background clicks — the flat
  -- row list has no explicit root row).
  if id == "" or id == state.root then
    return state.root, "root"
  end
  return nil, nil
end

local function handle_menu(id, item)
  if item == "new_file" or item == "new_folder" or item == "rename" then
    -- The GUI drives inline create/rename itself (beginCreate/beginRename);
    -- only the resulting blocking create/rename events come back to us.
    return
  end
  local path = resolve_menu_path(id)
  if not path then
    return
  end
  if item == "cd" then
    vim.api.nvim_set_current_dir(path)
    return
  end
  if state.remote then
    return -- delete/reveal are local-only (the remote menu never offers them)
  end
  if item == "delete" then
    notify_ui("host", "trash", "navbar", { path = path })
  elseif item == "reveal" then
    notify_ui("host", "reveal", "navbar", { path = path })
  end
end

---------------------------------------------------------------------------
-- GUI event dispatch (§6)
---------------------------------------------------------------------------

local function on_event(payload)
  local event = payload and payload.event
  if event == "open" then
    local row = state.by_id[payload.id]
    if not row then
      return
    end
    if row.kind == "file" then
      handle_open_event(row.path, payload.permanent == true)
    elseif row.kind == "dir" then
      toggle_expand(row.path)
    elseif row.kind == "up" then
      root_to_parent()
    elseif row.kind == "failed" then
      invalidate_dir(row.target_dir)
    end
  elseif event == "toggle" then
    local row = state.by_id[payload.id]
    if row and row.kind == "dir" then
      toggle_expand(row.path)
    end
  elseif event == "menu" then
    handle_menu(payload.id, payload.item)
  elseif event == "refresh" then
    full_refresh()
  elseif event == "rename" then
    return handle_rename(payload.id, payload.name)
  elseif event == "create" then
    return handle_create(payload.dir, payload.kind, payload.name)
  end
end

---------------------------------------------------------------------------
-- surface lifecycle + chrome delegation
---------------------------------------------------------------------------

local function open_surface()
  if surface then
    return
  end
  surface = require("superlemon.surface").open({
    surface_id = "navbar",
    control = "tree",
    filetype = "superlemon-navbar",
    width = 32,
    on_event = on_event,
    on_closed = function()
      surface = nil
      if not closing_internally then
        require("superlemon.chrome").set("sidebar", false)
      end
    end,
  })
  setup_mappings(surface.buf)
  do_render()
end

--- Open/close/toggle the navbar window. chrome.lua delegates its "sidebar"
--- part here in surface mode; user :q / Ctrl-W o on the window calls back
--- into chrome.set("sidebar", false) (guarded against recursion).
function M.set_open(on)
  if not enabled_flag then
    return
  end
  if on then
    open_surface()
  elseif surface then
    closing_internally = true
    local ok, err = pcall(require("superlemon.surface").close, surface)
    closing_internally = false
    if not ok then
      error(err, 0)
    end
  end
end

function M.toggle()
  require("superlemon.chrome").toggle("sidebar")
end

--- Install the navbar: model rooted at nvim's cwd, DirChanged re-rooting,
--- git.on_update subscription, and open the surface window (respecting the
--- chrome sidebar state / compact default).
---@param group integer augroup id
---@param opts { remote: boolean, compact: boolean }|nil
function M.setup(group, opts)
  opts = opts or {}
  enabled_flag = true
  state.remote = opts.remote == true
  state.root = vim.fn.getcwd()
  state.git_status = {}
  state.git_dirty_dirs = {}
  state.pending_select = nil
  tree = {}
  expanded = {}

  if not git_subscribed then
    git_subscribed = true
    require("superlemon.git").on_update(on_git_update)
  end

  vim.api.nvim_create_autocmd("DirChanged", {
    group = group,
    callback = function()
      re_root(vim.fn.getcwd())
    end,
  })

  ensure_loaded(state.root)
  watch_dir(state.root)

  local chrome_state = require("superlemon.chrome").state()
  if chrome_state.native_sidebar then
    open_surface()
  end
end

return M
