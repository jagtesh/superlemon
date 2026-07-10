import CoreGraphics
import CoreText
import GridKit
import NvimKit

extension NvimKit.RGBColor {
    /// sRGB CGColor. The backing stores use the same colorspace, so pure
    /// fills round-trip to exact pixel bytes (relied on by tests).
    var cgColor: CGColor {
        CGColor(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1)
    }
}

/// A maximal run of consecutive same-highlight cells (DESIGN §6 step 1).
/// `cellCount` includes empty-text cells (double-width trailing halves), which
/// extend the run's background without contributing glyphs.
struct StyleRun: Equatable {
    var startCol: Int
    var cellCount: Int
    var text: String
    var hlID: Int

    var colRange: Range<Int> { startCol..<(startCol + cellCount) }
}

/// The Core Text pipeline of DESIGN §6: run coalescing → background pass →
/// shaping (cached) → CTFontDrawGlyphs → decorations. Draws into an UNFLIPPED
/// CGContext (origin bottom-left); all y-coordinates convert from row space
/// via the grid's total height in points.
final class TextRasterizer {
    private(set) var fonts: FontSet
    let cache: GlyphCache

    init(fonts: FontSet, cacheCapacity: Int = 4096) {
        self.fonts = fonts
        self.cache = GlyphCache(capacity: cacheCapacity)
    }

    /// Merge a row's cells into style runs. Breaks on hlID change; empty-text
    /// cells extend the current run's width (they are wide-glyph trailing
    /// halves or never-drawn blanks — background only).
    static func coalesce(_ cells: ArraySlice<Cell>) -> [StyleRun] {
        var runs: [StyleRun] = []
        for (offset, cell) in cells.enumerated() {
            if var last = runs.last, cell.hlID == last.hlID {
                last.cellCount += 1
                last.text += cell.text
                runs[runs.count - 1] = last
            } else {
                runs.append(StyleRun(
                    startCol: offset, cellCount: 1, text: cell.text, hlID: cell.hlID))
            }
        }
        return runs
    }

    /// Draw one style run of `row` into `ctx`. `gridHeight` is the full grid
    /// height in points (for bottom-left y conversion).
    func draw(
        _ run: StyleRun, row: Int, gridHeight: CGFloat,
        into ctx: CGContext, highlights: HighlightTable
    ) {
        let attrs = highlights.resolved(id: run.hlID)
        let cw = fonts.cellSize.width
        let ch = fonts.cellSize.height
        let originX = CGFloat(run.startCol) * cw
        let cellTop = CGFloat(row) * ch
        let rect = CGRect(
            x: originX, y: gridHeight - cellTop - ch,
            width: CGFloat(run.cellCount) * cw, height: ch)

        // Background pass: full-cell fill so wide glyphs/ligatures leave no seams.
        ctx.setFillColor(attrs.background.cgColor)
        ctx.fill(rect)

        // Glyphs.
        let baselineY = gridHeight - cellTop - fonts.baselineOffset
        if !run.text.isEmpty, !run.text.allSatisfy({ $0 == " " }) {
            let variant = FontSet.Variant(bold: attrs.bold, italic: attrs.italic)
            let shaped = cache.shapedRun(
                text: run.text, variant: variant, font: fonts.font(for: variant),
                cellWidth: cw, baseAdvance: fonts.baseAdvance)
            ctx.saveGState()
            ctx.translateBy(x: originX, y: baselineY)
            ctx.setFillColor(attrs.foreground.cgColor)
            for segment in shaped.segments {
                CTFontDrawGlyphs(
                    segment.font, segment.glyphs, segment.positions,
                    segment.glyphs.count, ctx)
            }
            ctx.restoreGState()
        }

        drawDecorations(attrs, runRect: rect, baselineY: baselineY, into: ctx)
    }

    private func drawDecorations(
        _ attrs: ResolvedAttrs, runRect: CGRect, baselineY: CGFloat, into ctx: CGContext
    ) {
        let special = attrs.special.cgColor
        let thickness = fonts.underlineThickness
        let lineY = baselineY - fonts.underlineOffset

        func stroke(y: CGFloat, dash: [CGFloat] = []) {
            ctx.saveGState()
            ctx.setStrokeColor(special)
            ctx.setLineWidth(thickness)
            ctx.setLineDash(phase: 0, lengths: dash)
            ctx.move(to: CGPoint(x: runRect.minX, y: y))
            ctx.addLine(to: CGPoint(x: runRect.maxX, y: y))
            ctx.strokePath()
            ctx.restoreGState()
        }

        if attrs.underline { stroke(y: lineY) }
        if attrs.underdouble {
            stroke(y: lineY)
            stroke(y: lineY - 2 * thickness)
        }
        if attrs.underdotted { stroke(y: lineY, dash: [thickness, thickness]) }
        if attrs.underdashed { stroke(y: lineY, dash: [3 * thickness, thickness]) }
        if attrs.undercurl {
            // Sine wave below the baseline; phase from absolute x so the curl
            // is continuous across run boundaries.
            let amplitude = max(1, fonts.cellSize.height * 0.06)
            let wavelength = fonts.cellSize.width
            ctx.saveGState()
            ctx.setStrokeColor(special)
            ctx.setLineWidth(thickness)
            var x = runRect.minX
            ctx.move(to: CGPoint(
                x: x, y: lineY + amplitude * sin(2 * .pi * x / wavelength)))
            while x < runRect.maxX {
                x = min(x + 1, runRect.maxX)
                ctx.addLine(to: CGPoint(
                    x: x, y: lineY + amplitude * sin(2 * .pi * x / wavelength)))
            }
            ctx.strokePath()
            ctx.restoreGState()
        }
        if attrs.strikethrough {
            stroke(y: baselineY + fonts.cellSize.height * 0.18)
        }
    }
}
