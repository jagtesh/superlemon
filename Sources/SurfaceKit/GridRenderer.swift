import CoreGraphics
import CoreVideo
import Darwin
import GridKit
import IOSurface

/// The object installed into a row CALayer. IOSurface is the production path:
/// Core Animation can import the shared BGRA storage directly instead of
/// synchronously color-converting/copying a CGImage during transaction commit.
enum RowLayerContents: @unchecked Sendable {
    case image(CGImage)
    case surface(IOSurface)

    var object: AnyObject {
        switch self {
        case .image(let image): image
        case .surface(let surface): surface
        }
    }
}

/// One pool allocation. The pool retains the IOSurface object but deliberately
/// does not increment its cross-process use count; a revision lease does that.
private final class RowSurfaceResource {
    let id: UInt64
    let surface: IOSurface
    let context: CGContext
    var nextRevision: UInt64 = 0

    init?(id: UInt64, width: Int, height: Int, scale: CGFloat) {
        guard width > 0, height > 0,
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        let bytesPerRow = ((width * 4 + 63) / 64) * 64
        guard let surface = IOSurface(properties: [
            .width: width,
            .height: height,
            .bytesPerElement: 4,
            .bytesPerRow: bytesPerRow,
            .allocSize: bytesPerRow * height,
            .pixelFormat: kCVPixelFormatType_32BGRA,
        ]),
            let context = CGContext(
                data: surface.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: surface.bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }

        if let serialized = colorSpace.copyPropertyList() {
            IOSurfaceSetValue(surface, kIOSurfaceColorSpace, serialized)
        }
        context.scaleBy(x: scale, y: scale)
        context.setAllowsAntialiasing(true)
        context.setShouldSmoothFonts(false)
        self.id = id
        self.surface = surface
        self.context = context
    }
}

/// Keeps a published surface unavailable to the renderer's pool while the
/// authoritative renderer, row history, or layer binding can still reference
/// it. IOSurfaceIsInUse additionally covers compositor work after our last
/// reference has gone away.
private final class RowSurfaceLease: @unchecked Sendable {
    let resource: RowSurfaceResource
    let revision: UInt64

    init(resource: RowSurfaceResource) {
        self.resource = resource
        resource.nextRevision &+= 1
        revision = resource.nextRevision
        IOSurfaceIncrementUseCount(resource.surface)
    }

    deinit { IOSurfaceDecrementUseCount(resource.surface) }
}

private final class RowSurfacePool {
    private(set) var resources: [RowSurfaceResource] = []
    let capacity: Int
    let width: Int
    let height: Int
    let scale: CGFloat
    private var nextID: UInt64

    init(width: Int, height: Int, scale: CGFloat, capacity: Int, nextID: UInt64) {
        self.width = width
        self.height = height
        self.scale = scale
        self.capacity = max(0, capacity)
        self.nextID = nextID
    }

    func checkout() -> RowSurfaceLease? {
        if let available = resources.first(where: {
            !IOSurfaceIsInUse($0.surface)
        }) {
            return RowSurfaceLease(resource: available)
        }
        guard resources.count < capacity,
            let resource = RowSurfaceResource(
                id: nextID, width: width, height: height, scale: scale)
        else { return nil }
        nextID &+= 1
        resources.append(resource)
        return RowSurfaceLease(resource: resource)
    }

    var nextBackingID: UInt64 { nextID }
}

/// An immutable row-sized image revision. Surviving rows keep the same image
/// and token across vertical scrolls, so SurfaceKit can rotate layer bindings
/// without asking Core Animation to prepare another full-grid image.
struct RenderedRowSnapshot: @unchecked Sendable {
    let image: CGImage
    let backingID: UInt64
    let revision: UInt64
    let layerContents: RowLayerContents
    /// Retains the revision's IOSurface use-count lease for as long as row
    /// history can bind `layerContents`.
    let layerContentsRetention: AnyObject?

    init(
        image: CGImage, backingID: UInt64, revision: UInt64,
        layerContents: RowLayerContents? = nil,
        layerContentsRetention: AnyObject? = nil
    ) {
        self.image = image
        self.backingID = backingID
        self.revision = revision
        self.layerContents = layerContents ?? .image(image)
        self.layerContentsRetention = layerContentsRetention
    }

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
        let revision: UInt64
        let surfaceLease: RowSurfaceLease?
        var cachedImage: CGImage?
        var isPublished = false

        init(
            id: UInt64, revision: UInt64, context: CGContext,
            surfaceLease: RowSurfaceLease? = nil
        ) {
            self.id = id
            self.revision = revision
            self.context = context
            self.surfaceLease = surfaceLease
        }

        func snapshot() -> RenderedRowSnapshot? {
            if cachedImage == nil {
                if let surface = surfaceLease?.resource.surface {
                    guard surface.lock(options: [.readOnly], seed: nil) == 0 else {
                        return nil
                    }
                    cachedImage = context.makeImage()
                    _ = surface.unlock(options: [.readOnly], seed: nil)
                } else {
                    cachedImage = context.makeImage()
                }
            }
            guard let cachedImage else { return nil }
            isPublished = true
            return RenderedRowSnapshot(
                image: cachedImage, backingID: id, revision: revision,
                layerContents: surfaceLease.map {
                    .surface($0.resource.surface)
                } ?? .image(cachedImage),
                layerContentsRetention: surfaceLease)
        }

