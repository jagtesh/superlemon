import AppKit
import GridKit
import QuartzCore
import os.signpost

private final class WorkspaceNotificationToken: @unchecked Sendable {
    let center: NotificationCenter
    let value: NSObjectProtocol
    init(center: NotificationCenter, value: NSObjectProtocol) {
        self.center = center
        self.value = value
    }
    deinit { center.removeObserver(value) }
}

private struct ScrollDiagnosticRing {
    private let capacity: Int
    private var storage: [ScrollDiagnosticSample] = []
    private var nextIndex = 0

    init(capacity: Int) { self.capacity = max(1, capacity) }

    mutating func append(_ sample: ScrollDiagnosticSample) {
        if storage.count < capacity {
            storage.append(sample)
        } else {
            storage[nextIndex] = sample
            nextIndex = (nextIndex + 1) % capacity
        }
    }

    var ordered: [ScrollDiagnosticSample] {
        guard storage.count == capacity, nextIndex != 0 else { return storage }
        return Array(storage[nextIndex...]) + Array(storage[..<nextIndex])
    }

    mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        nextIndex = 0
    }
}

/// Preserve export order without putting file I/O on the main actor. Every
/// submission originates on the main actor, and the serial queue guarantees
/// that a newer settled gesture is always the final payload on disk.
private final class ScrollDiagnosticExporter: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.superlemon.editor.scroll-diagnostics", qos: .utility)

    func submit(_ payload: Data, to url: URL) {
        queue.async {
            try? payload.write(to: url, options: .atomic)
        }
    }
}

/// Font + spacing configuration for the surface. `name == nil` means the
/// system monospaced font. Mirrors nvim's `guifont`/`linespace` (DESIGN §4).
public struct FontSpec: Sendable, Equatable {
    public var name: String?
    public var size: CGFloat
    public var linespace: CGFloat
    /// Synthesize Powerline separators/branch (U+E0A0, U+E0B0–B3) as vector
    /// shapes — works with ANY font, no patched font required.
    public var powerlineGlyphs: Bool
    /// Shape with the font's standard ligatures (=> ≠ etc. in fonts that
    /// have them); off forces per-character glyphs.
    public var ligatures: Bool
    /// Route symbols/ligatures through the bundled companion font
    /// (FiraCode Nerd Font Mono) — real calt ligatures + full Nerd glyph
    /// coverage with any text font. Off by default.
    public var useSymbolFont: Bool
    /// Force Superlemon's built-in fallback rendering (vector powerline
    /// shapes + Unicode ligature substitution) regardless of font support.
    public var forceSynthesis: Bool

    public init(
        name: String? = nil, size: CGFloat = 13, linespace: CGFloat = 0,
        powerlineGlyphs: Bool = false, ligatures: Bool = true,
        useSymbolFont: Bool = false, forceSynthesis: Bool = false
    ) {
        self.name = name
        self.size = size
        self.linespace = linespace
        self.powerlineGlyphs = powerlineGlyphs
        self.ligatures = ligatures
        self.useSymbolFont = useSymbolFont
        self.forceSynthesis = forceSynthesis
    }
}

/// The bridge component (DESIGN §5-6): a layer-hosting NSView that renders
/// GridKit flush snapshots via Core Text into per-grid CALayers.
///
/// Coordinates: the view is flipped — (row 0, col 0) is the top-left cell,
/// matching grid coordinates. All public geometry is in view coordinates.
///
/// PUBLIC API IS THE CONTRACT with SuperlemonApp — keep it source-compatible.
@MainActor
public final class GridSurfaceView: NSView {
    /// Pixel size of one grid cell for the current font. Changes only via
    /// `setFont`; the app derives resize geometry from it.
    public private(set) var cellSize: CGSize = .zero

    public private(set) var fontSpec: FontSpec

    /// Visual reconciliation policy for Neovim's discrete grid_scroll frames.
    public var scrollMotionStyle: ScrollMotionStyle = .tightNative {
        didSet {
            guard scrollMotionStyle != oldValue else { return }
            if scrollMotionStyle == .immediate { settleSmoothMotion() }
        }
    }

    /// Sublime-style native miniature for each sufficiently large normal
    /// window grid. The app still owns the Neovim resize request; SurfaceKit
    /// waits for the matching grid_resize before exposing the gutter.
    public var showsMinimap: Bool = true {
        didSet {
            guard showsMinimap != oldValue else { return }
            refreshEditorAccessories()
        }
    }

    /// Small native overlay scrollers are opt-in. When a minimap is present
    /// they occupy its trailing 12 points; otherwise they overlay the grid's
    /// trailing edge without reserving a text column.
    public var showsNativeScrollbars: Bool = false {
        didSet {
            guard showsNativeScrollbars != oldValue else { return }
            refreshEditorAccessories()
        }
    }

    /// Desired trailing minimap gutter in points. SurfaceKit clamps the
    /// effective value to the runtime-supported 48...160 point range.
    public var minimapWidth: CGFloat = 88 {
        didSet {
            guard minimapWidth != oldValue else { return }
            refreshEditorAccessories()
        }
    }

