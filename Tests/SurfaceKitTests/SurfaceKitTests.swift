import AppKit
import GridKit
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

/// Sample one pixel (top-left origin) from an RGBA8 image.
private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
    let data = image.dataProvider!.data! as Data
    let offset = y * image.bytesPerRow + x * 4
    return (data[offset], data[offset + 1], data[offset + 2])
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
        _ = cache.shapedRun(text: "hello", variant: .regular, font: fonts.regular)
        _ = cache.shapedRun(text: "hello", variant: .regular, font: fonts.regular)
        _ = cache.shapedRun(text: "hello", variant: .bold, font: fonts.bold)
        #expect(cache.hits == 1)
        #expect(cache.misses == 2)
    }

    @Test func evictionKeepsCacheBounded() {
        let fonts = FontSet(spec: menlo)
        let cache = GlyphCache(capacity: 8)
        for i in 0..<50 {
            _ = cache.shapedRun(text: "word\(i)", variant: .regular, font: fonts.regular)
        }
        #expect(cache.misses == 50)
        // Everything distinct: eviction ran; re-shaping an early entry misses.
        _ = cache.shapedRun(text: "word0", variant: .regular, font: fonts.regular)
        #expect(cache.misses == 51)
    }
}

// MARK: - View geometry

@MainActor
@Suite struct ViewGeometryTests {
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
}
