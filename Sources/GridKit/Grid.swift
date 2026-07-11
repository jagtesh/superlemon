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

/// Grid-cell margins excluded from a window's scrollable viewport.
///
/// Neovim reports these independently from `win_viewport`; for example, a
/// winbar contributes to `top`, while status columns contribute to `left` or
/// `right`.
public struct ViewportMargins: Sendable, Equatable {
    public var top: Int
    public var bottom: Int
    public var left: Int
    public var right: Int

    public init(top: Int, bottom: Int, left: Int, right: Int) {
        self.top = top
        self.bottom = bottom
        self.left = left
        self.right = right
    }
}

/// One nvim grid (with ext_multigrid, one per window). Value type: `FlushResult`
/// snapshots are cheap COW copies, safely sendable across actors.
public struct Grid: Sendable, Equatable {
    public let id: Int
    public private(set) var rows: Int
    public private(set) var cols: Int
    /// Row-backed cell storage. The outer array and every row use independent
    /// copy-on-write buffers, so a `Grid` snapshot stays cheap while editing a
    /// line only copies that line. Full-width vertical scrolls can therefore
    /// move row values without copying their cells.
    private var cellRows: [[Cell]]

    /// Row-major compatibility view, `rows * cols` entries.
    ///
    /// Rendering should prefer `rowCells(_:)` so it can retain the row-level
    /// copy-on-write behavior without materializing a flattened array.
    public var cells: [Cell] {
        cellRows.flatMap { $0 }
    }
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
    /// Latest `win_viewport_margins` payload.
    public internal(set) var viewportMargins: ViewportMargins?

    public init(id: Int, rows: Int, cols: Int) {
        self.id = id
        self.rows = max(0, rows)
        self.cols = max(0, cols)
        self.cellRows = Self.blankRows(count: self.rows, cols: self.cols)
        self.damage.markAll(rows: self.rows, cols: self.cols)
    }

    // MARK: - Access

    public subscript(row: Int, col: Int) -> Cell {
        cellRows[row][col]
    }

    public func rowCells(_ row: Int) -> ArraySlice<Cell> {
        cellRows[row][...]
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
            if newCols == cols {
                // Row-only resizes retain the existing row buffers.
                var resizedRows = Array(cellRows.prefix(min(rows, newRows)))
                if newRows > resizedRows.count {
                    resizedRows.append(contentsOf: Self.blankRows(
                        count: newRows - resizedRows.count,
                        cols: newCols
                    ))
                }
                cellRows = resizedRows
            } else {
                // A column resize changes each row's shape, so copy only the
                // overlapping cells of the rows that survive.
                var resizedRows = Self.blankRows(count: newRows, cols: newCols)
                let preservedRows = min(rows, newRows)
                let preservedCols = min(cols, newCols)
                if preservedCols > 0 {
                    for row in 0..<preservedRows {
                        resizedRows[row].replaceSubrange(
                            0..<preservedCols,
                            with: cellRows[row].prefix(preservedCols)
                        )
                    }
                }
                cellRows = resizedRows
            }
            rows = newRows
            cols = newCols
        }
        damage = DamageMap()
        damage.markAll(rows: rows, cols: cols)
    }

    /// `grid_clear`: blank everything, damage all, drop pending scroll deltas.
    mutating func clear() {
        cellRows = Self.blankRows(count: rows, cols: cols)
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
        var rowCells = cellRows[row]
        var col = colStart
        outer: for run in runs {
            guard run.repeatCount > 0 else { continue }
            for _ in 0..<run.repeatCount {
                guard col < cols else { break outer }
                rowCells[col] = Cell(text: run.text, hlID: run.hlID)
                col += 1
            }
        }
        if col > colStart {
            cellRows[row] = rowCells
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

        let snapshot = cellRows

        // The overwhelmingly common viewport-scroll case moves complete rows.
        // Assigning row arrays rotates their shared COW buffers instead of
        // copying every Cell in the region. Exposed rows deliberately retain
        // their previous values until Neovim sends the replacement grid_line.
        if left == 0, right == cols, colDelta == 0, rowDelta != 0 {
            for row in top..<bottom {
                let sourceRow = row + rowDelta
                guard sourceRow >= top, sourceRow < bottom else { continue }
                cellRows[row] = snapshot[sourceRow]
            }
            return
        }

        // Partial-width and horizontal scrolls cannot rotate whole rows. Work
        // from the immutable row snapshot and copy only each destination row
        // that receives cells.
        for r in top..<bottom {
            let srcRow = r + rowDelta
            guard srcRow >= top, srcRow < bottom else { continue }
            var destination = cellRows[r]
            var didCopy = false
            for c in left..<right {
                let srcCol = c + colDelta
                guard srcCol >= left, srcCol < right else { continue }
                destination[c] = snapshot[srcRow][srcCol]
                didCopy = true
            }
            if didCopy {
                cellRows[r] = destination
            }
        }
    }

    private static func blankRows(count: Int, cols: Int) -> [[Cell]] {
        guard count > 0 else { return [] }
        let blankRow = [Cell](repeating: .blank, count: cols)
        return [[Cell]](repeating: blankRow, count: count)
    }
}
