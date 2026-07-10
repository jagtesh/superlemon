// ScrollAccumulator tests — DESIGN.md §7.4's momentum accumulator.
//
// Sign conventions (AppKit scrollingDelta): +Y → wheel up, -Y → wheel down,
// +X → wheel left, -X → wheel right.

import Testing
@testable import InputKit

/// 10x20pt cells keep the arithmetic readable: 20pt of Y is one row,
/// 10pt of X is one column.
private let cellW = 10.0
private let cellH = 20.0

extension ScrollAccumulator {
    /// Test shorthand: precise trackpad delta with the standard cell metrics.
    fileprivate mutating func precise(x: Double = 0, y: Double = 0) -> WheelSteps {
        accumulate(deltaX: x, deltaY: y, cellWidth: cellW, cellHeight: cellH, isPrecise: true)
    }

    /// Test shorthand: non-precise (clicky wheel) delta in lines.
    fileprivate mutating func lines(x: Double = 0, y: Double = 0) -> WheelSteps {
        accumulate(deltaX: x, deltaY: y, cellWidth: cellW, cellHeight: cellH, isPrecise: false)
    }
}

@Suite("ScrollAccumulator")
struct ScrollAccumulatorTests {

    // MARK: Precise (trackpad) accumulation

    @Test("sub-cell deltas emit nothing until a whole cell is crossed")
    func subCellAccumulation() {
        var acc = ScrollAccumulator()
        #expect(acc.precise(y: 8).isEmpty)   // 0.4 cells pending
        #expect(acc.precise(y: 8).isEmpty)   // 0.8 cells pending
        #expect(acc.precise(y: 8) == WheelSteps(up: 1))  // 1.2 → 1 step, 0.2 kept
        // The 0.2-cell remainder carries: 16pt more crosses the next cell.
        #expect(acc.precise(y: 16) == WheelSteps(up: 1))
    }

    @Test("a large fling emits multiple steps at once")
    func multiStepEvent() {
        var acc = ScrollAccumulator()
        #expect(acc.precise(y: 65) == WheelSteps(up: 3))  // 3.25 cells
        #expect(acc.precise(y: 15) == WheelSteps(up: 1))  // 0.25 + 0.75
    }

    @Test("momentum-style decaying deltas keep feeding the same remainder")
    func momentumDecay() {
        var acc = ScrollAccumulator()
        // A fling: big finger delta, then decaying momentum-phase deltas.
        // Total = 30+20+10+5+2+1 = 68pt = 3.4 cells → exactly 3 steps overall.
        var total = 0
        for delta in [30.0, 20, 10, 5, 2, 1] {
            total += acc.precise(y: delta).up
        }
        #expect(total == 3)
    }

    @Test("downward scrolling is symmetric")
    func downwardScrolling() {
        var acc = ScrollAccumulator()
        #expect(acc.precise(y: -30).down == 1)  // -1.5 cells → 1 down, -0.5 kept
        #expect(acc.precise(y: -10).down == 1)  // -0.5 + -0.5 → 1 down
    }

    @Test("horizontal axis accumulates independently, in columns")
    func horizontalAxis() {
        var acc = ScrollAccumulator()
        let steps = acc.precise(x: 25, y: 30)  // 2.5 cols, 1.5 rows
        #expect(steps == WheelSteps(up: 1, left: 2))
        #expect(acc.precise(x: -35).right == 3)  // reversal: remainder dropped
    }

    @Test("sign flip resets the pending remainder on that axis")
    func signFlipResetsRemainder() {
        var acc = ScrollAccumulator()
        #expect(acc.precise(y: 18).isEmpty)  // +0.9 cells pending
        // Reversal: the +0.9 credit must not swallow (or amplify) this nudge.
        #expect(acc.precise(y: -6).isEmpty)  // pending is now -0.3, not +0.6
        #expect(acc.precise(y: -16) == WheelSteps(down: 1))  // -0.3 + -0.8 = -1.1
    }

    @Test("a sign flip on one axis leaves the other axis's remainder alone")
    func signFlipIsPerAxis() {
        var acc = ScrollAccumulator()
        #expect(acc.precise(x: 8, y: 18).isEmpty)  // +0.8 col, +0.9 row pending
        // Y reverses, X keeps going: X remainder must survive.
        let steps = acc.precise(x: 4, y: -6)
        #expect(steps == WheelSteps(left: 1))  // 0.8 + 0.4 = 1.2 cols
    }

    @Test("reset drops all pending remainders")
    func resetDropsRemainders() {
        var acc = ScrollAccumulator()
        #expect(acc.precise(x: 9, y: 19).isEmpty)
        acc.reset()
        #expect(acc.precise(x: 2, y: 2).isEmpty)  // nothing carried over
    }

    // MARK: Non-precise (clicky wheel) passthrough

    @Test("non-precise deltas are whole steps, not cell-scaled")
    func nonPreciseWholeSteps() {
        var acc = ScrollAccumulator()
        #expect(acc.lines(y: 3) == WheelSteps(up: 3))
        #expect(acc.lines(y: -1) == WheelSteps(down: 1))
        #expect(acc.lines(x: 2) == WheelSteps(left: 2))
        #expect(acc.lines(x: -2) == WheelSteps(right: 2))
    }

    @Test("a slow single notch (fractional line delta) still scrolls one step")
    func nonPreciseMinimumOneStep() {
        var acc = ScrollAccumulator()
        #expect(acc.lines(y: 0.1) == WheelSteps(up: 1))
        #expect(acc.lines(y: -0.1) == WheelSteps(down: 1))
    }

    @Test("non-precise events do not disturb the precise remainder")
    func nonPreciseDoesNotTouchRemainder() {
        var acc = ScrollAccumulator()
        #expect(acc.precise(y: 18).isEmpty)          // +0.9 cells pending
        #expect(acc.lines(y: 1) == WheelSteps(up: 1)) // wheel notch passthrough
        #expect(acc.precise(y: 4) == WheelSteps(up: 1)) // 0.9 + 0.2 crosses
    }

    @Test("zero deltas emit nothing and change nothing")
    func zeroDeltas() {
        var acc = ScrollAccumulator()
        #expect(acc.precise().isEmpty)
        #expect(acc.lines().isEmpty)
        #expect(acc.precise(y: 18).isEmpty)
        #expect(acc.precise().isEmpty)               // zero must not reset
        #expect(acc.precise(y: 4) == WheelSteps(up: 1))
    }

    @Test("degenerate cell metrics never divide by zero")
    func degenerateCellMetrics() {
        var acc = ScrollAccumulator()
        let steps = acc.accumulate(
            deltaX: 10, deltaY: 10, cellWidth: 0, cellHeight: 0, isPrecise: true
        )
        #expect(steps.isEmpty)
    }
}
