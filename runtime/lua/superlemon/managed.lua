-- superlemon.managed — Superlemon's managed configuration as a callable
-- module. The bundled `config/init.lua` applies it during a `-u` launch;
-- bridge setup adopts it on host-supplied transport sessions (remote nvim)
-- whose startup never ran a local launch plan (CONTRACT.md "Managed
-- adoption"). Both paths share the exact same defaults, baseline, personal
-- override, and state-marker semantics.

local M = {}

--- Absolute path of the bundled config directory, resolved relative to this
--- file so the same lookup works from the local app bundle and from a
--- runtime directory deployed on a remote host, independent of runtimepath
--- search order.
---@return string
local function config_dir()
  local source = debug.getinfo(1, "S").source:sub(2)
  -- …/runtime/lua/superlemon/managed.lua → …/runtime/config
  local runtime_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
  return vim.fs.joinpath(runtime_root, "config")
end

--- Ordinary editor defaults for the fully-native experience. Deliberately
--- small; Superlemon-specific behavior lives in the annotated
--- `config/superlemon.vim`, sourced afterwards.
local function apply_editor_defaults()
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
end

--- Apply the complete managed configuration: editor defaults, the annotated
--- baseline, then the personal override with the standard state markers.
--- A broken personal file does not abort — its diagnostic is retained in
--- `g:superlemon_config_error` and the bundled baseline stays active.
---@param opts { safe_start: boolean }|nil safe_start skips the executable
--- personal override and records state `safe_start`.
function M.apply(opts)
  opts = opts or {}

  apply_editor_defaults()

  local baseline = vim.fs.joinpath(config_dir(), "superlemon.vim")
  vim.cmd("source " .. vim.fn.fnameescape(baseline))

  local user_config = require("superlemon.settings").user_config_path()
  vim.g.superlemon_config_mode = "managed"
  vim.g.superlemon_config_path = user_config

  -- Set state before :source so recursive setup/config helpers cannot source
  -- the same executable file again.
  if opts.safe_start then
    vim.g.superlemon_user_config_state = "safe_start"
    vim.g.superlemon_config_error = nil
  elseif vim.g.superlemon_user_config_state == nil then
    if vim.fn.filereadable(user_config) ~= 1 then
      vim.g.superlemon_user_config_state = "missing"
    else
      vim.g.superlemon_user_config_state = "loading"
      local ok, err = pcall(
        vim.cmd,
        "source " .. vim.fn.fnameescape(user_config)
      )
      if ok then
        vim.g.superlemon_user_config_state = "loaded"
        vim.g.superlemon_user_config_loaded = user_config
        vim.g.superlemon_config_error = nil
      else
        vim.g.superlemon_user_config_state = "error"
        vim.g.superlemon_config_error = {
          path = user_config,
          message = tostring(err),
        }
      end
    end
  end
end

--- Bridge-time adoption for host-supplied transport sessions. Such a
--- session's nvim was started by the far side, so no local `-u` launch plan
--- applied the managed configuration. Adopting layers the managed experience
--- over whatever the far side's startup loaded; the personal override read
--- here is the session machine's own `$XDG_CONFIG_HOME/superlemon/init.vim`.
--- A session whose startup already ran the managed init is left untouched,
--- which also makes repeated bridge setup idempotent.
---@return boolean adopted
function M.adopt()
  if vim.g.superlemon_config_mode == "managed" then
    return false
  end
  M.apply({ safe_start = vim.g.superlemon_config_mode == "safe" })
  return true
end

return M
