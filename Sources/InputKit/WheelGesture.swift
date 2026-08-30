// WheelGesture — quantize-ahead vertical scroll-row bookkeeping
// (docs/research/scroll-camera.md, "Predict, then reconcile").
//
// A wheel gesture accumulates fractional finger travel (in rows, down
// positive) and requests whole rows from Neovim as soon as the finger enters
// them: `ceil` away from zero rather than truncation toward zero, so nvim's
// viewport runs up to one row *ahead* of the finger. The camera (a
// `ScrollFollower` in SurfaceKit) then renders the fractional finger position
// over rows nvim has already confirmed, one round trip behind — never a row
// it doesn't have.
//
// `WheelGesture` is a pure value type: it knows nothing about AppKit, nvim,
// or the follower. It only turns a stream of `(deltaRows, phase,
// momentumPhase)` samples into whole row steps to request now.

/// Gesture-phase state, mapped from `NSEvent.Phase` by the AppKit-facing
/// caller (`InputHostView`) so this type stays AppKit-free and unit-testable.
public enum WheelPhase: Sendable, Equatable {
    case none
    case began
    case changed
    case ended
    case cancelled
    case mayBegin
    case stationary
}

/// Per-grid, per-axis (vertical) wheel-gesture state. Turns a stream of wheel
/// deltas into whole row steps to request from Neovim right now, quantizing
/// ahead of the finger so the follower always has a confirmed row to render
/// toward.
public struct WheelGesture: Sendable, Equatable {
    /// Cumulative fractional finger travel this gesture, in rows, down
    /// positive. While the gesture is open this can run ahead of whole rows;
    /// on finalize it snaps to `requestedRows` (the camera completes the row
    /// it is in rather than leaving a fractional remainder stranded after the
    /// finger lifts).
    public private(set) var inputRows: Double = 0
    /// Cumulative whole rows requested from Neovim this gesture, down
    /// positive. Always `inputRows` quantized ahead of zero.
    public private(set) var requestedRows: Int = 0
    /// Whether a gesture is currently open. A fresh `.began`, or any input
    /// arriving while closed, opens a new gesture with both counters reset
    /// to zero.
    public private(set) var isOpen: Bool = false

    public init() {}

    /// Feed one wheel sample. Returns the signed number of row steps to send
    /// to Neovim right now (positive = down); `0` means either the sample
    /// stayed within the already-requested row or this call finalized the
    /// gesture.
    ///
    /// - Parameters:
    ///   - deltaRows: signed fractional rows of finger travel since the last
    ///     call, down positive (`-event.scrollingDeltaY / cellHeight` for a
    ///     precise trackpad delta, `-event.scrollingDeltaY` lines otherwise).
    ///   - phase: the wheel event's own phase.
    ///   - momentumPhase: the wheel event's momentum phase (`.none` for a
    ///     non-momentum event).
    public mutating func input(
        deltaRows: Double, phase: WheelPhase, momentumPhase: WheelPhase
    ) -> Int {
        if phase == .began || !isOpen {
            inputRows = 0
            requestedRows = 0
            isOpen = true
        }

        let endedWithoutMomentum = (phase == .ended || phase == .cancelled)
            && momentumPhase == .none
        let momentumEnded = momentumPhase == .ended || momentumPhase == .cancelled
        if endedWithoutMomentum || momentumEnded {
            // The camera completes the row it is in rather than stranding a
            // fractional remainder once the finger (or momentum) stops.
            inputRows = Double(requestedRows)
            isOpen = false
            return 0
        }

        inputRows += deltaRows
        // Quantize ahead of zero: a positive fraction requests the next row
        // down as soon as the finger enters it; a negative fraction requests
        // the next row up. This intentionally means a reversal can request
        // two steps in one call (e.g. +0.3 requested then a swing to -0.2
        // requests -1 overall, i.e. two up-steps from the +1 already sent) —
        // acceptable because it only ever happens on a direction reversal.
        let wanted = inputRows >= 0 ? Int(inputRows.rounded(.up)) : Int(inputRows.rounded(.down))
        let steps = wanted - requestedRows
        requestedRows = wanted
        return steps
    }
}

#if canImport(AppKit)
import AppKit

extension WheelPhase {
    /// Map an `NSEvent.Phase` (used for both `event.phase` and
    /// `event.momentumPhase`) to the AppKit-free case above. `NSEvent.Phase`
    /// is an option set; in practice AppKit sets at most one bit at a time,
    /// but this checks in a stable priority order rather than assuming so.
    public init(_ phase: NSEvent.Phase) {
        if phase.contains(.began) { self = .began }
        else if phase.contains(.changed) { self = .changed }
        else if phase.contains(.ended) { self = .ended }
        else if phase.contains(.cancelled) { self = .cancelled }
        else if phase.contains(.mayBegin) { self = .mayBegin }
        else if phase.contains(.stationary) { self = .stationary }
        else { self = .none }
    }
}
#endif
