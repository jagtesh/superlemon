import AppKit
import GridKit
import QuartzCore

/// The visual policy for reconciling Neovim's cell-at-a-time scroll frames.
public enum ScrollMotionStyle: Sendable, Equatable {
    /// Present every authoritative Neovim frame without interpolation.
    case immediate
    /// Reconcile discrete viewport rows with a display-linked motion envelope.
    case tightNative
}

/// Analytical critically damped spring used for the cursor's short correction.
struct CriticalDampedSpring: Equatable {
    var position: CGFloat = 0
    var velocity: CGFloat = 0
    var animationLength: CFTimeInterval = 0.300

    var angularFrequency: CGFloat {
        CGFloat(4 / max(0.001, animationLength))
    }

    mutating func advance(by elapsed: CFTimeInterval) {
        guard elapsed > 0 else { return }
        let omega = angularFrequency
        let time = CGFloat(elapsed)
        let a = position
        let b = position * omega + velocity
        let decay = exp(-omega * time)
        position = (a + b * time) * decay
        velocity = decay * (-a * omega - b * time * omega + b)
    }

    mutating func settle() {
        position = 0
        velocity = 0
    }

    var isSettled: Bool {
        abs(position) < 0.01 && abs(velocity) < 0.10
    }
}

/// A single `(position, velocity)` critically damped follower that is
/// retargeted on every scroll arrival, replacing the previous design's sum
/// of one fixed-duration minimum-jerk residual per arrival
/// (`ContinuousScrollEnvelope`/`MinimumJerkScrollSegment`) plus a separate
/// backlog spring (`catchUp`). Every shipping smooth-scroll implementation
/// surveyed (Chromium, Firefox APZ, Neovide) keeps one follower and
/// retargets it; summing per-arrival bells produced isolated 0→peak→0
/// pulses once arrivals were spaced wider than half a bell, and up to 2×
/// overshoot when they were closer together.
///
/// State is in ROWS. `position` is the visual offset of the retained
/// filmstrip relative to the authoritative viewport, using the same sign
/// convention as the previous `motion.position`: an arrival of
/// `animatedDelta` rows adds `-animatedDelta`. `target` is zero whenever no
/// wheel gesture is predicting ahead of nvim's confirmation (all of this
/// file's direct-`present` tests, and the resting state between gestures);
/// `SmoothViewportState` retargets it to the clamped predicted offset while
/// a gesture is open and running ahead — see `clampedTarget()`.
struct ScrollFollower: Equatable {
    /// Soft-start stiffness (s⁻²): the first movement-carrying arrival, or
    /// any arrival far enough from the previous one to read as a fresh
    /// gesture rather than a continuation. Firefox `ComputeSpringConstant`
    /// (`ScrollAnimationPhysics.cpp`).
    static let softStartStiffness: Double = 1250
    /// "Coming to a stop" stiffness: an arrival slower than, and slowing
    /// down relative to, the previous one settles the spring faster so the
    /// camera does not linger behind a stream that is winding down.
    static let stoppingStiffness: Double = 2000
    /// Steady-cadence stiffness for dense, evenly spaced arrivals.
    static let steadyStiffness: Double = 1000
    /// A gap at or above this many seconds reads as a fresh gesture rather
    /// than a continuation of the previous one.
    static let gestureRestartGap: CFTimeInterval = 0.120
    /// The "coming to a stop" rule only applies once the gap itself clears
    /// this floor, so sub-frame jitter between two dense arrivals does not
    /// read as slowing down.
    static let stoppingGapFloor: CFTimeInterval = 0.012
    /// An arrival gap at least this many times the previous gap reads as
    /// slowing down.
    static let stoppingGapRatio: Double = 1.3
    /// Gentle stiffness for the glide after a gesture has finalized
    /// (`noteScrollInput(gestureOpen: false)`): the remaining fractional-row
    /// correction — at most half a row, `WheelGesture`'s nearest-row
    /// finalize — should settle calmly rather than at whatever
    /// cadence-selected stiffness happened to be active when the finger
    /// lifted. ω ≈ 22, about 180 ms to rest.
    static let settleStiffness: Double = 500

    /// Fixed physics substep (Fiedler, "Fix Your Timestep!"; Firefox
    /// `AxisPhysicsModel`). `advance(by:)` integrates whole substeps and
    /// extrapolates any fractional remainder exactly (see `readout`), so the
    /// result is independent of the caller's frame rate.
    static let substep: CFTimeInterval = 1.0 / 120.0
    /// A single `advance(by:)` call integrates at most this many seconds, so
    /// a display link resuming after a long stall does not replay an
    /// unbounded number of substeps.
    static let maximumAdvance: CFTimeInterval = 0.25

    /// Settle threshold, in rows and rows/second (Neovide).
    static let settleEpsilon: CGFloat = 0.01
    /// Below this observed arrival gap, delivery is local-pipe cadence and
    /// the natural `√stiffness` frequency applies unstretched.
    static let cadenceStretchThreshold: CFTimeInterval = 0.090
    /// The settle horizon stretches to span about this many observed arrival
    /// gaps, so the next burst on a high-latency transport always lands
    /// mid-glide with nonzero velocity instead of after the camera has
    /// already come to rest.
    static let cadenceStretchFactor: Double = 2.0
    /// Ceiling on the stretched settle time (`4 / ω`); a very sparse remote
    /// cadence must not stretch the glide indefinitely.
    static let maximumSettleDuration: CFTimeInterval = 0.480

    struct State: Equatable {
        var position: CGFloat = 0
        var velocity: CGFloat = 0
    }

    private var current = State()
    private var accumulator: CFTimeInterval = 0

    /// The follower's current aim point, in rows. Zero is "camera exactly on
    /// the authoritative viewport" (today's behaviour whenever no wheel
    /// gesture is in flight). While a gesture is open and running ahead of
    /// nvim's confirmation, `SmoothViewportState` retargets this to the
    /// clamped predicted offset so the glide continues toward the finger
    /// instead of the origin; see `SmoothViewportState.clampedTarget()`.
    var target: CGFloat = 0
    private(set) var stiffness: Double = ScrollFollower.softStartStiffness
    /// Peak-hold-with-decay estimate of the gap between scroll-frame
    /// arrivals, fed by the host's cadence tracking. Used only to cap `ω` so
    /// the settle horizon spans high-latency bursts; see `angularFrequency`.
    var estimatedArrivalGap: CFTimeInterval = 0
    private(set) var isActive = false
    /// Set by `lockSettleStiffness()` when a gesture finalizes; cleared by
    /// `unlockStiffness()` (a new gesture opened) or `settle()` (the glide
    /// finished). While locked, `updateStiffness` leaves `stiffness` alone —
    /// otherwise the arrival that confirms a finalize's possible
    /// nearest-row step-back would immediately override the gentle settle
    /// stiffness with whatever the cadence rule selects for that arrival.
    private var stiffnessLocked = false

