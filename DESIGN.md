# Superlemon — Current Design

Superlemon is a macOS-native code editor with Neovim as its editing engine.
Neovim runs as an embedded child process and remains authoritative for buffers,
undo, modes, mappings, registers, syntax, LSP, plugins, windows, and editor
writes. Superlemon supplies the native window, menus, workspace chrome,
filesystem browsing and sidebar mutations, input bridge, and rendering pipeline.

This document describes the implementation currently checked into this
repository. Anything described as **open work** is not part of the current
product contract.

The rendering stack is deliberately native: Core Text shapes glyphs, Core
Graphics rasterizes row tiles, IOSurface provides compositor-shareable backing,
and Core Animation positions and composites those tiles. Superlemon contains no
custom Metal renderer. The WindowServer/GPU may still accelerate composition
under Core Animation.

---

## 1. Current product contract and boundaries

### Current contract

- One Superlemon workspace window owns one embedded `nvim --embed` process.
- Neovim's `ext_linegrid` and `ext_multigrid` protocols are rendered as native
  Core Animation layers.
- Compatible vertical viewport scrolling is reconciled with a display-linked,
  interruptible row filmstrip. Neovim's final grid remains authoritative.
- Keyboard, IME, mouse, trackpad, paste, and resize input ultimately route back
  through Neovim.
- Native chrome currently includes a file-tree sidebar, Quick Open, an optional
  buffer strip and status bar, externalized command line, completion popup,
  message toast/history, native prompts, Settings, and standard file panels.
- Users may run Superlemon's managed Neovim configuration, their normal Neovim
  configuration, or an explicit init file. Superlemon-specific overrides live
  in `$XDG_CONFIG_HOME/superlemon/init.vim`.
- macOS 14 or newer is the package deployment target.

### Intentional or current boundaries

- macOS only. AppKit and Core Animation are part of the product architecture.
- There is currently one workspace/editor window and one Neovim process.
  Settings, message history, panels, and sheets are auxiliary windows. Multiple
  workspace windows and shared/remote Neovim sessions are open work.
- Neovim owns editor semantics. Superlemon does not implement a parallel buffer,
  undo, selection, layout, or save model.
- Vertical viewport scrolling is the optimized interpolated path. Horizontal
  scrolling and conflicting partial-region scrolls present atomically.
- The current IME bridge supports marked text, commit/cancel, and candidate
  placement, but not rich per-clause styling or reconversion fidelity.
- Session restoration, Finder/Dock open-file routing, drag-and-drop, Services, a
  command-line helper, signed distribution, and notarization are open work.

---

## 2. Architecture overview

The Swift package contains modules with deliberately narrow responsibilities:

```text
SuperlemonApp (@MainActor integration)
├── AppDelegate
│   ├── application/window lifecycle
│   ├── menus, About, Settings, open/save panels
│   └── native workspace layout
├── NvimController
│   ├── one NvimSession
│   ├── one GridStore
│   ├── ordered input queue
│   └── redraw/runtime/chrome coordination
├── InputHostView
│   └── first responder + NSTextInputClient + mouse adapter
├── WorkspaceChrome
│   └── ChromeKit + ShellKit wiring
└── UIComponentRouter
    └── superlemon.ui protocol dispatcher

NvimKit (actor)                 InputKit (pure value translation)
├── child process + pipes       ├── key notation
├── MessagePack-RPC             ├── Option policy
├── typed redraw decoding       ├── mouse translation
└── lifecycle/notification      └── fractional scroll accumulation

GridKit (@MainActor store)      ShellKit (@MainActor views + FileIndex actor)
├── row-COW Grid values         ├── file tree and file operations
├── highlights and layout       ├── Quick Open and fuzzy scoring
├── damage/scroll provenance    ├── buffer strip
└── deferred presentation       └── native status bar

SurfaceKit (@MainActor)         ChromeKit (@MainActor)
├── Core Text rasterizer        ├── cmdline state/panel
├── row IOSurface renderer      ├── popupmenu state/panel
├── display-linked filmstrip    └── messages/toasts/history
└── cursor layer
```

SwiftPM dependency edges remain one-way:

- `GridKit` depends on `NvimKit` for typed UI events.
- `SurfaceKit` depends on `GridKit`.
- `ChromeKit` depends on `NvimKit`.
- `InputKit` and `ShellKit` are independent libraries.
- `SuperlemonApp` is the integration target and depends on all six libraries.

### Concurrency and ownership

- `NvimSession` is an actor. Pipe pumps read off-actor and deliver decoded
  chunks back to the actor.
- `RedrawBatch`, RPC values, grid snapshots, and model records are `Sendable`
  value types.
- `NvimController`, `GridStore`, SurfaceKit, ChromeKit, ShellKit views, and the
  app shell run on the main actor.
- `FileIndex` is an actor so project walking and fuzzy queries do not execute in
  view callbacks.
- IOSurface and CGImage row snapshots are immutable once published. Explicit
  leases keep IOSurfaces out of the reuse pool while model history or the
  compositor can still reference them.

### Data flow from Neovim

1. Neovim writes MessagePack-RPC `redraw` notifications to stdout.
2. NvimKit decodes them into typed `RedrawBatch` values.
3. `NvimController` consumes batches on the main actor.
4. `WorkspaceChrome` observes every batch in wire order.
5. `GridStore.applyDeferred(_:)` applies every authoritative model event in wire
   order and classifies flushed frames as immediate or display-linked.
