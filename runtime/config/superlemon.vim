" Superlemon's Neovim and renderer settings.
"
" The bundled `init.lua` sources this copy as Superlemon's managed baseline,
" then sources $XDG_CONFIG_HOME/superlemon/init.vim (normally
" ~/.config/superlemon/init.vim) as the primary personal override. Settings >
" Edit Superlemon Configuration creates and opens that home-directory copy.
" When you select your own Neovim init instead of the managed config,
" Superlemon's runtime still sources the personal file once before bridge setup.
"
" Every boolean below uses 1 for enabled and 0 for disabled. Changes take
" effect on the next Superlemon launch because the runtime bridge reads one
" complete settings snapshot during setup.

" ---------------------------------------------------------------------------
" Smooth trackpad and mouse scrolling
" ---------------------------------------------------------------------------
"
" macOS already supplies acceleration and momentum. Treat each wheel event as
" one logical row/column so Superlemon's display-linked renderer receives fine
" grained movement instead of Neovim's terminal-oriented three-row jumps.
" Increase either number if you prefer faster, coarser wheel scrolling.
set mousescroll=ver:1,hor:1

" ---------------------------------------------------------------------------
" Native window chrome
" ---------------------------------------------------------------------------
"
" Show open buffers in Superlemon's native titlebar strip. Set to 0 to keep
" the strip hidden and use a Neovim tab/buffer plugin instead.
let g:superlemon_native_tabs = 1

" Show the native command/status bar along the bottom of the window. It
" displays Neovim's evaluated 'statusline', so statusline plugins still work.
" If you turn this off, also restore 'laststatus'/'showmode' in the row section
" below if you want those indicators drawn inside Neovim's grid.
let g:superlemon_native_statusbar = 1

" Move Neovim's statusline into the native bar while that bar is visible.
" To display both bars, set this to 0 and set 'laststatus' below to 2 or 3.
let g:superlemon_adopt_statusline = 1

" Hide Neovim's own tabline at startup when the native buffer strip is used.
" This is off by default because a tabline and a buffer list are not always
" equivalent. Set to 1 if your tabline/bufferline duplicates the native strip.
let g:superlemon_hide_tabline = 0

" Show a syntax-colored native minimap inside every sufficiently wide Neovim
" split. Narrow splits hide it automatically instead of covering useful text.
let g:superlemon_native_minimap = 1

" Keep the independent native overlay scrollbar hidden by default while the
" minimap provides document position. This can be enabled with or without the
" minimap.
let g:superlemon_native_scrollbars = 0

" Reclaim the grid rows replaced by native controls. `laststatus=0` hides the
" in-grid statusline, `cmdheight=0` lets the externalized command line use no
" permanent row, and `noshowmode` avoids duplicating the native mode badge.
set laststatus=0
set cmdheight=0
set noshowmode

" ---------------------------------------------------------------------------
" Native pickers and prompts
" ---------------------------------------------------------------------------
"
" Route vim.ui.select() and vim.ui.input() through Superlemon's native palette
" and text field. Set to 0 to keep Neovim's built-ins. A picker installed by
" your config before Superlemon starts always wins, regardless of this value.
let g:superlemon_native_ui = 1

" ---------------------------------------------------------------------------
" Default macOS keyboard shortcuts
" ---------------------------------------------------------------------------
"
" The runtime installs the shortcuts below only when that key is still
" unmapped in the corresponding mode. Set this to 0 to install none of them,
" or define just the mappings you want to replace in your config before the
" Superlemon bridge starts.
"
"   Command-S             save (normal, insert, visual)
"   Command-A             select all (normal, insert, visual)
"   Command-C / Command-X copy / cut (visual)
"   Command-Z             undo (normal, insert, visual)
"   Command-Shift-Z       redo (normal, insert)
"   Command-N             new buffer (normal, insert)
"   Command-= / - / 0     font zoom in / out / reset (normal, insert, visual)
let g:superlemon_default_keymaps = 1

