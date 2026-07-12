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

struct ScrollMotionSample: Equatable {
    var position: CGFloat = 0
    var velocity: CGFloat = 0
    var acceleration: CGFloat = 0

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(
            position: lhs.position + rhs.position,
            velocity: lhs.velocity + rhs.velocity,
            acceleration: lhs.acceleration + rhs.acceleration)
    }
}

/// A quintic minimum-jerk residual that reaches rest with continuous position,
/// velocity, and acceleration. The residual begins at `initial.position` and
/// ends at zero; adding `-delta` when the authoritative viewport rotates keeps
/// the visible camera stationary without injecting a velocity/acceleration
/// tooth at the row boundary.
struct MinimumJerkScrollSegment: Equatable {
    let initial: ScrollMotionSample
    let duration: CFTimeInterval
    private(set) var elapsed: CFTimeInterval = 0

    init(initial: ScrollMotionSample, duration: CFTimeInterval) {
        self.initial = initial
        self.duration = max(0.001, duration)
    }

    var isFinished: Bool { elapsed >= duration }

    var sample: ScrollMotionSample {
        guard !isFinished else { return ScrollMotionSample() }
        let u = CGFloat(min(1, max(0, elapsed / duration)))
        let u2 = u * u
        let u3 = u2 * u
        let u4 = u3 * u
        let u5 = u4 * u
        let time = CGFloat(duration)

        // Quintic Hermite basis for initial position/velocity/acceleration,
        // with final position/velocity/acceleration all equal to zero.
        let hPosition = 1 - 10 * u3 + 15 * u4 - 6 * u5
        let hVelocity = u - 6 * u3 + 8 * u4 - 3 * u5
        let hAcceleration = 0.5 * (u2 - 3 * u3 + 3 * u4 - u5)

        let dhPosition = -30 * u2 + 60 * u3 - 30 * u4
        let dhVelocity = 1 - 18 * u2 + 32 * u3 - 15 * u4
        let dhAcceleration = u - 4.5 * u2 + 6 * u3 - 2.5 * u4

        let ddhPosition = -60 * u + 180 * u2 - 120 * u3
        let ddhVelocity = -36 * u + 96 * u2 - 60 * u3
        let ddhAcceleration = 1 - 9 * u + 18 * u2 - 10 * u3

        return ScrollMotionSample(
            position: hPosition * initial.position
                + hVelocity * time * initial.velocity
                + hAcceleration * time * time * initial.acceleration,
            velocity: dhPosition * initial.position / time
                + dhVelocity * initial.velocity
                + dhAcceleration * time * initial.acceleration,
            acceleration: ddhPosition * initial.position / (time * time)
                + ddhVelocity * initial.velocity / time
                + ddhAcceleration * initial.acceleration)
    }

    mutating func advance(by elapsed: CFTimeInterval) {
        self.elapsed = min(duration, self.elapsed + max(0, elapsed))
    }
}

/// A gesture-level camera envelope. Every authoritative displacement adds a
/// C2 residual pulse; overlapping pulses turn repeated rows into one smooth
/// velocity envelope without changing derivatives at insertion boundaries.
struct ContinuousScrollEnvelope: Equatable {
    private(set) var segments: [MinimumJerkScrollSegment] = []

    var sample: ScrollMotionSample {
        segments.reduce(ScrollMotionSample()) { $0 + $1.sample }
    }
    var position: CGFloat { sample.position }
    var velocity: CGFloat { sample.velocity }
    var acceleration: CGFloat { sample.acceleration }
    var isActive: Bool { !segments.isEmpty }
    var negativeMagnitude: CGFloat {
        -segments.reduce(CGFloat.zero) { result, segment in
            result + min(0, segment.sample.position)
        }
    }
    var positiveMagnitude: CGFloat {
        segments.reduce(CGFloat.zero) { result, segment in
            result + max(0, segment.sample.position)
        }
    }

    mutating func add(positionOffset: CGFloat, duration: CFTimeInterval) {
        guard positionOffset != 0 else { return }
        segments.append(MinimumJerkScrollSegment(
            initial: ScrollMotionSample(position: positionOffset),
            duration: duration))
    }

    mutating func advance(by elapsed: CFTimeInterval) {
        guard elapsed > 0 else { return }
        for index in segments.indices {
            segments[index].advance(by: elapsed)
        }
        segments.removeAll(where: \.isFinished)
    }

    mutating func settle() {
        segments.removeAll(keepingCapacity: true)
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
    /// At this width, three 60 ms row steps already overlap; denser wheel and
    /// key-repeat streams converge on a nearly flat, continuous velocity.
    static let motionEnvelopeDuration: CFTimeInterval = 0.180

    let gridID: Int

    private(set) var geometry = SmoothViewportGeometry(rows: 0, cols: 0, margins: nil)
    private(set) var history = CircularRowHistory<SharedImageRow>(capacity: 0)
    private(set) var motion = ContinuousScrollEnvelope()
    /// Backlog absorber for sustained far scrolling. The fixed-duration
    /// envelope drains debt too slowly under page-jump storms, forcing
    /// per-event cuts at the retained-history bound; this spring's drain
    /// rate scales with the backlog, so storms reach a smooth equilibrium
    /// below the physical one-screenful limit.
    private(set) var catchUp = CriticalDampedSpring(
        animationLength: SmoothViewportState.motionEnvelopeDuration)
    private(set) var isActive = false
    private(set) var lastSemanticDelta = 0

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

    var position: CGFloat { motion.position + catchUp.position }
    var velocity: CGFloat { motion.velocity + catchUp.velocity }
    var acceleration: CGFloat { motion.acceleration }
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
    @discardableResult
    func present(
        rowSnapshots: [RenderedRowSnapshot], rows: Int, cols: Int,
        margins: ViewportMargins?, scrolls: [ScrollDelta], semanticDelta: Int?,
        semanticMotion: ViewportScrollMotion? = nil,
        cellSize: CGSize, scale: CGFloat, host: CALayer, animate: Bool
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
            cellSize: cellSize, scale: scale, host: host, animate: animate)
    }

