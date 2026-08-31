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
    /// Horizontal-axis-only now: `WheelGesture` (below) owns the vertical
    /// axis's quantize-ahead prediction (docs/research/scroll-camera.md).
    private var scrollAccumulator = ScrollAccumulator()
    /// The trackpad/wheel gesture in progress for `scrollWheel`, keyed to the
    /// grid under the pointer when it opened.
    private var wheelGesture = WheelGesture()
    private var wheelGestureGridID: Int?
    /// The accessory (minimap/scroller) gesture in progress for
    /// `handleAccessoryWheel`. AppKit gives these views no phases, so each
    /// call reads as `.changed` of an open gesture; `accessoryWheelFinalizeTask`
    /// closes it after a quiet period instead.
    private var accessoryWheelGesture = WheelGesture()
    private var accessoryWheelGridID: Int?
    private var accessoryWheelFinalizeTask: Task<Void, Never>?
    /// How long an accessory wheel gesture may go quiet before it is treated
    /// as finished, since these views deliver no `.ended`/momentum phases.
    private static let accessoryWheelStalenessInterval: TimeInterval = 0.250

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
        commitMarkedTextLocallyAndDiscardComposition()
        return super.resignFirstResponder()
    }

    /// Grid pixels remain owned by this first-responder view. Explicit native
    /// controls in an acknowledged accessory gutter — and the surface-navbar
    /// overlay, which paints over its suppressed vim-window grid — are the
    /// sole exceptions. AppKit passes `point` in the superview's coordinate
    /// system; this view sits at a sidebar-width x offset inside the split
    /// view, so converting from the correct space is load-bearing.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard super.hitTest(point) != nil else { return nil }
        if let overlay = surfaceOverlay, !overlay.isHidden,
            let hit = overlay.hitTest(convert(point, from: superview))
        {
            return hit
        }
        let pointInSurface = surface.convert(point, from: superview)
        return surface.accessoryInteractionView(at: pointInSurface) ?? self
    }

    /// The surface-navbar overlay (docs/design/surface-navbar-v1.md §7),
    /// mounted above the grid surface; SurfaceHostRouter positions it over
    /// its vim window's grid frame each flush.
    private(set) var surfaceOverlay: NSView?

    func setSurfaceOverlay(_ view: NSView?) {
        if let surfaceOverlay, surfaceOverlay !== view {
            surfaceOverlay.removeFromSuperview()
        }
        surfaceOverlay = view
        if let view, view.superview !== self {
            view.isHidden = true  // shown once a grid frame positions it
            addSubview(view, positioned: .above, relativeTo: surface)
        }
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
        discardComposition()
        clearMarkedText()
        suppressUnmarkCommit = false
    }

    /// Ends composition because *this view* decided the session is over
    /// (focus is being acquired or given up) — distinct from the IME
    /// committing on its own, which arrives through the `unmarkText()`
    /// NSTextInputClient callback and needs no further discard, since the
    /// input method already knows its own session ended.
    ///
    /// Committing `markedText` into the buffer without telling the input
    /// context leaves the IME believing it still owns an active
    /// composition: the next keystroke it receives gets folded into that
    /// stale buffer and replayed whole via setMarkedText/insertText,
    /// duplicating the text already sent to Neovim here. Discarding through
    /// `discardComposition()` (== `inputContext?.discardMarkedText()` in
    /// production) tells the IME to drop its buffer too.
    ///
    /// `discardComposition()` can itself trigger a reentrant call back into
    /// `unmarkText()`; `suppressUnmarkCommit` keeps that reentrant call from
    /// sending a second copy of the same committed text (same pattern as
    /// `discardMarkedTextForSessionChange`).
    private func commitMarkedTextLocallyAndDiscardComposition() {
        guard hasMarkedText() else { return }
        let committed = markedText.string
        suppressUnmarkCommit = true
        discardComposition()
        clearMarkedText()
        suppressUnmarkCommit = false
        guard !committed.isEmpty else { return }
        commitComposedInput(KeyTranslator.escapeForInput(committed))
    }

    /// Test seams for the app-initiated composition-commit path above.
    /// Production leaves both at their defaults, routing through the live
    /// responder chain; tests substitute counters since neither a real
    /// `NSTextInputContext` session nor a live Neovim connection exists in a
    /// headless suite.
    lazy var discardComposition: () -> Void = { [weak self] in
        self?.inputContext?.discardMarkedText()
    }
    lazy var commitComposedInput: (String) -> Void = { [weak self] keys in
        self?.controller?.sendInput(keys)
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
        guard let cell = cellUnderPointer(event) else { return }

        if let wheelGestureGridID, wheelGestureGridID != cell.grid {
            // The pointer moved to a different grid mid-gesture: the old
            // grid's gesture gets no more samples, so close it out now
            // rather than leave its follower predicting forever.
            finalizeWheelGesture(gridID: wheelGestureGridID)
        }
        wheelGestureGridID = cell.grid

        let modifiers = Modifiers(rawValue: event.modifierFlags.rawValue)
        let isPrecise = event.hasPreciseScrollingDeltas
        let cellHeight = surface.cellSize.height
        // Down-positive, matching `WheelGesture`'s convention — the inverse
        // of AppKit's `scrollingDeltaY` (positive = up).
        let deltaRows = isPrecise
            ? (cellHeight > 0 ? -Double(event.scrollingDeltaY) / Double(cellHeight) : 0)
            : -Double(event.scrollingDeltaY)

        let verticalSteps = wheelGesture.input(
            deltaRows: deltaRows,
            phase: WheelPhase(event.phase), momentumPhase: WheelPhase(event.momentumPhase))

        let horizontalSteps = scrollAccumulator.accumulate(
            deltaX: event.scrollingDeltaX, deltaY: 0,
            cellWidth: surface.cellSize.width, cellHeight: cellHeight,
            isPrecise: isPrecise, timestamp: event.timestamp)

        emitVerticalSteps(verticalSteps, modifiers: modifiers, cell: cell)
        emitWheel(.left, count: horizontalSteps.left, modifiers: modifiers, cell: cell)
        emitWheel(.right, count: horizontalSteps.right, modifiers: modifiers, cell: cell)

        surface.noteScrollInput(
            gridID: cell.grid, inputRows: wheelGesture.inputRows,
            requestedRows: wheelGesture.requestedRows, gestureOpen: wheelGesture.isOpen)
        if !wheelGesture.isOpen { wheelGestureGridID = nil }
    }

    private func finalizeWheelGesture(gridID: Int) {
        guard wheelGesture.isOpen else { return }
        // Finalize may return a nearest-row step-back (`WheelGesture.input`),
        // not just `0` — send it like any other step, or nvim's viewport
        // never receives the un-scroll and the camera glides to a target the
        // grid never confirmed.
        let steps = wheelGesture.input(deltaRows: 0, phase: .ended, momentumPhase: .none)
        emitVerticalSteps(
            steps, modifiers: Modifiers(rawValue: 0),
            cell: (grid: gridID, row: 0, col: 0))
        surface.noteScrollInput(
            gridID: gridID, inputRows: wheelGesture.inputRows,
            requestedRows: wheelGesture.requestedRows, gestureOpen: wheelGesture.isOpen)
    }

    /// Native minimap/scroller views forward wheel deltas here so there is
    /// still exactly one accumulator/gesture and one ordered Neovim mouse
    /// route. These views deliver no AppKit gesture phases, so every call
    /// reads as `.changed` of an open gesture; `accessoryWheelFinalizeTask`
    /// closes the gesture after a quiet period in place of a real `.ended`.
    private func handleAccessoryWheel(_ request: GridAccessoryWheelRequest) {
        guard let controller, controller.isMouseEnabled else { return }

        if let accessoryWheelGridID, accessoryWheelGridID != request.gridID {
            finalizeAccessoryWheelGesture(gridID: accessoryWheelGridID)
        }
        accessoryWheelGridID = request.gridID

        let isPrecise = request.hasPreciseDeltas
        let cellHeight = surface.cellSize.height
        let deltaRows = isPrecise
            ? (cellHeight > 0 ? -Double(request.deltaY) / Double(cellHeight) : 0)
            : -Double(request.deltaY)

        let verticalSteps = accessoryWheelGesture.input(
            deltaRows: deltaRows, phase: .changed, momentumPhase: .none)

        let horizontalSteps = scrollAccumulator.accumulate(
            deltaX: request.deltaX, deltaY: 0,
            cellWidth: surface.cellSize.width, cellHeight: cellHeight,
            isPrecise: isPrecise)

        let modifiers = Modifiers(rawValue: request.modifierFlagsRawValue)
        let cell = (grid: request.gridID, row: 0, col: 0)
        emitVerticalSteps(verticalSteps, modifiers: modifiers, cell: cell)
        emitWheel(.left, count: horizontalSteps.left, modifiers: modifiers, cell: cell)
        emitWheel(.right, count: horizontalSteps.right, modifiers: modifiers, cell: cell)

        surface.noteScrollInput(
            gridID: request.gridID, inputRows: accessoryWheelGesture.inputRows,
            requestedRows: accessoryWheelGesture.requestedRows,
            gestureOpen: accessoryWheelGesture.isOpen)
        scheduleAccessoryWheelFinalize(gridID: request.gridID)
    }

    private func scheduleAccessoryWheelFinalize(gridID: Int) {
        accessoryWheelFinalizeTask?.cancel()
        let nanoseconds = UInt64(Self.accessoryWheelStalenessInterval * 1_000_000_000)
        accessoryWheelFinalizeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            self?.finalizeAccessoryWheelGesture(gridID: gridID)
        }
    }

    private func finalizeAccessoryWheelGesture(gridID: Int) {
        accessoryWheelFinalizeTask?.cancel()
        accessoryWheelFinalizeTask = nil
        guard accessoryWheelGesture.isOpen else { return }
        // See `finalizeWheelGesture`: finalize may return a nearest-row
        // step-back that must still be sent to Neovim.
        let steps = accessoryWheelGesture.input(deltaRows: 0, phase: .ended, momentumPhase: .none)
        emitVerticalSteps(
            steps, modifiers: Modifiers(rawValue: 0),
            cell: (grid: gridID, row: 0, col: 0))
        surface.noteScrollInput(
            gridID: gridID, inputRows: accessoryWheelGesture.inputRows,
            requestedRows: accessoryWheelGesture.requestedRows,
            gestureOpen: accessoryWheelGesture.isOpen)
        if accessoryWheelGridID == gridID { accessoryWheelGridID = nil }
    }

    private func emitVerticalSteps(
        _ steps: Int, modifiers: Modifiers, cell: (grid: Int, row: Int, col: Int)
    ) {
        if steps > 0 {
            emitWheel(.down, count: steps, modifiers: modifiers, cell: cell)
        } else if steps < 0 {
            emitWheel(.up, count: -steps, modifiers: modifiers, cell: cell)
        }
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
        commitMarkedTextLocallyAndDiscardComposition()
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
