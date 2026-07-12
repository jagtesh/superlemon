import NvimKit

/// How urgently an accumulated redraw frame must be handed to SurfaceKit.
///
/// The app uses `.displayLinked` only for viewport motion that can be safely
/// coalesced until the next display opportunity. Everything else preserves
/// the existing atomic/immediate presentation contract.
package enum PresentationDisposition: Sendable, Equatable {
    case none
    case displayLinked
    case immediate
}

public struct CursorPosition: Sendable, Equatable {
    public var grid: Int
    public var row: Int
    public var col: Int

    public init(grid: Int, row: Int, col: Int) {
        self.grid = grid
        self.row = row
        self.col = col
    }
}

/// Compact provenance for semantic viewport movement coalesced across one or
/// more Neovim flushes. `netDelta` remains the authoritative old-to-new
/// displacement, while `largestStepMagnitude` distinguishes one genuinely
/// far incoming jump from ordinary small steps whose accumulated debt happens
/// to cross a screen. Cancellation deliberately remains observable so a
/// display-linked reversal does not force the active spring to settle.
public struct ViewportScrollMotion: Sendable, Equatable {
    public private(set) var netDelta: Int
    public private(set) var largestStepMagnitude: Int
    public private(set) var largestStepDelta: Int
    public private(set) var lastDelta: Int
    public private(set) var stepCount: Int
    public private(set) var containsReversal: Bool

    public init(delta: Int) {
        netDelta = delta
        largestStepMagnitude = Int(min(UInt(Int.max), delta.magnitude))
        largestStepDelta = delta
        lastDelta = delta
        stepCount = delta == 0 ? 0 : 1
        containsReversal = false
    }

    public var hasMovement: Bool { stepCount > 0 }

    package mutating func append(_ delta: Int) {
        guard delta != 0 else { return }
        if lastDelta != 0, lastDelta.signum() != delta.signum() {
            containsReversal = true
        }
        netDelta += delta
        let magnitude = Int(min(UInt(Int.max), delta.magnitude))
        if magnitude >= largestStepMagnitude {
            largestStepMagnitude = magnitude
            largestStepDelta = delta
        }
        lastDelta = delta
        stepCount += 1
    }
}

/// Everything the renderer needs for one atomic present, produced only at a
/// Neovim `flush` boundary. Deferred presentation may coalesce several wire
/// flushes into this single consistent snapshot.
public struct FlushResult: Sendable {
    /// A damaged grid's post-batch snapshot plus its consumed damage.
    public struct DamagedGrid: Sendable {
        /// Snapshot of the grid after this batch (its own damage already
        /// consumed/cleared; use `damage` alongside).
        public let grid: Grid
        /// Damage accumulated since last consumed. Renderers rotate compatible
        /// `damage.presentationScrolls` row tiles, then repaint
        /// `damage.rowSpans` from the final `grid` model.
        public let damage: DamageMap
    }

    /// Grids with pending damage, sorted by grid id.
    public let damagedGrids: [DamagedGrid]
    /// All live grids (damaged or not) — window frames/anchors for layout.
    public let grids: [Int: Grid]
    /// Per-grid displayed-line movement from `win_viewport`, consumed exactly
    /// once at this flush. Unlike `Grid.viewport.scrollDelta`, this cannot be
    /// accidentally replayed by a later unrelated frame.
    public let viewportScrollDeltas: [Int: Int]
    /// Per-grid provenance for the one-shot deltas above. This preserves the
    /// difference between one far jump and many coalesced small steps, as well
    /// as reversals whose net displacement is zero.
    public let viewportScrollMotions: [Int: ViewportScrollMotion]
    /// False when any coalesced wire frame required atomic presentation.
    /// SurfaceKit must settle existing motion and install this frame without
    /// interpolation, even if it also contains otherwise compatible scroll
    /// damage accumulated before the immediate event.
    public let allowsScrollInterpolation: Bool
    public let highlights: HighlightTable
    public let cursor: CursorPosition
    /// Current mode's info (cursor shape, blink, attr id), if known.
    public let mode: ModeInfo?
    public let title: String
    public let isBusy: Bool
    public let isMouseEnabled: Bool
}