    /// `ω = √stiffness`, capped so the settle time (`4/ω`) spans roughly two
    /// observed arrival gaps on a high-latency transport, and floored so
    /// that stretch never exceeds `maximumSettleDuration`.
    var angularFrequency: CGFloat {
        let natural = CGFloat(stiffness.squareRoot())
        guard estimatedArrivalGap > Self.cadenceStretchThreshold else { return natural }
        let stretched = CGFloat(4 / (Self.cadenceStretchFactor * estimatedArrivalGap))
        let floor = CGFloat(4 / Self.maximumSettleDuration)
        return max(floor, min(natural, stretched))
    }

    /// The follower's exact state at "now": whole `substep`s already folded
    /// into `current` by `advance(by:)`, plus one more closed-form step for
    /// the leftover fractional remainder in `accumulator`. Unlike a generic
    /// fixed-step integrator, the closed form is stable and exact at any
    /// `dt` (Holden), so this remainder step is an exact analytic
    /// extrapolation, not a linear approximation toward a stale
    /// once-per-substep sample — which matters here because `substep`
    /// (1/120 s) is also the typical display-callback period: a caller that
    /// always advances by exactly one substep would otherwise see `current`
    /// change on every call but the *interpolated* readout stay perpetually
    /// one substep stale, so a retarget's motion would not become visible
    /// until the *second* subsequent callback.
    private var readout: State {
        accumulator > 0 ? step(current, dt: accumulator) : current
    }

    var position: CGFloat { isActive ? readout.position : target }
    var velocity: CGFloat { isActive ? readout.velocity : 0 }
    /// Diagnostics only, evaluated at the extrapolated readout — not itself
    /// integrated.
    var acceleration: CGFloat {
        guard isActive else { return 0 }
        let omega = angularFrequency
        return -omega * omega * (position - target) - 2 * omega * velocity
    }

    /// Select the stiffness for the glide this arrival starts. `gap` is the
    /// elapsed time since the previous movement-carrying arrival (`nil` for
    /// the very first one); `previousGap` is the gap before that. Firefox
    /// `ComputeSpringConstant`.
    mutating func updateStiffness(gap: CFTimeInterval?, previousGap: CFTimeInterval?) {
        guard !stiffnessLocked else { return }
        guard let gap else {
            stiffness = Self.softStartStiffness
            return
        }
        if gap >= Self.gestureRestartGap {
            stiffness = Self.softStartStiffness
        } else if gap >= Self.stoppingGapFloor, let previousGap,
            gap >= Self.stoppingGapRatio * previousGap
        {
            stiffness = Self.stoppingStiffness
        } else {
            stiffness = Self.steadyStiffness
        }
    }

    /// A gesture just finalized (`noteScrollInput(gestureOpen: false)`): the
    /// remaining glide settles at the gentle `settleStiffness` and
    /// `updateStiffness` ignores the cadence rule until a new gesture opens
    /// or the follower comes to rest.
    mutating func lockSettleStiffness() {
        stiffness = Self.settleStiffness
        stiffnessLocked = true
    }

    /// A new gesture opened: cadence-selected stiffness resumes.
    mutating func unlockStiffness() {
        stiffnessLocked = false
    }

    /// Move the follower's state by `delta` rows without resetting velocity
    /// — the retarget that keeps the camera continuous across a filmstrip
    /// rotation. Clamped to `±bound` (the retained-history filmstrip
    /// bound — Neovide's clamp), then the resulting velocity is clamped so
    /// an arrival cannot leave the spring carrying more energy than its own
    /// remaining error could produce (Firefox bug 1846935).
    mutating func retarget(byRows delta: CGFloat, bound: CGFloat) {
        guard delta != 0 else { return }
        let clampBound = max(0, bound)
        current.position = clampPosition(current.position + delta, bound: clampBound)
        current.velocity = clampVelocity(current.velocity, position: current.position)
        isActive = true
    }

    private func clampPosition(_ position: CGFloat, bound: CGFloat) -> CGFloat {
        min(bound, max(-bound, position))
    }

    private func clampVelocity(_ velocity: CGFloat, position: CGFloat) -> CGFloat {
        let limit = angularFrequency * abs(position - target)
        guard abs(velocity) > limit else { return velocity }
        return velocity < 0 ? -limit : limit
    }

    /// Closed-form critically damped step, stable at any `dt` (Holden
    /// `simple_spring_damper_exact`; Juckett; Neovide).
    private func step(_ state: State, dt: CFTimeInterval) -> State {
        let omega = angularFrequency
        let time = CGFloat(dt)
        let j0 = state.position - target
        let j1 = state.velocity + j0 * omega
        let decay = exp(-omega * time)
        return State(
            position: decay * (j0 + j1 * time) + target,
            velocity: decay * (state.velocity - j1 * omega * time))
    }

    /// Integrate whole `substep`s into `current` — independent of the
    /// caller's frame rate (Fiedler, "Fix Your Timestep!"; Firefox
    /// `AxisPhysicsModel`) — leaving any fractional remainder in
    /// `accumulator` for `readout` to extrapolate exactly.
    mutating func advance(by elapsed: CFTimeInterval) {
        guard isActive else { return }
        accumulator += min(max(0, elapsed), Self.maximumAdvance)
        while accumulator >= Self.substep {
            current = step(current, dt: Self.substep)
            accumulator -= Self.substep
        }
        if isSettled(readout) { settle() }
    }

    private func isSettled(_ state: State) -> Bool {
        guard abs(state.position - target) < Self.settleEpsilon else { return false }
        let omega = angularFrequency
        let projectedVelocityError = abs(state.velocity) * (4 / max(omega, .leastNormalMagnitude))
        return projectedVelocityError < Self.settleEpsilon
    }

    mutating func settle() {
        current = State(position: target, velocity: 0)
        accumulator = 0
        isActive = false
        stiffnessLocked = false
    }
}

/// A modulo-addressed history whose logical index zero moves without copying
/// its elements. Negative logical rows are the lines above the final viewport.
struct CircularRowHistory<Element> {
    private(set) var storage: [Element?]
    private(set) var head = 0

