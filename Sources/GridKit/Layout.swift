/// A rectangle in outer-grid cell coordinates.
public struct GridRect: Sendable, Equatable {
    public var row: Int
    public var col: Int
    public var width: Int
    public var height: Int

    public init(row: Int, col: Int, width: Int, height: Int) {
        self.row = row
        self.col = col
        self.width = width
        self.height = height
    }
}

/// A grid placed in the outer coordinate space, with compositing order.
public struct ResolvedGridFrame: Sendable, Equatable {
    public var gridID: Int
    public var rect: GridRect
    public var zIndex: Int

    public init(gridID: Int, rect: GridRect, zIndex: Int) {
        self.gridID = gridID
        self.rect = rect
        self.zIndex = zIndex
    }
}

/// Pure multigrid layout resolution: window frames, float anchors (resolved
/// against the anchor grid's frame, all four corners, clamped to the outer
/// grid), message grid position, and a z-sorted draw order.
public enum GridLayout {
    /// z bands: floats above windows above the base grid; msg grid on top.
    public static let baseZ = 0
    public static let windowZ = 10
    public static let floatZBase = 100
    public static let msgZ = 200

    /// Resolve every visible grid's frame in outer-grid cells, returned in
    /// draw order (back to front: ascending zIndex, then grid id).
    /// Hidden and externalized grids are excluded. Grids with no known
    /// placement (and not grid 1) are skipped.
    public static func resolve(
        outerRows: Int, outerCols: Int, grids: [Int: Grid]
    ) -> [ResolvedGridFrame] {
        let outerFrame = GridRect(row: 0, col: 0, width: outerCols, height: outerRows)
        var memo: [Int: GridRect?] = [:]
        var visiting: Set<Int> = []

        func frame(of id: Int) -> GridRect? {
            if let cached = memo[id] { return cached }
            // Anchor cycles (protocol shouldn't produce them) fall back to
            // the outer frame rather than recursing forever.
            guard visiting.insert(id).inserted else { return outerFrame }
            defer { visiting.remove(id) }
            let result = compute(id)
            memo[id] = result
            return result
        }

        func compute(_ id: Int) -> GridRect? {
            if id == 1 { return outerFrame }
            guard let grid = grids[id] else { return nil }
            if let msg = grid.msgPosition {
                return GridRect(row: msg.row, col: 0, width: outerCols, height: grid.rows)
            }
            if let anchor = grid.floatAnchor {
                let base = frame(of: anchor.anchorGrid) ?? outerFrame
                let width = grid.cols
                let height = grid.rows
                var row = base.row + Int(anchor.row.rounded(.down))
                var col = base.col + Int(anchor.col.rounded(.down))
                switch anchor.corner {
                case .northWest: break
                case .northEast: col -= width
                case .southWest: row -= height
                case .southEast: row -= height; col -= width
                }
                // Clamp fully inside the outer grid (best effort if larger).
                row = max(0, min(row, max(0, outerRows - height)))
                col = max(0, min(col, max(0, outerCols - width)))
                return GridRect(row: row, col: col, width: width, height: height)
            }
            if let win = grid.windowFrame {
                return GridRect(row: win.startRow, col: win.startCol,
                                width: win.width, height: win.height)
            }
            return nil
        }

        var resolved: [ResolvedGridFrame] = []
        for (id, grid) in grids {
            guard !grid.isHidden, !grid.isExternal else { continue }
            guard let rect = frame(of: id) else { continue }
            let z: Int
            if grid.msgPosition != nil {
                z = msgZ
            } else if let anchor = grid.floatAnchor {
                z = floatZBase + anchor.zIndex
            } else if id == 1 {
                z = baseZ
            } else {
                z = windowZ
            }
            resolved.append(ResolvedGridFrame(gridID: id, rect: rect, zIndex: z))
        }
        return resolved.sorted { ($0.zIndex, $0.gridID) < ($1.zIndex, $1.gridID) }
    }
}