/// The top-level grid model. `@MainActor` by design:
/// - `RedrawBatch` is `Sendable`, so hopping decoded batches from the NvimKit
///   actor to the main actor is free of shared mutable state.
/// - Everything above the model layer (SurfaceKit, ChromeKit) is `@MainActor`
///   (DESIGN.md §2); applying events on main means `FlushResult` is handed to
///   the renderer with no further synchronization.
/// - All contained state is value-typed (`Grid`, `HighlightTable`, `DamageMap`),
///   so a `FlushResult` is an O(1)-ish COW snapshot — no locking, no copies of
///   cell storage unless the model mutates afterward.
@MainActor
public final class GridStore {
    public private(set) var grids: [Int: Grid] = [:]
    public private(set) var highlights = HighlightTable()
    public private(set) var cursor = CursorPosition(grid: 1, row: 0, col: 0)

    public private(set) var modes: [ModeInfo] = []
    public private(set) var cursorStyleEnabled = false
    public private(set) var currentModeIndex = 0
    public private(set) var currentModeName = ""
    public var currentMode: ModeInfo? {
        modes.indices.contains(currentModeIndex) ? modes[currentModeIndex] : nil
    }

    public private(set) var title = ""
    public private(set) var isBusy = false
    public private(set) var isMouseEnabled = true
    /// Raw `option_set` values by name (e.g. "guifont"), for upper layers.
    public private(set) var options: [String: Value] = [:]
    /// Semantic displayed-line movement accumulated until the next presented
    /// frame, including its per-event provenance.
    private var pendingViewportScrollMotions: [Int: ViewportScrollMotion] = [:]
    /// Deferred mode deliberately leaves model damage unconsumed across wire
    /// flushes. A single immutable FlushResult is produced only when the
    /// display is ready to present it.
    private var hasPendingPresentation = false
    private var pendingPresentationRequiresImmediate = false
    private var hasUnflushedDeferredEvents = false
    private var deferredFrame = DeferredFrameClassification()
    /// Direct `apply(_:)` also accepts redraw notifications split before their
    /// eventual `flush`. Keep its frame provenance across calls just as the
    /// deferred path does.
    private var directFrame = DeferredFrameClassification()
    private var directFrameHasEvents = false

    public init() {}

    /// Apply one decoded redraw batch, in wire order. Returns a `FlushResult`
    /// only if the batch contained `flush` (nvim's frame boundary); otherwise
    /// damage keeps accumulating and nil is returned.
    @discardableResult
    public func apply(_ batch: RedrawBatch) -> FlushResult? {
        var sawFlush = false
        var allowsScrollInterpolation = !pendingPresentationRequiresImmediate
        for event in batch.events {
            if case .flush = event {
                sawFlush = true
                appendPendingViewportSteps(directFrame.reconciledViewportSteps)
                if directFrameHasEvents {
                    allowsScrollInterpolation =
                        allowsScrollInterpolation && directFrame.isDisplayLinked
                }
                directFrameHasEvents = false
                directFrame.reset()
            } else {
                directFrameHasEvents = true
                directFrame.observe(event, grids: grids)
            }
            apply(event)
        }
        guard sawFlush else { return nil }
        // Direct callers retain the original one-batch/one-present behavior.
        // Also make the method robust if a caller switches out of deferred
        // mode while a presentation is pending.
        hasPendingPresentation = false
        pendingPresentationRequiresImmediate = false
        hasUnflushedDeferredEvents = false
        deferredFrame.reset()
        return makeFlushResult(
            allowsScrollInterpolation: allowsScrollInterpolation)
    }

