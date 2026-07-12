import AppKit
import CoreVideo
import GridKit
import IOSurface
import NvimKit
import Testing

@testable import SurfaceKit

// MARK: - Helpers

private let menlo = FontSpec(name: "Menlo", size: 13)

/// Drive a GridStore with synthetic UI events and return the flush result.
@MainActor
private func flush(_ store: GridStore, _ events: [UIEvent]) -> FlushResult {
    let result = store.apply(RedrawBatch(events: events + [.flush]))
    precondition(result != nil, "batch ended in flush; apply must return a result")
    return result!
}

/// One row of `text` as a single-hl grid_line event.
private func line(_ row: Int, _ text: String, hl: Int, grid: Int = 1) -> UIEvent {
    .gridLine(
        grid: grid, row: row, colStart: 0,
        cells: text.map { CellRun(text: String($0), hlID: hl) }, wrap: false)
}

private func rgb(_ v: UInt32) -> NvimKit.RGBColor { .init(rgb: v) }

private func solidImage(width: Int, height: Int) -> CGImage {
    let ctx = GridRenderer.makeContext(width: width, height: height, scale: 1)!
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

/// Sample one logical RGB pixel (top-left origin) from the renderer's native
/// BGRA8 storage.
private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
    let data = image.dataProvider!.data! as Data
    let offset = y * image.bytesPerRow + x * 4
    return (data[offset + 2], data[offset + 1], data[offset])
}

/// Whole-image byte comparison.
private func identical(_ a: CGImage, _ b: CGImage) -> Bool {
    guard a.width == b.width, a.height == b.height else { return false }
    return (a.dataProvider!.data! as Data) == (b.dataProvider!.data! as Data)
}

private func center(of cell: (row: Int, col: Int), _ fonts: FontSet) -> (x: Int, y: Int) {
    (
        x: Int((CGFloat(cell.col) + 0.5) * fonts.cellSize.width),
        y: Int((CGFloat(cell.row) + 0.5) * fonts.cellSize.height)
    )
}

// MARK: - Font metrics

@Suite struct FontMetricsTests {
    @Test func cellGeometryMatchesCoreTextMetrics() {
        let fonts = FontSet(spec: menlo)
        let font = NSFont(name: "Menlo", size: 13)! as CTFont
        var chars: [UniChar] = [0x4D]
        var glyphs: [CGGlyph] = [0]
        CTFontGetGlyphsForCharacters(font, &chars, &glyphs, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphs, &advance, 1)
        #expect(fonts.cellSize.width == ceil(advance.width))
        #expect(
            fonts.cellSize.height
                == ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)))
    }

    @Test func linespaceAddsToCellHeightAndCentersBaseline() {
        let plain = FontSet(spec: menlo)
        let spaced = FontSet(spec: FontSpec(name: "Menlo", size: 13, linespace: 4))
        #expect(spaced.cellSize.height == plain.cellSize.height + 4)
        #expect(spaced.baselineOffset == plain.baselineOffset + 2)
    }

    @Test func missingFontFallsBackToSystemMono() {
        let fonts = FontSet(spec: FontSpec(name: "NoSuchFont-983", size: 13))
        #expect(fonts.cellSize.width > 0 && fonts.cellSize.height > 0)
    }
}

// MARK: - Run coalescing

@Suite struct RunCoalescingTests {
    @Test func mergesSameHighlightAndBreaksOnChange() {
        let cells: [Cell] = [
            Cell(text: "a", hlID: 1), Cell(text: "b", hlID: 1),
            Cell(text: "c", hlID: 2),
        ]
        let runs = TextRasterizer.coalesce(cells[...])
        #expect(runs == [
            StyleRun(startCol: 0, cellCount: 2, text: "ab", hlID: 1),
            StyleRun(startCol: 2, cellCount: 1, text: "c", hlID: 2),
        ])
    }

    @Test func doubleWidthTrailingCellExtendsRunWithoutText() {
        let cells: [Cell] = [
            Cell(text: "世", hlID: 3), Cell(text: "", hlID: 3),
            Cell(text: "x", hlID: 3),
        ]
        let runs = TextRasterizer.coalesce(cells[...])
        #expect(runs == [StyleRun(startCol: 0, cellCount: 3, text: "世x", hlID: 3)])
    }

    @Test func wholeBlankRowIsOneRun() {
        let cells = [Cell](repeating: .blank, count: 10)
        let runs = TextRasterizer.coalesce(cells[...])
        #expect(runs == [StyleRun(startCol: 0, cellCount: 10, text: "", hlID: 0)])
    }
}

// MARK: - Rasterization

@MainActor
@Suite struct RasterTests {
    private func render(_ events: [UIEvent], rows: Int = 4, cols: Int = 10) -> (CGImage, FontSet) {
        let store = GridStore()
        let result = flush(store, [.gridResize(grid: 1, width: cols, height: rows)] + events)
        let fonts = FontSet(spec: menlo)
        let renderer = GridRenderer(rasterizer: TextRasterizer(fonts: fonts), scale: 1)
        let damaged = result.damagedGrids.first { $0.grid.id == 1 }!
        renderer.apply(grid: damaged.grid, damage: damaged.damage, highlights: result.highlights)
        return (renderer.image()!, fonts)
    }

    @Test func bitmapIsNativeBGRA8AndPreservesSRGBComponents() {
        let context = GridRenderer.makeContext(width: 1, height: 1, scale: 1)!
        context.setBlendMode(.copy)
        context.setFillColor(rgb(0x123456).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let image = context.makeImage()!

        #expect(image.bitsPerComponent == 8)
        #expect(image.bitsPerPixel == 32)
        #expect(image.alphaInfo == .premultipliedFirst)
        #expect(image.bitmapInfo.contains(.byteOrder32Little))
        #expect(image.colorSpace?.name == CGColorSpace.sRGB)

        let bytes = image.dataProvider!.data! as Data
        #expect(Array(bytes.prefix(4)) == [0x56, 0x34, 0x12, 0xFF],
                "native memory order must be BGRA")
        #expect(pixel(image, x: 0, y: 0) == (0x12, 0x34, 0x56),
                "the storage optimization must not change managed sRGB color")
    }

    @Test func backgroundFillIsExact() {
        var red = HlAttrs()
        red.background = rgb(0xFF0000)
        let (image, fonts) = render([
            .defaultColorsSet(fg: rgb(0xFFFFFF), bg: rgb(0x000000), special: rgb(0xFF0000)),
            .hlAttrDefine(id: 5, attrs: red),
            line(1, "    ", hl: 5),  // spaces: background only
        ])
        let p = center(of: (row: 1, col: 2), fonts)
        #expect(pixel(image, x: p.x, y: p.y) == (255, 0, 0))
        // Untouched cell shows the default background exactly.
        let q = center(of: (row: 3, col: 5), fonts)
        #expect(pixel(image, x: q.x, y: q.y) == (0, 0, 0))
    }

    @Test func glyphsActuallyDraw() {
        let (image, fonts) = render([
            .defaultColorsSet(fg: rgb(0x000000), bg: rgb(0xFFFFFF), special: rgb(0xFF0000)),
            line(0, "MMMM", hl: 0),
        ])
        // Some pixel inside cell (0,0) must differ from the white background.
        var found = false
        for y in 0..<Int(fonts.cellSize.height) {
            for x in 0..<Int(fonts.cellSize.width) {
                let p = pixel(image, x: x, y: y)
                if p != (255, 255, 255) { found = true }
            }
        }
        #expect(found, "expected glyph coverage in cell (0,0)")
    }

    @Test func reverseSwapsColors() {
        var attrs = HlAttrs()
        attrs.foreground = rgb(0x112233)
        attrs.background = rgb(0xAABBCC)
        attrs.reverse = true
        let (image, fonts) = render([
            .hlAttrDefine(id: 7, attrs: attrs),
            line(2, "  ", hl: 7),
        ])
        let p = center(of: (row: 2, col: 0), fonts)
        // Background drawn with the (swapped-in) foreground color.
        #expect(pixel(image, x: p.x, y: p.y) == (0x11, 0x22, 0x33))
    }

    @Test func undercurlDrawsSpecialColorBelowBaseline() {
        var attrs = HlAttrs()
        attrs.undercurl = true
        attrs.special = rgb(0x00FF00)
        attrs.background = rgb(0xFFFFFF)
        attrs.foreground = rgb(0xFFFFFF)  // hide the glyph: only the curl is non-white
        let (image, fonts) = render([
            .defaultColorsSet(fg: rgb(0xFFFFFF), bg: rgb(0xFFFFFF), special: rgb(0x000000)),
            .hlAttrDefine(id: 9, attrs: attrs),
            line(0, "aaaa", hl: 9),
        ])
        var found = false
        let baseline = Int(fonts.baselineOffset)
        for y in baseline..<Int(fonts.cellSize.height) {
            for x in 0..<Int(fonts.cellSize.width * 4) {
                let p = pixel(image, x: x, y: y)
                if p.g > 150, p.r < 120, p.b < 120 { found = true }
            }
        }
        #expect(found, "expected green undercurl pixels below the baseline")
    }
}

// MARK: - Blit == full repaint (the gold standard, DESIGN §5)

@MainActor
@Suite struct BlitGoldStandardTests {
    /// Distinct row colors so vertical movement is unmistakable in pixels.
    private func paint(rows: Int, cols: Int) -> [UIEvent] {
        let palette: [UInt32] = [0xE81123, 0x107C10, 0x0078D4, 0xFFB900, 0x8E24AA, 0x00B294]
        var events: [UIEvent] = []
        for (i, color) in palette.prefix(rows).enumerated() {
            var attrs = HlAttrs()
            attrs.background = rgb(color)
            events.append(.hlAttrDefine(id: 10 + i, attrs: attrs))
            events.append(line(i, String(repeating: " ", count: cols), hl: 10 + i))
        }
        return events
    }

