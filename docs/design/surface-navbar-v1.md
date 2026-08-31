# Surface Navbar v1 — contract

Status: v1 implementation contract (2026-08-31). This document is the source
of truth for the three parallel workstreams; deviations must be brought back
here first. When implemented and stable, the wire sections graduate into
`runtime/CONTRACT.md`.

## 1. Goal

The navbar becomes a **real Neovim window** whose content is owned by the
runtime plugin (`navbar.lua`) and rendered by a **native macOS control**
(`TreeSurfaceView`) painted over that window's grid. Vim's own machinery then
provides everything NerdTree users expect for free — `Ctrl-W` navigation,
`j/k`, `/` + `n`, counts, `gg/G`, marks, macros — because the buffer holds one
line per visible tree row and keystrokes never leave the normal
`nvim_input` path. AppKit first-responder focus **never moves**:
`InputHostView` stays the sole first responder; "the navbar is focused" simply
means the navbar window is nvim's current window.

v1 scope = **full feature parity** with the existing `FileTreeSidebarView`
(see §10 checklist), plus the new keyboard layer. The generic composable-
controls framework is the direction, not the v1 deliverable: the render
payload is shaped as a node (`control = "tree"`) so the schema can grow into
`vstack`/`text`/etc. without breaking.

## 2. Architecture

```
runtime/lua/superlemon/navbar.lua          Sources/EditorHostKit/SurfaceHost.swift
  model: fs scandir, watchers, git,          routes ("surface", …) + ("host", …)
  expansion, decorations                     maps winid→grid, suppresses grid text,
  projection: buffer lines == rows           mounts/positions TreeSurfaceView,
  mappings: <CR>, go, R, C, u                selection = viewport.curline,
     │ superlemon.ui notifications           dispatches events via ui._dispatch
     ▼                                                  │
runtime/lua/superlemon/surface.lua          Sources/ShellKit/TreeSurfaceView.swift
  window+buffer lifecycle, render send,       flat-row native tree control
  callback registration (via ui.lua)          (cells shared with FileTreeSidebarView)
```

Two planes, unchanged from the rest of the product:

- **Redraw plane** (`ext_multigrid`): the navbar window's grid gives the GUI
  its frame (`GridLayout.resolve`), lifecycle (`win_hide`/`win_close`), focus
  (`hasCursor`), and selection (`win_viewport.curline`). No new RPC for any
  of these.
- **`superlemon.ui` plane**: the existing generic notification
  `[component, method, namespace, args]` plus the existing blocking callback
  registry (`ui._dispatch`) carry the render payload and events.

## 3. Mode flag and bootstrap

- GUI: `SUPERLEMON_NAVBAR=surface` in the environment enables surface mode
  (`NvimController.navbarSurfaceEnabled`, read once at init). Default off in
  v1; the flip to default-on happens only after the §10 checklist passes.
- `bootstrapRuntimePlugin` passes `navbar_surface = <bool>` in the setup opts
  table. `init.lua` calls `require("superlemon.navbar").setup(group, opts)`
  only when the flag is true (`opts` carries `remote` through).
- `navbar.enabled()` → true iff setup ran with the flag. Other Lua modules
  (chrome, ui, git, minimap) consult it at call time.
- In surface mode the GUI keeps the legacy split-view sidebar pane
  permanently collapsed (`EditorHostNSView` ignores `native_sidebar` for the
  pane) and `chrome.lua`'s `M.set("sidebar", on)` delegates to
  `navbar.set_open(on)` instead of only recording state. Chrome state still
  reports `native_sidebar` so the tab-strip toggle button stays accurate:
  navbar open/close events (including `:q`/`Ctrl-W o` on the window) call
  back into `chrome.set("sidebar", …)` guarded against recursion.
- Legacy mode (flag off) must behave byte-for-byte as today. Nothing in the
  legacy path may be deleted in v1.

## 4. The navbar window (Lua, `surface.lua` + `navbar.lua`)

`surface.lua` owns generic window/buffer mechanics so a second surface can
exist later; `navbar.lua` owns everything file-tree.

Window/buffer creation (`surface.open{...}`):

- Scratch buffer: `nvim_create_buf(false, true)`; `buftype=nofile`,
  `bufhidden=hide`, `swapfile=false`, `buflisted=false`, `modifiable=false`,
  `filetype=superlemon-navbar` (the filetype identifies navbar buffers
  everywhere — minimap exclusion, statusline, tests).
- Window: leftmost full-height vertical split, **without stealing focus**
  (`nvim_open_win(buf, false, {split = "left", win = -1})` on nvim ≥ 0.10;
  verify and fall back to `:topleft vertical split` + restore-win if the API
  form misbehaves).
