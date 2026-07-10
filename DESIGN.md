# Superlemon — Design Document

A macOS-native code editor. **Neovim is the editor engine; macOS is the face.**

Neovim runs headless as an embedded child process and owns everything editorial:
buffers, undo, modes, motions, registers, tree-sitter, LSP, plugins, the user's
entire config. Superlemon owns everything the user sees and touches: a
high-performance native rendering surface, the input system, windows, menus,
tabs, and dialogs.

**North star:** it never makes you wait. Instant launch, zero perceptible
typing latency, smooth scrolling. We achieve this by *not* building an editor
core — Neovim already has a 30-year-hardened editing engine — and spending all
our engineering budget on the last inch: pixels and input.

**Rendering ground rule:** no WebGL, no hand-rolled Metal pipeline. We render
with the platform's own text stack — Core Text for shaping, Core Graphics for
rasterization, Core Animation for compositing. The GPU still does the
compositing work, but through the same machinery every native Mac app uses.
That's the point: Superlemon should render like the Mac, look like the Mac, and
inherit every OS improvement (Retina, ProMotion, vibrancy, wide color) for free.

---

## 1. Goals & Non-Goals

### Goals
- **Full Neovim fidelity.** Anything that works in terminal nvim works here:
  the user's `init.lua`, plugins, `:terminal`, LSP, tree-sitter highlighting,
  macros, all of it. We are a UI, not a fork.
- **A native rendering bridge** (`GridSurface`) that translates Neovim's grid
  protocol into Core Animation content with terminal-emulator performance.
- **A native input system**: full IME (Japanese/Chinese/Korean, dead keys,
  press-and-hold accents), every macOS keyboard convention, ⌘-shortcuts that
  coexist with Vim's key language and are remappable *from the user's nvim
  config*.
- **Native chrome for externalized UI**: Neovim's cmdline, completion popup,
  tabline, and messages rendered as real AppKit components, not cell-grid
  imitations.
- Window/tab/session behavior a Mac user expects: state restoration, native
  fullscreen, drag-and-drop, Services, the standard Edit menu actually working.

### Non-Goals (v1)
- Multiple Neovim instances per window, or one instance across windows
  (one window ↔ one `nvim` process; simple, crash-isolated).
