-- Renderer settings are sent as one complete, typed payload at setup.
local H = dofile(vim.fs.dirname(arg[0]) .. "/helpers.lua")
H.setup_rtp()

local settings = require("superlemon.settings")

local config_home = H.tmpdir() .. " config home"
vim.fn.mkdir(config_home, "p")
vim.env.XDG_CONFIG_HOME = config_home
local expected_path = vim.fs.joinpath(config_home, "superlemon", "init.vim")
H.eq(settings.user_config_path(), expected_path, "personal config path honors XDG_CONFIG_HOME")

local template = H.root() .. "/config/superlemon.vim"
local target = settings.ensure_user_config(template)
H.eq(target, expected_path, "ensure returns the personal config path")
H.eq(vim.fn.readfile(target), vim.fn.readfile(template), "first ensure copies the template exactly")

vim.fn.writefile({ 'let g:superlemon_settings_source_marker = "personal"' }, target)
H.eq(settings.ensure_user_config(template), target, "ensure returns an existing personal config")
H.eq(vim.fn.readfile(target), {
  'let g:superlemon_settings_source_marker = "personal"',
}, "ensure never overwrites an existing personal config")
H.eq(settings.source_user_config(), true, "personal config sources when not already loaded")
H.eq(vim.g.superlemon_settings_source_marker, "personal", "personal config takes effect")
H.eq(settings.source_user_config(), false, "personal config is sourced only once")

H.eq(settings.payload(), {
  powerline_glyphs = false,
  ligatures = true,
  use_symbol_font = false,
  force_glyph_fallback = false,
  minimap_width = 88,
  minimap_scale = 0.20,
  minimap_pitch = 2.0,
  minimap_min_editor_columns = 40,
}, "renderer settings have stable defaults")

-- Requiring or pushing the module without the GUI remains inert.
local calls = H.stub_gui()
settings.push()
H.eq(#calls.notify, 0, "settings push without a GUI channel is a no-op")

vim.g.superlemon_powerline_glyphs = 1
vim.g.superlemon_ligatures = 0
vim.g.superlemon_use_symbol_font = true
vim.g.superlemon_force_glyph_fallback = false
vim.g.superlemon_minimap_width = 104
vim.g.superlemon_minimap_scale = 0.25
vim.g.superlemon_minimap_pitch = 2.5
vim.g.superlemon_minimap_min_editor_columns = 52

require("superlemon").setup(7)

local function settings_calls()
  return vim.tbl_filter(function(call)
    return call.method == "superlemon.settings"
  end, calls.notify)
end

local pushed = settings_calls()
H.eq(#pushed, 1, "setup pushes renderer settings once")
H.eq(pushed[1].chan, 7, "settings target the stored GUI channel")
H.eq(pushed[1].args[1], {
  powerline_glyphs = true,
  ligatures = false,
  use_symbol_font = true,
  force_glyph_fallback = false,
  minimap_width = 104,
  minimap_scale = 0.25,
  minimap_pitch = 2.5,
  minimap_min_editor_columns = 52,
}, "setup sends every configured renderer setting")

-- Unsafe numeric values are clamped or replaced before crossing the wire.
vim.g.superlemon_minimap_width = 999
vim.g.superlemon_minimap_scale = 0 / 0
vim.g.superlemon_minimap_pitch = -4
vim.g.superlemon_minimap_min_editor_columns = 999
H.eq(settings.payload().minimap_width, 160, "minimap width clamps to supported maximum")
H.eq(settings.payload().minimap_scale, 0.20, "NaN minimap scale returns to default")
H.eq(settings.payload().minimap_pitch, 1.0, "minimap pitch clamps to supported minimum")
H.eq(settings.payload().minimap_min_editor_columns, 120,
  "minimap editor-width threshold clamps to supported maximum")

-- Restore the configured snapshot before the repeated-setup assertion.
vim.g.superlemon_minimap_width = 104
vim.g.superlemon_minimap_scale = 0.25
vim.g.superlemon_minimap_pitch = 2.5
vim.g.superlemon_minimap_min_editor_columns = 52

-- A repeated setup is safe and emits one fresh, complete snapshot.
require("superlemon").setup(7)
pushed = settings_calls()
H.eq(#pushed, 2, "repeated setup pushes one fresh settings snapshot")
H.eq(pushed[2].args[1], pushed[1].args[1], "repeated setup preserves the payload")

H.finish()