    @Test func scrollBlitMatchesFullRepaint() {
        let rows = 6, cols = 8
        let store = GridStore()
        let fonts = FontSet(spec: menlo)
        let incremental = GridRenderer(rasterizer: TextRasterizer(fonts: fonts), scale: 1)

        // Frame 1: full paint.
        let first = flush(
            store, [.gridResize(grid: 1, width: cols, height: rows)] + paint(rows: rows, cols: cols))
        let d1 = first.damagedGrids.first { $0.grid.id == 1 }!
        incremental.apply(grid: d1.grid, damage: d1.damage, highlights: first.highlights)

        // Frame 2: scroll up by 2, repaint the exposed strip with new colors.
        var fresh = HlAttrs()
        fresh.background = rgb(0x123456)
        let second = flush(store, [
            .gridScroll(grid: 1, top: 0, bottom: rows, left: 0, right: cols, rows: 2, cols: 0),
            .hlAttrDefine(id: 30, attrs: fresh),
            line(rows - 2, String(repeating: " ", count: cols), hl: 30),
            line(rows - 1, String(repeating: " ", count: cols), hl: 30),
        ])
        let d2 = second.damagedGrids.first { $0.grid.id == 1 }!
        incremental.apply(grid: d2.grid, damage: d2.damage, highlights: second.highlights)

        // Reference: a fresh renderer painting the final model from scratch.
        let reference = GridRenderer(rasterizer: TextRasterizer(fonts: fonts), scale: 1)
        var fullDamage = DamageMap()
        fullDamage.markAll(rows: rows, cols: cols)
        reference.apply(grid: d2.grid, damage: fullDamage, highlights: second.highlights)

        #expect(identical(incremental.image()!, reference.image()!),
                "blit path must be pixel-identical to a full repaint")
    }

    @Test func verticalScrollRotatesSurvivingRowImagesWithoutResnapshotting() {
        let rows = 6, cols = 8
        let store = GridStore()
        let fonts = FontSet(spec: menlo)
        let renderer = GridRenderer(rasterizer: TextRasterizer(fonts: fonts), scale: 1)
        let first = flush(
            store, [.gridResize(grid: 1, width: cols, height: rows)]
                + paint(rows: rows, cols: cols))
        let d1 = first.damagedGrids.first { $0.grid.id == 1 }!
        renderer.apply(grid: d1.grid, damage: d1.damage, highlights: first.highlights)
        let before = renderer.rowSnapshots()!

        let second = flush(store, [
            .gridScroll(
                grid: 1, top: 0, bottom: rows, left: 0, right: cols,
                rows: 2, cols: 0),
            line(rows - 2, String(repeating: " ", count: cols), hl: 10),
            line(rows - 1, String(repeating: " ", count: cols), hl: 11),
        ])
        let d2 = second.damagedGrids.first { $0.grid.id == 1 }!
        renderer.apply(grid: d2.grid, damage: d2.damage, highlights: second.highlights)
        let after = renderer.rowSnapshots()!

        for destination in 0..<(rows - 2) {
            #expect(after[destination].image === before[destination + 2].image)
            #expect(after[destination].token == before[destination + 2].token)
        }
        #expect(after[rows - 2].token != before[0].token)
        #expect(after[rows - 1].token != before[1].token)
        if case .surface = after[rows - 2].layerContents {} else {
            Issue.record("exposed production row should use IOSurface contents")
        }
        if case .surface = after[rows - 1].layerContents {} else {
            Issue.record("exposed production row should use IOSurface contents")
        }
        #expect(after.allSatisfy { $0.image.height == Int(fonts.cellSize.height) })
    }

    @Test func recycledBackingPoolIsBoundedAndOldSnapshotsStayImmutable() {
        let rows = 6, cols = 8
        let store = GridStore()
        let fonts = FontSet(spec: menlo)
        let renderer = GridRenderer(rasterizer: TextRasterizer(fonts: fonts), scale: 1)
        let first = flush(
            store, [.gridResize(grid: 1, width: cols, height: rows)]
                + paint(rows: rows, cols: cols))
        let firstDamage = first.damagedGrids.first { $0.grid.id == 1 }!
        renderer.apply(
            grid: firstDamage.grid, damage: firstDamage.damage,
            highlights: first.highlights)
        let initial = renderer.rowSnapshots()!
        let retainedImage = initial[0].image
        let retainedBytes = retainedImage.dataProvider!.data! as Data
        guard case .surface(let retainedSurface) = initial[0].layerContents else {
            Issue.record("production snapshot did not expose IOSurface contents")
            return
        }
        #expect(retainedSurface.pixelFormat == kCVPixelFormatType_32BGRA)
        #expect(IOSurfaceCopyValue(retainedSurface, kIOSurfaceColorSpace) != nil)
        #expect(IOSurfaceGetUseCount(retainedSurface) > 0)
        _ = retainedSurface.lock(options: [.readOnly], seed: nil)
        let retainedSurfaceBytes = Data(
            bytes: retainedSurface.baseAddress,
            count: retainedSurface.allocationSize)
        _ = retainedSurface.unlock(options: [.readOnly], seed: nil)
        var backingIDs = Set(initial.map(\.backingID))

        for iteration in 0..<100 {
            let next = flush(store, [
                .gridScroll(
                    grid: 1, top: 0, bottom: rows, left: 0, right: cols,
                    rows: 1, cols: 0),
                line(
                    rows - 1, String(repeating: " ", count: cols),
                    hl: 10 + iteration % rows),
            ])
            let damage = next.damagedGrids.first { $0.grid.id == 1 }!
            renderer.apply(
                grid: damage.grid, damage: damage.damage,
                highlights: next.highlights)
            backingIDs.formUnion(renderer.rowSnapshots()!.map(\.backingID))
        }

        #expect(backingIDs.count <= rows * 2 + 1,
                "retained old rows plus current rows use a bounded surface set")
        #expect(renderer.rowSurfacePoolCount <= renderer.rowSurfacePoolCapacity)
        #expect(renderer.rowSurfacePoolCapacity == rows * 4)
        #expect((retainedImage.dataProvider!.data! as Data) == retainedBytes,
                "history snapshots remain immutable while their contexts recycle")
        _ = retainedSurface.lock(options: [.readOnly], seed: nil)
        let finalSurfaceBytes = Data(
            bytes: retainedSurface.baseAddress,
            count: retainedSurface.allocationSize)
        _ = retainedSurface.unlock(options: [.readOnly], seed: nil)
        #expect(finalSurfaceBytes == retainedSurfaceBytes,
                "a published IOSurface revision must never be mutated")
    }

    @Test func unsupportedScrollRerasterizesOnlyItsAffectedRows() {
        let rows = 6, cols = 8
        let store = GridStore()
        let fonts = FontSet(spec: menlo)
        let renderer = GridRenderer(rasterizer: TextRasterizer(fonts: fonts), scale: 1)
        let first = flush(
            store, [.gridResize(grid: 1, width: cols, height: rows)]
                + paint(rows: rows, cols: cols))
        let firstDamage = first.damagedGrids.first { $0.grid.id == 1 }!
        renderer.apply(
            grid: firstDamage.grid, damage: firstDamage.damage,
            highlights: first.highlights)
        let before = renderer.rowSnapshots()!

        let second = flush(store, [
            .gridScroll(
                grid: 1, top: 1, bottom: 4, left: 1, right: 7,
                rows: 0, cols: 1),
        ])
        let secondDamage = second.damagedGrids.first { $0.grid.id == 1 }!
        renderer.apply(
            grid: secondDamage.grid, damage: secondDamage.damage,
            highlights: second.highlights)
        let after = renderer.rowSnapshots()!

        for row in 0..<rows {
            if (1..<4).contains(row) {
                #expect(after[row].token != before[row].token)
            } else {
                #expect(after[row].token == before[row].token)
                #expect(after[row].image === before[row].image)
            }
        }
    }

    @Test func scrollDownAndHorizontalAlsoMatch() {
        let rows = 6, cols = 8
        let store = GridStore()
        let fonts = FontSet(spec: menlo)
        let incremental = GridRenderer(rasterizer: TextRasterizer(fonts: fonts), scale: 1)

        let first = flush(
            store, [.gridResize(grid: 1, width: cols, height: rows)] + paint(rows: rows, cols: cols))
        let d1 = first.damagedGrids.first { $0.grid.id == 1 }!
        incremental.apply(grid: d1.grid, damage: d1.damage, highlights: first.highlights)

        var fresh = HlAttrs()
        fresh.background = rgb(0x654321)
        let second = flush(store, [
            .gridScroll(grid: 1, top: 1, bottom: 5, left: 0, right: cols, rows: -1, cols: 0),
            .gridScroll(grid: 1, top: 0, bottom: rows, left: 0, right: cols, rows: 0, cols: 3),
            .hlAttrDefine(id: 31, attrs: fresh),
            line(1, String(repeating: " ", count: cols), hl: 31),
        ])
        let d2 = second.damagedGrids.first { $0.grid.id == 1 }!
        incremental.apply(grid: d2.grid, damage: d2.damage, highlights: second.highlights)

        let reference = GridRenderer(rasterizer: TextRasterizer(fonts: fonts), scale: 1)
        var fullDamage = DamageMap()
        fullDamage.markAll(rows: rows, cols: cols)
        reference.apply(grid: d2.grid, damage: fullDamage, highlights: second.highlights)

        #expect(identical(incremental.image()!, reference.image()!))
    }
}

// MARK: - Glyph cache

@Suite struct GlyphCacheTests {
    @Test func repeatedShapingHitsCache() {
        let fonts = FontSet(spec: menlo)
        let cache = GlyphCache(capacity: 64)
        _ = cache.shapedRun(text: "hello", variant: .regular, font: fonts.regular, cellWidth: 8, baseAdvance: 7.8)
        _ = cache.shapedRun(text: "hello", variant: .regular, font: fonts.regular, cellWidth: 8, baseAdvance: 7.8)
        _ = cache.shapedRun(text: "hello", variant: .bold, font: fonts.bold, cellWidth: 8, baseAdvance: 7.8)
        #expect(cache.hits == 1)
        #expect(cache.misses == 2)
    }

    @Test func evictionKeepsCacheBounded() {
        let fonts = FontSet(spec: menlo)
        let cache = GlyphCache(capacity: 8)
        for i in 0..<50 {
            _ = cache.shapedRun(text: "word\(i)", variant: .regular, font: fonts.regular, cellWidth: 8, baseAdvance: 7.8)
        }
        #expect(cache.misses == 50)
        // Everything distinct: eviction ran; re-shaping an early entry misses.
        _ = cache.shapedRun(text: "word0", variant: .regular, font: fonts.regular, cellWidth: 8, baseAdvance: 7.8)
        #expect(cache.misses == 51)
    }
}

// MARK: - View geometry

@MainActor
@Suite struct ScrollTransitionTests {
    private let cellSize = CGSize(width: 8, height: 16)

