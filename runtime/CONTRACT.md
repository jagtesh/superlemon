# superlemon.nvim ↔ GUI RPC contract

The bundled runtime plugin (`runtime/lua/superlemon/`) is the nvim-side half
of the bridge (DESIGN.md §9). This file is the FIXED contract between the Lua
plugin and the Swift app — both sides are implemented against it. Change it
only by changing both sides together.

## Bootstrap

After `nvim_ui_attach`, the GUI runs:

```
nvim_command("set runtimepath^=<path-to-runtime-dir>")
nvim_exec_lua("require('superlemon').setup(...)", [channel_id])
```

where `channel_id` is the GUI's RPC channel (from `nvim_get_api_info`).
`setup()` must be idempotent and must never error if called twice.

## nvim → GUI notifications  (`vim.rpcnotify(chan, method, payload)`)

### `superlemon.status`
One map argument; pushed on `ModeChanged`, `BufEnter`, `BufModifiedSet`,
`CursorMoved`/`CursorMovedI` (debounced ~100 ms via `vim.uv` timer), and
`DirChanged`:

```lua
{
  mode = "n",             -- vim.api.nvim_get_mode().mode (raw)
  file = "Sources/a.swift",  -- buffer name relative to cwd, "" if unnamed
  modified = true,
  line = 42, col = 7,        -- 1-based cursor
  total_lines = 310,
  branch = "main",           -- git branch or "" (see below)
  project = "superlemon",    -- basename of cwd
}
```

Branch: read `.git/HEAD` with `vim.uv.fs_*` (no shelling out per keystroke),
cached per cwd, refreshed on `DirChanged`/`FocusGained`.

### `superlemon.chrome`
One map argument; pushed at setup and whenever a toggle flips:

```lua
{ native_tabs = false, native_statusbar = false }
```

Sources of truth (in order): `vim.g.superlemon_native_tabs` /
`vim.g.superlemon_native_statusbar` (read at setup; 1/true = on), then the
user command `:SuperlemonChrome (tabs|statusbar) (on|off|toggle)`. The GUI's
View-menu items call `require('superlemon').chrome_toggle(...)` — nvim state
is the single source of truth; the GUI only reflects notifications.

**Faithfulness rule: the toggles have NO side effects on user options.**
Turning native chrome on shows the GUI's tabs/bar and nothing else — if the
loaded config draws its own statusline/bufferline, both appear until the user
resolves it in their config (`laststatus=0`, disabling the plugin, etc.).
Superlemon's internal init sources the annotated bundled baseline
`runtime/config/superlemon.vim`, then sources the primary personal override at
`$XDG_CONFIG_HOME/superlemon/init.vim` (normally
`~/.config/superlemon/init.vim`) when present. Thus the home-directory file
wins setting-by-setting without modifying the bundled runtime. When a custom
or user Neovim init bypasses the internal managed init, runtime bootstrap still
sources the personal Superlemon init once before `setup()`.

### `superlemon.settings`
One complete renderer-settings map, pushed at every `setup()`:

```lua
{
  powerline_glyphs = false,
  ligatures = true,
  use_symbol_font = false,
  force_glyph_fallback = false,
}
```

Values come from `g:superlemon_powerline_glyphs`,
`g:superlemon_ligatures`, `g:superlemon_use_symbol_font`, and
`g:superlemon_force_glyph_fallback`. Each accepts `1`/`true` for enabled and
`0`/`false` for disabled. Ligatures default to enabled when unset; the other
three settings default to disabled. The complete snapshot lets the GUI apply
configuration atomically without retaining values from an earlier setup.

### `superlemon.buffers`
One map argument; pushed (debounced ~50 ms) on BufAdd/BufDelete/BufEnter/
BufFilePost/BufModifiedSet while `native_tabs` is on, plus once when it
turns on:

```lua
{
  current = 3,                     -- current buffer number
  buffers = {                      -- listed buffers, stable order
    { bufnr = 3, name = "Sources/a.swift", modified = false, preview = false },
    ...                            -- name cwd-relative, "" if unnamed
  },
}
```

GUI tab actions go through standard API: click →
`nvim_set_current_buf`, close → `confirm bdelete N` via `nvim_command`.

**Preview buffers (VS Code/Sublime semantics, superlemon.preview module):**
at most one buffer is the preview (`preview = true`; the GUI renders its tab
italic). Sidebar single-click → `require('superlemon.preview').open(path)`:
switches if the file is already open, otherwise replaces the previous clean
preview. Double-click (file or tab) → `.promote()`. Editing a preview
promotes it automatically; a modified preview is promoted, never discarded,
when a new preview replaces it.

### `superlemon.statusline`
One map argument; pushed on the `superlemon.status` cadence, but ONLY while
`native_statusbar` is on (plus once when it turns on):

```lua
{
  segments = {                        -- the USER'S statusline, evaluated
    { text = " NORMAL ", fg = 0x1B2023, bg = 0xADC694, bold = true, italic = false },
    ...
  } | vim.NIL,                        -- NIL: statusline evaluated to nothing
}                                     -- (rare; nvim 0.12's default is non-empty)
```

