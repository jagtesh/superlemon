import AppKit
import CoreGraphics
import CoreText
import GridKit
import NvimKit
import QuartzCore

// MARK: - Package bridge

/// Semantic style flags supplied by the Neovim-side minimap provider. At the
/// miniature scale foreground color carries most of the information, but
/// retaining traits lets the native rasterizer preserve recognizable weight
/// and slant where the active font supports them.
package struct MinimapTextStyle: OptionSet, Sendable, Hashable {
    package let rawValue: UInt8

    package init(rawValue: UInt8) { self.rawValue = rawValue }

    package static let bold = Self(rawValue: 1 << 0)
    package static let italic = Self(rawValue: 1 << 1)
    package static let underline = Self(rawValue: 1 << 2)
}

/// A resolved syntax run. Byte offsets are UTF-8 offsets into `MinimapLine`'s
/// raw text, matching Neovim's buffer-column convention.
package struct MinimapHighlightSpan: Sendable, Equatable, Hashable {
    package var byteRange: Range<Int>
    package var foregroundRGB: UInt32
    package var style: MinimapTextStyle

    package init(
        byteRange: Range<Int>, foregroundRGB: UInt32,
        style: MinimapTextStyle = []
    ) {
        self.byteRange = byteRange
        self.foregroundRGB = foregroundRGB
        self.style = style
    }
}

package struct MinimapLine: Sendable, Equatable {
    package var text: String
    package var spans: [MinimapHighlightSpan]

    package init(text: String, spans: [MinimapHighlightSpan] = []) {
        self.text = text
        self.spans = spans
    }
}

/// Per-window identity required to reject stale asynchronous chunks.
package struct MinimapBufferTopology: Sendable, Equatable, Hashable {
    package var windowHandle: Int
    package var bufferHandle: Int
    package var changedTick: Int64
    package var totalLineCount: Int
    package var highlightGeneration: UInt64
    package var tabstop: Int
    package var bufferLabel: String
    package var filetype: String

    package init(
        windowHandle: Int, bufferHandle: Int, changedTick: Int64,
        totalLineCount: Int, highlightGeneration: UInt64,
        tabstop: Int = 4, bufferLabel: String = "", filetype: String = ""
    ) {
        self.windowHandle = windowHandle
        self.bufferHandle = bufferHandle
        self.changedTick = changedTick
        self.totalLineCount = max(0, totalLineCount)
        self.highlightGeneration = highlightGeneration
        self.tabstop = max(1, tabstop)
        self.bufferLabel = bufferLabel
        self.filetype = filetype
    }
}

package struct MinimapContentRangeRequest: Sendable, Equatable {
    package var requestID: UInt64
    package var gridID: Int
    package var topology: MinimapBufferTopology
    package var lineRange: Range<Int>
    package var maxColumns: Int

    package init(
        requestID: UInt64, gridID: Int,
        topology: MinimapBufferTopology, lineRange: Range<Int>,
        maxColumns: Int = 160
    ) {
        self.requestID = requestID
        self.gridID = gridID
        self.topology = topology
        self.lineRange = lineRange
        self.maxColumns = max(1, maxColumns)
    }
}

/// Immutable provider response. The response must echo the request and model
/// generations; SurfaceKit silently rejects anything stale.
package struct MinimapContentChunk: Sendable, Equatable {
    package var requestID: UInt64
    package var gridID: Int
    package var topology: MinimapBufferTopology
    /// Zero-based half-open line coordinates, matching `lineRange`.
    package var firstLine: Int
    package var lastLine: Int
    /// True only on the provider's final chunk for this request.
    package var complete: Bool
    package var lines: [MinimapLine]

    package init(
        requestID: UInt64, gridID: Int,
        topology: MinimapBufferTopology, firstLine: Int, lastLine: Int,
        complete: Bool, lines: [MinimapLine]
    ) {
        self.requestID = requestID
        self.gridID = gridID
        self.topology = topology
        self.firstLine = max(0, firstLine)
        self.lastLine = max(self.firstLine, lastLine)
        self.complete = complete
        self.lines = Array(lines.prefix(self.lastLine - self.firstLine))
    }

    /// Convenience for single-chunk producers and source compatibility with
    /// the initial bridge draft.
    package init(
        requestID: UInt64, gridID: Int,
        topology: MinimapBufferTopology, startLine: Int,
        lines: [MinimapLine], complete: Bool = true
    ) {
        let first = max(0, startLine)
        self.init(
            requestID: requestID, gridID: gridID, topology: topology,
            firstLine: first, lastLine: first + lines.count,
            complete: complete, lines: lines)
    }

    package var startLine: Int { firstLine }

    package var lineRange: Range<Int> {
        firstLine..<lastLine
    }
}

/// `cols == rows == 0` releases UI ownership back to Neovim.
package struct GridAccessorySizeRequest: Sendable, Equatable {
    package var gridID: Int
    package var windowHandle: Int
    package var cols: Int
    package var rows: Int

    package init(gridID: Int, windowHandle: Int, cols: Int, rows: Int) {
        self.gridID = gridID
        self.windowHandle = windowHandle
        self.cols = cols
        self.rows = rows
    }

    package var releasesOwnership: Bool { cols == 0 && rows == 0 }
}

package enum GridAccessoryGesturePhase: Sendable, Equatable {
    case began
    case changed
    case ended
}

package struct GridAccessoryViewportTargetRequest: Sendable, Equatable {
    package var gridID: Int
    package var windowHandle: Int
    package var bufferHandle: Int?
    package var targetTopline: Int
    package var phase: GridAccessoryGesturePhase

    package init(
        gridID: Int, windowHandle: Int, bufferHandle: Int?,
        targetTopline: Int, phase: GridAccessoryGesturePhase
    ) {
        self.gridID = gridID
        self.windowHandle = windowHandle
        self.bufferHandle = bufferHandle
        self.targetTopline = max(0, targetTopline)
        self.phase = phase
    }
}

/// Raw AppKit wheel data from a minimap/scroller interaction view. The app
/// feeds it through its existing ScrollAccumulator and FIFO mouse route.
package struct GridAccessoryWheelRequest: Sendable, Equatable {
    package var gridID: Int
    package var windowHandle: Int
    package var deltaX: CGFloat
    package var deltaY: CGFloat
    package var hasPreciseDeltas: Bool
    package var modifierFlagsRawValue: UInt

    package init(
        gridID: Int, windowHandle: Int,
        deltaX: CGFloat, deltaY: CGFloat,
        hasPreciseDeltas: Bool, modifierFlagsRawValue: UInt
    ) {
        self.gridID = gridID
        self.windowHandle = windowHandle
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.hasPreciseDeltas = hasPreciseDeltas
        self.modifierFlagsRawValue = modifierFlagsRawValue
    }
}

package enum GridAccessoryGutterOwnership: Sendable, Equatable {
    case delegated
    case requesting(cols: Int, rows: Int)
    case owned(cols: Int, rows: Int)
    case releasing
}

