-- preview.lua — VS Code / Sublime "preview tab" semantics (CONTRACT.md).
--
-- Single-clicking a file in the GUI sidebar opens it as the PREVIEW buffer:
-- at most one exists, and opening another preview replaces it (the old one
-- is wiped if unmodified). A preview becomes permanent when:
--   * promote() is called (double-click on the file or its tab), or
--   * the buffer is modified (you edited it — it's yours now), or
--   * a new preview would replace a modified preview (promoted instead).
-- Clicking a file whose buffer already exists permanently just switches.
--
-- nvim is the source of truth: the GUI renders the `preview` flag pushed in
-- superlemon.buffers (italic tab) and calls open()/promote() over RPC.

local M = {}

local state = { bufnr = nil }
local AUGROUP = "superlemon_preview"

--- The current preview buffer, or nil.
---@return integer|nil
function M.bufnr()
  if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
    return state.bufnr
  end
  state.bufnr = nil
  return nil
end

---@param bufnr integer
---@return boolean
function M.is_preview(bufnr)
  return M.bufnr() == bufnr
end

local function push_buffers()
  pcall(function()
    require("superlemon.chrome").push_buffers()
  end)
end

--- Make the preview permanent (double-click, or automatic on edit).
---@param bufnr integer|nil defaults to the current buffer
function M.promote(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if M.bufnr() ~= bufnr then
    return
  end
  state.bufnr = nil
  pcall(vim.api.nvim_del_augroup_by_name, AUGROUP)
  push_buffers()
end

--- Watch the preview buffer: the first real modification promotes it.
local function watch(bufnr)
  local group = vim.api.nvim_create_augroup(AUGROUP, { clear = true })
  vim.api.nvim_create_autocmd("BufModifiedSet", {
    group = group,
    buffer = bufnr,
    callback = function()
      if vim.bo[bufnr].modified then
        M.promote(bufnr)
      end
    end,
  })
end

--- Resolve an absolute path to an existing listed buffer, if any.
---@param path string absolute
---@return integer|nil
local function buffer_for(path)
  local want = vim.uv.fs_realpath(path) or path
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[b].buflisted then
      local name = vim.api.nvim_buf_get_name(b)
      if name ~= "" and (vim.uv.fs_realpath(name) or name) == want then
        return b
      end
    end
  end
  return nil
end

--- Sidebar single-click entry point.
---@param path string absolute path
function M.open(path)
  local existing = buffer_for(path)

  -- Already open as a permanent buffer (or as the current preview):
  -- just switch to it; preview state is untouched.
  if existing then
    vim.api.nvim_set_current_buf(existing)
    return
  end

  local old = M.bufnr()
  if old and vim.bo[old].modified then
    -- Edited previews are never discarded — they graduate.
    M.promote(old)
    old = nil
  end

  vim.cmd.drop(vim.fn.fnameescape(path))
  local new = vim.api.nvim_get_current_buf()

  -- Replace the previous (clean) preview: its tab disappears.
  if old and old ~= new then
    pcall(vim.api.nvim_buf_delete, old, {})
  end

  state.bufnr = new
  watch(new)
  push_buffers()
end

--- Sidebar double-click: open the file and pin it (promoting it if it is
--- the current preview).
---@param path string absolute path
function M.open_permanent(path)
  M.open(path)
  local current = vim.api.nvim_get_current_buf()
  if M.is_preview(current) then
    M.promote(current)
  end
end

return M