6. Immediate frames drain pending presentation synchronously. Compatible scroll
   frames may accumulate until the next shared display callback while motion is
   active.
7. `GridSurfaceView` updates row revisions, viewport motion, and cursor state in
   one Core Animation transaction with implicit actions disabled.

Neovim's `flush` event is the wire-level consistency boundary. Superlemon never
presents a half-applied wire frame. Display-linked coalescing may skip obsolete
intermediate *presentations*, but it never skips model events or protocol input.

### Data flow to Neovim

Keyboard, mouse, wheel, paste, and resize commands enter one main-actor FIFO in
`NvimController`. Adjacent compatible input commands coalesce without changing
their semantics. Notifications are serialized into one contiguous pipe write;
wheel repeats remain an exact repeated sequence of `nvim_input_mouse`
notifications. Paste uses one `nvim_paste` request and resize uses
`nvim_ui_try_resize`.

---

## 3. NvimKit — process and RPC layer

### Process startup

`NvimController.start()` resolves Neovim in this order:

1. executable path in `SUPERLEMON_NVIM`;
2. an app-bundled `Contents/Helpers/nvim` or development sibling binary;
3. `command -v nvim` from a login zsh;
4. `/opt/homebrew/bin/nvim` as the final fallback.

The controller launches `nvim --embed`. `SUPERLEMON_LISTEN=<path>` adds
`--listen <path>` for diagnostics and external driving.

Neovim configuration is selected before launch:

1. an existing explicit custom init path from Settings;
2. the managed `runtime/config/init.lua` when managed configuration is enabled;
3. otherwise no `-u` flag, allowing Neovim to load the user's normal init.

After the process starts, Superlemon:

1. calls `nvim_get_api_info` and records channel/API/version metadata;
2. identifies itself with `nvim_set_client_info`;
3. attaches the UI with `ext_linegrid`, `ext_multigrid`, `ext_cmdline`,
   `ext_popupmenu`, `ext_messages`, and RGB color enabled;
4. prepends the bundled runtime to `runtimepath`;
5. sources the personal Superlemon configuration once; and
6. calls `require('superlemon').setup(channel)`.

`ext_tabline` is decoded by NvimKit but is not enabled by the application. The
visible native strip is a runtime-driven buffer list, not Neovim tabpages.

The handshake currently records API compatibility data but does not reject an
older Neovim version. Version claims should therefore be treated as tested
compatibility, not an enforced runtime gate.

### RPC implementation

NvimKit owns a hand-written MessagePack encoder/decoder and MessagePack-RPC
session:

- requests correlate responses by message ID;
- input notifications are fire-and-forget;
- package-scoped notification batches preserve ordering in one pipe write;
- requests initiated by Neovim are dispatched through an async handler;
- non-redraw notifications feed a separate ordered stream;
- unknown redraw events are logged and skipped;
- malformed MessagePack terminates the session rather than advancing a corrupt
  model, while well-formed unknown/non-RPC payloads are logged and skipped;
- stderr is retained in a bounded 64 KiB ring.

`grid_line` is decoded from MessagePack values into typed `CellRun` values. It is
not a raw-byte zero-copy parser.

### Exit and quit behavior

Normal Neovim exit closes the window and terminates the current app instance.
Unexpected exit presents the exit code and captured stderr tail, then closes.
There is no current session autosave or automatic relaunch.

Quit and window close use an app-owned native flow:

1. query listed modified buffers, guarded by a two-second timeout;
2. if none are modified, issue `qa!`;
3. otherwise present Save All & Quit, Discard All & Quit, and Cancel;
4. Save All runs `wall` and then `qa!`;
5. if Neovim does not answer, offer Cancel or Force Quit.

Neovim still owns the actual write operations and buffer state. The native sheet
does not maintain a duplicate modified-buffer model.

---

## 4. GridKit — authoritative presentation model

Neovim exposes terminal-shaped grids. GridKit stores the last authoritative
state needed to render them.

```swift
struct Grid: Sendable {
    let id: Int
    private(set) var rows: Int
    private(set) var cols: Int
    private var cellRows: [[Cell]]       // row-level copy-on-write
    var damage: DamageMap                // dirty spans + ordered scrolls
    var windowFrame: WindowFrame?
    var floatAnchor: FloatAnchor?
    var msgPosition: MsgPosition?
    var viewport: Viewport?
    var viewportMargins: ViewportMargins?
    var isHidden: Bool
    var isExternal: Bool
}
```

`cells` remains a flattened compatibility view. Renderers use `rowCells(_:)` so
editing one line copies only that row. A full-width vertical `grid_scroll`
rotates row-array references; partial-column and horizontal scrolls copy only
the affected destination rows.

### Damage and scroll provenance

`DamageMap` retains:

- sorted, coalesced dirty column spans per row; and
- ordered `ScrollDelta` records.

Compatible adjacent, same-region, same-direction vertical scroll records compact
for presentation. Reversals, horizontal motion, and conflicting regions remain
ordered so the renderer can choose an atomic repaint. Recording a scroll also
translates existing dirty spans with their content and marks the exposed strip.

