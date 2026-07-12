# NORTHSTAR — The Superlemon Experience

Superlemon's destination is a code editor with **Vim's language and Neovim's
engine, expressed as a first-class macOS application**. Neovim remains the
authoritative editor; Superlemon turns its state into native pixels, motion,
windows, menus, panels, and gestures.

This is deliberately a **destination document**. It specifies what the finished
experience should feel like, including surfaces that may not exist yet. It is
not a claim about the current build and it is not a milestone plan. Read
[`README.md`](README.md) for the product available today and
[`DESIGN.md`](DESIGN.md) for the implemented architecture, boundaries, and open
work.

original palette and proportions. They do not define Superlemon's product model;
§10 records exactly how they are used as reference material.

---

## 1. The experience we are building

Superlemon should feel less like a terminal wrapped in a window and more like
the Mac editor Vim might have become if it had always had native pixels:

- **Neovim without a compatibility tax.** Buffers, undo, registers, mappings,
  macros, plugins, LSP, tree-sitter, terminals, splits, tabpages, highlights,
  and buffer reads/writes stay Neovim-native. Superlemon does not emulate or
  fork the editing model.
- **macOS without a lowest-common-denominator tax.** Windows, restoration,
  menus, sheets, Services, drag and drop, accessibility, text input, trackpad
  gestures, materials, and display cadence behave like a carefully made Mac
  app.
- **Instantaneous and calm.** Typing never waits for decorative work. Scrolling
  stays continuous from a slow one-line wheel step through a ProMotion fling.
  Fast operations communicate direction and progress without noisy spinners or
  gratuitous animation.
- **Flat, opaque, hairline-separated workspace chrome.** Permanent regions use
  quiet solid fills and one-physical-pixel boundaries. Depth, blur, and shadow
  are reserved for transient panels, floats, and workspace overview cards.
- **A colorscheme is part of the user's identity.** Editor colors remain exact
  Neovim highlights. Native chrome coordinates with them; it never recolors the
  source grid into a house theme.
- **Native controls are projections, not competing authorities.** A menu item,
  Settings control, status segment, or file panel must ultimately operate on
  Neovim state or on the documented Superlemon configuration. There is no
  hidden second editor preference model.
- **Progressive native enhancement.** A plain Vim configuration remains useful.
  Plugins can opt into richer native palettes, prompts, decorations, and status
  surfaces without being rewritten as Swift extensions.
- **Accessibility changes the behavior, not merely the speed.** Reduce Motion
  removes interpolation; VoiceOver receives meaningful editor and chrome
  structure; keyboard-only operation reaches every native surface.

The emotional target is restrained confidence: no imitation terminal frame, no
IDE dashboard clutter, and no animation whose purpose is to call attention to
itself. Superlemon should disappear until a native affordance is genuinely more
useful than a grid of cells.

---

## 2. Master palette

The palette defines Superlemon-owned chrome. Editor foregrounds, backgrounds,
selections, cursors, and syntax remain colorscheme-owned. Values marked `≈` are
visual targets rather than interoperability requirements.

### 2.1 Light appearance

| Token | Hex | Target use |
|---|---|---|
| `titlebar.bg` | `#F0F0EE` | Unified titlebar and buffer-strip band |
| `titlebar.text` | `#3A3A3A` / `#A2A3A5` | Workspace title / inactive tab text |
| `surface.bg` | `#FFFFFF` | Sidebar, editor-adjacent chrome, preview, status bar |
| `hairline` | `#DADADB` | Pane, header, strip, and bar boundaries |
| `sidebar.selection` | `#EAEAEA` | Full-width selected file row |
| `tab.active` | `#FFFFFF` | Active buffer tab raised by contrast, not shadow |
| `preview.codeBlock` | `#F6F8FA` | Markdown code blocks and inline-code chips |
| `preview.secondary` | `#8D8F91` | Utility-pane headers and metadata |
| `status.mode.normal` | `#004DC8` | NORMAL badge with white text |
| `status.chip` | `#E2E3E5` | Neutral fallback status segments |
| `status.position` | `#005A37` | Position cap with white text |
| `palette.bg` | `#ECECEC` | Quick Open and generic picker body |
| `palette.field` | `#FFFFFF` | Picker search row |
| `palette.selection` | `#DBDBDB` | Selected picker row |
| `palette.secondary` | `#7D7E7F` | Result paths and secondary labels |
| `palette.tertiary` | `#A9A9AA` | Counts and subdued controls |
| `viewer.canvas` | `#ECECEC` | Image-viewer canvas and information bar |
| `overview.canvas` | `#E0E0DF` | Workspace-overview background |
| `overview.card` | `#ECECEB` | Workspace-card title band and new-workspace card |
| `scrim` | black at ≈30% | Modal palette separation from workspace content |