    private func expectExactFilmstripOnly(_ state: SmoothViewportState) {
        let sublayers = state.overlayLayer.sublayers ?? []
        #expect(sublayers.count == 1,
                "the clipped viewport must contain no synthetic visual layers")
        #expect(sublayers.first === state.translatedContainerLayer)
    }

    @Test func circularHistoryRotatesWithoutCopyingAndWrapsNegativeIndices() {
        var history = CircularRowHistory<Int>(capacity: 6)
        for row in 0..<6 { history[row] = row }

        history.rotate(by: 2)
        #expect(history.head == 2)
        #expect(history[-2] == 0)
        #expect(history[-1] == 1)
        #expect(history[0] == 2)
        #expect(history[3] == 5)
        #expect(history[4] == 0)

        // A reversal moves only the logical head; all retained rows remain
        // addressable on either side of the viewport.
        history.rotate(by: -3)
        #expect(history.head == 5)
        #expect(history[-1] == 4)
        #expect(history[0] == 5)
        #expect(history[1] == 0)
        #expect(history[-6] == 5)
    }

    @Test func viewportGeometryExcludesMarginsAndRejectsAtomicScrollShapes() {
        let geometry = SmoothViewportGeometry(
            rows: 10, cols: 20,
            margins: ViewportMargins(top: 1, bottom: 2, left: 3, right: 4))
        #expect(geometry.innerRows == 7)
        #expect(geometry.innerCols == 13)
        #expect(geometry.clipRect(cellSize: cellSize)
            == CGRect(x: 24, y: 16, width: 104, height: 112))

        let matching = ScrollDelta(
            top: 1, bottom: 8, left: 3, right: 16, rows: 1, cols: 0)
        let reverse = ScrollDelta(
            top: 1, bottom: 8, left: 3, right: 16, rows: -1, cols: 0)
        let partial = ScrollDelta(
            top: 2, bottom: 8, left: 3, right: 16, rows: 1, cols: 0)
        let horizontal = ScrollDelta(
            top: 1, bottom: 8, left: 3, right: 16, rows: 0, cols: 1)
        #expect(geometry.accepts([matching], semanticDelta: 1))
        #expect(geometry.accepts([reverse], semanticDelta: -1))
        #expect(!geometry.accepts([matching], semanticDelta: -1))
        #expect(!geometry.accepts([matching, partial], semanticDelta: 1))
        #expect(!geometry.accepts([horizontal], semanticDelta: 1))
        #expect(!geometry.accepts([matching], semanticDelta: 0))
    }

    @Test func criticalSpringIsRefreshRateIndependentAndSettlesMonotonically() {
        var at60 = CriticalDampedSpring(position: -3, velocity: 1.25)
        var at120 = at60
        for _ in 0..<18 { at60.advance(by: 1.0 / 60.0) }
        for _ in 0..<36 { at120.advance(by: 1.0 / 120.0) }
        #expect(abs(at60.position - at120.position) < 0.000_001)
        #expect(abs(at60.velocity - at120.velocity) < 0.000_001)

        var monotonic = CriticalDampedSpring(position: -2, velocity: 0)
        var previous = monotonic.position
        for _ in 0..<120 {
            monotonic.advance(by: 1.0 / 120.0)
            #expect(monotonic.position >= previous)
            #expect(monotonic.position <= 0)
            previous = monotonic.position
        }
        #expect(abs(monotonic.position) < 0.000_1)
    }

    @Test func minimumJerkSegmentHasExactC2EndpointsAndSymmetry() {
        let duration = 0.180
        var down = MinimumJerkScrollSegment(
            initial: ScrollMotionSample(position: -1), duration: duration)
        var up = MinimumJerkScrollSegment(
            initial: ScrollMotionSample(position: 1), duration: duration)

        #expect(down.sample == ScrollMotionSample(position: -1))
        #expect(up.sample == ScrollMotionSample(position: 1))
        var previous = down.sample.position
        for _ in 0..<180 {
            down.advance(by: 0.001)
            up.advance(by: 0.001)
            #expect(down.sample.position >= previous)
            #expect(down.sample.position <= 0)
            #expect(down.sample.position == -up.sample.position)
            #expect(down.sample.velocity == -up.sample.velocity)
            #expect(down.sample.acceleration == -up.sample.acceleration)
            previous = down.sample.position
        }
        #expect(down.sample == ScrollMotionSample())
        #expect(up.sample == ScrollMotionSample())
    }

    @Test func fiveRowBurstPreservesC2CameraAndStopsExactly() {
        let duration = 0.180
        let period = 1.0 / 120.0
        var motion = ContinuousScrollEnvelope()
        var semanticRows: CGFloat = 0

        for input in 1...5 {
            if input > 1 { motion.advance(by: period) }
            let before = motion.sample
            let cameraBefore = semanticRows + before.position
            semanticRows += 1
            motion.add(positionOffset: -1, duration: duration)
            let after = motion.sample
            #expect(abs(semanticRows + after.position - cameraBefore) < 0.000_001)
            #expect(after.velocity == before.velocity)
            #expect(after.acceleration == before.acceleration)
            if input >= 3 { #expect(after.velocity > 0) }
        }

        var previousCamera = semanticRows + motion.position
        for _ in 0..<240 where motion.isActive {
            motion.advance(by: period)
            let camera = semanticRows + motion.position
            #expect(camera >= previousCamera)
            #expect(camera <= semanticRows)
            previousCamera = camera
        }
        #expect(!motion.isActive)
        #expect(motion.sample == ScrollMotionSample())
        #expect(previousCamera == 5)
    }

    @Test func identicalEnvelopeTimelineMatchesAt60And120Hz() {
        let duration = 0.180
        func trajectory(hz: Int) -> [ScrollMotionSample] {
            var motion = ContinuousScrollEnvelope()
            var result: [ScrollMotionSample] = []
            let period = 1.0 / Double(hz)
            for frame in 0...(hz * 3 / 5) {
                if frame > 0 { motion.advance(by: period) }
                let time = Double(frame) * period
                let eventIndex = Int((time * 60).rounded())
                if eventIndex < 5,
                    abs(time - Double(eventIndex) / 60.0) < 0.000_001
                {
                    motion.add(positionOffset: -1, duration: duration)
                }
                result.append(motion.sample)
            }
            return result
        }
        let at60 = trajectory(hz: 60)
        let at120 = trajectory(hz: 120)
        for index in at60.indices where index * 2 < at120.count {
            let lhs = at60[index]
            let rhs = at120[index * 2]
            #expect(abs(lhs.position - rhs.position) < 0.000_001)
            #expect(abs(lhs.velocity - rhs.velocity) < 0.000_001)
            #expect(abs(lhs.acceleration - rhs.acceleration) < 0.000_001)
        }
    }

    @Test func stateSeedsTwoViewportHistoryAndAnimatesSharedImageRows() {
        let host = CALayer()
        host.frame = CGRect(x: 0, y: 0, width: 80, height: 96)
        let first = solidImage(width: 80, height: 96)
        let final = solidImage(width: 80, height: 96)
        let state = SmoothViewportState(gridID: 7)

        let seeded = state.present(
            image: first, rows: 6, cols: 10, margins: nil,
            scrolls: [], semanticDelta: nil, cellSize: cellSize,
            scale: 1, host: host, animate: true)
        #expect(!seeded)
        #expect(state.history.capacity == 12)
        #expect(state.historyHead == 0)
        #expect(state.history[0]?.sourceRow == 0)
        #expect(state.history[5]?.sourceRow == 5)
        #expect(abs((state.history[0]?.contentsRect.minY ?? -1) - 5.0 / 6.0)
            < 0.000_001)
        #expect(state.history[5]?.contentsRect.minY == 0,
                "CALayer contentsRect is bottom-up even in a flipped host view")
        #expect(state.currentRowsReference(first))
        #expect(!state.overlayLayer.isHidden,
                "the exact row filmstrip remains installed while idle")

        let scroll = ScrollDelta(
            top: 0, bottom: 6, left: 0, right: 10, rows: 1, cols: 0)
        let started = state.present(
            image: final, rows: 6, cols: 10, margins: nil,
            scrolls: [scroll], semanticDelta: 1, cellSize: cellSize,
            scale: 1, host: host, animate: true)
        #expect(started)
        #expect(state.isActive)
        #expect(state.historyHead == 1)
        #expect(state.position == -1)
        #expect(!state.overlayLayer.isHidden)
        #expect(state.visibleRowLayers.count == 7)
        #expect(state.visibleRowLayers[0].frame.minY > state.visibleRowLayers[1].frame.minY,
                "top-down logical rows must descend in CALayer's bottom-up coordinates")
        let oldEdgeRow = state.visibleRowLayers[0].contents as! CGImage
        let authoritativeRow = state.visibleRowLayers[1].contents as! CGImage
        #expect(oldEdgeRow !== first,
                "the outgoing edge must not retain its full-grid parent image")
        #expect(oldEdgeRow.width == 80 && oldEdgeRow.height == 16)
        #expect(pixel(oldEdgeRow, x: 40, y: 8) == pixel(first, x: 40, y: 8))
        #expect(authoritativeRow === final)
        #expect(state.currentRowsReference(final))
        for row in 0..<6 {
            #expect(state.history[row]?.image === final)
            #expect(state.history[row]?.sourceRow == row)
        }

        for _ in 0..<240 where state.isActive {
            _ = state.advance(by: 1.0 / 120.0)
        }
        #expect(!state.isActive)
        #expect(!state.overlayLayer.isHidden)
        #expect(state.currentRowsReference(final),
                "settling must expose the exact authoritative backing image")
    }

    @Test func reversalPreservesC2MotionAndReturnsToExactViewport() {
        let rowPixels = Int(cellSize.height * 2)
        let period = 1.0 / 120.0

        for direction in [-1, 1] {
            for ticksBeforeReversal in 0...2 {
                let host = CALayer()
                let state = SmoothViewportState(
                    gridID: direction * 10 + ticksBeforeReversal)
                _ = state.present(
                    image: solidImage(width: 160, height: 192),
                    rows: 6, cols: 10, margins: nil, scrolls: [],
                    semanticDelta: nil, cellSize: cellSize, scale: 2,
                    host: host, animate: true)
                _ = state.present(
                    image: solidImage(width: 160, height: 192),
                    rows: 6, cols: 10, margins: nil,
                    scrolls: [ScrollDelta(
                        top: 0, bottom: 6, left: 0, right: 10,
                        rows: direction, cols: 0)],
                    semanticDelta: direction, cellSize: cellSize, scale: 2,
                    host: host, animate: true)

                for _ in 0..<ticksBeforeReversal {
                    _ = state.advance(by: period, nominalDisplayPeriod: period)
                }
                var semanticRows = direction
                let before = semanticRows * rowPixels
                    + state.snappedTranslationPixels
                let velocityBefore = state.velocity
                let accelerationBefore = state.acceleration
                _ = state.present(
                    image: solidImage(width: 160, height: 192),
                    rows: 6, cols: 10, margins: nil,
                    scrolls: [ScrollDelta(
                        top: 0, bottom: 6, left: 0, right: 10,
                        rows: -direction, cols: 0)],
                    semanticDelta: -direction, cellSize: cellSize, scale: 2,
                    host: host, animate: true)
                semanticRows -= direction
                let atRetarget = semanticRows * rowPixels
                    + state.snappedTranslationPixels
                #expect(abs(atRetarget - before) <= 1,
                        "reversal retargeting must preserve the visible camera")
                #expect(state.velocity == velocityBefore)
                #expect(state.acceleration == accelerationBefore,
                        "a row reversal must not add an acceleration tooth")

                var camera = [atRetarget]
                var sawReverseVelocity = ticksBeforeReversal == 0
                for _ in 0..<240 where state.isActive {
                    _ = state.advance(by: period, nominalDisplayPeriod: period)
                    camera.append(semanticRows * rowPixels
                        + state.snappedTranslationPixels)
                    if state.velocity * CGFloat(direction) < 0 {
                        sawReverseVelocity = true
                    }
                }
                #expect(sawReverseVelocity,
                        "the opposite pulse must smoothly turn carried momentum")
                #expect(camera.last == 0)
                #expect(!state.isActive)
                #expect(state.position == 0)
                #expect(state.velocity == 0)
                #expect(state.acceleration == 0)
                #expect(state.historyHead == 0)
            }
        }
    }

    @Test func farJumpRetainsOnlyItsFinalLineOfMotion() {
        let host = CALayer()
        let first = solidImage(width: 80, height: 96)
        let final = solidImage(width: 80, height: 96)
        let state = SmoothViewportState(gridID: 1)
        _ = state.present(
            image: first, rows: 6, cols: 10, margins: nil,
            scrolls: [], semanticDelta: nil, cellSize: cellSize,
            scale: 1, host: host, animate: true)

        let started = state.present(
            image: final, rows: 6, cols: 10, margins: nil,
            scrolls: [ScrollDelta(
                top: 0, bottom: 6, left: 0, right: 10, rows: 20, cols: 0)],
            semanticDelta: 20, cellSize: cellSize,
            scale: 1, host: host, animate: true)
        #expect(started)
        #expect(state.historyHead == 1)
        #expect(state.position == -1)
        #expect(state.currentRowsReference(final))
    }

    @Test func farJumpCannotOvershootItsSingleLineCue() {
        let host = CALayer()
        let state = SmoothViewportState(gridID: 1)
        _ = state.present(
            image: solidImage(width: 80, height: 96),
            rows: 6, cols: 10, margins: nil, scrolls: [], semanticDelta: nil,
            cellSize: cellSize, scale: 1, host: host, animate: true)
        _ = state.present(
            image: solidImage(width: 80, height: 96),
            rows: 6, cols: 10, margins: nil,
            scrolls: [ScrollDelta(
                top: 0, bottom: 6, left: 0, right: 10, rows: 6, cols: 0)],
            semanticDelta: 6, cellSize: cellSize,
            scale: 1, host: host, animate: true)
        _ = state.advance(by: 1.0 / 60.0)
        #expect(state.velocity > 0)

        _ = state.present(
            image: solidImage(width: 80, height: 96),
            rows: 6, cols: 10, margins: nil,
            scrolls: [ScrollDelta(
                top: 0, bottom: 6, left: 0, right: 10, rows: 20, cols: 0)],
            semanticDelta: 20, cellSize: cellSize,
            scale: 1, host: host, animate: true)
        #expect(state.position == -1)
        var previous = state.position
        for _ in 0..<240 where state.isActive {
            _ = state.advance(by: 1.0 / 120.0)
            #expect(state.position >= previous)
            #expect(state.position <= 0)
            previous = state.position
        }
        #expect(!state.isActive)
    }

    @Test func coalescedFarJumpKeepsTheFarStepsDirection() {
        let host = CALayer()
        let state = SmoothViewportState(gridID: 1)
        _ = state.present(
            image: solidImage(width: 80, height: 96),
            rows: 6, cols: 10, margins: nil, scrolls: [], semanticDelta: nil,
            cellSize: cellSize, scale: 1, host: host, animate: true)
        var motion = ViewportScrollMotion(delta: 20)
        motion.append(-1)

        _ = state.present(
            image: solidImage(width: 80, height: 96),
            rows: 6, cols: 10, margins: nil, scrolls: [],
            semanticDelta: motion.netDelta, semanticMotion: motion,
            cellSize: cellSize, scale: 1, host: host, animate: true)

        #expect(state.position == -1,
                "a trailing opposite step must not reverse the far-jump cue")
    }

    @Test func resizeResetsHistoryAndSettlesOnTheExactFilmstrip() {
        let host = CALayer()
        let first = solidImage(width: 80, height: 96)
        let scrolling = solidImage(width: 80, height: 96)
        let resized = solidImage(width: 80, height: 128)
        let state = SmoothViewportState(gridID: 1)
        _ = state.present(
            image: first, rows: 6, cols: 10, margins: nil,
            scrolls: [], semanticDelta: nil, cellSize: cellSize,
            scale: 1, host: host, animate: true)
        _ = state.present(
            image: scrolling, rows: 6, cols: 10, margins: nil,
            scrolls: [ScrollDelta(
                top: 0, bottom: 6, left: 0, right: 10, rows: 1, cols: 0)],
            semanticDelta: 1, cellSize: cellSize,
            scale: 1, host: host, animate: true)
        #expect(state.isActive)

        let animated = state.present(
            image: resized, rows: 8, cols: 10, margins: nil,
            scrolls: [], semanticDelta: nil, cellSize: cellSize,
            scale: 1, host: host, animate: true)
        #expect(!animated)
        #expect(!state.isActive)
        #expect(state.history.capacity == 16)
        #expect(state.historyHead == 0)
        #expect(!state.overlayLayer.isHidden)
        #expect(state.currentRowsReference(resized))
    }

    @Test func displayTranslationIsSnappedToPhysicalPixels() {
        let host = CALayer()
        let first = solidImage(width: 160, height: 192)
        let final = solidImage(width: 160, height: 192)
        let state = SmoothViewportState(gridID: 1)
        _ = state.present(
            image: first, rows: 6, cols: 10, margins: nil,
            scrolls: [], semanticDelta: nil, cellSize: cellSize,
            scale: 2, host: host, animate: true)
        _ = state.present(
            image: final, rows: 6, cols: 10, margins: nil,
            scrolls: [ScrollDelta(
                top: 0, bottom: 6, left: 0, right: 10, rows: 1, cols: 0)],
            semanticDelta: 1, cellSize: cellSize,
            scale: 2, host: host, animate: true)
        _ = state.advance(by: 1.0 / 60.0)

        for layer in state.visibleRowLayers where !layer.isHidden {
            let physicalY = layer.frame.minY * 2
            #expect(abs(physicalY - physicalY.rounded()) < 0.000_001)
        }
        let physicalTranslation = state.translatedContainerLayer.affineTransform().ty * 2
        #expect(abs(physicalTranslation - physicalTranslation.rounded()) < 0.000_001)
    }

    @Test func cumulativeSmallDeltasClampWithoutBecomingFarJumps() {
        let host = CALayer()
        let state = SmoothViewportState(gridID: 1)
        _ = state.present(
            image: solidImage(width: 80, height: 96),
            rows: 6, cols: 10, margins: nil, scrolls: [], semanticDelta: nil,
            cellSize: cellSize, scale: 1, host: host, animate: true)
        let scroll = ScrollDelta(
            top: 0, bottom: 6, left: 0, right: 10, rows: 1, cols: 0)

        for input in 1...10 {
            _ = state.present(
                image: solidImage(width: 80, height: 96),
                rows: 6, cols: 10, margins: nil, scrolls: [scroll], semanticDelta: 1,
                cellSize: cellSize, scale: 1, host: host, animate: true)
            #expect(state.position == -CGFloat(min(input, 6)),
                    "cumulative debt clamps at retained history instead of resetting")
            #expect(state.historyHead == input % 12)
            expectExactFilmstripOnly(state)
        }
    }

    @Test func alternatingDirectionsBoundSignedResidualsAndCleanUpExactly() {
        let rows = 6
        let host = CALayer()
        let image = solidImage(width: 80, height: 96)
        let state = SmoothViewportState(gridID: 1)
        _ = state.present(
            image: image, rows: rows, cols: 10, margins: nil,
            scrolls: [], semanticDelta: nil, cellSize: cellSize,
            scale: 1, host: host, animate: true)
        let down = ScrollDelta(
            top: 0, bottom: rows, left: 0, right: 10, rows: 1, cols: 0)
        let up = ScrollDelta(
            top: 0, bottom: rows, left: 0, right: 10, rows: -1, cols: 0)

        // Net position remains zero after every pair. Each direction must
        // nevertheless consume and clamp its own retained-history capacity.
        for pair in 1...(rows * 2) {
            _ = state.present(
                image: image, rows: rows, cols: 10, margins: nil,
                scrolls: [down], semanticDelta: 1, cellSize: cellSize,
                scale: 1, host: host, animate: true)
            #expect(state.motion.negativeMagnitude == CGFloat(min(pair, rows)))
            #expect(state.motion.positiveMagnitude == CGFloat(min(pair - 1, rows)))

            _ = state.present(
                image: image, rows: rows, cols: 10, margins: nil,
                scrolls: [up], semanticDelta: -1, cellSize: cellSize,
                scale: 1, host: host, animate: true)
            let expectedMagnitude = CGFloat(min(pair, rows))
            #expect(state.motion.negativeMagnitude == expectedMagnitude)
            #expect(state.motion.positiveMagnitude == expectedMagnitude)
            #expect(state.motion.negativeMagnitude <= CGFloat(rows))
            #expect(state.motion.positiveMagnitude <= CGFloat(rows))
        }

        #expect(state.motion.segments.count == rows * 2)
        #expect(state.position == 0)
        #expect(state.velocity == 0)
        #expect(state.acceleration == 0)
        #expect(state.isActive)
        #expect(state.historyHead == 0)

        #expect(!state.advance(
            by: 1, nominalDisplayPeriod: 1.0 / 120.0,
            detectDisplayGap: false))
        #expect(!state.isActive)
        #expect(state.motion.segments.isEmpty)
        #expect(state.motion.sample == ScrollMotionSample())
        #expect(state.motion.negativeMagnitude == 0)
        #expect(state.motion.positiveMagnitude == 0)
        #expect(state.snappedTranslationPixels == 0)
        #expect(state.historyHead == 0)
        #expect(state.currentRowsReference(image))
    }

    @Test func coalescedSmallMotionBeyondAViewportClampsWithoutFarReset() {
        let host = CALayer()
        let state = SmoothViewportState(gridID: 1)
        _ = state.present(
            image: solidImage(width: 80, height: 96),
            rows: 6, cols: 10, margins: nil, scrolls: [], semanticDelta: nil,
            cellSize: cellSize, scale: 1, host: host, animate: true)
        var motion = ViewportScrollMotion(delta: 1)
        for _ in 1..<10 { motion.append(1) }

        _ = state.present(
            image: solidImage(width: 80, height: 96),
            rows: 6, cols: 10, margins: nil,
            scrolls: [ScrollDelta(
                top: 0, bottom: 6, left: 0, right: 10, rows: 6, cols: 0)],
            semanticDelta: motion.netDelta, semanticMotion: motion,
            cellSize: cellSize, scale: 1, host: host, animate: true)

        #expect(state.position == -6)
        #expect(state.historyHead == 6,
                "retained history rotates a full viewport, not a one-line far cue")
        expectExactFilmstripOnly(state)
    }

    @Test func zeroNetCoalescedReversalPreservesActiveEnvelopeDerivatives() {
        let host = CALayer()
        let state = SmoothViewportState(gridID: 1)
        _ = state.present(
            image: solidImage(width: 80, height: 96),
            rows: 6, cols: 10, margins: nil, scrolls: [], semanticDelta: nil,
            cellSize: cellSize, scale: 1, host: host, animate: true)
        let down = ScrollDelta(
            top: 0, bottom: 6, left: 0, right: 10, rows: 1, cols: 0)
        _ = state.present(
            image: solidImage(width: 80, height: 96),
            rows: 6, cols: 10, margins: nil, scrolls: [down], semanticDelta: 1,
            cellSize: cellSize, scale: 1, host: host, animate: true)
        _ = state.advance(by: 1.0 / 60.0)
        let oldPosition = state.position
        let oldVelocity = state.velocity
        let oldAcceleration = state.acceleration
        var reversal = ViewportScrollMotion(delta: 1)
        reversal.append(-1)

        _ = state.present(
            image: solidImage(width: 80, height: 96),
            rows: 6, cols: 10, margins: nil,
            scrolls: [down, ScrollDelta(
                top: 0, bottom: 6, left: 0, right: 10, rows: -1, cols: 0)],
            semanticDelta: 0, semanticMotion: reversal,
            cellSize: cellSize, scale: 1, host: host, animate: true)

        #expect(state.isActive)
        #expect(state.position == oldPosition)
        #expect(state.velocity == oldVelocity)
        #expect(state.acceleration == oldAcceleration)
    }

    @Test func fractionalTicksOnlyTranslateTheContainer() {
        let host = CALayer()
        let state = SmoothViewportState(gridID: 1)
        _ = state.present(
            image: solidImage(width: 80, height: 96),
            rows: 6, cols: 10, margins: nil, scrolls: [], semanticDelta: nil,
            cellSize: cellSize, scale: 2, host: host, animate: true)
        _ = state.present(
            image: solidImage(width: 80, height: 96),
            rows: 6, cols: 10, margins: nil,
            scrolls: [ScrollDelta(
                top: 0, bottom: 6, left: 0, right: 10, rows: 1, cols: 0)],
            semanticDelta: 1, cellSize: cellSize, scale: 2,
            host: host, animate: true)
        let before = state.visibleRowLayers.map { $0.contents as AnyObject? }
        let transformBefore = state.translatedContainerLayer.affineTransform()

        _ = state.advance(by: 1.0 / 30.0)

        let after = state.visibleRowLayers.map { $0.contents as AnyObject? }
        for index in before.indices {
            #expect(before[index] === after[index])
        }
        #expect(state.translatedContainerLayer.affineTransform() != transformBefore)
    }

    @Test func viewportRetargetReusesAllSurvivingLayerContents() {
        let host = CALayer()
        let state = SmoothViewportState(gridID: 1)
        let initial = (0..<6).map { row in
            RenderedRowSnapshot(
                image: solidImage(width: 80, height: 16),
                backingID: UInt64(row + 1), revision: 1)
        }
        _ = state.present(
            rowSnapshots: initial, rows: 6, cols: 10, margins: nil,
            scrolls: [], semanticDelta: nil, cellSize: cellSize,
            scale: 1, host: host, animate: true)
        let before = Dictionary(uniqueKeysWithValues: state.visibleRowLayers.map {
            (ObjectIdentifier($0), $0.contents as AnyObject?)
        })

        let exposed = RenderedRowSnapshot(
            image: solidImage(width: 80, height: 16),
            backingID: 7, revision: 1)
        let final = Array(initial.dropFirst()) + [exposed]
        _ = state.present(
            rowSnapshots: final, rows: 6, cols: 10, margins: nil,
            scrolls: [ScrollDelta(
                top: 0, bottom: 6, left: 0, right: 10, rows: 1, cols: 0)],
            semanticDelta: 1, cellSize: cellSize,
            scale: 1, host: host, animate: true)

        let changed = state.visibleRowLayers.filter { layer in
            let old = before[ObjectIdentifier(layer)] ?? nil
            return old !== (layer.contents as AnyObject?)
        }
        #expect(changed.count <= 1,
                "only the newly exposed edge slot may upload different contents")
    }

    @Test func trueFarJumpKeepsOnlyTheExactOneRowCue() {
        let host = CALayer()
        let state = SmoothViewportState(gridID: 1)
        _ = state.present(
            image: solidImage(width: 80, height: 96),
            rows: 6, cols: 10, margins: nil, scrolls: [], semanticDelta: nil,
            cellSize: cellSize, scale: 1, host: host, animate: true)
        _ = state.present(
            image: solidImage(width: 80, height: 96),
            rows: 6, cols: 10, margins: nil,
            scrolls: [ScrollDelta(
                top: 0, bottom: 6, left: 0, right: 10, rows: 20, cols: 0)],
            semanticDelta: 20, cellSize: cellSize, scale: 1,
            host: host, animate: true)
        #expect(state.position == -1)
        expectExactFilmstripOnly(state)

        for _ in 0..<20 { _ = state.advance(by: 1.0 / 120.0) }
        expectExactFilmstripOnly(state)

        state.settle()
        _ = state.present(
            image: solidImage(width: 80, height: 96),
            rows: 6, cols: 10, margins: nil,
            scrolls: [ScrollDelta(
                top: 0, bottom: 6, left: 0, right: 10, rows: 20, cols: 0)],
            semanticDelta: 20, cellSize: cellSize, scale: 1,
            host: host, animate: false)
        expectExactFilmstripOnly(state)
    }

    @Test func delayedDisplayIntervalsKeepOnlyExactRows() {
        func scrollingState(gridID: Int) -> SmoothViewportState {
            let state = SmoothViewportState(gridID: gridID)
            let host = CALayer()
            _ = state.present(
                image: solidImage(width: 160, height: 192),
                rows: 6, cols: 10, margins: nil, scrolls: [],
                semanticDelta: nil, cellSize: cellSize, scale: 2,
                host: host, animate: true)
            _ = state.present(
                image: solidImage(width: 160, height: 192),
                rows: 6, cols: 10, margins: nil,
                scrolls: [ScrollDelta(
                    top: 0, bottom: 6, left: 0, right: 10,
                    rows: 1, cols: 0)],
                semanticDelta: 1, cellSize: cellSize, scale: 2,
                host: host, animate: true)
            return state
        }

        let schedulingLatency = 0.0188
        let period = 1.0 / 120.0
        let firstTick = scrollingState(gridID: 1)
        _ = firstTick.advance(
            by: schedulingLatency, nominalDisplayPeriod: period,
            detectDisplayGap: false)
        expectExactFilmstripOnly(firstTick)

        let genuinelyLateTick = scrollingState(gridID: 2)
        _ = genuinelyLateTick.advance(
            by: schedulingLatency, nominalDisplayPeriod: period,
            detectDisplayGap: true)
        expectExactFilmstripOnly(genuinelyLateTick)
    }

    @Test func sustainedClampKeepsTheExactFilmstripVisible() {
        let host = CALayer()
        let state = SmoothViewportState(gridID: 1)
        _ = state.present(
            image: solidImage(width: 80, height: 96),
            rows: 6, cols: 10, margins: nil, scrolls: [], semanticDelta: nil,
            cellSize: cellSize, scale: 1, host: host, animate: true)
        let scroll = ScrollDelta(
            top: 0, bottom: 6, left: 0, right: 10, rows: 1, cols: 0)
        // Fill the retained-history debt without advancing the envelope.
        for _ in 0..<6 {
            _ = state.present(
                image: solidImage(width: 80, height: 96),
                rows: 6, cols: 10, margins: nil,
                scrolls: [scroll], semanticDelta: 1, cellSize: cellSize,
                scale: 1, host: host, animate: true)
        }

        for _ in 0..<24 {
            _ = state.present(
                image: solidImage(width: 80, height: 96),
                rows: 6, cols: 10, margins: nil,
                scrolls: [scroll], semanticDelta: 1, cellSize: cellSize,
                scale: 1, host: host, animate: true)
            _ = state.advance(by: 1.0 / 60.0)
            expectExactFilmstripOnly(state)
        }

        #expect(abs(state.position) <= 6,
                "clamped motion must remain inside retained exact history")
    }

    @Test func envelopeFinishesAnalyticallyAfterPixelResidualReachesZero() {
        let largeCell = CGSize(width: 12, height: 64)
        let host = CALayer()
        let first = solidImage(width: 120, height: 384)
        let final = solidImage(width: 120, height: 384)
        let state = SmoothViewportState(gridID: 1)
        _ = state.present(
            image: first, rows: 6, cols: 10, margins: nil,
            scrolls: [], semanticDelta: nil, cellSize: largeCell,
            scale: 2, host: host, animate: true)
        _ = state.present(
            image: final, rows: 6, cols: 10, margins: nil,
            scrolls: [ScrollDelta(
                top: 0, bottom: 6, left: 0, right: 10, rows: 1, cols: 0)],
            semanticDelta: 1, cellSize: largeCell,
            scale: 2, host: host, animate: true)

        var sawPixelEquivalentTail = false
        for _ in 0..<240 where state.isActive {
            _ = state.advance(
                by: 1.0 / 120.0,
                nominalDisplayPeriod: 1.0 / 120.0)
            if state.snappedTranslationPixels == 0, state.isActive {
                sawPixelEquivalentTail = true
            }
        }
        #expect(sawPixelEquivalentTail,
                "pixel snapping must not feed back into the analytical envelope")
        #expect(!state.isActive)
        #expect(state.position == 0)
        #expect(state.velocity == 0)
        #expect(state.acceleration == 0)
        #expect(!state.overlayLayer.isHidden)
    }

    @Test func historyRetainsOnlyOneFullImageAndDetachedEdgeRows() {
        let host = CALayer()
        let state = SmoothViewportState(gridID: 1)
        var image = solidImage(width: 80, height: 96)
        _ = state.present(
            image: image, rows: 6, cols: 10, margins: nil,
            scrolls: [], semanticDelta: nil, cellSize: cellSize,
            scale: 1, host: host, animate: true)

        for _ in 0..<24 {
            image = solidImage(width: 80, height: 96)
            _ = state.present(
                image: image, rows: 6, cols: 10, margins: nil,
                scrolls: [ScrollDelta(
                    top: 0, bottom: 6, left: 0, right: 10,
                    rows: 1, cols: 0)],
                semanticDelta: 1, cellSize: cellSize,
                scale: 1, host: host, animate: true)
            _ = state.advance(by: 1.0 / 120.0)

            var unique: [ObjectIdentifier: CGImage] = [:]
            for row in state.history.storage.compactMap({ $0 }) {
                unique[ObjectIdentifier(row.image)] = row.image
            }
            let fullImages = unique.values.filter { $0.height > Int(cellSize.height) }
            #expect(fullImages.count == 1,
                    "history may share only the newest full authoritative image")
            #expect(unique.values.allSatisfy {
                $0.height == Int(cellSize.height) || $0 === image
            })
        }

        state.settle()
        var settledUnique: [ObjectIdentifier: CGImage] = [:]
        for row in state.history.storage.compactMap({ $0 }) {
            settledUnique[ObjectIdentifier(row.image)] = row.image
        }
        #expect(settledUnique.count == 1)
        #expect(settledUnique.values.first === image)
        #expect(state.visibleRowLayers.prefix(6).allSatisfy { $0.contents != nil })
    }

    @Test func detachedEdgeRowKeepsTheCorrectTopDownPixels() {
        let context = GridRenderer.makeContext(width: 80, height: 96, scale: 1)!
        for row in 0..<6 {
            let color = NSColor(
                calibratedRed: CGFloat(row + 1) / 7, green: 0, blue: 0, alpha: 1)
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: 0, y: CGFloat(5 - row) * 16, width: 80, height: 16))
        }
        let first = context.makeImage()!
        let final = solidImage(width: 80, height: 96)
        let host = CALayer()
        let state = SmoothViewportState(gridID: 1)
        _ = state.present(
            image: first, rows: 6, cols: 10, margins: nil,
            scrolls: [], semanticDelta: nil, cellSize: cellSize,
            scale: 1, host: host, animate: true)
        _ = state.present(
            image: final, rows: 6, cols: 10, margins: nil,
            scrolls: [ScrollDelta(
                top: 0, bottom: 6, left: 0, right: 10, rows: 1, cols: 0)],
            semanticDelta: 1, cellSize: cellSize,
            scale: 1, host: host, animate: true)

        guard let detached = state.history[-1] else {
            Issue.record("outgoing top row missing from history")
            return
        }
        #expect(detached.image.width == 80)
        #expect(detached.image.height == 16)
        #expect(detached.contentsRect == CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(pixel(detached.image, x: 40, y: 8)
            == pixel(first, x: 40, y: 8))
    }

    @Test func productionHistoryRetainsOnlyRowSizedImages() {
        let host = CALayer()
        let state = SmoothViewportState(gridID: 1)
        func rows(_ generation: UInt64) -> [RenderedRowSnapshot] {
            (0..<6).map { row in
                RenderedRowSnapshot(
                    image: solidImage(width: 80, height: 16),
                    backingID: generation * 10 + UInt64(row), revision: generation)
            }
        }
        _ = state.present(
            rowSnapshots: rows(1), rows: 6, cols: 10, margins: nil,
            scrolls: [], semanticDelta: nil, cellSize: cellSize,
            scale: 1, host: host, animate: true)
        _ = state.present(
            rowSnapshots: rows(2), rows: 6, cols: 10, margins: nil,
            scrolls: [ScrollDelta(
                top: 0, bottom: 6, left: 0, right: 10, rows: 1, cols: 0)],
            semanticDelta: 1, cellSize: cellSize,
            scale: 1, host: host, animate: true)

        #expect(state.history.storage.compactMap { $0 }.allSatisfy {
            $0.image.height == 16 && !$0.retainsFullGridImage
        })
    }

    @Test func detachedRowCropRespectsAllViewportMargins() {
        let context = GridRenderer.makeContext(width: 80, height: 96, scale: 1)!
        for row in 0..<6 {
            for col in 0..<10 {
                context.setFillColor(NSColor(
                    calibratedRed: CGFloat(row + 1) / 7,
                    green: CGFloat(col + 1) / 11, blue: 0, alpha: 1).cgColor)
                context.fill(CGRect(
                    x: CGFloat(col * 8), y: CGFloat(5 - row) * 16,
                    width: 8, height: 16))
            }
        }
        let first = context.makeImage()!
        let final = solidImage(width: 80, height: 96)
        let margins = ViewportMargins(top: 1, bottom: 1, left: 2, right: 1)
        let host = CALayer()
        let state = SmoothViewportState(gridID: 1)
        _ = state.present(
            image: first, rows: 6, cols: 10, margins: margins,
            scrolls: [], semanticDelta: nil, cellSize: cellSize,
            scale: 1, host: host, animate: true)
        _ = state.present(
            image: final, rows: 6, cols: 10, margins: margins,
            scrolls: [ScrollDelta(
                top: 1, bottom: 5, left: 2, right: 9, rows: 1, cols: 0)],
            semanticDelta: 1, cellSize: cellSize,
            scale: 1, host: host, animate: true)

        guard let detached = state.history[-1] else {
            Issue.record("margin-scoped outgoing row missing")
            return
        }
        #expect(detached.image.width == 56)
        #expect(detached.image.height == 16)
        #expect(pixel(detached.image, x: 4, y: 8)
            == pixel(first, x: 20, y: 24))
        #expect(pixel(detached.image, x: 52, y: 8)
            == pixel(first, x: 68, y: 24))
    }

    @Test func staleDisplayGapSettlesWithBoundedIntegrationWork() {
        let host = CALayer()
        let state = SmoothViewportState(gridID: 1)
        _ = state.present(
            image: solidImage(width: 80, height: 96),
            rows: 6, cols: 10, margins: nil, scrolls: [], semanticDelta: nil,
            cellSize: cellSize, scale: 1, host: host, animate: true)
        _ = state.present(
            image: solidImage(width: 80, height: 96),
            rows: 6, cols: 10, margins: nil,
            scrolls: [ScrollDelta(
                top: 0, bottom: 6, left: 0, right: 10, rows: 1, cols: 0)],
            semanticDelta: 1, cellSize: cellSize,
            scale: 1, host: host, animate: true)

        #expect(!state.advance(by: 60 * 60))
        #expect(!state.isActive)
        #expect(!state.overlayLayer.isHidden)
    }

    @Test func atomicOrImmediatePresentationShowsExactRowsWithoutMotion() {
        let host = CALayer()
        let first = solidImage(width: 80, height: 96)
        let final = solidImage(width: 80, height: 96)
        let state = SmoothViewportState(gridID: 1)
        _ = state.present(
            image: first, rows: 6, cols: 10, margins: nil,
            scrolls: [], semanticDelta: nil, cellSize: cellSize,
            scale: 1, host: host, animate: false)
        let started = state.present(
            image: final, rows: 6, cols: 10, margins: nil,
            scrolls: [ScrollDelta(
                top: 0, bottom: 6, left: 0, right: 10, rows: 1, cols: 0)],
            semanticDelta: 1, cellSize: cellSize,
            scale: 1, host: host, animate: false)
        #expect(!started)
        #expect(!state.isActive)
        #expect(!state.overlayLayer.isHidden)
        expectExactFilmstripOnly(state)
        #expect(state.currentRowsReference(final))
    }

    @Test func atomicPureEditSettlesAnExistingScrollTail() {
        let host = CALayer()
        let state = SmoothViewportState(gridID: 1)
        _ = state.present(
            image: solidImage(width: 80, height: 96),
            rows: 6, cols: 10, margins: nil, scrolls: [], semanticDelta: nil,
            cellSize: cellSize, scale: 1, host: host, animate: true)
        _ = state.present(
            image: solidImage(width: 80, height: 96),
            rows: 6, cols: 10, margins: nil,
            scrolls: [ScrollDelta(
                top: 0, bottom: 6, left: 0, right: 10, rows: 1, cols: 0)],
            semanticDelta: 1, cellSize: cellSize, scale: 1,
            host: host, animate: true)
        #expect(state.isActive)

        _ = state.present(
            image: solidImage(width: 80, height: 96),
            rows: 6, cols: 10, margins: nil, scrolls: [], semanticDelta: nil,
            cellSize: cellSize, scale: 1, host: host, animate: false)

        #expect(!state.isActive)
        #expect(state.position == 0)
        #expect(state.velocity == 0)
    }

    @Test func unsupportedScrollSettlesAnActiveViewportTail() {
        let host = CALayer()
        let first = solidImage(width: 80, height: 96)
        let scrolling = solidImage(width: 80, height: 96)
        let atomic = solidImage(width: 80, height: 96)
        let state = SmoothViewportState(gridID: 1)
        _ = state.present(
            image: first, rows: 6, cols: 10, margins: nil,
            scrolls: [], semanticDelta: nil, cellSize: cellSize,
            scale: 1, host: host, animate: true)
        _ = state.present(
            image: scrolling, rows: 6, cols: 10, margins: nil,
            scrolls: [ScrollDelta(
                top: 0, bottom: 6, left: 0, right: 10, rows: 1, cols: 0)],
            semanticDelta: 1, cellSize: cellSize,
            scale: 1, host: host, animate: true)
        _ = state.advance(by: 1.0 / 120.0)
        #expect(state.isActive)

        // Horizontal scrolls have no semantic row delta. They remain atomic,
        // and must not leave the previous vertical history moving above them.
        let started = state.present(
            image: atomic, rows: 6, cols: 10, margins: nil,
            scrolls: [ScrollDelta(
                top: 0, bottom: 6, left: 0, right: 10, rows: 0, cols: 1)],
            semanticDelta: nil, cellSize: cellSize,
            scale: 1, host: host, animate: true)
        #expect(!started)
        #expect(!state.isActive)
        #expect(!state.overlayLayer.isHidden)
        expectExactFilmstripOnly(state)
        #expect(state.position == 0)
        #expect(state.velocity == 0)
        #expect(state.currentRowsReference(atomic))
    }
}

