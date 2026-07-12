# ShellKit wiring

ShellKit contains Superlemon's native workspace chrome. It has no package
dependencies; the app connects it to Neovim, ChromeKit, and the filesystem with
plain Swift values and closures.

`WorkspaceChrome` owns one set of ShellKit objects per window/session:

```swift
let statusBar = StatusBarView()
let tabStrip = BufferTabStripView()
let sidebar = FileTreeSidebarView()
let quickOpen = QuickOpenPanelController()
var fileIndex = FileIndex(root: projectRoot)
```

## Components

| Component | Isolation | Current role |
|---|---|---|
| `FuzzyScorer` | pure | fzy-style subsequence scoring and match positions |
| `FileIndex` | actor | project walk, root `.gitignore` subset, `.git` exclusion, 50,000-file cap, modification-time ordering |
| `QuickOpenPanelController` | `@MainActor` | 498 x 346 native file/plugin palette with scrim |
| `StatusBarView` | `@MainActor` | fallback chips, harvested Neovim statusline, cmdline overlay, plugin segments |
| `BufferTabStripView` | `@MainActor` | 28-point listed-buffer strip, including preview tabs |
| `FileTreeSidebarView` | `@MainActor` | lazy outline tree, preview/open callbacks, git and plugin decorations |
| `FileOperations` | pure namespace | filesystem mutations emitted by the sidebar |

## Window layout and appearance

The standard macOS titlebar is outside `contentView`. The content layout is:

```text
NSWindow.contentView
├── BufferTabStripView       28 pt when native_tabs is enabled, otherwise 0
├── NSSplitView
│   ├── FileTreeSidebarView  starts at 260 pt; minimum 180 pt
│   └── InputHostView
│       └── GridSurfaceView
└── StatusBarView            24 pt when native_statusbar is enabled, otherwise 0
```

`superlemon.chrome` is authoritative for both native bands. On a toggle, update
the height constraint and `isHidden`, lay out the root view, and immediately
notify Neovim of the changed grid size. The View menu only requests a toggle;
it never owns a parallel preference.

Native chrome follows `NSWindow.effectiveAppearance`. The editor background and
text continue to follow Neovim's highlight state. Settings does not contain a
second theme, font, ligature, or chrome preference store.

```swift
func applyAppearance(dark: Bool) {
    statusBar.render(statusBar.model, dark: dark)
    sidebar.applyAppearance(dark: dark)
    quickOpen.applyAppearance(dark: dark)
    tabStrip.applyAppearance(dark: dark)
}
```

## Runtime notification ownership

`NvimController` consumes `session.notifications` on the main actor and passes
all `superlemon.*` methods to `WorkspaceChrome.handleNotification`. The complete
wire contract is in `runtime/CONTRACT.md`.

### Status model: `superlemon.status`

Map the payload into `StatusModel`:

| Payload | Model | Behavior |
|---|---|---|
| `mode` | `StatusMode(rawNvimMode:)` | `i` insert, `v`/`V`/CTRL-V/`s`/`S` visual, `c` command, `R` replace, otherwise normal |
| `file` | `file` | cwd-relative; basename is shown; empty becomes `[No Name]` |
| `modified` | `modified` | adds the modified dot |
| `branch` | `branch` | empty hides the branch chip |
| `line`, `col` | `line`, `col` | one-based line/column chip |
| `total_lines` | `totalLines` | retained in the model |
| `project` | `project` | empty hides the project chip |

```swift
let model = StatusModel(
    mode: StatusMode(rawNvimMode: payload["mode"]?.stringValue ?? "n"),
    file: payload["file"]?.stringValue ?? "",
    modified: payload["modified"]?.boolValue ?? false,
    branch: payload["branch"]?.stringValue ?? "",
    line: payload["line"]?.intValue ?? 1,
    col: payload["col"]?.intValue ?? 1,
    totalLines: payload["total_lines"]?.intValue ?? 1,
    project: payload["project"]?.stringValue ?? ""
)
statusBar.render(model, dark: isDark)
```

This model always stays current, but its built-in chips are a fallback. A
nonempty harvested statusline replaces all built-in chips.

### Harvested statusline: `superlemon.statusline`

The runtime evaluates the user's active window/global `statusline` with
highlights and sends styled runs:

```swift
guard let text = value["text"]?.stringValue else { return nil }
return StatuslineSegment(
    text: text,
    fg: value["fg"]?.intValue.map { UInt32(truncatingIfNeeded: $0) },
    bg: value["bg"]?.intValue.map { UInt32(truncatingIfNeeded: $0) },
    bold: value["bold"]?.boolValue ?? false,
    italic: value["italic"]?.boolValue ?? false
)
```