### 2.2 Dark appearance

| Token | Hex | Target use |
|---|---|---|
| `titlebar.bg` | `#373736` | Unified titlebar and buffer strip |
| `titlebar.text` | `#CDD2D7` / `#A6ABB0` | Active / inactive title text |
| `chrome.bg` | `#1E1E1E` | Sidebar, status, utility headers |
| `hairline` | `#000000` | Pane and band boundaries |
| `sidebar.selection` | `#343434` | Full-width selected file row |
| `tab.active` | `#4A4A49` | Active buffer tab |
| `preview.bg` | `#0D1117` | Markdown reading surface |
| `preview.codeBlock` | `#1C2129` | Markdown code blocks |
| `status.chip` | `#2F3336` | Neutral fallback status segments |
| `status.mode.normal` | `#66788A` | NORMAL badge with near-black text |
| `status.position` | `#ADC694` | Position cap with near-black text |
| `palette.bg` | `#2A2A2A` | Quick Open and generic picker body |
| `palette.field` | `#1E1E1E` | Picker search row |
| `palette.selection` | `#343434` | Selected picker row |
| `palette.secondary` | `#8B9196` | Result paths and secondary labels |
| `palette.tertiary` | `#6E6E6F` | Counts and subdued controls |
| `viewer.canvas` | `#262625` | Image-viewer canvas and information bar |
| `overview.canvas` | `#20201F` | Workspace-overview background |

### 2.3 Preferences surfaces

Preferences use semantic AppKit controls over a slightly warmer dark surface
than the main workspace. The reference family is `#3A3837` for the toolbar,
`#2B2A28` for the body, `#474544` for a selected toolbar tile, and system blue
for focus and selection. These colors are subordinate to native control
legibility; standard AppKit behavior wins when platform metrics change.

### 2.4 Color ownership rules

- Syntax and grid content never use the chrome palette.
- The command line, completion, evaluated statusline, and Neovim-backed plugin
  content may carry resolved Neovim highlight colors onto native surfaces.
- AppKit semantic colors own menus, sheets, buttons, fields, focus rings, and
  accessibility contrast.
- Plugin-supplied accents are composited into designated slots; they do not
  recolor whole permanent regions.
- Wide-color support should preserve the intent of Neovim RGB highlights while
  the measured chrome tokens remain stable sRGB anchors.

---

## 3. Typography and iconography

| Role | Target typography | Notes |
|---|---|---|
| Window/workspace title | SF Pro Text, 13 pt semibold | Leading-aligned after the sidebar control |
| Buffer tabs | SF Pro Text, 13 pt | Preview italic, modified dot, middle truncation |
| Sidebar header | SF Pro Text, 13 pt semibold | Project name or compact breadcrumb |
| Sidebar rows | SF Pro Text, 13 pt | 24 pt rows, deep trees remain readable |
| Status and command bar | User's mono face, ≈11–12 pt | Bold/italic and Powerline geometry retained |
| Editor | Neovim `guifont`, normally 13–14 pt | Managed defaults are calm; user choice is absolute |
| Quick Open | SF Pro Text, 13 pt title / 11 pt path | Match ranges emphasized without visual noise |
| Preferences | Native system form typography | Toolbar labels, section headers, captions |
| Markdown prose | SF Pro Text, ≈15 pt body | GitHub-like hierarchy, native text rendering |
| Markdown code | Editor-compatible mono, ≈13 pt | Keeps code visually related to the grid |
| Image metadata | SF Pro Text, ≈11 pt | Secondary-label contrast |

Chrome icons use SF Symbols or a deliberately matched monochrome set. File types
may use restrained colored symbols with a colored-dot fallback; the interface
must not depend on a patched font being installed. Powerline separators use the
user's glyphs when they rasterize cleanly and vector geometry otherwise.

Emoji are content, not chrome. Quick Open, file rows, toolbar actions, and status
segments should not fall back to colorful emoji as permanent interface icons.

---

## 4. Target experience in detail

### 4.1 Main window

The finished workspace has four horizontal bands and up to three content
regions:

1. **Unified native titlebar** — approximately 46 pt. Standard traffic lights
   remain untouched. A sidebar toggle sits after them, followed by the workspace
   title. The trailing side holds only durable workspace actions such as
   overview and sharing/remote state when relevant; idle space remains empty.
   The band is opaque and flat, not a permanently blurred material.
