import Testing
import NvimKit
@testable import GridKit

@MainActor
@Suite struct FlushTests {
    @Test func batchWithoutFlushReturnsNil() {
        let store = makeStore()
        let result = store.apply(batch(line(1, 0, 0, runs("hi"))))
        #expect(result == nil)
        // ...but the model advanced and damage accumulated.
        #expect(store.grids[1]!.rowText(0) == "hi")
        #expect(!store.grids[1]!.damage.isEmpty)
    }

    @Test func damageAccumulatesAcrossBatchesUntilFlush() {
        let store = makeStore()
        #expect(store.apply(batch(line(1, 0, 0, runs("aa", hl: 1)))) == nil)
        #expect(store.apply(batch(line(1, 2, 5, runs("bb", hl: 2)))) == nil)
        let result = store.apply(batch(line(1, 0, 2, runs("c")), .flush))!
        #expect(result.damagedGrids.count == 1)
        let damage = result.damagedGrids[0].damage
        #expect(damage.rowSpans == [0: [0..<3], 2: [5..<7]])
    }

    @Test func flushConsumesDamage() {
        let store = makeStore()
        _ = store.apply(batch(line(1, 1, 0, runs("x")), .flush))
        #expect(store.grids[1]!.damage.isEmpty)
        // A second flush with no intervening damage reports nothing.
        let result = store.apply(batch(.flush))!
        #expect(result.damagedGrids.isEmpty)
    }

    @Test func onlyDamagedGridsAreReported() {
        let store = makeStore()
        _ = store.apply(batch(
            .gridResize(grid: 2, width: 10, height: 5),
            .gridResize(grid: 3, width: 10, height: 5),
            .flush
        ))
        let result = store.apply(batch(line(3, 0, 0, runs("only")), .flush))!
        #expect(result.damagedGrids.map(\.grid.id) == [3])
        // But all grids ride along for layout.
        #expect(Set(result.grids.keys) == [1, 2, 3])
    }

    @Test func damagedGridsSortedByID() {
        let store = makeStore()
        _ = store.apply(batch(
            .gridResize(grid: 5, width: 4, height: 2),
            .gridResize(grid: 2, width: 4, height: 2),
            .flush
        ))
        let result = store.apply(batch(
            line(5, 0, 0, runs("b")),
            line(2, 0, 0, runs("a")),
            line(1, 0, 0, runs("c")),
            .flush
        ))!
        #expect(result.damagedGrids.map(\.grid.id) == [1, 2, 5])
    }

    @Test func snapshotInResultIsImmutable() {
        let store = makeStore()
        let result = store.apply(batch(line(1, 0, 0, runs("old")), .flush))!
        let snapshot = result.damagedGrids[0].grid
        // Mutating the store afterward must not affect the snapshot (COW).
        store.apply(batch(line(1, 0, 0, runs("new"))))
        #expect(snapshot.rowText(0) == "old")
        #expect(store.grids[1]!.rowText(0) == "new")
    }

    @Test func flushCarriesCursorModeTitleAndFlags() {
        let store = makeStore()
        var normal = ModeInfo()
        normal.name = "normal"
        normal.cursorShape = .block
        var insert = ModeInfo()
        insert.name = "insert"
        insert.cursorShape = .vertical
        let result = store.apply(batch(
            .setTitle("main.swift — superlemon"),
            .modeInfoSet(cursorStyleEnabled: true, modes: [normal, insert]),
            .modeChange(mode: "insert", modeIndex: 1),
            .gridCursorGoto(grid: 1, row: 4, col: 7),
            .busyStart,
            .mouseOff,
            .flush
        ))!
        #expect(result.cursor == CursorPosition(grid: 1, row: 4, col: 7))
        #expect(result.mode?.name == "insert")
        #expect(result.mode?.cursorShape == .vertical)
        #expect(result.title == "main.swift — superlemon")
        #expect(result.isBusy)
        #expect(!result.isMouseEnabled)
        #expect(store.currentModeName == "insert")
    }

    @Test func cursorOwnershipMovesBetweenGrids() {
        let store = makeStore()
        _ = store.apply(batch(.gridResize(grid: 2, width: 5, height: 5), .flush))
        store.apply(batch(.gridCursorGoto(grid: 2, row: 1, col: 1)))
        #expect(store.grids[2]!.hasCursor)
        #expect(!store.grids[1]!.hasCursor)
        store.apply(batch(.gridCursorGoto(grid: 1, row: 0, col: 0)))
        #expect(store.grids[1]!.hasCursor)
        #expect(!store.grids[2]!.hasCursor)
    }

    @Test func scrollDeltasAppearInFlushResultAndAreConsumed() {
        let store = makeStore(rows: 6, cols: 6)
        let result = store.apply(batch(
            .gridScroll(grid: 1, top: 0, bottom: 6, left: 0, right: 6, rows: 1, cols: 0),
            line(1, 5, 0, runs("bottom")),
            .flush
        ))!
        let damage = result.damagedGrids[0].damage
        #expect(damage.scrolls == [ScrollDelta(top: 0, bottom: 6, left: 0, right: 6, rows: 1, cols: 0)])
        #expect(damage.rowSpans[5] == [0..<6])
        #expect(store.grids[1]!.damage.isEmpty)
    }
}