Pass the array to `statusBar.renderStatusline`. Nil or empty segments restore
the fallback chips. The runtime evaluates `%=` fill with private-use U+E000;
`StatusBarView` splits at that marker and uses native flexible space to preserve
left/right alignment instead of drawing hundreds of spaces.

When the native bar is enabled, adopt mode is on by default: the runtime saves
Neovim's `laststatus`, sets it to zero, and renders the same statusline in the
native bar. Setting `g:superlemon_adopt_statusline = 0` prevents that option
mutation; whether an in-grid bar remains visible then follows the user's own
`laststatus` value.

`superlemon.ui` plugin segments are additive. They are ordered by namespace and
remain visible beside either fallback chips or a harvested statusline. An
active command line temporarily hides them.

### Command line

ChromeKit owns decoded `ext_cmdline` state. `WorkspaceChrome` routes it into the
status bar while `native_statusbar` is enabled:

```swift
statusBar.renderCommand(attributedCommandLine)
// cmdline_hide, Esc, or disabling the native bar:
statusBar.renderCommand(nil)
```

The command occupies the flexible middle. It hides file/branch/project,
harvested statusline, and plugin segments while keeping fallback mode and
line/column visible. With the native bar disabled, the command line moves to
ChromeKit's floating panel instead.

### Buffer strip: `superlemon.buffers`

The strip represents listed buffers, not Neovim tabpages:

```swift
let tabs = (payload["buffers"]?.arrayValue ?? []).compactMap { value -> BufferTab? in
    guard let bufnr = value["bufnr"]?.intValue else { return nil }
    return BufferTab(
        bufnr: bufnr,
        name: value["name"]?.stringValue ?? "",
        modified: value["modified"]?.boolValue ?? false,
        preview: value["preview"]?.boolValue ?? false
    )
}
tabStrip.render(
    tabs: tabs,
    current: payload["current"]?.intValue ?? -1,
    dark: isDark
)
```

Wire actions back through Neovim:

```swift
tabStrip.onSelect = { controller.switchToBuffer($0) }
tabStrip.onClose = { controller.closeBuffer($0) }       // confirm bdelete
tabStrip.onPromote = { controller.promoteBuffer($0) }   // double-click preview
```

Preview tabs are italic. A modified buffer shows a dot. Overflow scrolls
horizontally without elasticity.

### Git and plugin decorations

`superlemon.git` supplies cwd-relative paths and one-letter statuses. Resolve
them below the current `projectRoot` and pass the resulting absolute-path map to
`sidebar.setGitStatus`. Files show `M`, `A`, `D`, `R`, `U`, or `?`; ancestor
directories of changed files show a dot.

`UIComponentRouter` owns namespaced `superlemon.ui` decorations. It resolves
their paths against the same root, composes namespaces lexicographically (later
names win per path), then calls `sidebar.setUIDecorations`. An explicit plugin
decoration wins over the built-in git badge for the same row.

## Quick Open

`FileIndex.refresh()` walks from scratch. Hidden files are included unless
excluded by the root `.gitignore`; `.git` is always skipped. Empty queries
return the most recently modified files, not learned usage recency.

The current workspace owns a replaceable index rather than capturing one index
forever:

```swift
quickOpen.onQueryChange = { [weak self] query in
    guard let self else { return }
    let index = self.fileIndex
    let generation = self.fileIndexGeneration
    Task {
        let results = await index.query(query)
        let total = await index.count()
        guard generation == self.fileIndexGeneration else { return }
        self.quickOpen.display(
            results: results.map { QuickOpenResult(path: $0.path, positions: $0.positions) },
            totalCount: total
        )
    }
}

quickOpen.onOpen = { [weak self] relativePath in
    guard let self else { return }
    self.controller.openFile(self.projectRoot.appendingPathComponent(relativePath).path)
}
```

`present(over:)` installs a 30-percent scrim, places the panel near the upper
center, focuses the query field, and fires the empty query. Escape, Return,
arrow keys, double-click, and scrim click are handled by the controller.

The same panel hosts `superlemon.ui` plugin palette sessions. Opening a plugin
palette saves the built-in callbacks; selection/close restores them. Choosing
Go > Quick Open while a plugin palette is active closes that session first.

The index currently refreshes:

- when the workspace attaches;
- after native sidebar mutations;
- after File > Open Folder replaces the project root.

There is no filesystem watcher. A raw `:cd` inside Neovim updates runtime
status/git data but does not currently carry an absolute cwd back to the app,
so it cannot re-root the native sidebar/index. File > Open Folder is the
coordinated workspace-change path.