    /// Apply decoded redraws without consuming damage at every Neovim flush.
    /// The returned disposition tells the app whether to wait for the shared
    /// display link or drain the accumulated state immediately.
    @discardableResult
    package func applyDeferred(_ batch: RedrawBatch) -> PresentationDisposition {
        var result: PresentationDisposition = .none
        for event in batch.events {
            if case .flush = event {
                // ext_messages frames are consumed by ChromeKit before they
                // reach GridStore. If that is all Neovim flushed, there is no
                // SurfaceKit state to present. In particular, do not turn a
                // standalone msg_showcmd frame into an immediate drain that
                // interrupts an already scheduled scroll presentation.
                guard deferredFrame.hasPresentationEffect else {
                    hasUnflushedDeferredEvents = false
                    deferredFrame.reset()
                    continue
                }
                appendPendingViewportSteps(deferredFrame.reconciledViewportSteps)
                hasPendingPresentation = true
                hasUnflushedDeferredEvents = false
                let frameDisposition = deferredFrame.isDisplayLinked
                    ? PresentationDisposition.displayLinked
                    : PresentationDisposition.immediate
                pendingPresentationRequiresImmediate =
                    pendingPresentationRequiresImmediate || frameDisposition == .immediate
                result = pendingPresentationRequiresImmediate ? .immediate : .displayLinked
                deferredFrame.reset()
            } else {
                deferredFrame.observe(event, grids: grids)
                // Externalized messages are already complete from
                // SurfaceKit's perspective, even if their redraw notification
                // is split before its eventual `flush`. They must not block a
                // previously scheduled authoritative grid presentation.
                hasUnflushedDeferredEvents = hasUnflushedDeferredEvents
                    || deferredFrame.hasPresentationEffect
            }
            apply(event)
        }
        return result
    }

    /// Consume all model damage and semantic viewport movement accumulated by
    /// `applyDeferred`. Each viewport delta remains one-shot relative to this
    /// *presented* frame, even when several wire flushes were coalesced.
    package func consumePendingPresentation() -> FlushResult? {
        // The model is allowed to advance immediately into the next wire
        // frame, but SurfaceKit must never observe that frame half-applied.
        // If events arrived after the last flush, wait for their flush and
        // present the newer consistent state instead.
        guard hasPendingPresentation, !hasUnflushedDeferredEvents else { return nil }
        let allowsScrollInterpolation = !pendingPresentationRequiresImmediate
        hasPendingPresentation = false
        pendingPresentationRequiresImmediate = false
        return makeFlushResult(
            allowsScrollInterpolation: allowsScrollInterpolation)
    }

    // MARK: - Event application

