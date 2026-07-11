import CoreGraphics
import GridKit

/// An immutable row-sized image revision. Surviving rows keep the same image
/// and token across vertical scrolls, so SurfaceKit can rotate layer bindings
/// without asking Core Animation to prepare another full-grid image.
struct RenderedRowSnapshot: @unchecked Sendable {
    let image: CGImage
    let backingID: UInt64
    let revision: UInt64

    var token: RowImageToken {
        RowImageToken(backingID: backingID, revision: revision)
    }
}

struct RowImageToken: Sendable, Hashable {
    let backingID: UInt64
    let revision: UInt64
}

/// Per-grid row-tiled Retina backing store. A compatible vertical scroll is a
/// rotation of row backing references; only exposed/damaged rows rasterize.
/// Unsupported scroll geometry deliberately falls back to an atomic repaint
/// from the final authoritative Grid model.
final class GridRenderer {
    private final class RowBacking {
        let id: UInt64
        let context: CGContext
        var revision: UInt64 = 0
        var cachedImage: CGImage?

        init(id: UInt64, context: CGContext) {
            self.id = id
            self.context = context
        }

        func changed() {
            revision &+= 1
            cachedImage = nil
        }

        func snapshot() -> RenderedRowSnapshot? {
            if cachedImage == nil { cachedImage = context.makeImage() }
            guard let cachedImage else { return nil }
            return RenderedRowSnapshot(
                image: cachedImage, backingID: id, revision: revision)
        }
    }

    private(set) var scale: CGFloat
    private(set) var rows = 0
    private(set) var cols = 0
    private var rowBackings: [RowBacking] = []
    private var nextBackingID: UInt64 = 1
    /// Post-apply model snapshot, kept for full re-renders (scale/font change).
    private var lastGrid: Grid?
    private var lastHighlights: HighlightTable?

    let rasterizer: TextRasterizer

    init(rasterizer: TextRasterizer, scale: CGFloat) {
        self.rasterizer = rasterizer
        self.scale = max(1, scale)
    }

    private var cellSize: CGSize { rasterizer.fonts.cellSize }
    private var gridHeight: CGFloat { CGFloat(rows) * cellSize.height }

    /// Apply one damaged-grid snapshot. Compatible vertical scrolls rotate
    /// row references in wire order, then final-model damage repaints rows.
    func apply(grid: Grid, damage: DamageMap, highlights: HighlightTable) {
        lastGrid = grid
        lastHighlights = highlights
        guard grid.rows > 0, grid.cols > 0 else {
            rows = max(0, grid.rows)
            cols = max(0, grid.cols)
            rowBackings.removeAll()
            return
        }

        if grid.rows != rows || grid.cols != cols || rowBackings.count != grid.rows {
            rebuild(rows: grid.rows, cols: grid.cols)
            renderAll(grid: grid, highlights: highlights)
            return
        }

        let scrolls = damage.presentationScrolls
        let canRotateAll = scrolls.allSatisfy {
            $0.cols == 0 && $0.rows != 0 && $0.left == 0 && $0.right == cols
                && $0.top >= 0 && $0.bottom <= rows && $0.bottom > $0.top
        }

        var forcedFullRows = Set<Int>()
        if canRotateAll {
            for delta in scrolls {
                forcedFullRows.formUnion(rotateRows(for: delta))
            }
        } else if !scrolls.isEmpty {
            // A partial-column, horizontal, or conflicting scroll cannot be
            // represented by rotating full-row bitmaps. Repaint only each
            // scroll region's affected rows from the final model.
            for delta in scrolls {
                let top = max(0, min(rows, delta.top))
                let bottom = max(top, min(rows, delta.bottom))
                forcedFullRows.formUnion(top..<bottom)
            }
        }

        var spansByRow = damage.rowSpans
        for row in forcedFullRows where row >= 0 && row < rows {
            spansByRow[row] = [0..<cols]
        }
        for (row, spans) in spansByRow.sorted(by: { $0.key < $1.key }) {
            guard row >= 0, row < rows, !spans.isEmpty else { continue }
            repaint(
                row: row, spans: spans, grid: grid,
                highlights: highlights, into: rowBackings[row])
        }
    }

    /// Full re-render from the last applied model (font/scale changes).
    func renderFullFromLastState() {
        guard let grid = lastGrid, let highlights = lastHighlights else { return }
        rebuild(rows: grid.rows, cols: grid.cols)
        renderAll(grid: grid, highlights: highlights)
    }

    /// Explicit one-pass full render used by surface rebuilds. This avoids the
    /// former `apply` followed by `renderFullFromLastState` double raster.
    func renderFull(grid: Grid, highlights: HighlightTable) {
        lastGrid = grid
        lastHighlights = highlights
        if grid.rows != rows || grid.cols != cols || rowBackings.count != grid.rows {
            rebuild(rows: grid.rows, cols: grid.cols)
        }
        renderAll(grid: grid, highlights: highlights)
    }

    func setScale(_ newScale: CGFloat, rerender: Bool = true) {
        let clamped = max(1, newScale)
        guard clamped != scale else { return }
        scale = clamped
        if rerender {
            renderFullFromLastState()
        } else {
            // The caller will perform one explicit full render at the new
            // scale; invalidate old pixel-sized contexts without drawing.
            rowBackings.removeAll()
        }
    }

