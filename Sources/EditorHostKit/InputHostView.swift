// InputHostView — the first responder and NSTextInputClient (DESIGN.md §7).
//
// The GridSurfaceView is a subview filling this view; hitTest returns self so
// every event lands here. Key path: marked text → IME; translatable chords →
// nvim_input; everything else → interpretKeyEvents → insertText/setMarkedText.

import AppKit
import CoreText
import GridKit
import InputKit
import QuartzCore
import SurfaceKit

@MainActor
public final class InputHostView: NSView, @preconcurrency NSTextInputClient, NSMenuItemValidation {
    weak var controller: NvimController?
    let surface: GridSurfaceView

    /// DESIGN §7.1 default: left Option = Meta, right Option = Option.
    var optionPolicy: OptionPolicy = .default

    private let keyTranslator = KeyTranslator()
    private let mouseTranslator = MouseTranslator()
    private var scrollAccumulator = ScrollAccumulator()

    /// A small, coherent text-storage window for the active composition. The
    /// actual Neovim buffer is deliberately not mirrored: ordinary committed
    /// input still travels through nvim_input, while AppKit can query and
    /// replace the marked range without being told that every screen point is
    /// document index zero.
    private var markedText = NSAttributedString(string: "")
    private var markedDocumentRange = NSRange(location: NSNotFound, length: 0)
    private var markedSelectedRange = NSRange(location: NSNotFound, length: 0)
    private var suppressUnmarkCommit = false
    private var preeditLayer: CATextLayer?

    private var accessibleText = ""
    private var accessibleSelection = NSRange(location: 0, length: 0)
    private var accessibilityUpdateScheduled = false

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
    public required init?(coder: NSCoder) { fatalError("not supported") }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func resignFirstResponder() -> Bool {
        // A focus change should not silently throw away an in-progress word.
        // Session teardown uses discardMarkedTextForSessionChange() instead.
        if hasMarkedText() { unmarkText() }
        return super.resignFirstResponder()
    }