Produced by `nvim_eval_statusline(&statusline, {highlights = true})` on the
current window — powerline/lualine/airline content comes through with its
real colors (groups resolved via `nvim_get_hl`, links followed; fg/bg are
24-bit ints, absent = use the bar's defaults). The GUI renders these segments
INSTEAD of its built-in chips; NIL segments fall back to the chips.
Customization therefore lives where it always did: the user's statusline
config.

**Adopt mode (default):** while the native bar is on, the plugin sets
`laststatus=0` (saving the user's value, restored exactly when toggled off) —
the statusline RELOCATES from the grid into the native bar, where the
harvested segments display the same content. This is the deliberate meaning
of the toggle: the statusline lives at the bottom of the Superlemon window,
not inside the nvim grid. It remains faithful because the content is the
user's own statusline and the round trip is lossless. Opt out with
`vim.g.superlemon_adopt_statusline = 0` to keep both bars. No other option
is ever touched.

### `superlemon.font`
`{ delta = 1 | -1 | 0 }` — GUI adjusts guifont size (+/-) or resets to default.

### `superlemon.save_as`
No payload. The default `<D-s>` mapping emits this for an unnamed buffer;
the GUI presents its native Save As sheet and completes the operation through
Neovim's `:saveas`. Named buffers use `:write` directly. A user-owned
`<D-s>` mapping replaces this default flow as usual.

### `superlemon.git`
One map argument; pushed (debounced ~150 ms) on BufWritePost/FocusGained/
DirChanged/VimResume plus once at setup. Gathered asynchronously via
`vim.system git status --porcelain` — the plugin is a DATA PROVIDER only;
the GUI sidebar renders the badges:

```lua
{
  files = {                          -- cwd-relative; empty = clean/not a repo
    { path = "Sources/a.swift", status = "M" },
    { path = "new.txt", status = "?" },
    ...   -- status: M A D R C U ? (worktree column, else index column)
  },
}
```

### `superlemon.ui` — the component framework (DESIGN §15)

One generic notification; array payload `[component, method, namespace, args]`
(component/method/namespace strings, args a map). Colors are `"#RRGGBB"`
strings. v1 components:

| component | methods | args |
|---|---|---|
| `sidebar` | `set_badge` | `{path, text, color?}` (path cwd-relative) |
| | `set_dot` | `{path, color}` |
| | `clear` | `{}` (this namespace only) |
| `palette` | `open` | `{placeholder?, query_cb, select_cb, close_cb?}` (cb = int callback id) |
| | `close` | `{}` |
| `toast` | `show` | `{text, kind}` kind ∈ info/warn/error |
| `statusbar` | `set_segment` | `{text, color?}` |
| | `clear` | `{}` |
| `input` | `open` | `{prompt?, default?, submit_cb}` (Enter → cb(text), Esc → cb(nil)) |

Namespaces isolate plugins: a namespace's `clear` never touches another's
state; the GUI composes namespaces sorted by name. GUI invokes Lua callbacks
via blocking request:

```
nvim_exec_lua("return require('superlemon.ui')._dispatch(...)", [cb_id, payload])
```

For `query_cb` the payload is `{query = "..."}` and the return value is
`{ {id, title, subtitle?, positions?}, ... }` (positions = 1-based match
indices into title for bold rendering). `select_cb` gets `{id = ...}`,
fire-and-forget. Callback ids are freed when the palette/input closes.

Lua public API (`require("superlemon.ui")`): `sidebar.namespace(name)` →
`ns:set_badge(path, opts)` / `ns:set_dot(path, opts)` / `ns:clear()`;
`palette.open{placeholder, on_query, on_select, on_close}` / `palette.close()`;
`toast{text, kind}`; `statusbar.segment(ns, opts)` / `statusbar.clear(ns)`;
`input{prompt, default, on_submit}`. At setup, `vim.ui.select` and
`vim.ui.input` are overridden to route to palette/input (skipped if the user
already replaced them; opt out with `g:superlemon_native_ui = 0`).

## nvim → GUI requests  (`vim.rpcrequest(chan, method, ...)`)

### `superlemon.clipboard_get` → `[lines, regtype]`
### `superlemon.clipboard_set(lines, regtype)` → any
Registered as `g:clipboard` provider named "superlemon" for registers `+`
and `*`. `lines` is a list of strings, `regtype` "v"/"V"/"b".

## GUI → nvim  (all via `nvim_input` / standard API — no custom methods)

- Every ⌘-chord arrives as `<D-x>` through `nvim_input`. The plugin defines
  DEFAULT mappings for: `<D-s>` save, `<D-a>` select all, `<D-c>` `"+y`,
  `<D-x>` `"+d` (visual), `<D-z>` undo / `<D-S-z>` redo, `<D-n>` `:enew`,
  `<D-=>`/`<D-->`/`<D-0>` font size (call `superlemon.font_bump(1|-1|0)`
  which rpcnotifies `superlemon.font` with `{delta = n}`). Use
  `vim.keymap.set` with `{silent = true}`; do NOT pass `unique` — user config
  loaded before us must win, so guard each with
  `vim.fn.maparg(lhs, mode) == ""`. Set
  `g:superlemon_default_keymaps = 0` to disable every default at once.
- Sidebar file operations use `:edit`/`:drop` via `nvim_command` (GUI side).

## Guarantees

- The plugin must be a no-op under plain terminal nvim (guard on
  `#vim.api.nvim_list_uis() > 0 and vim.g.superlemon_channel ~= nil`).
- `setup()` stores the channel in `vim.g.superlemon_channel`.
- All autocmds live in augroup `superlemon` (cleared on re-setup).
- Never block: no `rpcrequest` from the plugin outside the clipboard
  provider (which vim itself calls synchronously by design).
