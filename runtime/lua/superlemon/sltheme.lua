-- superlemon.sltheme — built-in native status bar themes (CONTRACT.md
-- `superlemon.statusline`). `g:superlemon_statusline_theme` selects:
--
--   "powerline"  colored mode/git/file/position segments (the default)
--   "default"    no managed statusline; the native bar shows its plain
--                built-in chips
--
-- Applied at bridge setup, after every configuration file has run, so a
-- 'statusline' set by user configuration (lualine, airline, hand-written)
-- always wins. The powerline highlights are reapplied on ColorScheme:
-- loading or reloading a colorscheme clears user-defined groups, and the
-- Appearance setting legitimately reloads the colorscheme whenever
-- 'background' follows a system light/dark switch — the theme must
-- survive that. The segment palette is deliberately fixed rather than
-- appearance-derived; it reads well on both backgrounds.

local M = {}

local POWERLINE_GROUPS = {
  -- Mode badge colors.
  SLModeNormal = { fg = "#FFFFFF", bg = "#004DC8", bold = true },
  SLModeInsert = { fg = "#1B2023", bg = "#ADC694", bold = true },
  SLModeVisual = { fg = "#FFFFFF", bg = "#8E24AA", bold = true },
  SLModeReplace = { fg = "#FFFFFF", bg = "#C42B1C", bold = true },
  SLModeCommand = { fg = "#1B2023", bg = "#E0B268", bold = true },
  -- Remaining statusline segment colors.
  SLGit = { fg = "#CDD2D7", bg = "#4A4A49" },
  SLFile = { fg = "#CDD2D7", bg = "#373736" },
  SLInfo = { fg = "#A6ABB0", bg = "#2B2B2A" },
  SLPos = { fg = "#FFFFFF", bg = "#005A37", bold = true },
}

-- Human-readable labels and highlight groups for every editor mode.
local MODE_NAMES = {
  n = "NORMAL", i = "INSERT", v = "VISUAL", V = "V-LINE", ["\22"] = "V-BLOCK",
  c = "COMMAND", R = "REPLACE", s = "SELECT", S = "S-LINE", t = "TERMINAL",
}
local MODE_GROUPS = {
  n = "SLModeNormal", i = "SLModeInsert", v = "SLModeVisual",
  V = "SLModeVisual", ["\22"] = "SLModeVisual", c = "SLModeCommand",
  R = "SLModeReplace", t = "SLModeInsert",
}

-- Return the colored mode badge. The optional argument keeps the function
-- easy to exercise from :lua and from the runtime test suite.
function _G.superlemon_sl_mode(mode)
  mode = mode or vim.fn.mode()
  local key = mode:sub(1, 1)
  local group = MODE_GROUPS[key] or "SLModeNormal"
  local name = MODE_NAMES[key] or mode:upper()
  return "%#" .. group .. "# " .. name .. " "
end

-- Return a branch segment when the working directory belongs to a Git repo.
-- The bundled provider caches this lookup, so statusline evaluation is cheap.
function _G.superlemon_sl_git()
  local ok, status = pcall(require, "superlemon.status")
  local branch = ok and status.branch_for(vim.fn.getcwd()) or ""
  if branch == "" then
    return ""
  end
  return "%#SLGit# ⎇ " .. branch .. " "
end

-- The powerline layout: `%=` separates the left side from the
-- right-aligned informational segments.
local function powerline_expression()
  return table.concat({
    "%{%v:lua.superlemon_sl_mode()%}",
    "%{%v:lua.superlemon_sl_git()%}",
    "%#SLFile# %f %m%r ",
    "%=",
    "%#SLInfo# %{&filetype == '' ? 'text' : &filetype} ",
    "%#SLInfo# %{&fileencoding == '' ? &encoding : &fileencoding}[%{&fileformat}] ",
    "%#SLInfo# %p%% ",
    "%#SLPos# ln:%l/%L ≡ :%c ",
  })
end

local function apply_highlights()
  for name, attrs in pairs(POWERLINE_GROUPS) do
    vim.api.nvim_set_hl(0, name, attrs)
  end
end

--- Apply the selected theme. Idempotent; bridge re-setup calls it again.
---@return boolean applied true when the powerline theme was installed
function M.apply()
  local theme = vim.g.superlemon_statusline_theme or "powerline"
  local expression = powerline_expression()

  -- The user's configuration owns 'statusline' when it set one. Neovim
  -- 0.10+ ships a non-empty built-in default, so emptiness is no signal:
  -- an explicitly set option whose value is neither ours nor the built-in
  -- default is a user choice.
  local info = vim.api.nvim_get_option_info2("statusline", {})
  local user_owned = info.was_set
    and vim.o.statusline ~= expression
    and vim.o.statusline ~= info.default

  if theme ~= "powerline" then
    -- Retract a previously installed powerline expression (restoring the
    -- built-in default) so switching the theme and re-running setup does
    -- not strand it. A user's own 'statusline' is not ours to clear.
    if vim.o.statusline == expression then
      vim.o.statusline = info.default
    end
    pcall(vim.api.nvim_del_augroup_by_name, "superlemon_sltheme")
    return false
  end

  if user_owned then
    return false
  end

  apply_highlights()
  vim.o.statusline = expression
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("superlemon_sltheme", { clear = true }),
    desc = "superlemon: statusline theme survives colorscheme reloads",
    callback = apply_highlights,
  })
  return true
end

return M
