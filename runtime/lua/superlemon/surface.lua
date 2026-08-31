-- superlemon.surface — generic surface-window mechanics for natively
-- rendered vim windows (docs/design/surface-navbar-v1.md §4/§6). A surface
-- is a real nvim window holding a scratch projection buffer; the GUI
-- suppresses the grid's text and paints a native control over it. This
-- module owns window/buffer lifecycle and the wire helpers; content policy
-- (what the rows mean) belongs to the surface's owner (navbar.lua).

local M = {}

-- winid -> surface handle, so M.is_surface_win() and future callers can
-- recognize a surface window without threading the handle everywhere.
local open_surfaces = {}

local function active()
  return require("superlemon").active()
end

--- Fire one `superlemon.ui` notification for this surface's component
--- namespace, silently no-op when the GUI is not attached (same contract as
--- every other module in this plugin).
local function notify(component, method, ns, args)
  if not active() then
    return
  end
  vim.rpcnotify(vim.g.superlemon_channel, "superlemon.ui", component, method, ns, args)
end

--- True when `win` sits alone in screen column 0 (nothing else is stacked
--- above/below it there) — i.e. it is both leftmost and full height. Used to
--- verify `nvim_open_win{split="left"}` produced the window we asked for,
--- and by surface_spec.lua to assert the same thing.
---@param win integer
---@return boolean
function M.is_leftmost_fullheight(win)
  if not vim.api.nvim_win_is_valid(win) then
    return false
  end
  local pos = vim.api.nvim_win_get_position(win)
  if pos[2] ~= 0 then
    return false
  end
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if w ~= win then
      local ok, wpos = pcall(vim.api.nvim_win_get_position, w)
      if ok and wpos[2] == 0 then
        return false -- another window shares column 0: not alone/full-height
      end
    end
  end
  return true
end

local WINDOW_OPTIONS = {
  winfixwidth = true,
  winfixbuf = true,
  number = false,
  relativenumber = false,
  signcolumn = "no",
  foldcolumn = "0",
  wrap = false,
  cursorline = false,
  list = false,
}

local function apply_window_options(win, width)
  for opt, value in pairs(WINDOW_OPTIONS) do
    vim.wo[win][opt] = value
  end
  pcall(vim.api.nvim_win_set_width, win, width)
end

--- Leftmost full-height vertical split WITHOUT stealing focus. Tries the
--- nvim >= 0.10 declarative form first; falls back to `:topleft vertical
--- split` + focus restore if that form is unavailable or misbehaves.
local function open_leftmost_win(buf, width)
  local ok, win = pcall(vim.api.nvim_open_win, buf, false, {
    split = "left",
    win = -1,
    width = width,
  })
  if ok and type(win) == "number" and win > 0
    and vim.api.nvim_win_is_valid(win) and M.is_leftmost_fullheight(win)
  then
    return win
  end
  if ok and type(win) == "number" and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end

  local restore = vim.api.nvim_get_current_win()
  vim.cmd("topleft vertical " .. math.floor(width) .. "split")
  local fallback_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(fallback_win, buf)
  if vim.api.nvim_win_is_valid(restore) then
    vim.api.nvim_set_current_win(restore)
  end
  return fallback_win
end

--- Open a surface window. Creates the scratch buffer (buftype=nofile,
--- bufhidden=hide, noswap, unlisted, nomodifiable, filetype from opts) and
--- a leftmost full-height vertical split WITHOUT stealing focus; sets
--- winfixwidth/winfixbuf and chrome-free window options; installs
--- WinClosed/BufWinEnter guards; sends ("surface","open") with the event
--- callback id.
---@param opts { surface_id: string, control: string, filetype: string,
---  width: integer, on_event: fun(payload: table): any,
---  on_closed: fun() }
---@return table surface handle { win, buf, ... }
function M.open(opts)
  assert(type(opts) == "table" and type(opts.surface_id) == "string" and opts.surface_id ~= "",
    "surface.open: surface_id required")

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].buflisted = false
  vim.bo[buf].filetype = opts.filetype or ""
  vim.bo[buf].modifiable = false

  local width = opts.width or 32
  local win = open_leftmost_win(buf, width)
  apply_window_options(win, width)

  local surface = {
    id = opts.surface_id,
    win = win,
    buf = buf,
    opts = opts,
    closed = false,
    event_cb = nil,
  }
  open_surfaces[win] = surface

  if opts.on_event then
    surface.event_cb = require("superlemon.ui")._register(function(payload)
      return opts.on_event(payload)
    end)
  end

  local group = vim.api.nvim_create_augroup(
    "superlemon_surface_" .. opts.surface_id, { clear = true }
  )
  surface.augroup = group

  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = tostring(win),
    once = true,
    callback = function()
      M.close(surface)
    end,
  })

  -- winfixbuf (nvim >= 0.10) already refuses most buffer switches in this
  -- window; this is belt-and-suspenders against anything that defeats it
  -- (e.g. a forced :buffer, or an old nvim without winfixbuf support).
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    callback = function(ev)
      if not surface.closed and vim.api.nvim_win_is_valid(win)
        and vim.api.nvim_get_current_win() == win and ev.buf ~= surface.buf
      then
        pcall(vim.api.nvim_win_set_buf, win, surface.buf)
      end
    end,
  })

  notify("surface", "open", surface.id, {
    surface_id = surface.id,
    win = surface.win,
    buf = surface.buf,
    control = opts.control,
    event_cb = surface.event_cb,
  })

  return surface
end

--- Close the surface window (idempotent; fires on_closed exactly once
--- whether closed here or by the user via :q / Ctrl-W o).
function M.close(surface)
  if not surface or surface.closed then
    return
  end
  surface.closed = true
  open_surfaces[surface.win] = nil

  if surface.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, surface.augroup)
  end
  if surface.win and vim.api.nvim_win_is_valid(surface.win) then
    pcall(vim.api.nvim_win_close, surface.win, true)
  end

  notify("surface", "close", surface.id, { surface_id = surface.id })

  if surface.opts and surface.opts.on_closed then
    surface.opts.on_closed()
  end
end

--- Atomically write the projection buffer lines AND send the
--- ("surface","render") notification from one rows list — the projection
--- invariant: rows[i] describes buffer line i.
---@param surface table handle from M.open
---@param payload { seq: integer, header: table, menu: table, rows: table }
---@param lines string[] buffer lines, same length/order as payload.rows
function M.render(surface, payload, lines)
  assert(surface and surface.buf, "surface.render: invalid surface")
  assert(type(payload) == "table" and type(payload.rows) == "table",
    "surface.render: payload.rows required")
  assert(#lines == #payload.rows,
    "surface.render: lines/rows length mismatch ("
      .. #lines .. " lines, " .. #payload.rows .. " rows)")
  if surface.closed then
    return
  end

  vim.bo[surface.buf].modifiable = true
  vim.api.nvim_buf_set_lines(surface.buf, 0, -1, false, lines)
  vim.bo[surface.buf].modifiable = false

  payload.surface_id = surface.id
  notify("surface", "render", surface.id, payload)
end

--- True when `win` is a live surface window.
function M.is_surface_win(win)
  return open_surfaces[win] ~= nil
end

return M