- Window options: `winfixwidth`, `winfixbuf`, `nonumber`,
  `norelativenumber`, `signcolumn=no`, `foldcolumn=0`, `nowrap`,
  `nocursorline`, `nolist`. Default width **32 columns**.
- Guard autocmds: `WinClosed` on the navbar window → notify close + inform
  `chrome`; `BufWinEnter` guard for anything that defeats `winfixbuf`.
- `:mksession` must not resurrect the buffer (nofile + unlisted handles it;
  spec asserts it).

**Projection invariant (the load-bearing rule):** the buffer's lines and the
render payload's `rows` array are written in the same function from the same
`visible_rows()` computation — `rows[i]` describes buffer line `i` (1-based
Lua, converted to 0-based for the GUI). Line text = indented label
(`string.rep("  ", depth) .. label`) so `/` search hits what the user sees.
The buffer is only ever written via this function (`modifiable` toggled
around the write).

Buffer-local mappings (normal mode):

| Key | On file | On dir | On `..` row |
|---|---|---|---|
| `<CR>`, `o` | open permanently (`preview.open_permanent`) | toggle expand | root to parent |
| `go` | preview open (`preview.open`) | toggle expand | — |
| `R` | refresh whole tree | same | same |
| `C` | — | `:cd` into dir | root to parent |
| `u` | root to parent (any row) | same | same |

Opens leave the navbar window current? No: `preview.open*` targets the
previous/main window — `navbar.lua` opens files via
`vim.fn.win_execute`/`nvim_set_current_win` on the most-recent normal window
(`winfixbuf` protects the navbar window itself), matching NerdTree's
behavior of opening into the last-used window. After a keyboard open, focus
moves to that window (vim-native, like NerdTree).

## 5. The model (Lua, `navbar.lua`)

Owns: root path (nvim cwd; follows `DirChanged`), lazy children via
`vim.uv.fs_scandir` (async; `loading` placeholder row while in flight,
`failed` row with retry on error), expansion set keyed by absolute path,
sort dirs-first then case-insensitive by name (match current sidebar),
`..` row when root has a parent, root header title = root basename.

- **Watchers:** one non-recursive `vim.uv.fs_event` per *expanded* directory
  (nvim-tree pattern), debounced 100 ms per dir; teardown on collapse.
  Works identically local and remote because it runs inside nvim.
- **Git:** `git.lua` gains a subscriber registry
  (`git.on_update(fn)` — called with the parsed `files` list on every
  refresh). In surface mode `navbar.lua` subscribes and merges one-letter
  statuses onto rows (`badge`), with directory propagation matching the
  current sidebar's behavior (a dirty child marks ancestors with a dot).
  The existing `superlemon.git` GUI notification continues unconditionally
  (legacy path + other consumers).
- **Plugin decorations:** `ui.lua`'s `Namespace:set_badge/set_dot/clear`
  route to `navbar.decorations(ns, …)` when `navbar.enabled()`, else send to
  the GUI as today. Same merge rule: namespaces sorted by name, later wins
  per path.
- **File ops (local sessions only, `remote=false`):** create file/folder
  (`uv.fs_open`/`uv.fs_mkdir`), rename (`uv.fs_rename`; reject on
  collision), delete → host trash (§8), reveal → host (§8). Remote sessions:
  ops disabled exactly as `allowsFileOperations=false` does today (menu
  events for them are never offered — `menu` list omits them).
- After create/rename, set the navbar window's cursor to the new row —
  cursor **is** the selection channel, so the GUI highlight follows with no
  extra wire.

## 6. Wire contract (all on the existing `superlemon.ui` notification)

`ui.lua` exports `M._register(fn) → id` (the existing private `register`)
so `surface.lua` can mint callback ids that flow through the existing
blocking `_dispatch`.

### nvim → GUI notifications

`("surface", "open", "navbar", args)`:

```lua
{ surface_id = "navbar",     -- stable string id
  win = <winid>, buf = <bufnr>,
  control = "tree",
  event_cb = <int> }         -- one callback id for ALL events of this surface
```

`("surface", "render", "navbar", args)`:

```lua
{ surface_id = "navbar",
  seq = <int>,               -- monotonic; GUI drops stale seq
  header = { title = "myproject" },
  menu = {                   -- declarative context menu, filtered per row kind
    { id="new_file",   title="New File",                 for_kinds={"file","dir","root"} },
    { id="new_folder", title="New Folder",               for_kinds={"file","dir","root"} },
    { id="rename",     title="Rename",                   for_kinds={"file","dir"} },
    { id="delete",     title="Move to Trash",            for_kinds={"file","dir"} },
    { id="reveal",     title="Reveal in Finder",         for_kinds={"file","dir","root"} },
    { id="cd",         title="Change Working Directory", for_kinds={"dir","up"} },
  },                         -- ops omitted entirely on remote sessions
  rows = {                   -- flat, buffer-line order; rows[i] == line i
    { id = "<abs path>",     -- absolute path IS the row id
      label = "Sources",
      depth = 0,
      kind = "file"|"dir"|"up"|"loading"|"failed",
      expanded = true|false, -- dirs only
      badge = { text = "M", color = "#e5c07b" },  -- optional
      dot = "#61afef",       -- optional
    }, ... } }
```

