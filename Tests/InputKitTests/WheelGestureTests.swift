// WheelGesture tests — quantize-ahead vertical scroll-row bookkeeping
// (docs/research/scroll-camera.md, "Predict, then reconcile").
//
// Sign convention: `deltaRows` is down-positive.

import Testing
@testable import InputKit

@Suite("WheelGesture")
struct WheelGestureTests {

    @Test("a fractional finger nudge requests the row it just entered")
    func fractionalNudgeRequestsOneRowAhead() {
        var gesture = WheelGesture()
        // 0.3 rows down: quantize ahead (ceil) → the next row down is
        // requested immediately, even though the finger hasn't finished it.
        #expect(gesture.input(deltaRows: 0.3, phase: .changed, momentumPhase: .none) == 1)
        #expect(gesture.inputRows == 0.3)
        #expect(gesture.requestedRows == 1)

        // Still inside the already-requested row: no new step.
        #expect(gesture.input(deltaRows: 0.4, phase: .changed, momentumPhase: .none) == 0)
        #expect(gesture.requestedRows == 1)

        // 1.1 total rows: the second row down is now entered.
        #expect(gesture.input(deltaRows: 0.4, phase: .changed, momentumPhase: .none) == 1)
        #expect(gesture.requestedRows == 2)
    }

    @Test("a reversal can request steps in both directions within one gesture")
    func reversalRequestsOppositeSteps() {
        var gesture = WheelGesture()
        #expect(gesture.input(deltaRows: 0.3, phase: .began, momentumPhase: .none) == 1)
        #expect(gesture.requestedRows == 1)

        // Swing from +0.3 total to -0.2 total: wanted = floor(-0.2) = -1, so
        // two up-steps come back at once relative to the +1 already sent.
        let steps = gesture.input(deltaRows: -0.5, phase: .changed, momentumPhase: .none)
        #expect(steps == -2)
        #expect(gesture.requestedRows == -1)
        #expect(abs(gesture.inputRows - (-0.2)) < 0.000_001)
    }

    @Test("ending without momentum finalizes: inputRows snaps to requestedRows")
    func endWithoutMomentumFinalizes() {
        var gesture = WheelGesture()
        _ = gesture.input(deltaRows: 0.6, phase: .began, momentumPhase: .none)
        #expect(gesture.requestedRows == 1)

        let steps = gesture.input(deltaRows: 0, phase: .ended, momentumPhase: .none)
        #expect(steps == 0)
        #expect(!gesture.isOpen)
        #expect(gesture.inputRows == Double(gesture.requestedRows))
        #expect(gesture.inputRows == 1)
    }

    @Test("ended with momentum stays open until momentum itself ends")
    func endedWithMomentumStaysOpenUntilMomentumEnds() {
        var gesture = WheelGesture()
        _ = gesture.input(deltaRows: 0.5, phase: .began, momentumPhase: .none)
        // The finger lifted, but momentum is about to carry the gesture on:
        // still open, no snap yet.
        let midSteps = gesture.input(deltaRows: 0, phase: .ended, momentumPhase: .began)
        #expect(midSteps == 0)
        #expect(gesture.isOpen)

        // Momentum keeps feeding deltas like any other sample: 0.5 + 0.6 =
        // 1.1 total rows, so a second row down is now entered.
        #expect(gesture.input(deltaRows: 0.6, phase: .none, momentumPhase: .changed) == 1)
        #expect(gesture.requestedRows == 2)

        // Momentum itself ends: finalize. The camera is only 1.1 rows into
        // a 2-row request — 0.9 row short, more than half a row — so
        // nearest-row finalize steps back one row toward where the camera
        // actually is rather than gliding the full 0.9-row remainder.
        let finalSteps = gesture.input(deltaRows: 0, phase: .none, momentumPhase: .ended)
        #expect(finalSteps == -1)
        #expect(!gesture.isOpen)
        #expect(gesture.requestedRows == 1)
        #expect(gesture.inputRows == Double(gesture.requestedRows))
    }

    @Test("a new .began after finalize reopens the gesture with reset counters")
    func newBeganReopensAfterFinalize() {
        var gesture = WheelGesture()
        _ = gesture.input(deltaRows: 2.4, phase: .began, momentumPhase: .none)
        _ = gesture.input(deltaRows: 0, phase: .ended, momentumPhase: .none)
        #expect(!gesture.isOpen)

        #expect(gesture.input(deltaRows: 0.2, phase: .began, momentumPhase: .none) == 1)
        #expect(gesture.isOpen)
        #expect(gesture.inputRows == 0.2)
        #expect(gesture.requestedRows == 1)
    }

    @Test("any input while closed reopens the gesture, not just .began")
    func anyInputWhileClosedReopens() {
        var gesture = WheelGesture()
        _ = gesture.input(deltaRows: 1.0, phase: .began, momentumPhase: .none)
        _ = gesture.input(deltaRows: 0, phase: .ended, momentumPhase: .none)

        // A later accessory-wheel style `.changed` sample with no `.began`
        // still starts a fresh gesture rather than accumulating onto the
        // finalized one.
        #expect(gesture.input(deltaRows: 0.5, phase: .changed, momentumPhase: .none) == 1)
        #expect(gesture.inputRows == 0.5)
        #expect(gesture.requestedRows == 1)
    }

