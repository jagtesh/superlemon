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
-- Native trackpads already provide acceleration and momentum. One logical
-- wheel step should therefore advance one grid cell; Neovim's terminal-first
-- default of three rows makes precise input visibly jump in chunks.
vim.opt.mousescroll = "ver:1,hor:1"

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

---------------------------------------------------------------------------
-- Statusline (powerline-style) ────────────────────────────────────────────
--
-- This is a PLAIN vim 'statusline' (:h 'statusline') — even though
-- laststatus=0 hides it in the grid, the native bar harvests whatever it
-- evaluates to (nvim_eval_statusline; CONTRACT.md superlemon.statusline).
-- CUSTOMIZE IT LIKE ANY VIMRC: edit the highlight colors, reorder the
-- segments, add your own %{} items — the native bar follows live.
---------------------------------------------------------------------------

local hl = vim.api.nvim_set_hl
-- Mode badge colors (mirrors the classic airline scheme + NORTHSTAR caps).
hl(0, "SLModeNormal", { fg = "#FFFFFF", bg = "#004DC8", bold = true })
hl(0, "SLModeInsert", { fg = "#1B2023", bg = "#ADC694", bold = true })
hl(0, "SLModeVisual", { fg = "#FFFFFF", bg = "#8E24AA", bold = true })
hl(0, "SLModeReplace", { fg = "#FFFFFF", bg = "#C42B1C", bold = true })
hl(0, "SLModeCommand", { fg = "#1B2023", bg = "#E0B268", bold = true })
hl(0, "SLGit", { fg = "#CDD2D7", bg = "#4A4A49" })
hl(0, "SLFile", { fg = "#CDD2D7", bg = "#373736" })
hl(0, "SLInfo", { fg = "#A6ABB0", bg = "#2B2B2A" })
hl(0, "SLPos", { fg = "#FFFFFF", bg = "#005A37", bold = true })

local MODE_NAMES = {
  n = "NORMAL", i = "INSERT", v = "VISUAL", V = "V-LINE", ["\22"] = "V-BLOCK",
  c = "COMMAND", R = "REPLACE", s = "SELECT", S = "S-LINE", t = "TERMINAL",
}
local MODE_GROUPS = {
  n = "SLModeNormal", i = "SLModeInsert", v = "SLModeVisual",
  V = "SLModeVisual", ["\22"] = "SLModeVisual", c = "SLModeCommand",
  R = "SLModeReplace", t = "SLModeInsert",
}

-- Mode badge: name and color react to the current mode. (`mode` argument
-- is for testing; it defaults to the live mode.)
function _G.superlemon_sl_mode(mode)
  mode = mode or vim.fn.mode()
  local key = mode:sub(1, 1)
  local group = MODE_GROUPS[key] or "SLModeNormal"
  local name = MODE_NAMES[key] or mode:upper()
  return "%#" .. group .. "# " .. name .. " "
end

-- Git branch segment (data from the superlemon plugin's cached provider;
-- empty outside a repository).
function _G.superlemon_sl_git()
  local ok, status = pcall(require, "superlemon.status")
  local branch = ok and status.branch_for(vim.fn.getcwd()) or ""
  if branch == "" then
    return ""
  end
  return "%#SLGit# ⎇ " .. branch .. " "
end

vim.o.statusline = table.concat({
  "%{%v:lua.superlemon_sl_mode()%}",
  "%{%v:lua.superlemon_sl_git()%}",
  "%#SLFile# %f %m%r ",
  "%=",  -- ── right side ──
  "%#SLInfo# %{&filetype == '' ? 'text' : &filetype} ",
  "%#SLInfo# %{&fileencoding == '' ? &encoding : &fileencoding}[%{&fileformat}] ",
  "%#SLInfo# %p%% ",
  "%#SLPos# ln:%l/%L ≡ :%c ",
})
