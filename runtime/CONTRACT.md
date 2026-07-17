# superlemon.nvim / GUI contract

`runtime/lua/superlemon/` is the Neovim half of Superlemon. This document
describes the implemented MessagePack-RPC wire contract, configuration
ownership, and standard Neovim API calls used by the Swift app. Change both
sides together when changing a wire shape.

## Bootstrap and configuration

The GUI prepends the bundled runtime through a pre-init `--cmd`. After
`nvim_ui_attach`, it starts the bridge. Configuration is startup input and is
never sourced by this bootstrap:

```lua
local channel, mode, compact = ...
vim.g.superlemon_config_mode = vim.g.superlemon_config_mode or mode
return require("superlemon").setup(channel, { compact = compact })
```

The GUI passes `[channel_id, config_mode, compact]` as the `nvim_exec_lua`
argument array. `channel_id` comes from `nvim_get_api_info`; `config_mode` is
managed, user, or custom launch state used when the managed init did not set
it; `compact` is a boolean that is true when the GUI window started narrower
than its compact threshold (~800 pt) — the sidebar and minimap then default to
hidden unless their `g:superlemon_native_*` globals are explicitly set.

`require("superlemon")` has no side effects. `setup(channel, opts)` rejects
invalid channels, stores a valid one in `g:superlemon_channel`, stays inert
when no UI is attached, and may be called again safely. It returns structured readiness
with `ready`, `runtime_api`, and `config` fields. Active setup installs status,
clipboard, keymap, chrome, minimap, git, and native-UI adapters, then pushes
initial settings and status.

### Configuration source order

Settings selects exactly one launch source:

1. managed: bundled `runtime/config/init.lua` (the default);
2. user: no `-u`, allowing Neovim to load its normal init; or
3. custom: a diagnostic-only bundled `-u` loader that sources exactly the
   readable regular file selected in Settings once. The loader exists so an
   init error can be returned over RPC instead of entering Neovim's startup
   prompt; it applies no defaults or other executable configuration.

The modes are mutually exclusive. User and custom launches do not receive the
managed baseline or the Superlemon personal override after startup. A missing
custom file is a startup error rather than a silent fallback.

The managed init sources the annotated baseline
`runtime/config/superlemon.vim`, then sources:

```text
$XDG_CONFIG_HOME/superlemon/init.vim
```

or `~/.config/superlemon/init.vim` when `XDG_CONFIG_HOME` is unset. The personal
file wins setting by setting. The state marker is set to `loading` before
`:source`, then becomes `loaded` or `error`, preventing recursive/repeated
execution. A source error is retained as structured path/message diagnostics.
Bridge setup returns that error to the GUI, which presents recovery including
an explicit safe-start path rather than silently changing configuration modes.

Recovery can launch managed mode with `SUPERLEMON_SAFE_START=1` (and an isolated
`NVIM_APPNAME`). It loads the bundled baseline, skips executable personal
configuration, and reports config state `safe_start`.

Settings creates the personal file from the minimal `config/user-init.vim`
template only when it does not already exist. Editor, scrolling, native chrome,
minimap, native UI, keymap, statusline, and renderer preferences live in these
Vim files rather than a parallel native preference store.

## Neovim to GUI notifications

All methods below use `vim.rpcnotify(g:superlemon_channel, method, ...)`.

### `superlemon.status`

One map argument:

```lua
{
  mode = "n",                 -- raw nvim_get_mode().mode
  file = "Sources/a.swift",   -- cwd-relative; "" when unnamed
  modified = true,
  modifiable = true, readonly = false, buftype = "",
  can_undo = true, can_redo = false, -- native menu enablement snapshot
  line = 42, col = 7,         -- one-based
  total_lines = 310,
  branch = "main",            -- "" outside a repository
  project = "superlemon",     -- cwd basename
}
```

Immediate pushes occur at setup and on `ModeChanged`, `BufEnter`,
`BufModifiedSet`, `BufFilePost`, relevant `OptionSet`, `DirChanged`, and
`FocusGained`. `CursorMoved`, `CursorMovedI`, `TextChanged`, and `TextChangedI`
use one trailing-edge timer: a movement/edit burst produces one push about
100 ms after its final event. This keeps Save, Cut, Undo, and Redo enablement
current even when a plugin edits or renames a buffer without moving the cursor.

