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

--- Copy the bundled annotated template on first use. An existing personal
--- file is never modified or replaced.
---@param template string
---@return string target
function M.ensure_user_config(template)
  local target = M.user_config_path()
  if vim.uv.fs_stat(target) ~= nil then
    return target
  end

  -- Older GUI builds pass config/superlemon.vim. Prefer the sibling minimal
  -- user template when available so first use never freezes a complete copy
  -- of the managed defaults into the user's override file.
  if vim.fs.basename(template) == "superlemon.vim" then
    local user_template = vim.fs.joinpath(vim.fs.dirname(template), "user-init.vim")
    if vim.fn.filereadable(user_template) == 1 then
      template = user_template
    end
  end

  assert(vim.fn.filereadable(template) == 1, "missing bundled user-init.vim")
  vim.fn.mkdir(vim.fs.dirname(target), "p")
  assert(
    vim.fn.writefile(vim.fn.readfile(template), target) == 0,
    "could not create " .. target
  )
  vim.uv.fs_chmod(target, 384) -- 0600
  return target
end

--- Structured startup diagnostics returned by bridge setup. User and custom
--- modes intentionally have no managed personal-file state unless the GUI
--- supplies their mode before setup.
---@return table
function M.config_status()
  local mode = vim.g.superlemon_config_mode or "external"
  local state = vim.g.superlemon_user_config_state
  if state == nil then
    state = mode == "managed" and "unknown" or "not_applicable"
  end

  local status = {
    mode = mode,
    state = state,
  }
  if vim.g.superlemon_config_path ~= nil then
    status.path = vim.g.superlemon_config_path
  end
  if vim.g.superlemon_config_error ~= nil then
    status.error = vim.g.superlemon_config_error
  end
  return status
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
    minimap_pitch = number_setting(vim.g.superlemon_minimap_pitch, 3.0, 1.0, 6.0),
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
