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
        guard !scrolls.contains(where: { delta in
            delta.cols != 0 || delta.rows == 0
                || delta.top != top || delta.bottom != rows - bottom
                || delta.left != left || delta.right != cols - right
                || delta.rows.signum() != semanticDelta.signum()
        }) else { return false }
        return true
    }
}

/// One logical line. Current rows share the authoritative full image through
/// `contentsRect`; only outgoing history edges are detached into bounded,
/// row-sized images so old full-grid generations are never retained.
struct SharedImageRow {
    let image: CGImage
    let contentsRect: CGRect
    let sourceRow: Int
    let generation: UInt64
}

struct ScrollDiagnosticSample: Sendable, Equatable {
    let timestamp: CFTimeInterval
    let gridID: Int
    let delta: Int
    let historyHead: Int
    let position: CGFloat
    let velocity: CGFloat
    let cursorAuthoritativeY: CGFloat?
    let cursorVisualY: CGFloat?
}

/// A persistent, per-grid visual viewport. The normal grid layer always holds
/// Neovim's final bitmap; this state only supplies continuous inter-frame rows.
@MainActor
final class SmoothViewportState {
    let gridID: Int

    private(set) var geometry = SmoothViewportGeometry(rows: 0, cols: 0, margins: nil)
    private(set) var history = CircularRowHistory<SharedImageRow>(capacity: 0)
    private(set) var spring = CriticalDampedSpring()
    private(set) var isActive = false
    private(set) var lastSemanticDelta = 0

    private weak var hostLayer: CALayer?
    private let clipLayer = CALayer()
    private var rowLayers: [CALayer] = []
    private var cellSize: CGSize = .zero
    private var scale: CGFloat = 1
    private var imageGeneration: UInt64 = 0
    private var lastBoundFirstRow: Int?
    private var lastBoundGeneration: UInt64 = .max
    private var hasAuthoritativeRows = false

    init(gridID: Int) {
        self.gridID = gridID
        disableActions(on: clipLayer)
        clipLayer.masksToBounds = true
        clipLayer.zPosition = 1
        clipLayer.isHidden = true
    }

    var position: CGFloat { spring.position }
    var velocity: CGFloat { spring.velocity }
    var historyHead: Int { history.head }
    var overlayLayer: CALayer { clipLayer }
    var visibleRowLayers: [CALayer] { rowLayers }

    /// Install a final renderer image and, when eligible, add its semantic
    /// viewport movement to the existing spring without resetting velocity.
    @discardableResult
    func present(
        image: CGImage, rows: Int, cols: Int, margins: ViewportMargins?,
        scrolls: [ScrollDelta], semanticDelta: Int?, cellSize: CGSize,
        scale: CGFloat, host: CALayer, animate: Bool
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
            settle()
            seedCurrentRows(from: image)
            // A resize or first image has no coherent predecessor to animate.
            return false
        }

        let delta = semanticDelta ?? 0
        var eligible = animate && geometry.accepts(scrolls, semanticDelta: delta)
        // Unsupported scroll shapes are deliberately atomic.  They must also
        // terminate any older full-viewport tail; otherwise that stale row
        // history would keep moving over the newly committed partial or
        // horizontal scroll.
        if !eligible, !scrolls.isEmpty || (semanticDelta != nil && delta != 0) {
            settle()
        }

        if eligible, hasAuthoritativeRows {
            eligible = rotateForNewViewport(delta)
            if !eligible { settle() }
        }
        seedCurrentRows(from: image)

        guard eligible, hasAuthoritativeRows else {
            if !isActive { hideOverlay() }
            return false
        }

