import NvimKit

/// A normal window's frame in outer-grid cells (from `win_pos`).
public struct WindowFrame: Sendable, Equatable {
    public var startRow: Int
    public var startCol: Int
    public var width: Int
    public var height: Int

    public init(startRow: Int, startCol: Int, width: Int, height: Int) {
        self.startRow = startRow
        self.startCol = startCol
        self.width = width
        self.height = height
    }
}

public enum FloatAnchorCorner: String, Sendable, Equatable {
    case northWest = "NW"
    case northEast = "NE"
    case southWest = "SW"
    case southEast = "SE"
}

/// Float placement from `win_float_pos`: which corner of the float sits at
/// (row, col) of the anchor grid.
public struct FloatAnchor: Sendable, Equatable {
    public var corner: FloatAnchorCorner
    public var anchorGrid: Int
    public var row: Double
    public var col: Double
    public var focusable: Bool
    public var zIndex: Int

    public init(
        corner: FloatAnchorCorner, anchorGrid: Int, row: Double, col: Double,
        focusable: Bool, zIndex: Int
    ) {
        self.corner = corner
        self.anchorGrid = anchorGrid
        self.row = row
        self.col = col
        self.focusable = focusable
        self.zIndex = zIndex
    }
}

/// Message-grid placement from `msg_set_pos`.
public struct MsgPosition: Sendable, Equatable {
    public var row: Int
    public var scrolled: Bool
    public var sepChar: String

    public init(row: Int, scrolled: Bool, sepChar: String) {
        self.row = row
        self.scrolled = scrolled
        self.sepChar = sepChar
    }
}

/// Scroll/cursor state from `win_viewport` (drives native scrollbars).
public struct Viewport: Sendable, Equatable {
    public var topline: Int
    public var botline: Int
    public var curline: Int
    public var curcol: Int
    public var lineCount: Int
    public var scrollDelta: Int

    public init(topline: Int, botline: Int, curline: Int, curcol: Int, lineCount: Int, scrollDelta: Int) {
        self.topline = topline
        self.botline = botline
        self.curline = curline
        self.curcol = curcol
        self.lineCount = lineCount
        self.scrollDelta = scrollDelta
    }
}

/// One nvim grid (with ext_multigrid, one per window). Value type: `FlushResult`
/// snapshots are cheap COW copies, safely sendable across actors.
public struct Grid: Sendable, Equatable {
    public let id: Int
    public private(set) var rows: Int
    public private(set) var cols: Int
    /// Row-major cell storage, `rows * cols` entries.
    public private(set) var cells: [Cell]
    /// Accumulated damage since last consumed (survives across batches).
    public internal(set) var damage = DamageMap()

    /// True when this grid owns the cursor (last `grid_cursor_goto` target).
    public internal(set) var hasCursor = false
    /// nvim window handle from win_pos / win_float_pos, if any.
    public internal(set) var windowHandle: Int?
    /// Normal-window frame in outer-grid cells (`win_pos`). nil for floats.
    public internal(set) var windowFrame: WindowFrame?
    /// Float placement (`win_float_pos`). nil for normal windows.
    public internal(set) var floatAnchor: FloatAnchor?
    /// Message-grid placement (`msg_set_pos`).
    public internal(set) var msgPosition: MsgPosition?
    /// Hidden via `win_hide` / closed via `win_close`.
    public internal(set) var isHidden = false
    /// Externalized via `win_external_pos`.
    public internal(set) var isExternal = false
    /// Latest `win_viewport` payload.
    public internal(set) var viewport: Viewport?

    public init(id: Int, rows: Int, cols: Int) {
        self.id = id
        self.rows = max(0, rows)
        self.cols = max(0, cols)
        self.cells = [Cell](repeating: .blank, count: self.rows * self.cols)
        self.damage.markAll(rows: self.rows, cols: self.cols)
    }

    // MARK: - Access

