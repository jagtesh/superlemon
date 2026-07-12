-- superlemon.settings — pushes renderer preferences from the Neovim config
-- to the native GUI. See CONTRACT.md `superlemon.settings`.

local M = {}

--- Absolute path of the primary personal Superlemon configuration.
---@return string
function M.user_config_path()
  local config_home = vim.env.XDG_CONFIG_HOME
  if config_home == nil or config_home == "" then
    config_home = vim.fs.joinpath(vim.uv.os_homedir(), ".config")
  end
  return vim.fs.joinpath(config_home, "superlemon", "init.vim")
end

--- Source the personal configuration once. The managed internal init loads it
--- before runtimepath is available and records the same marker; custom/user
--- init launches arrive here without the marker and are covered as well.
---@return boolean sourced
function M.source_user_config()
  local path = M.user_config_path()
  if vim.g.superlemon_user_config_loaded == path then
    return false
  end
  if vim.fn.filereadable(path) ~= 1 then
    return false
  end
  vim.cmd("source " .. vim.fn.fnameescape(path))
  vim.g.superlemon_user_config_loaded = path
  return true
end

--- Copy the bundled annotated template on first use. An existing personal
--- file is never modified or replaced.
---@param template string
---@return string target
function M.ensure_user_config(template)
  local target = M.user_config_path()
  if vim.fn.filereadable(target) == 1 then
    return target
  end
  assert(vim.fn.filereadable(template) == 1, "missing bundled superlemon.vim")
  vim.fn.mkdir(vim.fs.dirname(target), "p")
  assert(
    vim.fn.writefile(vim.fn.readfile(template), target) == 0,
    "could not create " .. target
  )
  return target
end

--- Interpret the public 1/0-or-boolean convention used by Superlemon globals.
---@param value any
---@param default boolean
---@return boolean
local function boolean_setting(value, default)
  if value == nil or value == vim.NIL then
    return default
  end
  return value == 1 or value == true
end

--- Keep public numeric rendering preferences finite and inside the native
--- renderer's supported range. Invalid values fall back to the documented
--- default instead of crossing the wire as NaN/Inf or an unusable size.
---@param value any
---@param default number
---@param minimum number
---@param maximum number
---@return number
local function number_setting(value, default, minimum, maximum)
  if type(value) ~= "number" or value ~= value
    or value == math.huge or value == -math.huge
  then
    return default
  end
  return math.max(minimum, math.min(maximum, value))
end

--- Return the complete renderer-settings payload. Keeping this pure makes the
--- defaults explicit and lets the GUI replace its whole settings snapshot.
---@return table
function M.payload()
  return {
    powerline_glyphs = boolean_setting(vim.g.superlemon_powerline_glyphs, false),
    ligatures = boolean_setting(vim.g.superlemon_ligatures, true),
    use_symbol_font = boolean_setting(vim.g.superlemon_use_symbol_font, false),
    force_glyph_fallback = boolean_setting(vim.g.superlemon_force_glyph_fallback, false),
    minimap_width = number_setting(vim.g.superlemon_minimap_width, 88, 48, 160),
    minimap_scale = number_setting(vim.g.superlemon_minimap_scale, 0.20, 0.10, 0.50),
    minimap_pitch = number_setting(vim.g.superlemon_minimap_pitch, 2.0, 1.0, 6.0),
    minimap_min_editor_columns = number_setting(
      vim.g.superlemon_minimap_min_editor_columns, 40, 20, 120),
  }
end

--- Push the current renderer settings. No-op outside the Superlemon GUI.
function M.push()
  if not require("superlemon").active() then
    return
  end
  vim.rpcnotify(vim.g.superlemon_channel, "superlemon.settings", M.payload())
end

return M