    init(capacity: Int) {
        storage = [Element?](repeating: nil, count: max(0, capacity))
    }

    var capacity: Int { storage.count }

    mutating func reset(capacity: Int) {
        storage = [Element?](repeating: nil, count: max(0, capacity))
        head = 0
    }

    mutating func rotate(by rows: Int) {
        guard capacity > 0 else { return }
        head = modulo(head + rows, capacity)
    }

    subscript(logicalRow: Int) -> Element? {
        get {
            guard capacity > 0 else { return nil }
            return storage[modulo(head + logicalRow, capacity)]
        }
        set {
            guard capacity > 0 else { return }
            storage[modulo(head + logicalRow, capacity)] = newValue
        }
    }

    private func modulo(_ value: Int, _ divisor: Int) -> Int {
        let remainder = value % divisor
        return remainder >= 0 ? remainder : remainder + divisor
    }
}

struct SmoothViewportGeometry: Equatable {
    let rows: Int
    let cols: Int
    let top: Int
    let bottom: Int
    let left: Int
    let right: Int

    init(rows: Int, cols: Int, margins: ViewportMargins?) {
        self.rows = max(0, rows)
        self.cols = max(0, cols)
        let requestedTop = max(0, margins?.top ?? 0)
        let requestedBottom = max(0, margins?.bottom ?? 0)
        let requestedLeft = max(0, margins?.left ?? 0)
        let requestedRight = max(0, margins?.right ?? 0)
        top = min(self.rows, requestedTop)
        bottom = min(self.rows - top, requestedBottom)
        left = min(self.cols, requestedLeft)
        right = min(self.cols - left, requestedRight)
    }

    var innerRows: Int { rows - top - bottom }
    var innerCols: Int { cols - left - right }

    func clipRect(cellSize: CGSize) -> CGRect {
        CGRect(
            x: CGFloat(left) * cellSize.width,
            y: CGFloat(top) * cellSize.height,
            width: CGFloat(innerCols) * cellSize.width,
            height: CGFloat(innerRows) * cellSize.height)
    }

    func accepts(
        _ scrolls: [ScrollDelta], semanticDelta: Int,
        semanticMotion: ViewportScrollMotion? = nil
    ) -> Bool {
        let hasMovement = semanticMotion?.hasMovement ?? (semanticDelta != 0)
        guard hasMovement, innerRows > 0, innerCols > 0 else { return false }
        guard !scrolls.isEmpty else { return true }
        guard !scrolls.contains(where: { delta in
            delta.cols != 0 || delta.rows == 0
                || delta.top != top || delta.bottom != rows - bottom
                || delta.left != left || delta.right != cols - right
                || (semanticMotion == nil
                    && delta.rows.signum() != semanticDelta.signum())
        }) else { return false }
        return true
    }
}

/// One immutable raster row (or a testing-only slice of a full image).
/// Production scroll history retains row-sized images only.
struct SharedImageRow: @unchecked Sendable {
    let image: CGImage
    let layerContents: RowLayerContents
    /// Holds the renderer's IOSurface use-count lease while this revision is
    /// addressable through authoritative rows, history, or a layer slot.
    let layerContentsRetention: AnyObject?
    let contentsRect: CGRect
    let sourceRow: Int
    let generation: UInt64
    let token: RowImageToken
    let retainsFullGridImage: Bool
}

package struct ScrollDiagnosticSample: Sendable, Equatable {
    package let timestamp: CFTimeInterval
    package let gridID: Int
    package let delta: Int
    package let historyHead: Int
    package let position: CGFloat
    package let velocity: CGFloat
    package let acceleration: CGFloat
    package let snappedTranslationPixels: Int
    package let cursorAuthoritativeY: CGFloat?
    package let cursorVisualY: CGFloat?
    /// The follower's current settle-time estimate (`4 / ω`), for parity
    /// with the previous latency-adaptive residual duration.
    package let envelopeDuration: CFTimeInterval
    /// The follower's current spring stiffness (s⁻²).
    package let stiffness: Double
}

private struct RowLayerBinding: Equatable {
    let token: RowImageToken
    let contentsRect: CGRect
}

private struct FilmstripSlot {
    let layer: CALayer
    var logicalRow: Int?
    var binding: RowLayerBinding?
}

/// Persistent per-grid row compositor. Exact authoritative row tiles are
/// always installed; scrolling only rebinds a row when an integer boundary is
/// crossed and translates one clipped container between those boundaries.
@MainActor
final class SmoothViewportState {
    /// A gap longer than this is a pause between gestures, not delivery
    /// cadence; it neither feeds nor resets the peak-hold estimate below
    /// (transport latency is a session property, not a gesture property).
    /// A gap this long already reads as a fresh gesture to
    /// `ScrollFollower.updateStiffness`, so it needs no separate handling
    /// there.
    static let cadenceGestureWindow: CFTimeInterval = 0.600
    /// Per-arrival decay of the peak-hold cadence estimate. About fifteen
    /// dense local arrivals — a fraction of a second of wheel motion — fully
    /// unlearn a stretched remote cadence after a transport hiccup.
    static let cadenceDecay: Double = 0.9

    let gridID: Int

    private(set) var geometry = SmoothViewportGeometry(rows: 0, cols: 0, margins: nil)
    private(set) var history = CircularRowHistory<SharedImageRow>(capacity: 0)
    /// The single camera follower. Replaces the previous fixed-duration
    /// residual envelope plus a separate backlog spring: one
    /// `(position, velocity)` pair retargeted on every arrival, including
    /// far-jump cuts and sustained backlog, stays continuous and reaches a
    /// smooth equilibrium below the retained-history bound without a
    /// separate regime switch.
    private(set) var follower = ScrollFollower()
    private(set) var isActive = false
    private(set) var lastSemanticDelta = 0
    /// Cumulative animated arrival rows for the currently open wheel
    /// gesture, same sign convention as `gestureInputRows` (down positive).
    /// Rebased to zero when a gesture opens (`noteScrollInput`); incremented
    /// by `animatedDelta` on every non-far arrival (`rotateForNewViewport`);
    /// reset by an isolated far-jump cut, which did not come from the wheel.
    private(set) var confirmedRows = 0
    /// The open wheel gesture's own bookkeeping, mirrored from
    /// `InputKit.WheelGesture` by `noteScrollInput`. `gestureIsOpen` is
    /// tracked separately from the incoming `gestureOpen` flag so a
    /// transition into "open" (not just "is open") can be detected, which is
    /// what triggers the `confirmedRows` rebase.
    private var gestureInputRows: Double = 0
    private var gestureRequestedRows = 0
    private var gestureIsOpen = false
    /// Peak-hold-with-decay estimate of the gap between scroll-frame
    /// arrivals. Zero until two movement-carrying frames arrive within one
    /// gesture window of each other. Feeds `follower.estimatedArrivalGap`,
    /// which only caps the settle horizon (see `ScrollFollower.
    /// angularFrequency`) — it does not select the stiffness.
    private(set) var estimatedArrivalGap: CFTimeInterval = 0
    private var lastScrollArrival: CFTimeInterval?
    /// The raw gap before the most recent one, feeding
    /// `ScrollFollower.updateStiffness`'s "coming to a stop" rule. Unlike
    /// `estimatedArrivalGap` this is never filtered by
    /// `cadenceGestureWindow` — a long pause already reads as a fresh
    /// gesture through the stiffness rule's own gap threshold.
    private var previousArrivalGap: CFTimeInterval?