package struct GridAccessoryDebugSnapshot {
    package var gridID: Int
    package var windowHandle: Int
    package var ownership: GridAccessoryGutterOwnership
    package var gutterFrame: CGRect?
    package var interactionFrame: CGRect?
    package var displayRange: Range<Int>?
    package var pendingRange: Range<Int>?
    package var minimapImage: CGImage?
    package var acceptedRange: Range<Int>?
    package var accumulatedLineCount: Int
    package var viewportFrame: CGRect?
    package var cursorFrame: CGRect?
    package var scrollerIsVisible: Bool
    package var minimapLayerSuperviewIsGridLayer: Bool
}

// MARK: - Geometry policy

package enum GridAccessoryPolicy {
    package static let desiredGutterWidth: CGFloat = 88
    package static let defaultMinimapScale: CGFloat = 0.20
    package static let defaultMinimapPitch: CGFloat = 3.0
    package static let defaultMinimumEditorColumns = 40
    package static let scrollbarWidth: CGFloat = 12
    /// Matches the Lua provider's hard request bound.
    package static let maximumChunkLines = 384

    package static func wantsMinimap(
        outerWidth: CGFloat, cellWidth: CGFloat, innerRows: Int,
        wasWanted: Bool, gutterWidth: CGFloat = desiredGutterWidth,
        minimumEditorColumns: Int = defaultMinimumEditorColumns
    ) -> Bool {
        guard cellWidth > 0 else { return false }
        let width = max(48, min(160, gutterWidth))
        let showColumns = max(20, min(120, minimumEditorColumns))
        let hideColumns = max(1, showColumns - 4)
        if wasWanted {
            return outerWidth >= width + CGFloat(hideColumns) * cellWidth
                && innerRows >= 10
        }
        return outerWidth >= width + CGFloat(showColumns) * cellWidth
            && innerRows >= 14
    }

    package static func targetGridSize(
        outerCols: Int, outerRows: Int, cellWidth: CGFloat,
        gutterWidth: CGFloat = desiredGutterWidth
    ) -> (cols: Int, rows: Int) {
        let width = max(48, min(160, gutterWidth))
        let gutterCols = max(1, Int(ceil(width / max(1, cellWidth))))
        return (max(1, outerCols - gutterCols), max(1, outerRows))
    }

    package static func linePitch(
        scale: CGFloat, minimapScale: CGFloat = defaultMinimapScale,
        minimapPitch: CGFloat = defaultMinimapPitch
    ) -> CGFloat {
        _ = minimapScale // Glyph scale is intentionally independent of pitch.
        let backingScale = max(1, scale)
        let points = max(1, min(6, minimapPitch))
        return max(1, (points * backingScale).rounded()) / backingScale
    }

    package static func displayRange(
        totalLines: Int, viewportTopline: Int,
        railHeight: CGFloat, scale: CGFloat,
        minimapScale: CGFloat = defaultMinimapScale,
        minimapPitch: CGFloat = defaultMinimapPitch
    ) -> Range<Int> {
        guard totalLines > 0 else { return 0..<0 }
        let capacity = min(maximumChunkLines, max(1, Int(floor(
            railHeight / linePitch(
                scale: scale, minimapScale: minimapScale,
                minimapPitch: minimapPitch)))))
        let count = min(totalLines, capacity)
        let centered = viewportTopline - count / 2
        let start = max(0, min(centered, totalLines - count))
        return start..<(start + count)
    }

    package static func requestedRange(
        totalLines: Int, displayRange: Range<Int>
    ) -> Range<Int> {
        guard totalLines > 0, !displayRange.isEmpty else { return 0..<0 }
        let displayCount = displayRange.count
        let count = min(totalLines, maximumChunkLines, max(
            displayCount, min(maximumChunkLines, displayCount * 3)))
        let desiredStart = displayRange.lowerBound - (count - displayCount) / 2
        let start = max(0, min(desiredStart, totalLines - count))
        return start..<(start + count)
    }

    package static func targetTopline(
        clickedLine: CGFloat, visibleLineCount: Int,
        grabOffsetLines: CGFloat, totalLines: Int
    ) -> Int {
        let visible = max(1, visibleLineCount)
        let maximum = max(0, totalLines - visible)
        return max(0, min(
            maximum, Int(floor(clickedLine - grabOffsetLines))))
    }
}

// MARK: - Native miniature rasterizer

private struct MinimapRenderJob: Sendable {
    var lines: [MinimapLine]
    var width: CGFloat
    var scale: CGFloat
    var minimapScale: CGFloat
    var minimapPitch: CGFloat
    var tabstop: Int
    var editorFontSize: CGFloat
    var backgroundRGB: UInt32
    var defaultForegroundRGB: UInt32
    var fontName: String
}

private final class SendableMinimapImage: @unchecked Sendable {
    let image: CGImage?
    init(_ image: CGImage?) { self.image = image }
}