The branch reader walks upward for `.git`, supports worktree/submodule
`gitdir:` indirection, reads `HEAD` with `vim.uv` filesystem calls, and caches
by cwd. `DirChanged` and `FocusGained` clear that cache before pushing.

Every status push also asks `superlemon.statusline` to push; it no-ops while the
native status bar is disabled.

### `superlemon.chrome`

One complete map, pushed during setup and after an actual toggle change:

```lua
{
  native_tabs = true,
  native_statusbar = true,
  native_minimap = true,
  native_scrollbars = false,
  native_sidebar = true,
}
```

Initial state comes from `g:superlemon_native_tabs` and
`g:superlemon_native_statusbar` (`1`/`true` means enabled), plus
`g:superlemon_native_minimap` (default enabled),
`g:superlemon_native_scrollbars` (default disabled), and
`g:superlemon_native_sidebar` (default enabled). When `setup` receives
`compact = true` (narrow startup window), `native_minimap` and
`native_sidebar` default to disabled instead; an explicitly set global always
wins over that compact default. Later changes go through:

```vim
:SuperlemonChrome tabs on|off|toggle
:SuperlemonChrome statusbar on|off|toggle
:SuperlemonChrome minimap on|off|toggle
:SuperlemonChrome scrollbars on|off|toggle
:SuperlemonChrome sidebar on|off|toggle
```

or `require("superlemon").chrome_toggle(part)`. View-menu items call that API
and wait for the notification; Neovim is the source of truth. Minimap and
scrollbar state are independent. Disabling the minimap also cancels its
pending runtime content generations and clears its window-topology payload.

Native-statusbar adopt mode is enabled unless
`g:superlemon_adopt_statusline` is `0`/`false`. While adopted, the runtime saves
the exact `laststatus` value, sets `laststatus=0`, and restores the saved value
when the native bar turns off. Set the variable to zero to prevent this option
mutation; in-grid visibility then follows the user's own `laststatus` value.

Native tabs do not change `showtabline` when toggled. Separately,
`g:superlemon_hide_tabline=1` applies `showtabline=0` once at setup. The managed
baseline also chooses `cmdheight=0`, `noshowmode`, and `laststatus=0`; the
personal configuration may override those ordinary Neovim options.

### `superlemon.cwd`

One map argument, pushed from a `DirChanged` autocmd whenever Neovim's global
working directory changes (`:cd`, `nvim_set_current_dir`, and so on):

```lua
{ cwd = "/Users/me/project" } -- vim.fn.getcwd()
```

The GUI re-roots the workspace (file sidebar, quick-open index) at the new
path when it differs from the current project root. GUI-initiated folder
changes also call `nvim_set_current_dir`, so this notification fires for those
too; the GUI's changed-path guard makes the echo a no-op.

### `superlemon.settings`

One complete renderer/accessory-settings map, pushed at every setup:

```lua
{
  powerline_glyphs = false,
  ligatures = true,
  use_symbol_font = false,
  force_glyph_fallback = false,
  minimap_width = 88,
  minimap_scale = 0.20,
  minimap_pitch = 3.0,
  minimap_min_editor_columns = 40,
}
```

Values come from:

| Payload | Vim global | Default |
|---|---|---|
| `powerline_glyphs` | `g:superlemon_powerline_glyphs` | false |
| `ligatures` | `g:superlemon_ligatures` | true |
| `use_symbol_font` | `g:superlemon_use_symbol_font` | false |
| `force_glyph_fallback` | `g:superlemon_force_glyph_fallback` | false |
| `minimap_width` | `g:superlemon_minimap_width` | 88 pt |
| `minimap_scale` | `g:superlemon_minimap_scale` | 0.20 × active editor font size |
| `minimap_pitch` | `g:superlemon_minimap_pitch` | 3.0 pt |
| `minimap_min_editor_columns` | `g:superlemon_minimap_min_editor_columns` | 40 columns |

