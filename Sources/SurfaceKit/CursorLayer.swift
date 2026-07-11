import AppKit
import GridKit
import NvimKit

/// The cursor as its own CALayer (DESIGN §6): moves without touching any grid
/// backing store. Shape/blink from mode_info_set; a block cursor re-renders
/// the underlying cell with swapped colors into THIS layer only.
@MainActor
final class CursorLayer: CALayer {
    private var blinkKey: String { "superlemon.blink" }
    private var lastStyleSignature: StyleSignature?
    private var lastBlinkSignature: BlinkSignature?

    private struct StyleSignature: Equatable {
        var mode: ModeInfo?
        var text: String
        var cellAttrs: ResolvedAttrs
        var modeAttrs: ResolvedAttrs?
        var cellSize: CGSize
        var fontName: String
        var fontSize: CGFloat
        var scale: CGFloat
    }

    private struct BlinkSignature: Equatable {
        var grid: Int
        var bufferLine: Int
        var bufferColumn: Int
        var blinkWait: Int
        var blinkOn: Int
        var blinkOff: Int
    }

    override init() {
        super.init()
        zPosition = 10_000
        actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(),
                   "hidden": NSNull(), "backgroundColor": NSNull(),
                   "opacity": NSNull()]
    }

    override init(layer: Any) { super.init(layer: layer) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Reposition/restyle for one flush. `cellOrigin` is the cursor cell's
    /// top-left in view coordinates (multigrid frame already applied).
    func update(
        flush: FlushResult, cellOrigin: CGPoint,
        fonts: FontSet, cache: GlyphCache, scale: CGFloat
    ) {
        isHidden = flush.isBusy
        guard !flush.isBusy else {
            lastBlinkSignature = nil
            return
        }

        let cw = fonts.cellSize.width
        let ch = fonts.cellSize.height
        let mode = flush.mode
        let pct = CGFloat(max(1, min(100, mode?.cellPercentage ?? 100))) / 100

        // Colors: mode attr 0 means "reverse the cell underneath"; a concrete
        // attr id supplies its own colors (already reverse-folded by resolve).
        let cell = flush.grids[flush.cursor.grid].flatMap { grid -> Cell? in
            guard flush.cursor.row >= 0, flush.cursor.row < grid.rows,
                flush.cursor.col >= 0, flush.cursor.col < grid.cols
            else { return nil }
            return grid[flush.cursor.row, flush.cursor.col]
        }
        let cellAttrs: ResolvedAttrs = {
            guard let cell else { return flush.highlights.resolved(id: 0) }
            return flush.highlights.resolved(id: cell.hlID)
        }()
        let attrID = mode?.attrID ?? 0
        let modeAttrs = attrID == 0 ? nil : flush.highlights.resolved(id: attrID)
        let fill: NvimKit.RGBColor
        let glyphColor: NvimKit.RGBColor
        if attrID == 0 {
            fill = cellAttrs.foreground
            glyphColor = cellAttrs.background
        } else {
            let a = modeAttrs!
            fill = a.background
            glyphColor = a.foreground
        }

        let styleSignature = StyleSignature(
            mode: mode, text: cell?.text ?? "", cellAttrs: cellAttrs,
            modeAttrs: modeAttrs, cellSize: fonts.cellSize,
            fontName: CTFontCopyPostScriptName(fonts.regular) as String,
            fontSize: CTFontGetSize(fonts.regular), scale: scale)
        let styleChanged = styleSignature != lastStyleSignature
        if styleChanged {
            contents = nil
            backgroundColor = fill.cgColor
            contentsScale = scale
        }

        switch mode?.cursorShape ?? .block {
        case .vertical:
            frame = CGRect(x: cellOrigin.x, y: cellOrigin.y,
                           width: max(1, cw * pct), height: ch)
        case .horizontal:
            let h = max(1, ch * pct)
            frame = CGRect(x: cellOrigin.x, y: cellOrigin.y + ch - h,
                           width: cw, height: h)
        case .block:
            frame = CGRect(x: cellOrigin.x, y: cellOrigin.y, width: cw, height: ch)
            if styleChanged {
                renderBlockGlyph(
                    flush: flush, glyphColor: glyphColor, fill: fill,
                    fonts: fonts, cache: cache, scale: scale)
            }
        }
        lastStyleSignature = styleSignature

        let viewport = flush.grids[flush.cursor.grid]?.viewport
        let blinkSignature = BlinkSignature(
            grid: flush.cursor.grid,
            bufferLine: viewport?.curline ?? flush.cursor.row,
            bufferColumn: viewport?.curcol ?? flush.cursor.col,
            blinkWait: mode?.blinkWait ?? 0,
            blinkOn: mode?.blinkOn ?? 0,
            blinkOff: mode?.blinkOff ?? 0)
        if blinkSignature != lastBlinkSignature {
            updateBlink(mode)
            lastBlinkSignature = blinkSignature
        }
    }

    /// Display-link cursor motion only changes position. It never recreates
    /// glyph contents and never touches the independent blink animation.
    func setVisualY(_ y: CGFloat) {
        var next = frame
        next.origin.y = y
        frame = next
    }

    /// A velocity veil may de-emphasize the cursor without rebuilding its
    /// bitmap or touching the independent blink animation/timeline.
    func setScrollDimmed(_ dimmed: Bool) {
        opacity = dimmed ? 0.25 : 1
    }

    /// Draw the underlying cell's glyph in swapped colors into this layer.
    private func renderBlockGlyph(
        flush: FlushResult, glyphColor: NvimKit.RGBColor, fill: NvimKit.RGBColor,
        fonts: FontSet, cache: GlyphCache, scale: CGFloat
    ) {
        guard let grid = flush.grids[flush.cursor.grid],
            flush.cursor.row < grid.rows, flush.cursor.col < grid.cols
        else { return }
        let cell = grid[flush.cursor.row, flush.cursor.col]
        guard !cell.text.isEmpty, cell.text != " " else { return }

        let cw = fonts.cellSize.width
        let ch = fonts.cellSize.height
        guard let ctx = GridRenderer.makeContext(
            width: Int(cw * scale), height: Int(ch * scale), scale: scale)
        else { return }
        ctx.setFillColor(fill.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: cw, height: ch))
        // Match the grid's font variant for this cell — an upright glyph
        // drawn over italic/bold text reads as the wrong letter entirely.
        let attrs = flush.highlights.resolved(id: cell.hlID)
        let variant = FontSet.Variant(bold: attrs.bold, italic: attrs.italic)
        let shaped = cache.shapedRun(
            text: cell.text, variant: variant, font: fonts.font(for: variant),
            cellWidth: cw, baseAdvance: fonts.baseAdvance)
        ctx.translateBy(x: 0, y: ch - fonts.baselineOffset)
        ctx.setFillColor(glyphColor.cgColor)
        for segment in shaped.segments {
            CTFontDrawGlyphs(
                segment.font, segment.glyphs, segment.positions,
                segment.glyphs.count, ctx)
        }
        contents = ctx.makeImage()
    }

    /// Blink via CAKeyframeAnimation — no timers (DESIGN §6). The caller only
    /// invokes this when the semantic cursor or blink style changes, so a
    /// scroll-only flush leaves the current blink phase intact.
    private func updateBlink(_ mode: ModeInfo?) {
        removeAnimation(forKey: blinkKey)
        opacity = 1
        guard let mode, mode.blinkOn > 0, mode.blinkOff > 0 else { return }
        let on = Double(mode.blinkOn) / 1000
        let off = Double(mode.blinkOff) / 1000
        let wait = Double(mode.blinkWait) / 1000
        let period = on + off
        let anim = CAKeyframeAnimation(keyPath: "opacity")
        // Additive values preserve the exact on/off waveform while allowing
        // the model opacity to dim the cursor during a velocity veil. The
        // existing animation object and beginTime are never rebuilt by scroll.
        anim.values = [0, 0, -1, -1]
        anim.isAdditive = true
        anim.keyTimes = [0, NSNumber(value: on / period), NSNumber(value: on / period), 1]
        anim.duration = period
        anim.beginTime = CACurrentMediaTime() + wait
        anim.repeatCount = .infinity
        anim.fillMode = .backwards
        add(anim, forKey: blinkKey)
    }
}
