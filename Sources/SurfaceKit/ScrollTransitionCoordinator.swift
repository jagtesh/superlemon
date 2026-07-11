import AppKit
import GridKit
import QuartzCore

/// The visual policy for reconciling Neovim's cell-at-a-time scroll frames.
public enum ScrollMotionStyle: Sendable, Equatable {
    /// Present each authoritative Neovim frame without interpolation.
    case immediate
    /// Briefly translate the old pixels away to reveal the new frame below.
    case tightNative
}

/// Pure geometry used by the layer coordinator and its tests.
struct ScrollTransitionGeometry: Equatable {
    let region: CGRect
    let translation: CGPoint
    let duration: CFTimeInterval

    static func make(
        delta: ScrollDelta, rows: Int, cols: Int, cellSize: CGSize
    ) -> ScrollTransitionGeometry? {
        guard rows > 0, cols > 0, cellSize.width > 0, cellSize.height > 0,
            delta.top >= 0, delta.left >= 0,
            delta.bottom <= rows, delta.right <= cols,
            delta.bottom > delta.top, delta.right > delta.left,
            delta.rows != 0 || delta.cols != 0,
            abs(delta.rows) <= 3, abs(delta.cols) <= 3
        else { return nil }

        let distance = max(abs(delta.rows), abs(delta.cols))
        // One-cell moves get the full, perceptible glide. Larger moves finish
        // sooner so the animation never feels like input latency.
        let duration = max(0.045, 0.070 - Double(max(0, distance - 1)) * 0.0125)
        return ScrollTransitionGeometry(
            region: CGRect(
                x: CGFloat(delta.left) * cellSize.width,
                y: CGFloat(delta.top) * cellSize.height,
                width: CGFloat(delta.right - delta.left) * cellSize.width,
                height: CGFloat(delta.bottom - delta.top) * cellSize.height),
            translation: CGPoint(
                x: -CGFloat(delta.cols) * cellSize.width,
                y: -CGFloat(delta.rows) * cellSize.height),
            duration: duration)
    }
}

/// Owns the transient old-pixel overlay for one Neovim grid.
@MainActor
final class ScrollTransitionCoordinator {
    private weak var hostLayer: CALayer?
    private var overlay: CALayer?
    private var region: CGRect = .zero
    private var targetTranslation: CGPoint = .zero
    private var direction = CGPoint.zero
    private var generation = 0

    var isActive: Bool { overlay != nil }

    @discardableResult
    func transition(
        oldImage: CGImage, delta: ScrollDelta, gridRows: Int, gridCols: Int,
        cellSize: CGSize, scale: CGFloat, in host: CALayer
    ) -> CFTimeInterval? {
        guard let geometry = ScrollTransitionGeometry.make(
            delta: delta, rows: gridRows, cols: gridCols, cellSize: cellSize)
        else {
            settle()
            return nil
        }

        let newDirection = CGPoint(
            x: CGFloat(delta.cols.signum()), y: CGFloat(delta.rows.signum()))
        if let overlay, region == geometry.region,
            directionsAreCompatible(direction, newDirection)
        {
            let proposed = CGPoint(
                x: targetTranslation.x + geometry.translation.x,
                y: targetTranslation.y + geometry.translation.y)
            guard abs(proposed.x) <= 3 * cellSize.width,
                abs(proposed.y) <= 3 * cellSize.height
            else {
                settle()
                return start(
                    oldImage: oldImage, geometry: geometry, gridRows: gridRows,
                    gridCols: gridCols, scale: scale, in: host)
            }
            let from = overlay.presentation()?.transform ?? overlay.transform
            targetTranslation = proposed
            animate(overlay, from: from, to: transform(for: proposed), duration: geometry.duration)
            scheduleSettlement(after: geometry.duration)
            return geometry.duration
        }

        settle()
        direction = newDirection
        return start(
            oldImage: oldImage, geometry: geometry, gridRows: gridRows,
            gridCols: gridCols, scale: scale, in: host)
    }

    func settle() {
        generation += 1
        overlay?.removeAllAnimations()
        overlay?.removeFromSuperlayer()
        overlay = nil
        hostLayer = nil
        targetTranslation = .zero
        direction = .zero
        region = .zero
    }

    private func start(
        oldImage: CGImage, geometry: ScrollTransitionGeometry,
        gridRows: Int, gridCols: Int, scale: CGFloat, in host: CALayer
    ) -> CFTimeInterval {
        let pixelRect = CGRect(
            x: geometry.region.minX * scale,
            y: geometry.region.minY * scale,
            width: geometry.region.width * scale,
            height: geometry.region.height * scale).integral
        guard let cropped = oldImage.cropping(to: pixelRect) else { return 0 }

        let layer = CALayer()
        layer.actions = [
            "position": NSNull(), "bounds": NSNull(), "contents": NSNull(),
            "transform": NSNull(), "opacity": NSNull(),
        ]
        layer.frame = geometry.region
        layer.contents = cropped
        layer.contentsScale = scale
        layer.contentsGravity = .resize
        layer.isOpaque = true
        layer.zPosition = 1
        host.masksToBounds = true
        host.addSublayer(layer)

        hostLayer = host
        overlay = layer
        region = geometry.region
        targetTranslation = geometry.translation
        animate(
            layer, from: CATransform3DIdentity,
            to: transform(for: geometry.translation), duration: geometry.duration)
        scheduleSettlement(after: geometry.duration)
        return geometry.duration
    }

    private func animate(
        _ layer: CALayer, from: CATransform3D, to: CATransform3D,
        duration: CFTimeInterval
    ) {
        layer.transform = to
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = NSValue(caTransform3D: from)
        animation.toValue = NSValue(caTransform3D: to)
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: "superlemon.pixel-conveyor")
    }

    private func scheduleSettlement(after duration: CFTimeInterval) {
        generation += 1
        let expected = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.generation == expected else { return }
            self.settle()
        }
    }

    private func directionsAreCompatible(_ a: CGPoint, _ b: CGPoint) -> Bool {
        (a.x == 0 || b.x == 0 || a.x == b.x)
            && (a.y == 0 || b.y == 0 || a.y == b.y)
    }

    private func transform(for point: CGPoint) -> CATransform3D {
        CATransform3DMakeTranslation(point.x, point.y, 0)
    }
}