2. **Native buffer strip** — 28 pt and optional. Tabs are leading-aligned,
   intrinsic-width, horizontally scrollable, and never wrap. They show modified,
   close, active, and preview states. The strip represents listed Neovim buffers
   within this workspace; it is not overloaded with Neovim tabpages or app-level
   workspaces.
3. **Content row** — edge-to-edge regions separated by hairlines:
   - **File sidebar:** resizable, approximately 300–370 pt on a large window. A
     compact header shows the project/breadcrumb plus New File, New Folder,
     Refresh, and Reveal Active File. The lazy tree uses 24 pt rows, 17 pt
     indentation, file-type symbols, Git state, diagnostics, and namespaced
     plugin decorations. Selection is a square full-row fill.
   - **Neovim editor:** the visual center of gravity. Multigrid splits and
     floats retain Neovim geometry; the colorscheme owns all cells. No permanent
     bezel surrounds it. Native overlay scrollbars are invisible at rest.
   - **Utility pane:** optional and contextual. Markdown preview, image metadata,
     documentation, or another native companion may occupy the right side
     without shrinking the editor when it has no reason to exist.
4. **Native status/command bar** — 24 pt and optional. It renders the user's
   evaluated Neovim statusline with its actual highlights. A polished fallback
   supplies mode, file, branch, project, diagnostics, encoding, progress, and
   position. While the command line is active, its content takes over the
   flexible middle rather than adding a second bottom row.

Sidebar width, utility-pane width, visibility, selected buffer, and window frame
restore with the workspace. The editor remains the first responder after every
palette, sheet, sidebar action, and tab click that does not intentionally move
focus elsewhere.

### 4.2 Workspace overview

Workspace overview is an app-level Exposé, not a Neovim tabpage metaphor:

- One card represents one top-level Superlemon workspace window and its isolated
  Neovim process.
- Live thumbnails show the actual sidebar/editor/status composition, not generic
  project icons.
- Cards arrange in a responsive grid on a calm neutral canvas, with the active
  workspace clearly but quietly selected.
- Clicking or pressing Return activates that window. Arrow keys traverse cards;
  typing filters by workspace, project, recent file, or Git branch.
- A `+` card creates a workspace through the same native folder/recent-project
  flow as File ▸ Open Folder in New Window.
- Closing a card runs that workspace's Neovim confirm flow. Unsaved buffers are
  never inferred from thumbnail state.

Neovim tabpages remain available as editor layout state inside a workspace.
Buffer tabs remain buffer tabs. The overview resolves the old temptation to make
one strip mean three different kinds of “tab.”

### 4.3 Quick Open

Quick Open is the fastest native path to a project file:

- `⌘P` opens a 498 × 346 pt Spotlight-like palette near the upper center of the
  window. It grows only when the window or accessibility text size demands it.
- A 30% black scrim dims workspace content below the persistent titlebar/buffer
  context; the palette remains visually attached to its window.
- The 34 pt search row contains a monochrome magnifier, editable query, live file
  count, and clear button.
- Results use 44 pt two-line rows: file-type mark, basename, project-relative
  path, and restrained matched-range emphasis. The selection spans the full row.
- Filtering is incremental, cancellation-safe, `.gitignore` aware, recency
  aware, and never performs filesystem work in a keystroke callback.
- `↑`/`↓`, Page Up/Down, Return, and Escape work exactly as expected. A mouse or
  trackpad can select without stealing subsequent editor focus.
- Opening a result goes through Neovim and participates in preview/pin semantics
  according to whether the user previews or confirms it.

The same visual component serves buffers, commands, code actions, symbols,
workspace search, and plugin-owned pickers. Each provider supplies data and
callbacks; Superlemon supplies consistent input, ranking affordances, layout,
accessibility, and animation.

### 4.4 File workflow, menus, and context

The menu bar should be complete enough that a Mac user can discover Superlemon
without weakening Vim's command language:

- **File:** New Buffer, Open File, Open Folder, Open Recent, Open in New Window,
  Save, Save As, Revert, Close Buffer, Close Window.
- **Edit:** Undo, Redo, Cut, Copy, Paste, Select All, Find, Spelling and
  Substitutions, and Services. Each editor command maps to Neovim or the native
  clipboard bridge; menu state reflects whether the operation is meaningful.
- **View:** sidebar, buffer strip, status bar, utility pane, native scrollbars,
  focus/fullscreen controls, and appearance command entry points.
- **Go:** Quick Open, Go to File/Symbol/Line, Back/Forward, buffer/tab/window
  navigation, and workspace overview.