    /// Cached row revisions for the compositor hot path. Only a dirty row's
    /// `CGContext.makeImage()` runs; surviving rows return their prior image.
    func rowSnapshots() -> [RenderedRowSnapshot]? {
        guard rowBackings.count == rows else { return nil }
        var result: [RenderedRowSnapshot] = []
        result.reserveCapacity(rows)
        for backing in rowBackings {
            guard let snapshot = backing.snapshot() else { return nil }
            result.append(snapshot)
        }
        return result
    }

    func rowSnapshot(at row: Int) -> RenderedRowSnapshot? {
        guard rowBackings.indices.contains(row) else { return nil }
        return rowBackings[row].snapshot()
    }

    /// Compose a full image only for screenshots/tests/atomic consumers. The
    /// scrolling layer tree never calls this method.
    func image() -> CGImage? {
        guard rows > 0, cols > 0, let snapshots = rowSnapshots(),
            let context = Self.makeContext(
                width: Int(CGFloat(cols) * cellSize.width * scale),
                height: Int(CGFloat(rows) * cellSize.height * scale),
                scale: scale)
        else { return nil }

        context.saveGState()
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        for (row, snapshot) in snapshots.enumerated() {
            context.draw(snapshot.image, in: CGRect(
                x: 0,
                y: gridHeight - CGFloat(row + 1) * cellSize.height,
                width: CGFloat(cols) * cellSize.width,
                height: cellSize.height))
        }
        context.restoreGState()
        return context.makeImage()
    }

    // MARK: - Row storage

    private func rebuild(rows: Int, cols: Int) {
        self.rows = max(0, rows)
        self.cols = max(0, cols)
        rowBackings = (0..<self.rows).compactMap { _ in makeRowBacking() }
        if rowBackings.count != self.rows { rowBackings.removeAll() }
    }

    private func makeRowBacking() -> RowBacking? {
        guard cols > 0,
            let context = Self.makeContext(
                width: Int(CGFloat(cols) * cellSize.width * scale),
                height: Int(cellSize.height * scale), scale: scale)
        else { return nil }
        let backing = RowBacking(id: nextBackingID, context: context)
        nextBackingID &+= 1
        return backing
    }

    /// Positive rows move content up: destination r receives source r+rows.
    /// Returns the exposed destination rows that require full repaint.
    private func rotateRows(for delta: ScrollDelta) -> Set<Int> {
        let top = delta.top
        let bottom = delta.bottom
        let height = bottom - top
        let amount = delta.rows
        guard height > 0, amount != 0 else { return [] }

        let previous = Array(rowBackings[top..<bottom])
        let displacedCount = min(height, abs(amount))
        let displaced: ArraySlice<RowBacking>
        if amount > 0 {
            displaced = previous.prefix(displacedCount)
        } else {
            displaced = previous.suffix(displacedCount)
        }
        var displacedIndex = displaced.startIndex
        var exposed = Set<Int>()
        for destination in top..<bottom {
            let source = destination + amount
            if source >= top, source < bottom {
                rowBackings[destination] = previous[source - top]
            } else {
                // Recycle a row that just scrolled out. Any CGImage retained
                // by viewport history is immutable, so CGContext mutation
                // naturally takes Core Graphics' copy-on-write path.
                guard displacedIndex < displaced.endIndex else { continue }
                rowBackings[destination] = displaced[displacedIndex]
                displacedIndex = displaced.index(after: displacedIndex)
                exposed.insert(destination)
            }
        }
        return exposed
    }

    private func renderAll(grid: Grid, highlights: HighlightTable) {
        guard rowBackings.count == rows else { return }
        for row in 0..<rows {
            repaint(
                row: row, spans: [0..<cols], grid: grid,
                highlights: highlights, into: rowBackings[row])
        }
    }

    /// Repaint whole style runs that intersect damage. The row context uses
    /// local row zero, preserving the exact Core Text baseline and glyph path
    /// of the former full-grid renderer without retaining a full framebuffer.
    private func repaint(
        row: Int, spans: [Range<Int>], grid: Grid,
        highlights: HighlightTable, into backing: RowBacking
    ) {
        var runs = TextRasterizer.coalesce(grid.rowCells(row))
        let fonts = rasterizer.fonts
        let hasCompanion = fonts.symbolFont != nil
        if fonts.powerlineGlyphs, hasCompanion || fonts.forceSynthesis {
            runs = TextRasterizer.splitPowerlineRuns(
                runs, cells: grid.rowCells(row), fullPUA: hasCompanion)
        }
        if fonts.ligatures, hasCompanion || fonts.forceSynthesis {
            runs = TextRasterizer.splitLigatureRuns(runs, cells: grid.rowCells(row))
        }
        for run in runs {
            guard spans.contains(where: { $0.overlaps(run.colRange) }) else { continue }
            rasterizer.draw(
                run, row: 0, gridHeight: cellSize.height,
                into: backing.context, highlights: highlights)
        }
        backing.changed()
    }

    static func makeContext(width: Int, height: Int, scale: CGFloat) -> CGContext? {
        guard width > 0, height > 0,
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let ctx = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue)
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldSmoothFonts(false)
        return ctx
    }
}
