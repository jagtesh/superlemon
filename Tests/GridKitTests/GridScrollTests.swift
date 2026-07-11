import Testing
import NvimKit
@testable import GridKit

@MainActor
@Suite struct GridScrollTests {
    /// 6x6 grid with row r filled with its letter: "aaaaaa", "bbbbbb", ...
    func makeLetterStore() -> GridStore {
        let store = makeStore(rows: 6, cols: 6)
        var events: [UIEvent] = []
        for (r, ch) in "abcdef".enumerated() {
            events.append(line(1, r, 0, [run(String(ch), hl: r, rep: 6)]))
        }
        events.append(.flush)
        _ = store.apply(RedrawBatch(events: events))
        return store
    }

    @Test func scrollUpMovesContentTowardTop() {
        let store = makeLetterStore()
        store.apply(batch(.gridScroll(grid: 1, top: 0, bottom: 6, left: 0, right: 6, rows: 2, cols: 0)))
        let grid = store.grids[1]!
        #expect(grid.rowText(0) == "cccccc")
        #expect(grid.rowText(3) == "ffffff")
        // Exposed rows keep old content until grid_line arrives.
        #expect(grid.rowText(4) == "eeeeee")
        #expect(grid.rowText(5) == "ffffff")
        // hl moved with the text.
        #expect(grid[0, 0].hlID == 2)
    }

    @Test func scrollDownMovesContentTowardBottom() {
        let store = makeLetterStore()
        store.apply(batch(.gridScroll(grid: 1, top: 0, bottom: 6, left: 0, right: 6, rows: -2, cols: 0)))
        let grid = store.grids[1]!
        #expect(grid.rowText(5) == "dddddd")
        #expect(grid.rowText(2) == "aaaaaa")
        // Exposed rows at the top keep old content.
        #expect(grid.rowText(0) == "aaaaaa")
        #expect(grid.rowText(1) == "bbbbbb")
    }

    @Test func regionBoundedScrollLeavesOutsideUntouched() {
        let store = makeLetterStore()
        store.apply(batch(.gridScroll(grid: 1, top: 1, bottom: 4, left: 0, right: 6, rows: 1, cols: 0)))
        let grid = store.grids[1]!
        #expect(grid.rowText(0) == "aaaaaa") // above region: untouched
        #expect(grid.rowText(1) == "cccccc")
        #expect(grid.rowText(2) == "dddddd")
        #expect(grid.rowText(3) == "dddddd") // exposed, keeps old content
        #expect(grid.rowText(4) == "eeeeee") // below region: untouched
        #expect(grid.rowText(5) == "ffffff")
    }

    @Test func columnBoundedScrollOnlyShiftsRegionColumns() {
        let store = makeStore(rows: 2, cols: 6)
        _ = store.apply(batch(line(1, 0, 0, runs("abcdef")), .flush))
        store.apply(batch(.gridScroll(grid: 1, top: 0, bottom: 1, left: 1, right: 5, rows: 0, cols: 2)))
        let grid = store.grids[1]!
        // cols 1..<5 shift left by 2: dest c <- src c+2 => b,c,d,e -> d,e,?,?
        #expect(grid.rowText(0) == "adedef")
    }

    @Test func negativeColumnScrollShiftsRight() {
        let store = makeStore(rows: 1, cols: 6)
        _ = store.apply(batch(line(1, 0, 0, runs("abcdef")), .flush))
        store.apply(batch(.gridScroll(grid: 1, top: 0, bottom: 1, left: 0, right: 6, rows: 0, cols: -2)))
        let grid = store.grids[1]!
        // dest c <- src c-2: right shift by 2; exposed cols 0..2 keep old.
        #expect(grid.rowText(0) == "ababcd")
    }

    @Test func partialWidthVerticalScrollCopiesOnlyRegionColumns() {
        let store = makeStore(rows: 4, cols: 6)
        _ = store.apply(batch(
            line(1, 0, 0, runs("abcdef")),
            line(1, 1, 0, runs("ghijkl")),
            line(1, 2, 0, runs("mnopqr")),
            line(1, 3, 0, runs("stuvwx")),
            .flush
        ))

        store.apply(batch(.gridScroll(
            grid: 1, top: 0, bottom: 4, left: 1, right: 5, rows: 1, cols: 0
        )))

        let grid = store.grids[1]!
        #expect(grid.rowText(0) == "ahijkf")
        #expect(grid.rowText(1) == "gnopql")
        #expect(grid.rowText(2) == "mtuvwr")
        #expect(grid.rowText(3) == "stuvwx")
    }

    @Test func combinedVerticalAndHorizontalScrollUsesOriginalRows() {
        let store = makeStore(rows: 3, cols: 5)
        _ = store.apply(batch(
            line(1, 0, 0, runs("abcde")),
            line(1, 1, 0, runs("fghij")),
            line(1, 2, 0, runs("klmno")),
            .flush
        ))

        store.apply(batch(.gridScroll(
            grid: 1, top: 0, bottom: 3, left: 0, right: 5, rows: 1, cols: 1
        )))

        let grid = store.grids[1]!
        #expect(grid.rowText(0) == "ghije")
        #expect(grid.rowText(1) == "lmnoj")
        #expect(grid.rowText(2) == "klmno")
    }