Open File and Open Folder use native panels. Save and Save As preserve Neovim
encoding, autocmds, undo, swap, and modified state. Folder changes synchronize
Neovim cwd with the sidebar, file index, Git state, and plugin-relative paths.

The sidebar `NSMenu` uses native metrics and groups:

1. New File, New Folder, Open, Open to the Side;
2. Cut, Copy, Paste, Duplicate, Rename, Move to Trash;
3. Copy Relative Path, Copy Absolute Path, Reveal in Finder, Open With;
4. Git- and plugin-provided actions in stable namespaced groups.

Filesystem mutations reconcile any open Neovim buffers before the tree changes,
so a native rename cannot strand an editor buffer at its old path. FSEvents keeps
the tree and index fresh without requiring a manual refresh ritual.

About Superlemon uses the standard macOS panel and communicates the product's
lineage plainly: Copyright © 2026 Jagtesh Chadha, licensed under the BSD
3-Clause License, with thanks to Vim, Neovim, and Sublime Text for the editing
behavior, feel, layout, and client-server foundation that made Superlemon
possible.

### 4.5 Preferences

Preferences is a compact native toolbar window whose controls expose real
authorities instead of inventing opaque app-only settings.

**General** includes:

- appearance: Follow Editor (default), System, Light, or Dark;
- Neovim discovery, selected executable, version verification, and readable
  verification output;
- managed, normal-user, or explicit custom Neovim init selection;
- restoration, recent workspaces, file associations, and CLI installation; and
- the canonical personal Superlemon config path with Open and Reveal actions.

**Editor** includes:

- font family, size, line spacing, ligatures, and symbol/Powerline fallback;
- smooth-motion style, scrollbar visibility, and Reduce Motion explanation;
- preview-buffer and native-chrome behavior; and
- a clear “Use values from Neovim configuration” mode.

The source of truth remains standard Neovim options plus
`$XDG_CONFIG_HOME/superlemon/init.vim`, normally
`~/.config/superlemon/init.vim`. Native controls show the effective value and
apply it live through Neovim. Persisting a native override writes only a clearly
delimited, round-trippable block in that user-owned file; manual configuration
outside the block is never rewritten. Advanced users can ignore the forms and
edit the annotated file directly with equal fidelity.

Pre-launch choices such as executable and init source may remain native app
state because Neovim cannot supply them before it starts. Everything that can be
a Vim option or documented Superlemon variable should remain one.

### 4.6 Markdown preview

A Markdown buffer can open a synchronized native preview to the right of the
editor:

- GitHub-flavored headings, tables, task lists, code fences, links, blockquotes,
  and inline code use a readable native/web rendering surface.
- Light preview uses white with `#F6F8FA` code blocks; dark preview uses
  `#0D1117` with `#1C2129` code blocks.
- Source and preview scroll positions track by parsed block identity rather than
  fragile percentage alone. Clicking a preview block can reveal its source.
- Render work is debounced and cancellable. Typing latency never waits for the
  preview.
- Local images and project-relative links resolve safely. Remote content follows
  explicit privacy and network policy.
- A 30 pt header names the pane and provides refresh, open externally, and close
  actions without becoming another toolbar strip.

The preview is a companion to the Neovim buffer, never a second document model.
Edits, saves, undo, diagnostics, and modified state remain in Neovim.

### 4.7 Native image viewer

Opening a supported image from the sidebar routes the document region to a
native viewer while preserving workspace chrome:

- The image is centered on a flat semantic canvas, initially aspect-fit and
  pixel-sharp at integral zoom levels.
- Pinch, double-click, and keyboard shortcuts zoom around the pointer/focus;
  panning uses native trackpad physics.
- Transparency is legible without an aggressive checkerboard dominating the
  artwork.
- A 30 pt information bar shows filename, format, pixel dimensions, file size,
  color profile, and modification time, plus Reveal and Open Externally.
- Very large images decode incrementally and never block editor input in another
  workspace.

Returning to a text buffer restores the exact editor grid, cursor, scroll
position, sidebar state, and first responder.

### 4.8 Dark appearance

Dark appearance is designed, not inverted. The editor keeps its colorscheme;
neutral charcoal chrome frames it; Markdown becomes slightly darker than the
main chrome; hairlines become black; and colorful status segments switch their
foreground strategy as defined in §6.3. Window, palette, overview, preferences,
and utility surfaces must look intentionally related without collapsing into
one undifferentiated gray rectangle.

### 4.9 Scrolling, motion, and native scrollbars

The ideal scrolling model extends Superlemon's exact-row architecture rather
than asking Neovim to synthesize fake intermediate edits:

- Every compatible grid has retained row history and a permanent clipped
  filmstrip. Core Animation translates already-rasterized Retina rows on the
  display link; glyphs are not blurred, scaled, or crossfaded during exact
  motion.
- Every discrete row joins one continuous gesture-level envelope as an
  approximately 180 ms quintic minimum-jerk contribution. A new contribution
  cancels its authoritative row jump without changing the camera's existing
  velocity or acceleration; repeated rows overlap until the motion reads as one
  native gesture instead of a sequence of eased teeth.
- Position, velocity, and acceleration remain continuous through additions,
  reversals, and natural stops. The analytical path remains fractional; Retina
  pixel snapping occurs only when presenting a frame and never alters the motion
  that the next frame inherits.
- Vertical, horizontal, wrapped-line, fold, split, and margin-aware motion share
  one semantic model. Unsupported geometry settles atomically rather than
  showing a plausible but wrong transition.
- Each direction has an independently bounded history budget, so reversals
  cannot conceal more visual debt than exact retained rows can represent. True
  beyond-history jumps receive one concise one-row cue. When history clamps or a
  display callback is delayed, the latest exact rows remain visible—never a
  tinted, blurred, magnified, or misregistered substitute.
- Cursor position derives from the same residual motion as its text, clamps at
  viewport edges, preserves blink phase, and never jitters independently.
- Reduce Motion presents every authoritative state immediately and removes all
  interpolation and ornamental movement.

Each Neovim window/split gains an independent native overlay scrollbar. Thumb
geometry comes from `win_viewport`; it appears on hover/scroll, fades at rest,
and never consumes a text column. Dragging requests a semantic Neovim viewport
change and lets the same exact-row renderer reconcile the result. A scrollbar
cannot directly move pixels into a state Neovim has not accepted.

All non-scroll animation follows the same discipline: short ease-out entry,
faster exit, velocity continuity when interrupted, no bounce in dense editor
chrome, and no implicit Core Animation on authoritative grid changes.

### 4.10 Input, IME, gestures, and accessibility

The editor must pass the hard cases that distinguish a native text app from a
key event tunnel:

- Full `NSTextInputClient` composition supports Japanese, Simplified and
  Traditional Chinese, Korean, dead keys, emoji, clause selection, candidate
  placement, reconversion, and cancellation.
- Marked text is visible as a native preedit overlay but is not committed into
  Neovim until the input method commits it. Clause styling and candidate
  geometry remain pixel-aligned with the grid.
- Key repeat remains appropriate for Vim navigation. Option/Meta behavior is
  configurable per side without breaking ordinary macOS text entry.
- Command-key shortcuts occupy one remappable Neovim namespace. Native menu
  affordances and direct keyboard input cannot disagree about what `⌘S`, `⌘Z`,
  or `⌘C` means.
- Precise trackpad deltas preserve momentum. Pinch changes `guifont`; Force
  Click can request LSP hover/definition; separator drags latch the originating
  grid and remain stable while Neovim relayouts.
- Dragging files into a workspace opens them through Neovim. Dragging selected
  text out exposes appropriate pasteboard types. Services receive and replace
  text through Neovim-aware commands.
- VoiceOver can identify the active line, cursor, selection, diagnostics, tabs,
  sidebar rows, status, and transient panels. Increased Contrast, Reduce
  Transparency, Reduce Motion, keyboard navigation, and larger text are honored
  as behavior, not decorative afterthoughts.

### 4.11 Windows, workspaces, and restoration

One top-level workspace window owns one Neovim process. That boundary gives
crash isolation, straightforward teardown, independent configuration, and a
clear unit of restoration. The finished app must support many such windows
concurrently.

On relaunch, Superlemon restores window frame, project root, sidebar/utility
layout, native chrome visibility, recent/active buffers, and Neovim session
state. A failed plugin or abnormal Neovim exit produces a useful native recovery
surface with stderr context, restart, safe-start, and session-recovery choices.

Finder, Dock, `open`, Services, recent documents, and a `superlemon` CLI all
route into the appropriate existing workspace or create a new one according to
an explicit user policy. The CLI supports wait semantics for `$EDITOR` use.

### 4.12 Externalized Neovim UI

Neovim's external UI contracts should look as if macOS designed them:

- command line as the native status/command bar or a focused floating palette;
- completion and wildmenu as cell-anchored native lists with documentation;
- messages as quiet stacking toasts plus searchable history;
- confirm and input prompts as native sheets/fields whose answers return to
  Neovim;
- floats with purpose-sensitive corner radius, shadow, and optional material,
  while preserving exact Neovim content and z-order; and