    /// Grid pixels remain owned by this first-responder view. Explicit native
    /// controls in an acknowledged accessory gutter are the sole exception.
    /// AppKit passes `point` in the superview's coordinate system; this view
    /// sits at a sidebar-width x offset inside the split view, so converting
    /// from the correct space is load-bearing.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard super.hitTest(point) != nil else { return nil }
        let pointInSurface = surface.convert(point, from: superview)
        return surface.accessoryInteractionView(at: pointInSurface) ?? self
    }

    public override func layout() {
        super.layout()
        surface.frame = bounds
        controller?.surfaceLayoutChanged()
    }

    // MARK: - Keyboard

    public override func keyDown(with event: NSEvent) {
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

    public override func flagsChanged(with event: NSEvent) {
        // Modifier-only events are deliberately ignored (DESIGN §7.1).
    }

    // MARK: - NSTextInputClient

    public func insertText(_ string: Any, replacementRange: NSRange) {
        let text = Self.plainString(from: string)
        clearMarkedText()
        guard !text.isEmpty else { return }
        controller?.sendInput(KeyTranslator.escapeForInput(text))
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let attributed = Self.attributedString(from: string)
        if attributed.length == 0 {
            clearMarkedText()
            return
        }

        let origin: Int
        let selectionOffset: Int
        if hasMarkedText(), Self.range(replacementRange, isContainedIn: markedDocumentRange) {
            // This is the replacement case we can honor without pretending to
            // mirror the Neovim document: replace a UTF-16 slice of the active
            // composition and preserve its surrounding attributed clauses.
            let localReplacement = NSRange(
                location: replacementRange.location - markedDocumentRange.location,
                length: replacementRange.length)
            let updated = NSMutableAttributedString(attributedString: markedText)
            updated.replaceCharacters(in: localReplacement, with: attributed)
            origin = markedDocumentRange.location
            selectionOffset = localReplacement.location
            markedText = updated
        } else {
            // Arbitrary-buffer reconversion is deliberately unsupported until
            // there is a changedtick-validated Neovim text snapshot. Keep a
            // local composition coordinate space instead of inventing one.
            origin = markedDocumentRange.location == NSNotFound
                ? 0 : markedDocumentRange.location
            selectionOffset = 0
            markedText = attributed
        }
        markedDocumentRange = NSRange(location: origin, length: markedText.length)
        let relativeLocation = selectedRange.location == NSNotFound
            ? attributed.length
            : min(max(0, selectedRange.location), attributed.length)
        let relativeLength = min(
            max(0, selectedRange.length), attributed.length - relativeLocation)
        markedSelectedRange = NSRange(
            location: origin + selectionOffset + relativeLocation,
            length: relativeLength)
        updatePreeditLayer()
    }

    public func unmarkText() {
        let committed = markedText.string
        clearMarkedText()
        if !suppressUnmarkCommit, !committed.isEmpty {
            controller?.sendInput(KeyTranslator.escapeForInput(committed))
        }
    }

    public func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    public func markedRange() -> NSRange {
        hasMarkedText() ? markedDocumentRange : NSRange(location: NSNotFound, length: 0)
    }

    public func selectedRange() -> NSRange {
        hasMarkedText() ? markedSelectedRange : NSRange(location: NSNotFound, length: 0)
    }

    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?)
        -> NSAttributedString?
    {
        guard hasMarkedText(), range.location != NSNotFound else { return nil }
        let intersection = NSIntersectionRange(range, markedDocumentRange)
        guard intersection.length > 0 else { return nil }
        actualRange?.pointee = intersection
        let local = NSRange(
            location: intersection.location - markedDocumentRange.location,
            length: intersection.length)
        return markedText.attributedSubstring(from: local)
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [.underlineStyle, .underlineColor, .markedClauseSegment, .textAlternatives]
    }

    /// Anchors the IME candidate window at the cursor cell (view → window →
    /// screen).
    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let cellRect =
            surface.cursorRect
            ?? NSRect(x: 0, y: 0, width: surface.cellSize.width, height: surface.cellSize.height)
        var rectInSelf = convert(cellRect, from: surface)
        if hasMarkedText() {
            let requested: NSRange
            if range.location == NSNotFound {
                requested = markedSelectedRange
            } else if range.length == 0,
                range.location >= markedDocumentRange.location,
                range.location <= NSMaxRange(markedDocumentRange)
            {
                requested = NSRange(location: range.location, length: 0)
            } else {
                let intersection = NSIntersectionRange(range, markedDocumentRange)
                requested = intersection.length > 0 ? intersection : markedSelectedRange
            }
            actualRange?.pointee = requested
            let localLocation = min(
                max(0, requested.location - markedDocumentRange.location), markedText.length)
            let prefix = markedText.attributedSubstring(
                from: NSRange(location: 0, length: localLocation))
            rectInSelf.origin.x += ceil(prefix.size().width)
            rectInSelf.size.width = max(1, surface.cellSize.width)
        } else {
            actualRange?.pointee = NSRange(location: NSNotFound, length: 0)
        }
        let rectInWindow = convert(rectInSelf, to: nil)
        return window?.convertToScreen(rectInWindow) ?? rectInWindow
    }

    public func characterIndex(for point: NSPoint) -> Int {
        guard hasMarkedText(), let window, let preeditLayer else { return NSNotFound }
        let pointInWindow = window.convertPoint(fromScreen: point)
        let pointInSelf = convert(pointInWindow, from: nil)
        let frame = preeditLayer.frame
        guard frame.insetBy(dx: -2, dy: -2).contains(pointInSelf) else { return NSNotFound }

        let line = CTLineCreateWithAttributedString(markedText)
        let localX = min(max(0, pointInSelf.x - frame.minX), frame.width)
        let index = CTLineGetStringIndexForPosition(line, CGPoint(x: localX, y: 0))
        let bounded = index == kCFNotFound ? markedText.length : min(max(0, index), markedText.length)
        return markedDocumentRange.location + bounded
    }

    public override func doCommand(by selector: Selector) {
        if hasMarkedText() {
            // Commands emitted by an input manager while it owns marked text
            // must not leak to Neovim and move/delete unrelated buffer text.
            if selector == NSSelectorFromString("cancelOperation:") {
                discardMarkedTextForSessionChange()
            }
            return
        }
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
        markedText = NSAttributedString(string: "")
        markedDocumentRange = NSRange(location: NSNotFound, length: 0)
        markedSelectedRange = NSRange(location: NSNotFound, length: 0)
        preeditLayer?.removeFromSuperlayer()
        preeditLayer = nil
    }

    /// Cancel composition without committing it. Used when the embedded
    /// session is being replaced or torn down; ordinary focus loss commits.
    func discardMarkedTextForSessionChange() {
        suppressUnmarkCommit = true
        inputContext?.discardMarkedText()
        clearMarkedText()
        suppressUnmarkCommit = false
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
        let attributed = NSMutableAttributedString(attributedString: markedText)
        let fullRange = NSRange(location: 0, length: attributed.length)
        attributed.addAttributes([
            .font: font,
            .foregroundColor: NSColor.textColor,
            .backgroundColor: NSColor.textBackgroundColor,
        ], range: fullRange)
        if attributed.attribute(.underlineStyle, at: 0, effectiveRange: nil) == nil {
            attributed.addAttribute(
                .underlineStyle, value: NSUnderlineStyle.single.rawValue, range: fullRange)
        }
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

    private static func attributedString(from string: Any) -> NSAttributedString {
        if let attributed = string as? NSAttributedString { return attributed.copy() as! NSAttributedString }
        return NSAttributedString(string: (string as? String) ?? "")
    }

    private static func range(_ candidate: NSRange, isContainedIn container: NSRange) -> Bool {
        guard candidate.location != NSNotFound, container.location != NSNotFound else {
            return false
        }
        let (candidateEnd, candidateOverflow) = candidate.location.addingReportingOverflow(
            candidate.length)
        let (containerEnd, containerOverflow) = container.location.addingReportingOverflow(
            container.length)
        return !candidateOverflow && !containerOverflow
            && candidate.location >= container.location
            && candidateEnd <= containerEnd
    }

    // MARK: - Accessibility

    /// Expose the active Neovim grid as a coherent visible text snapshot.
    /// This is intentionally viewport-scoped; claiming a synthetic full
    /// document would make VoiceOver navigation less trustworthy, not more.
    func updateAccessibility(with flush: FlushResult) {
        guard let grid = flush.grids[flush.cursor.grid] else { return }
        var lines: [String] = []
        lines.reserveCapacity(grid.rows)
        for row in 0..<grid.rows {
            lines.append(grid.rowText(row).replacingOccurrences(of: "\0", with: ""))
        }
        accessibleText = lines.joined(separator: "\n")

        var location = 0
        for row in 0..<min(flush.cursor.row, grid.rows) {
            location += (lines[row] as NSString).length + 1
        }
        if flush.cursor.row < grid.rows {
            let prefix = grid.rowCells(flush.cursor.row).prefix(max(0, flush.cursor.col))
                .map(\.text).joined()
            location += (prefix as NSString).length
        }
        accessibleSelection = NSRange(
            location: min(location, (accessibleText as NSString).length), length: 0)

        guard !accessibilityUpdateScheduled else { return }
        accessibilityUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.accessibilityUpdateScheduled = false
            NSAccessibility.post(element: self, notification: .valueChanged)
            NSAccessibility.post(element: self, notification: .selectedTextChanged)
        }
    }

    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    public override func accessibilityLabel() -> String? { "Neovim editor" }
    public override func accessibilityValue() -> Any? { accessibleText }
    public override func accessibilitySelectedTextRange() -> NSRange { accessibleSelection }
    public override func accessibilityVisibleCharacterRange() -> NSRange {
        NSRange(location: 0, length: (accessibleText as NSString).length)
    }
    public override func accessibilityNumberOfCharacters() -> Int {
        (accessibleText as NSString).length
    }

    // MARK: - Mouse (DESIGN §7.4)

    public override func mouseDown(with event: NSEvent) {
        acquireEditorFocus()
        sendMouse(event, button: .left, action: .press)
    }
    public override func mouseDragged(with event: NSEvent) { sendMouse(event, button: .left, action: .drag) }
    public override func mouseUp(with event: NSEvent) { sendMouse(event, button: .left, action: .release) }

    public override func rightMouseDown(with event: NSEvent) {
        acquireEditorFocus()
        sendMouse(event, button: .right, action: .press)
    }
    public override func rightMouseDragged(with event: NSEvent) { sendMouse(event, button: .right, action: .drag) }
    public override func rightMouseUp(with event: NSEvent) { sendMouse(event, button: .right, action: .release) }

    public override func otherMouseDown(with event: NSEvent) {
        acquireEditorFocus()
        sendMouse(event, button: .middle, action: .press)
    }
    public override func otherMouseDragged(with event: NSEvent) { sendMouse(event, button: .middle, action: .drag) }
    public override func otherMouseUp(with event: NSEvent) { sendMouse(event, button: .middle, action: .release) }

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

    public override func scrollWheel(with event: NSEvent) {
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

    private func acquireEditorFocus() {
        window?.makeFirstResponder(self)
        if hasMarkedText() { unmarkText() }
    }

    // MARK: - Menu actions

    @objc public func undo(_ sender: Any?) { controller?.performUndo() }

    @objc public func redo(_ sender: Any?) { controller?.performRedo() }

    @objc public func cut(_ sender: Any?) { controller?.copySelection(cut: true) }

    @objc public func copy(_ sender: Any?) { controller?.copySelection(cut: false) }

    @objc public func paste(_ sender: Any?) {
        controller?.pasteFromPasteboard()
    }

    public override func selectAll(_ sender: Any?) { controller?.selectAllText() }

    @objc public func performFindPanelAction(_ sender: Any?) { controller?.beginFind() }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)):
            return controller?.canUndo ?? false
        case #selector(redo(_:)):
            return controller?.canRedo ?? false
        case #selector(cut(_:)):
            return controller?.canCutSelection ?? false
        case #selector(copy(_:)):
            return controller?.canCopySelection ?? false
        case #selector(paste(_:)):
            return (controller?.editorCommandsAvailable ?? false)
                && !(NSPasteboard.general.string(forType: .string) ?? "").isEmpty
        case #selector(selectAll(_:)), #selector(performFindPanelAction(_:)):
            return controller?.editorCommandsAvailable ?? false
        default:
            return true
        }
    }
}