package enum MinimapRasterizer {
    package static func render(
        lines: [MinimapLine], width: CGFloat, scale: CGFloat,
        backgroundRGB: UInt32, defaultForegroundRGB: UInt32,
        fontName: String = "Menlo",
        minimapScale: CGFloat = GridAccessoryPolicy.defaultMinimapScale,
        minimapPitch: CGFloat = GridAccessoryPolicy.defaultMinimapPitch,
        tabstop: Int = 4, editorFontSize: CGFloat = 13
    ) -> CGImage? {
        render(MinimapRenderJob(
            lines: lines, width: width, scale: scale,
            minimapScale: minimapScale, minimapPitch: minimapPitch,
            tabstop: max(1, tabstop),
            editorFontSize: max(1, editorFontSize),
            backgroundRGB: backgroundRGB,
            defaultForegroundRGB: defaultForegroundRGB,
            fontName: fontName))
    }

    fileprivate static func render(_ job: MinimapRenderJob) -> CGImage? {
        let scale = max(1, job.scale)
        let pitch = GridAccessoryPolicy.linePitch(
            scale: scale, minimapScale: job.minimapScale,
            minimapPitch: job.minimapPitch)
        let width = max(1 / scale, job.width)
        let height = max(pitch, CGFloat(max(1, job.lines.count)) * pitch)
        guard let context = GridRenderer.makeContext(
            width: max(1, Int(ceil(width * scale))),
            height: max(1, Int(ceil(height * scale))), scale: scale)
        else { return nil }

        context.setBlendMode(.copy)
        context.setFillColor(color(job.backgroundRGB))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setBlendMode(.normal)
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setShouldSmoothFonts(false)
        context.clip(to: CGRect(x: 0, y: 0, width: width, height: height))

        // Scale real CoreText glyphs from the active editor face; no viewport
        // bitmap is ever blurred, resized, or reused for the minimap.
        let fontSize = max(
            1, job.editorFontSize * max(0.10, min(0.50, job.minimapScale)))
        let font = CTFontCreateWithName(job.fontName as CFString, fontSize, nil)
        var spaceCharacter: UniChar = 0x20
        var spaceGlyph: CGGlyph = 0
        CTFontGetGlyphsForCharacters(font, &spaceCharacter, &spaceGlyph, 1)
        var spaceAdvance = CGSize.zero
        CTFontGetAdvancesForGlyphs(
            font, .horizontal, &spaceGlyph, &spaceAdvance, 1)
        var tabInterval = max(
            1 / scale, spaceAdvance.width * CGFloat(max(1, job.tabstop)))
        let paragraphStyle = withUnsafePointer(to: &tabInterval) { interval in
            var setting = CTParagraphStyleSetting(
                spec: .defaultTabInterval,
                valueSize: MemoryLayout<CGFloat>.size,
                value: UnsafeRawPointer(interval))
            return CTParagraphStyleCreate(&setting, 1)
        }
        let bold = CTFontCreateCopyWithSymbolicTraits(
            font, fontSize, nil, .boldTrait, .boldTrait) ?? font
        let italic = CTFontCreateCopyWithSymbolicTraits(
            font, fontSize, nil, .italicTrait, .italicTrait) ?? font
        let boldItalic = CTFontCreateCopyWithSymbolicTraits(
            font, fontSize, nil,
            [.boldTrait, .italicTrait], [.boldTrait, .italicTrait]) ?? bold
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let textHeight = ascent + descent

        for (lineIndex, source) in job.lines.enumerated() {
            guard !source.text.isEmpty else { continue }
            let baseline = height - CGFloat(lineIndex) * pitch
                - max(0, (pitch - textHeight) / 2) - ascent
            guard baseline + ascent >= 0, baseline - descent <= height else { continue }

            // Pathological lines are deliberately reduced to two-device-pixel
            // density strokes; ordinary code uses real CoreText glyphs.
            if source.text.utf8.count > 4_096 {
                drawDensityLine(
                    source, baseline: baseline, width: width,
                    scale: scale, context: context,
                    defaultForegroundRGB: job.defaultForegroundRGB)
                continue
            }

            let attributed = NSMutableAttributedString(
                string: source.text,
                attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                        color(job.defaultForegroundRGB),
                    NSAttributedString.Key(kCTParagraphStyleAttributeName as String):
                        paragraphStyle,
                ])
            for span in source.spans {
                guard let range = utf16Range(
                    forUTF8Range: span.byteRange, in: source.text),
                    range.length > 0
                else { continue }
                let spanFont: CTFont
                if span.style.contains([.bold, .italic]) {
                    spanFont = boldItalic
                } else if span.style.contains(.bold) {
                    spanFont = bold
                } else if span.style.contains(.italic) {
                    spanFont = italic
                } else {
                    spanFont = font
                }
                attributed.addAttributes([
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                        color(span.foregroundRGB),
                    NSAttributedString.Key(kCTFontAttributeName as String): spanFont,
                ], range: range)
                if span.style.contains(.underline) {
                    attributed.addAttribute(
                        NSAttributedString.Key(kCTUnderlineStyleAttributeName as String),
                        value: CTUnderlineStyle.single.rawValue, range: range)
                }
            }
            let line = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(x: 0, y: baseline)
            CTLineDraw(line, context)
        }
        return context.makeImage()
    }

    private static func drawDensityLine(
        _ line: MinimapLine, baseline: CGFloat, width: CGFloat,
        scale: CGFloat, context: CGContext, defaultForegroundRGB: UInt32
    ) {
        let byteCount = max(1, line.text.utf8.count)
        let thickness = 2 / scale
        context.setFillColor(color(defaultForegroundRGB))
        context.fill(CGRect(
            x: 0, y: baseline, width: min(width, CGFloat(byteCount) / scale),
            height: thickness))
        for span in line.spans {
            let lower = max(0, min(byteCount, span.byteRange.lowerBound))
            let upper = max(lower, min(byteCount, span.byteRange.upperBound))
            guard upper > lower else { continue }
            context.setFillColor(color(span.foregroundRGB))
            context.fill(CGRect(
                x: CGFloat(lower) / scale, y: baseline,
                width: min(width - CGFloat(lower) / scale,
                           CGFloat(upper - lower) / scale),
                height: thickness))
        }
    }

    private static func utf16Range(
        forUTF8Range range: Range<Int>, in text: String
    ) -> NSRange? {
        let utf8 = text.utf8
        let lowerOffset = max(0, min(utf8.count, range.lowerBound))
        let upperOffset = max(lowerOffset, min(utf8.count, range.upperBound))
        let lowerUTF8 = utf8.index(utf8.startIndex, offsetBy: lowerOffset)
        let upperUTF8 = utf8.index(utf8.startIndex, offsetBy: upperOffset)
        guard let lower = String.Index(lowerUTF8, within: text),
            let upper = String.Index(upperUTF8, within: text)
        else { return nil }
        return NSRange(lower..<upper, in: text)
    }

    private static func color(_ rgb: UInt32) -> CGColor {
        NvimKit.RGBColor(rgb: rgb & 0x00FF_FFFF).cgColor
    }
}

// MARK: - Interaction views

@MainActor
private final class GridAccessoryScroller: NSScroller {
    var onTargetValue: ((Double, GridAccessoryGesturePhase) -> Void)?
    var onWheel: ((NSEvent) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self
        action = #selector(valueChanged(_:))
        controlSize = .small
        scrollerStyle = .overlay
        knobStyle = .default
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var acceptsFirstResponder: Bool { false }

    override func mouseDown(with event: NSEvent) {
        onTargetValue?(Double(doubleValue), .began)
        super.mouseDown(with: event)
        onTargetValue?(Double(doubleValue), .ended)
    }

    override func scrollWheel(with event: NSEvent) {
        onWheel?(event)
    }

    @objc private func valueChanged(_ sender: NSScroller) {
        onTargetValue?(Double(sender.doubleValue), .changed)
    }
}

@MainActor
private final class GridAccessoryInteractionView: NSView {
    let gridID: Int
    let scroller = GridAccessoryScroller(frame: .zero)
    var minimapIsInteractive = false
    var onMinimapPoint: ((CGFloat, GridAccessoryGesturePhase) -> Void)?
    var onWheel: ((NSEvent) -> Void)?
    var isTopmostAtSurfacePoint: ((NSPoint) -> Bool)?

    init(gridID: Int) {
        self.gridID = gridID
        super.init(frame: .zero)
        wantsLayer = false
        addSubview(scroller)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, bounds.contains(point) else { return nil }
        if let superview {
            let surfacePoint = convert(point, to: superview)
            guard isTopmostAtSurfacePoint?(surfacePoint) != false else { return nil }
        }
        if !scroller.isHidden, scroller.frame.contains(point) {
            return scroller.hitTest(convert(point, to: scroller))
        }
        return minimapIsInteractive ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        onMinimapPoint?(convert(event.locationInWindow, from: nil).y, .began)
    }

    override func mouseDragged(with event: NSEvent) {
        onMinimapPoint?(convert(event.locationInWindow, from: nil).y, .changed)
    }

    override func mouseUp(with event: NSEvent) {
        onMinimapPoint?(convert(event.locationInWindow, from: nil).y, .ended)
    }