    private func apply(_ event: UIEvent) {
        switch event {
        // -- global ----------------------------------------------------------
        case .flush:
            break
        case .setTitle(let t):
            title = t
        case .busyStart:
            isBusy = true
        case .busyStop:
            isBusy = false
        case .mouseOn:
            isMouseEnabled = true
        case .mouseOff:
            isMouseEnabled = false
        case .optionSet(let name, let value):
            options[name] = value
        case .modeInfoSet(let enabled, let modes):
            cursorStyleEnabled = enabled
            self.modes = modes
        case .modeChange(let mode, let index):
            currentModeName = mode
            currentModeIndex = index

        // -- highlight ---------------------------------------------------------
        case .defaultColorsSet(let fg, let bg, let sp):
            highlights.setDefaults(foreground: fg, background: bg, special: sp)
            // Default colors affect every cell resolved against them; nvim
            // does not re-send content, so the whole screen must repaint.
            for id in grids.keys { grids[id]?.damageAll() }
        case .hlAttrDefine(let id, let attrs):
            highlights.define(id: id, attrs: attrs)
        case .hlGroupSet(let name, let id):
            highlights.setGroup(name: name, id: id)

        // -- linegrid ----------------------------------------------------------
        case .gridResize(let grid, let width, let height):
            if grids[grid] != nil {
                grids[grid]?.resize(rows: height, cols: width)
            } else {
                grids[grid] = Grid(id: grid, rows: height, cols: width)
            }
        case .gridClear(let grid):
            grids[grid]?.clear()
        case .gridDestroy(let grid):
            grids.removeValue(forKey: grid)
            pendingViewportScrollMotions.removeValue(forKey: grid)
        case .gridCursorGoto(let grid, let row, let col):
            grids[cursor.grid]?.hasCursor = false
            cursor = CursorPosition(grid: grid, row: row, col: col)
            grids[grid]?.hasCursor = true
        case .gridLine(let grid, let row, let colStart, let cells, _):
            grids[grid]?.applyLine(row: row, colStart: colStart, runs: cells)
        case .gridScroll(let grid, let top, let bottom, let left, let right, let rows, let cols):
            grids[grid]?.applyScroll(
                top: top, bottom: bottom, left: left, right: right,
                rowDelta: rows, colDelta: cols)

        // -- multigrid ---------------------------------------------------------
        case .winPos(let grid, let win, let startRow, let startCol, let width, let height):
            grids[grid]?.windowHandle = win
            grids[grid]?.windowFrame = WindowFrame(
                startRow: startRow, startCol: startCol, width: width, height: height)
            grids[grid]?.floatAnchor = nil
            grids[grid]?.isHidden = false
            grids[grid]?.isExternal = false
        case .winFloatPos(let grid, let win, let anchor, let anchorGrid,
                          let anchorRow, let anchorCol, let focusable, let zIndex):
            grids[grid]?.windowHandle = win
            grids[grid]?.floatAnchor = FloatAnchor(
                corner: FloatAnchorCorner(rawValue: anchor) ?? .northWest,
                anchorGrid: anchorGrid, row: anchorRow, col: anchorCol,
                focusable: focusable, zIndex: zIndex)
            grids[grid]?.windowFrame = nil
            grids[grid]?.isHidden = false
            grids[grid]?.isExternal = false
        case .winExternalPos(let grid, let win):
            grids[grid]?.windowHandle = win
            grids[grid]?.isExternal = true
            grids[grid]?.windowFrame = nil
            grids[grid]?.floatAnchor = nil
        case .winHide(let grid):
            grids[grid]?.isHidden = true
        case .winClose(let grid):
            grids[grid]?.isHidden = true
            grids[grid]?.windowFrame = nil
            grids[grid]?.floatAnchor = nil
            grids[grid]?.windowHandle = nil
        case .msgSetPos(let grid, let row, let scrolled, let sepChar):
            grids[grid]?.msgPosition = MsgPosition(row: row, scrolled: scrolled, sepChar: sepChar)
        case .winViewport(let grid, _, let topline, let botline,
                          let curline, let curcol, let lineCount, let scrollDelta):
            grids[grid]?.viewport = Viewport(
                topline: topline, botline: botline, curline: curline,
                curcol: curcol, lineCount: lineCount, scrollDelta: scrollDelta)
        case .winViewportMargins(let grid, _, let top, let bottom, let left, let right):
            grids[grid]?.viewportMargins = ViewportMargins(
                top: top, bottom: bottom, left: left, right: right)

        // -- chrome events (ChromeKit's domain) and shell events with no model
        // -- effect: ignored here, never a crash.
        default:
            break
        }
    }

    // MARK: - Flush

    /// Merge one flushed wire frame's reconciled row steps into the one-shot
    /// presentation provenance. Zero entries are metadata-only viewport reports;
    /// zero *nets* produced by real opposite steps remain observable.
    private func appendPendingViewportSteps(_ stepsByGrid: [Int: [Int]]) {
        for (grid, steps) in stepsByGrid {
            for delta in steps where delta != 0 {
                if pendingViewportScrollMotions[grid] == nil {
                    pendingViewportScrollMotions[grid] = ViewportScrollMotion(
                        delta: delta)
                } else {
                    pendingViewportScrollMotions[grid]?.append(delta)
                }
            }
        }
    }

    private func makeFlushResult(allowsScrollInterpolation: Bool) -> FlushResult {
        var damaged: [FlushResult.DamagedGrid] = []
        for id in grids.keys.sorted() {
            guard var grid = grids[id], !grid.damage.isEmpty else { continue }
            let consumed = grid.consumeDamage()
            grids[id] = grid
            damaged.append(FlushResult.DamagedGrid(grid: grid, damage: consumed))
        }
        let viewportScrollMotions = pendingViewportScrollMotions
        let viewportScrollDeltas = viewportScrollMotions.reduce(into: [Int: Int]()) {
            if $1.value.netDelta != 0 { $0[$1.key] = $1.value.netDelta }
        }
        pendingViewportScrollMotions.removeAll(keepingCapacity: true)
        return FlushResult(
            damagedGrids: damaged,
            grids: grids,
            viewportScrollDeltas: viewportScrollDeltas,
            viewportScrollMotions: viewportScrollMotions,
            allowsScrollInterpolation: allowsScrollInterpolation,
            highlights: highlights,
            cursor: cursor,
            mode: currentMode,
            title: title,
            isBusy: isBusy,
            isMouseEnabled: isMouseEnabled
        )
    }
}