`FlushResult` contains:

- immutable damaged-grid snapshots and consumed damage;
- all live grids for layout;
- one-shot semantic `win_viewport` movement per grid;
- motion provenance including net delta, largest individual step, direction,
  step count, and reversal state;
- an `allowsScrollInterpolation` safety flag;
- highlights, cursor/mode, title, busy state, and mouse state.

Semantic viewport deltas are consumed once per presented frame, including when
several wire flushes coalesce. Within each wire frame, ordered compatible
`grid_scroll.rows` events are reconciled with the authoritative
`win_viewport.scroll_delta`. Matching nets preserve repeated one-row provenance
even when Neovim reports one aggregated viewport delta; mismatches force atomic
presentation and retain the authoritative semantic report. Externalized
`msg_showmode`, `msg_showcmd`, and `msg_ruler` updates do not invalidate an
otherwise-compatible grid scroll. A flush containing only those externalized
messages requests no SurfaceKit presentation and cannot drain or cancel a
display-linked scroll already waiting for vsync.

### Event handling

GridKit applies linegrid, multigrid, highlight, cursor, mode, title, option,
busy, and mouse events. `win_viewport_margins` records stationary rows/columns
such as winbars and status columns. `win_viewport` currently drives smooth
viewport motion and cursor coupling; native scrollbars are not implemented.

Some global events are decoded for forward compatibility but do not yet have an
app-shell effect, including bell, visual bell, icon, suspend, menu update, and
redraw-level directory-change events.

`option_set` values are retained by GridStore. `NvimController` parses `guifont`
and `linespace`, updates the SurfaceKit `FontSpec`, and requests a fresh Neovim
layout when metrics change.

---

## 5. SurfaceKit — row rendering and viewport motion

`GridSurfaceView` is a layer-hosting, flipped `NSView`. It resolves multigrid
positions with `GridLayout`, creates one host CALayer per visible grid, and keeps
one cursor layer above the grid tree.

```text
GridSurfaceView
├── grid host layer (one per visible Neovim grid)
│   ├── stationary base row layers
│   └── clipped SmoothViewportState
│       └── translated row container (innerHeight + 1 recyclable rows)
└── CursorLayer
```

Grid host layers preserve Neovim's resolved geometry and z-order. They are
opaque and clipped. Float positioning works, but native rounded corners, float
shadows, and background blur are not currently applied.

The IME preedit layer does not live here; `InputHostView` owns it so marked-text
state remains part of the input bridge.

### Row-backed renderer

Each `GridRenderer` owns row-sized BGRA bitmap contexts at the current backing
scale. The preferred backing is sRGB IOSurface memory:

- a compatible full-width vertical scroll rotates row backings;
- exposed or damaged rows receive new writable backings;
- published revisions are immutable;
- use-count leases and `IOSurfaceIsInUse` prevent premature reuse;
- each per-grid pool is bounded to four grid heights;
- saturation falls back to an immutable CGImage-backed context;
- only style runs intersecting dirty spans repaint; and
- `image()` composes a full grid only for tests, screenshots, and compatibility.

Core Animation receives the IOSurface object directly as row-layer contents on
the production path. Normal viewport scrolling never uploads a newly composed
full-grid image.

### Display-linked row filmstrip

Each grid has an independent `SmoothViewportState`:

- history capacity is twice the inner viewport height;
- stationary margin rows/columns remain in base layers;
- the inner viewport uses `innerHeight + 1` recyclable row layers;
- only the clipped row container translates each display tick;
- row layers rebind when an integer boundary is crossed or a row revision
  changes; and
- analytical motion remains fractional in row units, while the container's
  presented translation alone is snapped to physical backing pixels.

The first scroll from idle presents immediately. While compatible motion is
active, later scroll-only flushes may accumulate in GridStore. The next shared
display callback first advances existing motion to the frame's
`targetTimestamp`, then consumes and retargets the pending rows in the same
disabled-actions transaction. A new delta is therefore never pre-aged by the
interval before it arrived. Immediate model changes still drain pending scroll
state before presenting.

The motion model is a gesture-level sum of analytical 180 ms quintic
minimum-jerk residuals in row units. When the authoritative viewport advances
by `d` rows, a new residual begins at `-d` with zero velocity and acceleration.
That position exactly cancels the discrete row rotation for the current frame,
while the zero derivatives leave the existing envelope's velocity and
acceleration unchanged. Each residual reaches zero position, velocity, and
acceleration at its endpoint. Row arrivals and completed residuals are therefore
C2-continuous in the visual camera rather than repeatedly retargeting a spring.

Consecutive rows overlap in the same envelope. A lone row retains a finite
start and stop, while three to five closely spaced rows already share a smooth
velocity curve; additions and reversals do not insert a velocity or acceleration
tooth. Coalesced rows add their net residual once at presentation time, so no
unseen delta is pre-aged. Position, velocity, and acceleration are evaluated
analytically at the display target. Retina snapping is a presentation-only
operation and is never fed back into the envelope.

A jump is considered truly far only when one incoming semantic step exceeds the
inner viewport height. Many individually valid steps keep their overlapping
residuals even if cumulative visual debt reaches a screen. Positive and negative
residual magnitudes consume independent retained-history budgets; each budget is
capped at one inner viewport so cancellation cannot hide debt that later grows
beyond available rows. A true far jump discards unavailable history and active
residuals, then shows one final 180 ms, one-line directional cue.

