-- :checkhealth superlemon

local M = {}

function M.check()
  local health = vim.health

  health.start("superlemon")

  local chan = vim.g.superlemon_channel
  if chan ~= nil then
    health.ok(("GUI RPC channel present (id %d)"):format(chan))
  else
    health.warn(
      "no GUI RPC channel (g:superlemon_channel unset)",
      "This is expected under plain terminal nvim; the plugin is inert there."
    )
  end

  local clipboard = require("superlemon.clipboard")
  local g_clip = vim.g.clipboard
  if clipboard.active then
    health.ok('clipboard provider "superlemon" registered for + and *')
  elseif g_clip ~= nil and g_clip ~= vim.NIL then
    local name = (type(g_clip) == "table" and g_clip.name) or "user-defined"
    health.info(("clipboard provider %q was already configured; superlemon skipped its own"):format(name))
  else
    health.warn("no clipboard provider registered (setup() not run?)")
  end

  local keymaps = require("superlemon.keymaps")
  if keymaps.installed > 0 then
    health.ok(("%d default <D-...> keymaps installed"):format(keymaps.installed))
  elseif vim.g.superlemon_default_keymaps == 0
    or vim.g.superlemon_default_keymaps == false
  then
    health.info("default keymaps disabled by g:superlemon_default_keymaps")
  else
    health.info("no default keymaps installed (setup() not run, or user maps cover them all)")
  end
end

return M