/// Classification is intentionally conservative. Only row updates, cursor
/// movement and viewport metadata may accompany display-linked vertical
/// motion. Resize, chrome/layout, highlight, horizontal, and conflicting
/// partial-region changes retain immediate atomic presentation.
private struct DeferredFrameClassification {
    private struct Region: Equatable {
        var top: Int
        var bottom: Int
        var left: Int
        var right: Int
    }

    private var sawMotion = false
    private var requiresImmediate = false
    private var regions: [Int: Region] = [:]
    private var scrollDirections: [Int: Int] = [:]
    private var scrollDistances: [Int: Int] = [:]
    private var semanticDeltas: [Int: Int] = [:]
    /// Authoritative semantic reports in wire order, including zero. A zero
    /// report can validate an ordered pixel reversal whose net is also zero.
    private var semanticReports: [Int: [Int]] = [:]
    /// Full inner-viewport vertical row moves are the only pixel events that
    /// can refine semantic provenance. Their order distinguishes repeated
    /// one-row input from one genuinely large jump.
    private var viewportScrollSteps: [Int: [Int]] = [:]
    private var invalidProvenanceGrids: Set<Int> = []
    private var lineGrids: Set<Int> = []
    private var lineRows: [Int: Set<Int>] = [:]
    private var cursorGrids: Set<Int> = []
    /// Externalized message events are routed to ChromeKit and have no model
    /// or SurfaceKit effect. Their flush boundary must not request a duplicate
    /// presentation of the current grid snapshot.
    private(set) var hasPresentationEffect = false

    var isDisplayLinked: Bool {
        guard sawMotion, !requiresImmediate else { return false }
        let semanticGrids = Set(
            semanticDeltas.compactMap { grid, delta in delta == 0 ? nil : grid })
        let motionGrids = Set(regions.keys).union(semanticGrids)
        guard !motionGrids.isEmpty,
            lineGrids.isSubset(of: motionGrids),
            cursorGrids.isSubset(of: motionGrids)
        else { return false }

        // A grid_scroll without semantic viewport movement is not safe to
        // interpolate. SurfaceKit uses the semantic direction to select and
        // clamp retained history.
        for (grid, direction) in scrollDirections {
            guard let semantic = semanticDeltas[grid], semantic != 0,
                semantic.signum() == direction
            else { return false }

            // A pixel scroll and semantic viewport report that disagree cannot
            // share an exact history coordinate system. The provenance result
            // still falls back to the authoritative semantic step, but the
            // pixels for this frame must present atomically.
            if let candidates = viewportScrollSteps[grid],
                let reports = semanticReports[grid]
            {
                guard let pixelNet = Self.exactSum(candidates),
                    let semanticNet = Self.exactSum(reports),
                    pixelNet == semanticNet
                else { return false }
            }

            if let region = regions[grid], let rows = lineRows[grid] {
                let distance = min(
                    region.bottom - region.top,
                    max(0, scrollDistances[grid] ?? 0))
                let exposed = direction > 0
                    ? (region.bottom - distance)..<region.bottom
                    : region.top..<(region.top + distance)
                guard rows.allSatisfy(exposed.contains) else { return false }
            }
        }
        return true
    }

    /// Neovim may process several input notifications before emitting one
    /// aggregated `win_viewport.scroll_delta`. When the ordered compatible
    /// `grid_scroll` rows have exactly the same net, they are a more precise
    /// account of the small steps that produced that authoritative movement.
    /// Any incompatible geometry or net mismatch falls back to the semantic
    /// reports exactly as received, never inventing intermediate movement.
    var reconciledViewportSteps: [Int: [Int]] {
        var result: [Int: [Int]] = [:]
        for (grid, reports) in semanticReports {
            let semanticSteps = reports.filter { $0 != 0 }
            guard let semanticNet = Self.exactSum(reports) else {
                if !semanticSteps.isEmpty { result[grid] = semanticSteps }
                continue
            }
            if !invalidProvenanceGrids.contains(grid),
                let candidates = viewportScrollSteps[grid],
                !candidates.isEmpty,
                Self.exactSum(candidates) == semanticNet
            {
                result[grid] = candidates
            } else if !semanticSteps.isEmpty {
                result[grid] = semanticSteps
            }
        }
        return result
    }