    private weak var hostLayer: CALayer?
    private let baseLayer = CALayer()
    private let clipLayer = CALayer()
    private let rowContainerLayer = CALayer()
    private var baseRowLayers: [CALayer] = []
    private var baseBindings: [RowLayerBinding?] = []
    private var rowSlots: [FilmstripSlot] = []
    private var authoritativeRows: [SharedImageRow] = []
    private var cellSize: CGSize = .zero
    private var scale: CGFloat = 1
    private var presentationGeneration: UInt64 = 0
    private var lastBoundFirstRow: Int?
    private var lastTranslationY: CGFloat = .nan
    private var rowsNeedBinding = true
    private var hasAuthoritativeRows = false

    init(gridID: Int) {
        self.gridID = gridID
        for layer in [baseLayer, clipLayer, rowContainerLayer] {
            disableActions(on: layer)
        }
        baseLayer.zPosition = 0
        clipLayer.zPosition = 1
        clipLayer.masksToBounds = true
        rowContainerLayer.zPosition = 0
        clipLayer.addSublayer(rowContainerLayer)
    }

    var position: CGFloat { follower.position }
    var velocity: CGFloat { follower.velocity }
    var acceleration: CGFloat { follower.acceleration }
    var snappedTranslationY: CGFloat {
        lastTranslationY.isFinite
            ? lastTranslationY
            : pixelSnap(position * cellSize.height, scale: scale)
    }
    var snappedTranslationPixels: Int {
        Int((snappedTranslationY * scale).rounded())
    }
    var historyHead: Int { history.head }
    /// Kept for source compatibility with the previous transient overlay.
    /// It is now the permanent clipped exact-row viewport.
    var overlayLayer: CALayer { clipLayer }
    var visibleRowLayers: [CALayer] {
        rowSlots.sorted {
            ($0.logicalRow ?? Int.max) < ($1.logicalRow ?? Int.max)
        }.map(\.layer)
    }
    var translatedContainerLayer: CALayer { rowContainerLayer }

    /// Production entry point: install cached row-sized renderer revisions.
    /// `arrivalTimestamp` feeds the arrival-cadence estimate; nil (the
    /// default, used by deterministic tests) leaves the estimate untouched.
    /// - Parameter forceAtomic: `nil` (the default, used by every existing
    ///   direct-`present` test) preserves prior behavior by falling back to
    ///   `!animate` — an explicitly atomic/Reduce-Motion/non-`tightNative`
    ///   frame, or a per-flush classifier-atomic frame (`animate == false`
    ///   because the flush merely wasn't safe to interpolate — e.g. it
    ///   carried no motion at all), both hard-settled exactly as before.
    ///   Production (`GridSurfaceView`) passes an explicit value decoupled
    ///   from `animate`: `redrawAll || style != .tightNative ||
    ///   reducedMotion` — the reasons that actually invalidate the
    ///   filmstrip's coordinate system or the session's motion policy — so a
    ///   damage-only atomic frame (an edit, a cursor-line/matchparen repaint,
    ///   no scroll, same geometry) rebinds rows without cutting off a glide
    ///   still in flight. See `docs/research/scroll-camera.md` §C/§D.
    @discardableResult
    func present(
        rowSnapshots: [RenderedRowSnapshot], rows: Int, cols: Int,
        margins: ViewportMargins?, scrolls: [ScrollDelta], semanticDelta: Int?,
        semanticMotion: ViewportScrollMotion? = nil,
        cellSize: CGSize, scale: CGFloat, host: CALayer, animate: Bool,
        forceAtomic: Bool? = nil,
        arrivalTimestamp: CFTimeInterval? = nil
    ) -> Bool {
        let sourceRows = rowSnapshots.enumerated().map { row, snapshot in
            SharedImageRow(
                image: snapshot.image,
                layerContents: snapshot.layerContents,
                layerContentsRetention: snapshot.layerContentsRetention,
                contentsRect: CGRect(x: 0, y: 0, width: 1, height: 1),
                sourceRow: row, generation: snapshot.revision,
                token: snapshot.token, retainsFullGridImage: false)
        }
        return present(
            authoritativeRows: sourceRows, rows: rows, cols: cols,
            margins: margins, scrolls: scrolls, semanticDelta: semanticDelta,
            semanticMotion: semanticMotion,
            cellSize: cellSize, scale: scale, host: host, animate: animate,
            forceAtomic: forceAtomic, arrivalTimestamp: arrivalTimestamp)
    }

    /// Testing/snapshot compatibility. The application never takes this
    /// full-grid path; outgoing slices are detached before entering history.
    @discardableResult
    func present(
        image: CGImage, rows: Int, cols: Int, margins: ViewportMargins?,
        scrolls: [ScrollDelta], semanticDelta: Int?,
        semanticMotion: ViewportScrollMotion? = nil, cellSize: CGSize,
        scale: CGFloat, host: CALayer, animate: Bool,
        forceAtomic: Bool? = nil,
        arrivalTimestamp: CFTimeInterval? = nil
    ) -> Bool {
        presentationGeneration &+= 1
        let rowHeight = 1 / CGFloat(max(1, rows))
        let sourceRows = (0..<max(0, rows)).map { row in
            SharedImageRow(
                image: image,
                layerContents: .image(image),
                layerContentsRetention: nil,
                contentsRect: CGRect(
                    x: 0, y: 1 - CGFloat(row + 1) * rowHeight,
                    width: 1, height: rowHeight),
                sourceRow: row, generation: presentationGeneration,
                token: RowImageToken(
                    backingID: UInt64.max &- presentationGeneration,
                    revision: UInt64(row)),
                retainsFullGridImage: true)
        }
        return present(
            authoritativeRows: sourceRows, rows: rows, cols: cols,
            margins: margins, scrolls: scrolls, semanticDelta: semanticDelta,
            semanticMotion: semanticMotion,
            cellSize: cellSize, scale: scale, host: host, animate: animate,
            forceAtomic: forceAtomic, arrivalTimestamp: arrivalTimestamp)
    }