Boolean values accept `1`/`true` or `0`/`false`. The complete snapshot replaces
native renderer state atomically. Numeric minimap values must be finite; width
clamps to 48...160, scale to 0.10...0.50, pitch to 1...6, and minimum editor
columns to 20...120 before crossing the wire. Scale multiplies the active
editor-font size; pitch independently controls vertical line spacing and is
snapped to physical pixels by SurfaceKit. Neovim's standard `guifont` and
`linespace` remain authoritative for font name, size, and spacing.

### `superlemon.minimap`

One map argument with a required `kind`. The lightweight topology provider is
active while either `native_minimap` or `native_scrollbars` is enabled, because
both controls validate semantic viewport targets against the current
window/buffer pair. Highlighted content is requested only for a visible
minimap. The provider reports data; SurfaceKit/AppKit owns every pixel, layer,
clipping decision, and interaction.

#### `kind = "windows"`

The complete set of visible normal windows in the current tabpage. Floating,
hidden-tab, and external windows are not included:

```lua
{
  kind = "windows",
  windows = {
    {
      winid = 1000,
      bufnr = 3,
      buftype = "",
      buffer_name = "/workspace/Sources/App.swift",
      filetype = "swift",
      tabstop = 4,
      changedtick = 27,
      line_count = 640,
      highlight_generation = 3,
    },
  },
}
```

Setup pushes this immediately. Window/buffer/tab/filetype changes schedule a
fresh complete snapshot with about 20 ms debounce. Every listed buffer receives
one lightweight `nvim_buf_attach(..., false, callbacks)` subscription.

#### `kind = "invalidate"`

Buffer-attach callbacks invalidate native content/style caches without sending
the replacement text themselves:

```lua
{
  kind = "invalidate",
  bufnr = 3,
  changedtick = 27,
  line_count = 640,
  highlight_generation = 3,
  firstline = 10,
  lastline = 12,       -- old end, zero-based and exclusive
  new_lastline = 15,   -- new end, zero-based and exclusive
  reload = true?,
  detached = true?,
}
```

A reload/detach uses `firstline=0`, `lastline=-1`, and `new_lastline=-1`.
Highlight-affecting events use the same range plus `highlights=true`, bump
`highlight_generation`, cancel older content work, and repush window topology.

#### `kind = "content"`

Results from `request()` arrive in ordered, cooperative chunks:

```lua
{
  kind = "content",
  request_id = 91,
  winid = 1000,
  bufnr = 3,
  changedtick = 27,
  line_count = 640,
  highlight_generation = 3,
  firstline = 128,
  lastline = 144,
  complete = false,
  clamped = false,
  highlight_source = "treesitter" | "legacy" | "normal",
  degraded = "treesitter-budget" | "legacy-budget" |
             "extmark-cap" | "extmark-error" | nil,
  lines = {
    {
      line = 128,
      text = "func example()",
      byte_length = 14,
      truncated = false,
      spans = {
        {
          start_col = 0, end_col = 4, -- UTF-8 bytes, end-exclusive
          source = "normal" | "treesitter" | "legacy" | "extmark",
          priority = 100,
          order = 7,
          style = {
            fg = 0xC586C0, bg = 0x1E1E1E, sp = 0xFF0000,
            bold = true, italic = false, underline = false,
          },
        },
      },
    },
  },
}
```

Every nonempty line includes a priority-zero `Normal` span. Tree-sitter is used
only when an already-active highlighter can be safely feature-detected; the
provider never starts a parser. Active highlighter queries/injections are
bounded by time and span count. Otherwise legacy `synID()` runs inside the
requested window, then plain `Normal` is the final fallback. Persistent
text-range extmarks overlay any base source with their priority and stack
order. Ephemeral decoration-provider output, virtual text/lines, match/search
state, conceal, and pixels are intentionally outside this checkpoint.

Content requests are zero-based and end-exclusive:

```lua
return require("superlemon.minimap").request({
  request_id = 91,
  winid = 1000,
  bufnr = 3,
  changedtick = 27,
  line_count = 640,
  highlight_generation = 3,
  firstline = 128,
  lastline = 512,
  max_columns = 120,
})
```

The call returns `true` only after validating that the enabled provider has the
normal window, that the window still displays the supplied loaded buffer, that
the range is well formed, and that `changedtick`, `line_count`, and
`highlight_generation` exactly match the provider's current topology. A stale
tuple cancels older work for that window, immediately republishes the complete
current `kind="windows"` snapshot, and returns `false`; the fire-and-forget GUI
therefore receives authoritative identity and issues a fresh request. No content
work starts for the stale tuple.

