-- chrome.lua — native-chrome toggles + buffer-list pusher (CONTRACT.md
-- `superlemon.chrome` / `superlemon.buffers`).
--
-- nvim is the single source of truth for whether the GUI shows native buffer
-- tabs, status bar, per-window minimaps, scrollbars, and the file sidebar:
-- their corresponding g:superlemon_native_* globals seed the state,
-- :SuperlemonChrome flips it, and the GUI merely reflects `superlemon.chrome`
-- notifications.
--
-- Native-statusbar adoption is the one deliberate option bridge: by default
-- this module saves `laststatus`, sets it to zero while the native bar renders
-- the evaluated statusline, and restores it exactly when the bar turns off.
-- Set g:superlemon_adopt_statusline = 0 to keep the in-grid bar. Native tabs
-- do not mutate `showtabline`; the separate startup-only
-- g:superlemon_hide_tabline setting owns that choice.

local M = {}

local state = {
  native_tabs = false,
  native_statusbar = false,
  native_minimap = true,
  native_scrollbars = false,
  native_sidebar = true,
}

local buffer_timer

-- Adopt mode (DEFAULT while the native bar is on): the statusline moves OUT
-- of the grid and INTO the native bar — the bar displays the user's own
-- evaluated statusline (statusline.lua), so nothing is lost; laststatus is
-- saved and restored exactly when the bar toggles off. Opt out with
-- g:superlemon_adopt_statusline = 0 to keep both bars visible.
local adopt_saved = nil
local function apply_adopt_statusline()
  local adopt = not (
    vim.g.superlemon_adopt_statusline == 0
    or vim.g.superlemon_adopt_statusline == false
  )
  if state.native_statusbar and adopt then
    if adopt_saved == nil then
      adopt_saved = vim.o.laststatus
    end
    vim.o.laststatus = 0
  elseif adopt_saved ~= nil then
    vim.o.laststatus = adopt_saved
    adopt_saved = nil
  end
end

local function active()
  return require("superlemon").active()
end

local function push_chrome()
  if not active() then
    return
  end
  vim.rpcnotify(vim.g.superlemon_channel, "superlemon.chrome", {
    native_tabs = state.native_tabs,
    native_statusbar = state.native_statusbar,
    native_minimap = state.native_minimap,
    native_scrollbars = state.native_scrollbars,
    native_sidebar = state.native_sidebar,
  })
end

-- Window/buffer topology is also required to validate native scrollbar drags
-- when the visible minimap is off. Content remains demand-driven, so keeping
-- this lightweight provider active does not rasterize or mirror the buffer.
local function sync_accessory_provider()
  pcall(function()
    require("superlemon.minimap").set_enabled(
      state.native_minimap or state.native_scrollbars
    )
  end)
end

local function push_buffers()
  if not (active() and state.native_tabs) then
    return
  end
  local buffers = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[b].buflisted then
      local name = vim.api.nvim_buf_get_name(b)
      local rel = ""
      if name ~= "" then
        rel = vim.fs.relpath(vim.fn.getcwd(), name) or name
      end
      table.insert(buffers, {
        bufnr = b,
        name = rel,
        modified = vim.bo[b].modified,
        preview = require("superlemon.preview").is_preview(b),
      })
    end
  end
  vim.rpcnotify(vim.g.superlemon_channel, "superlemon.buffers", {
    current = vim.api.nvim_get_current_buf(),
    buffers = buffers,
  })
end

--- Immediate (non-debounced) buffer push — preview open/promote call this so
--- the italic flag updates without waiting for a buffer event.
function M.push_buffers()
  push_buffers()
end

-- Debounced (~50 ms): buffer events arrive in bursts (`:bufdo`, session load).
local function schedule_buffers()
  if not (active() and state.native_tabs) then
    return
  end
  if not buffer_timer then
    buffer_timer = vim.uv.new_timer()
  end
  buffer_timer:stop()
  buffer_timer:start(50, 0, vim.schedule_wrap(push_buffers))
