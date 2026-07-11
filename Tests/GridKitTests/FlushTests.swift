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

    @Test func viewportScrollDeltaIsDeliveredOncePerFlush() {
        let store = makeStore(rows: 6, cols: 6)
        #expect(store.apply(batch(
            .winViewport(
                grid: 1, win: 10, topline: 1, botline: 7,
                curline: 2, curcol: 0, lineCount: 100, scrollDelta: 1)
        )) == nil)
        let first = store.apply(batch(
            .winViewport(
                grid: 1, win: 10, topline: 3, botline: 9,
                curline: 4, curcol: 0, lineCount: 100, scrollDelta: 2),
            .flush
        ))!
        #expect(first.viewportScrollDeltas == [1: 3])
        #expect(store.grids[1]?.viewport?.scrollDelta == 2)

        let unrelated = store.apply(batch(.setTitle("later"), .flush))!
        #expect(unrelated.viewportScrollDeltas.isEmpty)
    }

    @Test func viewportScrollDeltasAreIndependentAndCancellationIsOmitted() {
        let store = makeStore(rows: 6, cols: 6)
        _ = store.apply(batch(.gridResize(grid: 2, width: 6, height: 6), .flush))

        let result = store.apply(batch(
            .winViewport(
                grid: 1, win: 10, topline: 2, botline: 8,
                curline: 3, curcol: 0, lineCount: 100, scrollDelta: 2),
            .winViewport(
                grid: 1, win: 10, topline: 0, botline: 6,
                curline: 1, curcol: 0, lineCount: 100, scrollDelta: -2),
            .winViewport(
                grid: 2, win: 20, topline: 4, botline: 10,
                curline: 5, curcol: 0, lineCount: 100, scrollDelta: 4),
            .flush
        ))!

        #expect(result.viewportScrollDeltas == [2: 4])
        #expect(result.viewportScrollMotions[1]?.netDelta == 0)
        #expect(result.viewportScrollMotions[1]?.containsReversal == true)
        #expect(result.viewportScrollMotions[1]?.stepCount == 2)
        #expect(result.viewportScrollMotions[1]?.largestStepDelta == -2)
    }

    @Test func deferredScrollFlushesCoalesceUntilConsumed() {
        let store = makeStore(rows: 6, cols: 6)

        let first = store.applyDeferred(batch(
            .gridScroll(
                grid: 1, top: 0, bottom: 6, left: 0, right: 6,
                rows: 1, cols: 0),
            line(1, 5, 0, runs("first ")),
            .winViewport(
                grid: 1, win: 10, topline: 1, botline: 7,
                curline: 2, curcol: 0, lineCount: 100, scrollDelta: 1),
            .flush
        ))
        let second = store.applyDeferred(batch(
            .gridScroll(
                grid: 1, top: 0, bottom: 6, left: 0, right: 6,
                rows: 2, cols: 0),
            line(1, 4, 0, runs("next  ")),
            line(1, 5, 0, runs("last  ")),
            .winViewport(
                grid: 1, win: 10, topline: 3, botline: 9,
                curline: 4, curcol: 0, lineCount: 100, scrollDelta: 2),
            .flush
        ))

        #expect(first == .displayLinked)
        #expect(second == .displayLinked)
        let presented = store.consumePendingPresentation()
        #expect(presented?.viewportScrollDeltas == [1: 3])
        #expect(presented?.allowsScrollInterpolation == true)
        #expect(presented?.viewportScrollMotions[1]?.netDelta == 3)
        #expect(presented?.viewportScrollMotions[1]?.largestStepMagnitude == 2)
        #expect(presented?.viewportScrollMotions[1]?.largestStepDelta == 2)
        #expect(presented?.viewportScrollMotions[1]?.stepCount == 2)
        #expect(presented?.viewportScrollMotions[1]?.containsReversal == false)
        #expect(presented?.damagedGrids.first?.damage.scrolls.count == 2)
        #expect(store.consumePendingPresentation() == nil)
    }

    @Test func deferredMotionKeepsSmallStepAndReversalProvenance() {
        let store = makeStore(rows: 6, cols: 6)

        for top in 1...8 {
            #expect(store.applyDeferred(batch(
                .gridScroll(
                    grid: 1, top: 0, bottom: 6, left: 0, right: 6,
                    rows: 1, cols: 0),
                .winViewport(
                    grid: 1, win: 10, topline: top, botline: top + 6,
                    curline: top + 1, curcol: 0, lineCount: 100,
                    scrollDelta: 1),
                .flush
            )) == .displayLinked)
        }
        #expect(store.applyDeferred(batch(
            .gridScroll(
                grid: 1, top: 0, bottom: 6, left: 0, right: 6,
                rows: -1, cols: 0),
            .winViewport(
                grid: 1, win: 10, topline: 7, botline: 13,
                curline: 8, curcol: 0, lineCount: 100, scrollDelta: -1),
            .flush
        )) == .displayLinked)

        let motion = store.consumePendingPresentation()?.viewportScrollMotions[1]
        #expect(motion?.netDelta == 7)
        #expect(motion?.largestStepMagnitude == 1)
        #expect(motion?.lastDelta == -1)
        #expect(motion?.stepCount == 9)
        #expect(motion?.containsReversal == true)
    }

    @Test func deferredMotionRetainsZeroNetReversal() {
        let store = makeStore(rows: 6, cols: 6)
        for delta in [1, -1] {
            #expect(store.applyDeferred(batch(
                .gridScroll(
                    grid: 1, top: 0, bottom: 6, left: 0, right: 6,
                    rows: delta, cols: 0),
                .winViewport(
                    grid: 1, win: 10, topline: delta > 0 ? 1 : 0,
                    botline: delta > 0 ? 7 : 6, curline: 1, curcol: 0,
                    lineCount: 100, scrollDelta: delta),
                .flush
            )) == .displayLinked)
        }

        let result = store.consumePendingPresentation()
        #expect(result?.viewportScrollDeltas.isEmpty == true)
        #expect(result?.viewportScrollMotions[1]?.netDelta == 0)
        #expect(result?.viewportScrollMotions[1]?.containsReversal == true)
        #expect(result?.viewportScrollMotions[1]?.lastDelta == -1)
    }

    @Test func deferredPresentationClassifiesUnsafeFramesImmediate() {
        let store = makeStore(rows: 6, cols: 6)

        let horizontal = store.applyDeferred(batch(
            .gridScroll(
                grid: 1, top: 0, bottom: 6, left: 0, right: 6,
                rows: 0, cols: 1),
            .flush
        ))
        #expect(horizontal == .immediate)
        #expect(store.consumePendingPresentation()?.allowsScrollInterpolation == false)

        let resize = store.applyDeferred(batch(
            .gridResize(grid: 1, width: 7, height: 7),
            .flush
        ))
        #expect(resize == .immediate)
        let resized = store.consumePendingPresentation()
        #expect(resized?.grids[1]?.rows == 7)
        #expect(resized?.allowsScrollInterpolation == false)
    }

    @Test func directApplyCarriesTheSameInterpolationSafety() {
        let store = makeStore(rows: 6, cols: 6)
        let compatible = store.apply(batch(
            .gridScroll(
                grid: 1, top: 0, bottom: 6, left: 0, right: 6,
                rows: 1, cols: 0),
            .winViewport(
                grid: 1, win: 10, topline: 1, botline: 7,
                curline: 2, curcol: 0, lineCount: 100, scrollDelta: 1),
            .flush
        ))
        #expect(compatible?.allowsScrollInterpolation == true)

        let mixedEdit = store.apply(batch(
            line(1, 2, 0, runs("typed!")), .flush
        ))
        #expect(mixedEdit?.allowsScrollInterpolation == false)
    }

    @Test func deferredScrollRequiresTheExactInnerViewportRegion() {
        let store = makeStore(rows: 8, cols: 6)
        _ = store.apply(batch(
            .winViewportMargins(
                grid: 1, win: 10, top: 1, bottom: 1, left: 1, right: 1),
            .flush
        ))

        #expect(store.applyDeferred(batch(
            .gridScroll(
                grid: 1, top: 1, bottom: 7, left: 1, right: 5,
                rows: 1, cols: 0),
            .winViewport(
                grid: 1, win: 10, topline: 1, botline: 7,
                curline: 2, curcol: 0, lineCount: 100, scrollDelta: 1),
            .flush
        )) == .displayLinked)
        #expect(store.consumePendingPresentation() != nil)

        #expect(store.applyDeferred(batch(
            .gridScroll(
                grid: 1, top: 0, bottom: 7, left: 0, right: 6,
                rows: 1, cols: 0),
            .flush
        )) == .immediate)
        #expect(store.consumePendingPresentation() != nil)
    }

    @Test func deferredScrollRequiresMatchingSemanticDirectionAndTouchedGrids() {
        let store = makeStore(rows: 6, cols: 6)
        _ = store.apply(batch(.gridResize(grid: 2, width: 6, height: 6), .flush))

        #expect(store.applyDeferred(batch(
            .gridScroll(
                grid: 1, top: 0, bottom: 6, left: 0, right: 6,
                rows: 1, cols: 0),
            .winViewport(
                grid: 1, win: 10, topline: 1, botline: 7,
                curline: 2, curcol: 0, lineCount: 100, scrollDelta: -1),
            .flush
        )) == .immediate)
        #expect(store.consumePendingPresentation() != nil)

        #expect(store.applyDeferred(batch(
            .gridScroll(
                grid: 1, top: 0, bottom: 6, left: 0, right: 6,
                rows: 1, cols: 0),
            line(2, 0, 0, runs("other!")),
            .winViewport(
                grid: 1, win: 10, topline: 2, botline: 8,
                curline: 3, curcol: 0, lineCount: 100, scrollDelta: 1),
            .flush
        )) == .immediate)
        #expect(store.consumePendingPresentation() != nil)

        #expect(store.applyDeferred(batch(
            .gridScroll(
                grid: 1, top: 0, bottom: 6, left: 0, right: 6,
                rows: 1, cols: 0),
            line(1, 2, 0, runs("typed!")),
            .winViewport(
                grid: 1, win: 10, topline: 3, botline: 9,
                curline: 4, curcol: 0, lineCount: 100, scrollDelta: 1),
            .flush
        )) == .immediate)
        #expect(store.consumePendingPresentation() != nil)
    }

    @Test func deferredScrollSupportsIndependentMovingSplits() {
        let store = makeStore(rows: 6, cols: 6)
        _ = store.apply(batch(.gridResize(grid: 2, width: 6, height: 6), .flush))

        #expect(store.applyDeferred(batch(
            .gridScroll(
                grid: 1, top: 0, bottom: 6, left: 0, right: 6,
                rows: 1, cols: 0),
            line(1, 5, 0, runs("one   ")),
            .winViewport(
                grid: 1, win: 10, topline: 1, botline: 7,
                curline: 2, curcol: 0, lineCount: 100, scrollDelta: 1),
            .gridScroll(
                grid: 2, top: 0, bottom: 6, left: 0, right: 6,
                rows: -2, cols: 0),
            line(2, 0, 0, runs("two   ")),
            line(2, 1, 0, runs("split ")),
            .winViewport(
                grid: 2, win: 20, topline: 8, botline: 14,
                curline: 10, curcol: 0, lineCount: 100, scrollDelta: -2),
            .flush
        )) == .displayLinked)

        let result = store.consumePendingPresentation()
        #expect(result?.viewportScrollDeltas == [1: 1, 2: -2])
        #expect(result?.damagedGrids.map(\.grid.id) == [1, 2])
    }

    @Test func semanticFarJumpCanAnimateWithoutPixelScrollDamage() {
        let store = makeStore(rows: 6, cols: 6)
        #expect(store.applyDeferred(batch(
            line(1, 0, 0, runs("final ")),
            .winViewport(
                grid: 1, win: 10, topline: 40, botline: 46,
                curline: 42, curcol: 0, lineCount: 100, scrollDelta: 40),
            .flush
        )) == .displayLinked)

        let result = store.consumePendingPresentation()
        #expect(result?.viewportScrollDeltas == [1: 40])
        #expect(result?.viewportScrollMotions[1]?.largestStepDelta == 40)
        #expect(result?.damagedGrids.first?.damage.scrolls.isEmpty == true)
    }

    @Test func immediateDeferredFrameDrainsEarlierScrollDamage() {
        let store = makeStore(rows: 6, cols: 6)
        #expect(store.applyDeferred(batch(
            .gridScroll(
                grid: 1, top: 0, bottom: 6, left: 0, right: 6,
                rows: 1, cols: 0),
            .winViewport(
                grid: 1, win: 10, topline: 1, botline: 7,
                curline: 2, curcol: 0, lineCount: 100, scrollDelta: 1),
            .flush
        )) == .displayLinked)

        #expect(store.applyDeferred(batch(
            line(1, 0, 0, runs("typed!")),
            .flush
        )) == .immediate)

        let presented = store.consumePendingPresentation()
        #expect(presented?.viewportScrollDeltas == [1: 1])
        #expect(presented?.allowsScrollInterpolation == false)
        #expect(presented?.damagedGrids.first?.damage.scrolls.count == 1)
        #expect(presented?.damagedGrids.first?.grid.rowText(0) == "typed!")
    }

    @Test func deferredConsumerNeverExposesAPartialWireFrame() {
        let store = makeStore(rows: 6, cols: 6)
        #expect(store.applyDeferred(batch(
            .gridScroll(
                grid: 1, top: 0, bottom: 6, left: 0, right: 6,
                rows: 1, cols: 0),
            .winViewport(
                grid: 1, win: 10, topline: 1, botline: 7,
                curline: 2, curcol: 0, lineCount: 100, scrollDelta: 1),
            .flush
        )) == .displayLinked)

        // The next Neovim frame has begun but has not reached its atomic
        // flush boundary. The older pending presentation is deliberately
        // superseded rather than exposing this partial state.
        #expect(store.applyDeferred(batch(
            line(1, 5, 0, runs("part  "))
        )) == .none)
        #expect(store.consumePendingPresentation() == nil)

        #expect(store.applyDeferred(batch(.flush)) == .immediate)
        let complete = store.consumePendingPresentation()
        #expect(complete?.damagedGrids.first?.grid.rowText(5) == "part  ")
        #expect(complete?.viewportScrollDeltas == [1: 1])
    }
}