    override func scrollWheel(with event: NSEvent) {
        onWheel?(event)
    }
}

// MARK: - Per-grid state

private struct MinimapAcceptedChunk {
    var payload: MinimapContentChunk
    var renderWidth: CGFloat = 0
    var renderScale: CGFloat = 0
    var minimapScale: CGFloat = 0
    var minimapPitch: CGFloat = 0
    var tabstop = 0
    var editorFontSize: CGFloat = 0
    var backgroundRGB: UInt32 = 0
    var foregroundRGB: UInt32 = 0
    var fontName: String = ""
}

@MainActor
private final class GridEditorAccessoryState {
    let gridID: Int
    var windowHandle: Int
    var ownership: GridAccessoryGutterOwnership = .delegated
    var wantsGutter = false
    var requestedSize: GridAccessorySizeRequest?
    var dispatchedSize: GridAccessorySizeRequest?
    var topology: MinimapBufferTopology?
    var pendingContentRequest: MinimapContentRangeRequest?
    var dispatchedContentRequestID: UInt64?
    var accumulatedRequestID: UInt64?
    var accumulatedLines: [Int: MinimapLine] = [:]
    var acceptedChunk: MinimapAcceptedChunk?
    var displayRange: Range<Int>?
    var latestViewport: Viewport?
    var latestResidual: CGFloat = 0
    var minimapGrabOffsetLines: CGFloat?
    var gutterFrameInGrid: CGRect?
    var interactionFrameInSurface: CGRect?
    var mapWidth: CGFloat = 0
    var scale: CGFloat = 1
    var minimapScale: CGFloat = GridAccessoryPolicy.defaultMinimapScale
    var minimapPitch: CGFloat = GridAccessoryPolicy.defaultMinimapPitch
    var editorFontSize: CGFloat = 13
    var fontName = "Menlo"
    var backgroundRGB: UInt32 = 0
    var foregroundRGB: UInt32 = 0xFFFFFF
    var renderSerial: UInt64 = 0
    var renderTask: Task<Void, Never>?
    var renderedImage: CGImage?

    let minimapLayer = CALayer()
    let contentLayer = CALayer()
    let viewportLayer = CALayer()
    let cursorLayer = CALayer()
    let interactionView: GridAccessoryInteractionView
    weak var presentationGridLayer: CALayer?

    var onViewportTarget: ((GridAccessoryViewportTargetRequest) -> Void)?
    var onWheel: ((GridAccessoryWheelRequest) -> Void)?

    init(gridID: Int, windowHandle: Int) {
        self.gridID = gridID
        self.windowHandle = windowHandle
        interactionView = GridAccessoryInteractionView(gridID: gridID)

        for layer in [minimapLayer, contentLayer, viewportLayer, cursorLayer] {
            layer.actions = [
                "position": NSNull(), "bounds": NSNull(), "frame": NSNull(),
                "contents": NSNull(), "opacity": NSNull(), "hidden": NSNull(),
                "backgroundColor": NSNull(), "borderColor": NSNull(),
                "borderWidth": NSNull(),
            ]
        }
        minimapLayer.isOpaque = true
        minimapLayer.masksToBounds = true
        minimapLayer.zPosition = 80
        contentLayer.contentsGravity = .resize
        contentLayer.zPosition = 0
        viewportLayer.zPosition = 1
        viewportLayer.backgroundColor = CGColor(
            srgbRed: 1, green: 1, blue: 1, alpha: 0.09)
        viewportLayer.borderColor = CGColor(
            srgbRed: 1, green: 1, blue: 1, alpha: 0.22)
        cursorLayer.zPosition = 2
        cursorLayer.backgroundColor = CGColor(
            srgbRed: 1, green: 1, blue: 1, alpha: 0.72)
        minimapLayer.addSublayer(contentLayer)
        minimapLayer.addSublayer(viewportLayer)
        minimapLayer.addSublayer(cursorLayer)

        interactionView.onMinimapPoint = { [weak self] y, phase in
            self?.emitMinimapTarget(at: y, phase: phase)
        }
        interactionView.onWheel = { [weak self] event in
            self?.emitWheel(event)
        }
        interactionView.scroller.onTargetValue = { [weak self] value, phase in
            self?.emitScrollerTarget(value: value, phase: phase)
        }
        interactionView.scroller.onWheel = { [weak self] event in
            self?.emitWheel(event)
        }
    }

    deinit { renderTask?.cancel() }

    func destroy() {
        renderTask?.cancel()
        renderTask = nil
        minimapLayer.removeFromSuperlayer()
        interactionView.removeFromSuperview()
        acceptedChunk = nil
        renderedImage = nil
        pendingContentRequest = nil
        dispatchedContentRequestID = nil
        accumulatedRequestID = nil
        accumulatedLines.removeAll()
    }

    func hidePresentation() {
        minimapLayer.isHidden = true
        interactionView.isHidden = true
        gutterFrameInGrid = nil
        interactionFrameInSurface = nil
    }

    func configurePresentation(
        gridLayer: CALayer, hostView: NSView,
        gutterFrame: CGRect?, scrollerFrame: CGRect?,
        minimapVisible: Bool, scrollerVisible: Bool,
        backgroundRGB: UInt32, foregroundRGB: UInt32,
        scale: CGFloat, fontName: String, minimapScale: CGFloat,
        minimapPitch: CGFloat, editorFontSize: CGFloat
    ) {
        self.scale = max(1, scale)
        self.minimapScale = max(0.10, min(0.50, minimapScale))
        self.minimapPitch = max(1, min(6, minimapPitch))
        self.editorFontSize = max(1, editorFontSize)
        self.fontName = fontName
        self.backgroundRGB = backgroundRGB
        self.foregroundRGB = foregroundRGB

        if minimapVisible, let gutterFrame {
            presentationGridLayer = gridLayer
            gutterFrameInGrid = gutterFrame
            if minimapLayer.superlayer !== gridLayer {
                minimapLayer.removeFromSuperlayer()
                gridLayer.addSublayer(minimapLayer)
            }
            minimapLayer.frame = gutterFrame
            minimapLayer.backgroundColor = NvimKit.RGBColor(
                rgb: backgroundRGB).cgColor
            minimapLayer.isHidden = false
            viewportLayer.borderWidth = 1 / self.scale
            cursorLayer.bounds.size.height = 1 / self.scale
        } else {
            minimapLayer.isHidden = true
            gutterFrameInGrid = nil
        }

        let surfaceFrame: CGRect?
        if minimapVisible, let gutterFrame {
            surfaceFrame = gutterFrame.offsetBy(
                dx: gridLayer.frame.minX, dy: gridLayer.frame.minY)
        } else {
            surfaceFrame = scrollerFrame
        }

        guard let surfaceFrame, minimapVisible || scrollerVisible else {
            interactionView.isHidden = true
            interactionFrameInSurface = nil
            return
        }
        interactionFrameInSurface = surfaceFrame
        if interactionView.superview !== hostView {
            interactionView.removeFromSuperview()
            hostView.addSubview(interactionView)
        }
        interactionView.frame = surfaceFrame
        interactionView.isHidden = false
        interactionView.minimapIsInteractive = minimapVisible
        let scrollerWidth = min(
            GridAccessoryPolicy.scrollbarWidth,
            max(0, interactionView.bounds.width))
        interactionView.scroller.frame = CGRect(
            x: max(0, interactionView.bounds.width - scrollerWidth), y: 0,
            width: scrollerWidth, height: interactionView.bounds.height)
        interactionView.scroller.isHidden = !scrollerVisible
        mapWidth = minimapVisible
            ? max(0, interactionView.bounds.width - (scrollerVisible ? scrollerWidth : 0))
            : 0
        updateScroller()
        updateMotionLayers()
    }