An accepted call returns immediately. Results use at most 16 lines per
scheduled turn. A request is capped to 384 lines and 256 Unicode characters per
line; partial reads and UTF-8-safe truncation prevent a pathological line from
becoming a pathological payload. Each syntax source attempt receives about 1.5
ms and bounded capture/extmark counts.

Only the newest request generation for a window may notify. Each scheduled
chunk revalidates window/buffer identity, `changedtick`, line count, and
highlight generation; edits, buffer switches, minimap disablement, or a
replacement request silently retire stale work.

`ColorScheme`, `Syntax`, `FileType`, `LspTokenUpdate`, `DiagnosticChanged`, and
relevant option changes advance the highlight generation. Buffer invalidations
always include current line count and highlight generation; reload/detach and
topology changes also schedule a fresh windows snapshot.

### `superlemon.buffers`

One map, emitted only while `native_tabs` is enabled:

```lua
{
  current = 3,
  buffers = {
    {
      bufnr = 3,
      name = "Sources/a.swift", -- cwd-relative; "" when unnamed
      modified = false,
      preview = true,
    },
  },
}
```

The list contains `buflisted` buffers in `nvim_list_bufs()` order. It is pushed
once when native tabs turn on and, with about 50 ms debounce, after `BufAdd`,
`BufDelete`, `BufEnter`, `BufFilePost`, and `BufModifiedSet`. Preview state
changes request an immediate push.

GUI actions use standard Neovim APIs:

- select: `nvim_set_current_buf(bufnr)`;
- close: `:confirm bdelete {bufnr}`;
- double-click preview tab: `require("superlemon.preview").promote(bufnr)`.

#### Preview buffers

The native sidebar provides VS Code/Sublime-style preview behavior through
`superlemon.preview`:

- single-click calls `open(path)`;
- double-click calls `open_permanent(path)`;
- at most one preview exists;
- opening another file wipes the old preview only when it is clean;
- modifying a preview promotes it automatically;
- a modified preview is promoted, never discarded;
- selecting an already-open permanent buffer does not replace a different
  preview;
- double-clicking the italic tab calls `promote(bufnr)`.

Neovim owns preview identity. The GUI only renders the `preview` boolean and
invokes these Lua entry points.

### `superlemon.statusline`

One map, pushed on the `superlemon.status` cadence only while
`native_statusbar` is enabled, plus an immediate seed when it turns on:

```lua
{
  segments = {
    {
      text = " NORMAL ",
      fg = 0x1B2023,       -- absent means native bar default
      bg = 0xADC694,
      bold = true,
      italic = false,
    },
  } | vim.NIL,
}
```

The runtime uses the current window-local `statusline`, falling back to the
global value. If neither is configured, `segments` is `vim.NIL` and the GUI
shows its built-in status chips. The fallback also covers evaluation failure or
empty output.

Configured content is evaluated with:

```lua
vim.api.nvim_eval_statusline(expr, {
  winid = current_window,
  highlights = true,
  maxwidth = 500,
  fillchar = vim.fn.nr2char(0xE000),
})
```

Highlight links are resolved to concrete 24-bit colors. The private-use U+E000
fill character marks `%=` unambiguously; the GUI splits there and recreates
left/right alignment with native layout. The native bar renders these segments
instead of fallback chips, while namespaced `superlemon.ui` status segments
remain additive. An active cmdline temporarily supersedes both.

### `superlemon.font`

```lua
{ delta = 1 | -1 | 0 }
```

The GUI temporarily changes its native `FontSpec` by one point, clamped to
6...72. It does not write `guifont`. Delta zero restores the font name, size,
and spacing last derived from Neovim's `guifont`/`linespace` while retaining the
current renderer settings.

### `superlemon.save_as`

No payload. The bundled `<D-s>` mapping emits this when the current buffer is
unnamed. The GUI opens its native Save As sheet, then completes the operation
through Neovim. Named buffers use `vim.cmd.write()`.

File > Save As opens the same native workflow directly and does not require
this notification. A user mapping for `<D-s>` replaces the bundled behavior.