        func withWritableContext(_ body: (CGContext) -> Void) -> Bool {
            guard let surface = surfaceLease?.resource.surface else {
                body(context)
                return true
            }
            guard surface.lock(options: [], seed: nil) == 0 else { return false }
            body(context)
            _ = surface.unlock(options: [], seed: nil)
            return true
        }
    }

    private(set) var scale: CGFloat
    private(set) var rows = 0
    private(set) var cols = 0
    private var rowBackings: [RowBacking] = []
    private var nextBackingID: UInt64 = 1
    private var nextBitmapRevision: UInt64 = 1
    private var surfacePool: RowSurfacePool?
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

    var rowSurfacePoolCount: Int { surfacePool?.resources.count ?? 0 }
    var rowSurfacePoolCapacity: Int { surfacePool?.capacity ?? 0 }

    /// Apply one damaged-grid snapshot. Compatible vertical scrolls rotate
    /// row references in wire order, then final-model damage repaints rows.
    func apply(grid: Grid, damage: DamageMap, highlights: HighlightTable) {
        lastGrid = grid
        lastHighlights = highlights
        guard grid.rows > 0, grid.cols > 0 else {
            rows = max(0, grid.rows)
            cols = max(0, grid.cols)
            rowBackings.removeAll()
            surfacePool = nil
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
            let coversWholeRow = spans.contains {
                $0.lowerBound <= 0 && $0.upperBound >= cols
            }
            if rowBackings[row].isPublished {
                let old = rowBackings[row]
                guard let replacement = makeRowBacking(
                    preserving: coversWholeRow ? nil : old)
                else { continue }
                rowBackings[row] = replacement
            }
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
        // Published IOSurfaces are immutable. A full render therefore starts
        // with a fresh bounded pool generation even when geometry is stable.
        rebuild(rows: grid.rows, cols: grid.cols)
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
            surfacePool = nil
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
        let width = Int(CGFloat(self.cols) * cellSize.width * scale)
        let height = Int(cellSize.height * scale)
        surfacePool = RowSurfacePool(
            width: width, height: height, scale: scale,
            // Current rows + two-history viewports + one compositor-flight
            // viewport. Saturation falls back to immutable CGImage storage.
            capacity: self.rows * 4, nextID: nextBackingID)
        rowBackings = (0..<self.rows).compactMap { _ in makeRowBacking() }
        if rowBackings.count != self.rows { rowBackings.removeAll() }
    }

    private func makeRowBacking(preserving old: RowBacking? = nil) -> RowBacking? {
        guard cols > 0 else { return nil }
        let backing: RowBacking
        if let lease = surfacePool?.checkout() {
            nextBackingID = max(nextBackingID, surfacePool?.nextBackingID ?? nextBackingID)
            backing = RowBacking(
                id: lease.resource.id, revision: lease.revision,
                context: lease.resource.context, surfaceLease: lease)
        } else {
            guard
            let context = Self.makeContext(
                width: Int(CGFloat(cols) * cellSize.width * scale),
                height: Int(cellSize.height * scale), scale: scale)
            else { return nil }
            backing = RowBacking(
                id: nextBackingID, revision: nextBitmapRevision,
                context: context)
            nextBackingID &+= 1
            nextBitmapRevision &+= 1
        }
        if let old, !copyPixels(from: old, into: backing) { return nil }
        return backing
    }

    private func copyPixels(from old: RowBacking, into new: RowBacking) -> Bool {
        if let oldSurface = old.surfaceLease?.resource.surface,
            let newSurface = new.surfaceLease?.resource.surface,
            oldSurface !== newSurface,
            oldSurface.bytesPerRow == newSurface.bytesPerRow,
            oldSurface.height == newSurface.height
        {
            guard oldSurface.lock(options: [.readOnly], seed: nil) == 0 else {
                return false
            }
            defer { _ = oldSurface.unlock(options: [.readOnly], seed: nil) }
            guard newSurface.lock(options: [], seed: nil) == 0 else { return false }
            memcpy(
                newSurface.baseAddress, oldSurface.baseAddress,
                min(newSurface.allocationSize, oldSurface.allocationSize))
            _ = newSurface.unlock(options: [], seed: nil)
            return true
        }

        guard let image = old.snapshot()?.image else { return false }
        return new.withWritableContext { context in
            context.saveGState()
            context.setBlendMode(.copy)
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(
                x: 0, y: 0,
                width: CGFloat(cols) * cellSize.width,
                height: cellSize.height))
            context.restoreGState()
        }
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
        var exposed = Set<Int>()
        for destination in top..<bottom {
            let source = destination + amount
            if source >= top, source < bottom {
                rowBackings[destination] = previous[source - top]
            } else {
                // The displaced revision can still be visible in scrollback;
                // never mutate it. Checkout a compositor-safe surface (or the
                // bounded CGImage fallback when all surfaces are in flight).
                guard let replacement = makeRowBacking() else { continue }
                rowBackings[destination] = replacement
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
        _ = backing.withWritableContext { context in
            for run in runs {
                guard spans.contains(where: { $0.overlaps(run.colRange) }) else {
                    continue
                }
                rasterizer.draw(
                    run, row: 0, gridHeight: cellSize.height,
                    into: context, highlights: highlights)
            }
        }
    }

    static func makeContext(width: Int, height: Int, scale: CGFloat) -> CGContext? {
        guard width > 0, height > 0,
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let ctx = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                // Core Animation's native 8-bit texture layout on macOS is
                // BGRA. Keeping row tiles in that physical byte order avoids
                // a channel-swizzle/copy when a newly exposed CGImage is
                // prepared for the compositor. The image remains tagged sRGB,
                // so Neovim's 8-bit colors retain their managed appearance.
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldSmoothFonts(false)
        return ctx
    }
}
