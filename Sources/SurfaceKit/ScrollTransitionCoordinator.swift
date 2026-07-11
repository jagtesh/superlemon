import AppKit
import GridKit
import QuartzCore

/// The visual policy for reconciling Neovim's cell-at-a-time scroll frames.
public enum ScrollMotionStyle: Sendable, Equatable {
    /// Present every authoritative Neovim frame without interpolation.
    case immediate
    /// Reconcile discrete viewport rows with a short display-linked spring.
    case tightNative
}

/// Neovide's analytical critically damped spring, expressed in line units.
/// New input changes `position` and deliberately leaves `velocity` intact.
struct CriticalDampedSpring: Equatable {
    var position: CGFloat = 0
    var velocity: CGFloat = 0
    var animationLength: CFTimeInterval = 0.300

    mutating func advance(by elapsed: CFTimeInterval) {
        guard elapsed > 0 else { return }
        let omega = CGFloat(4 / max(0.001, animationLength))
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

    /// Bound a discontinuous retarget to a single, non-overshooting cue.
    /// Ordinary input never calls this and therefore preserves full velocity.
    mutating func constrainVelocityTowardTarget() {
        let omega = CGFloat(4 / max(0.001, animationLength))
        let criticalLimit = -position * omega
        if position < 0 {
            velocity = min(max(0, velocity), criticalLimit)
        } else if position > 0 {
            velocity = max(min(0, velocity), criticalLimit)
        } else {
            velocity = 0
        }
    }

    var isSettled: Bool {
        abs(position) < 0.01 && abs(velocity) < 0.10
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

    func accepts(_ scrolls: [ScrollDelta], semanticDelta: Int) -> Bool {
        guard semanticDelta != 0, innerRows > 0, innerCols > 0 else { return false }
        guard !scrolls.isEmpty else { return true }
        guard !scrolls.contains(where: { delta in
            delta.cols != 0 || delta.rows == 0
                || delta.top != top || delta.bottom != rows - bottom
                || delta.left != left || delta.right != cols - right
                || delta.rows.signum() != semanticDelta.signum()
        }) else { return false }
        return true
    }
}

/// One immutable raster row (or a testing-only slice of a full image).
/// Production scroll history retains row-sized images only.
struct SharedImageRow: @unchecked Sendable {
    let image: CGImage
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
    package let cursorAuthoritativeY: CGFloat?
    package let cursorVisualY: CGFloat?
}

private struct RowLayerBinding: Equatable {
    let token: RowImageToken
    let contentsRect: CGRect
}

private struct VeilSnapshotSource: @unchecked Sendable {
    let rows: [SharedImageRow]
    let outputWidth: Int
    let outputHeight: Int
}

/// Persistent per-grid row compositor. Exact authoritative row tiles are
/// always installed; scrolling only rebinds a row when an integer boundary is
/// crossed and translates one clipped container between those boundaries.
@MainActor
final class SmoothViewportState {
    let gridID: Int

    private(set) var geometry = SmoothViewportGeometry(rows: 0, cols: 0, margins: nil)
    private(set) var history = CircularRowHistory<SharedImageRow>(capacity: 0)
    private(set) var spring = CriticalDampedSpring()
    private(set) var isActive = false
    private(set) var lastSemanticDelta = 0

    private weak var hostLayer: CALayer?
    private let baseLayer = CALayer()
    private let clipLayer = CALayer()
    private let rowContainerLayer = CALayer()
    private let veilLayer = CALayer()
    private let glowLayer = CAGradientLayer()
    private var baseRowLayers: [CALayer] = []
    private var baseBindings: [RowLayerBinding?] = []
    private var rowLayers: [CALayer] = []
    private var rowBindings: [RowLayerBinding?] = []
    private var authoritativeRows: [SharedImageRow] = []
    private var cellSize: CGSize = .zero
    private var scale: CGFloat = 1
    private var presentationGeneration: UInt64 = 0
    private var lastBoundFirstRow: Int?
    private var lastTranslationY: CGFloat = .nan
    private var rowsNeedBinding = true
    private var hasAuthoritativeRows = false

    private(set) var isVeilActive = false
    private var veilElapsed: CFTimeInterval = 0
    private var veilDirection = 0
    private var cachedVeilImage: CGImage?
    private var veilSnapshotTask: Task<Void, Never>?
    private var veilSnapshotSerial: UInt64 = 0
    private var lastVeilSnapshotRequest: CFTimeInterval = 0
    private var receivedInputWhileClamped = false
    private var clampedDisplayPeriods = 0

    init(gridID: Int) {
        self.gridID = gridID
        for layer in [baseLayer, clipLayer, rowContainerLayer, veilLayer, glowLayer] {
            disableActions(on: layer)
        }
        baseLayer.zPosition = 0
        clipLayer.zPosition = 1
        clipLayer.masksToBounds = true
        rowContainerLayer.zPosition = 0
        veilLayer.zPosition = 2
        veilLayer.contentsGravity = .resizeAspectFill
        veilLayer.minificationFilter = .linear
        veilLayer.magnificationFilter = .linear
        veilLayer.isHidden = true
        glowLayer.zPosition = 3
        glowLayer.isHidden = true
        let accent = NSColor.controlAccentColor.withAlphaComponent(1).cgColor
        glowLayer.colors = [
            NSColor.clear.cgColor, accent, NSColor.clear.cgColor,
        ]
        glowLayer.locations = [0, 0.5, 1]
        glowLayer.startPoint = CGPoint(x: 0.5, y: 0)
        glowLayer.endPoint = CGPoint(x: 0.5, y: 1)
        clipLayer.addSublayer(rowContainerLayer)
        clipLayer.addSublayer(veilLayer)
        clipLayer.addSublayer(glowLayer)
    }

    var position: CGFloat { spring.position }
    var velocity: CGFloat { spring.velocity }
    var historyHead: Int { history.head }
    /// Kept for source compatibility with the previous transient overlay.
    /// It is now the permanent clipped exact-row viewport.
    var overlayLayer: CALayer { clipLayer }
    var visibleRowLayers: [CALayer] { rowLayers }
    var translatedContainerLayer: CALayer { rowContainerLayer }

    /// Production entry point: install cached row-sized renderer revisions.
    @discardableResult
    func present(
        rowSnapshots: [RenderedRowSnapshot], rows: Int, cols: Int,
        margins: ViewportMargins?, scrolls: [ScrollDelta], semanticDelta: Int?,
        cellSize: CGSize, scale: CGFloat, host: CALayer, animate: Bool
    ) -> Bool {
        let sourceRows = rowSnapshots.enumerated().map { row, snapshot in
            SharedImageRow(
                image: snapshot.image,
                contentsRect: CGRect(x: 0, y: 0, width: 1, height: 1),
                sourceRow: row, generation: snapshot.revision,
                token: snapshot.token, retainsFullGridImage: false)
        }
        return present(
            authoritativeRows: sourceRows, rows: rows, cols: cols,
            margins: margins, scrolls: scrolls, semanticDelta: semanticDelta,
            cellSize: cellSize, scale: scale, host: host, animate: animate)
    }

    /// Testing/snapshot compatibility. The application never takes this
    /// full-grid path; outgoing slices are detached before entering history.
    @discardableResult
    func present(
        image: CGImage, rows: Int, cols: Int, margins: ViewportMargins?,
        scrolls: [ScrollDelta], semanticDelta: Int?, cellSize: CGSize,
        scale: CGFloat, host: CALayer, animate: Bool
    ) -> Bool {
        presentationGeneration &+= 1
        let rowHeight = 1 / CGFloat(max(1, rows))
        let sourceRows = (0..<max(0, rows)).map { row in
            SharedImageRow(
                image: image,
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
            cellSize: cellSize, scale: scale, host: host, animate: animate)
    }

    @discardableResult
    private func present(
        authoritativeRows nextRows: [SharedImageRow], rows: Int, cols: Int,
        margins: ViewportMargins?, scrolls: [ScrollDelta], semanticDelta: Int?,
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
            spring.settle()
            isActive = false
            deactivateVeil()
            authoritativeRows = nextRows
            bindAuthoritativeRows()
            seedCurrentRows()
            render(forceBindings: true)
            scheduleVeilSnapshot()
            return false
        }

        let delta = semanticDelta ?? 0
        var eligible = animate && geometry.accepts(scrolls, semanticDelta: delta)
        let carriesMovement = !scrolls.isEmpty || (semanticDelta != nil && delta != 0)
        if !eligible, carriesMovement {
            settle()
        }

        if eligible, hasAuthoritativeRows {
            eligible = rotateForNewViewport(delta)
            if !eligible { settle() }
        }

        authoritativeRows = nextRows
        bindAuthoritativeRows()
        seedCurrentRows()

        if eligible, hasAuthoritativeRows {
            lastSemanticDelta = delta
            isActive = true
        }
        render(forceBindings: false)
        scheduleVeilSnapshot()
        return eligible && hasAuthoritativeRows
    }

    /// Integrate in <= 1/120-second steps. Only the latest analytical result
    /// is rendered, so a delayed callback never causes obsolete layer commits.
    @discardableResult
    func advance(
        by elapsed: CFTimeInterval,
        nominalDisplayPeriod: CFTimeInterval = 1.0 / 60.0
    ) -> Bool {
        guard isActive || isVeilActive else { return false }
        let bounded = min(max(0, elapsed), 1.0)
        let nominal = max(1.0 / 240.0, nominalDisplayPeriod)

        if isActive, bounded >= nominal * 2, lastSemanticDelta != 0 {
            activateVeil(direction: lastSemanticDelta.signum())
        }
        if receivedInputWhileClamped {
            clampedDisplayPeriods += 1
            if clampedDisplayPeriods >= 2, lastSemanticDelta != 0 {
                activateVeil(direction: lastSemanticDelta.signum())
            }
        } else {
            clampedDisplayPeriods = 0
        }
        receivedInputWhileClamped = false

        if isActive {
            var remaining = bounded
            let maximumStep: CFTimeInterval = 1.0 / 120.0
            while remaining > 0 {
                let step = min(remaining, maximumStep)
                spring.advance(by: step)
                remaining -= step
            }

            let hasNoPixelResidual =
                (spring.position * cellSize.height * scale).rounded() == 0
            if spring.isSettled, hasNoPixelResidual {
                spring.settle()
                isActive = false
                lastSemanticDelta = 0
                discardNonCurrentHistory()
            }
            render(forceBindings: false)
        }

        advanceVeil(by: bounded)
        return isActive || isVeilActive
    }

    func settle() {
        spring.settle()
        isActive = false
        lastSemanticDelta = 0
        receivedInputWhileClamped = false
        clampedDisplayPeriods = 0
        discardNonCurrentHistory()
        deactivateVeil()
        render(forceBindings: false)
    }

    func destroy() {
        settle()
        veilSnapshotTask?.cancel()
        veilSnapshotTask = nil
        baseLayer.removeFromSuperlayer()
        clipLayer.removeFromSuperlayer()
        hostLayer = nil
        history.reset(capacity: 0)
        baseRowLayers.removeAll()
        rowLayers.removeAll()
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
            historyHead: history.head, position: spring.position,
            velocity: spring.velocity, cursorAuthoritativeY: cursorAuthoritativeY,
            cursorVisualY: cursorVisualY)
    }

    // MARK: - History

    @discardableResult
    private func rotateForNewViewport(_ delta: Int) -> Bool {
        let height = geometry.innerRows
        guard height > 0, delta != 0 else { return false }

        let direction = delta.signum()
        if isVeilActive, veilDirection != direction { deactivateVeil() }
        let far = abs(delta) > height
        let animatedDelta = far ? direction : delta
        if far { discardNonCurrentHistory() }

        guard copyDisplacedRows(for: animatedDelta) else { return false }
        history.rotate(by: animatedDelta)

        if far {
            spring.position = -CGFloat(animatedDelta)
            spring.constrainVelocityTowardTarget()
            activateVeil(direction: direction)
        } else {
            let proposed = spring.position - CGFloat(delta)
            let capacity = CGFloat(height)
            let bounded = min(capacity, max(-capacity, proposed))
            receivedInputWhileClamped = receivedInputWhileClamped || bounded != proposed
            spring.position = bounded
        }
        // Velocity is intentionally preserved, including through reversals
        // and cumulative-debt clamping.
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
            image: image, contentsRect: CGRect(x: 0, y: 0, width: 1, height: 1),
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
            image: row.image, contentsRect: rect, sourceRow: row.sourceRow,
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
        rowLayers.forEach { $0.removeFromSuperlayer() }
        baseRowLayers.removeAll()
        rowLayers.removeAll()
        baseBindings.removeAll()
        rowBindings.removeAll()
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
        veilLayer.frame = clipLayer.bounds
        glowLayer.frame = clipLayer.bounds

        for row in 0..<geometry.rows {
            let layer = makeRowLayer()
            layer.frame = CGRect(
                x: 0, y: fullHeight - CGFloat(row + 1) * cellSize.height,
                width: fullWidth, height: cellSize.height)
            baseLayer.addSublayer(layer)
            baseRowLayers.append(layer)
            baseBindings.append(nil)
        }

        let innerWidth = CGFloat(geometry.innerCols) * cellSize.width
        let innerHeight = CGFloat(geometry.innerRows) * cellSize.height
        if geometry.innerRows > 0, geometry.innerCols > 0 {
            for index in 0...geometry.innerRows {
                let layer = makeRowLayer()
                layer.frame = CGRect(
                    x: 0, y: innerHeight - CGFloat(index + 1) * cellSize.height,
                    width: innerWidth, height: cellSize.height)
                rowContainerLayer.addSublayer(layer)
                rowLayers.append(layer)
                rowBindings.append(nil)
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
            bind(authoritativeRows[row], to: baseRowLayers[row], binding: &baseBindings[row])
        }
    }

    private func render(forceBindings: Bool) {
        guard hasAuthoritativeRows, !rowLayers.isEmpty else { return }
        let firstRow = Int(floor(spring.position))
        let needsBindings = forceBindings || rowsNeedBinding || firstRow != lastBoundFirstRow
        if needsBindings, forceBindings || firstRow != lastBoundFirstRow {
            rowBindings = [RowLayerBinding?](repeating: nil, count: rowLayers.count)
        }
        if needsBindings {
            for (index, layer) in rowLayers.enumerated() {
                guard let slice = history[firstRow + index] else {
                    layer.contents = nil
                    layer.isHidden = true
                    rowBindings[index] = nil
                    continue
                }
                bind(slice, to: layer, binding: &rowBindings[index])
            }
            rowsNeedBinding = false
        }
        lastBoundFirstRow = firstRow

        let translation = pixelSnap(
            (spring.position - CGFloat(firstRow)) * cellSize.height, scale: scale)
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
        layer.contents = row.image
        layer.contentsRect = row.contentsRect
        layer.contentsScale = scale
        binding = next
    }

    private func pixelSnap(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        (value * max(1, scale)).rounded() / max(1, scale)
    }

    // MARK: - Adaptive velocity veil

    private func activateVeil(direction: Int) {
        guard direction != 0 else { return }
        if isVeilActive, veilDirection == direction { return }
        if isVeilActive { deactivateVeil() }
        isVeilActive = true
        veilDirection = direction
        veilElapsed = 0
        clampedDisplayPeriods = 0
        veilLayer.contents = cachedVeilImage
        veilLayer.opacity = 0
        veilLayer.isHidden = false
        glowLayer.opacity = 0
        glowLayer.isHidden = false
    }

    private func advanceVeil(by elapsed: CFTimeInterval) {
        guard isVeilActive else { return }
        veilElapsed += elapsed
        let fadeIn: CFTimeInterval = 1.0 / 60.0
        // Exact row revisions are already beneath the veil. Once its first
        // display-period fade-in is visible, begin the requested 50 ms exit.
        let fadeOutStart = fadeIn
        let hardLimit = min(0.150, fadeOutStart + 0.050)
        if veilElapsed >= hardLimit {
            deactivateVeil()
            return
        }

        let alpha: CGFloat
        if veilElapsed < fadeIn {
            alpha = CGFloat(veilElapsed / fadeIn)
        } else if veilElapsed <= fadeOutStart {
            alpha = 1
        } else {
            alpha = CGFloat((hardLimit - veilElapsed) / (hardLimit - fadeOutStart))
        }
        let progress = CGFloat(min(1, veilElapsed / hardLimit))
        let offset = CGFloat(veilDirection) * cellSize.height * 0.75 * progress
        veilLayer.opacity = Float(0.68 * alpha)
        veilLayer.setAffineTransform(
            CGAffineTransform(translationX: 0, y: offset).scaledBy(x: 1.015, y: 1.015))
        glowLayer.opacity = Float(0.08 * alpha)
        glowLayer.setAffineTransform(CGAffineTransform(
            translationX: 0,
            y: CGFloat(veilDirection) * clipLayer.bounds.height * (progress - 0.5)))
    }

    private func deactivateVeil() {
        isVeilActive = false
        veilElapsed = 0
        veilDirection = 0
        veilLayer.isHidden = true
        veilLayer.opacity = 0
        veilLayer.setAffineTransform(.identity)
        glowLayer.isHidden = true
        glowLayer.opacity = 0
        glowLayer.setAffineTransform(.identity)
    }

    /// Keep a throttled quarter-resolution exact snapshot ready. Composition
    /// occurs away from the main actor and only immutable CGImages cross the
    /// boundary; activation itself is a cheap contents/transform update.
    private func scheduleVeilSnapshot() {
        guard geometry.innerRows > 0, geometry.innerCols > 0,
            (0..<geometry.innerRows).allSatisfy({ history[$0] != nil })
        else { return }
        let now = CACurrentMediaTime()
        guard now - lastVeilSnapshotRequest >= 0.080 || cachedVeilImage == nil else { return }
        lastVeilSnapshotRequest = now
        veilSnapshotSerial &+= 1
        let serial = veilSnapshotSerial
        let rows = (0..<geometry.innerRows).compactMap { history[$0] }
        let width = max(1, Int(
            CGFloat(geometry.innerCols) * cellSize.width * scale / 4))
        let height = max(1, Int(
            CGFloat(geometry.innerRows) * cellSize.height * scale / 4))
        let source = VeilSnapshotSource(
            rows: rows, outputWidth: width, outputHeight: height)
        veilSnapshotTask?.cancel()
        veilSnapshotTask = Task.detached(priority: .utility) { [weak self] in
            let image = Self.makeVeilSnapshot(source)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.veilSnapshotSerial == serial else { return }
                self.cachedVeilImage = image
                // Do not replace the old-frame bridge with a newer exact
                // snapshot while it is visibly fading out.
                if self.isVeilActive, self.veilLayer.contents == nil {
                    self.veilLayer.contents = image
                }
            }
        }
    }

    nonisolated private static func makeVeilSnapshot(
        _ source: VeilSnapshotSource
    ) -> CGImage? {
        guard let context = GridRenderer.makeContext(
            width: source.outputWidth, height: source.outputHeight, scale: 1),
            !source.rows.isEmpty
        else { return nil }
        context.setBlendMode(.copy)
        context.interpolationQuality = .low
        let rowHeight = CGFloat(source.outputHeight) / CGFloat(source.rows.count)
        for (index, row) in source.rows.enumerated() {
            let width = CGFloat(row.image.width)
            let height = CGFloat(row.image.height)
            let crop = CGRect(
                x: row.contentsRect.minX * width,
                y: (1 - row.contentsRect.maxY) * height,
                width: row.contentsRect.width * width,
                height: row.contentsRect.height * height).integral
            guard crop.width > 0, crop.height > 0,
                let image = row.image.cropping(to: crop)
            else { continue }
            context.draw(image, in: CGRect(
                x: 0,
                y: CGFloat(source.rows.count - index - 1) * rowHeight,
                width: CGFloat(source.outputWidth), height: rowHeight))
        }
        return context.makeImage()
    }

    private func disableActions(on layer: CALayer) {
        layer.actions = [
            "position": NSNull(), "bounds": NSNull(), "frame": NSNull(),
            "contents": NSNull(), "contentsRect": NSNull(), "hidden": NSNull(),
            "transform": NSNull(), "opacity": NSNull(), "sublayers": NSNull(),
        ]
    }
}