    @discardableResult
    private func present(
        authoritativeRows nextRows: [SharedImageRow], rows: Int, cols: Int,
        margins: ViewportMargins?, scrolls: [ScrollDelta], semanticDelta: Int?,
        semanticMotion: ViewportScrollMotion?,
        cellSize: CGSize, scale: CGFloat, host: CALayer, animate: Bool,
        forceAtomic: Bool?,
        arrivalTimestamp: CFTimeInterval?
    ) -> Bool {
        let nextGeometry = SmoothViewportGeometry(rows: rows, cols: cols, margins: margins)
        let nextScale = max(1, scale)
        let needsReset = hostLayer !== host || geometry != nextGeometry
            || self.cellSize != cellSize || self.scale != nextScale

        if needsReset {
            attach(to: host)
            geometry = nextGeometry
            self.cellSize = cellSize
            self.scale = nextScale
            rebuildLayers()
            follower.settle()
            isActive = false
            authoritativeRows = nextRows
            bindAuthoritativeRows()
            seedCurrentRows()
            render(forceBindings: true)
            return false
        }

        let delta = semanticDelta ?? 0
        var eligible = animate && geometry.accepts(
            scrolls, semanticDelta: delta, semanticMotion: semanticMotion)
        let carriesMovement = !scrolls.isEmpty
            || semanticMotion?.hasMovement == true
            || (semanticDelta != nil && delta != 0)
        if animate, carriesMovement, let arrivalTimestamp {
            updateArrivalCadence(arrivalTimestamp)
        }
        // `resolvedForceAtomic` is the set of reasons that actually
        // invalidate the filmstrip's coordinate system or the session's
        // motion policy: an explicit full redraw, Reduce Motion, the
        // `.immediate` style, or (absent an explicit caller value) any
        // `animate == false` frame, matching the previous behavior exactly
        // for every direct-`present` call site that does not pass
        // `forceAtomic`. It is deliberately *not* `!animate` on its own in
        // production: `GridSurfaceView` passes the narrower explicit value
        // so a damage-only atomic frame (an edit, a cursor-line/matchparen
        // repaint — `animate == false` only because the flush classifier
        // found nothing safe to interpolate, not because anything
        // invalidated the coordinate system) rebinds rows without cutting
        // off a glide still in flight.
        let resolvedForceAtomic = forceAtomic ?? !animate
        if resolvedForceAtomic, isActive {
            // A genuinely atomic frame supersedes any visual tail even when
            // it contains only edits or highlight changes.
            settle()
        } else if !eligible, carriesMovement {
            // This frame carries movement the follower cannot represent
            // (incompatible geometry/direction) — settle regardless of why
            // `animate` was false.
            settle()
        }

        // Wrapped lines ('wrap') and virtual lines make one document line
        // span several screen rows, so win_viewport's line-based delta
        // understates how many rows the grid actually rotated — animating a
        // five-row wrapped step as one row is the field-reported wrap judder.
        // The wire grid_scroll rows are the screen-space truth; the semantic
        // delta remains provenance and the fallback for scrolls that redraw
        // without rotation damage (far jumps).
        let wireRows = scrolls.reduce(0) { $0 + $1.rows }
        let displacement = wireRows != 0 ? wireRows : delta
        if eligible, hasAuthoritativeRows {
            if displacement != 0 {
                let largestStep: Int
                let farDirection: Int
                if wireRows != 0 {
                    largestStep = Int(min(UInt(Int.max), wireRows.magnitude))
                    farDirection = wireRows.signum()
                } else {
                    largestStep = semanticMotion?.largestStepMagnitude
                        ?? Int(min(UInt(Int.max), delta.magnitude))
                    farDirection = semanticMotion?.largestStepDelta.signum()
                        ?? delta.signum()
                }
                eligible = rotateForNewViewport(
                    displacement, trueFar: largestStep > geometry.innerRows,
                    farDirection: farDirection)
                if !eligible { settle() }
            } else {
                // Coalesced reversal can return to the same viewport. It is
                // still compatible motion. Existing signed pulses continue;
                // zero-net input adds no artificial camera movement.
                eligible = semanticMotion?.hasMovement == true && isActive
            }
        }

        authoritativeRows = nextRows
        bindAuthoritativeRows()
        seedCurrentRows()

        if eligible, hasAuthoritativeRows {
            lastSemanticDelta = displacement != 0
                ? displacement
                : (semanticMotion?.lastDelta ?? delta)
            isActive = follower.isActive
        }
        render(forceBindings: false)
        return eligible && hasAuthoritativeRows && isActive
    }

    /// Advance the follower to the latest display target. Delayed callbacks
    /// render only that exact resulting filmstrip position.
    @discardableResult
    func advance(
        by elapsed: CFTimeInterval,
        nominalDisplayPeriod: CFTimeInterval = 1.0 / 60.0,
        detectDisplayGap: Bool = true
    ) -> Bool {
        guard isActive else { return false }
        let bounded = min(max(0, elapsed), 1.0)
        _ = nominalDisplayPeriod
        _ = detectDisplayGap

        follower.advance(by: bounded)
        if !follower.isActive {
            isActive = false
            lastSemanticDelta = 0
            discardNonCurrentHistory()
        }
        render(forceBindings: false)

        return isActive
    }

    func settle() {
        // A hard settle (an atomic/Reduce-Motion frame, a layout change, or
        // teardown) abandons any in-flight prediction along with the visual
        // tail: reset the target before `follower.settle()` snaps `position`
        // to it, so a nonzero predicted target left over from an open
        // gesture cannot strand the camera off the authoritative viewport.
        // If the gesture is still physically open, the very next
        // `noteScrollInput` call re-syncs from the real `WheelGesture`
        // state and rebases `confirmedRows` to the (now-authoritative)
        // present picture.
        gestureInputRows = 0
        gestureRequestedRows = 0
        gestureIsOpen = false
        confirmedRows = 0
        follower.target = 0
        follower.settle()
        isActive = false
        lastSemanticDelta = 0
        discardNonCurrentHistory()
        render(forceBindings: false)
    }

