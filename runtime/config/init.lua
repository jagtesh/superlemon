-- Superlemon's managed configuration.
--
-- Used when "Use Superlemon Config" is enabled in the app menu: nvim launches
-- with `-u` pointing here, so the user's own init (and its statusline /
-- bufferline plugins) never loads. This is the fully-native experience —
-- Superlemon's chrome replaces the in-grid equivalents.
--
-- Deliberately small: ordinary editor defaults and one example plugin.
-- Superlemon-specific behavior lives in the annotated sibling
-- `superlemon.vim`, which is sourced at the end of this file.

vim.opt.termguicolors = true
vim.opt.number = true
vim.opt.signcolumn = "yes"
vim.opt.undofile = true
vim.opt.ignorecase = true
vim.opt.smartcase = true
vim.opt.splitright = true
vim.opt.splitbelow = true
vim.opt.updatetime = 250

-- Ships with nvim; calm and readable in both appearances.
vim.cmd.colorscheme("habamax")

---------------------------------------------------------------------------
-- Plugins ─────────────────────────────────────────────────────────────────
--
-- Managed with nvim's BUILT-IN package manager (:h vim.pack, nvim 0.12+):
-- add/remove entries here like any vimrc — plugins are fetched on first
-- launch and loaded on every launch after. `:checkhealth vim.pack` to
-- inspect. nvim-surround gives Sublime-style ys/cs/ds surround editing.
---------------------------------------------------------------------------
pcall(function()
  vim.pack.add({
    { src = "https://github.com/kylechui/nvim-surround" },
  })
  require("nvim-surround").setup()
end)

-- Source the managed Superlemon settings by absolute path. The bundled
-- runtime is added to 'runtimepath' only after Neovim starts, so :runtime
-- cannot locate this sibling during init processing.
local init_path = debug.getinfo(1, "S").source:sub(2)
local superlemon_config = vim.fs.joinpath(vim.fs.dirname(init_path), "superlemon.vim")
vim.cmd("source " .. vim.fn.fnameescape(superlemon_config))

-- Personal Superlemon overrides live in their own XDG config directory.
-- Source them second so every value there wins over the bundled baseline.
local config_home = vim.env.XDG_CONFIG_HOME
if config_home == nil or config_home == "" then
  config_home = vim.fs.joinpath(vim.uv.os_homedir(), ".config")
end
local user_superlemon_config = vim.fs.joinpath(config_home, "superlemon", "init.vim")
if vim.fn.filereadable(user_superlemon_config) == 1 then
  vim.cmd("source " .. vim.fn.fnameescape(user_superlemon_config))
  vim.g.superlemon_user_config_loaded = user_superlemon_config
end