    @Test func sharedRowsRemainValueIndependentAfterScrollAndLineUpdate() {
        var grid = Grid(id: 1, rows: 4, cols: 4)
        for (row, character) in "abcd".enumerated() {
            grid.applyLine(row: row, colStart: 0, runs: [
                run(String(character), hl: row, rep: 4)
            ])
        }
        let snapshot = grid

        grid.applyScroll(
            top: 0, bottom: 4, left: 0, right: 4, rowDelta: 1, colDelta: 0
        )
        // Rows 2 and 3 now reference the same pre-scroll row buffer. Updating
        // the exposed row must COW that row without changing the moved row or
        // the earlier Grid snapshot.
        grid.applyLine(row: 3, colStart: 0, runs: [run("x", rep: 4)])

        #expect(grid.rowText(2) == "dddd")
        #expect(grid.rowText(3) == "xxxx")
        #expect(snapshot.rowText(0) == "aaaa")
        #expect(snapshot.rowText(3) == "dddd")
        #expect(grid.cells.count == 16)
        #expect(grid.cells.map(\.text).joined() == "bbbbccccddddxxxx")
    }

    @Test func scrollLargerThanRegionPreservesCellsForReplacementLines() {
        let store = makeLetterStore()
        store.apply(batch(.gridScroll(
            grid: 1, top: 1, bottom: 4, left: 0, right: 6, rows: -4, cols: 0
        )))

        let grid = store.grids[1]!
        #expect((0..<6).map(grid.rowText) == [
            "aaaaaa", "bbbbbb", "cccccc", "dddddd", "eeeeee", "ffffff",
        ])
    }

    @Test func scrollDeltaRecordedInOrderWithExposedDamage() {
        let store = makeLetterStore()
        store.apply(batch(
            .gridScroll(grid: 1, top: 0, bottom: 6, left: 0, right: 6, rows: 1, cols: 0),
            .gridScroll(grid: 1, top: 2, bottom: 5, left: 1, right: 4, rows: -1, cols: 0)
        ))
        let damage = store.grids[1]!.damage
        #expect(damage.scrolls == [
            ScrollDelta(top: 0, bottom: 6, left: 0, right: 6, rows: 1, cols: 0),
            ScrollDelta(top: 2, bottom: 5, left: 1, right: 4, rows: -1, cols: 0),
        ])
        // First scroll exposes row 5 fully; second exposes row 2 cols 1..<4.
        #expect(damage.rowSpans[5] == [0..<6])
        #expect(damage.rowSpans[2] == [1..<4])
    }

    @Test func existingDamageTranslatesWithScroll() {
        let store = makeLetterStore()
        // Damage row 3 (no flush), then scroll the whole grid up by one:
        // the stale pixels move to row 2, and row 5 is exposed.
        store.apply(batch(line(1, 3, 1, runs("xy", hl: 1))))
        store.apply(batch(.gridScroll(grid: 1, top: 0, bottom: 6, left: 0, right: 6, rows: 1, cols: 0)))
        let damage = store.grids[1]!.damage
        #expect(damage.rowSpans[2] == [1..<3])
        #expect(damage.rowSpans[3] == nil)
        #expect(damage.rowSpans[5] == [0..<6])
    }

    @Test func damageOutsideScrollRegionStaysPut() {
        let store = makeLetterStore()
        store.apply(batch(line(1, 0, 0, runs("zz", hl: 1))))
        store.apply(batch(.gridScroll(grid: 1, top: 2, bottom: 6, left: 0, right: 6, rows: 1, cols: 0)))
        let damage = store.grids[1]!.damage
        #expect(damage.rowSpans[0] == [0..<2])
    }

    @Test func damageScrolledOutOfRegionIsDropped() {
        let store = makeLetterStore()
        // Damage the region's top row, then scroll up: content (and staleness)
        // at row 2 leaves the region and is gone.
        store.apply(batch(line(1, 2, 0, runs("q", hl: 1))))
        store.apply(batch(.gridScroll(grid: 1, top: 2, bottom: 6, left: 0, right: 6, rows: 1, cols: 0)))
        let damage = store.grids[1]!.damage
        // Row 1 is outside the region: nothing translated there.
        #expect(damage.rowSpans[1] == nil)
        // Row 2's only damage was dropped; exposed strip is row 5.
        #expect(damage.rowSpans[2] == nil)
        #expect(damage.rowSpans[5] == [0..<6])
    }

    @Test func scrollOnUnknownGridIsIgnored() {
        let store = makeStore()
        store.apply(batch(.gridScroll(grid: 9, top: 0, bottom: 3, left: 0, right: 3, rows: 1, cols: 0)))
        #expect(store.grids[9] == nil)
    }
}