Horizontal scrolls, mismatched semantic/pixel directions, resize/layout changes,
and conflicting partial scroll regions settle and present atomically.

### Exact-only exceptional presentation

The filmstrip never places a tinted, blurred, magnified, or offset approximation
above the editor. When accumulated residuals reach retained-history capacity,
the representable motion clamps while the latest authoritative exact rows remain
visible. A true beyond-screen jump keeps only the final one-row directional cue.
A delayed display callback advances the analytical envelope to its latest time
and presents that exact result; it does not synthesize intermediate imagery.

### Motion policy and accessibility

`GridSurfaceView.scrollMotionStyle` is public and source-compatible:

- `.tightNative` enables exact-row filmstrip interpolation;
- `.immediate` installs every authoritative frame without interpolation.

`NSWorkspace.accessibilityDisplayShouldReduceMotion` is observed live. Reduce
Motion settles all viewport envelopes, the cursor correction spring, and
scheduled presentation immediately, then bypasses interpolation.

### Resize and backing changes

The grid size is the number of whole cells that fit the view bounds. Live resize
requests coalesce once per main-run-loop turn. Neovim remains authoritative for
the resulting `grid_resize` and repaint sequence.

Cell width is the ceiling of the primary font's `M` advance. Cell height is the
ceiling of ascent + descent + leading, plus `linespace`. A font, linespace, or
backing-scale change destroys incompatible history, rebuilds row contexts, and
forces an authoritative repaint.

---

## 6. Text and cursor rendering

### Text rasterization

For each damaged row, SurfaceKit:

1. coalesces adjacent equal-highlight cells into style runs;
2. splits configured Powerline/PUA and synthesized-ligature runs when needed;
3. fills the full run background;
4. shapes non-synthetic text through Core Text;
5. snaps glyph positions back onto Neovim's fixed cell grid;
6. draws glyphs with `CTFontDrawGlyphs`; and
7. draws underline, double underline, dotted/dashed underline, undercurl, and
   strikethrough from resolved highlight attributes.

Core Text provides fallback segmentation for CJK, emoji, and symbols. Bold and
italic variants come from symbolic font traits when the family supports them.

The glyph cache is color-independent and scoped to one `TextRasterizer`. It is
bounded by 4,096 shaped-run entries and is rebuilt on font changes. It is not a
byte-counted 4 MB cache and no fixed hit-rate is guaranteed.

Row contexts use sRGB BGRA storage and explicitly disable font smoothing for
stable, pixel-consistent rasterization. Antialiasing remains enabled.

### Fonts, ligatures, and symbols

Neovim's `guifont` and `linespace` own font name, size, and cell spacing. Runtime
settings additionally control:

- standard ligatures;
- vector Powerline fallback;
- the process-local bundled Fira Code Nerd Font companion for symbols and
  coding ligatures; and
- forced fallback synthesis for testing or broken fonts.

The companion font affects symbols/ligatures only; normal source text continues
to use `guifont`.

### Cursor

`CursorLayer` is separate from row backing stores:

- shape, percentage, color attributes, and blink timings come from Neovim mode
  events;
- a block cursor re-renders its current cell with reversed colors into the
  cursor layer;
- blink uses a `CAKeyframeAnimation`;
- style/glyph/blink state rebuilds only when its semantic signature changes;
- scroll-only frames preserve the existing blink phase;
- active viewport motion derives cursor Y from the same pixel-snapped residual;
- the cursor clamps to the nearest inner viewport edge;
- authoritative cursor-row changes during motion retain the prior visual
  position through a 40 ms correction spring; and
- `busy_start` hides the cursor.

Typing does not currently suppress blink.

### Instrumentation and targets

Scroll frames emit `os_signpost` events and can record a bounded in-memory
diagnostic ring when `SUPERLEMON_SCROLL_TRACE=1` or a test hook is installed.
Samples include time, semantic delta, history head, envelope position, velocity,
and acceleration, snapped physical translation, and authoritative/visual cursor
Y. Display-linked presentation emits one final-state sample per target frame
after any queued residual has been applied. Setting
`SUPERLEMON_SCROLL_TRACE_FILE=/path/to/trace.jsonl` also enables sampling and
writes the bounded ring off-main after motion settles, keeping file I/O out of
the input, raster, and display-commit paths.

Low input latency, hitch-free 60/120 Hz scrolling, bounded memory growth, and
fast launch remain product targets. End-to-end key/RPC/raster/commit signposts,
cold-launch budgets, and automated performance gates are open work rather than
current test guarantees.

---

## 7. InputKit and the application input bridge

InputKit is a pure translation library. `InputHostView` in SuperlemonApp owns
AppKit event handling and is the window's first responder.

### 7.1 Keyboard path

```text
NSEvent.keyDown
├── marked text active ───────────────► interpretKeyEvents
├── translatable chord/special key ───► NvimController.sendInput
└── printable/dead-key input ─────────► interpretKeyEvents
                                        ├── insertText
                                        └── setMarkedText
```