`("surface", "close", "navbar", { surface_id = "navbar" })` — window was
closed (`:q`, `Ctrl-W o`, toggle). GUI unmounts the overlay and
unsuppresses the grid.

`("host", "trash", "navbar", { path = "<abs>" })` — GUI moves the file to
the macOS Trash (`FileManager.trashItem`); failure → toast. Local only.

`("host", "reveal", "navbar", { path = "<abs>" })` — GUI reveals in Finder
(`NSWorkspace.activateFileViewerSelecting`). Local only.

### GUI → nvim events (via blocking `nvim_exec_lua` → `ui._dispatch(event_cb, payload)`)

Detached (fire-and-forget, `dispatchUICallbackDetached`):

- `{ event = "open",   id, permanent = false|true }` — row single/double click.
- `{ event = "toggle", id }` — disclosure chevron or double-clicked dir.
- `{ event = "menu",   id, item = "<menu id>" }` — context-menu selection.
- `{ event = "refresh" }` — pull-to-refresh affordance if the control has one.

Blocking (`dispatchUICallback`, GUI awaits result):

- `{ event = "rename", id, name }` → `{ ok = true }` or `{ error = "text" }`
  (GUI keeps the inline field open and shows the error).
- `{ event = "create", dir = "<abs>", kind = "file"|"folder", name }` →
  `{ ok = true, path = "<abs>" }` or `{ error = "text" }`.

Direct nvim API calls by the GUI (no event):

- Row click also does `nvim_win_set_cursor(win, {row, 0})` — keeps
  vim selection synced without switching the current window (parity: a
  click never moves keyboard focus into the navbar).
- Native right-edge drag → `nvim_win_set_width(win, cols)`.

## 7. GUI side (`SurfaceHost.swift`, Swift wiring)

`SurfaceHostRouter` (EditorHostKit) owns surface-mode state:

- Receives `("surface", …)`/`("host", …)` from `WorkspaceChrome`'s
  `superlemon.ui` routing (in front of `UIComponentRouter`, which keeps all
  its existing cases).
- `sync(flush: FlushResult)` is called by `NvimController` after each
  `surface.present(flush)` (hook at `NvimController.swift:1035`). It:
  - resolves `winid → gridID` by scanning `flush.grids` for
    `windowHandle == win` (tolerates the open notification racing the first
    flush: until the grid appears, the overlay stays hidden);
  - keeps `GridSurfaceView.setOverlaidWindowHandles([win])` current so the
    grid's **text layer is not drawn** (new SurfaceKit API; the layout still
    resolves the frame — suppression is paint-only);
  - positions the overlay view over `surface.rect(ofGrid:)` converted to
    `InputHostView` coordinates;
  - selection: `flush.grids[gid].viewport.curline` (0-based buffer line) →
    `treeView.setSelectedRow(curline)`; scroll-to-reveal only when curline
    changed;
  - active state: `flush.grids[gid].hasCursor` (is the navbar the cursor
    grid) → `treeView.setActive(_:)` (emphasized vs. secondary selection).
- Overlay mounting and hit-testing: `InputHostView` gains
  `setSurfaceOverlay(_ view: NSView?)`; its `hitTest` returns the overlay's
  deepest hit before falling back to the grid-cell path, mirroring the
  accessory exemption. Wheel/click events then reach the native control
  normally.
- Event dispatch: uses the existing
  `controller.dispatchUICallback(Detached)` exactly as `UIComponentRouter`
  does.
- Renders arriving before `open`, or with stale `seq`, are dropped;
  a render for an unmounted grid is stored and applied on mount.

`GridSurfaceView` additions (SurfaceKit):

- `public func setOverlaidWindowHandles(_ handles: Set<Int>)` — grids whose
  `windowHandle` is in the set get no text/background layer content (layer
  hidden), no cursor rendering when the cursor is on them, and are excluded
  from editor accessories. Everything else (layout resolution, viewport
  bookkeeping) unchanged.

## 8. `TreeSurfaceView` (ShellKit)

