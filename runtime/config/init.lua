-- Superlemon's managed configuration.
--
-- Used when "Use Superlemon Config" is enabled in the app menu: nvim launches
-- with `-u` pointing here, so the user's own init (and its statusline /
-- bufferline plugins) never loads. This is the fully-native experience —
-- Superlemon's chrome replaces the in-grid equivalents.
--
-- Deliberately small: sensible defaults, native chrome on, nothing exotic.

vim.opt.termguicolors = true
vim.opt.number = true
vim.opt.signcolumn = "yes"
vim.opt.undofile = true
vim.opt.ignorecase = true
vim.opt.smartcase = true
vim.opt.splitright = true
vim.opt.splitbelow = true
vim.opt.updatetime = 250

-- Native chrome (see runtime/CONTRACT.md `superlemon.chrome`):
-- buffer tabs in the titlebar band, powerline bar + command input at the
-- bottom. The superlemon runtime plugin reads these at setup.
vim.g.superlemon_native_tabs = 1
vim.g.superlemon_native_statusbar = 1

-- THIS config (and only this config) releases the in-grid rows the native
-- bar replaces — the runtime plugin never touches these options, so a user
-- config keeps its own statusline/cmdline untouched (CONTRACT.md).
vim.opt.laststatus = 0
vim.opt.cmdheight = 0
vim.opt.showmode = false

-- Ships with nvim; calm and readable in both appearances.
vim.cmd.colorscheme("habamax")
