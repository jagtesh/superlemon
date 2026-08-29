" Superlemon's Neovim and renderer settings.
"
" The bundled `init.lua` sources this copy as Superlemon's managed baseline,
" then sources $XDG_CONFIG_HOME/superlemon/init.vim (normally
" ~/.config/superlemon/init.vim) as the primary personal override. Settings >
" Edit Superlemon Configuration creates and opens that home-directory copy.
" Normal-user and custom-init modes bypass both this managed baseline and its
" personal override. Host-supplied transport sessions (remote nvim) adopt
" this same baseline and the session machine's personal override at bridge
" setup instead (CONTRACT.md "Managed adoption").
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

" Neovim only moves the cursor's line during a wheel scroll when the scroll
" would otherwise push it out of the window, and when it does it still
" applies the cursor's remembered column (curswant), so the column hops
" left/right as it lands on lines of different lengths. The runtime installs
" default <ScrollWheelUp>/<ScrollWheelDown> mappings (normal, insert, visual)
" that park the cursor at column 0 only while a gesture is actively dragging
" it, then restore the remembered column once the gesture ends — so the
" cursor never jitters mid-scroll but still ends up exactly where plain
" Neovim scrolling would have left it. Keyboard scrolling (Command-D, `j`,
" `zz`, ...) is unaffected, and a mapping you define for these keys before
" the Superlemon bridge starts always wins. Set to 0 to disable.
let g:superlemon_scroll_homes_cursor = 1

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
" On by default; when the window starts narrower than ~800 pt it starts hidden
" instead. Uncomment to force a value either way (an explicit setting always
" wins over the narrow-window default).
" let g:superlemon_native_minimap = 1

" Show the native file-navigation sidebar. On by default; when the window
" starts narrower than ~800 pt it starts hidden instead. Uncomment to force a
" value either way (an explicit setting always wins over the narrow-window
" default). Toggle at runtime with :SuperlemonChrome sidebar toggle or Cmd-B.
" let g:superlemon_native_sidebar = 1

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
" Native status bar theme
" ---------------------------------------------------------------------------
"
" The native bar renders the normal Neovim 'statusline'. Superlemon ships two
" built-in themes, applied at bridge startup only when your configuration has
" not set a 'statusline' of its own:
"
"   powerline   colored mode/git/file/position segments (the default; its
"               fixed palette is independent of the Appearance setting and
"               survives colorscheme reloads)
"   default     no managed statusline; the bar shows its plain built-in chips
"
" Any ordinary statusline configuration (lualine, airline, or a hand-written
" 'statusline') simply wins: Superlemon harvests the evaluated result and its
" highlight groups rather than drawing a second bar. The theme definitions
" live in the runtime's lua/superlemon/sltheme.lua.
let g:superlemon_statusline_theme = get(g:, 'superlemon_statusline_theme', 'powerline')