- generic plugin palettes, sidebar decorations, status segments, notifications,
  progress, and inputs through `superlemon.ui`.

Native views remain renderers and interaction surfaces. They do not become a
parallel command-line editor or completion engine, nor an authoritative message
or plugin state store.

---

## 5. Destination component inventory

| Component | Northstar contract |
|---|---|
| **Window chrome** | Standard Mac window behavior inside a flat unified titlebar with sidebar and workspace controls; state restores per workspace |
| **Buffer strip** | Optional 28 pt native listed-buffer strip with active, modified, close, preview, drag, overflow, and accessibility states |
| **Workspace overview** | Responsive grid of live top-level workspace thumbnails plus a new-workspace card; never conflated with buffers or tabpages |
| **Sidebar** | Resizable lazy tree, compact project header, type symbols, Git/diagnostic/plugin decorations, FSEvents refresh, preview/pin behavior, and buffer-aware file operations |
| **Editor surface** | Exact Neovim multigrid with Core Text glyphs, per-grid row surfaces, native float treatment, and no theme translation |
| **Smooth viewport** | Display-linked exact-row history, overlapping C2 minimum-jerk row envelopes, presentation-only Retina snapping, coupled cursor, exact-only capacity handling, and atomic fallback |
| **Native scrollbars** | Independent overlay scroller per Neovim window, derived from viewport metadata and routed back through Neovim |
| **Status/command bar** | User-evaluated statusline, polished fallback, plugin segments, and in-place externalized command line |
| **Quick Open / palettes** | 498 × 346 pt file palette and reusable provider-driven native picker with cancellable async data |
| **Completion** | Cell-anchored native completion/wildmenu with kind, detail, documentation, and Neovim-owned selection |
| **Messages and prompts** | Toasts, searchable history, native confirm sheets, `vim.ui.select`, `vim.ui.input`, and progress presentation |
| **Markdown preview** | Optional synchronized GitHub-flavored companion pane, source-linked and nonblocking |
| **Image viewer** | Native fitted/zoomable image surface with metadata and external-open actions |
| **Preferences** | Native projection of launch choices, Neovim options, and the canonical personal Superlemon config |
| **Menus and system integration** | Complete App/Edit/File/View/Go/Window/Help behavior, Services, drag/drop, Finder/Dock routing, recents, and CLI |
| **Input and accessibility** | Full IME/reconversion, remappable Command namespace, gestures, VoiceOver semantics, and system display accommodations |
| **About** | Standard macOS panel with BSD 3-Clause notice and Vim/Neovim/Sublime Text acknowledgement |

The inventory is a coherence test: every component must honor the same authority
boundaries, palette, focus behavior, accessibility model, and interruption rules.
It is not a status table or implementation sequence.

---

## 6. Appearance behavior

### 6.1 Editor and chrome coordinate without merging

**Follow Editor** is the default appearance policy: Neovim's default-background
luminance selects the matching native appearance. **System**, **Light**, and
**Dark** may be explicit user choices; they set native appearance and provide
Neovim's standard `background` hint so a responsive colorscheme can adapt. They
never rewrite highlight groups behind the user's back.

The editor, preview, image viewer, overview, preferences, and chrome may use
different depths of the same appearance. A dark Markdown reading surface can be
darker than the sidebar; that deliberate seam is preferable to forcing every
region onto one background.

### 6.2 Hairlines carry structure

Light mode uses `#DADADB`; dark mode uses black. Dividers are one physical pixel
where backing scale permits it. They separate regions without faux bevels,
inset shadows, or double rules. Resizable dividers gain generous invisible hit
targets and appropriate cursors without becoming visually thick.

### 6.3 Dark chip contrast strategy

Status chips, badges, and compact accents are recomputed for dark appearance:

- **Light:** saturated fills (`#004DC8`, `#005A37`) with white foregrounds;
  neutral chips use light gray with dark text.
- **Dark:** desaturated/pastel fills (`#66788A`, `#ADC694`, `#C79595`) with
  near-black foregrounds; neutral chips use charcoal with light text.

Do not dim the light palette or put white text on every dark-mode color. The
perceptual contrast strategy flips. User-evaluated Neovim statusline colors,
however, remain the user's colors unless accessibility contrast requires a
clearly disclosed correction.

### 6.4 Selection and focus are distinct

Selection fills maintain a similar lightness delta across appearances
(`#EAEAEA` on white, `#343434` on charcoal). Keyboard focus uses the native
focus language only where it helps; it must not add blue rings around every
dense editor row. Active workspace, active buffer, sidebar selection, cursor,
and first responder are distinct states and must remain visually distinguishable.

### 6.5 Materials are transient or semantic

