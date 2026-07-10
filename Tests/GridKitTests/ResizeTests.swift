import Testing
import NvimKit
@testable import GridKit

@MainActor
@Suite struct ResizeTests {
    @Test func resizeCreatesUnknownGridFullyDamaged() {
        let store = GridStore()
        store.apply(batch(.gridResize(grid: 2, width: 8, height: 3)))
        let grid = store.grids[2]!
        #expect(grid.rows == 3)
        #expect(grid.cols == 8)
        #expect(grid.cells.allSatisfy { $0 == .blank })
        #expect(grid.damage.rowSpans == fullDamage(rows: 3, cols: 8))
    }

    @Test func growPreservesContentAndBlanksNewCells() {
        let store = makeStore(rows: 3, cols: 4)
        store.apply(batch(line(1, 0, 0, runs("abcd", hl: 2)), line(1, 2, 0, runs("wxyz", hl: 3))))
        store.apply(batch(.gridResize(grid: 1, width: 6, height: 5)))
        let grid = store.grids[1]!
        #expect(grid.rows == 5 && grid.cols == 6)
        #expect(grid.rowText(0) == "abcd")
        #expect(grid[0, 3] == Cell(text: "d", hlID: 2))
        #expect(grid[0, 4] == .blank)
        #expect(grid[2, 0] == Cell(text: "w", hlID: 3))
        #expect(grid.rowCells(3).allSatisfy { $0 == .blank })
        #expect(grid.rowCells(4).allSatisfy { $0 == .blank })
    }

    @Test func shrinkDropsOutOfBoundsContent() {
        let store = makeStore(rows: 4, cols: 6)
        store.apply(batch(
            line(1, 0, 0, runs("abcdef")),
            line(1, 3, 0, runs("gone!!"))
        ))
        store.apply(batch(.gridResize(grid: 1, width: 3, height: 2)))
        let grid = store.grids[1]!
        #expect(grid.rows == 2 && grid.cols == 3)
        #expect(grid.rowText(0) == "abc")
        // Growing back yields blanks where content was dropped.
        store.apply(batch(.gridResize(grid: 1, width: 6, height: 4)))
        let regrown = store.grids[1]!
        #expect(regrown.rowText(0) == "abc")
        #expect(regrown[0, 3] == .blank)
        #expect(regrown.rowCells(3).allSatisfy { $0 == .blank })
    }

    @Test func resizeDamagesEverythingAndDropsPendingScrolls() {
        let store = makeStore(rows: 4, cols: 4)
        store.apply(batch(.gridScroll(grid: 1, top: 0, bottom: 4, left: 0, right: 4, rows: 1, cols: 0)))
        store.apply(batch(.gridResize(grid: 1, width: 5, height: 5)))
        let damage = store.grids[1]!.damage
        #expect(damage.scrolls.isEmpty)
        #expect(damage.rowSpans == fullDamage(rows: 5, cols: 5))
    }

    @Test func clearBlanksCellsAndDamagesEverything() {
        let store = makeStore(rows: 3, cols: 4)
        _ = store.apply(batch(line(1, 1, 0, runs("data", hl: 4)), .flush))
        store.apply(batch(.gridClear(grid: 1)))
        let grid = store.grids[1]!
        #expect(grid.cells.allSatisfy { $0 == .blank })
        #expect(grid.damage.rowSpans == fullDamage(rows: 3, cols: 4))
        #expect(grid.damage.scrolls.isEmpty)
    }

    @Test func destroyRemovesGrid() {
        let store = makeStore()
        store.apply(batch(.gridResize(grid: 2, width: 4, height: 4)))
        store.apply(batch(.gridDestroy(grid: 2)))
        #expect(store.grids[2] == nil)
        #expect(store.grids[1] != nil)
    }
}