" ---------------------------------------------------------------------------
" Editor font hooks
" ---------------------------------------------------------------------------
"
" Superlemon follows Neovim's standard 'guifont' and 'linespace' options.
" Leave them unset to use the native monospaced 13-point default. Examples:
"
"   set guifont=SF\ Mono:h13
"   set linespace=2
"
" Command-= and Command-- temporarily zoom that font. Command-0 returns to the
" configured 'guifont' size; zoom never rewrites this file.

" ---------------------------------------------------------------------------
" Text rendering
" ---------------------------------------------------------------------------
"
" Draw Powerline separators as crisp vector shapes. This makes Powerline
" statuslines work with an unpatched text font.
let g:superlemon_powerline_glyphs = 0

" Allow the selected font to shape standard coding ligatures such as `=>` and
" `!=`. Set to 0 to keep every source character as an independent glyph.
let g:superlemon_ligatures = 1

" Use the bundled FiraCode Nerd Font as a companion only for symbols and
" ligatures, while ordinary source text continues to use 'guifont'.
let g:superlemon_use_symbol_font = 0

" Always use Superlemon's built-in Powerline and ligature substitutions even
" when the active font claims native support. Usually useful only for testing
" or working around a broken font.
let g:superlemon_force_glyph_fallback = 0

" Native minimap geometry. Width and pitch are points; scale multiplies the
" editor font size for the Core Text miniature. Runtime settings clamp unsafe
" overrides before sending them to the GUI.
let g:superlemon_minimap_width = 88
let g:superlemon_minimap_scale = 0.20
let g:superlemon_minimap_pitch = 3.0

" Hide the minimap unless the split can retain at least this many editor
" columns after reserving its native gutter. A small hysteresis band prevents
" the minimap from flickering on and off while a split divider is dragged.
let g:superlemon_minimap_min_editor_columns = 40

" ---------------------------------------------------------------------------
" Native status bar appearance and contents
" ---------------------------------------------------------------------------
"
" The native bar renders the normal Neovim 'statusline'. The SL* highlight
" groups below control each segment's colors, while the final table controls
" segment order and text. You may replace this entire section with lualine,
" airline, or any ordinary statusline configuration; Superlemon harvests the
" evaluated result and its highlight groups rather than drawing a second bar.

lua << LUA
local hl = vim.api.nvim_set_hl

-- Mode badge colors. Each table is { foreground, background, bold? }.
hl(0, "SLModeNormal", { fg = "#FFFFFF", bg = "#004DC8", bold = true })
hl(0, "SLModeInsert", { fg = "#1B2023", bg = "#ADC694", bold = true })
hl(0, "SLModeVisual", { fg = "#FFFFFF", bg = "#8E24AA", bold = true })
hl(0, "SLModeReplace", { fg = "#FFFFFF", bg = "#C42B1C", bold = true })
hl(0, "SLModeCommand", { fg = "#1B2023", bg = "#E0B268", bold = true })

-- Remaining statusline segment colors.
hl(0, "SLGit", { fg = "#CDD2D7", bg = "#4A4A49" })
hl(0, "SLFile", { fg = "#CDD2D7", bg = "#373736" })
hl(0, "SLInfo", { fg = "#A6ABB0", bg = "#2B2B2A" })
hl(0, "SLPos", { fg = "#FFFFFF", bg = "#005A37", bold = true })

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

-- Reorder, add, or remove entries here like any normal Vim statusline.
-- `%=` separates the left side from the right-aligned informational segments.
vim.o.statusline = table.concat({
  "%{%v:lua.superlemon_sl_mode()%}",
  "%{%v:lua.superlemon_sl_git()%}",
  "%#SLFile# %f %m%r ",
  "%=",
  "%#SLInfo# %{&filetype == '' ? 'text' : &filetype} ",
  "%#SLInfo# %{&fileencoding == '' ? &encoding : &fileencoding}[%{&fileformat}] ",
  "%#SLInfo# %p%% ",
  "%#SLPos# ln:%l/%L ≡ :%c ",
})
LUA