    public subscript(row: Int, col: Int) -> Cell {
        cells[row * cols + col]
    }

    public func rowCells(_ row: Int) -> ArraySlice<Cell> {
        cells[row * cols ..< (row + 1) * cols]
    }

    /// The row's text with blank/trailing cells contributing nothing.
    /// Convenient for tests and debugging.
    public func rowText(_ row: Int) -> String {
        rowCells(row).map(\.text).joined()
    }

    /// Returns accumulated damage and resets tracking.
    public mutating func consumeDamage() -> DamageMap {
        let consumed = damage
        damage = DamageMap()
        return consumed
    }

    // MARK: - Event application (module-internal; GridStore drives these)

    /// `grid_resize`: preserve overlapping content, blank new cells, damage all.
    /// Pending scroll deltas are dropped: full damage supersedes any blit.
    mutating func resize(rows newRows: Int, cols newCols: Int) {
        let newRows = max(0, newRows)
        let newCols = max(0, newCols)
        if newRows != rows || newCols != cols {
            var newCells = [Cell](repeating: .blank, count: newRows * newCols)
            for r in 0..<min(rows, newRows) {
                for c in 0..<min(cols, newCols) {
                    newCells[r * newCols + c] = cells[r * cols + c]
                }
            }
            cells = newCells
            rows = newRows
            cols = newCols
        }
        damage = DamageMap()
        damage.markAll(rows: rows, cols: cols)
    }

    /// `grid_clear`: blank everything, damage all, drop pending scroll deltas.
    mutating func clear() {
        cells = [Cell](repeating: .blank, count: rows * cols)
        damage = DamageMap()
        damage.markAll(rows: rows, cols: cols)
    }

    mutating func damageAll() {
        damage.markAll(rows: rows, cols: cols)
    }

    /// `grid_line`: write cell runs starting at `colStart`. Each run's hlID is
    /// already concrete (decoder resolved wire-format repeats); `repeatCount`
    /// expands a run horizontally. Double-width trailing halves arrive as
    /// empty-text runs and are stored as-is.
    mutating func applyLine(row: Int, colStart: Int, runs: [CellRun]) {
        guard row >= 0, row < rows, colStart >= 0, colStart < cols else { return }
        var col = colStart
        outer: for run in runs {
            guard run.repeatCount > 0 else { continue }
            for _ in 0..<run.repeatCount {
                guard col < cols else { break outer }
                cells[row * cols + col] = Cell(text: run.text, hlID: run.hlID)
                col += 1
            }
        }
        if col > colStart {
            damage.mark(row: row, cols: colStart..<col)
        }
    }

    /// `grid_scroll`: records the delta first (renderer blits from it), then
    /// moves cells. Positive `rowDelta` scrolls content up: destination row r
    /// takes source row r+rowDelta within the region; columns likewise.
    /// Cells outside the copy destination (the exposed strip) keep their old
    /// content until follow-up `grid_line` events arrive, per protocol.
    mutating func applyScroll(
        top: Int, bottom: Int, left: Int, right: Int, rowDelta: Int, colDelta: Int
    ) {
        let top = max(0, min(top, rows))
        let bottom = max(top, min(bottom, rows))
        let left = max(0, min(left, cols))
        let right = max(left, min(right, cols))
        guard bottom > top, right > left, rowDelta != 0 || colDelta != 0 else { return }

        damage.recordScroll(
            ScrollDelta(top: top, bottom: bottom, left: left, right: right,
                        rows: rowDelta, cols: colDelta))

        let snapshot = cells
        for r in top..<bottom {
            let srcRow = r + rowDelta
            guard srcRow >= top, srcRow < bottom else { continue }
            for c in left..<right {
                let srcCol = c + colDelta
                guard srcCol >= left, srcCol < right else { continue }
                cells[r * cols + c] = snapshot[srcRow * cols + srcCol]
            }
        }
    }
}