    func applyTopology(_ next: MinimapBufferTopology?) {
        guard topology != next else { return }
        topology = next
        pendingContentRequest = nil
        dispatchedContentRequestID = nil
        accumulatedRequestID = nil
        accumulatedLines.removeAll()
        acceptedChunk = nil
        displayRange = nil
        contentLayer.contents = nil
        renderedImage = nil
        renderTask?.cancel()
        renderTask = nil
        renderSerial &+= 1
    }

    func accept(_ chunk: MinimapContentChunk) -> Bool {
        guard let pendingContentRequest,
            pendingContentRequest.requestID == chunk.requestID,
            pendingContentRequest.gridID == chunk.gridID,
            pendingContentRequest.topology == chunk.topology,
            topology == chunk.topology,
            chunk.gridID == gridID
        else { return false }
        if accumulatedRequestID != chunk.requestID {
            accumulatedRequestID = chunk.requestID
            accumulatedLines.removeAll(keepingCapacity: true)
        }
        for (offset, line) in chunk.lines.enumerated() {
            let lineNumber = chunk.firstLine + offset
            guard lineNumber < chunk.lastLine,
                pendingContentRequest.lineRange.contains(lineNumber)
            else { continue }
            accumulatedLines[lineNumber] = line
        }
        let published = publishAccumulatedContentIfReady(
            allowIncompleteCoverage: chunk.complete)
        if chunk.complete {
            self.pendingContentRequest = nil
            dispatchedContentRequestID = nil
            accumulatedRequestID = nil
        }
        return published
    }

    func beginContentRequest(_ request: MinimapContentRangeRequest) {
        guard pendingContentRequest?.requestID != request.requestID else { return }
        pendingContentRequest = request
        dispatchedContentRequestID = nil
        accumulatedRequestID = request.requestID
        accumulatedLines.removeAll(keepingCapacity: true)
    }

    /// Chunks are accumulated until the currently visible range is complete,
    /// or until the provider explicitly marks the request complete. This
    /// prevents a first 16-line response from replacing a larger minimap with
    /// a partial image while retaining progressive publication.
    @discardableResult
    func publishAccumulatedContentIfReady(
        allowIncompleteCoverage: Bool = false
    ) -> Bool {
        guard let request = pendingContentRequest,
            accumulatedRequestID == request.requestID
        else { return false }
        let visibleLower = displayRange.map {
            max($0.lowerBound, request.lineRange.lowerBound)
        } ?? request.lineRange.lowerBound
        let visibleUpper = displayRange.map {
            min($0.upperBound, request.lineRange.upperBound)
        } ?? request.lineRange.upperBound
        guard visibleLower < visibleUpper else { return false }
        let visible = visibleLower..<visibleUpper
        let covered = visible.allSatisfy { accumulatedLines[$0] != nil }
        guard covered || allowIncompleteCoverage else { return false }
        var lower = allowIncompleteCoverage
            ? request.lineRange.lowerBound : visible.lowerBound
        var upper = allowIncompleteCoverage
            ? request.lineRange.upperBound : visible.upperBound
        if !allowIncompleteCoverage {
            while lower > request.lineRange.lowerBound,
                accumulatedLines[lower - 1] != nil
            { lower -= 1 }
            while upper < request.lineRange.upperBound,
                accumulatedLines[upper] != nil
            { upper += 1 }
        }
        let publishedRange = lower..<upper
        let lines = publishedRange.map {
            accumulatedLines[$0] ?? MinimapLine(text: "")
        }
        acceptedChunk = MinimapAcceptedChunk(payload: MinimapContentChunk(
            requestID: request.requestID, gridID: request.gridID,
            topology: request.topology, firstLine: publishedRange.lowerBound,
            lastLine: publishedRange.upperBound,
            complete: allowIncompleteCoverage,
            lines: lines))
        return true
    }

    func requestRenderIfNeeded(
        install: @escaping @MainActor (Int, UInt64, CGImage?) -> Void
    ) {
        guard mapWidth > 0, var acceptedChunk else { return }
        let alreadyMatches = acceptedChunk.renderWidth == mapWidth
            && acceptedChunk.renderScale == scale
            && acceptedChunk.minimapScale == minimapScale
            && acceptedChunk.minimapPitch == minimapPitch
            && acceptedChunk.tabstop == acceptedChunk.payload.topology.tabstop
            && acceptedChunk.editorFontSize == editorFontSize
            && acceptedChunk.backgroundRGB == backgroundRGB
            && acceptedChunk.foregroundRGB == foregroundRGB
            && acceptedChunk.fontName == fontName
            && contentLayer.contents != nil
        guard !alreadyMatches else {
            positionContentLayer()
            return
        }
        acceptedChunk.renderWidth = mapWidth
        acceptedChunk.renderScale = scale
        acceptedChunk.minimapScale = minimapScale
        acceptedChunk.minimapPitch = minimapPitch
        acceptedChunk.tabstop = acceptedChunk.payload.topology.tabstop
        acceptedChunk.editorFontSize = editorFontSize
        acceptedChunk.backgroundRGB = backgroundRGB
        acceptedChunk.foregroundRGB = foregroundRGB
        acceptedChunk.fontName = fontName
        self.acceptedChunk = acceptedChunk

        renderTask?.cancel()
        renderSerial &+= 1
        let serial = renderSerial
        let job = MinimapRenderJob(
            lines: acceptedChunk.payload.lines,
            width: mapWidth, scale: scale, minimapScale: minimapScale,
            minimapPitch: minimapPitch,
            tabstop: acceptedChunk.payload.topology.tabstop,
            editorFontSize: editorFontSize,
            backgroundRGB: backgroundRGB,
            defaultForegroundRGB: foregroundRGB,
            fontName: fontName)
        renderTask = Task.detached(priority: .utility) {
            let image = SendableMinimapImage(MinimapRasterizer.render(job))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                install(self.gridID, serial, image.image)
            }
        }
    }

    func installRenderedImage(_ image: CGImage?, serial: UInt64) {
        guard serial == renderSerial, let image else { return }
        renderedImage = image
        contentLayer.contents = image
        contentLayer.contentsScale = scale
        positionContentLayer()
    }

    func positionContentLayer() {
        guard let acceptedChunk, let displayRange else { return }
        let pitch = GridAccessoryPolicy.linePitch(
            scale: scale, minimapScale: minimapScale,
            minimapPitch: minimapPitch)
        let y = -CGFloat(displayRange.lowerBound - acceptedChunk.payload.startLine) * pitch
        contentLayer.frame = CGRect(
            x: 0, y: y, width: mapWidth,
            height: CGFloat(max(1, acceptedChunk.payload.lines.count)) * pitch)
    }