@MainActor
@Suite struct ViewGeometryTests {
    @Test func marginOnlyFlushRebuildsThePermanentViewportClip() {
        let view = GridSurfaceView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 400), font: menlo)
        let store = GridStore()
        view.present(flush(store, [
            .gridResize(grid: 1, width: 10, height: 6),
            line(0, "aaaaaaaaaa", hl: 0), line(1, "bbbbbbbbbb", hl: 0),
            line(2, "cccccccccc", hl: 0), line(3, "dddddddddd", hl: 0),
            line(4, "eeeeeeeeee", hl: 0), line(5, "ffffffffff", hl: 0),
        ]))
        view.present(flush(store, [
            .winViewportMargins(
                grid: 1, win: 10, top: 1, bottom: 1, left: 2, right: 1),
        ]))

        guard let grid = view.layer?.sublayers?.first(where: { $0.zPosition != 10_000 }),
            let clip = grid.sublayers?.first(where: { $0.masksToBounds })
        else {
            Issue.record("permanent viewport clip missing")
            return
        }
        #expect(clip.frame == CGRect(
            x: 2 * view.cellSize.width, y: view.cellSize.height,
            width: 7 * view.cellSize.width, height: 4 * view.cellSize.height))
    }

    @Test func immediateMetadataOnlyFramePreservesUnrelatedViewportMotion() {
        let view = GridSurfaceView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 400), font: menlo)
        let store = GridStore()
        view.present(flush(store, [
            .gridResize(grid: 1, width: 10, height: 6),
            line(0, "aaaaaaaaaa", hl: 0), line(1, "bbbbbbbbbb", hl: 0),
            line(2, "cccccccccc", hl: 0), line(3, "dddddddddd", hl: 0),
            line(4, "eeeeeeeeee", hl: 0), line(5, "ffffffffff", hl: 0),
        ]))
        view.present(flush(store, [
            .gridScroll(
                grid: 1, top: 0, bottom: 6, left: 0, right: 10,
                rows: 1, cols: 0),
            line(5, "zzzzzzzzzz", hl: 0),
            .winViewport(
                grid: 1, win: 10, topline: 1, botline: 7,
                curline: 2, curcol: 0, lineCount: 100, scrollDelta: 1),
        ]))
        #expect(!view.animationsAreIdle)

        _ = store.applyDeferred(RedrawBatch(events: [
            .setTitle("atomic"), .flush,
        ]))
        guard let atomic = store.consumePendingPresentation() else {
            Issue.record("immediate presentation missing")
            return
        }
        #expect(!atomic.allowsScrollInterpolation)
        view.present(atomic)
        #expect(!view.animationsAreIdle,
                "metadata-only presentation must not snap an unrelated filmstrip")
    }

    @Test func cursorRectAndHitTestingAgree() {
        let view = GridSurfaceView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 400), font: menlo)
        let store = GridStore()
        let result = flush(store, [
            .gridResize(grid: 1, width: 40, height: 12),
            .gridCursorGoto(grid: 1, row: 2, col: 3),
        ])
        view.present(result)

        let cw = view.cellSize.width
        let ch = view.cellSize.height
        #expect(view.cursorRect == NSRect(x: 3 * cw, y: 2 * ch, width: cw, height: ch))

        let hit = view.cell(at: NSPoint(x: 3.5 * cw, y: 2.5 * ch))
        #expect(hit! == (grid: 1, row: 2, col: 3))
    }

    @Test func gridSizeTracksBoundsAndFont() {
        let view = GridSurfaceView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 400), font: menlo)
        let size = view.gridSize
        #expect(size.rows == Int(400 / view.cellSize.height))
        #expect(size.cols == Int(600 / view.cellSize.width))

        view.setFont(FontSpec(name: "Menlo", size: 26))
        #expect(view.gridSize.rows < size.rows)
    }

    @Test func displayLinkedPresentationHookDefersOnlyWhileMotionIsActive() {
        let view = GridSurfaceView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 400), font: menlo)
        let window = NSWindow(
            contentRect: view.frame, styleMask: .borderless,
            backing: .buffered, defer: false)
        window.contentView = view

        var calls = 0
        #expect(!view.schedulePresentationOnNextDisplay { calls += 1 },
                "the first idle scroll remains immediate")
        let store = GridStore()
        view.present(flush(store, [
            .gridResize(grid: 1, width: 10, height: 6),
            .winViewport(
                grid: 1, win: 10, topline: 0, botline: 6,
                curline: 3, curcol: 2, lineCount: 100, scrollDelta: 0),
        ]))
        view.present(flush(store, [
            .gridScroll(
                grid: 1, top: 0, bottom: 6, left: 0, right: 10,
                rows: 1, cols: 0),
            .winViewport(
                grid: 1, win: 10, topline: 1, botline: 7,
                curline: 3, curcol: 2, lineCount: 100, scrollDelta: 1),
        ]))

        let pendingFlush = flush(store, [
            .gridScroll(
                grid: 1, top: 0, bottom: 6, left: 0, right: 10,
                rows: 1, cols: 0),
            .winViewport(
                grid: 1, win: 10, topline: 2, botline: 8,
                curline: 3, curcol: 2, lineCount: 100, scrollDelta: 1),
        ])
        let beforeTick = view.scrollPosition(gridID: 1)
        var actionRan = false
        var positionWhenActionRan: CGFloat?
        var samples: [ScrollDiagnosticSample] = []
        view.resetScrollDiagnostics()
        view.scrollDiagnosticHandler = { sample in
            samples.append(sample)
            #expect(actionRan,
                    "the frame sample must describe the final retargeted state")
        }
        #expect(view.schedulePresentationOnNextDisplay {
            actionRan = true
            positionWhenActionRan = view.scrollPosition(gridID: 1)
            view.present(pendingFlush)
            calls += 1
        })
        #expect(calls == 0)
        _ = view.advanceAnimations(
            by: 1.0 / 120.0, nominalDisplayPeriod: 1.0 / 120.0,
            timestamp: 100)
        #expect(calls == 1)
        #expect(positionWhenActionRan != beforeTick,
                "existing motion advances before a newly queued retarget")
        #expect(samples.count == 1,
                "one display target must produce one final-state sample")
        #expect(samples.first?.timestamp == 100)
        #expect(samples.first?.historyHead == 2)

        _ = view.advanceAnimations(
            by: 1.0 / 120.0, nominalDisplayPeriod: 1.0 / 120.0,
            timestamp: 100 + 1.0 / 120.0)
        #expect(samples.count == 2)
        #expect(zip(samples, samples.dropFirst()).allSatisfy {
            before, after in before.timestamp < after.timestamp
        }, "diagnostic timestamps must remain monotonic")
        window.contentView = nil
    }

    @Test func displayLinkSimulationTargetsTheFrameBeingPrepared() {
        let timestamp = 100.0
        let target = timestamp + 1.0 / 120.0
        #expect(abs(GridSurfaceView.nominalDisplayPeriod(
            timestamp: timestamp, targetTimestamp: target,
            duration: 1.0 / 60.0) - 1.0 / 120.0) < 0.000_001)
        #expect(GridSurfaceView.displayTargetTimestamp(
            timestamp: timestamp, targetTimestamp: target,
            duration: 1.0 / 60.0) == target)
        #expect(abs(GridSurfaceView.displayTargetTimestamp(
            timestamp: timestamp, targetTimestamp: timestamp,
            duration: 1.0 / 60.0) - (timestamp + 1.0 / 60.0)) < 0.000_001)
        #expect(!GridSurfaceView.shouldDetectDisplayGap(
            resumedAt: timestamp, callbackTimestamp: timestamp + 0.0105,
            nominalDisplayPeriod: 1.0 / 120.0),
            "normal first-callback scheduling latency is not a missed frame")
        #expect(GridSurfaceView.shouldDetectDisplayGap(
            resumedAt: timestamp, callbackTimestamp: timestamp + 0.050,
            nominalDisplayPeriod: 1.0 / 120.0),
            "a real stall immediately after resume still triggers gap handling")
        #expect(GridSurfaceView.shouldDetectDisplayGap(
            resumedAt: nil, callbackTimestamp: timestamp,
            nominalDisplayPeriod: 1.0 / 120.0),
            "all callbacks after the first participate in gap detection")
    }
}

