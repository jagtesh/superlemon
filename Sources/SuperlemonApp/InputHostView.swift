// InputHostView — the first responder and NSTextInputClient (DESIGN.md §7).
//
// The GridSurfaceView is a subview filling this view; hitTest returns self so
// every event lands here. Key path: marked text → IME; translatable chords →
// nvim_input; everything else → interpretKeyEvents → insertText/setMarkedText.

import AppKit
import InputKit
import QuartzCore
import SurfaceKit

@MainActor
final class InputHostView: NSView, @preconcurrency NSTextInputClient {
    weak var controller: NvimController?
    let surface: GridSurfaceView

    /// DESIGN §7.1 default: left Option = Meta, right Option = Option.
    var optionPolicy: OptionPolicy = .default

    private let keyTranslator = KeyTranslator()
    private let mouseTranslator = MouseTranslator()
    private var scrollAccumulator = ScrollAccumulator()

    private var markedText = ""
    private var markedSelectedRange = NSRange(location: NSNotFound, length: 0)
    private var preeditLayer: CATextLayer?

    init(frame frameRect: NSRect, surface: GridSurfaceView, controller: NvimController) {
        self.surface = surface
        self.controller = controller
        super.init(frame: frameRect)
        wantsLayer = true
        surface.frame = bounds
        surface.autoresizingMask = [.width, .height]
        addSubview(surface)
        surface.onGridAccessoryWheelRequest = { [weak self] request in
            self?.handleAccessoryWheel(request)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Grid pixels remain owned by this first-responder view. Explicit native
    /// controls in an acknowledged accessory gutter are the sole exception.
    /// AppKit passes `point` in the superview's coordinate system; this view
    /// sits at a sidebar-width x offset inside the split view, so converting
    /// from the correct space is load-bearing.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard super.hitTest(point) != nil else { return nil }
        let pointInSurface = surface.convert(point, from: superview)
        return surface.accessoryInteractionView(at: pointInSurface) ?? self
    }

    override func layout() {
        super.layout()
        surface.frame = bounds
        controller?.surfaceLayoutChanged()
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        if hasMarkedText() {
            interpretKeyEvents([event])  // the IME owns the event
            return
        }
        switch keyTranslator.translate(event, policy: optionPolicy) {
        case .input(let notation):
            controller?.sendInput(notation)
        case .passToIME:
            interpretKeyEvents([event])
        case .ignored:
            break
        }
    }

    override func flagsChanged(with event: NSEvent) {
        // Modifier-only events are deliberately ignored (DESIGN §7.1).
    }

    // MARK: - NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = Self.plainString(from: string)
        clearMarkedText()
        guard !text.isEmpty else { return }
        controller?.sendInput(KeyTranslator.escapeForInput(text))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text = Self.plainString(from: string)
        if text.isEmpty {
            clearMarkedText()
            return
        }
        markedText = text
        markedSelectedRange = selectedRange
        updatePreeditLayer()
    }

    func unmarkText() {
        clearMarkedText()
    }

    func hasMarkedText() -> Bool {
        !markedText.isEmpty
    }

    func markedRange() -> NSRange {
        hasMarkedText()
            ? NSRange(location: 0, length: (markedText as NSString).length)
            : NSRange(location: NSNotFound, length: 0)
    }

    func selectedRange() -> NSRange {
        hasMarkedText() ? markedSelectedRange : NSRange(location: NSNotFound, length: 0)
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?)
        -> NSAttributedString?
    {
        nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [.underlineStyle]
    }