    func updateMotionLayers() {
        guard !minimapLayer.isHidden, let displayRange, let viewport = latestViewport else {
            viewportLayer.isHidden = true
            cursorLayer.isHidden = true
            return
        }
        let pitch = GridAccessoryPolicy.linePitch(
            scale: scale, minimapScale: minimapScale,
            minimapPitch: minimapPitch)
        let visualTop = CGFloat(viewport.topline) + latestResidual
        let y = (visualTop - CGFloat(displayRange.lowerBound)) * pitch
        let visibleLines = max(1, min(viewport.lineCount, viewport.botline)
            - min(viewport.lineCount, viewport.topline))
        viewportLayer.frame = CGRect(
            x: 0, y: y, width: mapWidth,
            height: max(2 / scale, CGFloat(visibleLines) * pitch))
        viewportLayer.isHidden = false

        let cursorY = (CGFloat(viewport.curline) + latestResidual
            - CGFloat(displayRange.lowerBound)) * pitch
        cursorLayer.frame = CGRect(
            x: 0, y: cursorY, width: mapWidth, height: 1 / scale)
        cursorLayer.isHidden = cursorY < 0 || cursorY > minimapLayer.bounds.height
    }

    func updateScroller() {
        guard let viewport = latestViewport, viewport.lineCount > 0 else {
            interactionView.scroller.doubleValue = 0
            interactionView.scroller.knobProportion = 1
            interactionView.scroller.isEnabled = false
            return
        }
        let clampedTop = max(0, min(viewport.lineCount, viewport.topline))
        let clampedBottom = max(clampedTop, min(viewport.lineCount, viewport.botline))
        let visible = max(1, clampedBottom - clampedTop)
        let maximum = max(0, viewport.lineCount - visible)
        interactionView.scroller.knobProportion = min(
            1, CGFloat(visible) / CGFloat(max(1, viewport.lineCount)))
        interactionView.scroller.doubleValue = maximum == 0
            ? 0 : Double(clampedTop) / Double(maximum)
        interactionView.scroller.isEnabled = maximum > 0
    }

    private func emitMinimapTarget(
        at y: CGFloat, phase: GridAccessoryGesturePhase
    ) {
        guard let displayRange, !displayRange.isEmpty, mapWidth > 0,
            interactionView.bounds.width > 0,
            y >= 0, y <= interactionView.bounds.height
        else { return }
        // The trailing scroller owns its own hit area.
        if !interactionView.scroller.isHidden,
            y >= interactionView.scroller.frame.minY,
            interactionView.scroller.frame.width == interactionView.bounds.width
        { return }
        let pitch = GridAccessoryPolicy.linePitch(
            scale: scale, minimapScale: minimapScale,
            minimapPitch: minimapPitch)
        let visibleLines = CGFloat(visibleViewportLineCount)
        if phase == .began {
            if !viewportLayer.isHidden,
                y >= viewportLayer.frame.minY, y <= viewportLayer.frame.maxY
            {
                minimapGrabOffsetLines = max(
                    0, (y - viewportLayer.frame.minY) / max(1 / scale, pitch))
            } else {
                minimapGrabOffsetLines = visibleLines / 2
            }
        }
        let grabOffset = minimapGrabOffsetLines ?? visibleLines / 2
        let clickedLine = CGFloat(displayRange.lowerBound)
            + y / max(1 / scale, pitch)
        let total = topology?.totalLineCount ?? latestViewport?.lineCount ?? 0
        let target = GridAccessoryPolicy.targetTopline(
            clickedLine: clickedLine,
            visibleLineCount: visibleViewportLineCount,
            grabOffsetLines: grabOffset, totalLines: total)
        onViewportTarget?(GridAccessoryViewportTargetRequest(
            gridID: gridID, windowHandle: windowHandle,
            bufferHandle: topology?.bufferHandle,
            targetTopline: target, phase: phase))
        if phase == .ended { minimapGrabOffsetLines = nil }
    }

    private func emitScrollerTarget(
        value: Double, phase: GridAccessoryGesturePhase
    ) {
        guard let viewport else { return }
        let clampedTop = max(0, min(viewport.lineCount, viewport.topline))
        let clampedBottom = max(clampedTop, min(viewport.lineCount, viewport.botline))
        let visible = max(1, clampedBottom - clampedTop)
        let maximum = max(0, viewport.lineCount - visible)
        let target = Int((max(0, min(1, value)) * Double(maximum)).rounded())
        onViewportTarget?(GridAccessoryViewportTargetRequest(
            gridID: gridID, windowHandle: windowHandle,
            bufferHandle: topology?.bufferHandle,
            targetTopline: target, phase: phase))
    }

    private var viewport: Viewport? { latestViewport }

    private var visibleViewportLineCount: Int {
        guard let viewport else { return 1 }
        let top = max(0, min(viewport.lineCount, viewport.topline))
        let bottom = max(top, min(viewport.lineCount, viewport.botline))
        return max(1, bottom - top)
    }

    private func emitWheel(_ event: NSEvent) {
        onWheel?(GridAccessoryWheelRequest(
            gridID: gridID, windowHandle: windowHandle,
            deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
            hasPreciseDeltas: event.hasPreciseScrollingDeltas,
            modifierFlagsRawValue: event.modifierFlags.rawValue))
    }
}

// MARK: - Coordinator

@MainActor
final class GridAccessoryCoordinator {
    weak var hostView: GridSurfaceView?

    var onContentRangeRequest: ((MinimapContentRangeRequest) -> Void)? {
        didSet { retryContentRequests() }
    }
    var onGridSizeRequest: ((GridAccessorySizeRequest) -> Void)? {
        didSet { retrySizeRequests() }
    }
    var onViewportTargetRequest: ((GridAccessoryViewportTargetRequest) -> Void)?
    var onWheelRequest: ((GridAccessoryWheelRequest) -> Void)?

    private var states: [Int: GridEditorAccessoryState] = [:]
    private var topologies: [Int: MinimapBufferTopology] = [:]
    private var lastFrames: [ResolvedGridFrame] = []
    private var lastCellSize: CGSize = .zero
    private var nextContentRequestID: UInt64 = 1

    init(hostView: GridSurfaceView) {
        self.hostView = hostView
    }

    func setTopologies(_ values: [MinimapBufferTopology]) {
        topologies = Dictionary(
            values.map { ($0.windowHandle, $0) },
            uniquingKeysWith: { _, newest in newest })
        for state in states.values {
            state.applyTopology(topologies[state.windowHandle])
            if state.topology == nil {
                releaseForMissingTopology(state)
            } else {
                refreshContent(for: state)
            }
        }
    }

    func updateTopology(_ topology: MinimapBufferTopology) {
        topologies[topology.windowHandle] = topology
        for state in states.values where state.windowHandle == topology.windowHandle {
            state.applyTopology(topology)
            refreshContent(for: state)
        }
    }

    func removeTopology(windowHandle: Int) {
        topologies.removeValue(forKey: windowHandle)
        for state in states.values where state.windowHandle == windowHandle {
            state.applyTopology(nil)
            releaseForMissingTopology(state)
        }
    }

    func provide(_ chunk: MinimapContentChunk) {
        guard let state = states[chunk.gridID], state.accept(chunk) else { return }
        state.requestRenderIfNeeded(install: installRenderedImage)
    }