### `superlemon.git`

One map, pushed once at setup and with about 150 ms debounce after
`BufWritePost`, `FocusGained`, `DirChanged`, and `VimResume`:

```lua
{
  files = {
    { path = "Sources/a.swift", status = "M" },
    { path = "new.txt", status = "?" },
  },
}
```

The provider asynchronously runs, in the current cwd:

```text
git --no-optional-locks status --porcelain -z
```

It parses NUL-delimited rename/copy records and chooses the worktree status
column when set, otherwise the index column. Status is `M`, `A`, `D`, `R`, `C`,
`U`, or `?`. Generation tokens ensure that only the newest request can notify;
a directory change invalidates an older in-flight result immediately. Git
failure/not-a-repository sends an empty list, which clears native badges.

### `superlemon.ui`

The canonical wire shape is one notification with four arguments, not one
array argument:

```lua
vim.rpcnotify(
  g:superlemon_channel,
  "superlemon.ui",
  component,
  method,
  namespace,
  args
)
```

`component`, `method`, and `namespace` are strings; `args` is always a map.
Pass `vim.empty_dict()` when it has no fields. Colors are `"#RRGGBB"` strings.
The GUI tolerates a legacy/defensive single wrapped array, but producers should
send the canonical four arguments.

Implemented methods:

| Component | Method | Args |
|---|---|---|
| `sidebar` | `set_badge` | `{path, text, color?}`; path is cwd-relative |
| `sidebar` | `set_dot` | `{path, color}` |
| `sidebar` | `clear` | `{}`; clears this namespace only |
| `palette` | `open` | `{placeholder?, query_cb, select_cb, close_cb?}` |
| `palette` | `close` | `{}` |
| `toast` | `show` | `{text, kind}` where kind is `info`, `warn`, or `error` |
| `statusbar` | `set_segment` | `{text, color?}` |
| `statusbar` | `clear` | `{}`; clears this namespace only |
| `input` | `open` | `{prompt?, default?, submit_cb}` |

Sidebar namespaces compose in sorted-name order, with the later namespace
winning for the same path. Statusbar namespaces render in sorted-name order.
A plugin sidebar decoration wins over a built-in git decoration on the same
row.

Callback IDs refer to Lua functions in a session registry. The GUI invokes one
with a request:

```lua
return require("superlemon.ui")._dispatch(callback_id, payload)
```

Transport is `nvim_exec_lua` with `[callback_id, payload]` as its argument
array. Unknown/freed IDs and callback errors return `vim.NIL` rather than
failing the GUI request.

- `query_cb` receives `{query = "..."}` and returns
  `{{id, title, subtitle?, positions?}, ...}`. Positions are one-based indices
  into the title; the GUI converts them to zero-based indices for rendering.
- `select_cb` receives `{id = ...}`. Selection frees the palette session before
  user code runs, so that code may open another palette.
- Palette dismissal invokes `close_cb` once and frees the session. Opening a
  replacement frees the prior session's callback IDs before replacing the GUI
  session; it does not invoke the prior `on_close` callback.
- `submit_cb` receives `{text = "..."}` on submit or `{}` on cancellation. The
  Lua public callback sees a string or nil.

Public Lua API:

```lua
local ui = require("superlemon.ui")

local ns = ui.sidebar.namespace("my-plugin")
ns:set_badge(path, { text = "M", color = "#ADC694" })
ns:set_dot(path, { color = "#ADC694" })
ns:clear()

ui.palette.open({ placeholder, on_query, on_select, on_close })
ui.palette.close()
ui.toast({ text, kind })
ui.statusbar.segment(namespace, { text, color })
ui.statusbar.clear(namespace)
ui.input({ prompt, default, on_submit })
```

At setup, `vim.ui.select` and `vim.ui.input` are replaced only when they still
appear to be Neovim's stock implementations. Set `g:superlemon_native_ui=0` to
disable both adapters; a picker installed by user configuration normally wins.

## Neovim to GUI requests

The clipboard provider is the only runtime path that initiates a blocking
`vim.rpcrequest`.

### `superlemon.clipboard_get` -> `[lines, regtype]`

