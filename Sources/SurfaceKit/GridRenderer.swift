import CoreGraphics
import GridKit

/// Per-grid Retina bitmap backing store (DESIGN §5). Applies one flush's
/// damage: scroll deltas replayed as blits IN RECORDED ORDER first, then
/// damaged row spans re-rasterized from the final model. `image()` snapshots
/// the store as a copy-on-write CGImage for the grid's CALayer contents.
final class GridRenderer {
    private(set) var scale: CGFloat
    private(set) var rows = 0
    private(set) var cols = 0
    private var ctx: CGContext?
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

    /// Apply one damaged-grid snapshot: blits, then span repaints.
    func apply(grid: Grid, damage: DamageMap, highlights: HighlightTable) {
        lastGrid = grid
        lastHighlights = highlights
        guard grid.rows > 0, grid.cols > 0 else { return }
        if grid.rows != rows || grid.cols != cols || ctx == nil {
            rows = grid.rows
            cols = grid.cols
            ctx = Self.makeContext(
                width: Int(CGFloat(cols) * cellSize.width * scale),
                height: Int(CGFloat(rows) * cellSize.height * scale),
                scale: scale)
            renderAll(grid: grid, highlights: highlights)
            return
        }
        guard let ctx else { return }
        for delta in damage.scrolls {
            blit(delta, into: ctx)
        }
        for (row, spans) in damage.rowSpans.sorted(by: { $0.key < $1.key }) {
            guard row >= 0, row < rows else { continue }
            repaint(row: row, spans: spans, grid: grid, highlights: highlights, into: ctx)
        }
    }

    /// Full re-render from the last applied model (font/scale changes).
    func renderFullFromLastState() {
        guard let grid = lastGrid, let highlights = lastHighlights else { return }
        rows = 0  // force context rebuild against current metrics/scale
        apply(grid: grid, damage: DamageMap(), highlights: highlights)
    }

    func setScale(_ newScale: CGFloat) {
        let clamped = max(1, newScale)
        guard clamped != scale else { return }
        scale = clamped
        renderFullFromLastState()
    }

    /// COW snapshot of the backing store.
    func image() -> CGImage? {
        ctx?.makeImage()
    }

    // MARK: - internals

    private func renderAll(grid: Grid, highlights: HighlightTable) {
        guard let ctx else { return }
        for row in 0..<rows {
            repaint(row: row, spans: [0..<cols], grid: grid, highlights: highlights, into: ctx)
        }
    }

    /// Repaint the style runs of `row` that intersect any dirty span. Whole
    /// runs are redrawn (never partial), so ligatures and wide glyphs can't
    /// tear at span edges; the overdraw is idempotent by construction.
    private func repaint(
        row: Int, spans: [Range<Int>], grid: Grid,
        highlights: HighlightTable, into ctx: CGContext
    ) {
        var runs = TextRasterizer.coalesce(grid.rowCells(row))
        if rasterizer.fonts.powerlineGlyphs {
            runs = TextRasterizer.splitPowerlineRuns(runs, cells: grid.rowCells(row))
        }
        for run in runs {
            guard spans.contains(where: { $0.overlaps(run.colRange) }) else { continue }
            rasterizer.draw(
                run, row: row, gridHeight: gridHeight, into: ctx, highlights: highlights)
        }
    }

    /// Replay one grid_scroll as a backing-store blit. The snapshot image is
    /// immutable, so overlapping src/dest regions are well-defined (the
    /// ping-pong of DESIGN §5 without a second live buffer).
    private func blit(_ delta: ScrollDelta, into ctx: CGContext) {
        // Surviving content: source rows/cols that remain visible after the shift.
        let srcRowLo = delta.top + max(delta.rows, 0)
        let srcRowHi = delta.bottom + min(delta.rows, 0)
        let srcColLo = delta.left + max(delta.cols, 0)
        let srcColHi = delta.right + min(delta.cols, 0)
        guard srcRowHi > srcRowLo, srcColHi > srcColLo else { return }
        guard let snapshot = ctx.makeImage() else { return }

        let cw = cellSize.width
        let ch = cellSize.height
        // Source rect in snapshot pixel space (top-left origin, y down).
        let srcPixels = CGRect(
            x: CGFloat(srcColLo) * cw * scale,
            y: CGFloat(srcRowLo) * ch * scale,
            width: CGFloat(srcColHi - srcColLo) * cw * scale,
            height: CGFloat(srcRowHi - srcRowLo) * ch * scale)
        guard let cropped = snapshot.cropping(to: srcPixels) else { return }

        // Destination rect in context point space (bottom-left origin, y up).
        let destRowLo = srcRowLo - delta.rows
        let destRect = CGRect(
            x: CGFloat(srcColLo - delta.cols) * cw,
            y: gridHeight - CGFloat(destRowLo + (srcRowHi - srcRowLo)) * ch,
            width: CGFloat(srcColHi - srcColLo) * cw,
            height: CGFloat(srcRowHi - srcRowLo) * ch)
        ctx.saveGState()
        ctx.interpolationQuality = .none
        ctx.draw(cropped, in: destRect)
        ctx.restoreGState()
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