    func sync(
        flush: FlushResult, frames: [ResolvedGridFrame],
        gridLayers: [Int: CALayer], residuals: [Int: CGFloat],
        cellSize: CGSize, scale: CGFloat, fontName: String,
        editorFontSize: CGFloat,
        showsMinimap: Bool, showsScrollbars: Bool,
        minimapWidth: CGFloat, minimapScale: CGFloat,
        minimapPitch: CGFloat, minimapMinEditorColumns: Int
    ) {
        guard let hostView else { return }
        lastFrames = frames
        lastCellSize = cellSize
        let defaultBackground = flush.highlights.defaultBackground.rgb
        let defaultForeground = flush.highlights.defaultForeground.rgb
        var retained: Set<Int> = []

        for frame in frames {
            guard let grid = flush.grids[frame.gridID],
                grid.windowFrame != nil,
                let windowHandle = grid.windowHandle,
                let viewport = grid.viewport,
                let gridLayer = gridLayers[frame.gridID]
            else { continue }
            retained.insert(frame.gridID)

            let state: GridEditorAccessoryState
            if let existing = states[frame.gridID],
                existing.windowHandle == windowHandle
            {
                state = existing
            } else {
                states[frame.gridID]?.destroy()
                state = GridEditorAccessoryState(
                    gridID: frame.gridID, windowHandle: windowHandle)
                states[frame.gridID] = state
                state.interactionView.isTopmostAtSurfacePoint = { [weak self] point in
                    self?.isTopmost(gridID: frame.gridID, at: point) ?? false
                }
            }
            state.onViewportTarget = { [weak self] request in
                self?.onViewportTargetRequest?(request)
            }
            state.onWheel = { [weak self] request in
                self?.onWheelRequest?(request)
            }
            state.latestViewport = viewport
            state.latestResidual = residuals[frame.gridID] ?? 0
            state.applyTopology(topologies[windowHandle])

            let margins = grid.viewportMargins ?? ViewportMargins(
                top: 0, bottom: 0, left: 0, right: 0)
            let sampleRow = min(max(0, margins.top), max(0, grid.rows - 1))
            let sampleCol = min(
                max(0, grid.cols - max(0, margins.right) - 1),
                max(0, grid.cols - 1))
            let windowColors: (background: UInt32, foreground: UInt32)
            if grid.rows > 0, grid.cols > 0 {
                let attrs = flush.highlights.resolved(
                    id: grid[sampleRow, sampleCol].hlID)
                windowColors = (attrs.background.rgb, attrs.foreground.rgb)
            } else {
                windowColors = (defaultBackground, defaultForeground)
            }
            let outerWidth = CGFloat(frame.rect.width) * cellSize.width
            let innerRows = max(
                0,
                min(frame.rect.height, grid.rows) - margins.top - margins.bottom)
            let wants = showsMinimap && state.topology != nil
                && GridAccessoryPolicy.wantsMinimap(
                outerWidth: outerWidth, cellWidth: cellSize.width,
                innerRows: innerRows, wasWanted: state.wantsGutter,
                gutterWidth: minimapWidth,
                minimumEditorColumns: minimapMinEditorColumns)
            state.wantsGutter = wants

            let target = GridAccessoryPolicy.targetGridSize(
                outerCols: frame.rect.width, outerRows: frame.rect.height,
                cellWidth: cellSize.width, gutterWidth: minimapWidth)
            var minimapVisible = false
            if wants {
                let request = GridAccessorySizeRequest(
                    gridID: frame.gridID, windowHandle: windowHandle,
                    cols: target.cols, rows: target.rows)
                if state.requestedSize != request {
                    state.requestedSize = request
                    state.dispatchedSize = nil
                    state.ownership = .requesting(
                        cols: target.cols, rows: target.rows)
                }
                dispatchSizeRequestIfNeeded(for: state)
                if state.dispatchedSize == request,
                    grid.cols == target.cols, grid.rows == target.rows
                {
                    state.ownership = .owned(cols: target.cols, rows: target.rows)
                    minimapVisible = true
                } else {
                    state.ownership = .requesting(cols: target.cols, rows: target.rows)
                }
            } else {
                if state.ownership != .delegated, state.ownership != .releasing {
                    state.requestedSize = GridAccessorySizeRequest(
                        gridID: frame.gridID, windowHandle: windowHandle,
                        cols: 0, rows: 0)
                    state.dispatchedSize = nil
                    state.ownership = .releasing
                }
                dispatchSizeRequestIfNeeded(for: state)
                if state.ownership == .releasing,
                    grid.cols == frame.rect.width, grid.rows == frame.rect.height
                {
                    state.ownership = .delegated
                    state.requestedSize = nil
                    state.dispatchedSize = nil
                }
            }

            let clampedTop = max(0, min(viewport.lineCount, viewport.topline))
            let clampedBottom = max(
                clampedTop, min(viewport.lineCount, viewport.botline))
            let scrollerEligible = showsScrollbars
                && viewport.lineCount > max(1, clampedBottom - clampedTop)

            let localGutter: CGRect?
            let scrollerSurfaceFrame: CGRect?
            if minimapVisible {
                let contentWidth = CGFloat(grid.cols) * cellSize.width
                let width = max(0, outerWidth - contentWidth)
                localGutter = CGRect(
                    x: contentWidth,
                    y: CGFloat(margins.top) * cellSize.height,
                    width: width,
                    height: CGFloat(innerRows) * cellSize.height)
                scrollerSurfaceFrame = nil
            } else {
                localGutter = nil
                let gridFrame = gridLayer.frame
                scrollerSurfaceFrame = scrollerEligible ? CGRect(
                    x: gridFrame.maxX - GridAccessoryPolicy.scrollbarWidth,
                    y: gridFrame.minY + CGFloat(margins.top) * cellSize.height,
                    width: GridAccessoryPolicy.scrollbarWidth,
                    height: CGFloat(innerRows) * cellSize.height) : nil
            }

            state.configurePresentation(
                gridLayer: gridLayer, hostView: hostView,
                gutterFrame: localGutter,
                scrollerFrame: scrollerSurfaceFrame,
                minimapVisible: minimapVisible,
                scrollerVisible: scrollerEligible,
                backgroundRGB: windowColors.background,
                foregroundRGB: windowColors.foreground,
                scale: scale, fontName: fontName,
                minimapScale: minimapScale, minimapPitch: minimapPitch,
                editorFontSize: editorFontSize)
            refreshContent(for: state)
        }

        // Hidden grids keep Neovim storage but not native interaction views.
        // Release an owned normal grid while its handle is still valid; closed
        // or destroyed grids are simply forgotten.
        for gridID in Array(states.keys) where !retained.contains(gridID) {
            guard let state = states.removeValue(forKey: gridID) else { continue }
            if let grid = flush.grids[gridID], grid.windowHandle == state.windowHandle,
                state.ownership != .delegated
            {
                onGridSizeRequest?(GridAccessorySizeRequest(
                    gridID: gridID, windowHandle: state.windowHandle,
                    cols: 0, rows: 0))
            }
            state.destroy()
        }
    }

