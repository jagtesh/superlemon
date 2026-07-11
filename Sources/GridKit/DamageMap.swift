/// One `grid_scroll`, recorded before the cell moves were applied to the
/// model, so the renderer can rotate compatible row tiles or choose an atomic
/// final-model repaint for unsupported geometry.
/// Region is rows [top, bottom) x cols [left, right); positive `rows` moves
/// content up (destination row r receives source row r+rows), positive `cols`
/// moves content left, mirroring the wire semantics.
public struct ScrollDelta: Sendable, Equatable {
    public var top: Int
    public var bottom: Int
    public var left: Int
    public var right: Int
    public var rows: Int
    public var cols: Int

    public init(top: Int, bottom: Int, left: Int, right: Int, rows: Int, cols: Int) {
        self.top = top
        self.bottom = bottom
        self.left = left
        self.right = right
        self.rows = rows
        self.cols = cols
    }
}

/// Per-grid damage: per-row dirty column spans (coalesced, sorted) plus the
/// ordered scroll deltas since the damage was last consumed.
///
/// Renderer contract (DESIGN.md §5): apply `presentationScrolls` as row-cache
/// rotations where supported, then repaint `rowSpans` from the final model.
/// To keep that sound when a
/// scroll arrives while unconsumed damage exists, recording a scroll
/// *translates* existing spans inside the scrolled region along with the
/// content (stale pixels move with the blit) and marks the exposed strip dirty.
public struct DamageMap: Sendable, Equatable {
    /// row -> sorted, non-overlapping, non-adjacent dirty column spans.
    public private(set) var rowSpans: [Int: [Range<Int>]] = [:]
    /// Scroll deltas in the order they occurred.
    public private(set) var scrolls: [ScrollDelta] = []

    public init() {}

    public var isEmpty: Bool { rowSpans.isEmpty && scrolls.isEmpty }

    /// Ordered scroll operations with only adjacent, same-region,
    /// same-direction vertical moves folded together. Reversals, horizontal
    /// motion and conflicting regions remain explicit so renderers can fall
    /// back atomically. A folded displacement is capped at the region height;
    /// reaching that cap means no cached survivor row can be reused.
    package var presentationScrolls: [ScrollDelta] {
        var result: [ScrollDelta] = []
        for delta in scrolls {
            guard delta.cols == 0, delta.rows != 0, delta.bottom > delta.top,
                var previous = result.last,
                previous.cols == 0, previous.rows != 0,
                previous.top == delta.top, previous.bottom == delta.bottom,
                previous.left == delta.left, previous.right == delta.right,
                previous.rows.signum() == delta.rows.signum()
            else {
                result.append(delta)
                continue
            }

            let height = max(0, delta.bottom - delta.top)
            let limit = UInt(height)
            let magnitude = Int(min(
                limit,
                min(limit, previous.rows.magnitude) + min(limit, delta.rows.magnitude)))
            previous.rows = previous.rows.signum() * magnitude
            result[result.count - 1] = previous
        }
        return result
    }

    /// Mark columns of one row dirty, coalescing with existing spans.
    public mutating func mark(row: Int, cols: Range<Int>) {
        guard !cols.isEmpty else { return }
        var spans = rowSpans[row] ?? []
        Self.insert(cols, into: &spans)
        rowSpans[row] = spans
    }

    /// Mark an entire rows x cols grid dirty (grid_clear / grid_resize).
    public mutating func markAll(rows: Int, cols: Int) {
        guard rows > 0, cols > 0 else { return }
        for r in 0..<rows { mark(row: r, cols: 0..<cols) }
    }

    /// Record a scroll: translate existing in-region damage with the content,
    /// append the delta, and mark the exposed strip dirty.
    public mutating func recordScroll(_ delta: ScrollDelta) {
        translateSpans(for: delta)
        scrolls.append(delta)

        // Rows exposed by a vertical shift.
        if delta.rows > 0 {
            for r in max(delta.top, delta.bottom - delta.rows)..<delta.bottom {
                mark(row: r, cols: delta.left..<delta.right)
            }
        } else if delta.rows < 0 {
            for r in delta.top..<min(delta.bottom, delta.top - delta.rows) {
                mark(row: r, cols: delta.left..<delta.right)
            }
        }
        // Columns exposed by a horizontal shift.
        if delta.cols != 0 {
            let lo = delta.cols > 0 ? max(delta.left, delta.right - delta.cols) : delta.left
            let hi = delta.cols > 0 ? delta.right : min(delta.right, delta.left - delta.cols)
            if lo < hi {
                for r in delta.top..<delta.bottom { mark(row: r, cols: lo..<hi) }
            }
        }
    }

    /// Move dirty spans inside the scrolled region the same way the blit moves
    /// pixels; parts shifted out of the region are dropped (overwritten).
    private mutating func translateSpans(for delta: ScrollDelta) {
        guard !rowSpans.isEmpty else { return }
        var translated: [Int: [Range<Int>]] = [:]
        func add(_ row: Int, _ span: Range<Int>) {
            var spans = translated[row] ?? []
            Self.insert(span, into: &spans)
            translated[row] = spans
        }
        for (row, spans) in rowSpans {
            let rowInRegion = row >= delta.top && row < delta.bottom
            for span in spans {
                guard rowInRegion else { add(row, span); continue }
                // Parts outside the region's columns stay put.
                if let left = Self.intersect(span, upper: delta.left) { add(row, left) }
                if let right = Self.intersect(span, lower: delta.right) { add(row, right) }
                // The in-region part moves with the content.
                guard let inside = Self.intersect(span, lower: delta.left, upper: delta.right)
                else { continue }
                let destRow = row - delta.rows
                guard destRow >= delta.top, destRow < delta.bottom else { continue }
                let shifted = (inside.lowerBound - delta.cols)..<(inside.upperBound - delta.cols)
                if let clipped = Self.intersect(shifted, lower: delta.left, upper: delta.right) {
                    add(destRow, clipped)
                }
            }
        }
        rowSpans = translated
    }

    /// Merge a span into a sorted span list, coalescing overlapping *and*
    /// adjacent (touching) spans.
    static func insert(_ range: Range<Int>, into spans: inout [Range<Int>]) {
        guard !range.isEmpty else { return }
        var merged = range
        var result: [Range<Int>] = []
        var placed = false
        for s in spans {
            if s.upperBound < merged.lowerBound {
                result.append(s)
            } else if s.lowerBound > merged.upperBound {
                if !placed {
                    result.append(merged)
                    placed = true
                }
                result.append(s)
            } else {
                merged = min(s.lowerBound, merged.lowerBound)..<max(s.upperBound, merged.upperBound)
            }
        }
        if !placed { result.append(merged) }
        spans = result
    }

    private static func intersect(
        _ span: Range<Int>, lower: Int = Int.min, upper: Int = Int.max
    ) -> Range<Int>? {
        let lo = max(span.lowerBound, lower)
        let hi = min(span.upperBound, upper)
        return lo < hi ? lo..<hi : nil
    }
}