    @Test("upward travel quantizes ahead in the negative direction")
    func upwardTravelQuantizesAhead() {
        var gesture = WheelGesture()
        #expect(gesture.input(deltaRows: -0.1, phase: .began, momentumPhase: .none) == -1)
        #expect(gesture.requestedRows == -1)
        // -0.1 + -0.85 = -0.95 total: still inside the already-requested row.
        #expect(gesture.input(deltaRows: -0.85, phase: .changed, momentumPhase: .none) == 0)
        #expect(gesture.requestedRows == -1)
        // -0.95 + -0.2 = -1.15 total: the second row up is now entered.
        #expect(gesture.input(deltaRows: -0.2, phase: .changed, momentumPhase: .none) == -1)
        #expect(gesture.requestedRows == -2)
    }

    @Test("whole-line ticks pass through unchanged, one step per line")
    func lineTicksPassThroughUnchanged() {
        var gesture = WheelGesture()
        #expect(gesture.input(deltaRows: 1, phase: .began, momentumPhase: .none) == 1)
        #expect(gesture.input(deltaRows: 1, phase: .changed, momentumPhase: .none) == 1)
        #expect(gesture.input(deltaRows: 2, phase: .changed, momentumPhase: .none) == 2)
        #expect(gesture.requestedRows == 4)
        #expect(gesture.inputRows == 4)
    }

    @Test("cancelled without momentum finalizes just like ended")
    func cancelledFinalizes() {
        var gesture = WheelGesture()
        // 0.4 rows into the row quantized ahead (requestedRows == 1): nearer
        // to 0 than to 1, so nearest-row finalize steps back rather than
        // gliding forward the remaining 0.6 row.
        _ = gesture.input(deltaRows: 0.4, phase: .began, momentumPhase: .none)
        let steps = gesture.input(deltaRows: 0, phase: .cancelled, momentumPhase: .none)
        #expect(steps == -1)
        #expect(!gesture.isOpen)
        #expect(gesture.requestedRows == 0)
        #expect(gesture.inputRows == 0)
    }

    // MARK: - Nearest-row finalize (docs/research/scroll-camera.md §B)

    @Test("finalize just past the midpoint steps back one row toward the finger")
    func finalizeJustPastMidpointStepsBack() {
        var gesture = WheelGesture()
        _ = gesture.input(deltaRows: 1.05, phase: .began, momentumPhase: .none)
        #expect(gesture.requestedRows == 2)

        let steps = gesture.input(deltaRows: 0, phase: .ended, momentumPhase: .none)
        #expect(steps == -1)
        #expect(gesture.requestedRows == 1)
        #expect(gesture.inputRows == 1)
    }

    @Test("finalize just before the far edge completes forward")
    func finalizeJustBeforeFarEdgeCompletesForward() {
        var gesture = WheelGesture()
        _ = gesture.input(deltaRows: 1.6, phase: .began, momentumPhase: .none)
        #expect(gesture.requestedRows == 2)

        let steps = gesture.input(deltaRows: 0, phase: .ended, momentumPhase: .none)
        #expect(steps == 0)
        #expect(gesture.requestedRows == 2)
        #expect(gesture.inputRows == 2)
    }

    @Test("upward finalize steps back symmetrically")
    func upwardFinalizeStepsBackSymmetrically() {
        var gesture = WheelGesture()
        _ = gesture.input(deltaRows: -1.05, phase: .began, momentumPhase: .none)
        #expect(gesture.requestedRows == -2)

        let steps = gesture.input(deltaRows: 0, phase: .ended, momentumPhase: .none)
        #expect(steps == 1)
        #expect(gesture.requestedRows == -1)
        #expect(gesture.inputRows == -1)
    }

    @Test("momentum ending applies the same nearest-row finalize as a lifted finger")
    func momentumEndedAppliesNearestRowFinalize() {
        var gesture = WheelGesture()
        _ = gesture.input(deltaRows: 1.05, phase: .began, momentumPhase: .none)
        _ = gesture.input(deltaRows: 0, phase: .ended, momentumPhase: .began)
        #expect(gesture.isOpen)

        let steps = gesture.input(deltaRows: 0, phase: .none, momentumPhase: .ended)
        #expect(steps == -1)
        #expect(!gesture.isOpen)
        #expect(gesture.requestedRows == 1)
        #expect(gesture.inputRows == 1)
    }

    @Test("finalize exactly at the midpoint completes forward")
    func finalizeExactlyAtMidpointCompletesForward() {
        var gesture = WheelGesture()
        _ = gesture.input(deltaRows: 0.5, phase: .began, momentumPhase: .none)
        #expect(gesture.requestedRows == 1)

        let steps = gesture.input(deltaRows: 0, phase: .ended, momentumPhase: .none)
        #expect(steps == 0)
        #expect(gesture.requestedRows == 1)
        #expect(gesture.inputRows == 1)
    }
}