InputKit covers Escape, Return, Backspace/Delete, Tab, arrows, Home/End,
PageUp/PageDown, Insert-position Help, F1–F20, and distinct keypad keys. Chords
use Neovim notation with canonical modifier order `M-`, `C-`, `S-`, `D-`.
Literal `<` becomes `<lt>` before `nvim_input`.

The current Option policy is left Option = Meta and right Option = native Option.
It is represented as a value type and thoroughly unit-tested, but no runtime
setting currently changes `InputHostView.optionPolicy`.

Superlemon disables macOS press-and-hold accents in its app defaults so holding
Vim movement keys repeats normally. Dead keys and marked-text IMEs still route
through `NSTextInputClient`.

### 7.2 IME and marked text

`InputHostView` implements `NSTextInputClient` and keeps uncommitted marked text
out of Neovim. A `CATextLayer` at the cursor displays the marked string with a
single underline. `firstRect(forCharacterRange:)` maps the cursor cell into
screen coordinates so macOS can place its candidate window.

Commit clears the overlay and sends escaped text through `nvim_input`; cancel
removes it without changing the buffer. Current limitations are deliberate to
document: replacement ranges, attributed substring retrieval, rich active-clause
styling, and reconversion-specific behavior are not implemented.

### 7.3 Command shortcuts and File menu

Command chords without native menu ownership reach Neovim as `<D-...>`. The
runtime installs defaults only where the user has no existing mapping. Users can
disable all defaults with `g:superlemon_default_keymaps = 0`.

Native menu key equivalents run before `keyDown`. Current File workflows are:

| Menu item | Shortcut | Current behavior |
|---|---:|---|
| Open File… | ⌘O | Native `NSOpenPanel`, then Neovim `:drop` |
| Open Folder… | ⇧⌘O | Native folder panel, `nvim_set_current_dir`, then re-root native project state |
| Save | ⌘S | Send remappable `<D-s>`; default writes a named buffer or asks the GUI for Save As |
| Save As… | ⇧⌘S | Native `NSSavePanel`, then Neovim `nvim_cmd({cmd='saveas', bang=true})` |
| Close | ⌘W | Begin the app's native modified-buffer quit flow |

Other native equivalents include Settings (`⌘,`), Paste (`⌘V`), sidebar toggle
(`⌘B`), Quick Open (`⌘P`), and Quit (`⌘Q`). Quick Open and native file panels
are app actions, not Neovim mappings. Native Tabs and Native Status Bar menu
validation reflects runtime state; general enabled/modified menu validation is
not currently pushed from Neovim.

The clipboard provider supports plain strings for the `+` and `*` registers.
It does not currently publish HTML or rich-text pasteboard flavors.

### 7.4 Mouse and trackpad

Mouse press, drag, and release become `nvim_input_mouse` with multigrid-local
coordinates. Double/triple/quadruple click counts are encoded on press. The grid
under mouse-down is latched for drag and release, as required by Neovim's
multigrid contract.

Precise trackpad deltas accumulate independently in fractional row/column units.
Each whole cell crossed emits an exact wheel notification; sub-cell remainder is
retained. Direction reversal clears stale remainder on that axis. Non-precise
wheel input is already line-based and every nonzero notch emits at least one
step. Adjacent repeats use the input queue's batched pipe write.

The managed Superlemon configuration sets `mousescroll=ver:1,hor:1` for fine
steps. A user/custom Neovim configuration remains authoritative for its own
`mousescroll`. `mouse_on` and `mouse_off` gate pointer and wheel forwarding.

Pinch-to-zoom and Force Click LSP actions are not currently implemented. Font
zoom is available through the runtime's Command-=, Command--, and Command-0
mappings.

---

## 8. ChromeKit — externalized Neovim UI

ChromeKit models and renders the external UI extensions currently enabled at
attach:

| Neovim surface | Current native presentation |
|---|---|
| `ext_cmdline` | With native status bar off: upper-center nonactivating vibrancy panel. With it on: an attributed command segment inside the bottom bar. Nested levels and block lines are modeled. |
| `ext_popupmenu` | Nonactivating child panel with virtualized NSTableView, word text, textual kind, selection syncing, and grid/cmdline anchoring. Menu/info columns and SF Symbol kind icons are not rendered. |
| `ext_messages` | One replacing toast, a bounded timestamped history panel, and NSAlert sheets for confirm-kind prompts. Toasts auto-dismiss; they do not stack. |
| `ext_tabline` | Decoder/model support only. It is not attached or used for the visible strip. |

`msg_showmode`, `msg_showcmd`, and `msg_ruler` are retained in `ChromeState`, but
the current status bar is driven by runtime notifications and evaluated
`statusline` content instead.

Command-line chunks resolve Neovim highlight IDs. Evaluated statusline segments
carry their resolved Neovim colors. Popup rows, toasts, the sidebar, and most
shell chrome use adaptive AppKit/system colors. A colorscheme therefore controls
the editor and selected native content, but it does not recolor every chrome
surface from Neovim highlight groups.

---

## 9. Bundled runtime and configuration

The bundled Lua runtime at `runtime/lua/superlemon/` is the Neovim-side half of
the application. `runtime/CONTRACT.md` is the wire contract between Lua and
Swift.

### Runtime modules