- Remote/SSH nvim attachment (the architecture allows it — the RPC layer
  doesn't care what's on the other end of the pipe — but it's post-v1).
- Custom file-tree/search UI beyond what nvim plugins provide (post-v1 native
  sidebar can come later; Neovim's ecosystem covers it meanwhile).
- Windows/Linux. AppKit is the point.

---

## 2. Architecture Overview

```
┌────────────────────────────── superlemon.app ──────────────────────────────┐
│                                                                            │
│  ShellKit          windows, menus, dialogs, session restore, settings      │
│     │                                                                      │
│  ┌──▼───────────────────────── per window ─────────────────────────────┐   │
│  │                                                                     │   │
│  │  InputKit ──────────────┐            ┌───────────── ChromeKit       │   │
│  │  NSTextInputClient,     │            │   native cmdline, popupmenu, │   │
│  │  key translation,       │            │   tabline, messages          │   │
│  │  mouse/trackpad         │            │                              │   │
│  │            │            │            │                              │   │
│  │            ▼            ▼            ▼                              │   │
│  │  SurfaceKit — GridSurfaceView (the bridge, §5–6)                    │   │
│  │  CALayer tree · Core Text raster · damage tracking · cursor         │   │
│  │            ▲                                                        │   │
│  │            │ typed UI events (batched, flush-atomic)                │   │
│  │  GridKit — grid model: cells, highlight table, windows, viewport    │   │
│  │            ▲                                                        │   │
│  └────────────┼────────────────────────────────────────────────────────┘   │
│               │                                                            │
│  NvimKit — msgpack-RPC session (actor): requests, notifications,           │
│            redraw-event decoding, process lifecycle                        │
│               ▲                                                            │
└───────────────┼────────────────────────────────────────────────────────────┘
                │ stdin/stdout pipes (msgpack-RPC)
        ┌───────▼────────┐
        │  nvim --embed  │   + bundled runtime plugin (§9)
        └────────────────┘
```

Local SwiftPM packages, dependency arrows point down only. Swift 6 strict
concurrency: `NvimKit` is an actor; `GridKit` produces `Sendable` snapshots;
everything above the model layer is `@MainActor`.

### Data flow, both directions

**Down (input):** NSEvent → InputKit translates to Neovim key notation →
`nvim_input("<D-s>")` / `nvim_input_mouse(...)` — fire-and-forget
notifications, never blocking the main thread.

**Up (rendering):** nvim emits `redraw` notification batches → NvimKit decodes
into typed events → GridKit applies them to the grid model, accumulating
damage → on `flush`, a snapshot + damage list hops to the main actor →
SurfaceKit rasterizes damaged spans and commits one `CATransaction`.

The `flush` event is Neovim's frame boundary: everything between two flushes is
one consistent screen state. We never present a partial batch — this is what
makes the UI tear-free without any frame synchronization of our own.

---

## 3. NvimKit — process & RPC layer

### Process lifecycle
- Spawn `nvim --embed` via `Process`, pipes on stdin/stdout, stderr captured to
  a ring buffer (surfaced in a debug console and in crash reports).
- Binary discovery: user setting → `$PATH` (login-shell resolved, since GUI
  apps don't inherit shell PATH) → optional bundled nvim in
  `Contents/Helpers/` as fallback. Minimum supported: nvim 0.10.
- Handshake: `nvim_get_api_info` (validate API level), `nvim_set_client_info`,
  load bundled runtime plugin (§9), then `nvim_ui_attach(cols, rows, opts)`
  with:

  ```
  ext_linegrid: true      // modern grid protocol — required
  ext_multigrid: true     // one grid per window (§5)
  ext_cmdline:  true      // native command line (§8)
  ext_popupmenu: true     // native completion popup (§8)
  ext_tabline:  true      // native tab bar (§8)
  ext_messages: true      // native message toasts (§8)
  rgb: true
  ```

- Exit handling: normal exit closes the window; abnormal exit shows a native
  alert with the stderr tail and a Relaunch button that restores the session
  (via nvim's own `:mksession` autosaved by the runtime plugin).
- Quit flow: ⌘Q and window-close send `:confirm qa` semantics — nvim itself
  prompts about unsaved buffers through the native dialog path (§8), so we
  never second-guess buffer state from outside.

### RPC
- msgpack-RPC over the pipes: requests (with msgid correlation), responses,
  notifications. Implemented as a small hand-rolled codec (~500 lines: msgpack
  is simple, and owning it avoids dependency drift on the hot path).
- `NvimSession` actor API:
  - `func request(_ method: String, _ params: [Value]) async throws -> Value`
  - `func notify(_ method: String, _ params: [Value])` — used for all input
  - `var uiEvents: AsyncStream<RedrawBatch>` — decoded, typed, batched
- Redraw decoding is table-driven: event name → decoder. Unknown events are
  logged and skipped (forward compatibility with newer nvim).
- The decode hot path (`grid_line`) avoids intermediate `[Value]` arrays —
  it parses cells straight into `GridKit` cell runs.

---

## 4. GridKit — the model

Neovim's linegrid protocol is a terminal-shaped abstraction: numbered grids of
cells, each cell a grapheme cluster plus a highlight ID.

```swift
struct Cell { var text: SmallString   // grapheme cluster, usually 1 scalar
              var hlID: HlID }        // index into the highlight table

final class Grid {                    // one per nvim window (ext_multigrid)
    var id: Int
    var size: (rows: Int, cols: Int)
    var cells: [[Cell]]               // row-major
    var damage: DamageMap             // per-row dirty column ranges
    var winFrame: GridFrame?          // position from win_pos / win_float_pos
    var viewport: Viewport            // topline/botline/curline from win_viewport
    var zIndex: Int                   // floats stack above windows above grid 1
}
```

Events applied (the full `ext_linegrid` + `ext_multigrid` vocabulary):

| Event | Model effect |
|---|---|
| `grid_resize`, `grid_clear`, `grid_destroy` | structure |
| `hl_attr_define`, `default_colors_set`, `hl_group_set` | highlight table: fg/bg/special color, bold/italic/underline(+curl/dot/dash), strikethrough, reverse, blend |
| `grid_line` | write cell runs, mark damage |
| `grid_scroll` | move rows within the grid **and record a scroll delta** so the renderer can blit instead of redraw (§6) |
| `grid_cursor_goto` | cursor grid+position |
| `win_pos`, `win_float_pos`, `win_hide`, `win_close`, `msg_set_pos` | window geometry & z-order |
| `win_viewport` | scrollbar model: per-window native overlay scrollers |
| `mode_info_set`, `mode_change` | cursor shape (block/beam/underline), blink timing, per-mode attributes |
| `busy_start/stop`, `mouse_on/off`, `bell`, `visual_bell`, `set_title`, `option_set` | shell-level state |

`option_set guifont` deserves a callout: `:set guifont=SF\ Mono:h13` in the
user's config drives the *native* font. GridKit parses it, SurfaceKit rebuilds
metrics, and we call `nvim_ui_try_resize` with the new cell geometry. Font
choice lives in the user's dotfiles, where a vim user expects it.

Damage tracking is the renderer's contract: after applying a batch, GridKit
hands SurfaceKit `(grid snapshot, dirty row-ranges, scroll deltas)` — nothing
else gets touched at draw time.

---

## 5. SurfaceKit — the bridge component

This is the piece the whole design exists for: **`GridSurfaceView`**, a
layer-hosting `NSView` that makes Neovim's cell grids into native pixels.

### Layer tree

```
GridSurfaceView (layer-hosting NSView, @MainActor)
└── rootLayer
    ├── GridLayer (grid 2 — window)          ← one per nvim window
    ├── GridLayer (grid 3 — window)
    ├── GridLayer (grid 5 — float)             rounded corners, shadow,
    │                                          optional NSVisualEffectView blur
    ├── GridLayer (message grid)
    ├── CursorLayer                          ← §6, drawn above everything
    └── IMEOverlayLayer                      ← marked-text preedit (§7)
```

With `ext_multigrid`, every Neovim window is its own grid — so every window is
its own `CALayer`, positioned by `win_pos`/`win_float_pos`. Consequences that
fall out for free:

- **Floats are native surfaces.** Rounded corners (`cornerRadius`), real
  `CALayer` shadows, and — because `hl_attr_define` carries `blend` — background
  blur via a sibling `NSVisualEffectView` clipped to the float's frame. Neovim
  floats look like macOS popovers.
- **Per-window scrolling is per-layer damage.** A `grid_scroll` in one split
  never invalidates a pixel of another.
- **Z-order is `zPosition`.** No painter's-algorithm bookkeeping.

### GridLayer: backing store + blit scrolling

Each `GridLayer` owns a Retina-scaled bitmap backing store
(`CGContext`, `contentsScale = backingScaleFactor`) the size of its grid.

Per flush, for each damaged grid:

1. **Scroll deltas first.** `grid_scroll` becomes a self-blit: copy the
   surviving rectangle within the backing store, shifted by `rows × cellHeight`
   (double-buffer ping-pong to keep overlapping copies well-defined). This is
   the terminal-emulator trick that makes scrolling cheap: a memcpy-speed move,
   then only the newly exposed rows rasterize.
2. **Rasterize damaged spans** (§6) into the backing store.
3. **Present**: `layer.contents = context.makeImage()` (copy-on-write CGImage —
   cheap snapshot), inside a single `CATransaction` with actions disabled,
   covering *all* grids. One flush → one atomic commit → Core Animation
   composites on the GPU.

Why this shape and not the alternatives:

- **Plain `draw(_:)` NSView** — redraws every visible line on scroll; CPU-bound
  on large windows; no per-window compositing. Rejected.
- **`CATiledLayer`** — asynchronous tile draws cause visible pop-in; built for
  maps, not editors. Rejected.
- **One CALayer per row** — makes scrolling a pure layer-reposition (zero
  raster) and is the planned **post-v1 optimization** for the common
  full-width vertical scroll; the bitmap store remains the correctness
  fallback for partial-region updates. Not needed to hit budgets in v1.

### Resize & metrics

- Window resize → `cols = floor(surfaceWidth / cellWidth)`, likewise rows →
  `nvim_ui_try_resize`. During live-resize, coalesce to one request per frame;
  nvim replies with `grid_resize` and repaint events.
- Cell geometry from the primary font: `cellWidth = advance('M')`,
  `cellHeight = ceil(ascent + descent + leading) + linespace` (linespace from
  `option_set`). All layout in cell units × these two numbers; fractional
  scaling never appears because layers sit on pixel-aligned cell boundaries.

---

## 6. Text rendering pipeline (Core Text)

The rasterization of a damaged span, start to finish:

1. **Run coalescing.** Walk the span's cells, merging consecutive cells with
   identical `hlID` into *style runs*. Typical code line: 5–15 runs.
2. **Background pass.** Fill each run's background rect (`CGContextFillRect`,
   batched by color). Backgrounds are painted full-cell so double-width and
   ligature cells never leave seams.
3. **Shaping.** Per run: build the run's string (concatenated cell graphemes),
   shape with `CTTypesetter`/`CTLine` using the resolved font (base font +
   bold/italic traits via `CTFontCreateCopyWithSymbolicTraits`). Core Text
   handles font fallback (CJK, emoji, symbols) via cascade lists — we get
   correct glyphs for every script without any work.
4. **Ligatures for free, columns preserved.** Because a style run shapes as one
   string, `=>` `!=` `->` form ligatures naturally in fonts that have them
   (opt-out setting). Monospaced advances mean shaped positions already land on
   cell boundaries; double-width CJK occupies two cells exactly as nvim
   allocated them (nvim sends the trailing half as an empty cell).
5. **Glyph cache.** Extract `(glyphs[], positions[])` from the CTLine's runs
   once, cache keyed by `(string, fontID, traits)` — colors deliberately
   excluded so one cache entry serves every theme color. LRU-capped (~4 MB).
   Cache hit rate while typing/scrolling is ≈99%: most lines repeat.
6. **Draw.** Set fill color from the highlight attrs, `CTFontDrawGlyphs` into
   the backing store (handles color-bitmap emoji correctly, unlike raw
   `CGContextShowGlyphs`). Then decorations: underline/undercurl/underdot/
   strikethrough as paths, in the highlight's `special` color.
7. **Font smoothing** matches Terminal.app's behavior (respect the user's
   global font-smoothing default; no forced faux-bolding).

### Cursor

`CursorLayer` is separate from grid content so it can move without touching any
backing store:

- Shape and blink cadence from `mode_info_set`/`mode_change` (block in normal,
  beam in insert, underline for replace, plus per-mode `attr_id` colors).
- A block cursor re-renders its one cell with reversed colors *into the cursor
  layer* — the grid underneath stays untouched.
- Blink via `CAKeyframeAnimation` (no timers, no main-thread wakeups); blink
  suppressed while typing.
- Optional smooth cursor motion (Neovide-style) as an implicit-animation on
  `position` — off by default, it's a taste setting.
- `busy_start`/`busy_stop` hide/show the cursor.

### Performance budgets

| Metric | Budget |
|---|---|
| Keystroke → glyph on screen (end-to-end, incl. nvim round trip) | < 8 ms (one 120 Hz frame) |
| Full-screen scroll, 4K display | no dropped frames |
| Flush → CATransaction commit | < 2 ms typical |
| Cold launch → first render of restored session | < 400 ms |

Instrumented with `os_signpost` at each pipeline stage (keyDown, RPC write,
redraw decode, raster, commit) so latency regressions show up in Instruments
as a labeled waterfall, and enforced by an XCTest perf suite driving a real
headless nvim.

---

## 7. InputKit — the input system

Input is half the product. The design principle: **macOS conventions at the
edge, Vim semantics at the core, and one source of truth (nvim) for what any
key means.**

### 7.1 The key path

`GridSurfaceView` is the first responder and conforms to **`NSTextInputClient`**
— non-negotiable, because it's the only way to be a first-class citizen of the
macOS text input system (IMEs, dead keys, press-and-hold accents, dictation).

```
keyDown(event)
  │
  ├─ if marked text active ──────────────► interpretKeyEvents (IME owns it)
  │
  ├─ translate to nvim notation possible? ─► nvim_input("<C-w>") etc.
  │    (any Ctrl/Cmd chord, specials,        fire-and-forget notification
  │     function keys, meta-Option)
  │
  └─ else ───────────────────────────────► interpretKeyEvents(...)
        └─ insertText(_:replacementRange:) ─► nvim_input(escaped text)
        └─ setMarkedText(...) ──────────────► IME preedit overlay (§7.2)
```

- **Translation table** covers Neovim's full key notation: `<Esc>` `<CR>`
  `<BS>` `<Tab>` `<Del>` arrows, Home/End/PageUp/PageDown, `<F1>`–`<F20>`,
  keypad keys — each with modifier prefixes `S-`, `C-`, `M-` (Option), `D-`
  (Command) in nvim's canonical order.
- **Escaping:** literal text goes through `nvim_input` with `<` → `<lt>`;
  large insertions (paste) use `nvim_paste`, which is mapping-immune and
  streams in chunks so a 10 MB paste never stalls the UI.
- **Option key policy** (the classic Mac-Vim tension): per-side setting —
  *Option as Option* (types `é`, `∂`, dead keys; goes through the IME path) or
  *Option as Meta* (sends `<M-x>` using `charactersIgnoringModifiers`).
  Default: left Option = Meta, right Option = Option. Overridable from nvim
  config via the runtime plugin (§9).
- Key repeat, modifier-only events, and `performKeyEquivalent` ordering follow
  AppKit rules — we never bypass the responder chain, which is what keeps
  system-wide features (screenshot chords, VoiceOver, input-source switching)
  working.

### 7.2 IME — marked text done right

Composition (Japanese/Chinese/Korean, dead keys, press-and-hold) must not
touch the buffer until the user commits. Terminal nvim can't do this properly;
we can:

- `setMarkedText(...)` renders the preedit string into **`IMEOverlayLayer`**,
  positioned at the cursor cell, styled with the theme's cursor-line colors and
  proper underline segments for the active clause. Nvim knows nothing yet.
- `firstRect(forCharacterRange:)` returns the caret cell's screen rect — this
  is what places the IME candidate window correctly next to the cursor. In
  insert mode with a full-width composition, the overlay pushes no cells; it
  floats above (matching Terminal.app behavior).
- `insertText(_:replacementRange:)` clears the overlay and commits via
  `nvim_input`/`nvim_paste`.
- `unmarkText`, cancellation, and clause selection all stay inside the overlay.
- In *normal* mode, printable IME input still works (e.g. `f` + Japanese char),
  because commit goes through `nvim_input` like any key.

### 7.3 ⌘-shortcuts: menus and Vim, one namespace

The elegant move: **⌘-chords are just keys.** Every Command chord is delivered
to nvim as `<D-x>`, and the bundled runtime plugin (§9) defines the default
mappings in Lua:

```lua
vim.keymap.set({ "n", "i", "v" }, "<D-s>", "<Cmd>write<CR>")
vim.keymap.set("n", "<D-p>", function() require("superlemon").goto_anything() end)
vim.keymap.set({ "n", "v" }, "<D-c>", '"+y')  -- etc.
```

- **NSMenu items are affordances, not implementations.** The File ▸ Save menu
  item's action sends the same `<D-s>` into `nvim_input`. One namespace, one
  behavior, and the user can remap or unmap *any* ⌘-shortcut in their own
  `init.lua` — their config is the keybinding editor.
- Menu **validation** (enabled/disabled, checkmarks) comes from cheap cached
  state the runtime plugin pushes on relevant autocmds (`&modified`, mode,
  etc.) — never a synchronous RPC in `validateMenuItem`.
- **System-reserved chords stay native:** ⌘Q (quit flow §3), ⌘W (close window
  → `:confirm qa` semantics per window), ⌘M, ⌘H, ⌘\`, ⌘, (Settings). AppKit
  gets them via `performKeyEquivalent` before translation.
- **Clipboard is native both ways:** the runtime plugin sets `g:clipboard` to
  a provider that `rpcrequest`s Superlemon, which reads/writes `NSPasteboard`.
  So `"+y` in a macro and ⌘C both hit the real pasteboard, including
  rich-text/HTML flavors for paste *into* other apps (post-v1: paste with
  syntax colors).

### 7.4 Mouse & trackpad

- Clicks/drags → `nvim_input_mouse(button, action, modifiers, grid, row, col)`
  with per-grid coordinates (multigrid gives us the right window for free).
  Double/triple-click counts pass through (`:h mouse` word/line selection).
- **Trackpad scrolling with momentum:** `scrollWheel` deltas accumulate in
  fractional cell units per axis; each whole cell crossed emits a wheel event
  on the grid under the pointer. Momentum phase just keeps feeding the
  accumulator — nvim scrolls with real inertia, in whole lines. (A
  pixel-smooth sub-cell prototype — history margins + contentsRect window +
  a pixel/line control loop — was built and deliberately removed: the
  latency-absorption feel wasn't acceptable. Whole-line scrolling is the
  design.)
- **Pinch to zoom** (`magnify(with:)`) adjusts `guifont` size through the same
  `option_set` path — metrics, resize, persist.
- Force-click on a word → LSP hover/definition via the runtime plugin
  (`vim.lsp.buf.hover()`); a genuinely Mac gesture mapped to a genuinely Vim
  facility.
- `mouse_on`/`mouse_off` events gate all of it (some plugins take the mouse).

---

## 8. ChromeKit — externalized UI as native components

Neovim lets a UI take over specific surfaces. Each becomes real AppKit:

| nvim extension | Native component |
|---|---|
| `ext_cmdline` | Floating command palette panel: `NSVisualEffectView` material, SF Mono text field look, centered top-third like Spotlight. `cmdline_show/pos/hide` drive it; blockwise mode (`cmdline_block_*`) grows it into a multi-line sheet. Wildmenu completions render inside it as a native list. |
| `ext_popupmenu` | Completion popup: borderless `NSPanel` + virtualized `NSTableView`, anchored at the grid cell from `popupmenu_show` (works for cmdline completion too via `grid == -1`). Kind/menu columns, LSP kind icons in SF Symbols, scroll-synced with `popupmenu_select`. Insert-mode completion suddenly looks like Xcode's. |
| `ext_tabline` | Native tab strip driven by `tabline_update`. Renders nvim *tabpages* as Mac tabs — dirty dots, close buttons, drag to reorder (reorders via `:tabmove`), ⌘1–9. |
| `ext_messages` | `msg_show` routed by kind: errors/warnings as transient native toasts (top-right, stacking, click to expand); `confirm` prompts as native `NSAlert` sheets — **this is how ⌘Q's `:confirm qa` becomes a real Save/Don't Save/Cancel dialog**; `msg_history_show` as a scrollable panel. `msg_showmode`/`msg_showcmd`/`msg_ruler` feed a slim native status bar. |
| `win_viewport` | Per-window **native overlay scrollbars** (`NSScroller`-style, drawn as layers on each `GridLayer`): thumb geometry from topline/botline/line-count, fade in on scroll, draggable (drag → `nvim_input_mouse` wheel or `winrestview` RPC). |

Chrome theming: derived from nvim's own highlight groups
(`default_colors_set`, `hl_group_set` for `Normal`, `PMenu`, `TabLine`…), so
the native chrome always matches the user's colorscheme — change your nvim
theme, the whole app follows, light/dark appearance included (background
luminance selects `NSAppearance`).

---

## 9. The bundled runtime plugin (`superlemon.nvim`)

A small Lua plugin shipped in the app bundle and prepended to
`runtimepath` at attach. It is the *nvim-side half of the bridge*:

- Default `<D-...>` keymaps (§7.3) — defined with `unique = false` so user
  config wins.
- `g:clipboard` provider → native pasteboard (§7.3).
- Menu-validation state pushed on autocmds (`BufEnter`, `ModeChanged`,
  `TextChanged` — debounced).
- GUI services exposed to *any* plugin via `vim.rpcrequest(chan, ...)`:
  native open/save panels, "reveal in Finder", notifications
  (`UNUserNotificationCenter`), opening URLs. Plugin authors get Mac
  integration without Superlemon knowing about their plugin.
- Session autosave for crash recovery (§3).
- Option-key policy, ligature toggle, cursor-animation toggle as
  `vim.g.superlemon_*` variables — *all GUI settings live in nvim config*,
  versioned with the user's dotfiles. The native Settings window is a thin
  editor over the same variables.

---

## 10. ShellKit — app shell

- `NSDocument`-less: windows are workspaces, not documents (nvim owns files).
  State restoration via `NSWindowRestoration` + nvim sessions.
- One window ↔ one nvim process. Crash isolation, trivially correct teardown.
- Files opened from Finder/`open`/drag-onto-Dock route to the frontmost
  window's nvim (`:drop`), or a new window per user preference.
- `superlemon` CLI helper (like `subl`/`code`): opens files in a running
  instance via `NSDistributedNotification`/XPC, supports `-w` wait flag for
  `$EDITOR` use.
- Sparkle-free v1; signed, notarized, hardened runtime from M0 (bundling an
  nvim binary and shipping pipes means entitlements are settled early).

---

## 11. Testing strategy

- **Protocol tests:** golden msgpack transcripts (recorded from real nvim
  sessions) replayed into GridKit; assert final grid state. Runs headless, no
  UI, catches protocol regressions across nvim versions in CI.
- **Renderer golden images:** GridSurfaceView rasterized offscreen against
  reference PNGs (per Retina scale) for: ligatures, CJK double-width, emoji,
  undercurl, floats with blend, cursor shapes. Tolerance-based comparison.
- **Input matrix:** parameterized tests of NSEvent → notation translation
  (every modifier combo × special keys), plus scripted IME composition
  sequences through `NSTextInputClient`.
- **End-to-end latency harness:** real `nvim --embed`, synthesized keyDowns,
  signpost-measured budgets (§6) enforced as perf tests.
- **Fuzzing:** random redraw-event sequences (structure-aware) into GridKit —
  must never crash or desync damage tracking.

---

## 12. Milestones

Each ends in a usable app; riskiest integrations first.

**M0 — Pixels (2 weeks).** NvimKit process+RPC, single-grid linegrid (multigrid
off), GridSurfaceView with bitmap store + blit scroll, basic keyDown → 
`nvim_input`. *Exit: edit this repo in Superlemon with the user's own config
loading, and it feels instant.*

**M1 — Input done right (2 weeks).** Full `NSTextInputClient`/IME with preedit
overlay, complete key translation table, Option policy, clipboard provider,
mouse/trackpad with momentum accumulator. *Exit: a Japanese-input user and a
heavy Vim user both feel at home.*

**M2 — Multigrid & cursor (2 weeks).** `ext_multigrid` per-window layers,
floats with rounded corners/shadow/blend-blur, CursorLayer with mode shapes,
per-window scrollbars from `win_viewport`. *Exit: a busy telescope/​float-heavy
config looks native.*

**M3 — Native chrome (2–3 weeks).** ext_cmdline palette, ext_popupmenu,
ext_tabline, ext_messages with native confirm dialogs; menu bar wired through
`<D-...>`; runtime plugin v1. *Exit: ⌘Q politely asks about unsaved files;
completion looks like Xcode.*

**M4 — Mac citizenship (2 weeks).** Session restore, Finder/CLI open paths,
Settings window, ligature/font polish, notarized builds. *Exit: daily-driver
replacement for terminal nvim.*

**M5 — Performance hardening (ongoing, release-gated).** Row-layer scrolling,
glyph-cache tuning, Instruments passes, perf suite in CI enforcing §6 budgets.

---

## 13. Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Grid-model desync (damage bugs → visual corruption) | High | Golden transcript tests + fuzzing (§11); debug overlay that flashes damage rects; "full redraw" escape hatch (`nvim_ui_try_resize` forces repaint) |
| IME edge cases (clause editing, reconversion, per-IME quirks) | High — headline feature | Test matrix across Kotoeri/Google JP/Sogou/2-Set Korean early (M1, not later); preedit overlay keeps nvim state uninvolved, bounding the blast radius |
| ⌘-chord conflicts with plugin mappings | Medium | `<D-...>` defaults set `unique=false` and are documented; menu items reflect actual mappings post-config |
| ext_messages fidelity (plugins that expect TUI message quirks) | Medium | `ext_messages` can be toggled per-user to fall back to grid-rendered messages; ship both paths |
| nvim API evolution across versions | Medium | Table-driven event decoding skips unknown events; CI matrix against nvim stable + nightly; min-version gate at handshake |
| Blit-scroll correctness on Retina fractional scales | Low | Cell-aligned layers + integral backing pixels by construction; golden images per scale factor |
| Core Text shaping cost on pathological lines (minified JS) | Low | Runs cap at viewport width; glyph cache; worst case is one line of fresh shaping per frame |

---


`NORTHSTAR.md` (measured palettes, geometry, component inventory). It amends
this design as follows — where the two conflict, NORTHSTAR.md wins on
*appearance*, this document wins on *architecture*:

1. **Native file-tree sidebar is v1, not post-v1** (reverses §1 non-goals).
   ~370pt flat white/dark pane, 24pt rows, colored file-type icons, native
   context menu. Lives in ShellKit; file ops (rename/delete/new) route through
   the runtime plugin so `:e`/buffer state stays coherent.
2. **Split-view host for non-grid panes.** The editor grid is one pane of an
   `NSSplitView`; markdown preview (GitHub-styled, light `#FFFFFF`/dark
   `#0D1117`) and the native image viewer (checkerboard + metadata bar,
   binaries never touch nvim) are sibling panes. SurfaceKit stays unaware.
3. **Tabs are workspaces, not tabpages** (amends §8). The 28pt top strip
   switches *workspaces* (window-local sessions; one nvim per workspace,
   post-v1 may pool). `ext_tabline` data feeds the status bar / a buffer
   switcher instead of the strip.
4. **Quick-open is a native fuzzy file palette** (498×346pt, upper-center,
   30% scrim) — ⌘P opens it directly; it is not the ext_cmdline panel, though
   both share the palette visual language. Backed by the runtime plugin
   (`vim.fs`/fd) so ignore rules match the user's setup.
5. **Powerline-flavored native status bar**: mode badge, file, git branch,
   project, line:col chip — state pushed by the runtime plugin on autocmds
   (richer than §8's msg_ruler sketch).
6. **Appearance policy reconciled**: an explicit System/Light/Dark setting
   selects `NSAppearance` and pushes `background=light/dark` to nvim; chrome
   colors then derive from nvim highlight groups *within* that appearance
   (§8's luminance heuristic becomes the "System" mode's tiebreaker).
7. **Chrome is flat and opaque** — hairline separators, no vibrancy on
   titlebar/sidebar/status. Vibrancy/materials only on transient surfaces
   (palettes, menus, popups).
   until product direction says otherwise.

Milestone impact: sidebar + status bar join M3 (native chrome); quick-open
palette joins M3; preview/image panes and workspace strip join M4.

---

## 15. The component framework — `superlemon.ui` (Lua-scriptable native UI)

The architectural inversion that turns Superlemon from an app into a
platform: native components stop being hard-wired feature consumers and
become **servers scriptable from Lua**. Built-in features (git badges, ⌘P
quick-open) are reimplemented as bundled plugins on the same public API any
third-party plugin uses — permanent dogfooding.

### Lua surface (sketch)

```lua
local ui = require("superlemon.ui")

-- Sidebar decorations: plugins own namespaces; the GUI merges them.
local ns = ui.sidebar.namespace("gitsigns-native")
ns:set_badge("Sources/a.swift", { text = "M", color = "#E0B268" })
ns:set_dot("Sources", { color = "#ADC694" })
ns:clear()

-- The palette is a generic fuzzy-picker COMPONENT; ⌘P is just one user.
ui.palette.open({
  placeholder = "Buffers…",
  on_query = function(q) return {
    { id = 3, title = "a.swift", subtitle = "Sources", positions = { 1, 2 } },
  } end,
  on_select = function(id) vim.api.nvim_set_current_buf(id) end,
})

ui.toast({ text = "Build failed", kind = "error" })          -- MessageToast
ui.statusbar.segment("my-plugin", { text = "⚡ 3", color = "#E0B268" })
```

### Wire protocol (one generic pair, replacing bespoke notifications)

- nvim → GUI: `superlemon.ui` notification
  `{ component, method, namespace, args }` — e.g.
  `{ "sidebar", "set_badge", "gitsigns-native", { path, text, color } }`.
- GUI → Lua callbacks: the Lua side registers functions in a registry keyed
  by callback id; the GUI invokes them via
  `nvim_exec_lua("require('superlemon.ui')._dispatch(...)", [id, payload])`
  and awaits the return value (palette on_query round-trips in ~1 ms).
- Namespacing gives isolation: a plugin's `clear()` never touches another's
  badges; the GUI composes namespaces deterministically (sorted by name).

### Migration path

1. Wave A: protocol plumbing (`superlemon.ui` module + dispatcher, GUI
   router in WorkspaceChrome) + sidebar decorations as the first component;
   port git badges onto it.
2. Wave B: palette component; port ⌘P (the file picker moves into Lua —
   FileIndex/FuzzyScorer stay as the GUI-side engine the built-in picker
   uses, but any picker can bring its own source). `<D-p>` becomes a normal
   plugin-owned mapping, rebindable from any vimrc — CtrlP semantics on a
   native panel.
3. Wave C: statusbar segments, toasts, prompts; document as the public
   plugin-author API; CONTRACT.md's bespoke `superlemon.git`/quick-open
   paths are subsumed and deprecated.

---

## 16. Splits: nvim as layout engine, macOS as hands and paint

Nvim's window layout is an explicit tree (`winlayout()`: row/col/leaf) that
is structurally isomorphic to nested NSSplitViews — but four mismatches rule
out adopting NSSplitView's ENGINE, and each is load-bearing:

1. **Cell quantization vs pixel continuity** — nvim geometry is integer
   cells; pixel-continuous dividers either snap (jitter) or float at
   positions nvim cannot represent.
2. **Separators are content, not chrome** — nvim draws them as themed cells
   (`fillchars`/`WinSeparator`); native dividers would double them.
3. **The oscillation trap** — two authoritative layout engines resolving the
   same resize (holding priorities vs `equalalways`/`winfix*`) feed back;
   every shipping nvim GUI keeps layout authority singular for this reason.
4. **Atomicity** — win_pos batches arrive per flush (tear-free); NSSplitView
   resizes panes across frames, letterboxing grids mid-transition.

**The hybrid that survives all four**: grid layers positioned verbatim from
win_pos (atomic, one engine); native SEPARATOR AFFORDANCES overlaid on the
separator columns — resize cursors, generous hit targets, continuous drag
translated to `nvim_win_set_width/height` at cell crossings; and native
PAINT: the managed config blanks `fillchars` separators while the GUI draws
a 1px hairline in the reserved column — native look without layout
inversion.

**Mouse-drag latching (implemented)**: per the UI contract, drag/release
events stay on the PRESS grid. Re-hit-testing per event caused directional
jitter: dragging toward the window whose origin moves with the separator
(right/down) reported positions relative to an edge that had just moved —
a feedback loop. InputHostView latches the grid at mouse-down and converts
via `GridSurfaceView.cell(at:inGrid:)` (clamped) for the drag's duration.

---

## 17. What makes it feel right (checklist to protect)

- Your `init.lua` loads unmodified; every plugin works
- Keystroke latency indistinguishable from Terminal.app, UI polish
  indistinguishable from a first-party Mac app
- ⌘C/⌘V/⌘S/⌘Q behave like a Mac; `ciw`/`"+y`/`q:` behave like Vim; neither
  ever surprises you
- Japanese/Chinese/Korean input works *better* than terminal nvim
- Floats look like popovers; completion looks like Xcode; ⌘Q asks nicely
- Change your colorscheme and the whole app — chrome included — follows
