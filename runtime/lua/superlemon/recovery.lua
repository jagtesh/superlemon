-- Incremental host-side recovery mirror. The GUI survives a Neovim crash;
-- buffer deltas are sent as they happen, without rewriting large buffers.
local M = {}
local channel, group
local watched = {}
local function normal(buf)
  return vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == "" and vim.bo[buf].buflisted
end
local function send(kind, data)
  if channel then vim.rpcnotify(channel, "superlemon.recovery", kind, data) end
end
local function buffer(buf)
  return { id = buf, name = vim.api.nvim_buf_get_name(buf),
    lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false),
    modified = vim.bo[buf].modified, filetype = vim.bo[buf].filetype,
    fileformat = vim.bo[buf].fileformat, endofline = vim.bo[buf].endofline }
end
local function layout(node)
  if node[1] == "leaf" then
    local win = node[2]
    local buf = vim.api.nvim_win_get_buf(win)
    if not normal(buf) or vim.api.nvim_win_get_config(win).relative ~= "" then return nil end
    return { kind = "leaf", buffer = buf, cursor = vim.api.nvim_win_get_cursor(win),
      width = vim.api.nvim_win_get_width(win), height = vim.api.nvim_win_get_height(win),
      active = win == vim.api.nvim_get_current_win() }
  end
  local children = {}
  for _, child in ipairs(node[2]) do
    local kept = layout(child)
    if kept then children[#children + 1] = kept end
  end
  if #children == 0 then return nil end
  if #children == 1 then return children[1] end
  return { kind = node[1], children = children }
end
local function workspace()
  local tabs = {}
  local current = vim.api.nvim_get_current_tabpage()
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    local tree = layout(vim.fn.winlayout(vim.api.nvim_tabpage_get_number(tab)))
    if tree then tabs[#tabs + 1] = { tree = tree, active = tab == current } end
  end
  return { cwd = vim.fn.getcwd(), tabs = tabs }
end
local function attach(buf)
  if watched[buf] or not normal(buf) or not vim.api.nvim_buf_is_loaded(buf) then return end
  watched[buf] = true
  send("buffer", buffer(buf))
  vim.api.nvim_buf_attach(buf, false, {
    on_lines = function(_, b, _, first, last, new_last)
      send("lines", { id = b, first = first, last = last,
        lines = vim.api.nvim_buf_get_lines(b, first, new_last, false) })
    end,
    on_reload = function(_, b) send("buffer", buffer(b)) end,
    on_detach = function(_, b) watched[b] = nil end,
  })
end
function M.start(chan)
  channel = chan
  group = vim.api.nvim_create_augroup("superlemon_recovery", { clear = true })
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do attach(buf) end
  vim.api.nvim_create_autocmd({ "BufEnter", "BufReadPost", "BufNewFile" }, {
    group = group, callback = function(ev) attach(ev.buf) end,
  })
  vim.api.nvim_create_autocmd({ "BufModifiedSet", "BufFilePost", "BufWritePost" }, {
    group = group, callback = function(ev)
      if normal(ev.buf) and watched[ev.buf] then
        send("metadata", { id = ev.buf, name = vim.api.nvim_buf_get_name(ev.buf),
          modified = vim.bo[ev.buf].modified })
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = group, callback = function(ev) send("remove", { id = ev.buf }) end,
  })
  local pending = false
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "WinEnter", "WinClosed",
    "WinResized", "TabEnter", "DirChanged", "BufEnter" }, {
    group = group, callback = function()
      if pending then return end
      pending = true
      vim.schedule(function() pending = false; send("workspace", workspace()) end)
    end,
  })
  send("workspace", workspace())
end

function M.restore(snapshot)
  local ws = type(snapshot.workspace) == "table" and snapshot.workspace or {}
  if ws.cwd and vim.fn.isdirectory(ws.cwd) == 1 then vim.cmd.cd(vim.fn.fnameescape(ws.cwd)) end
  local buffers = {}
  for _, saved in ipairs(snapshot.buffers or {}) do
    local buf = saved.name ~= "" and vim.fn.bufadd(saved.name) or vim.api.nvim_create_buf(true, false)
    -- Never allow swap recovery prompts to block automatic recovery. The
    -- host copy is authoritative and disk files are never written here.
    local swapfile = vim.bo[buf].swapfile
    vim.bo[buf].swapfile = false
    vim.fn.bufload(buf)
    local disk = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local changed_on_disk = not vim.deep_equal(disk, saved.lines)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, saved.lines)
    vim.bo[buf].filetype = saved.filetype or ""
    vim.bo[buf].fileformat = saved.fileformat or "unix"
    vim.bo[buf].endofline = saved.endofline ~= false
    vim.bo[buf].modified = saved.modified or changed_on_disk
    vim.bo[buf].swapfile = swapfile
    buffers[saved.id] = buf
  end
  local active_win, active_tab
  local function build(node, win)
    if node.kind == "leaf" then
      if not buffers[node.buffer] then return end
      vim.api.nvim_set_current_win(win)
      vim.wo[win].winfixbuf = false
      vim.api.nvim_win_set_buf(win, buffers[node.buffer])
      pcall(vim.api.nvim_win_set_cursor, win, node.cursor)
      pcall(vim.api.nvim_win_set_width, win, node.width)
      pcall(vim.api.nvim_win_set_height, win, node.height)
      if node.active then active_win = win end
      return
    end
    local wins = { win }
    for i = 2, #node.children do
      vim.api.nvim_set_current_win(wins[i - 1])
      vim.cmd(node.kind == "row" and "rightbelow vsplit" or "rightbelow split")
      wins[i] = vim.api.nvim_get_current_win()
    end
    for i, child in ipairs(node.children) do build(child, wins[i]) end
  end
  -- Runtime startup may have opened its sidebar. Only normal editor windows
  -- participate in the restored layout; the sidebar is recreated by runtime.
  local target
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if normal(vim.api.nvim_win_get_buf(win)) then target = win; break end
  end
  if not target then vim.cmd("botright new"); target = vim.api.nvim_get_current_win() end
  for i, tab in ipairs(ws.tabs or {}) do
    if i > 1 then vim.cmd.tabnew(); target = vim.api.nvim_get_current_win() end
    if tab.active then active_tab = vim.api.nvim_get_current_tabpage() end
    build(tab.tree, target)
  end
  if active_tab then vim.api.nvim_set_current_tabpage(active_tab) end
  if active_win and vim.api.nvim_win_is_valid(active_win) then vim.api.nvim_set_current_win(active_win) end
  return true
end
return M