Permanent titlebar, sidebar, buffer strip, utility headers, and status bar are
flat and opaque. Quick Open, completion, command palettes, toasts, floating
documentation, and workspace cards may use native shadow/material because their
elevation communicates temporary layering. Reduce Transparency substitutes an
opaque equivalent with no loss of hierarchy.

### 6.6 Motion follows cause

Motion originates where the user acted, preserves velocity when interrupted,
and finishes on exact authoritative geometry. Content never moves merely to
decorate a state change. Reduce Motion removes spatial interpolation while
preserving immediate feedback, focus, and final state.

---

## 7. Architectural direction

The northstar extends the existing package boundaries rather than replacing
Neovim with a second editor core:

| Layer | Destination responsibility |
|---|---|
| **SuperlemonApp** | Multi-window lifecycle, workspace restoration/overview, menus, panels, routing, Settings, native document-view selection, and integration |
| **NvimKit** | Reliable local embedded sessions, typed MessagePack-RPC, version negotiation, ordered batch input, lifecycle, recovery context, and optional future transport abstraction |
| **GridKit** | Row-COW authoritative model, highlight/layout/viewport state, complete redraw vocabulary, damage provenance, and presentation classification |
| **SurfaceKit** | Core Text rasterization, IOSurface row revisions, exact filmstrips, horizontal/vertical motion, cursor, scrollbars, float treatment, backing changes, and diagnostics |
| **InputKit** | Pure key/mouse/gesture translation policies that remain independently testable |
| **ChromeKit** | Externalized command line, completion, messages, prompts, documentation, and transient native Neovim UI |
| **ShellKit** | Sidebar, buffers, status, Quick Open, workspace cards, utility panes, file operations, native palette, and shared chrome primitives |
| **Bundled runtime** | Default mappings, clipboard, previews, native-chrome data, statusline evaluation, Git/diagnostics providers, settings snapshot, session support, and `superlemon.ui` |

### Authority rules

- Neovim owns editor semantics, buffer contents, modified state, undo, mappings,
  windows/splits, tabpages, options, statusline meaning, and final redraw state.
- Superlemon owns macOS windows, workspace metadata, native component geometry,
  path-selection panels, file browsing, pixels, motion, focus, and accessibility.
- Operations crossing the boundary are acknowledged by the authority before the
  native surface claims success. A Save panel does not mean a file was saved;
  Neovim's successful `:write` does.
- A `flush` remains the wire-level consistency boundary. Display-linked
  coalescing may omit obsolete presentations but never model events.
- One workspace window owns one Neovim process. App-level overview and
  restoration coordinate many isolated sessions without creating a shared
  mutable editor core.

### Rendering direction

Core Text, Core Graphics, IOSurface, and Core Animation remain the preferred
stack. The WindowServer/GPU can composite native row surfaces without a bespoke
Metal glyph engine. A direct Metal renderer is justified only by measured
problems the native stack cannot solve, not by a desire to advertise GPU use.

Exact row revisions are the common currency for present, scroll, snapshot,
overview thumbnail, and velocity-gap presentation. Full-grid image composition
is an explicit consumer path, never the hot scrolling path.

### Native component framework

`superlemon.ui` should become the stable bridge through which bundled and
third-party plugins request native palettes, prompts, toasts, progress,
documentation, sidebar/status decorations, and contextual actions. Namespaces,
generation tokens, cancellation, and explicit callback lifetimes prevent one
plugin from corrupting another's surface.

Built-in features should dogfood the public component model where it preserves
latency and authority. Native UI is an enhancement tier: a plugin without an
adapter still works through Neovim's ordinary UI.

### Splits and utility panes

Neovim remains the only layout engine inside the editor grid. Superlemon does
not mirror its split tree into nested `NSSplitView`s. Native utility panes live
outside that grid and the app shell owns their split geometry. Native separator
paint/hit targets may overlay Neovim separators, but width/height changes are
requested from Neovim at whole-cell crossings.

---

## 8. Quick-reference geometry and motion sheet

