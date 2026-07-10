import NvimKit

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

/// Everything the renderer needs for one atomic present, produced when a
/// batch contains `flush`. All value types: safely sendable to the render
/// side, immutable snapshot of one consistent frame.
public struct FlushResult: Sendable {
    /// A damaged grid's post-batch snapshot plus its consumed damage.
    public struct DamagedGrid: Sendable {
        /// Snapshot of the grid after this batch (its own damage already
        /// consumed/cleared; use `damage` alongside).
        public let grid: Grid
        /// Damage accumulated since last consumed: apply `damage.scrolls` as
        /// blits in order, then repaint `damage.rowSpans` from `grid`.
        public let damage: DamageMap
    }

    /// Grids with pending damage, sorted by grid id.
    public let damagedGrids: [DamagedGrid]
    /// All live grids (damaged or not) — window frames/anchors for layout.
    public let grids: [Int: Grid]
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

    public init() {}

    /// Apply one decoded redraw batch, in wire order. Returns a `FlushResult`
    /// only if the batch contained `flush` (nvim's frame boundary); otherwise
    /// damage keeps accumulating and nil is returned.
    @discardableResult
    public func apply(_ batch: RedrawBatch) -> FlushResult? {
        var sawFlush = false
        for event in batch.events {
            apply(event, sawFlush: &sawFlush)
        }
        guard sawFlush else { return nil }
        return makeFlushResult()
    }

    // MARK: - Event application

    private func apply(_ event: UIEvent, sawFlush: inout Bool) {
        switch event {
        // -- global ----------------------------------------------------------
        case .flush:
            sawFlush = true
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

        // -- chrome events (ChromeKit's domain) and shell events with no model
        // -- effect: ignored here, never a crash.
        default:
            break
        }
    }

    // MARK: - Flush

    private func makeFlushResult() -> FlushResult {
        var damaged: [FlushResult.DamagedGrid] = []
        for id in grids.keys.sorted() {
            guard var grid = grids[id], !grid.damage.isEmpty else { continue }
            let consumed = grid.consumeDamage()
            grids[id] = grid
            damaged.append(FlushResult.DamagedGrid(grid: grid, damage: consumed))
        }
        return FlushResult(
            damagedGrids: damaged,
            grids: grids,
            highlights: highlights,
            cursor: cursor,
            mode: currentMode,
            title: title,
            isBusy: isBusy,
            isMouseEnabled: isMouseEnabled
        )
    }
}
