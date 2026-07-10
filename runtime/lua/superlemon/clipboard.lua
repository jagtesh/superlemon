-- superlemon.clipboard — g:clipboard provider bridging registers + and *
-- to the native pasteboard via rpcrequest (the one place the contract
-- allows a blocking request: vim itself calls providers synchronously).

local M = {}

--- True when the "superlemon" provider is the registered g:clipboard.
M.active = false

local warned = false

local function copy(lines, regtype)
  local chan = vim.g.superlemon_channel
  if chan == nil then
    return
  end
  vim.rpcrequest(chan, "superlemon.clipboard_set", lines, regtype)
end

local function paste()
  local chan = vim.g.superlemon_channel
  if chan == nil then
    return { {}, "v" }
  end
  return vim.rpcrequest(chan, "superlemon.clipboard_get")
end

--- Register the provider. Only called from setup() (GUI present). Never
--- clobbers a user-configured g:clipboard: user config loads before us.
function M.setup()
  local existing = vim.g.clipboard
  if existing ~= nil and existing ~= vim.NIL then
    if type(existing) == "table" and existing.name == "superlemon" then
      -- our own provider from a previous setup(); nothing to do
      M.active = true
      return
    end
    if not warned then
      warned = true
      local name = (type(existing) == "table" and existing.name) or "user-defined"
      vim.notify(
        ("superlemon: existing clipboard provider %q found; leaving it in place"):format(name),
        vim.log.levels.INFO
      )
    end
    return
  end

  vim.g.clipboard = {
    name = "superlemon",
    copy = { ["+"] = copy, ["*"] = copy },
    paste = { ["+"] = paste, ["*"] = paste },
    cache_enabled = false,
  }
  M.active = true
end

return M
