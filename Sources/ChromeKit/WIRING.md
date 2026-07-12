# ChromeKit wiring

ChromeKit renders Neovim's externalized command line, completion menu, and
messages with AppKit. It depends only on NvimKit; the app layer supplies GridKit
highlight and geometry information through small value/closure APIs.

All ChromeKit state and controllers are `@MainActor` and are owned once per
window/Neovim session by `WorkspaceChrome`:

```swift
let chromeState = ChromeState()
let cmdlinePanel = CmdlinePanelController(font: editorFont)
let popupMenu = PopupMenuPanelController(font: editorFont)
let toasts = MessageToastController()

toasts.attach(to: window)
```

`MessageToastController` displays one replacing toast at the top-right of the
content view. It also keeps a bounded, timestamped message history opened by
clicking the toast or choosing View > Message History.

## Redraw ownership and presentation order

Feed every `RedrawBatch` to `ChromeState`, without pre-filtering. ChromeState
ignores events outside `ext_cmdline`, `ext_popupmenu`, `ext_messages`, and
`ext_tabline`.

The app applies ChromeKit state before applying the same batch to GridKit:

```swift
for await batch in session.uiEvents {
    chrome.apply(batch)

    switch gridStore.applyDeferred(batch) {
    case .none:
        break
    case .immediate:
        drainPendingPresentation()
    case .displayLinked:
        let scheduled = surface.schedulePresentationOnNextDisplay {
            drainPendingPresentation()
        }
        if !scheduled { drainPendingPresentation() }
    }
}

func drainPendingPresentation() {
    guard let flush = gridStore.consumePendingPresentation() else { return }
    surface.present(flush)
}
```

GridKit always applies authoritative events in wire order. Compatible vertical
viewport scroll flushes may remain unconsumed until the next display-link
callback; mixed, layout, resize, highlight, and unsupported-scroll frames drain
immediately. ChromeState still consumes every wire batch, but fires `onChange`
only once per `apply(_:)` call and only when chrome state actually changed.

This distinction is intentional: the native grid may coalesce obsolete visual
scroll work without dropping Neovim state or delaying input.

## Synchronizing the native surfaces

Set one observer and synchronize all ChromeKit views from it:

```swift
chromeState.onChange = { [weak self] in self?.syncChrome() }
```

### Command line

The destination depends on Neovim-owned native chrome state:

- With `native_statusbar` enabled, dismiss the floating panel and call
  `statusBar.renderCommand(...)`. The command line temporarily replaces the
  harvested statusline; fallback mode and line/column indicators remain.
- With `native_statusbar` disabled, clear the status-bar command and render the
  model in `CmdlinePanelController`, calling `present(over:)` while non-nil.

Refresh `cmdlinePanel.font` from `GridSurfaceView.fontSpec` before rendering so
font zoom and `guifont` changes are reflected in the native command line.

### Popup menu

`popupmenu_select` changes only the selected row, so an already-presented panel
can use `render(_:)` without reloading its items. A fresh `popupmenu_show` must
be re-anchored when any of its identity fields change:

```swift
struct PopupIdentity: Equatable {
    let items: [PopupMenuItem]
    let grid: Int
    let row: Int
    let col: Int
}
```

If the new identity differs, call `present(anchoredAt:in:model:)`; otherwise
call `render(_:)`. Passing `nil` to `render` dismisses the panel. The controller
opens below the anchor when space permits and flips upward at the window edge.

### Messages and confirmations

```swift
toasts.render(chromeState.messages)

if let confirm = chromeState.pendingConfirm {
    chromeState.clearPendingConfirm()
    presentConfirmAlert(confirm)
}
```

Toasts exclude `confirm`/`confirm_sub` messages automatically. New messages
replace the visible toast, all kinds auto-dismiss after three seconds by
default, and the history retains the durable record. Error messages use error
styling but do not remain indefinitely.

Confirm prompts are app-owned `NSAlert` sheets. Parse Neovim's bracketed or
parenthesized hotkeys from the final prompt line and return the selected key
through `NvimController.sendInput`; use `<Esc>` for cancellation. Clear the
pending model before presenting so a later redraw cannot open the same sheet
again.

`ChromeState.showmode`, `showcmd`, `ruler`, `history`, and `tabline` retain their
decoded ext-message/tabline state, but they do not currently drive ShellKit.
The native status bar and buffer strip are instead driven by the runtime
notifications documented in `runtime/CONTRACT.md`.

## Highlight resolution

`CmdlinePanelController.render` accepts:

```swift
typealias HighlightResolver = (Int) -> (fg: NSColor, bg: NSColor)
```

ChromeKit deliberately does not depend on GridKit. The app resolves an ID to
concrete colors, including defaults and `reverse`, before crossing the module
boundary:

```swift
let highlightResolver: HighlightResolver = { hlID in
    let attrs = controller.store.highlights.resolved(id: hlID)
    return (nsColor(attrs.foreground), nsColor(attrs.background))
}
```

ID 0 must resolve to the current `default_colors_set` pair. The cmdline renderer
uses that pair for its block cursor and paints explicit chunk backgrounds only
for nonzero highlight IDs.

## Grid cell to popup anchor

`present(anchoredAt:in:model:)` takes a point in the host window's `contentView`
coordinate space. `GridSurfaceView` is flipped, so Neovim and view coordinates
both grow downward; AppKit conversion handles the change into the content view:

```swift
guard let gridRect = surface.rect(ofGrid: grid) else { return .zero }
let cellTopLeft = NSPoint(
    x: gridRect.minX + CGFloat(col) * surface.cellSize.width,
    y: gridRect.minY + CGFloat(row) * surface.cellSize.height
)
return surface.convert(cellTopLeft, to: window.contentView)
```

Grid `-1` is the wildmenu/cmdline case:

- If the cmdline is in the native status bar, anchor at the bar's top edge; the
  popup will flip upward.
- If the floating cmdline is active, its panel frame is in screen coordinates.
  Convert that screen frame through the host window before deriving the anchor.

Do not manually flip rows and do not use a cached grid origin: multigrid frames
can move between redraws.

## Input and lifecycle

ChromeKit views are render-only. The cmdline and completion panel are
nonactivating; editor keys continue through InputKit to Neovim. App-owned
sheets and palettes coordinate returning focus to `InputHostView` when they
close. Message History is an explicit key utility window rather than part of
the editor-input path.

Controllers can be constructed and rendered without a visible parent window.
Their panels use `isReleasedWhenClosed = false`; retain the controllers for the
window lifetime and reuse `render`, `present`, and `dismiss`.

## Tests

```sh
swift test --filter ChromeKitTests
```

The ChromeKit suite covers nested command lines and blocks, popup selection,
sizing and anchoring, message replacement/history/expiry, confirmation state,
tabline decoding, rendering smoke tests, and headless controller lifecycle.