| Module | Current responsibility |
|---|---|
| `init.lua` | Idempotent bridge setup and active-channel state |
| `settings.lua` | Source the personal config once and push renderer settings |
| `keymaps.lua` | Unmapped-only macOS defaults, native Save As request, font zoom |
| `clipboard.lua` | Plain-text `+`/`*` clipboard provider |
| `chrome.lua` | Native buffer-strip/status-bar toggles and buffer notifications |
| `status.lua` | Mode/file/position/project/branch state |
| `statusline.lua` | Evaluate the user's statusline with resolved highlights |
| `git.lua` | Async Git status data for sidebar badges |
| `preview.lua` | One preview buffer with single-click/double-click promotion semantics |
| `ui.lua` | Generic sidebar, palette, toast, statusbar, input, and `vim.ui` bridge |
| `health.lua` | Runtime health reporting |

There is no current runtime service API for arbitrary native open/save panels,
Finder reveal, notifications, or URL opening, and there is no session autosave.

### Configuration hierarchy

The default experience uses `runtime/config/init.lua`. It establishes ordinary
editor defaults, optionally loads its example plugin with Neovim's package
manager, then sources:

1. bundled `runtime/config/superlemon.vim`; and
2. `$XDG_CONFIG_HOME/superlemon/init.vim` if present, normally
   `~/.config/superlemon/init.vim`.

The second file is the user's primary Superlemon override and wins setting by
setting. Settings ▸ Edit Superlemon Configuration creates it from the annotated
bundled template only when absent, then opens it in Neovim.

When Settings selects the user's normal Neovim config or an explicit custom init,
the managed init is bypassed. Runtime bootstrap still sources the personal
Superlemon init once before bridge setup. A marker prevents duplicate sourcing
when the managed init already loaded it.

Superlemon-specific values currently include native chrome toggles, native
`vim.ui`, default keymaps, renderer ligatures/Powerline/symbol options, and the
managed statusline. Neovim's standard `guifont`, `linespace`, and `mousescroll`
remain authoritative. Configuration-source and renderer-setting changes apply
on relaunch.

---

## 10. Application shell and user experience

SuperlemonApp is intentionally `NSDocument`-less. Neovim owns buffers and file
state; the native window represents the current project/workspace around that
process.

The current default window contains:

- an optional 28-point native buffer strip;
- a vertical split with the file-tree sidebar and editor host; and
- an optional 24-point native status/command bar.

The sidebar starts at 260 points and has a 180-point minimum. Opening a folder
changes Neovim's global working directory, closes project-scoped palette state,
and rebuilds the sidebar root, FileIndex, UI-component path base, Git decoration
state, and project status label. Existing buffers remain in Neovim.

Settings chooses managed/user/custom Neovim initialization and opens the
personal Superlemon config. About Superlemon uses the standard AppKit panel and
states Copyright © 2026 Jagtesh Chadha, the BSD 3-Clause License, and the Vim,
Neovim, and Sublime Text acknowledgements.

Only one workspace/editor window is currently constructed; Settings, message
history, panels, and sheets are auxiliary windows rather than workspaces.
Secure restorable state is declared, but window/session restoration is not
wired. Finder/Dock open-file callbacks, drag-and-drop, multi-window workspaces,
and a `superlemon` CLI helper are open work.

---

## 11. Testing and verification

The repository uses Swift Testing across all six library targets plus a Lua
runtime suite.

Current Swift coverage includes:

- MessagePack wire formats, incremental decoding, RPC lifecycle, ordered batch
  writes, and a real-Neovim integration test when Neovim is available;
- redraw decoding, GridStore event application, row COW, damage translation,
  deferred presentation, scroll provenance, multigrid layout, and margins;
- key, Option, mouse, click-count, and fractional wheel translation;
- Core Text raster output, highlights, cursor glyphs, IOSurface row revisions,
  pool bounds, circular history, minimum-jerk envelope equivalence and C2
  continuity, delayed frames, exact-only clamping/far jumps, pixel snapping,
  cursor coupling, and display-link idle behavior;
- cmdline, popupmenu, messages, toast/history, and native view models; and
- file indexing, ignore rules, fuzzy scoring, file operations, file tree, Quick
  Open, buffer strip, status bar, and generic UI-component stores.

The Lua specs cover setup, managed/personal config loading, runtime settings,
default mappings, clipboard, chrome/buffers, status/statusline, Git, preview
buffers, and `superlemon.ui`.

Run the current gates from the repository root:

```sh
swift test
bash runtime/tests/run.sh
swift build -c release
swift run superlemon --smoke
```

The smoke path attaches a headless grid, waits for the first flush, prints its
size/title, and exits through the normal controller lifecycle.

Current tests are programmatic; the repository does not contain recorded golden
RPC transcripts, reference-PNG baselines, a structured redraw fuzzer, a scripted
IME matrix, or automated latency/memory performance gates. Native File-menu and
About-panel workflows are presently verified through live/manual app testing
rather than a SuperlemonApp test target.

---

## 12. Implementation status and open work

### Shipped in the current tree

- Embedded Neovim process, MessagePack-RPC, typed redraw protocol, multigrid.
- Row-COW grid model and damage/provenance-aware deferred presentation.
- Core Text row renderer with IOSurface-backed revisions.
- Display-linked two-viewport filmstrip, overlapping minimum-jerk row envelopes,
  cursor coupling, exact-only exceptional presentation, and Reduce Motion.