    /// Anchors the IME candidate window at the cursor cell (view → window →
    /// screen).
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let cellRect =
            surface.cursorRect
            ?? NSRect(x: 0, y: 0, width: surface.cellSize.width, height: surface.cellSize.height)
        let rectInSelf = convert(cellRect, from: surface)
        let rectInWindow = convert(rectInSelf, to: nil)
        return window?.convertToScreen(rectInWindow) ?? rectInWindow
    }

    func characterIndex(for point: NSPoint) -> Int {
        0
    }

    override func doCommand(by selector: Selector) {
        // Prefer translating the triggering key event — it carries the real
        // modifiers — falling back to a map of common selectors.
        if let event = NSApp.currentEvent, event.type == .keyDown,
            case .input(let notation) = keyTranslator.translate(event, policy: optionPolicy)
        {
            controller?.sendInput(notation)
            return
        }
        switch selector {
        case NSSelectorFromString("insertNewline:"): controller?.sendInput("<CR>")
        case NSSelectorFromString("deleteBackward:"): controller?.sendInput("<BS>")
        case NSSelectorFromString("insertTab:"): controller?.sendInput("<Tab>")
        case NSSelectorFromString("cancelOperation:"): controller?.sendInput("<Esc>")
        default: break  // never call super — unhandled selectors would beep
        }
    }

    // MARK: - Preedit overlay (minimal, DESIGN §7.2)

    private func clearMarkedText() {
        markedText = ""
        markedSelectedRange = NSRange(location: NSNotFound, length: 0)
        preeditLayer?.removeFromSuperlayer()
        preeditLayer = nil
    }

    private func updatePreeditLayer() {
        guard let hostLayer = layer else { return }
        let textLayer: CATextLayer
        if let existing = preeditLayer {
            textLayer = existing
        } else {
            textLayer = CATextLayer()
            textLayer.zPosition = 1000
            hostLayer.addSublayer(textLayer)
            preeditLayer = textLayer
        }
        textLayer.contentsScale = window?.backingScaleFactor ?? 2

        let spec = surface.fontSpec
        let font =
            spec.name.flatMap { NSFont(name: $0, size: spec.size) }
            ?? NSFont.monospacedSystemFont(ofSize: spec.size, weight: .regular)
        let attributed = NSAttributedString(
            string: markedText,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.textColor,
                .backgroundColor: NSColor.textBackgroundColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ])
        textLayer.string = attributed

        let textSize = attributed.size()
        let anchor = surface.cursorRect.map { convert($0, from: surface).origin } ?? .zero
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textLayer.frame = NSRect(
            x: anchor.x, y: anchor.y,
            width: ceil(textSize.width),
            height: max(surface.cellSize.height, ceil(textSize.height)))
        CATransaction.commit()
    }

    private static func plainString(from string: Any) -> String {
        (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
    }

    // MARK: - Mouse (DESIGN §7.4)

    override func mouseDown(with event: NSEvent) { sendMouse(event, button: .left, action: .press) }
    override func mouseDragged(with event: NSEvent) { sendMouse(event, button: .left, action: .drag) }
    override func mouseUp(with event: NSEvent) { sendMouse(event, button: .left, action: .release) }

    override func rightMouseDown(with event: NSEvent) { sendMouse(event, button: .right, action: .press) }
    override func rightMouseDragged(with event: NSEvent) { sendMouse(event, button: .right, action: .drag) }
    override func rightMouseUp(with event: NSEvent) { sendMouse(event, button: .right, action: .release) }

    override func otherMouseDown(with event: NSEvent) { sendMouse(event, button: .middle, action: .press) }
    override func otherMouseDragged(with event: NSEvent) { sendMouse(event, button: .middle, action: .drag) }
    override func otherMouseUp(with event: NSEvent) { sendMouse(event, button: .middle, action: .release) }

    /// The grid latched at mouse-press: per the nvim UI contract, DRAG and
    /// RELEASE events must stay on the press grid. Re-hit-testing per event
    /// made separator drags toward the moving window (right/down) feed back
    /// through that window's shifting origin — the jitter asymmetry.
    private var dragGrid: Int?

    private func sendMouse(_ event: NSEvent, button: MouseButton, action: MouseAction) {
        guard let controller, controller.isMouseEnabled else { return }
        var cell: (grid: Int, row: Int, col: Int)?
        switch action {
        case .press:
            cell = cellUnderPointer(event)
            dragGrid = cell?.grid
        case .drag, .release:
            if let grid = dragGrid {
                let point = surface.convert(event.locationInWindow, from: nil)
                if let local = surface.cell(at: point, inGrid: grid) {
                    cell = (grid: grid, row: local.row, col: local.col)
                }
            }
            if cell == nil { cell = cellUnderPointer(event) }
            if action == .release { dragGrid = nil }
        }
        guard let cell else { return }
        let arguments = mouseTranslator.translate(
            button: button,
            action: action,
            modifiers: Modifiers(rawValue: event.modifierFlags.rawValue),
            grid: cell.grid,
            row: cell.row,
            col: cell.col,
            clickCount: event.clickCount)
        controller.sendMouse(
            button: arguments.button, action: arguments.action, modifier: arguments.modifier,
            grid: arguments.grid, row: arguments.row, col: arguments.col)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let controller, controller.isMouseEnabled else { return }
        let steps = scrollAccumulator.accumulate(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            cellWidth: surface.cellSize.width,
            cellHeight: surface.cellSize.height,
            isPrecise: event.hasPreciseScrollingDeltas)
        guard !steps.isEmpty, let cell = cellUnderPointer(event) else { return }
        let modifiers = Modifiers(rawValue: event.modifierFlags.rawValue)
        emitWheel(.up, count: steps.up, modifiers: modifiers, cell: cell)
        emitWheel(.down, count: steps.down, modifiers: modifiers, cell: cell)
        emitWheel(.left, count: steps.left, modifiers: modifiers, cell: cell)
        emitWheel(.right, count: steps.right, modifiers: modifiers, cell: cell)
    }

    /// Native minimap/scroller views forward wheel deltas here so there is
    /// still exactly one accumulator and one ordered Neovim mouse route.
    private func handleAccessoryWheel(_ request: GridAccessoryWheelRequest) {
        guard let controller, controller.isMouseEnabled else { return }
        let steps = scrollAccumulator.accumulate(
            deltaX: request.deltaX,
            deltaY: request.deltaY,
            cellWidth: surface.cellSize.width,
            cellHeight: surface.cellSize.height,
            isPrecise: request.hasPreciseDeltas)
        guard !steps.isEmpty else { return }
        let modifiers = Modifiers(rawValue: request.modifierFlagsRawValue)
        let cell = (grid: request.gridID, row: 0, col: 0)
        emitWheel(.up, count: steps.up, modifiers: modifiers, cell: cell)
        emitWheel(.down, count: steps.down, modifiers: modifiers, cell: cell)
        emitWheel(.left, count: steps.left, modifiers: modifiers, cell: cell)
        emitWheel(.right, count: steps.right, modifiers: modifiers, cell: cell)
    }

    private func emitWheel(
        _ direction: WheelDirection, count: Int, modifiers: Modifiers,
        cell: (grid: Int, row: Int, col: Int)
    ) {
        guard count > 0, let controller else { return }
        let arguments = mouseTranslator.translateWheel(
            direction: direction, modifiers: modifiers,
            grid: cell.grid, row: cell.row, col: cell.col)
        controller.sendMouse(
            button: arguments.button, action: arguments.action,
            modifier: arguments.modifier,
            grid: arguments.grid, row: arguments.row, col: arguments.col,
            repeatCount: count)
    }

    private func cellUnderPointer(_ event: NSEvent) -> (grid: Int, row: Int, col: Int)? {
        surface.cell(at: surface.convert(event.locationInWindow, from: nil))
    }

    // MARK: - Menu actions

    @objc func paste(_ sender: Any?) {
        controller?.pasteFromPasteboard()
    }
}