    func destroy() {
        settle()
        baseLayer.removeFromSuperlayer()
        clipLayer.removeFromSuperlayer()
        hostLayer = nil
        history.reset(capacity: 0)
        baseRowLayers.removeAll()
        rowSlots.removeAll()
        authoritativeRows.removeAll()
        hasAuthoritativeRows = false
    }

    /// Legacy no-snap assertion used by the full-image compatibility tests.
    func currentRowsReference(_ image: CGImage) -> Bool {
        guard geometry.innerRows > 0 else { return true }
        return (0..<geometry.innerRows).allSatisfy { history[$0]?.image === image }
    }

    /// Production no-snap assertion: every final logical row matches the
    /// renderer's current immutable row revision.
    func currentRowsMatch(_ snapshots: [RenderedRowSnapshot]) -> Bool {
        guard snapshots.count == geometry.rows else { return false }
        return (0..<geometry.innerRows).allSatisfy { logicalRow in
            let sourceRow = geometry.top + logicalRow
            return history[logicalRow]?.token == snapshots[sourceRow].token
        }
    }

    func diagnosticSample(
        timestamp: CFTimeInterval, cursorAuthoritativeY: CGFloat?, cursorVisualY: CGFloat?
    ) -> ScrollDiagnosticSample {
        ScrollDiagnosticSample(
            timestamp: timestamp, gridID: gridID, delta: lastSemanticDelta,
            historyHead: history.head, position: follower.position,
            velocity: follower.velocity, acceleration: follower.acceleration,
            snappedTranslationPixels: snappedTranslationPixels,
            cursorAuthoritativeY: cursorAuthoritativeY,
            cursorVisualY: cursorVisualY,
            envelopeDuration: 4 / Double(follower.angularFrequency),
            stiffness: follower.stiffness)
    }

    /// The host reports the latest state of the open (or just-closed) wheel
    /// gesture for this grid, mirroring `InputKit.WheelGesture`'s own
    /// counters after every wheel sample. Moves the follower's `target`
    /// ahead of the origin to the clamped predicted offset so the camera
    /// runs ahead of nvim's confirmation instead of waiting for it —
    /// "quantize ahead, render behind" (docs/research/scroll-camera.md).
    ///
    /// - Parameters:
    ///   - inputRows: cumulative fractional finger travel this gesture, rows
    ///     down positive (`WheelGesture.inputRows`).
    ///   - requestedRows: cumulative whole rows requested from nvim this
    ///     gesture (`WheelGesture.requestedRows`).
    ///   - gestureOpen: `WheelGesture.isOpen`. `false` means the gesture just
    ///     finalized (finger lifted, or momentum ended): the target snaps to
    ///     zero and the follower glides the remaining fraction — the only
    ///     "snap", and it is a glide, not a jump.
    func noteScrollInput(inputRows: Double, requestedRows: Int, gestureOpen: Bool) {
        if gestureOpen, !gestureIsOpen {
            // A fresh gesture starts predicting from here: forget whatever
            // arrival history accumulated (or never rebased) up to now, and
            // let cadence-selected stiffness govern again.
            confirmedRows = 0
            follower.unlockStiffness()
        } else if !gestureOpen, gestureIsOpen {
            // The gesture just finalized: the remaining glide (at most half
            // a row — `WheelGesture`'s nearest-row finalize) settles gently
            // rather than at whatever stiffness the last arrival's cadence
            // selected.
            follower.lockSettleStiffness()
        }
        gestureIsOpen = gestureOpen
        gestureInputRows = inputRows
        gestureRequestedRows = requestedRows
        follower.target = gestureOpen ? clampedTarget() : 0
    }

    /// The predicted camera offset while a wheel gesture is open, clamped so
    /// the camera never exposes a row nvim has not confirmed:
    /// `raw = gestureInputRows - confirmedRows` is the finger's travel past
    /// what has been confirmed so far. Clamped toward the gesture's own
    /// direction (down: `target <= 0`; up: `target >= 0`) and to
    /// `±innerRows`, the retained-filmstrip bound. Zero whenever nothing is
    /// requested, or the finger's travel has been fully confirmed (today's
    /// behaviour).
    private func clampedTarget() -> CGFloat {
        let raw = CGFloat(gestureInputRows) - CGFloat(confirmedRows)
        let bound = CGFloat(geometry.innerRows)
        switch gestureRequestedRows.signum() {
        case 1: return max(-bound, min(0, raw))
        case -1: return min(bound, max(0, raw))
        default: return 0
        }
    }

    /// Fold one movement-carrying arrival into both the peak-hold cadence
    /// estimate (which only caps the follower's settle horizon on
    /// high-latency transports) and the raw last-two-gap history that
    /// selects the follower's stiffness for the glide this arrival starts
    /// (Firefox `ComputeSpringConstant`). The peak-hold keeps the estimate
    /// at the burst spacing rather than the intra-burst spacing (a burst
    /// delivers several frames a few ms apart and then nothing for a round
    /// trip), while the per-arrival decay lets a dense local stream unlearn
    /// a stretched cadence quickly.
    private func updateArrivalCadence(_ timestamp: CFTimeInterval) {
        defer { lastScrollArrival = timestamp }
        guard let lastScrollArrival else {
            follower.updateStiffness(gap: nil, previousGap: nil)
            return
        }
        let gap = timestamp - lastScrollArrival
        guard gap > 0 else { return }
        follower.updateStiffness(gap: gap, previousGap: previousArrivalGap)
        previousArrivalGap = gap
        guard gap <= Self.cadenceGestureWindow else { return }
        estimatedArrivalGap = max(gap, estimatedArrivalGap * Self.cadenceDecay)
        follower.estimatedArrivalGap = estimatedArrivalGap
    }

    // MARK: - History