No arguments. Returns a list of strings and register type `"v"` or `"V"` from
the macOS pasteboard.

### `superlemon.clipboard_set(lines, regtype)` -> nil

Writes the lines to the macOS pasteboard. A trailing empty line preserves the
linewise newline convention.

The runtime registers these methods as `g:clipboard` provider `"superlemon"`
for `+` and `*` only when the user has not already configured a provider. It
never replaces an existing user provider.

## GUI to Neovim

The GUI uses standard Neovim RPC methods and Lua entry points. Minimap content
uses the asynchronous `require("superlemon.minimap").request({...})` entry point
documented above; it returns an acceptance boolean and never returns content in
the request response.

### Input

Keyboard and mouse commands share one main-actor FIFO. Adjacent notifications
are encoded by `NvimSession.notifyBatch` in one serialized pipe write without
dropping or pacing protocol events. Paste remains an ordered `nvim_paste`
request.

Command chords not claimed by an AppKit menu item arrive through InputKit as
`<D-x>` notation via `nvim_input`. Standard Edit selectors remain on AppKit's
responder chain, so native text fields and panels retain native editing while
the editor input host maps the same selectors to Neovim. Semantic editor/File
commands call Neovim directly; for example File > Save issues `write` rather
than changing meaning through a `<D-s>` mapping. Direct Save is disabled for an
unnamed buffer; Save As remains available.

### Default Command-key mappings

Unless `g:superlemon_default_keymaps=0`, setup installs each default only when
`vim.fn.maparg(lhs, mode)` is empty. User mappings loaded before setup win.

| Chord | Modes | Default |
|---|---|---|
| Command-S | normal, insert, visual | write named buffer; request native Save As when unnamed |
| Command-A | normal, insert, visual | select all |
| Command-C / Command-X | visual | `"+y` / `"+d` |
| Command-Z | normal, insert, visual | undo |
| Shift-Command-Z | normal, insert | redo |
| Command-N | normal, insert | `:enew` |
| Command-= / Command-- / Command-0 | normal, insert, visual | `require("superlemon.keymaps").font_bump(1 | -1 | 0)` |

Mappings use `vim.keymap.set(..., {silent=true})`. Re-running setup
re-establishes entries recorded as bridge-owned. A mapping loaded before the
initial setup wins; the ownership table does not re-detect a user replacement
installed afterward.

### Native File menu

| Item | Standard API path |
|---|---|
| Open File... | native single-file panel, then `vim.cmd.drop(fnameescape(path))` |
| Open Folder... | native directory panel, `nvim_set_current_dir(path)`, return canonical `getcwd()`, then re-root native workspace chrome |
| Save | direct `nvim_command("write")`; surface failure in a native alert |
| Save As... | seed native panel with `nvim_buf_get_name(0)`, then `nvim_cmd({cmd="saveas", args={path}, bang=true})` |

The Save As panel has already confirmed replacement before `bang=true` is
used. Neovim still owns writing, encoding, autocmds, undo, and buffer naming.

Open Folder is the coordinated re-root path: the GUI replaces its sidebar,
Quick Open index, git/UI decorations, and project status only after Neovim
accepts the cwd. Existing buffers remain open. A raw `:cd` currently updates
runtime status/git notifications but does not send the absolute cwd required to
re-root native workspace chrome.

Quick Open and Open File use `:drop`. Sidebar single/double clicks instead use
`superlemon.preview.open/open_permanent`. Native rename/trash operations mutate
the filesystem and refresh the sidebar/index, but currently do not rename or
wipe matching open Neovim buffers.

### Workspace file listings (`superlemon.workspace`)

When the session's filesystem is not the GUI machine's (host-supplied remote
transports; `NvimController.hasRemoteFilesystem`), the GUI sources the native
sidebar tree and Quick Open index through `nvim_exec_lua` instead of its local
filesystem. `vim.uv` on this side of the transport always enumerates the
filesystem the session actually sees. Both calls are pure request/response
with no side effects and are safe before `setup()`.

Sidebar directory expansion (one level, never recursive):

```lua
return require("superlemon.workspace").list_dir(path)
-- { { name = "Sources", dir = true, hidden = false }, ... }
```