- Keyboard, basic IME, mouse, trackpad, clipboard, and ordered input queue.
- Native cmdline, popupmenu, messages, prompts, sidebar, Quick Open, preview
  buffers, buffer strip, statusline/status bar, file panels, Settings, and About.
- Annotated managed/personal configuration and generic `superlemon.ui` bridge.

### Open work

- Rich IME clause/reconversion behavior and a multi-IME validation matrix.
- Native scrollbars, float materials/shadows, and separator affordance paint.
- Workspace overview, multiple windows, restored sessions, Finder/Dock opening,
  drag-and-drop, Services, and CLI/XPC integration.
- Buffer-aware reconciliation for sidebar rename/trash operations.
- Rich clipboard flavors and broader menu validation.
- End-to-end latency/hitch/memory instrumentation and CI performance gates.
- Signed/notarized application packaging and distribution.

---

## 13. Known risks and limitations

| Area | Current risk or limitation | Current mitigation |
|---|---|---|
| Model/render synchronization | A bad damage or row-history decision can show stale pixels | Immutable row revisions, one-shot semantic deltas, authoritative-row assertions, extensive GridKit/SurfaceKit tests, atomic fallback |
| Fast scrolling | Retained history cannot represent every true far jump or delayed compositor frame | Exact authoritative rows stay visible; one-line far cue, bounded debt, diagnostics, Reduce Motion bypass |
| IOSurface lifetime | Reusing a surface still referenced by history/compositor corrupts rows | Revision leases, IOSurface use counts, compositor-use checks, bounded CGImage fallback |
| IME | Clause editing and reconversion are incomplete | Keep marked text out of Neovim; use AppKit candidate placement; document current scope |
| Externalized messages | Plugins may depend on TUI-specific hit-enter/message behavior | Typed model, native history, atomic editor grid; no claim of complete TUI-message emulation |
| Sidebar mutations | Rename/trash may leave an already-open Neovim buffer referring to the old path | File open/preview goes through Neovim; buffer-aware mutation integration remains open |
| Config combinations | Managed, normal-user, and custom init paths can expose different plugin/chrome behavior | Explicit Settings choice, one documented personal override, idempotent runtime setup, Lua config tests |
| Version compatibility | API metadata is observed but no minimum is enforced | Unknown events are skipped; decoder tests cover supported vocabulary; an explicit version gate remains open |

---

## 14. Native workspace chrome

`NORTHSTAR.md` describes the aspirational visual destination. This section is
authoritative for what the current implementation actually does.

### 14.1 Sidebar and file operations

`FileTreeSidebarView` is a native outline-style view rooted at the current
project directory. Directories load lazily, sort before files, and expose native
context-menu actions for New File, New Folder, Rename, Delete/Trash, and Reveal
in Finder. File-type dots, Git badges, and namespaced `superlemon.ui`
decorations compose in the row.

Single-click opens a Neovim preview buffer; double-click opens permanently.
Creating, renaming, and trashing currently use Swift `FileManager`, followed by
sidebar/index refresh. These mutations do not yet rename or delete an already
open Neovim buffer, which is a documented limitation rather than hidden
behavior.

### 14.2 Preview buffers

The runtime permits at most one preview buffer. A new single-click preview
replaces the previous clean preview. Editing or explicitly promoting it makes it
permanent; modified previews are never silently discarded. The native buffer
strip renders preview tabs in italics.

### 14.3 Native buffer strip

The optional top strip displays listed Neovim buffers from
`superlemon.buffers`. Selecting uses `nvim_set_current_buf`; closing uses
`confirm bdelete`; double-click promotes a preview. It is a buffer strip, not an
`ext_tabline` tabpage strip and not a cross-window workspace switcher.

The runtime variable `g:superlemon_native_tabs` is the source of truth. The View
menu toggles runtime state and reflects the resulting notification.

### 14.4 Quick Open

Command-P opens a native upper-center palette with a scrim. The built-in picker
is driven by the Swift `FileIndex` actor and `FuzzyScorer`:

- `.git` is always excluded;
- a documented subset of root `.gitignore` is honored;
- indexing is capped at 50,000 files;
- empty queries show recently modified files first;
- nonempty queries rank fuzzy path matches and bold matched positions; and
- opening a result calls Neovim `:drop`.

Opening another folder discards the old index and invalidates stale queries.
Built-in Quick Open is currently a native app action, not a Neovim mapping and
not a bundled Lua provider. The same panel can be temporarily driven by a
plugin's `superlemon.ui` palette session.

### 14.5 Native status and command bar

The optional bottom bar is controlled by
`g:superlemon_native_statusbar`. When active, it can render the user's evaluated
Neovim `statusline` with resolved highlight colors. The runtime's adopt mode
temporarily moves that statusline out of the grid by managing `laststatus`; users
can opt out and keep both.

When no evaluated statusline is available, built-in mode, file, branch, project,
and line/column chips provide a fallback. Namespaced `superlemon.ui` segments
remain additive. While the command line is active, it replaces normal bar
content with the externalized attributed command line.

### 14.6 Appearance