## Workspace re-rooting

`NvimController.openFolder` asks Neovim to run `nvim_set_current_dir` and
returns `getcwd()`. Only after that succeeds does `WorkspaceChrome` use the
canonical Neovim cwd to:

1. close built-in and plugin palettes;
2. increment the file-index generation and replace `FileIndex`;
3. clear old git and plugin decorations;
4. reset the sidebar root and project status;
5. refresh the new index.

Open buffers remain Neovim-owned and survive the root change.

## Sidebar and preview behavior

```swift
sidebar.setRoot(projectRoot)
sidebar.showsHiddenFiles = false

sidebar.onOpenFile = { controller.previewFile($0) }
sidebar.onOpenFilePermanently = { controller.openFilePermanently($0) }
```

- Single-click opens `require("superlemon.preview").open(path)`.
- Double-click opens `open_permanent(path)`.
- At most one clean preview exists; opening another wipes the old preview.
- Editing promotes a preview automatically. Modified previews are never
  discarded.
- Double-clicking an italic tab calls `promote(bufnr)`.
- Clicking an already-open permanent file switches to it without disturbing a
  different preview.

Directories list children only on first expansion. `.git` remains hidden even
when hidden files are enabled.

Sidebar context actions emit absolute-path `FileOperation` values. The app
owns the mutation and subsequent refresh:

```swift
sidebar.onFileOperation = { operation in
    switch operation {
    case .revealInFinder(let path):
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    case .rename(let path, _), .trash(let path):
        try? FileOperations.perform(operation)
        sidebar.reload(path: (path as NSString).deletingLastPathComponent)
        Task { await fileIndex.refresh() }
    case .newFile(let directory, _), .newFolder(let directory, _):
        try? FileOperations.perform(operation)
        sidebar.reload(path: directory)
        Task { await fileIndex.refresh() }
    }
}
```

`FileOperations.trash` uses the Trash and falls back to permanent removal when
the Trash is unavailable. The current implementation does not rename or wipe a
matching open Neovim buffer after native rename/trash; documentation and callers
must not assume that synchronization exists. New File and New Folder currently
use the default names `untitled` and `untitled folder`; mutation failures are
discarded by the app's current `try?` call rather than shown to the user.

## Native File menu workflows

Path selection is native; buffer and editor state remain authoritative in
Neovim:

| Menu item | Shortcut | Flow |
|---|---|---|
| Open File... | Command-O | single-file `NSOpenPanel` then `:drop` through `nvim_exec_lua` |
| Open Folder... | Shift-Command-O | directory panel, `nvim_set_current_dir`, then coordinated workspace re-root |
| Save | Command-S | re-inject `<D-s>` so a user's mapping wins; bundled mapping writes named buffers or requests Save As for unnamed ones |
| Save As... | Shift-Command-S | `NSSavePanel` seeded from `nvim_buf_get_name`, then `nvim_cmd` `saveas!`; AppKit has already confirmed replacement |

Open File and Quick Open use `:drop` so an existing buffer is selected rather
than duplicated. Save As remains a Neovim command so encoding, autocmds, undo,
and buffer naming stay coherent.

## Configuration hierarchy

Neovim launch configuration is selected in this order:

1. an explicit custom init path from Settings;
2. Superlemon's managed `runtime/config/init.lua` (the default);
3. the user's normal Neovim init when managed configuration is disabled.

The managed init sources the annotated bundled baseline
`runtime/config/superlemon.vim`, then the personal override at
`$XDG_CONFIG_HOME/superlemon/init.vim` (normally
`~/.config/superlemon/init.vim`). Custom/user-Neovim-init launches still source
the personal Superlemon file once during bridge bootstrap.

Settings chooses the init source and creates/opens the personal Superlemon file
from the bundled template. Font, scrolling, native chrome, per-split
minimap/scrollbar toggles and minimap geometry, native UI, keymap, statusline,
and renderer preferences live in that file and apply on relaunch; they are not
mirrored into native controls. Live View-menu accessory toggles still round-trip
through Neovim's `superlemon.chrome` state.

## Tests

```sh
swift test --filter ShellKitTests
```

The ShellKit suite covers fuzzy ranking and positions, file-index walking,
ignore rules, caps and modification ordering, filesystem operations, lazy tree
loading and reloads, git/UI decoration precedence, buffer-tab rendering and
callbacks, tab overflow, built-in and harvested status bars, command/plugin
segments, plugin palette rows, appearance changes, and view smoke tests.