    /// Testing/snapshot compatibility. The application never takes this
    /// full-grid path; outgoing slices are detached before entering history.
    @discardableResult
    func present(
        image: CGImage, rows: Int, cols: Int, margins: ViewportMargins?,
        scrolls: [ScrollDelta], semanticDelta: Int?,
        semanticMotion: ViewportScrollMotion? = nil, cellSize: CGSize,
        scale: CGFloat, host: CALayer, animate: Bool
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
            cellSize: cellSize, scale: scale, host: host, animate: animate)
    }

    @discardableResult
    private func present(
        authoritativeRows nextRows: [SharedImageRow], rows: Int, cols: Int,
        margins: ViewportMargins?, scrolls: [ScrollDelta], semanticDelta: Int?,
        semanticMotion: ViewportScrollMotion?,
        cellSize: CGSize, scale: CGFloat, host: CALayer, animate: Bool
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
            motion.settle()
            catchUp.settle()
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
        if !animate, isActive {
            // An explicitly atomic/Reduce Motion frame supersedes any visual
            // tail even when it contains only edits or highlight changes.
            settle()
        } else if !eligible, carriesMovement {
            settle()
        }

        if eligible, hasAuthoritativeRows {
            if delta != 0 {
                let largestStep = semanticMotion?.largestStepMagnitude
                    ?? Int(min(UInt(Int.max), delta.magnitude))
                eligible = rotateForNewViewport(
                    delta, trueFar: largestStep > geometry.innerRows,
                    farDirection: semanticMotion?.largestStepDelta.signum()
                        ?? delta.signum())
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
            lastSemanticDelta = semanticMotion?.lastDelta ?? delta
            isActive = motion.isActive || !catchUp.isSettled
        }
        render(forceBindings: false)
        return eligible && hasAuthoritativeRows && isActive
    }

    /// Advance every active analytical residual to the latest display target.
    /// Delayed callbacks render only that exact resulting filmstrip position.
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

        if isActive {
            motion.advance(by: bounded)
            if !catchUp.isSettled {
                catchUp.advance(by: bounded)
                if catchUp.isSettled { catchUp.settle() }
            }
            if !motion.isActive, catchUp.isSettled {
                motion.settle()
                catchUp.settle()
                isActive = false
                lastSemanticDelta = 0
                discardNonCurrentHistory()
            }
            render(forceBindings: false)
        }

        return isActive
    }

    func settle() {
        motion.settle()
        catchUp.settle()
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
            historyHead: history.head, position: motion.position,
            velocity: motion.velocity, acceleration: motion.acceleration,
            snappedTranslationPixels: snappedTranslationPixels,
            cursorAuthoritativeY: cursorAuthoritativeY,
            cursorVisualY: cursorVisualY)
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
        let catchingUp = !catchUp.isSettled

        if trueFar, !motion.isActive, !catchingUp {
            // An isolated far jump stays a cut: teleport with a one-row cue.
            discardNonCurrentHistory()
            guard copyDisplacedRows(for: direction) else { return false }
            history.rotate(by: direction)
            shiftFilmstripSlots(by: -direction)
            motion.settle()
            motion.add(
                positionOffset: -CGFloat(direction),
                duration: Self.motionEnvelopeDuration)
            return true
        }

        let retainedMagnitude = Int(min(UInt(height), delta.magnitude))
        let animatedDelta = direction * retainedMagnitude
        if trueFar { discardNonCurrentHistory() }

        guard copyDisplacedRows(for: animatedDelta) else { return false }
        history.rotate(by: animatedDelta)
        shiftFilmstripSlots(by: -animatedDelta)

        let requestedOffset = -CGFloat(animatedDelta)
        if !trueFar, !catchingUp {
            let capacity = CGFloat(height)
            let available = requestedOffset < 0
                ? max(0, capacity - motion.negativeMagnitude)
                : max(0, capacity - motion.positiveMagnitude)
            if abs(requestedOffset) <= available {
                motion.add(
                    positionOffset: requestedOffset,
                    duration: Self.motionEnvelopeDuration)
                return true
            }
        }

        // Catch-up regime: migrating the envelope's position and velocity
        // into the spring keeps the camera continuous; only the retained-
        // history screenful remains a hard bound, and in equilibrium the
        // spring's backlog-proportional drain stays below it.
        catchUp.position += motion.position
        catchUp.velocity += motion.velocity
        motion.settle()
        catchUp.position = max(
            -CGFloat(height),
            min(CGFloat(height), catchUp.position + requestedOffset))
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
