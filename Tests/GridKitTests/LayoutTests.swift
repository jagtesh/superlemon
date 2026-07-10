import Testing
import NvimKit
@testable import GridKit

@MainActor
@Suite struct LayoutTests {
    /// Outer grid 30 rows x 100 cols; grid 2 is a window at (5, 10), 20x40.
    func makeStoreWithWindow() -> GridStore {
        let store = makeStore(rows: 30, cols: 100)
        _ = store.apply(batch(
            .gridResize(grid: 2, width: 40, height: 20),
            .winPos(grid: 2, win: 1000, startRow: 5, startCol: 10, width: 40, height: 20),
            .flush
        ))
        return store
    }

    func resolve(_ store: GridStore) -> [ResolvedGridFrame] {
        GridLayout.resolve(outerRows: 30, outerCols: 100, grids: store.grids)
    }

    func addFloat(_ store: GridStore, grid: Int = 5, anchor: String, anchorGrid: Int = 2,
                  row: Double, col: Double, width: Int = 10, height: Int = 6, z: Int = 50) {
        _ = store.apply(batch(
            .gridResize(grid: grid, width: width, height: height),
            .winFloatPos(grid: grid, win: 2000, anchor: anchor, anchorGrid: anchorGrid,
                         anchorRow: row, anchorCol: col, focusable: true, zIndex: z),
            .flush
        ))
    }

    func frame(_ frames: [ResolvedGridFrame], _ id: Int) -> ResolvedGridFrame? {
        frames.first { $0.gridID == id }
    }

    @Test func outerGridAndWindowFrames() {
        let store = makeStoreWithWindow()
        let frames = resolve(store)
        #expect(frame(frames, 1)?.rect == GridRect(row: 0, col: 0, width: 100, height: 30))
        #expect(frame(frames, 1)?.zIndex == GridLayout.baseZ)
        #expect(frame(frames, 2)?.rect == GridRect(row: 5, col: 10, width: 40, height: 20))
        #expect(frame(frames, 2)?.zIndex == GridLayout.windowZ)
    }

    @Test func floatAnchoredNW() {
        let store = makeStoreWithWindow()
        addFloat(store, anchor: "NW", row: 2, col: 3)
        // NW corner at anchor-grid-relative (2,3): (5+2, 10+3).
        #expect(frame(resolve(store), 5)?.rect == GridRect(row: 7, col: 13, width: 10, height: 6))
    }

    @Test func floatAnchoredNE() {
        let store = makeStoreWithWindow()
        addFloat(store, anchor: "NE", row: 2, col: 30)
        // NE corner at (7, 40): left edge = 40 - width.
        #expect(frame(resolve(store), 5)?.rect == GridRect(row: 7, col: 30, width: 10, height: 6))
    }

    @Test func floatAnchoredSW() {
        let store = makeStoreWithWindow()
        addFloat(store, anchor: "SW", row: 10, col: 3)
        // SW corner at (15, 13): top edge = 15 - height.
        #expect(frame(resolve(store), 5)?.rect == GridRect(row: 9, col: 13, width: 10, height: 6))
    }

    @Test func floatAnchoredSE() {
        let store = makeStoreWithWindow()
        addFloat(store, anchor: "SE", row: 10, col: 30)
        #expect(frame(resolve(store), 5)?.rect == GridRect(row: 9, col: 30, width: 10, height: 6))
    }

    @Test func floatClampedToOuterGrid() {
        let store = makeStoreWithWindow()
        // NW anchor near the window's bottom-right pushes past the outer
        // edge (row 5+18=23+6 > 30, col 10+95=105 > 100): clamp.
        addFloat(store, anchor: "NW", row: 18, col: 95)
        #expect(frame(resolve(store), 5)?.rect == GridRect(row: 23, col: 90, width: 10, height: 6))

        // Negative resolution (SW at row -2 -> top = 5-2-6 = -3) clamps to 0.
        addFloat(store, grid: 6, anchor: "SW", row: -2, col: -20)
        #expect(frame(resolve(store), 6)?.rect == GridRect(row: 0, col: 0, width: 10, height: 6))
    }

    @Test func fractionalAnchorFloorsToCell() {
        let store = makeStoreWithWindow()
        addFloat(store, anchor: "NW", row: 2.6, col: 3.4)
        #expect(frame(resolve(store), 5)?.rect == GridRect(row: 7, col: 13, width: 10, height: 6))
    }

    @Test func floatAnchoredToAnotherFloatResolvesTransitively() {
        let store = makeStoreWithWindow()
        addFloat(store, grid: 5, anchor: "NW", row: 2, col: 3) // at (7, 13)
        addFloat(store, grid: 6, anchor: "NW", anchorGrid: 5, row: 1, col: 1, width: 4, height: 2)
        #expect(frame(resolve(store), 6)?.rect == GridRect(row: 8, col: 14, width: 4, height: 2))
    }

    @Test func zOrderIsBaseWindowsFloatsMsg() {
        let store = makeStoreWithWindow()
        addFloat(store, grid: 5, anchor: "NW", row: 0, col: 0, z: 50)
        addFloat(store, grid: 6, anchor: "NW", row: 1, col: 1, z: 20)
        _ = store.apply(batch(
            .gridResize(grid: 7, width: 100, height: 3),
            .msgSetPos(grid: 7, row: 27, scrolled: false, sepChar: "─"),
            .flush
        ))
        let frames = resolve(store)
        // Draw order back-to-front: base, window, low-z float, high-z float, msg.
        #expect(frames.map(\.gridID) == [1, 2, 6, 5, 7])
        #expect(frame(frames, 7)?.rect == GridRect(row: 27, col: 0, width: 100, height: 3))
        #expect(frame(frames, 7)?.zIndex == GridLayout.msgZ)
        #expect(frame(frames, 5)?.zIndex == GridLayout.floatZBase + 50)
    }

    @Test func hiddenAndClosedGridsAreExcluded() {
        let store = makeStoreWithWindow()
        addFloat(store, grid: 5, anchor: "NW", row: 0, col: 0)
        store.apply(batch(.winHide(grid: 5)))
        #expect(frame(resolve(store), 5) == nil)

        store.apply(batch(.winClose(grid: 2)))
        let frames = resolve(store)
        #expect(frame(frames, 2) == nil)
        #expect(frame(frames, 1) != nil)
    }

    @Test func winPosAfterHideUnhides() {
        let store = makeStoreWithWindow()
        store.apply(batch(.winHide(grid: 2)))
        #expect(frame(resolve(store), 2) == nil)
        store.apply(batch(.winPos(grid: 2, win: 1000, startRow: 0, startCol: 0, width: 40, height: 20)))
        #expect(frame(resolve(store), 2)?.rect == GridRect(row: 0, col: 0, width: 40, height: 20))
    }
}
