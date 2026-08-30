// ScrollAccumulator — trackpad/momentum scroll accumulation in fractional
// cell units (DESIGN.md §7.4).
//
// Precise (trackpad) deltas arrive in points; the accumulator divides them by
// the cell size, accumulates the fraction per axis, and emits one wheel step
// per whole cell crossed, carrying the sub-cell remainder into the next event.
// Momentum-phase events simply keep feeding the same accumulator, so nvim
// scrolls with real inertia. A direction reversal on an axis discards that
// axis's remainder — a leftover 0.9-cell credit from an upward fling must not
// make the first downward nudge feel dead (or worse, fire an extra up-step).
//
// Non-precise (clicky wheel mice) deltas are already in lines: each event
// converts directly into whole steps — at least one per non-zero event so
// slow single-notch scrolling always moves.
//
// Sign conventions match AppKit's `scrollingDelta{X,Y}`:
//   deltaY > 0 → wheel **up**,   deltaY < 0 → wheel **down**
//   deltaX > 0 → wheel **left**, deltaX < 0 → wheel **right**

/// Whole wheel steps produced by one `accumulate` call. At most one of
/// up/down and one of left/right is non-zero.
public struct WheelSteps: Sendable, Hashable {
    public var up: Int
    public var down: Int
    public var left: Int
    public var right: Int

    public init(up: Int = 0, down: Int = 0, left: Int = 0, right: Int = 0) {
        self.up = up
        self.down = down
        self.left = left
        self.right = right
    }

    public var isEmpty: Bool {
        up == 0 && down == 0 && left == 0 && right == 0
    }
}

/// Accumulates scroll deltas per axis and emits whole-cell wheel steps.
public struct ScrollAccumulator: Sendable, Hashable {
    /// A gap at or above this many seconds since the previous event reads as
    /// delivery having stopped and resumed, not a continuous gesture (WezTerm
    /// macOS accumulator). The stale remainder is dropped, and the event that
    /// ends the gap rounds away from zero instead of draining toward zero, so
    /// a slow first nudge after a pause is never swallowed by truncation.
    public static let stalenessGap: Double = 0.250

    /// Pending sub-cell scroll credit, in cells (X axis: positive = left).
    private var pendingX: Double = 0
    /// Pending sub-cell scroll credit, in cells (Y axis: positive = up).
    private var pendingY: Double = 0
    /// Timestamp of the last event fed to `accumulate`, when the caller
    /// supplies one. Nil means staleness is not tracked (existing callers
    /// that omit `timestamp` see no behavior change).
    private var lastEventTimestamp: Double?

    public init() {}

    /// Drop any accumulated remainders (e.g. when the pointer leaves the
    /// grid or a new gesture begins).
    public mutating func reset() {
        pendingX = 0
        pendingY = 0
        lastEventTimestamp = nil
    }

    /// Feed one scroll event; returns the whole steps to emit now.
    ///
    /// - Parameters:
    ///   - deltaX, deltaY: `scrollingDeltaX/Y` — points when `isPrecise`,
    ///     lines otherwise.
    ///   - cellWidth, cellHeight: current cell metrics in points (used only
    ///     for precise deltas).
    ///   - isPrecise: `NSEvent.hasPreciseScrollingDeltas`.
    ///   - timestamp: event time, for the staleness rule above. Omit (the
    ///     default) to leave staleness untracked, as before.
    public mutating func accumulate(
        deltaX: Double,
        deltaY: Double,
        cellWidth: Double,
        cellHeight: Double,
        isPrecise: Bool,
        timestamp: Double? = nil
    ) -> WheelSteps {
        var stale = false
        if let timestamp {
            if let lastEventTimestamp, timestamp - lastEventTimestamp >= Self.stalenessGap {
                pendingX = 0
                pendingY = 0
                stale = true
            }
            self.lastEventTimestamp = timestamp
        }

        var steps = WheelSteps()

        let x: Int
        let y: Int
        if isPrecise {
            x = cellWidth > 0
                ? Self.drain(&pendingX, adding: deltaX / cellWidth, roundAwayFromZero: stale) : 0
            y = cellHeight > 0
                ? Self.drain(&pendingY, adding: deltaY / cellHeight, roundAwayFromZero: stale) : 0
        } else {
            x = Self.wholeSteps(forLineDelta: deltaX)
            y = Self.wholeSteps(forLineDelta: deltaY)
        }

        if y > 0 { steps.up = y } else if y < 0 { steps.down = -y }
        if x > 0 { steps.left = x } else if x < 0 { steps.right = -x }
        return steps
    }

    // MARK: - Internals

    /// Add `delta` (in cells) to the pending remainder — resetting it first
    /// on a direction reversal — and drain whole steps. `roundAwayFromZero`
    /// rounds up (for a positive remainder) or down (negative) instead of
    /// truncating toward zero, so the first nudge after a stale gap always
    /// registers instead of being absorbed as sub-cell credit.
    private static func drain(
        _ pending: inout Double, adding delta: Double, roundAwayFromZero: Bool = false
    ) -> Int {
        guard delta != 0 else { return 0 }
        if pending != 0, (delta > 0) != (pending > 0) {
            pending = 0
        }
        pending += delta
        let whole = roundAwayFromZero
            ? (pending >= 0 ? pending.rounded(.up) : pending.rounded(.down))
            : pending.rounded(.towardZero)
        pending -= whole
        return Int(whole)
    }

    /// Non-precise wheels: every non-zero event is at least one whole step in
    /// its direction; larger line deltas (acceleration) truncate to lines.
    private static func wholeSteps(forLineDelta delta: Double) -> Int {
        guard delta != 0 else { return 0 }
        let magnitude = max(1, Int(abs(delta).rounded(.towardZero)))
        return delta > 0 ? magnitude : -magnitude
    }
}