end

---@param part '"tabs"'|'"statusbar"'|'"minimap"'|'"scrollbars"'|'"sidebar"'
---@param on boolean
function M.set(part, on)
  if part == "tabs" then
    if state.native_tabs == on then
      return
    end
    state.native_tabs = on
    if on then
      push_buffers() -- seed immediately; autocmds keep it fresh
    end
  elseif part == "statusbar" then
    if state.native_statusbar == on then
      return
    end
    state.native_statusbar = on
    apply_adopt_statusline()
    if on then
      pcall(function()
        require("superlemon.statusline").push() -- seed the harvested segments
      end)
    end
  elseif part == "minimap" then
    if state.native_minimap == on then
      return
    end
    state.native_minimap = on
    sync_accessory_provider()
  elseif part == "scrollbars" then
    if state.native_scrollbars == on then
      return
    end
    state.native_scrollbars = on
    sync_accessory_provider()
  elseif part == "sidebar" then
    if state.native_sidebar == on then
      return
    end
    state.native_sidebar = on
  else
    return
  end
  push_chrome()
end


---@param part '"tabs"'|'"statusbar"'|'"minimap"'|'"scrollbars"'|'"sidebar"'
function M.toggle(part)
  if part == "tabs" then
    M.set(part, not state.native_tabs)
  elseif part == "statusbar" then
    M.set(part, not state.native_statusbar)
  elseif part == "minimap" then
    M.set(part, not state.native_minimap)
  elseif part == "scrollbars" then
    M.set(part, not state.native_scrollbars)
  elseif part == "sidebar" then
    M.set(part, not state.native_sidebar)
  end
end

--- Current toggle state (health checks and tests).
function M.state()
  return {
    native_tabs = state.native_tabs,
    native_statusbar = state.native_statusbar,
    native_minimap = state.native_minimap,
    native_scrollbars = state.native_scrollbars,
    native_sidebar = state.native_sidebar,
  }
end

---@param group integer augroup id
---@param opts { compact: boolean }|nil compact = the GUI started at a narrow
--- width; sidebar and minimap then default off unless their g: globals are
--- explicitly set.
function M.setup(group, opts)
  local function truthy(v, default)
    if v == nil or v == vim.NIL then
      return default == true
    end
    return v == 1 or v == true
  end
  local compact = opts ~= nil and opts.compact == true
  state.native_tabs = truthy(vim.g.superlemon_native_tabs)
  state.native_statusbar = truthy(vim.g.superlemon_native_statusbar)
  state.native_minimap = truthy(vim.g.superlemon_native_minimap, not compact)
  state.native_scrollbars = truthy(vim.g.superlemon_native_scrollbars, false)
  state.native_sidebar = truthy(vim.g.superlemon_native_sidebar, not compact)
  apply_adopt_statusline()
  -- Startup-only (explicit user choice in Settings or config): hide the
  -- editor's own tab line (airline/bufferline tabs) — the native strip
  -- replaces it.
  if truthy(vim.g.superlemon_hide_tabline) then
    vim.o.showtabline = 0
  end

  vim.api.nvim_create_autocmd(
    { "BufAdd", "BufDelete", "BufEnter", "BufFilePost", "BufModifiedSet" },
    { group = group, callback = schedule_buffers }
  )

  vim.api.nvim_create_user_command("SuperlemonChrome", function(opts)
    local part, action = opts.fargs[1], opts.fargs[2] or "toggle"
    if action == "toggle" then
      M.toggle(part)
    else
      M.set(part, action == "on")
    end
  end, {
    nargs = "+",
    complete = function()
      return { "tabs", "statusbar", "minimap", "scrollbars", "sidebar" }
    end,
    desc = "Toggle Superlemon native chrome (tabs|statusbar|minimap|scrollbars|sidebar) (on|off|toggle)",
  })

  push_chrome()
  if state.native_tabs then
    push_buffers()
  end
end

return M
