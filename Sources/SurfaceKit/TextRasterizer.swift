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
        self.cache.ligatures = fonts.ligatures
    }

    /// Powerline separators/branch synthesized as vector shapes when the
    /// FontSpec asks for it — any font, no patching (U+E0A0, U+E0B0–E0B3).
    static let powerlineScalars: Set<Unicode.Scalar> = [
        "\u{E0A0}", "\u{E0B0}", "\u{E0B1}", "\u{E0B2}", "\u{E0B3}",
    ]

    static func containsPowerline(_ text: String) -> Bool {
        text.unicodeScalars.contains { powerlineScalars.contains($0) }
    }

    /// Split runs so every powerline character stands alone in a single-cell
    /// run (cell-accurate: columns come from the actual cells, so CJK or
    /// other non-ASCII neighbors never desync the shape's position).
    static func splitPowerlineRuns(
        _ runs: [StyleRun], cells: ArraySlice<Cell>
    ) -> [StyleRun] {
        var result: [StyleRun] = []
        let base = cells.startIndex
        for run in runs {
            guard containsPowerline(run.text) else {
                result.append(run)
                continue
            }
            var pending: StyleRun? = nil
            for col in run.colRange {
                let cell = cells[base + col]
                let isPL =
                    cell.text.unicodeScalars.count == 1
                    && powerlineScalars.contains(cell.text.unicodeScalars.first!)
                if isPL {
                    if let p = pending { result.append(p) }
                    pending = nil
                    result.append(
                        StyleRun(startCol: col, cellCount: 1, text: cell.text, hlID: run.hlID))
                } else if var p = pending {
                    p.cellCount += 1
                    p.text += cell.text
                    pending = p
                } else {
                    pending = StyleRun(
                        startCol: col, cellCount: 1, text: cell.text, hlID: run.hlID)
                }
            }
            if let p = pending { result.append(p) }
        }
        return result
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
        if fonts.powerlineGlyphs,
            run.text.unicodeScalars.count == 1,
            let scalar = run.text.unicodeScalars.first,
            Self.powerlineScalars.contains(scalar)
        {
            // Powerline cells are split into single-cell runs upstream
            // (splitPowerlineRuns), so any neighbors — ASCII, CJK, airline's
            // ≡/± — are unaffected. Draw the shape; done.
            drawPowerlineShape(scalar, in: rect, color: attrs.foreground, into: ctx)
        } else if !run.text.isEmpty, !run.text.allSatisfy({ $0 == " " }) {
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

    /// The five classic powerline glyphs as geometry (unflipped ctx, y-up).
    private func drawPowerlineShape(
        _ scalar: Unicode.Scalar, in cell: CGRect,
        color: NvimKit.RGBColor, into ctx: CGContext
    ) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let c = color.cgColor
        switch scalar {
        case "\u{E0B0}":  // solid right-pointing triangle
            ctx.setFillColor(c)
            ctx.move(to: CGPoint(x: cell.minX, y: cell.minY))
            ctx.addLine(to: CGPoint(x: cell.minX, y: cell.maxY))
            ctx.addLine(to: CGPoint(x: cell.maxX, y: cell.midY))
            ctx.closePath()
            ctx.fillPath()
        case "\u{E0B2}":  // solid left-pointing triangle
            ctx.setFillColor(c)
            ctx.move(to: CGPoint(x: cell.maxX, y: cell.minY))
            ctx.addLine(to: CGPoint(x: cell.maxX, y: cell.maxY))
            ctx.addLine(to: CGPoint(x: cell.minX, y: cell.midY))
            ctx.closePath()
            ctx.fillPath()
        case "\u{E0B1}", "\u{E0B3}":  // thin chevrons
            ctx.setStrokeColor(c)
            ctx.setLineWidth(max(1, fonts.underlineThickness))
            ctx.setLineJoin(.miter)
            let leftPointing = scalar == "\u{E0B3}"
            let tipX = leftPointing ? cell.minX + 1 : cell.maxX - 1
            let backX = leftPointing ? cell.maxX - 1 : cell.minX + 1
            ctx.move(to: CGPoint(x: backX, y: cell.maxY - 1))
            ctx.addLine(to: CGPoint(x: tipX, y: cell.midY))
            ctx.addLine(to: CGPoint(x: backX, y: cell.minY + 1))
            ctx.strokePath()
        case "\u{E0A0}":  // branch
            ctx.setStrokeColor(c)
            ctx.setLineWidth(max(1, fonts.underlineThickness))
            let x1 = cell.minX + cell.width * 0.32
            let x2 = cell.minX + cell.width * 0.72
            ctx.move(to: CGPoint(x: x1, y: cell.minY + cell.height * 0.12))
            ctx.addLine(to: CGPoint(x: x1, y: cell.maxY - cell.height * 0.12))
            ctx.move(to: CGPoint(x: x2, y: cell.minY + cell.height * 0.12))
            ctx.addLine(to: CGPoint(x: x2, y: cell.midY))
            ctx.addLine(to: CGPoint(x: x1, y: cell.midY + cell.height * 0.18))
            ctx.strokePath()
        default:
            break
        }
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
