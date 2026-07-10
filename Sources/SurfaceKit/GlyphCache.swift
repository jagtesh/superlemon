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

/// LRU cache of shaped runs, keyed by (text, font variant) — deliberately
/// COLOR-INDEPENDENT (DESIGN §6 step 5): colors are applied at draw time, so
/// one entry serves every theme. Owned by a TextRasterizer and discarded
/// wholesale on font change.
final class GlyphCache {
    private struct Key: Hashable {
        let text: String
        let variant: UInt8
    }

    private var store: [Key: (run: ShapedRun, tick: UInt64)] = [:]
    private var tick: UInt64 = 0
    let capacity: Int
    private(set) var hits = 0
    private(set) var misses = 0

    init(capacity: Int = 4096) {
        self.capacity = max(8, capacity)
    }

    func shapedRun(text: String, variant: FontSet.Variant, font: CTFont) -> ShapedRun {
        tick += 1
        let key = Key(text: text, variant: variant.rawValue)
        if let entry = store[key] {
            hits += 1
            store[key] = (entry.run, tick)
            return entry.run
        }
        misses += 1
        let run = Self.shape(text: text, font: font)
        store[key] = (run, tick)
        evictIfNeeded()
        return run
    }

    /// Shape one string with Core Text: ligatures form naturally within the
    /// run; font cascade handles fallback for scripts the base font lacks.
    private static func shape(text: String, font: CTFont) -> ShapedRun {
        let attributed = NSAttributedString(
            string: text,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let line = CTLineCreateWithAttributedString(attributed)
        var segments: [ShapedRun.Segment] = []
        for run in (CTLineGetGlyphRuns(line) as NSArray) {
            let run = run as! CTRun
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
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
