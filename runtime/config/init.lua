-- Superlemon's managed configuration.
--
-- Used when Settings selects Superlemon's managed configuration (the default):
-- nvim launches with `-u` pointing here, so the user's own Neovim init (and its
-- statusline / bufferline plugins) never loads. This is the fully-native
-- experience — Superlemon's chrome replaces the in-grid equivalents.
--
-- Deliberately small: ordinary editor defaults, followed by the documented
-- Superlemon baseline and one optional personal override.
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

-- The managed experience should be syntax-colored without depending on the
-- user's normal Neovim init. Filetype detection selects the bundled syntax,
-- indent, and ftplugin rules; the native minimap consumes the same semantics.
vim.cmd("filetype plugin indent on")
vim.cmd("syntax enable")

-- Ships with nvim; calm and readable in both appearances.
vim.cmd.colorscheme("habamax")

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
vim.g.superlemon_config_mode = "managed"
vim.g.superlemon_config_path = user_superlemon_config

-- Set state before :source so recursive setup/config helpers cannot source the
-- same executable file again. A broken personal file does not prevent bridge
-- startup: retain its diagnostic and continue with the bundled baseline.
if vim.env.SUPERLEMON_SAFE_START == "1" then
  vim.g.superlemon_user_config_state = "safe_start"
  vim.g.superlemon_config_error = nil
elseif vim.g.superlemon_user_config_state == nil then
  if vim.fn.filereadable(user_superlemon_config) ~= 1 then
    vim.g.superlemon_user_config_state = "missing"
  else
    vim.g.superlemon_user_config_state = "loading"
    local ok, err = pcall(
      vim.cmd,
      "source " .. vim.fn.fnameescape(user_superlemon_config)
    )
    if ok then
      vim.g.superlemon_user_config_state = "loaded"
      vim.g.superlemon_user_config_loaded = user_superlemon_config
      vim.g.superlemon_config_error = nil
    else
      vim.g.superlemon_user_config_state = "error"
      vim.g.superlemon_config_error = {
        path = user_superlemon_config,
        message = tostring(err),
      }
    end
  end
end
