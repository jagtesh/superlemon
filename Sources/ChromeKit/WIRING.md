# ChromeKit — app wiring guide

How SuperlemonApp integrates ChromeKit. ChromeKit depends only on NvimKit;
everything below is `@MainActor`.

## Objects to own (one set per window / nvim session)

```swift
let chromeState = ChromeState()
let cmdlinePanel = CmdlinePanelController(font: editorFont)   // same mono font as the grid
let popupMenu    = PopupMenuPanelController(font: editorFont)
let toasts       = MessageToastController()
```

Attach the toast controller once the window exists:

```swift
toasts.attach(to: window)   // toasts stack top-right of window.contentView
```

## 1. Who calls `apply`

Feed **every** `RedrawBatch` from `NvimSession.uiEvents` to *both* GridKit and
`chromeState.apply(_:)` — ChromeState filters to the chrome events
(`cmdline*`, `popupmenu*`, `msg*`, `tablineUpdate`) and ignores the rest, so
no pre-filtering is needed:

```swift
for await batch in session.uiEvents {
    gridStore.apply(batch)        // GridKit (other owner)
    chromeState.apply(batch)      // ChromeKit
}
```

Ordering: call `apply` on the same batch you hand to GridKit, *before* acting
on `flush`, so chrome and grid present the same frame.

## 2. When to render / present

Set one observer; it fires **at most once per mutating batch** (coalesced):

```swift
chromeState.onChange = { [weak self] in self?.syncChrome() }

func syncChrome() {
    // -- cmdline ---------------------------------------------------------
    cmdlinePanel.render(chromeState.cmdline, resolver: highlightResolver)
    if chromeState.cmdline != nil {
        cmdlinePanel.present(over: window)   // idempotent; re-present is fine
    }
    // render(nil, ...) dismisses the panel automatically.

    // -- popupmenu ---------------------------------------------------------
    if let menu = chromeState.popupmenu {
        if popupMenu.isPresented {
            popupMenu.render(menu)           // selection-only updates: no reload
        } else {
            let anchor = windowPoint(forGrid: menu.grid, row: menu.row, col: menu.col)
            popupMenu.present(anchoredAt: anchor, in: window, model: menu)
        }
    } else {
        popupMenu.render(nil)                // hides
    }

    // -- messages ------------------------------------------------------------
    toasts.render(chromeState.messages)      // confirm-kind skipped automatically

    if let confirm = chromeState.pendingConfirm {
        chromeState.clearPendingConfirm()
        presentConfirmAlert(confirm)          // app-owned NSAlert, see §5
    }

    // showmode / showcmd / ruler / tabline feed the status bar & buffer
    // switcher (ShellKit surfaces): chromeState.showmode, .showcmd, .ruler,
    // .tabline — plain value reads, no ChromeKit view exists for them.
}
```

## 3. The highlight resolver closure

`CmdlinePanelController.render` takes
`HighlightResolver = (_ hlID: Int) -> (fg: NSColor, bg: NSColor)`.
Back it with GridKit's highlight table (ChromeKit deliberately has no GridKit
dependency). ID 0 **must** return the default fg/bg pair
(`default_colors_set`); the renderer uses it for the block cursor
(inverted: cursor fg = default bg, cursor bg = default fg) and only paints
chunk backgrounds for `hlID != 0`.

```swift
let highlightResolver: HighlightResolver = { hlID in
    let attrs = gridStore.highlightTable[hlID]   // GridKit lookup
    let fg = attrs?.foreground ?? gridStore.defaultColors.fg
    let bg = attrs?.background ?? gridStore.defaultColors.bg
    return (NSColor(rgb: fg), NSColor(rgb: bg))  // app-side RGBColor -> NSColor
}
```

## 4. Grid cell -> window point for the popupmenu anchor

`present(anchoredAt:in:model:)` takes a point in the **window's contentView
coordinate space** (AppKit bottom-left origin) marking the **top-left corner
of the anchor cell**; the popup's top-left lands there, dropping downward.

```swift
func windowPoint(forGrid gridID: Int, row: Int, col: Int) -> NSPoint {
    if gridID == -1 {
        // Cmdline (wildmenu) completion: anchor under the cmdline panel.
        // Simplest v1: anchor at the panel's bottom-left in content coords.
        let panelFrame = window.contentView!.convert(
            cmdlinePanel.panel.frame, from: nil)  // screen -> content view
        return NSPoint(x: panelFrame.minX + 16, y: panelFrame.minY)
    }
    // Editor grid: GridSurfaceView knows each grid's origin (win_pos) and
    // cell metrics. Flip rows: nvim rows grow downward, AppKit y grows upward.
    let gridOrigin = surfaceView.origin(ofGrid: gridID)  // in surfaceView coords, top-left
    let x = gridOrigin.x + CGFloat(col) * cellWidth
    let yTop = gridOrigin.y + CGFloat(row) * cellHeight   // top-left-origin distance from grid top
    let pointInSurface = NSPoint(x: x, y: surfaceView.bounds.height - yTop)
    return surfaceView.convert(pointInSurface, to: window.contentView)
}
```

Anchor one cell **below** the completed row if you want the popup to sit under
the word being completed (`row + 1` before flipping) — nvim's `row`/`col` is
the anchor cell of the pum itself, which already accounts for this.

## 5. Confirm dialogs (ext_messages `confirm` kind)

ChromeKit never shows NSAlert. When `pendingConfirm` is non-nil:

1. Build an `NSAlert` from `confirm.text` (this is how `:confirm qa` /
   ⌘Q becomes a native Save / Don't Save / Cancel sheet).
2. Answer nvim by sending the keys the prompt expects, e.g.
   `session.notify("nvim_input", [.string("y")])` (or `n` / `<Esc>`), matching
   the choices in the message text.
3. Call `chromeState.clearPendingConfirm()` when the alert is presented.

## 6. Input while chrome is up

ChromeKit views are render-only; **all** keys still go to nvim via InputKit
(the cmdline panel shows state, it is not a text field; arrows/`<C-n>` drive
the popupmenu inside nvim). Do not give the panels key focus —
`.nonactivatingPanel` is already set.

## 7. Headless / lifecycle notes

- All controllers construct and `render` without a screen; `present` no-ops
  window-server work when the parent window isn't visible.
- Panels set `isReleasedWhenClosed = false`; keep the controllers alive for
  the window's lifetime and just `render`/`dismiss`.
- `MessageToastController.autoDismissInterval` defaults to 4s for non-error
  kinds; error kinds persist until click or `msg_clear`.
- Tabline: no ChromeKit view in this wave by design (NORTHSTAR delta 3 — tabs
  are workspaces). `chromeState.tabline` carries current index + names for the
  future buffer switcher.
