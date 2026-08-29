import CoreText
import Foundation

/// A shaped style run: glyphs + positions per fallback segment, positions
/// relative to the run origin (x from 0, y on the baseline). Core Text may
/// split one string across several fonts (CJK, emoji, symbols) — each split
/// is one segment.
struct ShapedRun {
    struct Segment {
        let font: CTFont
        let glyphs: [CGGlyph]
        let positions: [CGPoint]
    }
    let segments: [Segment]
}

/// LRU cache of shaped runs, keyed by (text, font variant, columns) —
/// deliberately COLOR-INDEPENDENT (DESIGN §6): colors are applied at draw
/// time, so one entry serves every theme. Owned by a TextRasterizer and
/// discarded wholesale on font change.
final class GlyphCache {
    private struct Key: Hashable {
        let text: String
        let variant: UInt8
        let columns: [Int]
    }

    private var store: [Key: (run: ShapedRun, tick: UInt64)] = [:]
    private var tick: UInt64 = 0
    let capacity: Int
    private(set) var hits = 0
    private(set) var misses = 0
    /// Standard ligatures on/off; set once by the owning TextRasterizer
    /// (the cache is rebuilt on font changes, so entries never mix modes).
    var ligatures = true

    init(capacity: Int = 4096) {
        self.capacity = max(8, capacity)
    }

    /// `columns[i]` is the grid column (relative to the run's own origin)
    /// that the i-th Character of `text` belongs to — the caller (a grid
    /// StyleRun, or a single-grapheme cell) already knows this exactly, so
    /// the shaper never has to guess a character's width from the text
    /// itself. Included in the cache key so identical text shaped against
    /// two different layouts can't collide.
    func shapedRun(
        text: String, variant: FontSet.Variant, font: CTFont,
        cellWidth: CGFloat, baseAdvance: CGFloat, columns: [Int]
    ) -> ShapedRun {
        tick += 1
        let key = Key(text: text, variant: variant.rawValue, columns: columns)
        if let entry = store[key] {
            hits += 1
            store[key] = (entry.run, tick)
            return entry.run
        }
        misses += 1
        let run = shape(
            text: text, font: font, cellWidth: cellWidth, baseAdvance: baseAdvance,
            columns: columns)
        store[key] = (run, tick)
        evictIfNeeded()
        return run
    }

    /// Shape one string with Core Text: ligatures form naturally within the
    /// run; font cascade handles fallback for scripts the base font lacks.
    private func shape(
        text: String, font: CTFont, cellWidth: CGFloat, baseAdvance: CGFloat,
        columns: [Int]
    ) -> ShapedRun {
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTLigatureAttributeName as String): ligatures ? 1 : 0,
            ])
        let line = CTLineCreateWithAttributedString(attributed)
        // Map each UTF-16 offset that starts a Character to that character's
        // 0-based index in `text`, so a Core Text glyph's string index
        // (always a grapheme-cluster start) can be turned into an index
        // into `columns`.
        var characterIndexForOffset: [Int: Int] = [:]
        var utf16Offset = 0
        for (index, character) in text.enumerated() {
            characterIndexForOffset[utf16Offset] = index
            utf16Offset += String(character).utf16.count
        }
        var segments: [ShapedRun.Segment] = []
        for run in (CTLineGetGlyphRuns(line) as NSArray) {
            let run = run as! CTRun
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            // Snap each glyph to its cell column: natural mono advances are
            // fractional (7.83…) while cells are integral; without this,
            // splitting a run (visual selection) re-anchors the tail and the
            // letter spacing visibly shifts. The column comes from the
            // caller-supplied `columns` (the grid's own layout), not from
            // classifying the glyph's text or from Core Text's cumulative
            // advance — a fallback font's CJK/emoji glyph rarely measures
            // exactly N times the primary font's cell.
            if baseAdvance > 0, cellWidth > 0 {
                var stringIndices = [CFIndex](repeating: 0, count: count)
                CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &stringIndices)
                for i in positions.indices {
                    let offset = Int(stringIndices[i])
                    let column: CGFloat
                    if let charIndex = characterIndexForOffset[offset], charIndex < columns.count {
                        column = CGFloat(columns[charIndex])
                    } else {
                        // Should not happen (every string index Core Text
                        // hands back is a character-start offset, and the
                        // caller is expected to supply one column per
                        // character); fall back to the old cumulative-
                        // advance snap rather than mis-position silently.
                        column = (positions[i].x / baseAdvance).rounded()
                    }
                    positions[i].x = column * cellWidth
                }
            }
            let attrs = CTRunGetAttributes(run) as NSDictionary
            let runFont = attrs[kCTFontAttributeName as String] as! CTFont
            segments.append(.init(font: runFont, glyphs: glyphs, positions: positions))
        }
        return ShapedRun(segments: segments)
    }

    /// Drop the least-recently-used quarter when over capacity.
    private func evictIfNeeded() {
        guard store.count > capacity else { return }
        let sorted = store.sorted { $0.value.tick < $1.value.tick }
        for (key, _) in sorted.prefix(store.count - capacity + capacity / 4) {
            store.removeValue(forKey: key)
        }
    }
}
