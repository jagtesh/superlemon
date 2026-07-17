-- remote_adopt_safe_spec.lua — safe start over a host-supplied transport:
-- adoption applies the bundled baseline but skips the executable personal
-- override, mirroring the local SUPERLEMON_SAFE_START semantics.
local H = dofile(vim.fs.dirname(arg[0]) .. "/helpers.lua")
H.setup_rtp()

local config_home = H.tmpdir()
vim.env.XDG_CONFIG_HOME = config_home
local override_dir = vim.fs.joinpath(config_home, "superlemon")
vim.fn.mkdir(override_dir, "p")
local personal = vim.fs.joinpath(override_dir, "init.vim")
vim.fn.writefile({ "set mousescroll=ver:4,hor:4" }, personal)

H.stub_gui()

-- The GUI bootstrap passes launch state "safe" when the user chose Start
-- Safely from recovery; the fallback assignment records it pre-setup.
vim.g.superlemon_config_mode = vim.g.superlemon_config_mode or "safe"
local readiness = require("superlemon").setup(7, { remote = true })

H.eq(readiness.ready, true, "bridge starts in remote safe start")
H.eq(readiness.config.mode, "managed", "safe adoption reports managed mode")
H.eq(readiness.config.state, "safe_start", "safe start skips the personal override")
H.eq(vim.o.mousescroll, "ver:1,hor:1",
  "bundled baseline applies without the personal override")

H.finish()