    mutating func reset() {
        sawMotion = false
        requiresImmediate = false
        regions.removeAll(keepingCapacity: true)
        scrollDirections.removeAll(keepingCapacity: true)
        scrollDistances.removeAll(keepingCapacity: true)
        semanticDeltas.removeAll(keepingCapacity: true)
        semanticReports.removeAll(keepingCapacity: true)
        viewportScrollSteps.removeAll(keepingCapacity: true)
        invalidProvenanceGrids.removeAll(keepingCapacity: true)
        lineGrids.removeAll(keepingCapacity: true)
        lineRows.removeAll(keepingCapacity: true)
        cursorGrids.removeAll(keepingCapacity: true)
        hasPresentationEffect = false
    }

    mutating func observe(_ event: UIEvent, grids: [Int: Grid]) {
        switch event {
        case .gridLine(let grid, let row, _, _, _):
            hasPresentationEffect = true
            lineGrids.insert(grid)
            lineRows[grid, default: []].insert(row)

        case .gridCursorGoto(let grid, _, _):
            hasPresentationEffect = true
            cursorGrids.insert(grid)

        case .winViewport(let grid, _, _, _, _, _, _, let scrollDelta):
            hasPresentationEffect = true
            semanticReports[grid, default: []].append(scrollDelta)
            sawMotion = sawMotion || scrollDelta != 0
            semanticDeltas[grid, default: 0] += scrollDelta
            if semanticDeltas[grid] == 0 { semanticDeltas.removeValue(forKey: grid) }

        case .gridScroll(
            let gridID, let top, let bottom, let left, let right,
            let rows, let cols):
            hasPresentationEffect = true
            let margins = grids[gridID]?.viewportMargins
            let marginTop = margins?.top ?? 0
            let marginBottom = margins?.bottom ?? 0
            let marginLeft = margins?.left ?? 0
            let marginRight = margins?.right ?? 0
            guard let grid = grids[gridID], rows != 0, cols == 0,
                top == marginTop, bottom == grid.rows - marginBottom, top < bottom,
                left == marginLeft, right == grid.cols - marginRight, left < right
            else {
                invalidProvenanceGrids.insert(gridID)
                requiresImmediate = true
                return
            }
            viewportScrollSteps[gridID, default: []].append(rows)
            sawMotion = true
            let direction = rows.signum()
            if let existing = scrollDirections[gridID], existing != direction {
                requiresImmediate = true
            } else {
                scrollDirections[gridID] = direction
                let regionHeight = bottom - top
                let oldDistance = scrollDistances[gridID] ?? 0
                let added = min(regionHeight, Int(min(UInt(regionHeight), rows.magnitude)))
                scrollDistances[gridID] =
                    oldDistance + min(regionHeight - oldDistance, added)
            }
            let region = Region(top: top, bottom: bottom, left: left, right: right)
            if let existing = regions[gridID], existing != region {
                invalidProvenanceGrids.insert(gridID)
                requiresImmediate = true
            } else {
                regions[gridID] = region
            }

        // Every ext_messages surface is owned by ChromeKit. Neovim commonly
        // emits `msg_ruler` beside viewport moves and `msg_showcmd` beside
        // keyboard scrolling; none of these events changes grid pixels or geometry.
        case .msgShow, .msgClear, .msgShowmode, .msgShowcmd, .msgRuler,
             .msgHistoryShow:
            break

        default:
            hasPresentationEffect = true
            requiresImmediate = true
        }
    }

    private static func exactSum(_ values: [Int]) -> Int? {
        var total = 0
        for value in values {
            let (next, overflow) = total.addingReportingOverflow(value)
            guard !overflow else { return nil }
            total = next
        }
        return total
    }
}