    @discardableResult
    private func rotateForNewViewport(
        _ delta: Int, trueFar: Bool, farDirection: Int
    ) -> Bool {
        let height = geometry.innerRows
        guard height > 0, delta != 0 else { return false }

        let direction = trueFar ? farDirection : delta.signum()
        guard direction != 0 else { return false }

        if trueFar, !follower.isActive {
            // An isolated far jump stays a cut: teleport with a one-row cue.
            // This did not come from the wheel (a mid-gesture jump this far
            // takes the sustained-backlog path below, since the follower is
            // already active), so any open gesture's prediction is stale:
            // reset it rather than let a resumed gesture predict against a
            // confirmedRows baseline from before the cut.
            gestureInputRows = 0
            gestureRequestedRows = 0
            gestureIsOpen = false
            confirmedRows = 0
            discardNonCurrentHistory()
            guard copyDisplacedRows(for: direction) else { return false }
            history.rotate(by: direction)
            shiftFilmstripSlots(by: -direction)
            // Reset the target to zero before settling so a stale nonzero
            // prediction target (left over from before the cut) does not
            // leave the settle at a nonzero position.
            follower.target = 0
            follower.settle()
            follower.retarget(byRows: -CGFloat(direction), bound: CGFloat(height))
            return true
        }

        let retainedMagnitude = Int(min(UInt(height), delta.magnitude))
        let animatedDelta = direction * retainedMagnitude
        if trueFar { discardNonCurrentHistory() }

        guard copyDisplacedRows(for: animatedDelta) else { return false }
        history.rotate(by: animatedDelta)
        shiftFilmstripSlots(by: -animatedDelta)

        // This arrival confirms `animatedDelta` more rows of the open
        // gesture's prediction (a no-op when no gesture is open, since
        // `clampedTarget()` is zero whenever `gestureRequestedRows == 0`).
        // Recompute the target from the updated `confirmedRows` *before*
        // retargeting: the retarget moves `position` by `-animatedDelta` and
        // the target moves by the same amount at the same time, so the
        // visual picture stays continuous even though both jump.
        confirmedRows += animatedDelta
        follower.target = clampedTarget()

        // The follower's own ±height retarget clamp replaces the previous
        // two-regime split (a fixed-duration envelope while capacity
        // remained, migrating into a separate backlog spring beyond it):
        // one continuous follower already reaches a smooth equilibrium at
        // the retained-history bound under sustained far input.
        let requestedOffset = -CGFloat(animatedDelta)
        follower.retarget(byRows: requestedOffset, bound: CGFloat(height))
        return true
    }

    private func copyDisplacedRows(for delta: Int) -> Bool {
        let height = geometry.innerRows
        guard height > 0, delta != 0 else { return false }
        let displaced: Range<Int>
        if delta > 0 {
            displaced = 0..<min(delta, height)
        } else {
            displaced = max(0, height + delta)..<height
        }
        for logicalRow in displaced {
            guard let slice = history[logicalRow] else { return false }
            if slice.retainsFullGridImage {
                guard let detached = detachedRow(from: slice) else { return false }
                history[logicalRow] = detached
            }
        }
        return true
    }

    private func detachedRow(from slice: SharedImageRow) -> SharedImageRow? {
        guard slice.retainsFullGridImage else { return slice }
        let imageWidth = CGFloat(slice.image.width)
        let imageHeight = CGFloat(slice.image.height)
        let x0 = max(0, min(slice.image.width,
            Int((slice.contentsRect.minX * imageWidth).rounded())))
        let x1 = max(x0, min(slice.image.width,
            Int((slice.contentsRect.maxX * imageWidth).rounded())))
        let y0 = max(0, min(slice.image.height,
            Int(((1 - slice.contentsRect.maxY) * imageHeight).rounded())))
        let y1 = max(y0, min(slice.image.height,
            Int(((1 - slice.contentsRect.minY) * imageHeight).rounded())))
        guard x1 > x0, y1 > y0,
            let cropped = slice.image.cropping(to: CGRect(
                x: x0, y: y0, width: x1 - x0, height: y1 - y0)),
            let context = GridRenderer.makeContext(
                width: cropped.width, height: cropped.height, scale: 1)
        else { return nil }

        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.draw(cropped, in: CGRect(
            x: 0, y: 0, width: cropped.width, height: cropped.height))
        guard let image = context.makeImage() else { return nil }
        return SharedImageRow(
            image: image, layerContents: .image(image),
            layerContentsRetention: nil,
            contentsRect: CGRect(x: 0, y: 0, width: 1, height: 1),
            sourceRow: slice.sourceRow, generation: slice.generation,
            token: slice.token, retainsFullGridImage: false)
    }

    private func discardNonCurrentHistory() {
        guard geometry.innerRows > 0 else { return }
        for logicalRow in geometry.innerRows..<(geometry.innerRows * 2) {
            history[logicalRow] = nil
        }
    }

    private func seedCurrentRows() {
        guard geometry.innerRows > 0, geometry.innerCols > 0,
            authoritativeRows.count == geometry.rows
        else {
            hasAuthoritativeRows = false
            return
        }
        for logicalRow in 0..<geometry.innerRows {
            let sourceRow = geometry.top + logicalRow
            history[logicalRow] = horizontalSlice(authoritativeRows[sourceRow])
        }
        hasAuthoritativeRows = true
        rowsNeedBinding = true
    }

    private func horizontalSlice(_ row: SharedImageRow) -> SharedImageRow {
        guard geometry.cols > 0 else { return row }
        let leftRatio = CGFloat(geometry.left) / CGFloat(geometry.cols)
        let widthRatio = CGFloat(geometry.innerCols) / CGFloat(geometry.cols)
        var rect = row.contentsRect
        rect.origin.x += rect.width * leftRatio
        rect.size.width *= widthRatio
        return SharedImageRow(
            image: row.image, layerContents: row.layerContents,
            layerContentsRetention: row.layerContentsRetention,
            contentsRect: rect, sourceRow: row.sourceRow,
            generation: row.generation, token: row.token,
            retainsFullGridImage: row.retainsFullGridImage)
    }

    // MARK: - Layers

    private func attach(to host: CALayer) {
        if hostLayer !== host {
            baseLayer.removeFromSuperlayer()
            clipLayer.removeFromSuperlayer()
            host.addSublayer(baseLayer)
            host.addSublayer(clipLayer)
            hostLayer = host
        } else {
            if baseLayer.superlayer == nil { host.addSublayer(baseLayer) }
            if clipLayer.superlayer == nil { host.addSublayer(clipLayer) }
        }
    }