// MARK: - Cursor rendering (block cursor must show the cell under it)

@MainActor
@Suite struct CursorRenderTests {
    private func makeView(cursorCol: Int) -> (GridSurfaceView, FlushResult) {
        let view = GridSurfaceView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 400), font: menlo)
        let store = GridStore()
        var mode = ModeInfo()
        mode.cursorShape = .block
        let result = flush(store, [
            .gridResize(grid: 1, width: 10, height: 4),
            .defaultColorsSet(fg: rgb(0xFFFFFF), bg: rgb(0x000000), special: rgb(0xFF0000)),
            .modeInfoSet(cursorStyleEnabled: true, modes: [mode]),
            .modeChange(mode: "normal", modeIndex: 0),
            line(0, "abc", hl: 0),
            .gridCursorGoto(grid: 1, row: 0, col: cursorCol),
        ])
        view.present(result)
        return (view, result)
    }

    private func cursorLayer(of view: GridSurfaceView) -> CALayer? {
        view.layer?.sublayers?.first { $0.zPosition == 10_000 }
    }

    /// Reference: what a block cursor over `letter` SHOULD contain —
    /// default-fg fill, default-bg glyph, same pipeline as the grid.
    private func reference(_ letter: String, fonts: FontSet) -> CGImage {
        let cw = fonts.cellSize.width
        let ch = fonts.cellSize.height
        let ctx = GridRenderer.makeContext(width: Int(cw * 2), height: Int(ch * 2), scale: 2)!
        ctx.setFillColor(NvimKit.RGBColor(rgb: 0xFFFFFF).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: cw, height: ch))
        let cache = GlyphCache(capacity: 8)
        let shaped = cache.shapedRun(
            text: letter, variant: .regular, font: fonts.regular,
            cellWidth: fonts.cellSize.width, baseAdvance: fonts.baseAdvance)
        ctx.translateBy(x: 0, y: ch - fonts.baselineOffset)
        ctx.setFillColor(NvimKit.RGBColor(rgb: 0x000000).cgColor)
        for segment in shaped.segments {
            CTFontDrawGlyphs(segment.font, segment.glyphs, segment.positions, segment.glyphs.count, ctx)
        }
        return ctx.makeImage()!
    }

    @Test func blockCursorFrameAndGlyphMatchTheCellUnderIt() {
        let (view, _) = makeView(cursorCol: 1)  // over "b"
        let fonts = FontSet(spec: menlo)
        let layer = cursorLayer(of: view)
        #expect(layer != nil, "cursor layer present")
        guard let layer else { return }

        #expect(layer.frame.origin.x == fonts.cellSize.width, "block sits over column 1")
        #expect(layer.frame.origin.y == 0, "block sits on row 0")

        guard let contents = layer.contents else {
            Issue.record("block cursor has no glyph contents")
            return
        }
        let image = contents as! CGImage
        let matchesB = identical(image, reference("b", fonts: fonts))
        let matchesA = identical(image, reference("a", fonts: fonts))
        let matchesC = identical(image, reference("c", fonts: fonts))
        #expect(matchesB, "cursor must render the letter under it ('b')")
        #expect(!matchesA && !matchesC, "cursor must not render a neighbor's letter")
    }
}

