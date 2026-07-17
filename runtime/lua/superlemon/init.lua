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
---@param opts { compact: boolean, remote: boolean }|nil compact = the GUI
--- window started at a narrow width; sidebar/minimap then default off
--- (explicit g: globals win). remote = the session reached this nvim through
--- a host-supplied transport, so no local launch plan ran; the managed
--- configuration is adopted before any adapter reads option/global state.
function M.setup(channel, opts)
  if type(channel) ~= "number" or channel <= 0 then
    return {
      ready = false,
      reason = "invalid_channel",
      runtime_api = 1,
      config = require("superlemon.settings").config_status(),
    }
  end

  vim.g.superlemon_channel = channel

  -- No UI attached (e.g. plain `nvim --headless` without the GUI): stay inert.
  if #vim.api.nvim_list_uis() == 0 then
    return {
      ready = false,
      reason = "no_ui",
      runtime_api = 1,
      config = require("superlemon.settings").config_status(),
    }
  end

  -- Host-supplied transports (e.g. an ssh bridge to a remote nvim) never ran
  -- a local launch plan, so the managed baseline was not applied at startup.
  -- Adopt it before the adapters below read option/global state; a session
  -- whose startup already ran the managed init is left untouched.
  if opts and opts.remote then
    require("superlemon.managed").adopt()
  end

  -- All autocmds live in this augroup; clearing it makes setup() idempotent.
  local group = vim.api.nvim_create_augroup("superlemon", { clear = true })

  require("superlemon.status").setup(group)
  require("superlemon.clipboard").setup()
  require("superlemon.keymaps").setup()
  -- After every configuration file has run: a user 'statusline' wins over
  -- the managed theme (CONTRACT.md `superlemon.statusline`).
  require("superlemon.sltheme").apply()
  require("superlemon.chrome").setup(group, opts)
  local chrome = require("superlemon.chrome").state()
  require("superlemon.minimap").setup(
    group, chrome.native_minimap or chrome.native_scrollbars
  )
  require("superlemon.git").setup(group)
  require("superlemon.ui").setup()

  -- Keep the GUI's workspace (file sidebar, quick-open index) rooted at
  -- nvim's cwd when the user cds inside nvim (CONTRACT.md `superlemon.cwd`).
  vim.api.nvim_create_autocmd("DirChanged", {
    group = group,
    callback = function()
      if M.active() then
        vim.rpcnotify(vim.g.superlemon_channel, "superlemon.cwd", {
          cwd = vim.fn.getcwd(),
        })
      end
    end,
  })

  -- Seed the GUI with the current configuration and editor state right away.
  require("superlemon.settings").push()
  require("superlemon.status").push()

  return {
    ready = true,
    runtime_api = 1,
    config = require("superlemon.settings").config_status(),
  }
end

--- GUI menu entry point (View ▸ Native Tabs / Native Status Bar): the menu
--- is an affordance; this module's state is the truth (CONTRACT.md).
---@param part '"tabs"'|'"statusbar"'|'"minimap"'|'"scrollbars"'|'"sidebar"'
function M.chrome_toggle(part)
  require("superlemon.chrome").toggle(part)
end

return M
