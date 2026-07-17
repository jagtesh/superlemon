-- remote_adopt_error_spec.lua — a broken personal override on the session
-- machine is diagnosed through the standard structured config error while
-- the adopted baseline stays active and the bridge remains repairable.
local H = dofile(vim.fs.dirname(arg[0]) .. "/helpers.lua")
H.setup_rtp()

local config_home = H.tmpdir()
vim.env.XDG_CONFIG_HOME = config_home
local override_dir = vim.fs.joinpath(config_home, "superlemon")
vim.fn.mkdir(override_dir, "p")
local personal = vim.fs.joinpath(override_dir, "init.vim")
vim.fn.writefile({
  'let g:superlemon_error_source_count = get(g:, "superlemon_error_source_count", 0) + 1',
  'this-command-does-not-exist',
}, personal)

H.stub_gui()

vim.g.superlemon_config_mode = vim.g.superlemon_config_mode or "custom"
local readiness = require("superlemon").setup(7, { remote = true })

H.eq(readiness.ready, true, "bridge still starts so the config can be repaired")
H.eq(readiness.config.mode, "managed", "adoption reports the managed mode")
H.eq(readiness.config.state, "error", "broken override records error state")
H.eq(readiness.config.error.path, personal, "diagnostic identifies the failing file")
H.ok(readiness.config.error.message:find("E492", 1, true) ~= nil,
  "diagnostic retains the Neovim source error")
H.eq(vim.g.superlemon_error_source_count, 1, "broken override executes once")
H.eq(vim.o.mousescroll, "ver:1,hor:1", "adopted baseline remains active")

-- Re-setup keeps the source-once guarantee.
require("superlemon").setup(7, { remote = true })
H.eq(vim.g.superlemon_error_source_count, 1, "broken override remains source-once")

H.finish()