    private func rebuildLayers() {
        baseRowLayers.forEach { $0.removeFromSuperlayer() }
        rowSlots.forEach { $0.layer.removeFromSuperlayer() }
        baseRowLayers.removeAll()
        rowSlots.removeAll()
        baseBindings.removeAll()
        history.reset(capacity: geometry.innerRows * 2)
        hasAuthoritativeRows = false
        lastBoundFirstRow = nil
        lastTranslationY = .nan
        rowsNeedBinding = true

        let fullWidth = CGFloat(geometry.cols) * cellSize.width
        let fullHeight = CGFloat(geometry.rows) * cellSize.height
        baseLayer.frame = CGRect(x: 0, y: 0, width: fullWidth, height: fullHeight)
        clipLayer.frame = geometry.clipRect(cellSize: cellSize)
        clipLayer.isHidden = geometry.innerRows == 0 || geometry.innerCols == 0
        rowContainerLayer.anchorPoint = .zero
        rowContainerLayer.position = .zero
        rowContainerLayer.bounds = CGRect(
            x: 0, y: 0, width: clipLayer.bounds.width, height: clipLayer.bounds.height)

        for row in 0..<geometry.rows {
            let layer = makeRowLayer()
            layer.frame = CGRect(
                x: 0, y: fullHeight - CGFloat(row + 1) * cellSize.height,
                width: fullWidth, height: cellSize.height)
            let isInnerRow = row >= geometry.top && row < geometry.rows - geometry.bottom
            if isInnerRow, geometry.left == 0, geometry.right == 0 {
                layer.isHidden = true
            }
            baseLayer.addSublayer(layer)
            baseRowLayers.append(layer)
            baseBindings.append(nil)
        }

        if geometry.innerRows > 0, geometry.innerCols > 0 {
            for _ in 0...geometry.innerRows {
                let layer = makeRowLayer()
                rowContainerLayer.addSublayer(layer)
                rowSlots.append(FilmstripSlot(
                    layer: layer, logicalRow: nil, binding: nil))
            }
        }
    }

    private func makeRowLayer() -> CALayer {
        let row = CALayer()
        disableActions(on: row)
        row.contentsGravity = .resize
        row.contentsScale = scale
        row.isOpaque = true
        return row
    }

    private func bindAuthoritativeRows() {
        guard authoritativeRows.count == baseRowLayers.count else { return }
        for row in authoritativeRows.indices {
            let isInnerRow = row >= geometry.top && row < geometry.rows - geometry.bottom
            if isInnerRow, geometry.left == 0, geometry.right == 0 {
                // Initialized hidden once in rebuildLayers. The permanent
                // filmstrip is authoritative here, so there is no per-present
                // duplicate contents/hidden write for the occluded base.
                continue
            }
            bind(authoritativeRows[row], to: baseRowLayers[row], binding: &baseBindings[row])
        }
    }

    private func render(forceBindings: Bool) {
        guard hasAuthoritativeRows, !rowSlots.isEmpty else { return }
        let firstRow = Int(floor(position))
        let needsBindings = forceBindings || rowsNeedBinding || firstRow != lastBoundFirstRow
        if needsBindings {
            let desiredRows = Array(firstRow...(firstRow + geometry.innerRows))
            let desiredSet = Set(desiredRows)
            var assigned = Set<Int>()
            var available: [Int] = []

            for index in rowSlots.indices {
                if let logicalRow = rowSlots[index].logicalRow,
                    desiredSet.contains(logicalRow), !assigned.contains(logicalRow)
                {
                    assigned.insert(logicalRow)
                } else {
                    rowSlots[index].logicalRow = nil
                    rowSlots[index].binding = nil
                    available.append(index)
                }
            }

            for logicalRow in desiredRows where !assigned.contains(logicalRow) {
                guard let index = available.popLast() else { break }
                rowSlots[index].logicalRow = logicalRow
                let innerHeight = CGFloat(geometry.innerRows) * cellSize.height
                rowSlots[index].layer.frame = CGRect(
                    x: 0,
                    y: innerHeight - CGFloat(logicalRow + 1) * cellSize.height,
                    width: CGFloat(geometry.innerCols) * cellSize.width,
                    height: cellSize.height)
            }

            for index in rowSlots.indices {
                guard let logicalRow = rowSlots[index].logicalRow,
                    let slice = history[logicalRow]
                else {
                    rowSlots[index].layer.contents = nil
                    rowSlots[index].layer.isHidden = true
                    rowSlots[index].binding = nil
                    continue
                }
                bind(
                    slice, to: rowSlots[index].layer,
                    binding: &rowSlots[index].binding)
            }
            rowsNeedBinding = false
        }
        lastBoundFirstRow = firstRow

        let translation = pixelSnap(
            position * cellSize.height, scale: scale)
        if translation != lastTranslationY {
            rowContainerLayer.setAffineTransform(
                CGAffineTransform(translationX: 0, y: translation))
            lastTranslationY = translation
        }
        clipLayer.isHidden = false
    }

    private func bind(
        _ row: SharedImageRow, to layer: CALayer,
        binding: inout RowLayerBinding?
    ) {
        let next = RowLayerBinding(token: row.token, contentsRect: row.contentsRect)
        guard binding != next || layer.isHidden else { return }
        layer.isHidden = false
        layer.contents = row.layerContents.object
        layer.contentsRect = row.contentsRect
        layer.contentsScale = scale
        binding = next
    }

    /// Move bound slots into the new history coordinate space without
    /// touching contents. The simultaneous envelope retarget cancels this
    /// frame shift visually; only newly exposed edge slots need a new image.
    private func shiftFilmstripSlots(by logicalRows: Int) {
        guard logicalRows != 0 else { return }
        for index in rowSlots.indices {
            guard let logicalRow = rowSlots[index].logicalRow else { continue }
            let shifted = logicalRow + logicalRows
            rowSlots[index].logicalRow = shifted
            let innerHeight = CGFloat(geometry.innerRows) * cellSize.height
            rowSlots[index].layer.frame = CGRect(
                x: 0,
                y: innerHeight - CGFloat(shifted + 1) * cellSize.height,
                width: CGFloat(geometry.innerCols) * cellSize.width,
                height: cellSize.height)
        }
    }

    func visibleLayer(sourceRow: Int) -> CALayer? {
        let candidates = rowSlots.compactMap { slot -> (Int, CALayer)? in
            guard let logicalRow = slot.logicalRow, !slot.layer.isHidden,
                history[logicalRow]?.sourceRow == sourceRow
            else { return nil }
            return (logicalRow, slot.layer)
        }
        return candidates.first(where: {
            $0.0 >= 0 && $0.0 < geometry.innerRows
        })?.1 ?? candidates.first?.1
    }

    private func pixelSnap(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        (value * max(1, scale)).rounded() / max(1, scale)
    }

    private func disableActions(on layer: CALayer) {
        layer.actions = [
            "position": NSNull(), "bounds": NSNull(), "frame": NSNull(),
            "contents": NSNull(), "contentsRect": NSNull(), "hidden": NSNull(),
            "transform": NSNull(), "opacity": NSNull(), "sublayers": NSNull(),
        ]
    }
}
