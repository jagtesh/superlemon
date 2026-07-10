# ShellKit wiring guide

How SuperlemonApp embeds the ShellKit components and connects their
callbacks. ShellKit has **no package dependencies** — everything crosses the
boundary as plain Swift values and closures. Geometry/colors follow
NORTHSTAR.md; architecture follows DESIGN.md §14.

## Components at a glance

| Component | Isolation | Role |
|---|---|---|
| `FuzzyScorer` | nonisolated (pure) | fzy-style subsequence scoring + highlight positions |
| `FileIndex` | actor | project file walk (`.git` skipped, root `.gitignore` subset, 50k cap), recency list, fuzzy queries |
| `QuickOpenPanelController` | @MainActor | 498×346 borderless palette + scrim, ⌘P file open |
| `StatusBarView` | @MainActor NSView | 24pt powerline bar fed by `superlemon.status`; command overlay via `renderCommand` |
| `BufferTabStripView` | @MainActor NSView | 28pt buffer tab strip fed by `superlemon.buffers` |
| `FileTreeSidebarView` | @MainActor NSView | lazy NSOutlineView tree, ~370pt, context menu |
| `FileOperations` | nonisolated enum | the actual FileManager mutations behind sidebar ops |

## Window layout

```
NSWindow contentView
├── titlebar band                        (app)
├── BufferTabStripView        (height 28, full width, below the titlebar)
├── NSSplitView
│   ├── FileTreeSidebarView   (≈370pt, holdingPriority high)
│   └── GridSurfaceView       (SurfaceKit; editor)
└── StatusBarView             (pinned bottom, height 24, full width)
```

`StatusBarView`, `BufferTabStripView`, and `FileTreeSidebarView` all expose
`applyAppearance(dark:)` / `render(...dark:)` — call them from the window's
`viewDidChangeEffectiveAppearance` observation (and when the Settings theme
override changes, per DESIGN §14.6).

The tab strip's visibility follows `superlemon.chrome` (CONTRACT.md): show
it while `native_tabs` is true, collapse it (height 0 / removed) when
false. Same deal for the status bar and `native_statusbar`. nvim state is
the source of truth — the GUI only reflects the notification; View-menu
toggles call `require('superlemon').chrome_toggle(...)`.

## Status bar ← `superlemon.status`

The runtime plugin pushes `superlemon.status` (runtime/CONTRACT.md) as one
msgpack map. Map it field-for-field into `StatusModel`:

| payload key | `StatusModel` field | notes |
|---|---|---|
| `mode` (raw, e.g. `"n"`, `"niI"`, `"i"`, `"v"`, `"V"`, CTRL-V, `"c"`, `"R"`) | `mode` | `StatusMode(rawNvimMode:)` does the mapping (first char: i→INSERT, v/V/^V/s/S→VISUAL, c→COMMAND, R→REPLACE, else NORMAL) |
| `file` (cwd-relative, `""` if unnamed) | `file` | view renders basename; `""` renders `[No Name]` |
| `modified` | `modified` | adds the ● dot to the file chip |
| `branch` (`""` when not a repo) | `branch` | branch chip hides itself on empty |
| `line`, `col` (1-based) | `line`, `col` | right green cap chip `"15:9"` |
| `total_lines` | `totalLines` | reserved for a percent readout; carried now |
| `project` (basename of cwd) | `project` | right-side project chip; hides on empty |

```swift
// In the RPC notification handler (NvimController):
let model = StatusModel(
    mode: StatusMode(rawNvimMode: payload["mode"]),
    file: payload["file"], modified: payload["modified"],
    branch: payload["branch"], line: payload["line"], col: payload["col"],
    totalLines: payload["total_lines"], project: payload["project"]
)
Task { @MainActor in statusBar.render(model, dark: isDarkAppearance) }
```

`render` is idempotent and cheap — call it on every notification and on every
appearance flip (chip colors are recomputed per NORTHSTAR §6.3, not dimmed).

### Command segment (overlay on the flexible middle)

While the user is in cmdline mode (ChromeKit's `ext_cmdline` events, or the
`mode == "c"` transitions of `superlemon.status`), the bar's middle can show
the command being typed:

```swift
statusBar.renderCommand(NSAttributedString(string: ":" + cmdlineText))
// ...on cmdline_hide / <Esc>:
statusBar.renderCommand(nil)
```

- Non-nil: the attributed string renders mono, single-line, tail-truncated,
  leading-aligned right after the mode badge; the file/branch/project chips
  hide. The mode badge and line:col cap stay visible throughout.
- `render(_:dark:)` during an active command keeps updating chip *content*
  but leaves them hidden until `renderCommand(nil)` restores them.
- The overlay carries its own attributes; recompute/re-set it on appearance
  flips if you colored it.

## Buffer tab strip ← `superlemon.buffers`

The runtime plugin pushes `superlemon.buffers` (runtime/CONTRACT.md) while
`native_tabs` is on. Map it directly:

| payload key | strip argument | notes |
|---|---|---|
| `buffers[]` (`bufnr`, `name`, `modified`) | `tabs: [BufferTab]` | `name` cwd-relative, `""` if unnamed (renders `[No Name]`); view shows the basename, full name as tooltip; `modified` adds the ● dot |
| `current` | `current: Int` | bufnr of the active tab (distinct fill + primary text) |

```swift
let tabStrip = BufferTabStripView()      // 28pt; BufferTabStripView.stripHeight

// In the RPC notification handler (NvimController):
let tabs = payload["buffers"].map {
    BufferTab(bufnr: $0["bufnr"], name: $0["name"], modified: $0["modified"])
}
Task { @MainActor in
    tabStrip.render(tabs: tabs, current: payload["current"], dark: isDarkAppearance)
}

// Tab actions go back through the standard API (CONTRACT.md):
tabStrip.onSelect = { bufnr in nvim.request("nvim_set_current_buf", [bufnr]) }
tabStrip.onClose = { bufnr in nvim.command("confirm bdelete \(bufnr)") }
```

- `render(tabs:current:dark:)` is idempotent and rebuilds the strip; call it
  on every notification. `applyAppearance(dark:)` re-renders the last model
  for appearance flips.
- Overflow scrolls horizontally inside the strip (hidden scrollers, no
  elasticity) — pin the strip to the window width and let it clip.
  is a separate, later ShellKit wave.

## Quick-open palette (⌘P)

```swift
let index = FileIndex(root: projectRoot)
Task { await index.refresh() }                  // at workspace open + on demand

let quickOpen = QuickOpenPanelController()
quickOpen.onQueryChange = { [weak quickOpen] query in
    Task {
        let results = await index.query(query)  // ranked; empty query = recency
        let total = await index.count()
        await MainActor.run {
            quickOpen?.display(
                results: results.map { QuickOpenResult(path: $0.path, positions: $0.positions) },
                totalCount: total
            )
        }
    }
}
quickOpen.onOpen = { relativePath in
    // :drop keeps buffer state coherent (DESIGN §14.1)
    nvim.command("drop \(escaped(projectRoot + "/" + relativePath))")
}
quickOpen.onClose = { /* return key focus to the grid surface */ }

// ⌘P handler:
quickOpen.present(over: window)                 // installs the 30% scrim itself
```

- `present(over:)` positions the panel upper-center (top edge 96pt below the
  parent content top), adds it as a child window, installs the scrim, focuses
  the field, and fires `onQueryChange("")` so the initial recency listing +
  live count appear immediately.
- Esc / ⏎ are handled inside the controller (`close()` / `onOpen`); ↑↓ move
  the selection. The app only needs the three closures above.
- `applyAppearance(dark:)` mirrors the window appearance.
- The index is a snapshot; call `refresh()` on `FocusGained`/`DirChanged`
  forwarded from the runtime plugin (FSEvents is a later wave).

## Sidebar

```swift
let sidebar = FileTreeSidebarView()             // FileSystemLister by default
sidebar.setRoot(projectRoot)                    // lists lazily on expansion
sidebar.showsHiddenFiles = false                // toggle from a header button

sidebar.onOpenFile = { absolutePath in
    nvim.command("drop \(escaped(absolutePath))")   // routes through nvim
}
sidebar.onFileOperation = { op in
    switch op {
    case .revealInFinder(let path):
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    case .rename(let path, _), .trash(let path):
        try? FileOperations.perform(op)         // the ACTUAL mutation
        // tell the runtime plugin so buffers follow (bufrename/bwipeout),
        // then refresh the affected subtree:
        sidebar.reload(path: (path as NSString).deletingLastPathComponent)
    case .newFile(let dir, _), .newFolder(let dir, _):
        try? FileOperations.perform(op)
        sidebar.reload(path: dir)
    }
}
```

- The sidebar never mutates the filesystem itself; it only *emits*
  `FileOperation` values (paths are absolute). The app decides ordering
  vs. nvim state, performs via `FileOperations`, then calls
  `reload(path:)` — nil reloads the whole tree, a path re-lists just that
  (already-loaded) subtree.
- "Rename" starts an inline edit of the row label; committing a changed name
  emits `.rename(path:newName:)`.
- `FileOperations.trash` uses `FileManager.trashItem` and falls back to
  permanent removal only where the Trash is unavailable (e.g. sandboxed
  test runners).
- Directory children are listed **only on first expansion** (`DirectoryLister`
  is injectable; tests use a counting wrapper to prove laziness). `.git` is
  never shown, even with hidden files on.

## Test surface

Everything above is constructible headless: `swift test --filter
ShellKitTests` exercises scorer ranking/positions, index walking +
`.gitignore` + cap + recency, file operations against temp dirs, tree
laziness, tab-strip rendering/callbacks/overflow, the status-bar command
overlay, and render smoke tests that walk the view hierarchies for the
expected strings.