The Neovim default background fills the editor host and window resize gaps.
`NvimController` derives light or dark `NSAppearance` from that background's
luminance. ShellKit views then use appearance-aware AppKit palettes; cmdline and
evaluated statusline content additionally use Neovim highlight colors.

There is no independent System/Light/Dark preference today. Persistent chrome
is flat and opaque. Vibrancy is reserved for transient command, completion, and
Quick Open panels.

### 14.7 Settings

The native Settings window chooses the Neovim init source and opens the personal
Superlemon configuration. Font, spacing, scroll steps, ligatures, symbols, native
chrome, statusline, and default-keymap customization remain file-backed rather
than duplicated in UserDefaults controls.

---

## 15. `superlemon.ui` component framework

`runtime/lua/superlemon/ui.lua` exposes native components to any Neovim plugin.
The framework is implemented and optional: it no-ops when Superlemon is not the
attached UI.

### Lua surface

```lua
local ui = require('superlemon.ui')

local ns = ui.sidebar.namespace('my-plugin')
ns:set_badge('Sources/a.swift', { text = 'M', color = '#E0B268' })
ns:set_dot('Sources', { color = '#ADC694' })
ns:clear()

ui.palette.open({
  placeholder = 'Buffers…',
  on_query = function(query)
    return { { id = 3, title = 'a.swift', subtitle = 'Sources' } }
  end,
  on_select = function(id) vim.api.nvim_set_current_buf(id) end,
})

ui.toast({ text = 'Build failed', kind = 'error' })
ui.statusbar.segment('my-plugin', { text = '⚡ 3', color = '#E0B268' })
ui.input({ prompt = 'Rename to:', default = 'name', on_submit = function(value) end })
```

### Wire protocol

Lua sends four positional notification parameters:

```lua
vim.rpcnotify(channel, 'superlemon.ui', component, method, namespace, args)
```

`args` is always a MessagePack map. `UIComponentRouter` validates the tuple and
routes it to the current native component. Namespaces isolate sidebar and status
state; clearing one namespace cannot erase another plugin's content.

Palette and input callbacks live in a Lua registry with monotonic integer IDs.
Swift invokes them through:

```lua
return require('superlemon.ui')._dispatch(callback_id, payload)
```

Palette query callbacks are awaited; select/close/input callbacks do not require
a return value. Session teardown frees callback IDs, and stale replies are
discarded by generation tokens.

### Current components

| Component | Current methods |
|---|---|
| sidebar | `set_badge`, `set_dot`, `clear` |
| palette | `open`, `close` with query/select/close callbacks |
| toast | `show` with info/warn/error kind |
| statusbar | `set_segment`, `clear` |
| input | `open` with submit/cancel callback |

The runtime overrides stock `vim.ui.select` and `vim.ui.input` when native UI is
enabled. If the user's config already installed its own implementation, that
implementation wins. The current `vim.ui.select` adapter uses a simple
case-insensitive substring filter over formatted items.

Built-in Git badges and Command-P Quick Open do not yet dogfood the generic API:
Git still uses `superlemon.git`, and the built-in picker uses Swift FileIndex.
`vim.notify` is not overridden. Quickfix, location lists, LSP progress, picker
adapters, and native hover dressing remain open integration points.

---

## 16. Splits: Neovim owns layout

Neovim is the only window-layout engine. `win_pos`, `win_float_pos`, hide/close,
and message-grid events resolve atomically at flush boundaries, and SurfaceKit
positions grid layers verbatim from that model.

Superlemon does not mirror editor splits into nested NSSplitViews. Doing so would
create competing layout authorities, continuous-pixel versus whole-cell
geometry, duplicate separator drawing, and multi-frame intermediate states.

Mouse drag and release remain on the grid that received the press. Re-hit-testing
separator drags after each `win_pos` update caused a feedback loop when the
target grid's origin moved. `InputHostView` therefore latches the press grid and
uses `GridSurfaceView.cell(at:inGrid:)` with clamping for the drag lifetime.

Native separator hit affordances and a replacement one-pixel hairline remain
open work. The managed config does not currently blank Neovim `fillchars`, and
the GUI does not paint its own split separators.

---

## 17. Invariants that protect the experience

- Neovim is authoritative for editor semantics and final pixels.
- Every protocol event is applied in wire order; display coalescing removes only
  obsolete visual work.
- A half-applied Neovim frame is never presented.
- Compatible vertical scrolling moves immutable, pixel-snapped row revisions;
  glyphs are never scaled or blurred during exact motion.
- Independent grids keep independent history and motion.
- The cursor follows the same viewport residual as its text, clamps at viewport
  edges, and scroll-only frames do not restart blink.
- Immediate mode and Reduce Motion leave no interpolated tail; scrolling never
  places synthetic imagery above the exact row filmstrip.
- Keyboard and mouse input remain ordered and unpaced; wheel batching preserves
  exact notification count and order.
- Native file panels choose paths, but Neovim performs buffer open/write/save-as
  operations.
- User mappings present before initial bridge setup beat bundled Command-key
  defaults; see the re-setup ownership caveat in `runtime/CONTRACT.md`.
- The personal Superlemon config always overrides the bundled baseline and is
  never overwritten once created.
- Persistent chrome follows macOS appearance; editor content and evaluated
  statusline colors remain Neovim-owned.
- Claims in this document distinguish current behavior from open work.
