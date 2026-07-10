import AppKit
import GridKit
import NvimKit

/// The cursor as its own CALayer (DESIGN §6): moves without touching any grid
/// backing store. Shape/blink from mode_info_set; a block cursor re-renders
/// the underlying cell with swapped colors into THIS layer only.
@MainActor
final class CursorLayer: CALayer {
    private var blinkKey: String { "superlemon.blink" }

    override init() {
        super.init()
        zPosition = 10_000
        actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(),
                   "hidden": NSNull(), "backgroundColor": NSNull()]
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
        guard !flush.isBusy else { return }

        let cw = fonts.cellSize.width
        let ch = fonts.cellSize.height
        let mode = flush.mode
        let pct = CGFloat(max(1, min(100, mode?.cellPercentage ?? 100))) / 100

        // Colors: mode attr 0 means "reverse the cell underneath"; a concrete
        // attr id supplies its own colors (already reverse-folded by resolve).
        let cellAttrs: ResolvedAttrs = {
            guard let grid = flush.grids[flush.cursor.grid],
                flush.cursor.row < grid.rows, flush.cursor.col < grid.cols
            else { return flush.highlights.resolved(id: 0) }
            return flush.highlights.resolved(
                id: grid[flush.cursor.row, flush.cursor.col].hlID)
        }()
        let attrID = mode?.attrID ?? 0
        let fill: NvimKit.RGBColor
        let glyphColor: NvimKit.RGBColor
        if attrID == 0 {
            fill = cellAttrs.foreground
            glyphColor = cellAttrs.background
        } else {
            let a = flush.highlights.resolved(id: attrID)
            fill = a.background
            glyphColor = a.foreground
        }

        contents = nil
        backgroundColor = fill.cgColor
        contentsScale = scale

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
            renderBlockGlyph(
                flush: flush, glyphColor: glyphColor, fill: fill,
                fonts: fonts, cache: cache, scale: scale)
        }

        updateBlink(mode)
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
            text: cell.text, variant: variant, font: fonts.font(for: variant))
        ctx.translateBy(x: 0, y: ch - fonts.baselineOffset)
        ctx.setFillColor(glyphColor.cgColor)
        for segment in shaped.segments {
            CTFontDrawGlyphs(
                segment.font, segment.glyphs, segment.positions,
                segment.glyphs.count, ctx)
        }
        contents = ctx.makeImage()
    }

    /// Blink via CAKeyframeAnimation — no timers (DESIGN §6). Re-added on
    /// every update, which restarts the cycle: typing suppresses blink.
    private func updateBlink(_ mode: ModeInfo?) {
        removeAnimation(forKey: blinkKey)
        opacity = 1
        guard let mode, mode.blinkOn > 0, mode.blinkOff > 0 else { return }
        let on = Double(mode.blinkOn) / 1000
        let off = Double(mode.blinkOff) / 1000
        let wait = Double(mode.blinkWait) / 1000
        let period = on + off
        let anim = CAKeyframeAnimation(keyPath: "opacity")
        anim.values = [1, 1, 0, 0]
        anim.keyTimes = [0, NSNumber(value: on / period), NSNumber(value: on / period), 1]
        anim.duration = period
        anim.beginTime = CACurrentMediaTime() + wait
        anim.repeatCount = .infinity
        anim.fillMode = .backwards
        add(anim, forKey: blinkKey)
    }
}
