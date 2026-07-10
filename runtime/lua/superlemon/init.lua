-- superlemon.nvim — nvim-side half of the Superlemon GUI bridge.
-- See runtime/CONTRACT.md. The GUI calls:
--   require('superlemon').setup(channel_id)
-- after nvim_ui_attach. Requiring this module under plain terminal nvim
-- has no side effects; everything happens in setup().

local M = {}

--- True when we are attached to the Superlemon GUI (per CONTRACT.md the
--- plugin must be a no-op under plain terminal nvim).
---@return boolean
function M.active()
  return vim.g.superlemon_channel ~= nil and #vim.api.nvim_list_uis() > 0
end

--- Idempotent entry point called by the GUI over RPC.
---@param channel integer RPC channel id of the GUI
function M.setup(channel)
  if type(channel) ~= "number" or channel <= 0 then
    return
  end

  vim.g.superlemon_channel = channel

  -- No UI attached (e.g. plain `nvim --headless` without the GUI): stay inert.
  if #vim.api.nvim_list_uis() == 0 then
    return
  end

  -- All autocmds live in this augroup; clearing it makes setup() idempotent.
  local group = vim.api.nvim_create_augroup("superlemon", { clear = true })

  require("superlemon.status").setup(group)
  require("superlemon.clipboard").setup()
  require("superlemon.keymaps").setup()
  require("superlemon.chrome").setup(group)

  -- Seed the GUI with the current state right away.
  require("superlemon.status").push()
end

--- GUI menu entry point (View ▸ Native Tabs / Native Status Bar): the menu
--- is an affordance; this module's state is the truth (CONTRACT.md).
---@param part '"tabs"'|'"statusbar"'
function M.chrome_toggle(part)
  require("superlemon.chrome").toggle(part)
end

return M
