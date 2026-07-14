-- Diagnostic-only loader for custom mode.
--
-- Neovim handles errors thrown directly by `-u <file>` with an interactive
-- startup prompt before the embedded RPC client can inspect them. Loading the
-- one selected file here lets Superlemon retain its path and traceback without
-- applying any bundled defaults or sourcing anything afterward.

local path = vim.env.SUPERLEMON_CUSTOM_INIT
local diagnostic = {
  state = "loading",
  path = path,
}
vim.g.superlemon_custom_config = diagnostic

local function source_selected_init()
  assert(type(path) == "string" and path ~= "", "SUPERLEMON_CUSTOM_INIT is missing")
  vim.env.MYVIMRC = path
  if path:sub(-4):lower() == ".lua" then
    local chunk, load_error = loadfile(path)
    assert(chunk, load_error)
    return chunk()
  end
  vim.cmd("source " .. vim.fn.fnameescape(path))
end

local ok, result = xpcall(source_selected_init, debug.traceback)
if ok then
  diagnostic.state = "loaded"
else
  diagnostic.state = "error"
  diagnostic.error = {
    path = path,
    message = tostring(result),
  }
end
vim.g.superlemon_custom_config = diagnostic