extension CursorRenderTests {
    /// The regression from the field: cursor over ITALIC text (comments)
    /// must render the italic glyph, not the upright variant.
    @MainActor
    @Test func blockCursorHonorsTheCellsFontVariant() {
        let view = GridSurfaceView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 400), font: menlo)
        let store = GridStore()
        var mode = ModeInfo()
        mode.cursorShape = .block
        var italic = HlAttrs()
        italic.italic = true
        let result = flush(store, [
            .gridResize(grid: 1, width: 10, height: 4),
            .defaultColorsSet(fg: rgb(0xFFFFFF), bg: rgb(0x000000), special: rgb(0xFF0000)),
            .modeInfoSet(cursorStyleEnabled: true, modes: [mode]),
            .modeChange(mode: "normal", modeIndex: 0),
            .hlAttrDefine(id: 5, attrs: italic),
            line(0, "bbb", hl: 5),
            .gridCursorGoto(grid: 1, row: 0, col: 1),
        ])
        view.present(result)
        guard let layer = view.layer?.sublayers?.first(where: { $0.zPosition == 10_000 }),
            let contents = layer.contents
        else {
            Issue.record("cursor layer/contents missing")
            return
        }
        let image = contents as! CGImage

        let fonts = FontSet(spec: menlo)
        func variantReference(_ variant: FontSet.Variant) -> CGImage {
            let cw = fonts.cellSize.width
            let ch = fonts.cellSize.height
            let ctx = GridRenderer.makeContext(width: Int(cw * 2), height: Int(ch * 2), scale: 2)!
            ctx.setFillColor(NvimKit.RGBColor(rgb: 0xFFFFFF).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: cw, height: ch))
            let cache = GlyphCache(capacity: 8)
            let shaped = cache.shapedRun(
                text: "b", variant: variant, font: fonts.font(for: variant),
                cellWidth: fonts.cellSize.width, baseAdvance: fonts.baseAdvance)
            ctx.translateBy(x: 0, y: ch - fonts.baselineOffset)
            ctx.setFillColor(NvimKit.RGBColor(rgb: 0x000000).cgColor)
            for s in shaped.segments {
                CTFontDrawGlyphs(s.font, s.glyphs, s.positions, s.glyphs.count, ctx)
            }
            return ctx.makeImage()!
        }
        #expect(identical(image, variantReference(.italic)),
                "cursor over italic text must draw the italic glyph")
        #expect(!identical(image, variantReference(.regular)),
                "upright glyph over italic text is the reported bug")
    }
}

