-- A broken managed personal config is diagnosed once without aborting the
-- bundled baseline or preventing the GUI bridge from becoming repairable.
local H = dofile(vim.fs.dirname(arg[0]) .. "/helpers.lua")
H.setup_rtp()

local config_home = H.tmpdir() .. " broken config home"
local override_dir = vim.fs.joinpath(config_home, "superlemon")
vim.fn.mkdir(override_dir, "p")
vim.env.XDG_CONFIG_HOME = config_home
local personal = vim.fs.joinpath(override_dir, "init.vim")
vim.fn.writefile({
  'let g:superlemon_error_source_count = get(g:, "superlemon_error_source_count", 0) + 1',
  'this-command-does-not-exist',
}, personal)

dofile(H.root() .. "/config/init.lua")

H.eq(vim.g.superlemon_error_source_count, 1, "broken personal config executes once")
H.eq(vim.g.superlemon_user_config_state, "error", "broken config records error state")
H.eq(vim.g.superlemon_config_error.path, personal, "diagnostic identifies the failing file")
H.ok(vim.g.superlemon_config_error.message:find("E492", 1, true) ~= nil,
  "diagnostic retains the Neovim source error")
H.eq(vim.g.superlemon_native_tabs, 1, "bundled baseline remains active")

H.stub_gui()
local readiness = require("superlemon").setup(9)
H.eq(readiness.ready, true, "bridge still starts so the config can be repaired")
H.eq(readiness.config.state, "error", "bridge returns config failure separately")
H.eq(readiness.config.error.path, personal, "bridge diagnostic retains config path")
H.eq(vim.g.superlemon_error_source_count, 1, "broken config remains source-once")

H.finish()
