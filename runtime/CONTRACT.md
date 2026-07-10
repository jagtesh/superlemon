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
Superlemon's managed config (runtime/config/init.lua) makes those choices for
the fully-native experience; a user config is never modified.

### `superlemon.buffers`
One map argument; pushed (debounced ~50 ms) on BufAdd/BufDelete/BufEnter/
BufFilePost/BufModifiedSet while `native_tabs` is on, plus once when it
turns on:

```lua
{
  current = 3,                     -- current buffer number
  buffers = {                      -- listed buffers, stable order
    { bufnr = 3, name = "Sources/a.swift", modified = false },
    ...                            -- name cwd-relative, "" if unnamed
  },
}
```

GUI tab actions go through standard API: click →
`nvim_set_current_buf`, close → `confirm bdelete N` via `nvim_command`.

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

## nvim → GUI requests  (`vim.rpcrequest(chan, method, ...)`)

### `superlemon.clipboard_get` → `[lines, regtype]`
### `superlemon.clipboard_set(lines, regtype)` → any
Registered as `g:clipboard` provider named "superlemon" for registers `+`
and `*`. `lines` is a list of strings, `regtype` "v"/"V"/"b".

## GUI → nvim  (all via `nvim_input` / standard API — no custom methods)

- Every ⌘-chord arrives as `<D-x>` through `nvim_input`. The plugin defines
  DEFAULT mappings for: `<D-s>` write, `<D-a>` select all, `<D-c>` `"+y`,
  `<D-x>` `"+d` (visual), `<D-z>` undo / `<D-S-z>` redo, `<D-n>` `:enew`,
  `<D-=>`/`<D-->`/`<D-0>` font size (call `superlemon.font_bump(1|-1|0)`
  which rpcnotifies `superlemon.font` with `{delta = n}`). Use
  `vim.keymap.set` with `{silent = true}`; do NOT pass `unique` — user config
  loaded before us must win, so guard each with
  `vim.fn.maparg(lhs, mode) == ""`.
- Sidebar file operations use `:edit`/`:drop` via `nvim_command` (GUI side).

### `superlemon.font`
`{ delta = 1 | -1 | 0 }` — GUI adjusts guifont size (+/-) or resets to default.

## Guarantees

- The plugin must be a no-op under plain terminal nvim (guard on
  `#vim.api.nvim_list_uis() > 0 and vim.g.superlemon_channel ~= nil`).
- `setup()` stores the channel in `vim.g.superlemon_channel`.
- All autocmds live in augroup `superlemon` (cleared on re-setup).
- Never block: no `rpcrequest` from the plugin outside the clipboard
  provider (which vim itself calls synchronously by design).