        lastSemanticDelta = delta
        isActive = true
        clipLayer.isHidden = false
        render()
        return true
    }

    /// Integrate in bounded steps so a delayed main-thread frame cannot kick
    /// the animation far past the trajectory sampled at normal refresh rates.
    @discardableResult
    func advance(by elapsed: CFTimeInterval) -> Bool {
        guard isActive else { return false }
        // A display link may stop while its view is hidden. One second is far
        // beyond this spring's visible lifetime and bounds subdivision work
        // when the window returns after minutes off-screen.
        var remaining = min(max(0, elapsed), 1.0)
        let maximumStep: CFTimeInterval = 1.0 / 120.0
        while remaining > 0 {
            let step = min(remaining, maximumStep)
            spring.advance(by: step)
            remaining -= step
        }

        // Do not hide the history until its snapped presentation is already
        // identical to the authoritative layer. A line-relative epsilon can
        // still be a whole Retina pixel with large fonts.
        let hasNoPixelResidual = (spring.position * cellSize.height * scale).rounded() == 0
        if spring.isSettled, hasNoPixelResidual {
            settle()
            return false
        }
        render()
        return true
    }

    func settle() {
        spring.settle()
        isActive = false
        lastSemanticDelta = 0
        discardNonCurrentHistory()
        hideOverlay()
    }

    func destroy() {
        settle()
        clipLayer.removeFromSuperlayer()
        hostLayer = nil
        history.reset(capacity: 0)
        rowLayers.removeAll()
        hasAuthoritativeRows = false
    }

    /// The no-snap invariant: when the overlay is hidden, every logical final
    /// row must still select the exact CGImage installed on the base layer.
    func currentRowsReference(_ image: CGImage) -> Bool {
        guard geometry.innerRows > 0 else { return true }
        return (0..<geometry.innerRows).allSatisfy { logicalRow in
            history[logicalRow]?.image === image
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

    @discardableResult
    private func rotateForNewViewport(_ delta: Int) -> Bool {
        let proposed = spring.position - CGFloat(delta)
        let capacity = CGFloat(geometry.innerRows)
        let far = abs(delta) > geometry.innerRows || abs(proposed) > capacity
        let animatedDelta = far ? delta.signum() : delta
        if far {
            // Preserve just one old edge line to communicate direction; the
            // unrelated bulk of a far jump is already authoritative beneath.
            discardNonCurrentHistory()
        }

        // The current viewport shares one full authoritative image. Before
        // its edge rows rotate into history, detach only those rows into true
        // row-sized images. This preserves reversal continuity without
        // stranding one full-grid raster allocation per wheel tick.
        guard copyDisplacedRows(for: animatedDelta) else { return false }
        history.rotate(by: animatedDelta)
        if far {
            spring.position = -CGFloat(animatedDelta)
            spring.constrainVelocityTowardTarget()
        } else {
            spring.position = proposed
        }
        // Deliberately preserve spring.velocity, including through reversal.
        return true
    }

    private func copyDisplacedRows(for delta: Int) -> Bool {
        let height = geometry.innerRows
        guard height > 0, delta != 0 else { return false }
        let rows: Range<Int>
        if delta > 0 {
            rows = 0..<min(delta, height)
        } else {
            rows = max(0, height + delta)..<height
        }
        for logicalRow in rows {
            guard let slice = history[logicalRow],
                let detached = detachedRow(from: slice)
            else { return false }
            history[logicalRow] = detached
        }
        return true
    }

    private func detachedRow(from slice: SharedImageRow) -> SharedImageRow? {
        if slice.contentsRect == CGRect(x: 0, y: 0, width: 1, height: 1) {
            return slice
        }

        let imageWidth = CGFloat(slice.image.width)
        let imageHeight = CGFloat(slice.image.height)
        let x0 = max(0, min(slice.image.width,
            Int((slice.contentsRect.minX * imageWidth).rounded())))
        let x1 = max(x0, min(slice.image.width,
            Int((slice.contentsRect.maxX * imageWidth).rounded())))
        // CALayer contentsRect is bottom-up, while CGImage cropping uses the
        // renderer snapshot's top-down pixel coordinates.
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
            sourceRow: slice.sourceRow, generation: slice.generation)
    }

    private func discardNonCurrentHistory() {
        guard geometry.innerRows > 0 else { return }
        for logicalRow in geometry.innerRows..<(geometry.innerRows * 2) {
            history[logicalRow] = nil
        }
    }

    private func seedCurrentRows(from image: CGImage) {
        guard geometry.innerRows > 0, geometry.innerCols > 0 else {
            hasAuthoritativeRows = false
            return
        }
        imageGeneration &+= 1
        let x = CGFloat(geometry.left) / CGFloat(max(1, geometry.cols))
        let width = CGFloat(geometry.innerCols) / CGFloat(max(1, geometry.cols))
        let rowHeight = 1 / CGFloat(max(1, geometry.rows))
        for logicalRow in 0..<geometry.innerRows {
            let sourceRow = geometry.top + logicalRow
            history[logicalRow] = SharedImageRow(
                image: image,
                contentsRect: CGRect(
                    // CALayer contentsRect uses bottom-up unit coordinates;
                    // Neovim/GridRenderer rows are numbered from the top.
                    x: x, y: 1 - CGFloat(sourceRow + 1) * rowHeight,
                    width: width, height: rowHeight),
                sourceRow: sourceRow, generation: imageGeneration)
        }
        hasAuthoritativeRows = true
    }

    private func attach(to host: CALayer) {
        if hostLayer !== host {
            clipLayer.removeFromSuperlayer()
            host.addSublayer(clipLayer)
            hostLayer = host
        } else if clipLayer.superlayer == nil {
            host.addSublayer(clipLayer)
        }
    }

    private func rebuildLayers() {
        rowLayers.forEach { $0.removeFromSuperlayer() }
        rowLayers = []
        history.reset(capacity: geometry.innerRows * 2)
        hasAuthoritativeRows = false
        lastBoundFirstRow = nil
        lastBoundGeneration = .max
        clipLayer.frame = geometry.clipRect(cellSize: cellSize)
        guard geometry.innerRows > 0, geometry.innerCols > 0 else { return }
        for _ in 0...geometry.innerRows {
            let row = CALayer()
            disableActions(on: row)
            row.contentsGravity = .resize
            row.contentsScale = scale
            row.isOpaque = true
            clipLayer.addSublayer(row)
            rowLayers.append(row)
        }
    }

    private func render() {
        guard isActive, !rowLayers.isEmpty else { return }
        let firstRow = Int(floor(spring.position))
        if firstRow != lastBoundFirstRow || imageGeneration != lastBoundGeneration {
            for (index, layer) in rowLayers.enumerated() {
                guard let slice = history[firstRow + index] else {
                    layer.contents = nil
                    layer.isHidden = true
                    continue
                }
                layer.isHidden = false
                layer.contents = slice.image
                layer.contentsRect = slice.contentsRect
                layer.contentsScale = scale
            }
            lastBoundFirstRow = firstRow
            lastBoundGeneration = imageGeneration
        }

        let fractionalOffset = CGFloat(firstRow) - spring.position
        let width = CGFloat(geometry.innerCols) * cellSize.width
        let height = CGFloat(geometry.innerRows) * cellSize.height
        for (index, layer) in rowLayers.enumerated() {
            // CALayer sublayer coordinates are bottom-up even inside the
            // flipped NSView hierarchy. Convert the desired top-down line
            // position explicitly; relying on nested isGeometryFlipped flags
            // double-flips the row order on a live AppKit-backed layer tree.
            let y = pixelSnap(
                height - (CGFloat(index) + fractionalOffset + 1) * cellSize.height,
                scale: scale)
            layer.frame = CGRect(x: 0, y: y, width: width, height: cellSize.height)
        }
    }

    private func hideOverlay() {
        clipLayer.isHidden = true
        lastBoundFirstRow = nil
        lastBoundGeneration = .max
        for layer in rowLayers {
            layer.contents = nil
            layer.isHidden = true
        }
    }

    private func pixelSnap(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        (value * max(1, scale)).rounded() / max(1, scale)
    }

    private func disableActions(on layer: CALayer) {
        layer.actions = [
            "position": NSNull(), "bounds": NSNull(), "contents": NSNull(),
            "contentsRect": NSNull(), "hidden": NSNull(), "transform": NSNull(),
            "opacity": NSNull(), "sublayers": NSNull(),
        ]
    }
}