    /// CoreText glyph scale relative to the active editor font size. It never
    /// scales the already-rasterized editor viewport.
    public var minimapScale: CGFloat = 0.20 {
        didSet {
            guard minimapScale != oldValue else { return }
            refreshEditorAccessories()
        }
    }

    /// Vertical minimap row pitch in points, snapped to physical pixels.
    public var minimapPitch: CGFloat = 3.0 {
        didSet {
            guard minimapPitch != oldValue else { return }
            refreshEditorAccessories()
        }
    }

    /// Minimum text columns required before reserving the minimap gutter.
    /// Hiding uses a four-column hysteresis band.
    public var minimapMinEditorColumns: Int = 40 {
        didSet {
            guard minimapMinEditorColumns != oldValue else { return }
            refreshEditorAccessories()
        }
    }

    public init(frame frameRect: NSRect, font: FontSpec) {
        self.fontSpec = font
        self.fonts = FontSet(spec: font)
        self.rasterizer = TextRasterizer(fonts: fonts)
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.addSublayer(cursorLayer)
        cellSize = fonts.cellSize
        reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        accessibilityObserver = WorkspaceNotificationToken(
            center: workspaceNotifications,
            value: workspaceNotifications.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.reducedMotion =
                        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                    if self.reducedMotion { self.settleSmoothMotion() }
                }
            })
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("not supported") }

    public override var isFlipped: Bool { true }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureDisplayLink()
    }

    /// Grid dimensions that fit the current bounds — feed to nvim_ui_try_resize.
    public var gridSize: (rows: Int, cols: Int) {
        guard cellSize.width > 0, cellSize.height > 0 else { return (0, 0) }
        return (
            rows: max(1, Int(bounds.height / cellSize.height)),
            cols: max(1, Int(bounds.width / cellSize.width))
        )
    }

    /// Present one atomic frame: rotate/repaint row tiles, update layers and
    /// cursor, and commit them in one disabled-actions CATransaction.
    public func present(_ flush: FlushResult) {
        // A direct/immediate present supersedes an older display-linked drain.
        scheduledDisplayPresentation = nil
        lastFlush = flush
        commit(flush, redrawAll: false)
    }

    /// Change font/linespace (guifont path). Recomputes metrics and fully
    /// re-renders; the app follows up with nvim_ui_try_resize.
    public func setFont(_ spec: FontSpec) {
        fontSpec = spec
        fonts = FontSet(spec: spec)
        rasterizer = TextRasterizer(fonts: fonts)
        cellSize = fonts.cellSize
        renderers.removeAll()
        settleSmoothMotion(destroyHistory: true)
        if let flush = lastFlush { commit(flush, redrawAll: true) }
    }

    /// Hit-test a view point to a (grid, row, col) cell for nvim_input_mouse.
    /// Multigrid frames resolve topmost-first; the outer grid is the fallback.
    public func cell(at point: NSPoint) -> (grid: Int, row: Int, col: Int)? {
        guard cellSize.width > 0, cellSize.height > 0, bounds.contains(point) else { return nil }
        let row = Int(point.y / cellSize.height)
        let col = Int(point.x / cellSize.width)
        for frame in lastFrames.reversed() {
            let r = frame.rect
            if row >= r.row, row < r.row + r.height, col >= r.col, col < r.col + r.width {
                let localRow = row - r.row
                let localCol = col - r.col
                if let grid = lastFlush?.grids[frame.gridID],
                    (localRow >= grid.rows || localCol >= grid.cols)
                {
                    // A UI-owned trailing gutter is never a Neovim cell.
                    return nil
                }
                return (grid: frame.gridID, row: localRow, col: localCol)
            }
        }
        return (grid: 1, row: row, col: col)
    }

    /// A grid's frame in view coordinates (top-left origin; the view is
    /// flipped). Nil for unknown/hidden grids. Used by the app to anchor
    /// chrome (popupmenu) at grid cells.
    public func rect(ofGrid id: Int) -> NSRect? {
        guard let frame = lastFrames.first(where: { $0.gridID == id }) else { return nil }
        return NSRect(
            x: CGFloat(frame.rect.col) * cellSize.width,
            y: CGFloat(frame.rect.row) * cellSize.height,
            width: CGFloat(frame.rect.width) * cellSize.width,
            height: CGFloat(frame.rect.height) * cellSize.height)
    }

    /// Convert a view point to a SPECIFIC grid's local cell, clamped to its
    /// bounds — mouse drags must stay on the press grid (`:h ui-multigrid`),
    /// even when the pointer wanders past its edges.
    public func cell(at point: NSPoint, inGrid id: Int) -> (row: Int, col: Int)? {
        guard cellSize.width > 0, cellSize.height > 0 else { return nil }
        guard let frame = lastFrames.first(where: { $0.gridID == id }) else { return nil }
        let localRow = Int(floor(point.y / cellSize.height)) - frame.rect.row
        let localCol = Int(floor(point.x / cellSize.width)) - frame.rect.col
        let gridRows = lastFlush?.grids[id]?.rows ?? frame.rect.height
        let gridCols = lastFlush?.grids[id]?.cols ?? frame.rect.width
        guard gridRows > 0, gridCols > 0 else { return nil }
        return (
            row: max(0, min(gridRows - 1, localRow)),
            col: max(0, min(gridCols - 1, localCol))
        )
    }

    /// Cursor cell rect in view coordinates — the IME candidate-window anchor
    /// (NSTextInputClient firstRect). Nil while no flush has been presented.
    public var cursorRect: NSRect? {
        guard let flush = lastFlush, cellSize != .zero else { return nil }
        let origin = cursorOrigin(flush)
        return NSRect(origin: origin, size: cellSize)
    }

    // MARK: - Package editor-accessory bridge

    package var onMinimapContentRangeRequest:
        ((MinimapContentRangeRequest) -> Void)?
    {
        get { accessoryCoordinator.onContentRangeRequest }
        set { accessoryCoordinator.onContentRangeRequest = newValue }
    }

    package var onGridAccessorySizeRequest:
        ((GridAccessorySizeRequest) -> Void)?
    {
        get { accessoryCoordinator.onGridSizeRequest }
        set { accessoryCoordinator.onGridSizeRequest = newValue }
    }

    package var onGridAccessoryViewportTargetRequest:
        ((GridAccessoryViewportTargetRequest) -> Void)?
    {
        get { accessoryCoordinator.onViewportTargetRequest }
        set { accessoryCoordinator.onViewportTargetRequest = newValue }
    }

    package var onGridAccessoryWheelRequest:
        ((GridAccessoryWheelRequest) -> Void)?
    {
        get { accessoryCoordinator.onWheelRequest }
        set { accessoryCoordinator.onWheelRequest = newValue }
    }

    package func setMinimapTopologies(_ topologies: [MinimapBufferTopology]) {
        accessoryCoordinator.setTopologies(topologies)
        refreshEditorAccessories()
    }

    package func updateMinimapTopology(_ topology: MinimapBufferTopology) {
        accessoryCoordinator.updateTopology(topology)
        refreshEditorAccessories()
    }

    package func removeMinimapTopology(windowHandle: Int) {
        accessoryCoordinator.removeTopology(windowHandle: windowHandle)
        refreshEditorAccessories()
    }

    package func provideMinimapContent(_ chunk: MinimapContentChunk) {
        accessoryCoordinator.provide(chunk)
    }

    /// InputHostView asks this before converting an event into a Neovim cell.
    /// It returns only explicit, topmost-safe accessory controls.
    package func accessoryInteractionView(at point: NSPoint) -> NSView? {
        accessoryCoordinator.interactionView(at: point)
    }

    package func editorAccessoryDebugSnapshot(
        gridID: Int
    ) -> GridAccessoryDebugSnapshot? {
        accessoryCoordinator.debugSnapshot(gridID: gridID)
    }

    package func editorAccessoryScroller(gridID: Int) -> NSScroller? {
        accessoryCoordinator.scroller(gridID: gridID)
    }

    /// Deterministic layer-tree capture used by accessory integration tests.
    package func editorAccessoryPresentedImage(gridID: Int) -> CGImage? {
        accessoryCoordinator.presentedMinimapImage(gridID: gridID)
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let newScale = window?.backingScaleFactor ?? 2
        guard newScale != scale else { return }
        settleSmoothMotion(destroyHistory: true)
        scale = newScale
        for renderer in renderers.values { renderer.setScale(newScale, rerender: false) }
        if let flush = lastFlush { commit(flush, redrawAll: true) }
    }

    // MARK: - internals

    private var fonts: FontSet
    private var rasterizer: TextRasterizer
    private var renderers: [Int: GridRenderer] = [:]
    private var gridLayers: [Int: CALayer] = [:]
    private var smoothViewports: [Int: SmoothViewportState] = [:]
    private lazy var accessoryCoordinator = GridAccessoryCoordinator(hostView: self)
    private let cursorLayer = CursorLayer()
    private var lastFlush: FlushResult?
    private var lastFrames: [ResolvedGridFrame] = []
    private var scale: CGFloat = 2
    private var reducedMotion = false
    private var accessibilityObserver: WorkspaceNotificationToken?
    private var animationDisplayLink: CADisplayLink?
    /// Simulation time of the frame currently being targeted. CADisplayLink
    /// callbacks arrive before that frame; integrating only to `timestamp`
    /// leaves motion one refresh behind what the transaction will display.
    private var lastDisplayTargetTimestamp: CFTimeInterval?
    /// Lets the first callback distinguish its normal target-frame horizon
    /// from a real main-thread stall that began immediately after resume.
    private var displayLinkResumeTimestamp: CFTimeInterval?
    private var scheduledDisplayPresentation: (@MainActor () -> Void)?
    private var isInsideDisplayTick = false

    private var authoritativeCursorY: CGFloat?
    private var authoritativeCursorRow: Int?
    private var authoritativeCursorGrid: Int?
    private var visualCursorY: CGFloat?
    private var cursorCorrection = CriticalDampedSpring(animationLength: 0.040)
    private var cursorCorrectionActive = false

    /// Internal hook used by deterministic tests and opt-in field diagnostics.
    package var scrollDiagnosticHandler: ((ScrollDiagnosticSample) -> Void)?
    private let diagnosticExportURL = ProcessInfo.processInfo.environment[
        "SUPERLEMON_SCROLL_TRACE_FILE"
    ].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
    private let environmentDiagnosticsEnabled =
        ProcessInfo.processInfo.environment["SUPERLEMON_SCROLL_TRACE"] == "1"
        || ProcessInfo.processInfo.environment["SUPERLEMON_SCROLL_TRACE_FILE"] != nil
    private var diagnosticRing = ScrollDiagnosticRing(capacity: 2_048)
    private let diagnosticExporter = ScrollDiagnosticExporter()
    private static let scrollSignpostLog = OSLog(
        subsystem: "com.superlemon.editor",
        category: OSLog.Category.pointsOfInterest.rawValue)

    /// Queue one accumulated model presentation for the next shared display
    /// callback. Returning false preserves immediate first-scroll response and
    /// lets the caller drain synchronously. Replacing an action is intentional:
    /// GridStore keeps accumulating authoritative state until it is consumed.
    package func schedulePresentationOnNextDisplay(
        _ action: @escaping @MainActor () -> Void
    ) -> Bool {
        guard scrollMotionStyle == .tightNative, !reducedMotion,
            animationDisplayLink != nil,
            smoothViewports.values.contains(where: \.isActive)
        else { return false }
        scheduledDisplayPresentation = action
        resumeDisplayLink()
        return true
    }

    /// Bounded, allocation-stable diagnostic history. Unlike the former
    /// stderr trace this performs no synchronous I/O during a gesture.
    package var recordedScrollDiagnostics: [ScrollDiagnosticSample] {
        diagnosticRing.ordered
    }

    package func resetScrollDiagnostics() {
        diagnosticRing.removeAll()
    }

    private func commit(_ flush: FlushResult, redrawAll: Bool) {
        let previousFrames = Dictionary(
            uniqueKeysWithValues: lastFrames.map { ($0.gridID, $0) })
        let outer = flush.grids[1]
        let frames = GridLayout.resolve(
            outerRows: outer?.rows ?? 0, outerCols: outer?.cols ?? 0,
            grids: flush.grids)
        lastFrames = frames

        let ownsTransaction = !isInsideDisplayTick
        if ownsTransaction {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
        }
        defer { if ownsTransaction { CATransaction.commit() } }

        layer?.backgroundColor = flush.highlights.defaultBackground.cgColor

        // 1. Update row backing stores. Compatible vertical motion rotates
        // immutable row revisions and rasterizes only exposed/damaged rows.
        var updatedContents: Set<Int> = []
        if redrawAll {
            for (id, grid) in flush.grids {
                renderer(for: id).renderFull(grid: grid, highlights: flush.highlights)
                updatedContents.insert(id)
            }
        } else {
            for damaged in flush.damagedGrids {
                renderer(for: damaged.grid.id).apply(
                    grid: damaged.grid, damage: damaged.damage,
                    highlights: flush.highlights)
                updatedContents.insert(damaged.grid.id)
            }
        }

        // 2. Sync the layer tree to the resolved frames (back-to-front order).
        let cw = cellSize.width
        let ch = cellSize.height
        var visible: Set<Int> = []
        let damageByGrid = Dictionary(
            uniqueKeysWithValues: flush.damagedGrids.map { ($0.grid.id, $0.damage) })
        var motionStarted = false
        var atomicallySettledGrids: Set<Int> = []
        for frame in frames {
            guard let grid = flush.grids[frame.gridID] else { continue }
            visible.insert(frame.gridID)
            let gridLayer = layerFor(frame.gridID, flush: flush, updated: &updatedContents)
            if !redrawAll, !flush.allowsScrollInterpolation,
                previousFrames[frame.gridID] != frame,
                let state = smoothViewports[frame.gridID]
            {
                // Layout changes affect this grid's pixels even when Neovim
                // sends no grid damage. Settle only that filmstrip; unrelated
                // splits and metadata-only cursor/style frames keep moving.
                state.settle()
                atomicallySettledGrids.insert(frame.gridID)
            }
            gridLayer.frame = CGRect(
                x: CGFloat(frame.rect.col) * cw,
                y: CGFloat(frame.rect.row) * ch,
                width: CGFloat(frame.rect.width) * cw,
                height: CGFloat(frame.rect.height) * ch)
            gridLayer.zPosition = CGFloat(frame.zIndex)
            gridLayer.backgroundColor = flush.highlights.defaultBackground.cgColor
            let viewportMotion = flush.viewportScrollMotions[frame.gridID]
            let targetGeometry = SmoothViewportGeometry(
                rows: grid.rows, cols: grid.cols, margins: grid.viewportMargins)
            let geometryChanged = smoothViewports[frame.gridID].map {
                $0.geometry != targetGeometry
            } ?? false
            if updatedContents.contains(frame.gridID) || viewportMotion != nil
                || geometryChanged,
                let rowSnapshots = renderers[frame.gridID]?.rowSnapshots()
            {
                // The normal compositor never uploads a full-grid image.
                gridLayer.contents = nil
                let state = smoothViewports[frame.gridID]
                    ?? SmoothViewportState(gridID: frame.gridID)
                smoothViewports[frame.gridID] = state
                let animate = scrollMotionStyle == .tightNative && !reducedMotion
                    && !redrawAll && flush.allowsScrollInterpolation
                if !animate { atomicallySettledGrids.insert(frame.gridID) }
                let started = state.present(
                    rowSnapshots: rowSnapshots, rows: grid.rows, cols: grid.cols,
                    margins: grid.viewportMargins,
                    scrolls: damageByGrid[frame.gridID]?.presentationScrolls ?? [],
                    semanticDelta: redrawAll ? nil : flush.viewportScrollDeltas[frame.gridID],
                    semanticMotion: redrawAll ? nil : viewportMotion,
                    cellSize: cellSize, scale: scale, host: gridLayer,
                    animate: animate)
                motionStarted = motionStarted || started
                assert(state.currentRowsMatch(rowSnapshots),
                       "filmstrip must end on authoritative row revisions")
            }
        }

        // 3. Drop layers/renderers for grids that no longer exist; hidden
        //    grids keep their renderer but lose their layer.
        for (id, gridLayer) in gridLayers where !visible.contains(id) {
            smoothViewports[id]?.destroy()
            smoothViewports.removeValue(forKey: id)
            gridLayer.removeFromSuperlayer()
            gridLayers.removeValue(forKey: id)
        }
        for id in renderers.keys where flush.grids[id] == nil {
            renderers.removeValue(forKey: id)
            smoothViewports[id]?.destroy()
            smoothViewports.removeValue(forKey: id)
        }

        syncEditorAccessories(flush: flush, frames: frames)

        // 4. Cursor.
        if atomicallySettledGrids.contains(flush.cursor.grid)
            || authoritativeCursorGrid.map(atomicallySettledGrids.contains) == true
        {
            cursorCorrection.settle()
            cursorCorrectionActive = false
        }
        let previousVisualY = visualCursorY
        let previousAuthoritativeRow = authoritativeCursorRow
        let previousCursorGrid = authoritativeCursorGrid
        let newCursorOrigin = cursorOrigin(flush)
        cursorLayer.update(
            flush: flush, cellOrigin: newCursorOrigin,
            fonts: fonts, cache: rasterizer.cache, scale: scale)
        let newAuthoritativeY = cursorLayer.frame.minY
        let cursorState = smoothViewports[flush.cursor.grid]
        let coupledY = newAuthoritativeY - (cursorState?.snappedTranslationY ?? 0)
        let cursorGridChanged = previousCursorGrid != flush.cursor.grid
        let authoritativeChanged = previousAuthoritativeRow != flush.cursor.row
        if cursorGridChanged {
            // A correction is expressed in the coordinate/history space of
            // one grid.  Never carry it into another split that happens to be
            // scrolling at the same time.
            cursorCorrection.settle()
            cursorCorrectionActive = false
        } else if cursorState?.isActive == true, authoritativeChanged,
            let previousVisualY {
            cursorCorrection.position = previousVisualY - coupledY
            cursorCorrection.velocity = 0
            cursorCorrectionActive = !cursorCorrection.isSettled
        } else if cursorState?.isActive != true, authoritativeChanged {
            cursorCorrection.settle()
            cursorCorrectionActive = false
        }
        authoritativeCursorY = newAuthoritativeY
        authoritativeCursorRow = flush.cursor.row
        authoritativeCursorGrid = flush.cursor.grid
        updateCursorPresentation()

        if motionStarted || cursorCorrectionActive
            || accessoryCoordinator.hasActiveMotion
        {
            resumeDisplayLink()
        }
    }

    private func settleSmoothMotion(destroyHistory: Bool = false) {
        // A style/accessibility switch must not strand authoritative model
        // damage that was already scheduled for the next display callback.
        if let scheduledDisplayPresentation {
            self.scheduledDisplayPresentation = nil
            scheduledDisplayPresentation()
        }
        for state in smoothViewports.values {
            destroyHistory ? state.destroy() : state.settle()
        }
        if destroyHistory { smoothViewports.removeAll() }
        cursorCorrection.settle()
        cursorCorrectionActive = false
        updateCursorPresentation()
        accessoryCoordinator.settleMotion()
        pauseDisplayLink()
    }

    private func configureDisplayLink() {
        animationDisplayLink?.invalidate()
        animationDisplayLink = nil
        lastDisplayTargetTimestamp = nil
        displayLinkResumeTimestamp = nil
        guard window != nil else { return }
        let link = displayLink(
            target: self, selector: #selector(displayLinkDidFire(_:)))
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        animationDisplayLink = link
        if smoothViewports.values.contains(where: \.isActive)
            || cursorCorrectionActive || accessoryCoordinator.hasActiveMotion
            || scheduledDisplayPresentation != nil
        {
            resumeDisplayLink()
        }
    }

    @objc private func displayLinkDidFire(_ link: CADisplayLink) {
        let nominalDisplayPeriod = Self.nominalDisplayPeriod(
            timestamp: link.timestamp,
            targetTimestamp: link.targetTimestamp,
            duration: link.duration)
        let targetTimestamp = Self.displayTargetTimestamp(
            timestamp: link.timestamp,
            targetTimestamp: link.targetTimestamp,
            duration: link.duration)
        let elapsed: CFTimeInterval
        if let lastDisplayTargetTimestamp {
            let targetDelta = targetTimestamp - lastDisplayTargetTimestamp
            elapsed = targetDelta > 0 ? targetDelta : nominalDisplayPeriod
        } else {
            elapsed = nominalDisplayPeriod
        }
        lastDisplayTargetTimestamp = targetTimestamp
        let detectDisplayGap = Self.shouldDetectDisplayGap(
            resumedAt: displayLinkResumeTimestamp,
            callbackTimestamp: link.timestamp,
            nominalDisplayPeriod: nominalDisplayPeriod)
        displayLinkResumeTimestamp = nil

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        isInsideDisplayTick = true
        let active = runDisplayTickWithoutTransaction(
            by: elapsed, nominalDisplayPeriod: nominalDisplayPeriod,
            timestamp: targetTimestamp, detectDisplayGap: detectDisplayGap)
        isInsideDisplayTick = false
        CATransaction.commit()

        if !active, scheduledDisplayPresentation == nil {
            pauseDisplayLink()
        }
    }

    /// Deterministic animation entry point used by both CADisplayLink and
    /// refresh-rate equivalence tests.
    @discardableResult
    func advanceAnimations(
        by elapsed: CFTimeInterval,
        nominalDisplayPeriod: CFTimeInterval = 1.0 / 60.0,
        timestamp: CFTimeInterval = CACurrentMediaTime(),
        detectDisplayGap: Bool = true
    ) -> Bool {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        isInsideDisplayTick = true
        let active = runDisplayTickWithoutTransaction(
            by: elapsed, nominalDisplayPeriod: nominalDisplayPeriod,
            timestamp: timestamp, detectDisplayGap: detectDisplayGap)
        isInsideDisplayTick = false
        CATransaction.commit()
        return active
    }

    /// Advance motion that existed during the elapsed interval before applying
    /// a scroll batch that arrived during that interval. Retargeting first
    /// would pre-age the new delta by up to one frame and create a phase-
    /// dependent pixel kick. Both operations still commit atomically.
    private func runDisplayTickWithoutTransaction(
        by elapsed: CFTimeInterval, nominalDisplayPeriod: CFTimeInterval,
        timestamp: CFTimeInterval, detectDisplayGap: Bool
    ) -> Bool {
        let pendingPresentation = scheduledDisplayPresentation
        scheduledDisplayPresentation = nil
        let wasActive = advanceAnimationsWithoutTransaction(
            by: elapsed, nominalDisplayPeriod: nominalDisplayPeriod,
            detectDisplayGap: detectDisplayGap)
        pendingPresentation?()
        // A pending presentation may extend the envelope and retarget the cursor. Sample
        // once, after that final state exists, using the timestamp of the
        // frame this transaction is preparing.
        emitDiagnostics(timestamp: timestamp)
        return wasActive || hasActiveAnimationWork
    }

    private func advanceAnimationsWithoutTransaction(
        by elapsed: CFTimeInterval, nominalDisplayPeriod: CFTimeInterval,
        detectDisplayGap: Bool
    ) -> Bool {
        let boundedElapsed = min(max(0, elapsed), 1.0)
        var active = false
        for state in smoothViewports.values where state.isActive {
            active = state.advance(
                by: boundedElapsed,
                nominalDisplayPeriod: nominalDisplayPeriod > 0
                    ? nominalDisplayPeriod : 1.0 / 60.0,
                detectDisplayGap: detectDisplayGap) || active
        }

        if cursorCorrectionActive {
            var remaining = boundedElapsed
            while remaining > 0 {
                let step = min(remaining, 1.0 / 120.0)
                cursorCorrection.advance(by: step)
                remaining -= step
            }
            if cursorCorrection.isSettled {
                cursorCorrection.settle()
                cursorCorrectionActive = false
            } else {
                active = true
            }
        }
        active = accessoryCoordinator.advanceMotion(by: boundedElapsed) || active
        updateCursorPresentation()
        return active
            || smoothViewports.values.contains(where: \.isActive)
            || scheduledDisplayPresentation != nil
    }

    var animationsAreIdle: Bool {
        !hasActiveAnimationWork
            && (animationDisplayLink?.isPaused ?? true)
    }

    private var hasActiveAnimationWork: Bool {
        smoothViewports.values.contains(where: \.isActive)
            || cursorCorrectionActive || accessoryCoordinator.hasActiveMotion
            || scheduledDisplayPresentation != nil
    }

    /// Deterministic test hook that avoids annotating hot-path CALayers with
    /// names/KVC metadata solely to identify their authoritative source row.
    func visibleRowLayer(gridID: Int, sourceRow: Int) -> CALayer? {
        smoothViewports[gridID]?.visibleLayer(sourceRow: sourceRow)
    }

    /// Deterministic camera-state hook for cadence and retargeting tests.
    package func scrollTranslationPixels(gridID: Int) -> Int? {
        smoothViewports[gridID]?.snappedTranslationPixels
    }

    /// Analytical position before Retina pixel snapping. A C2 motion envelope
    /// can advance during its first display period without crossing a physical
    /// pixel, so cadence tests must not infer retarget ordering from layers.
    package func scrollPosition(gridID: Int) -> CGFloat? {
        smoothViewports[gridID]?.position
    }

    private func resumeDisplayLink() {
        guard let animationDisplayLink else { return }
        // Preserve the last sampled time while already running. A redraw can
        // arrive between two display callbacks after a main-thread stall; if
        // it reset the timestamp here, the next callback would integrate only
        // one nominal frame and silently discard the delayed interval.
        if animationDisplayLink.isPaused {
            // Seed with real time; the callback advances to targetTimestamp,
            // so a step committed just before vsync still moves on the frame
            // that the callback is preparing.
            let now = CACurrentMediaTime()
            lastDisplayTargetTimestamp = now
            displayLinkResumeTimestamp = now
            animationDisplayLink.isPaused = false
        }
    }

    private func pauseDisplayLink() {
        animationDisplayLink?.isPaused = true
        lastDisplayTargetTimestamp = nil
        displayLinkResumeTimestamp = nil
        exportScrollDiagnosticsIfRequested()
    }

    /// Export only after motion settles so diagnostics never add file I/O to
    /// the input, raster, or display-commit path. Exports are serialized so a
    /// later gesture's bounded snapshot always remains the final file content.
    private func exportScrollDiagnosticsIfRequested() {
        guard let diagnosticExportURL else { return }
        let samples = diagnosticRing.ordered
        guard !samples.isEmpty else { return }
        let lines = samples.map { sample in
            let authoritative = sample.cursorAuthoritativeY.map { "\($0)" } ?? "null"
            let visual = sample.cursorVisualY.map { "\($0)" } ?? "null"
            return "{\"timestamp\":\(sample.timestamp),\"grid\":\(sample.gridID),"
                + "\"delta\":\(sample.delta),\"historyHead\":\(sample.historyHead),"
                + "\"position\":\(sample.position),\"velocity\":\(sample.velocity),"
                + "\"acceleration\":\(sample.acceleration),"
                + "\"snappedTranslationPixels\":\(sample.snappedTranslationPixels),"
                + "\"cursorAuthoritativeY\":\(authoritative),"
                + "\"cursorVisualY\":\(visual)}"
        }
        guard let payload = (lines.joined(separator: "\n") + "\n").data(using: .utf8)
        else { return }
        diagnosticExporter.submit(payload, to: diagnosticExportURL)
    }

    private func updateCursorPresentation() {
        guard let flush = lastFlush, let authoritativeCursorY,
            let authoritativeCursorGrid
        else {
            return
        }
        let state = smoothViewports[authoritativeCursorGrid]
        var y = authoritativeCursorY
            - (state?.snappedTranslationY ?? 0)
            + cursorCorrection.position

        if let frame = lastFrames.first(where: { $0.gridID == authoritativeCursorGrid }),
            let grid = flush.grids[authoritativeCursorGrid]
        {
            let geometry = SmoothViewportGeometry(
                rows: grid.rows, cols: grid.cols, margins: grid.viewportMargins)
            if geometry.innerRows > 0 {
                let cellY = CGFloat(frame.rect.row + flush.cursor.row) * cellSize.height
                let shapeOffset = authoritativeCursorY - cellY
                let minimum = CGFloat(frame.rect.row + geometry.top) * cellSize.height
                    + shapeOffset
                let maximum = CGFloat(
                    frame.rect.row + geometry.rows - geometry.bottom - 1)
                    * cellSize.height + shapeOffset
                let bottomRow = geometry.rows - geometry.bottom - 1
                if flush.cursor.row <= geometry.top {
                    // Once Neovim pins the authoritative cursor to an edge,
                    // repeated viewport deltas must not pull it back into the
                    // window on every flush (the field-reported sawtooth).
                    y = minimum
                } else if flush.cursor.row >= bottomRow {
                    y = maximum
                } else {
                    y = min(maximum, max(minimum, y))
                }
            }
        }
        y = (y * max(1, scale)).rounded() / max(1, scale)
        cursorLayer.setVisualY(y)
        visualCursorY = y
    }

    private func emitDiagnostics(timestamp: CFTimeInterval) {
        for state in smoothViewports.values where state.isActive {
            let sample = state.diagnosticSample(
                timestamp: timestamp, cursorAuthoritativeY: authoritativeCursorY,
                cursorVisualY: visualCursorY)
            os_signpost(
                .event, log: Self.scrollSignpostLog, name: "ScrollFrame",
                "grid=%{public}d delta=%{public}d head=%{public}d pos=%{public}.4f vel=%{public}.4f acc=%{public}.4f snap=%{public}d",
                sample.gridID, sample.delta, sample.historyHead,
                Double(sample.position), Double(sample.velocity),
                Double(sample.acceleration),
                sample.snappedTranslationPixels)
            if scrollDiagnosticHandler != nil || environmentDiagnosticsEnabled {
                diagnosticRing.append(sample)
                scrollDiagnosticHandler?(sample)
            }
        }
    }

    package static func displayTargetTimestamp(
        timestamp: CFTimeInterval, targetTimestamp: CFTimeInterval,
        duration: CFTimeInterval
    ) -> CFTimeInterval {
        if targetTimestamp.isFinite, targetTimestamp > timestamp {
            return targetTimestamp
        }
        return timestamp + nominalDisplayPeriod(
            timestamp: timestamp, targetTimestamp: targetTimestamp,
            duration: duration)
    }

    package static func nominalDisplayPeriod(
        timestamp: CFTimeInterval, targetTimestamp: CFTimeInterval,
        duration: CFTimeInterval
    ) -> CFTimeInterval {
        let targetPeriod = targetTimestamp - timestamp
        if targetPeriod.isFinite, targetPeriod > 0 {
            return targetPeriod
        }
        return duration.isFinite && duration > 0 ? duration : 1.0 / 60.0
    }

    package static func shouldDetectDisplayGap(
        resumedAt: CFTimeInterval?, callbackTimestamp: CFTimeInterval,
        nominalDisplayPeriod: CFTimeInterval
    ) -> Bool {
        guard let resumedAt else { return true }
        let nominal = max(1.0 / 240.0, nominalDisplayPeriod)
        return callbackTimestamp - resumedAt >= nominal * 2
    }

    private func renderer(for id: Int) -> GridRenderer {
        if let existing = renderers[id] { return existing }
        let created = GridRenderer(rasterizer: rasterizer, scale: scale)
        renderers[id] = created
        return created
    }

    private func refreshEditorAccessories() {
        guard let flush = lastFlush else { return }
        syncEditorAccessories(flush: flush, frames: lastFrames)
    }

    private func syncEditorAccessories(
        flush: FlushResult, frames: [ResolvedGridFrame]
    ) {
        accessoryCoordinator.sync(
            flush: flush, frames: frames, gridLayers: gridLayers,
            cellSize: cellSize, scale: scale,
            fontName: CTFontCopyPostScriptName(fonts.regular) as String,
            editorFontSize: fontSpec.size,
            showsMinimap: showsMinimap,
            showsScrollbars: showsNativeScrollbars,
            minimapWidth: minimapWidth, minimapScale: minimapScale,
            minimapPitch: minimapPitch,
            minimapMinEditorColumns: minimapMinEditorColumns)
        if reducedMotion || scrollMotionStyle == .immediate {
            accessoryCoordinator.settleMotion()
        }
    }

    /// Layer for a grid, created on demand. A grid that never appeared in
    /// damagedGrids (unlikely — creation damages everything) still gets a
    /// full render so its layer is never blank.
    private func layerFor(
        _ id: Int, flush: FlushResult, updated: inout Set<Int>
    ) -> CALayer {
        if let existing = gridLayers[id] { return existing }
        let created = CALayer()
        created.actions = [
            "position": NSNull(), "bounds": NSNull(), "contents": NSNull(),
            "hidden": NSNull(), "zPosition": NSNull(),
        ]
        created.isOpaque = true
        created.isGeometryFlipped = true
        created.masksToBounds = true
        gridLayers[id] = created
        layer?.addSublayer(created)
        if !updated.contains(id), let grid = flush.grids[id] {
            renderer(for: id).renderFull(grid: grid, highlights: flush.highlights)
            updated.insert(id)
        }
        return created
    }

    /// Cursor cell top-left in view coordinates (multigrid frame applied).
    private func cursorOrigin(_ flush: FlushResult) -> CGPoint {
        var row = flush.cursor.row
        var col = flush.cursor.col
        if let frame = lastFrames.first(where: { $0.gridID == flush.cursor.grid }) {
            row += frame.rect.row
            col += frame.rect.col
        }
        return CGPoint(x: CGFloat(col) * cellSize.width, y: CGFloat(row) * cellSize.height)
    }
}