    func updateResiduals(_ residuals: [Int: CGFloat]) {
        for (gridID, state) in states {
            state.latestResidual = residuals[gridID] ?? 0
            state.updateMotionLayers()
        }
    }

    func retryAllRequests() {
        retrySizeRequests()
        retryContentRequests()
    }

    func interactionView(at point: NSPoint) -> NSView? {
        guard let hostView, let top = topmostGrid(at: point),
            let state = states[top.gridID],
            state.interactionView.superview != nil
        else { return nil }
        let pointInInteraction = state.interactionView.convert(point, from: hostView)
        return state.interactionView.hitTest(pointInInteraction)
    }

    func containsAcknowledgedGutter(gridID: Int, point: NSPoint) -> Bool {
        guard let state = states[gridID],
            case .owned = state.ownership,
            let frame = state.interactionFrameInSurface,
            state.gutterFrameInGrid != nil
        else { return false }
        return frame.contains(point)
    }

    func debugSnapshot(gridID: Int) -> GridAccessoryDebugSnapshot? {
        guard let state = states[gridID] else { return nil }
        return GridAccessoryDebugSnapshot(
            gridID: gridID, windowHandle: state.windowHandle,
            ownership: state.ownership,
            gutterFrame: state.gutterFrameInGrid,
            interactionFrame: state.interactionFrameInSurface,
            displayRange: state.displayRange,
            pendingRange: state.pendingContentRequest?.lineRange,
            minimapImage: state.renderedImage,
            acceptedRange: state.acceptedChunk?.payload.lineRange,
            accumulatedLineCount: state.accumulatedLines.count,
            viewportFrame: state.viewportLayer.isHidden ? nil : state.viewportLayer.frame,
            cursorFrame: state.cursorLayer.isHidden ? nil : state.cursorLayer.frame,
            scrollerIsVisible: !state.interactionView.scroller.isHidden,
            minimapLayerSuperviewIsGridLayer:
                state.minimapLayer.superlayer === state.presentationGridLayer)
    }

    func scroller(gridID: Int) -> NSScroller? {
        states[gridID]?.interactionView.scroller
    }

    private func refreshContent(for state: GridEditorAccessoryState) {
        guard !state.minimapLayer.isHidden, state.minimapLayer.bounds.height > 0,
            let viewport = state.latestViewport
        else { return }
        let total = state.topology?.totalLineCount ?? viewport.lineCount
        let centeredDisplay = GridAccessoryPolicy.displayRange(
            totalLines: total, viewportTopline: viewport.topline,
            railHeight: state.minimapLayer.bounds.height, scale: state.scale,
            minimapScale: state.minimapScale,
            minimapPitch: state.minimapPitch)
        // Keep the semantic window fixed while the authoritative viewport is
        // represented. Once it reaches an edge, shift only by the minimum
        // lines needed to retain it; never re-center by half a rail.
        let display: Range<Int>
        if let existing = state.displayRange,
            existing.count == centeredDisplay.count,
            existing.lowerBound >= 0, existing.upperBound <= total
        {
            var lower = existing.lowerBound
            if viewport.topline < existing.lowerBound {
                lower = viewport.topline
            } else if viewport.botline > existing.upperBound {
                lower += viewport.botline - existing.upperBound
            }
            lower = max(0, min(lower, total - existing.count))
            display = lower..<(lower + existing.count)
        } else {
            display = centeredDisplay
        }
        state.displayRange = display
        state.positionContentLayer()
        state.updateMotionLayers()

        if state.publishAccumulatedContentIfReady() {
            state.requestRenderIfNeeded(install: installRenderedImage)
        }

        guard let topology = state.topology, total > 0 else { return }
        if let accepted = state.acceptedChunk,
            accepted.payload.topology == topology,
            accepted.payload.lineRange.lowerBound <= display.lowerBound,
            accepted.payload.lineRange.upperBound >= display.upperBound
        {
            state.requestRenderIfNeeded(install: installRenderedImage)
            let safety = max(1, min(64, display.count / 3))
            let hasLeadingRoom = accepted.payload.lineRange.lowerBound == 0
                || display.lowerBound - accepted.payload.lineRange.lowerBound >= safety
            let hasTrailingRoom = accepted.payload.lineRange.upperBound == total
                || accepted.payload.lineRange.upperBound - display.upperBound >= safety
            if state.pendingContentRequest != nil
                || (hasLeadingRoom && hasTrailingRoom)
            { return }
        }

        let range = GridAccessoryPolicy.requestedRange(
            totalLines: total, displayRange: display)
        guard !range.isEmpty else { return }
        if state.pendingContentRequest?.topology != topology
            || state.pendingContentRequest?.lineRange != range
        {
            let request = MinimapContentRangeRequest(
                requestID: nextContentRequestID, gridID: state.gridID,
                topology: topology, lineRange: range)
            nextContentRequestID &+= 1
            state.beginContentRequest(request)
        }
        dispatchContentRequestIfNeeded(for: state)
    }

    private func installRenderedImage(
        gridID: Int, serial: UInt64, image: CGImage?
    ) {
        states[gridID]?.installRenderedImage(image, serial: serial)
    }

    private func dispatchSizeRequestIfNeeded(for state: GridEditorAccessoryState) {
        guard let request = state.requestedSize,
            state.dispatchedSize != request,
            let onGridSizeRequest
        else { return }
        state.dispatchedSize = request
        onGridSizeRequest(request)
    }

    private func dispatchContentRequestIfNeeded(for state: GridEditorAccessoryState) {
        guard let request = state.pendingContentRequest,
            state.dispatchedContentRequestID != request.requestID,
            let onContentRangeRequest
        else { return }
        state.dispatchedContentRequestID = request.requestID
        onContentRangeRequest(request)
    }

    private func retrySizeRequests() {
        for state in states.values { dispatchSizeRequestIfNeeded(for: state) }
    }

    private func retryContentRequests() {
        for state in states.values { dispatchContentRequestIfNeeded(for: state) }
    }

    private func releaseForMissingTopology(_ state: GridEditorAccessoryState) {
        state.wantsGutter = false
        state.hidePresentation()
        guard state.ownership != .delegated, state.ownership != .releasing else {
            return
        }
        state.requestedSize = GridAccessorySizeRequest(
            gridID: state.gridID, windowHandle: state.windowHandle,
            cols: 0, rows: 0)
        state.dispatchedSize = nil
        state.ownership = .releasing
        dispatchSizeRequestIfNeeded(for: state)
    }

    private func isTopmost(gridID: Int, at point: NSPoint) -> Bool {
        topmostGrid(at: point)?.gridID == gridID
    }

    private func topmostGrid(at point: NSPoint) -> ResolvedGridFrame? {
        guard lastCellSize.width > 0, lastCellSize.height > 0 else { return nil }
        return lastFrames.reversed().first { frame in
            CGRect(
                x: CGFloat(frame.rect.col) * lastCellSize.width,
                y: CGFloat(frame.rect.row) * lastCellSize.height,
                width: CGFloat(frame.rect.width) * lastCellSize.width,
                height: CGFloat(frame.rect.height) * lastCellSize.height
            ).contains(point)
        }
    }
}
