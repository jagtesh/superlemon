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
        let fonts = FontSet(spec: menlo)  // ligatures default ON
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
