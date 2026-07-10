import Testing
import NvimKit
@testable import GridKit

@MainActor
@Suite struct GridLineTests {
    @Test func writesCellsAtColStart() {
        let store = makeStore()
        store.apply(batch(line(1, 2, 5, runs("hello", hl: 3))))
        let grid = store.grids[1]!
        #expect(grid[2, 5] == Cell(text: "h", hlID: 3))
        #expect(grid[2, 9] == Cell(text: "o", hlID: 3))
        // Cells before colStart untouched (still blank from resize).
        #expect(grid[2, 4] == .blank)
        #expect(grid.rowText(2) == "hello")
    }

    @Test func repeatCountExpandsRuns() {
        let store = makeStore()
        store.apply(batch(line(1, 0, 0, [run("~", hl: 7), run(" ", hl: 0, rep: 19)])))
        let grid = store.grids[1]!
        #expect(grid[0, 0] == Cell(text: "~", hlID: 7))
        for c in 1..<20 {
            #expect(grid[0, c] == Cell(text: " ", hlID: 0))
        }
    }

    @Test func hlPersistsPerRunAndAcrossPartialUpdates() {
        let store = makeStore()
        store.apply(batch(line(1, 1, 0, [
            run("a", hl: 1), run("b", hl: 1), run("c", hl: 2, rep: 3),
        ])))
        var grid = store.grids[1]!
        #expect(grid[1, 0].hlID == 1)
        #expect(grid[1, 1].hlID == 1)
        #expect(grid[1, 2].hlID == 2)
        #expect(grid[1, 4].hlID == 2)

        // A later partial write must not disturb neighboring cells' hl.
        store.apply(batch(line(1, 1, 2, [run("X", hl: 9)])))
        grid = store.grids[1]!
        #expect(grid[1, 1] == Cell(text: "b", hlID: 1))
        #expect(grid[1, 2] == Cell(text: "X", hlID: 9))
        #expect(grid[1, 3] == Cell(text: "c", hlID: 2))
    }

    @Test func doubleWidthCellsStoredAsIs() {
        let store = makeStore()
        store.apply(batch(line(1, 0, 0, [
            run("漢", hl: 5), run("", hl: 5), run("字", hl: 5), run("", hl: 5), run("!", hl: 5),
        ])))
        let grid = store.grids[1]!
        #expect(grid[0, 0] == Cell(text: "漢", hlID: 5))
        #expect(grid[0, 1] == Cell(text: "", hlID: 5))
        #expect(grid[0, 1].isEmpty)
        #expect(grid[0, 2] == Cell(text: "字", hlID: 5))
        #expect(grid[0, 3] == Cell(text: "", hlID: 5))
        #expect(grid[0, 4] == Cell(text: "!", hlID: 5))
    }

    @Test func lineMarksDamageForWrittenSpanOnly() {
        let store = makeStore()
        _ = store.apply(batch(.flush)) // drain resize damage
        store.apply(batch(line(1, 3, 4, runs("abc"))))
        #expect(store.grids[1]!.damage.rowSpans == [3: [4..<7]])
    }

    @Test func overflowingRunsAreClippedAtGridEdge() {
        let store = makeStore(rows: 4, cols: 6)
        _ = store.apply(batch(.flush))
        store.apply(batch(line(1, 0, 4, [run("x", hl: 1, rep: 10)])))
        let grid = store.grids[1]!
        #expect(grid[0, 4].text == "x")
        #expect(grid[0, 5].text == "x")
        #expect(grid.damage.rowSpans == [0: [4..<6]])
    }

    @Test func eventsForUnknownGridsAreIgnored() {
        let store = makeStore()
        // None of these may crash or create grids.
        let result = store.apply(batch(
            line(42, 0, 0, runs("boom")),
            .gridScroll(grid: 42, top: 0, bottom: 5, left: 0, right: 5, rows: 1, cols: 0),
            .gridClear(grid: 42),
            .gridDestroy(grid: 42),
            .winPos(grid: 42, win: 1, startRow: 0, startCol: 0, width: 5, height: 5),
            .winHide(grid: 42),
            .winViewport(grid: 42, win: 1, topline: 0, botline: 1, curline: 0,
                         curcol: 0, lineCount: 1, scrollDelta: 0),
            .flush
        ))
        #expect(store.grids[42] == nil)
        #expect(result != nil)
        #expect(result!.damagedGrids.isEmpty)
    }

    @Test func outOfBoundsRowIgnored() {
        let store = makeStore(rows: 4, cols: 6)
        _ = store.apply(batch(.flush))
        store.apply(batch(line(1, 99, 0, runs("no")), line(1, -1, 0, runs("no"))))
        #expect(store.grids[1]!.damage.isEmpty)
    }
}
