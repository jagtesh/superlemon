-- remote_adopt_spec.lua — bridge setup with `remote = true` adopts the
-- managed configuration on a session whose startup ran a foreign config
-- (CONTRACT.md "Managed adoption"). The session machine's own personal
-- override still wins setting by setting, and adoption is one-shot.
local H = dofile(vim.fs.dirname(arg[0]) .. "/helpers.lua")
H.setup_rtp()

-- The "remote home": a personal override exists on the session machine.
local config_home = H.tmpdir()
vim.env.XDG_CONFIG_HOME = config_home
local override_dir = vim.fs.joinpath(config_home, "superlemon")
vim.fn.mkdir(override_dir, "p")
local personal = vim.fs.joinpath(override_dir, "init.vim")
vim.fn.writefile({ "set mousescroll=ver:2,hor:2" }, personal)

-- Pretend the far side's own startup already ran: terminal-oriented options
-- and no managed globals, exactly what an ssh-bridged nvim looks like.
vim.o.mousescroll = "ver:5,hor:6"
vim.o.laststatus = 2

H.stub_gui()

-- The GUI bootstrap sets the launch-state fallback before setup, and remote
-- transports report mode "custom" (no local plan ran).
vim.g.superlemon_config_mode = vim.g.superlemon_config_mode or "custom"
local readiness = require("superlemon").setup(7, { remote = true })

H.eq(readiness.ready, true, "bridge starts on the adopted session")
H.eq(readiness.config.mode, "managed", "adoption reports the managed mode")
H.eq(readiness.config.state, "loaded", "personal override was sourced")

H.eq(vim.o.mousescroll, "ver:2,hor:2",
  "session machine's personal override wins over the adopted baseline")
H.eq(vim.g.superlemon_native_tabs, 1, "managed chrome globals adopted")
H.eq(vim.g.superlemon_native_statusbar, 1, "native statusbar adopted")
H.ok(vim.o.statusline ~= "", "managed statusline adopted")
H.eq(vim.g.superlemon_config_path, personal,
  "config path identifies the session machine's override")

-- laststatus: superlemon.vim sets 0, then chrome adopt-mode manages it while
-- the native bar is on. Either way the in-grid statusline row is released.
H.eq(vim.o.laststatus, 0, "in-grid statusline released after adoption")

-- Re-setup must not re-source configuration: a live option changed after
-- adoption survives the second setup untouched.
vim.o.mousescroll = "ver:9,hor:9"
local second = require("superlemon").setup(7, { remote = true })
H.eq(second.ready, true, "re-setup stays ready")
H.eq(vim.o.mousescroll, "ver:9,hor:9", "adoption is one-shot across re-setup")
H.eq(second.config.mode, "managed", "re-setup still reports managed mode")

H.finish()
