import Testing
@testable import GridKit

@Suite struct DamageMapTests {
    @Test func adjacentSpansCoalesce() {
        var map = DamageMap()
        map.mark(row: 0, cols: 0..<3)
        map.mark(row: 0, cols: 3..<6) // touching
        #expect(map.rowSpans[0] == [0..<6])
    }

    @Test func overlappingSpansCoalesce() {
        var map = DamageMap()
        map.mark(row: 1, cols: 2..<8)
        map.mark(row: 1, cols: 5..<10)
        map.mark(row: 1, cols: 0..<3)
        #expect(map.rowSpans[1] == [0..<10])
    }

    @Test func disjointSpansStaySortedAndSeparate() {
        var map = DamageMap()
        map.mark(row: 2, cols: 10..<12)
        map.mark(row: 2, cols: 0..<2)
        map.mark(row: 2, cols: 5..<7)
        #expect(map.rowSpans[2] == [0..<2, 5..<7, 10..<12])
    }

    @Test func bridgingSpanMergesNeighbors() {
        var map = DamageMap()
        map.mark(row: 0, cols: 0..<2)
        map.mark(row: 0, cols: 4..<6)
        map.mark(row: 0, cols: 8..<10)
        map.mark(row: 0, cols: 2..<8) // bridges the first two and the third
        #expect(map.rowSpans[0] == [0..<10])
    }

    @Test func emptySpanIsIgnored() {
        var map = DamageMap()
        map.mark(row: 0, cols: 3..<3)
        #expect(map.isEmpty)
    }

    @Test func rowsAreIndependent() {
        var map = DamageMap()
        map.mark(row: 0, cols: 0..<5)
        map.mark(row: 3, cols: 2..<4)
        #expect(map.rowSpans == [0: [0..<5], 3: [2..<4]])
    }

    @Test func scrollAloneMakesMapNonEmpty() {
        var map = DamageMap()
        // A pure column shift where nothing is exposed vertically still
        // records the delta.
        map.recordScroll(ScrollDelta(top: 0, bottom: 0, left: 0, right: 0, rows: 1, cols: 0))
        #expect(!map.isEmpty)
        #expect(map.scrolls.count == 1)
    }
}