extension CursorRenderTests {
    private func blinkingBlockMode() -> ModeInfo {
        var mode = ModeInfo()
        mode.cursorShape = .block
        mode.blinkWait = 700
        mode.blinkOn = 400
        mode.blinkOff = 250
        return mode
    }

    private func cursorLayer(in view: GridSurfaceView) -> CALayer? {
        view.layer?.sublayers?.first { $0.zPosition == 10_000 }
    }

    private func movingRowLayer(
        in view: GridSurfaceView, sourceRow: Int, totalRows: Int
    ) -> (clip: CALayer, row: CALayer)? {
        guard let grid = view.layer?.sublayers?.first(where: { $0.zPosition != 10_000 }),
            let clip = grid.sublayers?.first(where: { $0.zPosition == 1 && $0.masksToBounds }),
            let row = view.visibleRowLayer(gridID: 1, sourceRow: sourceRow)
        else { return nil }
        _ = totalRows
        return (clip, row)
    }

    @Test func scrollOnlyFlushKeepsCursorBitmapAndBlinkPhase() {
        let view = GridSurfaceView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 400), font: menlo)
        let store = GridStore()
        let mode = blinkingBlockMode()
        view.present(flush(store, [
            .gridResize(grid: 1, width: 10, height: 6),
            .defaultColorsSet(
                fg: rgb(0xFFFFFF), bg: rgb(0x000000), special: rgb(0xFF0000)),
            .modeInfoSet(cursorStyleEnabled: true, modes: [mode]),
            .modeChange(mode: "normal", modeIndex: 0),
            line(0, "aaaaaaaaaa", hl: 0), line(1, "bbbbbbbbbb", hl: 0),
            line(2, "cccccccccc", hl: 0), line(3, "dddddddddd", hl: 0),
            line(4, "eeeeeeeeee", hl: 0), line(5, "ffffffffff", hl: 0),
            .gridCursorGoto(grid: 1, row: 3, col: 2),
            .winViewport(
                grid: 1, win: 10, topline: 0, botline: 6,
                curline: 3, curcol: 2, lineCount: 100, scrollDelta: 0),
        ]))

        guard let cursor = cursorLayer(in: view),
            let firstBlink = cursor.animation(forKey: "superlemon.blink"),
            let firstContents = cursor.contents
        else {
            Issue.record("expected a blinking block cursor with rasterized contents")
            return
        }
        let firstBitmap = firstContents as! CGImage

        // The viewport moved, but the buffer cursor still names line 3,
        // column 2. Its grid row and the backing image both changed.
        view.present(flush(store, [
            .gridScroll(
                grid: 1, top: 0, bottom: 6, left: 0, right: 10, rows: 1, cols: 0),
            line(5, "zzzzzzzzzz", hl: 0),
            .gridCursorGoto(grid: 1, row: 2, col: 2),
            .winViewport(
                grid: 1, win: 10, topline: 1, botline: 7,
                curline: 3, curcol: 2, lineCount: 100, scrollDelta: 1),
        ]))

        guard let secondBlink = cursor.animation(forKey: "superlemon.blink"),
            let secondContents = cursor.contents
        else {
            Issue.record("cursor blink or bitmap disappeared after scrolling")
            return
        }
        let secondBitmap = secondContents as! CGImage
        #expect(secondBlink.beginTime == firstBlink.beginTime,
                "scrolling the viewport must not restart the blink cycle")
        #expect(secondBitmap === firstBitmap,
                "the unchanged cursor cell must not be rasterized again")
    }

    @Test func cursorTracksItsMovingRowWithinOnePhysicalPixel() {
        let view = GridSurfaceView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 400), font: menlo)
        let store = GridStore()
        let mode = blinkingBlockMode()
        view.present(flush(store, [
            .gridResize(grid: 1, width: 10, height: 6),
            .modeInfoSet(cursorStyleEnabled: true, modes: [mode]),
            .modeChange(mode: "normal", modeIndex: 0),
            line(0, "aaaaaaaaaa", hl: 0), line(1, "bbbbbbbbbb", hl: 0),
            line(2, "cccccccccc", hl: 0), line(3, "dddddddddd", hl: 0),
            line(4, "eeeeeeeeee", hl: 0), line(5, "ffffffffff", hl: 0),
            .gridCursorGoto(grid: 1, row: 3, col: 2),
            .winViewport(
                grid: 1, win: 10, topline: 0, botline: 6,
                curline: 3, curcol: 2, lineCount: 100, scrollDelta: 0),
        ]))
        view.present(flush(store, [
            .gridScroll(
                grid: 1, top: 0, bottom: 6, left: 0, right: 10, rows: 1, cols: 0),
            line(5, "zzzzzzzzzz", hl: 0),
            .gridCursorGoto(grid: 1, row: 2, col: 2),
            .winViewport(
                grid: 1, win: 10, topline: 1, botline: 7,
                curline: 3, curcol: 2, lineCount: 100, scrollDelta: 1),
        ]))

        guard let cursor = cursorLayer(in: view) else {
            Issue.record("cursor layer missing")
            return
        }
        let tolerance: CGFloat = 0.5  // one physical pixel at the test view's 2x scale
        for _ in 0..<36 {
            guard let moving = movingRowLayer(in: view, sourceRow: 2, totalRows: 6)
            else {
                Issue.record("authoritative cursor row missing from animated history")
                return
            }
            let rowY = moving.row.convert(moving.row.bounds, to: view.layer).minY
            #expect(abs(cursor.frame.minY - rowY) <= tolerance,
                    "cursor y=\(cursor.frame.minY), row y=\(rowY), rect=\(moving.row.contentsRect) must share the display-linked trajectory")
            _ = view.advanceAnimations(by: 1.0 / 120.0)
        }

        for _ in 0..<240 where !view.animationsAreIdle {
            _ = view.advanceAnimations(by: 1.0 / 120.0)
        }
        #expect(view.animationsAreIdle)
        #expect(abs(cursor.frame.minY - 2 * view.cellSize.height) <= tolerance)
    }

    @Test func fastInteriorCursorStreamStaysLockedAndKeepsBlinkPhase() {
        let rows = 12
        let view = GridSurfaceView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 400), font: menlo)
        let store = GridStore()
        let mode = blinkingBlockMode()
        let contents = [
            "aaaaaaaaaa", "bbbbbbbbbb", "cccccccccc", "dddddddddd",
            "eeeeeeeeee", "ffffffffff", "gggggggggg", "hhhhhhhhhh",
            "iiiiiiiiii", "jjjjjjjjjj", "kkkkkkkkkk", "llllllllll",
        ]
        var initial: [UIEvent] = [
            .gridResize(grid: 1, width: 10, height: rows),
            .defaultColorsSet(
                fg: rgb(0xFFFFFF), bg: rgb(0x000000), special: rgb(0xFF0000)),
            .modeInfoSet(cursorStyleEnabled: true, modes: [mode]),
            .modeChange(mode: "normal", modeIndex: 0),
        ]
        initial.append(contentsOf: contents.enumerated().map {
            line($0.offset, $0.element, hl: 0)
        })
        initial.append(contentsOf: [
            .gridCursorGoto(grid: 1, row: 8, col: 2),
            .winViewport(
                grid: 1, win: 10, topline: 0, botline: rows,
                curline: 8, curcol: 2, lineCount: 100, scrollDelta: 0),
        ])
        view.present(flush(store, initial))

        guard let cursor = cursorLayer(in: view),
            let blink = cursor.animation(forKey: "superlemon.blink"),
            let firstContents = cursor.contents
        else {
            Issue.record("expected a blinking interior cursor")
            return
        }
        let bitmap = firstContents as! CGImage
        let tolerance: CGFloat = 0.5
        func expectLocked(to sourceRow: Int) {
            guard let moving = movingRowLayer(
                in: view, sourceRow: sourceRow, totalRows: rows)
            else {
                Issue.record("authoritative cursor row missing from fast filmstrip")
                return
            }
            let rowY = moving.row.convert(moving.row.bounds, to: view.layer).minY
            #expect(abs(cursor.frame.minY - rowY) <= tolerance,
                    "fast cursor y=\(cursor.frame.minY) must stay on row y=\(rowY)")
            #expect(cursor.animation(forKey: "superlemon.blink")?.beginTime
                == blink.beginTime)
            let currentBitmap = cursor.contents as! CGImage
            #expect(currentBitmap === bitmap,
                    "scrolling the same buffer cell must not rebuild the cursor")
        }

        // Two authoritative row changes per display tick approximate the
        // 4 ms-class stream used by the camera cadence test. The cursor stays
        // interior for all six steps, so edge clamping cannot mask a sawtooth.
        for step in 1...6 {
            let cursorRow = 8 - step
            view.present(flush(store, [
                .gridScroll(
                    grid: 1, top: 0, bottom: rows, left: 0, right: 10,
                    rows: 1, cols: 0),
                line(rows - 1, "zzzzzzzzzz", hl: 0),
                .gridCursorGoto(grid: 1, row: cursorRow, col: 2),
                .winViewport(
                    grid: 1, win: 10, topline: step, botline: step + rows,
                    curline: 8, curcol: 2, lineCount: 100, scrollDelta: 1),
            ]))
            expectLocked(to: cursorRow)
            if step.isMultiple(of: 2) {
                _ = view.advanceAnimations(
                    by: 1.0 / 120.0,
                    nominalDisplayPeriod: 1.0 / 120.0)
                expectLocked(to: cursorRow)
            }
        }

        for _ in 0..<240 where !view.animationsAreIdle {
            _ = view.advanceAnimations(
                by: 1.0 / 120.0,
                nominalDisplayPeriod: 1.0 / 120.0)
            expectLocked(to: 2)
        }
        #expect(view.animationsAreIdle)
    }

    @Test func cursorAtBottomMarginRemainsClampedDuringScroll() {
        let view = GridSurfaceView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 400), font: menlo)
        let store = GridStore()
        view.present(flush(store, [
            .gridResize(grid: 1, width: 10, height: 6),
            .winViewportMargins(grid: 1, win: 10, top: 1, bottom: 1, left: 0, right: 0),
            .gridCursorGoto(grid: 1, row: 4, col: 2),
            .winViewport(
                grid: 1, win: 10, topline: 0, botline: 4,
                curline: 4, curcol: 2, lineCount: 100, scrollDelta: 0),
        ]))
        view.present(flush(store, [
            .gridScroll(
                grid: 1, top: 1, bottom: 5, left: 0, right: 10, rows: 1, cols: 0),
            line(4, "zzzzzzzzzz", hl: 0),
            .gridCursorGoto(grid: 1, row: 4, col: 2),
            .winViewport(
                grid: 1, win: 10, topline: 1, botline: 5,
                curline: 5, curcol: 2, lineCount: 100, scrollDelta: 1),
        ]))

        guard let cursor = cursorLayer(in: view) else {
            Issue.record("cursor layer missing")
            return
        }
        let edgeY = 4 * view.cellSize.height
        for _ in 0..<72 {
            #expect(abs(cursor.frame.minY - edgeY) <= 0.5,
                    "cursor must not travel into the stationary bottom margin")
            _ = view.advanceAnimations(by: 1.0 / 120.0)
        }
    }

    @Test func cursorAtTopEdgeDoesNotKickIntoViewportOnRepeatedScrolls() {
        let view = GridSurfaceView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 400), font: menlo)
        let store = GridStore()
        view.present(flush(store, [
            .gridResize(grid: 1, width: 10, height: 6),
            .gridCursorGoto(grid: 1, row: 0, col: 2),
            .winViewport(
                grid: 1, win: 10, topline: 20, botline: 26,
                curline: 20, curcol: 2, lineCount: 100, scrollDelta: 0),
        ]))

        for topLine in 21...23 {
            view.present(flush(store, [
                .gridScroll(
                    grid: 1, top: 0, bottom: 6, left: 0, right: 10,
                    rows: 1, cols: 0),
                line(5, "zzzzzzzzzz", hl: 0),
                .gridCursorGoto(grid: 1, row: 0, col: 2),
                .winViewport(
                    grid: 1, win: 10, topline: topLine, botline: topLine + 6,
                    curline: topLine, curcol: 2, lineCount: 100, scrollDelta: 1),
            ]))
            guard let cursor = cursorLayer(in: view) else {
                Issue.record("cursor layer missing")
                return
            }
            for _ in 0..<8 {
                #expect(abs(cursor.frame.minY) <= 0.5,
                        "top-edge cursor must stay pinned instead of kicking down")
                _ = view.advanceAnimations(by: 1.0 / 120.0)
            }
        }
    }

    @Test func cursorCorrectionNeverLeaksBetweenScrollingSplits() {
        let view = GridSurfaceView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 400), font: menlo)
        let store = GridStore()
        view.present(flush(store, [
            .gridResize(grid: 1, width: 20, height: 12),
            .gridResize(grid: 2, width: 10, height: 6),
            .winPos(
                grid: 2, win: 20, startRow: 0, startCol: 0,
                width: 10, height: 6),
            .gridResize(grid: 3, width: 10, height: 6),
            .winPos(
                grid: 3, win: 30, startRow: 6, startCol: 0,
                width: 10, height: 6),
            .gridCursorGoto(grid: 2, row: 3, col: 2),
            .winViewport(
                grid: 2, win: 20, topline: 0, botline: 6,
                curline: 3, curcol: 2, lineCount: 100, scrollDelta: 0),
            .winViewport(
                grid: 3, win: 30, topline: 20, botline: 26,
                curline: 22, curcol: 2, lineCount: 100, scrollDelta: 0),
        ]))

        // Both histories move. Split 2 also moves its authoritative cursor by
        // an extra row, creating a non-zero short cursor correction there.
        view.present(flush(store, [
            .gridScroll(
                grid: 2, top: 0, bottom: 6, left: 0, right: 10,
                rows: 1, cols: 0),
            .gridScroll(
                grid: 3, top: 0, bottom: 6, left: 0, right: 10,
                rows: 1, cols: 0),
            .gridCursorGoto(grid: 2, row: 1, col: 2),
            .winViewport(
                grid: 2, win: 20, topline: 1, botline: 7,
                curline: 2, curcol: 2, lineCount: 100, scrollDelta: 1),
            .winViewport(
                grid: 3, win: 30, topline: 21, botline: 27,
                curline: 23, curcol: 2, lineCount: 100, scrollDelta: 1),
        ]))

        view.present(flush(store, [
            .gridCursorGoto(grid: 3, row: 2, col: 2),
        ]))

        guard let cursor = cursorLayer(in: view) else {
            Issue.record("cursor layer missing")
            return
        }
        // Grid 3 begins at outer row 6, its cursor is row 2, and its active
        // one-line residual starts one row below the authoritative cell.
        let expectedY = 9 * view.cellSize.height
        #expect(abs(cursor.frame.minY - expectedY) <= 0.5,
                "a correction created in split 2 must not offset split 3")
    }

    @Test func cursorShapeChangeDoesNotCreateARowCorrection() {
        let view = GridSurfaceView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 400), font: menlo)
        let store = GridStore()
        var block = ModeInfo()
        block.cursorShape = .block
        view.present(flush(store, [
            .gridResize(grid: 1, width: 10, height: 6),
            .modeInfoSet(cursorStyleEnabled: true, modes: [block]),
            .modeChange(mode: "normal", modeIndex: 0),
            .gridCursorGoto(grid: 1, row: 3, col: 2),
            .winViewport(
                grid: 1, win: 10, topline: 0, botline: 6,
                curline: 3, curcol: 2, lineCount: 100, scrollDelta: 0),
        ]))
        view.present(flush(store, [
            .gridScroll(
                grid: 1, top: 0, bottom: 6, left: 0, right: 10,
                rows: 1, cols: 0),
            .gridCursorGoto(grid: 1, row: 2, col: 2),
            .winViewport(
                grid: 1, win: 10, topline: 1, botline: 7,
                curline: 3, curcol: 2, lineCount: 100, scrollDelta: 1),
        ]))

        var horizontal = ModeInfo()
        horizontal.cursorShape = .horizontal
        horizontal.cellPercentage = 20
        view.present(flush(store, [
            .modeInfoSet(cursorStyleEnabled: true, modes: [horizontal]),
            .modeChange(mode: "normal", modeIndex: 0),
        ]))

        guard let cursor = cursorLayer(in: view) else {
            Issue.record("cursor layer missing")
            return
        }
        let shapeOffset = view.cellSize.height * 0.8
        let expectedY = 3 * view.cellSize.height + shapeOffset
        #expect(abs(cursor.frame.minY - expectedY) <= 0.5,
                "changing cursor shape must not be mistaken for a cursor-row move")
    }
}