| Measure | Northstar value |
|---|---|
| Unified titlebar | ≈46 pt; standard traffic-light geometry |
| Buffer strip | 28 pt |
| Sidebar width | ≈300 pt default; 220 pt minimum; ≈370 pt on wide layouts |
| Sidebar header | ≈30 pt |
| Sidebar row height / indent | 24 pt / 17 pt |
| Utility pane width | ≈420–560 pt; ≈320 pt minimum |
| Utility-pane header | ≈30 pt |
| Status/command bar | 24 pt |
| Quick Open panel | 498 × 346 pt; 34 pt search row; 44 pt results; ≈10 pt radius |
| Quick Open vertical offset | ≈96 pt below persistent window chrome |
| Quick Open scrim | black at ≈30% |
| Context menu | Native metrics; reference ≈216 pt wide, 22 pt rows |
| Preferences window | ≈540 × 460 pt; native toolbar items ≈54 × 44 pt |
| Workspace overview card | Reference ≈408 × 256 pt; responsive grid |
| Workspace overview gaps | ≈22 pt, with ≈48 pt top breathing room |
| Markdown preview padding | 24 pt |
| Image metadata bar | ≈30 pt |
| Editor font | User `guifont`; managed target 13–14 pt mono |
| Hairlines | 1 physical pixel at active backing scale |
| Window corners/shadow | Standard macOS window geometry |
| Scroll history | At least two inner viewports per grid |
| Exact filmstrip | Inner viewport height + 1 recyclable row layer |
| Scroll envelope | ≈0.180 s quintic minimum-jerk contribution per row; C2-continuous overlap |
| Display-linked sampling | Analytical at the target frame; Retina snapping at presentation only |
| Cursor correction | ≈0.040 s critical correction |
| Exceptional scroll gaps | Exact rows remain visible; bounded debt or one-line far cue; no synthetic overlay |
| Palette entry/exit | One display period in; ≈50–90 ms out |

These values define visual rhythm, not rigid window constraints. Small windows
collapse optional regions before crushing the editor. Large windows add useful
content width, not arbitrary empty gutters. Accessibility text size may expand
native controls while preserving hierarchy and whole-cell editor geometry.

---

## 9. The bar for “feels native”

The destination is reached only when all of these statements are true together:

- A user's existing Neovim configuration loads without a Superlemon-specific
  compatibility fork.
- `ciw`, macros, registers, terminal buffers, LSP, and plugin floats feel like
  Neovim; `⌘O`, `⌘S`, `⌘Q`, Services, drag/drop, restoration, and IME feel like
  macOS.
- Typing reaches a visible glyph within one display period under ordinary load.
  No preview, index, Git, thumbnail, or animation work may sit on that path.
- Slow scrolling is directly connected and repeated rows merge into a single
  smooth speed curve without acceleration teeth. Fast scrolling has no repeated
  frame, reverse tail, overlay snap, cursor-independent jitter, or two-period
  hitch at 60 or 120 Hz.
- Text remains sharp and pixel-snapped throughout exact motion. Visual
  approximation is rare, bounded, directionally honest, and gone before the
  user's eye can mistake it for editor state.
- The active buffer, preview state, modified state, current workspace, focus,
  and selection are always legible without extra labels or bright decoration.
- Every transient surface can be opened, navigated, confirmed, and dismissed
  by keyboard; focus reliably returns to the editor.
- Japanese, Chinese, and Korean users can compose and reconvert text without
  corrupting Neovim state or fighting the candidate window.
- VoiceOver and display accessibility settings expose the same operation, not a
  lesser parallel interface.
- Abnormal Neovim exit, missing binary, incompatible version, and failed file
  operation produce actionable native recovery rather than silent failure.
- Reopening Superlemon restores a working place, not merely an empty rectangle
  at the old coordinates.
- A plugin can add useful native UI without blocking the main thread, owning a
  Swift object, or losing its terminal-Neovim behavior.

Performance should be continuously measured at input write, RPC decode, model
apply, row raster, transaction commit, display presentation, and memory growth.
The northstar is not “usually smooth”; it is the absence of identifiable hitches
in deterministic 60 Hz and ProMotion stress scenarios.

---

## 10. Visual-reference provenance


- `dark-mode.png`
- `quick-open.png`
- `tabs.png`
- `file-context-menu.png`
- `settings-general.png`
- `settings-editor.png`
- `image-viewer.png`

The full-window captures are approximately @1×; the preferences and context-menu
crops are approximately @2×. Colors in §2 were sampled or adapted from those
images, and several geometry values in §8 began as measurements from them.

Superlemon adopts the references' calm opaque chrome, generous sidebar, native
palette, workspace cards, utility views, and Powerline-aware status language.
It intentionally replaces their ambiguous tab semantics with three explicit
concepts: buffers in the strip, Neovim tabpages inside the editor, and workspace
windows in overview. It also leaves product licensing UI out of the visual
northstar; licensing and distribution policy belong to product decisions, while
About Superlemon carries the BSD 3-Clause notice and editor acknowledgements.

The reference application's product name is not Superlemon's identity. Its
screenshots are evidence for taste and proportion; the contract above defines
the Superlemon destination.