A new flat-row native control; **shares cell/row views with
`FileTreeSidebarView`** (promote `FileTreeCellView`/`FileTreeRowView`/
placeholder cell to internal shared types rather than duplicating them —
pixel parity by construction: 24 pt rows, 17 pt/level indentation, same
fonts, badges, dots, disclosure chevrons, same header band and
`FileTransferProgressView` bottom band).

API (pinned as a compiling stub before parallel work starts):

- `render(model: TreeSurfaceModel)` — full-model diffed by row `id`
  (NSTableView-based; reload with animation-free diff, preserving scroll).
- `setSelectedRow(Int?)`, `setActive(Bool)`, `applyAppearance(dark:)`.
- `beginRename(rowID:)`, `beginCreate(dirID:kind:)` — inline text field in
  the cell (create shows a provisional row); commit calls the blocking
  callbacks below and keeps the field open on error.
- Callbacks: `onOpen(id, permanent)`, `onToggle(id)`,
  `onMenu(itemID, rowID)`, `onRowClickRow(Int)` (for cursor sync),
  `onRenameCommit(id, name) async -> String?` (error or nil),
  `onCreateCommit(dir, kind, name) async -> String?`,
  `onWidthDrag(CGFloat)` (right-edge handle, pixel width).
- Drag & drop: ports the sidebar's existing behavior against the same
  `WorkspaceFileTransferCoordinator`/promise machinery (drag out local URLs
  or remote promises; drop-in copies/uploads with the progress band). The
  fs watchers pick up resulting changes — no wire event.
- Context menu built from `model.menu` filtered by the row's `kind`.

Testing: ShellKit tests host the view in a real-framed `NSWindow`
(never order it front — gate any `orderFront` on `parentWindow.isVisible`,
per the ChromeKit convention).

## 9. Minimap/accessory exclusion

`minimap.lua` `push_windows()` must skip windows whose buffer filetype is
`superlemon-navbar` (belt and suspenders with the GUI-side accessory
exclusion in §7).

## 10. Parity acceptance checklist (the v1 flip gate)

Every row must pass in surface mode, local and (where applicable) remote:

1. Lazy expand/collapse with loading + failed/retry placeholder rows.
2. Expansion, selection, and scroll survive refreshes (row-id diffing).
3. Single click = preview open; double click = permanent; double-click dir
   = toggle; click never moves keyboard focus out of the editor.
4. Root header shows root name; `..` row roots to parent; cd re-roots tree,
   quick-open index, and git (via existing `DirChanged`/`superlemon.cwd`).
5. Context menu: New File / New Folder / Rename (inline, error keeps field
   open) / Move to Trash / Reveal in Finder / Change Working Directory —
   local sessions only (remote: menu shows only `cd`).
6. Created/renamed items are selected (cursor) afterwards.
7. Git badges + dirty-ancestor dots; plugin namespace badges/dots merge
   with the same precedence as today.
8. FS changes appear without user action (watchers), local and remote.
9. Drag out (local URLs; remote promises) and drop-in (copy/upload with
   progress band) work as today.
10. Sidebar toggle (menu, tab-strip button, `:SuperlemonChrome sidebar`)
    opens/closes the vim window; `:q`/`Ctrl-W o` on it updates chrome state.
11. Divider drag resizes (snaps to columns); `winfixwidth` holds width
    across splits; min width enforced (~180 pt worth of columns).
12. Dark/light appearance parity.
13. NEW: `Ctrl-W h/l/w` moves between navbar and editor windows; `j/k`,
    `/`+`n`, `gg/G`, counts move selection; `<CR>`/`go` open; `R`, `C`, `u`
    per §4; all with real vim splits present.
14. Legacy mode (flag off) unchanged; full test suite green in both modes.

## 11. Workstreams and file ownership

- **Agent L (Lua):** `runtime/lua/superlemon/surface.lua` (new),
  `navbar.lua` (new); edits: `init.lua`, `chrome.lua`, `git.lua`, `ui.lua`
  (`_register` export + decoration routing), `minimap.lua` (exclusion);
  specs: `runtime/tests/navbar_spec.lua`, `surface_spec.lua`.
- **Agent S1 (SurfaceKit/EditorHostKit):** `Sources/EditorHostKit/
  SurfaceHost.swift` (new), `Sources/SurfaceKit/GridSurfaceView.swift`
  (suppression API only); tests in `Tests/SurfaceKitTests`.
- **Agent S2 (ShellKit):** `Sources/ShellKit/TreeSurfaceView.swift` (new) +
  shared-cell refactor of `FileTreeSidebarView.swift`;
  `Tests/ShellKitTests/TreeSurfaceViewTests.swift`.
- **Main session (wiring):** `InputHostView.swift`, `NvimController.swift`,
  `WorkspaceChrome.swift`, `EditorHostNSView.swift`, flag plumbing,
  integration, commits.