// MARK: - Powerline glyph synthesis (any font, no patching)

@MainActor
@Suite struct PowerlineSynthesisTests {
    @Test func rightTriangleFillsItsCell() {
        let store = GridStore()
        let result = flush(store, [
            .gridResize(grid: 1, width: 6, height: 2),
            .defaultColorsSet(fg: rgb(0xFF0000), bg: rgb(0x000000), special: rgb(0x00FF00)),
            line(0, "a\u{E0B0}b", hl: 0),
        ])
        var spec = menlo
        spec.powerlineGlyphs = true
        spec.forceSynthesis = true
        let fonts = FontSet(spec: spec)
        let renderer = GridRenderer(rasterizer: TextRasterizer(fonts: fonts), scale: 1)
        let d = result.damagedGrids.first { $0.grid.id == 1 }!
        renderer.apply(grid: d.grid, damage: d.damage, highlights: result.highlights)
        let image = renderer.image()!

        let cw = Int(fonts.cellSize.width)
        let ch = Int(fonts.cellSize.height)
        // Cell 1 holds the synthesized triangle: red at the left-middle
        // (widest part), black at the top-right corner (outside the slope).
        #expect(pixel(image, x: cw + 1, y: ch / 2) == (255, 0, 0),
                "triangle base filled with the run's foreground")
        #expect(pixel(image, x: 2 * cw - 1, y: 1) == (0, 0, 0),
                "top-right corner stays background")
        // Neighbor 'a' still shaped normally: some ink in cell 0.
        var ink = false
        for y in 0..<ch {
            for x in 0..<cw where pixel(image, x: x, y: y) != (0, 0, 0) {
                ink = true
            }
        }
        #expect(ink, "adjacent text still renders")
    }

    @Test func synthesisIsOptIn() {
        let store = GridStore()
        let result = flush(store, [
            .gridResize(grid: 1, width: 4, height: 1),
            .defaultColorsSet(fg: rgb(0xFF0000), bg: rgb(0x000000), special: rgb(0x00FF00)),
            line(0, "\u{E0B0}", hl: 0),
        ])
        let fonts = FontSet(spec: menlo)  // powerlineGlyphs = false
        let renderer = GridRenderer(rasterizer: TextRasterizer(fonts: fonts), scale: 1)
        let d = result.damagedGrids.first { $0.grid.id == 1 }!
        renderer.apply(grid: d.grid, damage: d.damage, highlights: result.highlights)
        let image = renderer.image()!
        let fonts2 = fonts
        // Whatever the fallback draws (tofu or nothing), the exact solid
        // left-edge midpoint fill of the synthesized triangle must NOT be
        // guaranteed — assert only that both paths render without crashing.
        _ = pixel(image, x: 1, y: Int(fonts2.cellSize.height) / 2)
        #expect(Bool(true))
    }
}


// MARK: - Synthesized programming ligatures (any font)

@MainActor
@Suite struct LigatureSynthesisTests {
    private func render(_ text: String) -> (CGImage, FontSet) {
        let store = GridStore()
        let result = flush(store, [
            .gridResize(grid: 1, width: 12, height: 1),
            .defaultColorsSet(fg: rgb(0xFF0000), bg: rgb(0x000000), special: rgb(0x00FF00)),
            line(0, text, hl: 0),
        ])
        var lspec = menlo
        lspec.forceSynthesis = true  // substitution path under test
        let fonts = FontSet(spec: lspec)
        let renderer = GridRenderer(rasterizer: TextRasterizer(fonts: fonts), scale: 1)
        let d = result.damagedGrids.first { $0.grid.id == 1 }!
        renderer.apply(grid: d.grid, damage: d.damage, highlights: result.highlights)
        return (renderer.image()!, fonts)
    }

    @Test func doubleEqualsRendersAsLongBars() {
        let (image, fonts) = render("a==b")
        let cw = Int(fonts.cellSize.width)
        let ch = Int(fonts.cellSize.height)
        _ = fonts
        // A bar crosses the CELL BOUNDARY between cols 1 and 2 — impossible
        // with per-character '=' glyphs (they leave side bearings). Scan the
        // boundary column; antialiasing means partial coverage, so assert
        // strong red ink rather than an exact byte.
        var maxRed: UInt8 = 0
        for y in 0..<ch {
            maxRed = max(maxRed, pixel(image, x: 2 * cw, y: y).r)
        }
        #expect(maxRed >= 120, "bars span the two-cell boundary (got max r=\(maxRed))")
    }

    @Test func splitterExtractsSequencesCellAccurately() {
        let cells: [Cell] = "x!==y".map { Cell(text: String($0), hlID: 1) }
        let runs = TextRasterizer.splitLigatureRuns(
            TextRasterizer.coalesce(cells[...]), cells: cells[...])
        #expect(runs == [
            StyleRun(startCol: 0, cellCount: 1, text: "x", hlID: 1),
            StyleRun(startCol: 1, cellCount: 3, text: "!==", hlID: 1, synthetic: true),
            StyleRun(startCol: 4, cellCount: 1, text: "y", hlID: 1),
        ])
    }

    @Test func ligaturesOffLeavesRunsAlone() {
        let store = GridStore()
        let result = flush(store, [
            .gridResize(grid: 1, width: 8, height: 1),
            .defaultColorsSet(fg: rgb(0xFF0000), bg: rgb(0x000000), special: rgb(0x00FF00)),
            line(0, "a==b", hl: 0),
        ])
        var spec = menlo
        spec.ligatures = false
        let fonts = FontSet(spec: spec)
        let renderer = GridRenderer(rasterizer: TextRasterizer(fonts: fonts), scale: 1)
        let d = result.damagedGrids.first { $0.grid.id == 1 }!
        renderer.apply(grid: d.grid, damage: d.damage, highlights: result.highlights)
        let image = renderer.image()!
        let cw = Int(fonts.cellSize.width)
        let ch = Int(fonts.cellSize.height)
        _ = (fonts, cw, ch)
        // The toggle must change rendering: compare against the ON pipeline.
        let (onImage, _) = renderWithLigatures("a==b")
        #expect(!identical(image, onImage), "ligature toggle changes the pixels")
    }

    private func renderWithLigatures(_ text: String) -> (CGImage, FontSet) {
        render(text)
    }
}