Symlinks are resolved one level so a link to a directory expands. `hidden` is
a dotfile-prefix judgment. An unreadable directory raises; the GUI shows its
per-row failure/retry placeholder.

Quick Open index (bounded synchronous walk):

```lua
return require("superlemon.workspace").list_files(root, max)
-- { files = { { path = "Sources/a.swift", mtime = 1720000000 }, ... },
--   truncated = false }
```

`path` is root-relative; `mtime` is epoch seconds (0 when unavailable) and
drives the GUI's recency ordering. `.git` is always pruned. The root
`.gitignore` is honored with the same documented subset as the GUI's local
index (blank/`#` lines, `!` negation with last-match-wins, trailing `/`
directory-only rules, `/`-containing patterns anchored to the relative path,
basename match otherwise, `glob2regpat` wildcard semantics where `*` may cross
`/`). An ignored directory is pruned whole. The walk stops at `max` files;
`truncated` distinguishes exactly-`max` from more-than-`max`. Only regular
files are indexed.

The walk runs on Neovim's main loop, so `max` (50 000 from the GUI) is also
the latency bound. The GUI therefore refreshes sparingly: at project-root
adoption/changes and when the Quick Open palette is presented. There is no
remote FSEvents equivalent; the sidebar instead re-lists a directory each time
it is expanded.

#### File transfers (sidebar drag & drop)

The GUI's sidebar drag-and-drop streams file bytes between its machine and
the session's filesystem through chunked, handle-based calls. Chunks are
base64 strings (`vim.base64`): Lua strings are 8-bit clean, but arbitrary
bytes must not round-trip through msgpack STR/UTF-8 decoding on the GUI
side. All calls are synchronous request/response with no side effects
beyond the named file.

```lua
ws.stat(path)            -- { type = "file"|"directory"|..., size = n } | vim.NIL
ws.mkdir(path)           -- mkdir -p; true (existing directory is success)
ws.rename(from, to)      -- move; ERRORS if `to` exists (moves never overwrite)

id = ws.write_open(path)          -- opens `path .. ".superlemon-partial-<id>"`
ws.write_chunk(id, b64)           -- append; returns cumulative bytes written
ws.write_close(id, commit)        -- true: rename partial over `path`
                                  -- (atomic replace); false: unlink partial

r = ws.read_open(path)            -- { id, size }; errors unless a regular file
ws.read_chunk(r.id, max_bytes)    -- next base64 chunk | vim.NIL at EOF
ws.read_close(r.id)
```

Writes are atomic: until `write_close(id, true)` the target is untouched,
so a cancelled or failed upload never leaves a torn file. Handles live in a
session registry keyed by id; a stale or wrong-kind id errors. Handles are
GUI-owned — a GUI that dies mid-transfer leaks its handle until this nvim
exits (bounded; never data loss). The GUI streams 512 KiB of raw bytes per
chunk (~700 KB encoded) to keep the remote event loop responsive and
progress ticks flowing.

## Guarantees and health

- Merely requiring the plugin under terminal Neovim has no side effects.
- Active bridge setup stores its channel in `g:superlemon_channel`.
- Setup/status/chrome/minimap/git autocmds live in augroup `superlemon`, cleared
  on re-setup. The active preview-buffer watcher uses `superlemon_preview`.
- Runtime notifications are nonblocking. The runtime initiates `rpcrequest`
  only for the clipboard provider, which Neovim itself calls synchronously.
- Missing GUI state makes component APIs no-op rather than fail terminal use.
- Malformed `superlemon.ui` payloads are logged and dropped by the GUI.

Run:

```vim
:checkhealth superlemon
```

The health report covers GUI channel attachment, clipboard-provider ownership,
and default-keymap installation/opt-out state.

## Runtime tests

```sh
bash runtime/tests/run.sh
```

The suite covers setup idempotence and health, status cadence and branch
resolution, configuration precedence, renderer settings, chrome/adopt mode,
bounded minimap topology/content/invalidation behavior, buffer and preview
semantics, evaluated statuslines, keymap ownership and Save As,
clipboard/user-provider behavior, git parsing and stale-result suppression, and
the canonical `superlemon.ui` transport/callback lifecycle, and the
`superlemon.workspace` listings (directory shapes, gitignore-subset pruning,
and truncation semantics).
