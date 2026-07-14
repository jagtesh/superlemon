-- Recovery-only safe start keeps the bundled baseline but deliberately skips
-- executable personal configuration while retaining its path for diagnostics.
local H = dofile(vim.fs.dirname(arg[0]) .. "/helpers.lua")
H.setup_rtp()

local config_home = H.tmpdir() .. " safe config home"
local override_dir = vim.fs.joinpath(config_home, "superlemon")
vim.fn.mkdir(override_dir, "p")
vim.env.XDG_CONFIG_HOME = config_home
vim.env.SUPERLEMON_SAFE_START = "1"
local personal = vim.fs.joinpath(override_dir, "init.vim")
vim.fn.writefile({
  'let g:superlemon_safe_start_should_not_run = 1',
  'let g:superlemon_native_tabs = 0',
}, personal)

dofile(H.root() .. "/config/init.lua")

H.eq(vim.g.superlemon_safe_start_should_not_run, nil,
  "safe start skips the personal init")
H.eq(vim.g.superlemon_native_tabs, 1, "safe start retains the bundled baseline")
H.eq(require("superlemon.settings").config_status(), {
  mode = "managed",
  path = personal,
  state = "safe_start",
}, "safe start exposes structured recovery diagnostics")

H.finish()
