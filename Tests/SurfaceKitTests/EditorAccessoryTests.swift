import AppKit
import GridKit
import NvimKit
import Testing

@testable import SurfaceKit

private let accessoryFont = FontSpec(name: "Menlo", size: 13)

@MainActor
private func accessoryFlush(
    _ store: GridStore, _ events: [UIEvent]
) -> FlushResult {
    let result = store.apply(RedrawBatch(events: events + [.flush]))
    precondition(result != nil)
    return result!
}

@MainActor
private struct AccessoryHarness {
    let view: GridSurfaceView
    let store: GridStore
    let outerCols: Int
    let outerRows: Int
    let windowHandle: Int

    init(outerCols: Int = 100, outerRows: Int = 20, windowHandle: Int = 20) {
        view = GridSurfaceView(frame: .zero, font: accessoryFont)
        store = GridStore()
        self.outerCols = outerCols
        self.outerRows = outerRows
        self.windowHandle = windowHandle
        view.frame = CGRect(
            x: 0, y: 0,
            width: CGFloat(outerCols) * view.cellSize.width,
            height: CGFloat(outerRows) * view.cellSize.height)
        view.setMinimapTopologies([MinimapBufferTopology(
            windowHandle: windowHandle, bufferHandle: 44,
            changedTick: 1, totalLineCount: 2_000,
            highlightGeneration: 1)])
    }

    func presentInitial() {
        view.present(accessoryFlush(store, [
            .gridResize(grid: 1, width: outerCols, height: outerRows),
            .gridResize(grid: 2, width: outerCols, height: outerRows),
            .winPos(
                grid: 2, win: windowHandle, startRow: 0, startCol: 0,
                width: outerCols, height: outerRows),
            .gridCursorGoto(grid: 2, row: 4, col: 2),
            .winViewport(
                grid: 2, win: windowHandle, topline: 100,
                botline: 100 + outerRows, curline: 104, curcol: 2,
                lineCount: 2_000, scrollDelta: 0),
        ]))
    }

    func acknowledge(_ request: GridAccessorySizeRequest) {
        view.present(accessoryFlush(store, [
            .gridResize(grid: 2, width: request.cols, height: request.rows),
        ]))
    }

    /// Drains the minimap catch-up spring (and any grid motion) so
    /// end-state assertions observe settled geometry.
    func settleAccessoryMotion() {
        for _ in 0..<600 where !view.animationsAreIdle {
            _ = view.advanceAnimations(
                by: 1.0 / 120.0, nominalDisplayPeriod: 1.0 / 120.0)
        }
    }
}

@MainActor
private final class AccessoryRoutingHost: NSView {
    let surface: GridSurfaceView

    init(surface: GridSurfaceView) {
        self.surface = surface
        super.init(frame: surface.frame)
        surface.frame = bounds
        addSubview(surface)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }

    /// Mirrors InputHostView's production routing — including the AppKit
    /// contract that `point` arrives in superview coordinates — without
    /// importing the executable target into SurfaceKitTests.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard super.hitTest(point) != nil else { return nil }
        let pointInSurface = surface.convert(point, from: superview)
        return surface.accessoryInteractionView(at: pointInSurface) ?? self
    }

    func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: convert(point, to: nil),
            modifierFlags: [], timestamp: 0,
            windowNumber: window?.windowNumber ?? 0,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }
}

private func dominantRedPixelCount(_ image: CGImage) -> Int {
    let bytes = image.dataProvider!.data! as Data
    var count = 0
    for y in 0..<image.height {
        for x in 0..<image.width {
            let index = y * image.bytesPerRow + x * 4
            let blue = Int(bytes[index])
            let green = Int(bytes[index + 1])
            let red = Int(bytes[index + 2])
            if red > 70, red > green + 25, red > blue + 25 {
                count += 1
            }
        }
    }
    return count
}

@Suite struct GridAccessoryPolicyTests {
    @Test func minimapThresholdUsesHysteresis() {
        let cellWidth: CGFloat = 8
        #expect(!GridAccessoryPolicy.wantsMinimap(
            outerWidth: 88 + 40 * cellWidth - 0.5,
            cellWidth: cellWidth, innerRows: 14, wasWanted: false))
        #expect(GridAccessoryPolicy.wantsMinimap(
            outerWidth: 88 + 40 * cellWidth,
            cellWidth: cellWidth, innerRows: 14, wasWanted: false))
        #expect(GridAccessoryPolicy.wantsMinimap(
            outerWidth: 88 + 36 * cellWidth,
            cellWidth: cellWidth, innerRows: 10, wasWanted: true))
        #expect(!GridAccessoryPolicy.wantsMinimap(
            outerWidth: 88 + 36 * cellWidth - 0.5,
            cellWidth: cellWidth, innerRows: 10, wasWanted: true))
        #expect(!GridAccessoryPolicy.wantsMinimap(
            outerWidth: 88 + 40 * cellWidth,
            cellWidth: cellWidth, innerRows: 9, wasWanted: true))
    }

    @Test func requestedRangeIsSlidingAndBounded() {
        let display = GridAccessoryPolicy.displayRange(
            totalLines: 100_000, viewportTopline: 50_000,
            visibleLineCount: 40, railHeight: 600, scale: 2)
        let request = GridAccessoryPolicy.requestedRange(
            totalLines: 100_000, displayRange: display)
        #expect(request.count <= GridAccessoryPolicy.maximumChunkLines)
        #expect(request.lowerBound <= display.lowerBound)
        #expect(request.upperBound >= display.upperBound)
        #expect(request.lowerBound > 0)
        #expect(request.upperBound < 100_000)
    }

    @Test func proportionalWindowSweepsTheRailWithTheViewport() {
        #expect(GridAccessoryPolicy.windowOrigin(
            totalLines: 10_000, capacity: 200,
            visualTopline: 0, visibleLineCount: 40) == 0)
        #expect(GridAccessoryPolicy.windowOrigin(
            totalLines: 10_000, capacity: 200,
            visualTopline: 9_960, visibleLineCount: 40) == 9_800)
        let middle = GridAccessoryPolicy.windowOrigin(
            totalLines: 10_000, capacity: 200,
            visualTopline: 4_980, visibleLineCount: 40)
        #expect(abs(middle - 4_900) < 0.001)
        #expect(GridAccessoryPolicy.windowOrigin(
            totalLines: 150, capacity: 200,
            visualTopline: 100, visibleLineCount: 40) == 0,
            "a document that fits the rail never slides")
    }

    @Test func proportionalTargetingSpansTheWholeDocument() {
        // Rail: 200-line capacity at pitch 3; a 1,000-line document with 40
        // visible lines. The 160-line indicator track maps onto the 960
        // possible topline positions.
        #expect(GridAccessoryPolicy.targetTopline(
            railY: 0, pitch: 3, grabOffsetLines: 0,
            totalLines: 1_000, visibleLineCount: 40, capacity: 200) == 0)
        #expect(GridAccessoryPolicy.targetTopline(
            railY: 480, pitch: 3, grabOffsetLines: 0,
            totalLines: 1_000, visibleLineCount: 40, capacity: 200) == 960,
            "the rail end maps to the document end")
        #expect(GridAccessoryPolicy.targetTopline(
            railY: 240, pitch: 3, grabOffsetLines: 0,
            totalLines: 1_000, visibleLineCount: 40, capacity: 200) == 480)
        #expect(GridAccessoryPolicy.targetTopline(
            railY: 240, pitch: 3, grabOffsetLines: 20,
            totalLines: 1_000, visibleLineCount: 40, capacity: 200) == 360,
            "the grab offset shifts the map by lines inside the indicator")
        #expect(GridAccessoryPolicy.targetTopline(
            railY: 300, pitch: 3, grabOffsetLines: 0,
            totalLines: 150, visibleLineCount: 40, capacity: 200) == 100,
            "a document that fits the rail keeps the identity map")
    }

    @Test func authoritativeScrollerUpdatesDoNotFightActiveTracking() {
        #expect(GridAccessoryPolicy.scrollerPresentationValue(
            authoritative: 0.75, current: 0.25,
            isUserTracking: true) == 0.25)
        #expect(GridAccessoryPolicy.scrollerPresentationValue(
            authoritative: 0.75, current: 0.25,
            isUserTracking: false) == 0.75)
    }
}

@MainActor
@Suite struct GridAccessoryLifecycleTests {
    @Test func topologyPublishedAfterInitialFlushRequestsSizeImmediately() {
        let harness = AccessoryHarness()
        harness.view.removeMinimapTopology(windowHandle: harness.windowHandle)
        var requests: [GridAccessorySizeRequest] = []
        harness.view.onGridAccessorySizeRequest = { requests.append($0) }
        harness.presentInitial()
        #expect(requests.isEmpty)
        #expect(harness.view.editorAccessoryDebugSnapshot(
            gridID: 2)?.gutterFrame == nil)

        harness.view.updateMinimapTopology(MinimapBufferTopology(
            windowHandle: harness.windowHandle, bufferHandle: 44,
            changedTick: 2, totalLineCount: 2_000,
            highlightGeneration: 2))
        #expect(requests.count == 1,
                "publishing topology must re-evaluate the last flush")
        #expect(requests[0].releasesOwnership == false)
        #expect(harness.view.editorAccessoryDebugSnapshot(
            gridID: 2)?.gutterFrame == nil,
            "the gutter still waits for grid_resize acknowledgement")
    }

    @Test func publicGeometryConfigurationDrivesTheResizeContract() {
        let harness = AccessoryHarness()
        #expect(harness.view.minimapWidth == 88)
        #expect(harness.view.minimapScale == 0.20)
        #expect(harness.view.minimapPitch == 3.0)
        #expect(harness.view.minimapMinEditorColumns == 40)
        harness.view.minimapWidth = 104
        harness.view.minimapScale = 0.25
        harness.view.minimapPitch = 2.5
        harness.view.minimapMinEditorColumns = 44
        var request: GridAccessorySizeRequest?
        harness.view.onGridAccessorySizeRequest = { request = $0 }
        harness.presentInitial()
        let expected = GridAccessoryPolicy.targetGridSize(
            outerCols: harness.outerCols, outerRows: harness.outerRows,
            cellWidth: harness.view.cellSize.width, gutterWidth: 104)
        #expect(request?.cols == expected.cols)
        #expect(request?.rows == expected.rows)
    }

    @Test func gutterWaitsForResizeAcknowledgementAndNeverBecomesAGridCell() {
        let harness = AccessoryHarness()
        var requests: [GridAccessorySizeRequest] = []
        harness.view.onGridAccessorySizeRequest = { requests.append($0) }
        harness.presentInitial()

        let request = requests.last!
        #expect(!request.releasesOwnership)
        guard let requesting = harness.view.editorAccessoryDebugSnapshot(gridID: 2)
        else {
            Issue.record("missing accessory state")
            return
        }
        #expect(requesting.ownership == .requesting(
            cols: request.cols, rows: request.rows))
        #expect(requesting.gutterFrame == nil)
        #expect(harness.view.accessoryInteractionView(at: NSPoint(
            x: CGFloat(request.cols) * harness.view.cellSize.width + 1,
            y: harness.view.cellSize.height)) == nil)

        harness.acknowledge(request)
        guard let owned = harness.view.editorAccessoryDebugSnapshot(gridID: 2),
            let interaction = owned.interactionFrame
        else {
            Issue.record("acknowledged gutter missing")
            return
        }
        #expect(owned.ownership == .owned(cols: request.cols, rows: request.rows))
        #expect(owned.minimapLayerSuperviewIsGridLayer)
        let gutterPoint = NSPoint(x: interaction.minX + 1, y: interaction.midY)
        #expect(harness.view.accessoryInteractionView(at: gutterPoint) != nil)
        #expect(harness.view.cell(at: gutterPoint) == nil)
    }

    @Test func hostHitRoutingDeliversClicksAndClampedOutsideDrags() {
        let harness = AccessoryHarness()
        var sizeRequest: GridAccessorySizeRequest?
        harness.view.onGridAccessorySizeRequest = { sizeRequest = $0 }
        harness.presentInitial()
        harness.acknowledge(sizeRequest!)

        // Embed the host at a sidebar-like x offset inside a container, the
        // production split-view arrangement: hit-test points then arrive in
        // superview coordinates that differ from host-local ones, which is
        // exactly what broke live minimap routing.
        let host = AccessoryRoutingHost(surface: harness.view)
        let container = NSView(frame: NSRect(
            x: 0, y: 0,
            width: host.frame.width + 220, height: host.frame.height))
        host.setFrameOrigin(NSPoint(x: 220, y: 0))
        container.addSubview(host)
        let window = NSWindow(
            contentRect: container.frame, styleMask: .borderless,
            backing: .buffered, defer: false)
        window.contentView = container
        guard let snapshot = harness.view.editorAccessoryDebugSnapshot(gridID: 2),
            let interaction = snapshot.interactionFrame,
            let viewport = snapshot.viewportFrame,
            let display = snapshot.displayRange
        else {
            Issue.record("acknowledged interaction geometry missing")
            return
        }

        var targets: [GridAccessoryViewportTargetRequest] = []
        harness.view.onGridAccessoryViewportTargetRequest = { targets.append($0) }
        let clickInSurface = NSPoint(
            x: interaction.minX + 8,
            y: interaction.minY + interaction.height * 0.8)
        let clickInHost = host.convert(clickInSurface, from: harness.view)
        guard let routed = host.hitTest(
            container.convert(clickInHost, from: host)), routed !== host
        else {
            Issue.record("InputHost-style hit routing missed the minimap")
            return
        }
        routed.mouseDown(with: host.mouseEvent(.leftMouseDown, at: clickInHost))
        routed.mouseUp(with: host.mouseEvent(.leftMouseUp, at: clickInHost))

        let pitch = GridAccessoryPolicy.linePitch(
            scale: 2, minimapScale: harness.view.minimapScale,
            minimapPitch: harness.view.minimapPitch)
        let capacity = GridAccessoryPolicy.railCapacity(
            railHeight: interaction.height, scale: 2,
            minimapScale: harness.view.minimapScale,
            minimapPitch: harness.view.minimapPitch)
        let expectedClick = GridAccessoryPolicy.targetTopline(
            railY: interaction.height * 0.8, pitch: pitch,
            grabOffsetLines: CGFloat(sizeRequest!.rows) / 2,
            totalLines: 2_000, visibleLineCount: sizeRequest!.rows,
            capacity: capacity)
        _ = display
        #expect(targets.first?.phase == .began)
        #expect(targets.first?.targetTopline == expectedClick)
        #expect(targets.last?.phase == .ended)

        targets.removeAll()
        let grabInSurface = NSPoint(
            x: interaction.minX + 8,
            y: interaction.minY + viewport.midY)
        let grabInHost = host.convert(grabInSurface, from: harness.view)
        guard let dragTarget = host.hitTest(
            container.convert(grabInHost, from: host)), dragTarget !== host
        else {
            Issue.record("viewport marker drag was not routed to minimap")
            return
        }
        dragTarget.mouseDown(with: host.mouseEvent(.leftMouseDown, at: grabInHost))
        let belowGutter = NSPoint(
            x: grabInHost.x, y: host.convert(
                NSPoint(x: interaction.minX + 8, y: interaction.maxY + 100),
                from: harness.view).y)
        dragTarget.mouseDragged(with: host.mouseEvent(
            .leftMouseDragged, at: belowGutter))
        dragTarget.mouseUp(with: host.mouseEvent(.leftMouseUp, at: belowGutter))

        #expect(targets.map(\.phase) == [.began, .changed, .ended])
        #expect(targets.first?.targetTopline == 100,
            "grabbing the viewport indicator must not jump the view")
        #expect(targets.dropFirst().first?.targetTopline
            == 2_000 - sizeRequest!.rows,
            "a drag clamped past the rail end must reach the document end")
        _ = window
    }

    @Test func topmostFloatBlocksTheUnderlyingGutterInteraction() {
        let harness = AccessoryHarness()
        var request: GridAccessorySizeRequest?
        harness.view.onGridAccessorySizeRequest = { request = $0 }
        harness.presentInitial()
        harness.acknowledge(request!)
        guard let interaction = harness.view.editorAccessoryDebugSnapshot(
            gridID: 2)?.interactionFrame
        else {
            Issue.record("gutter missing")
            return
        }
        let anchorCol = Double(Int(interaction.minX / harness.view.cellSize.width))
        harness.view.present(accessoryFlush(harness.store, [
            .gridResize(grid: 3, width: 8, height: 5),
            .winFloatPos(
                grid: 3, win: 30, anchor: "NW", anchorGrid: 1,
                anchorRow: 2, anchorCol: anchorCol,
                focusable: true, zIndex: 50),
        ]))
        guard let floatFrame = harness.view.rect(ofGrid: 3) else {
            Issue.record("float frame missing")
            return
        }
        let overlap = interaction.intersection(floatFrame)
        #expect(!overlap.isNull && !overlap.isEmpty)
        let coveredPoint = NSPoint(x: overlap.midX, y: overlap.midY)
        #expect(harness.view.accessoryInteractionView(at: coveredPoint) == nil,
                "a topmost float must own hits over the split gutter")

        harness.view.present(accessoryFlush(harness.store, [.winHide(grid: 3)]))
        #expect(harness.view.accessoryInteractionView(at: coveredPoint) != nil)
    }

    @Test func splitOwnershipAndAcknowledgementRemainIndependent() {
        let view = GridSurfaceView(frame: .zero, font: accessoryFont)
        let store = GridStore()
        let outerCols = 100
        let splitRows = 20
        view.frame = CGRect(
            x: 0, y: 0, width: CGFloat(outerCols) * view.cellSize.width,
            height: CGFloat(splitRows * 2) * view.cellSize.height)
        view.setMinimapTopologies([
            MinimapBufferTopology(
                windowHandle: 20, bufferHandle: 44, changedTick: 1,
                totalLineCount: 2_000, highlightGeneration: 1),
            MinimapBufferTopology(
                windowHandle: 30, bufferHandle: 55, changedTick: 1,
                totalLineCount: 3_000, highlightGeneration: 1),
        ])
        var requests: [GridAccessorySizeRequest] = []
        view.onGridAccessorySizeRequest = { requests.append($0) }
        view.present(accessoryFlush(store, [
            .gridResize(grid: 1, width: outerCols, height: splitRows * 2),
            .gridResize(grid: 2, width: outerCols, height: splitRows),
            .winPos(
                grid: 2, win: 20, startRow: 0, startCol: 0,
                width: outerCols, height: splitRows),
            .winViewport(
                grid: 2, win: 20, topline: 0, botline: splitRows,
                curline: 0, curcol: 0, lineCount: 2_000, scrollDelta: 0),
            .gridResize(grid: 3, width: outerCols, height: splitRows),
            .winPos(
                grid: 3, win: 30, startRow: splitRows, startCol: 0,
                width: outerCols, height: splitRows),
            .winViewport(
                grid: 3, win: 30, topline: 100, botline: 100 + splitRows,
                curline: 100, curcol: 0, lineCount: 3_000, scrollDelta: 0),
        ]))
        let request2 = requests.first(where: { $0.gridID == 2 })!
        let request3 = requests.first(where: { $0.gridID == 3 })!
        view.present(accessoryFlush(store, [
            .gridResize(grid: 2, width: request2.cols, height: request2.rows),
        ]))
        #expect(view.editorAccessoryDebugSnapshot(gridID: 2)?.ownership
            == .owned(cols: request2.cols, rows: request2.rows))
        #expect(view.editorAccessoryDebugSnapshot(gridID: 3)?.ownership
            == .requesting(cols: request3.cols, rows: request3.rows))
        #expect(view.editorAccessoryDebugSnapshot(gridID: 2)?.gutterFrame != nil)
        #expect(view.editorAccessoryDebugSnapshot(gridID: 3)?.gutterFrame == nil)

        view.present(accessoryFlush(store, [
            .gridResize(grid: 3, width: request3.cols, height: request3.rows),
        ]))
        #expect(view.editorAccessoryDebugSnapshot(gridID: 2)?.gutterFrame != nil)
        #expect(view.editorAccessoryDebugSnapshot(gridID: 3)?.gutterFrame != nil)

        requests.removeAll()
        view.showsMinimap = false
        #expect(Set(requests.filter(\.releasesOwnership).map(\.gridID))
            == Set([2, 3]))
    }

    @Test func toplineZeroMarkerUsesTheVisualTopOfTheGutter() {
        let harness = AccessoryHarness()
        var request: GridAccessorySizeRequest?
        harness.view.onGridAccessorySizeRequest = { request = $0 }
        harness.presentInitial()
        harness.acknowledge(request!)
        harness.view.present(accessoryFlush(harness.store, [
            .winViewport(
                grid: 2, win: harness.windowHandle, topline: 0,
                botline: request!.rows, curline: 0, curcol: 0,
                lineCount: 2_000, scrollDelta: 0),
        ]))
        harness.settleAccessoryMotion()

        guard let snapshot = harness.view.editorAccessoryDebugSnapshot(gridID: 2)
        else {
            Issue.record("minimap debug geometry missing")
            return
        }
        #expect(snapshot.minimapUsesTopOrigin,
                "minimap children must use a top-origin local coordinate system")
        #expect(snapshot.displayRange?.lowerBound == 0)
        #expect(snapshot.viewportFrame?.minY == 0,
                "topline zero must draw at the visual top, not gutter bottom")
        #expect(snapshot.cursorFrame?.minY == 0)
    }

    @Test func disablingMinimapReleasesOwnershipAndHidesImmediately() {
        let harness = AccessoryHarness()
        var requests: [GridAccessorySizeRequest] = []
        harness.view.onGridAccessorySizeRequest = { requests.append($0) }
        harness.presentInitial()
        harness.acknowledge(requests.last!)

        harness.view.showsMinimap = false
        #expect(requests.last?.releasesOwnership == true)
        let snapshot = harness.view.editorAccessoryDebugSnapshot(gridID: 2)
        #expect(snapshot?.ownership == .releasing)
        #expect(snapshot?.gutterFrame == nil)
        #expect(snapshot?.interactionFrame == nil)
    }

    @Test func removingTopologyReleasesAnOwnedGutterImmediately() {
        let harness = AccessoryHarness()
        var requests: [GridAccessorySizeRequest] = []
        harness.view.onGridAccessorySizeRequest = { requests.append($0) }
        harness.presentInitial()
        harness.acknowledge(requests.last!)

        harness.view.removeMinimapTopology(windowHandle: harness.windowHandle)
        #expect(requests.last?.releasesOwnership == true)
        let snapshot = harness.view.editorAccessoryDebugSnapshot(gridID: 2)
        #expect(snapshot?.ownership == .releasing)
        #expect(snapshot?.gutterFrame == nil)
        #expect(snapshot?.interactionFrame == nil)
    }

    @Test func nativeScrollerDefaultsOffAndUsesTrailingTwelvePoints() {
        let harness = AccessoryHarness()
        var request: GridAccessorySizeRequest?
        harness.view.onGridAccessorySizeRequest = { request = $0 }
        harness.presentInitial()
        harness.acknowledge(request!)
        #expect(harness.view.showsNativeScrollbars == false)
        #expect(harness.view.editorAccessoryDebugSnapshot(
            gridID: 2)?.scrollerIsVisible == false)

        harness.view.showsNativeScrollbars = true
        guard let snapshot = harness.view.editorAccessoryDebugSnapshot(gridID: 2),
            let interaction = snapshot.interactionFrame,
            let scroller = harness.view.editorAccessoryScroller(gridID: 2)
        else {
            Issue.record("native scroller missing")
            return
        }
        #expect(snapshot.scrollerIsVisible)
        #expect(abs(scroller.frame.width - 12) < 0.001)
        #expect(abs(scroller.frame.maxX - interaction.width) < 0.001)

        // A standalone overlay scroller never draws its knob (NSScrollView's
        // fade machinery is what shows overlay knobs); the bar must be
        // persistently visible and draggable.
        #expect(scroller.scrollerStyle == .legacy)
        #expect(scroller.isEnabled)
        #expect(scroller.knobProportion > 0)
        let knob = scroller.rect(for: .knob)
        #expect(!knob.isEmpty, "the scroller must lay out a draggable knob")
        guard let rep = scroller.bitmapImageRepForCachingDisplay(
            in: scroller.bounds)
        else {
            Issue.record("scroller rasterization unavailable")
            return
        }
        scroller.cacheDisplay(in: scroller.bounds, to: rep)
        var inkedPixels = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide
            where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                inkedPixels += 1
            }
        }
        #expect(inkedPixels > 0, "the scroll bar must actually draw")
    }

    @Test func nativeScrollerAutoHidesWhenTheViewportCoversTheBuffer() {
        let harness = AccessoryHarness()
        harness.view.showsNativeScrollbars = true
        var request: GridAccessorySizeRequest?
        harness.view.onGridAccessorySizeRequest = { request = $0 }
        harness.presentInitial()
        harness.acknowledge(request!)
        harness.view.present(accessoryFlush(harness.store, [
            .winViewport(
                grid: 2, win: harness.windowHandle, topline: 0,
                botline: request!.rows, curline: 0, curcol: 0,
                lineCount: request!.rows, scrollDelta: 0),
        ]))
        #expect(harness.view.editorAccessoryDebugSnapshot(
            gridID: 2)?.scrollerIsVisible == false)

        harness.view.present(accessoryFlush(harness.store, [
            .winViewport(
                grid: 2, win: harness.windowHandle, topline: 0,
                botline: request!.rows, curline: 0, curcol: 0,
                lineCount: request!.rows + 1, scrollDelta: 0),
        ]))
        #expect(harness.view.editorAccessoryDebugSnapshot(
            gridID: 2)?.scrollerIsVisible == true)
    }

    @Test func contentChunksAccumulateUntilVisibleCoverageOrCompletion() {
        let harness = AccessoryHarness()
        var sizeRequest: GridAccessorySizeRequest?
        var contentRequest: MinimapContentRangeRequest?
        harness.view.onGridAccessorySizeRequest = { sizeRequest = $0 }
        harness.view.onMinimapContentRangeRequest = { contentRequest = $0 }
        harness.view.setMinimapTopologies([MinimapBufferTopology(
            windowHandle: harness.windowHandle, bufferHandle: 44,
            changedTick: 8, totalLineCount: 2_000,
            highlightGeneration: 3, tabstop: 4,
            bufferLabel: "sample.swift", filetype: "swift")])
        harness.presentInitial()
        harness.acknowledge(sizeRequest!)

        guard let request = contentRequest,
            let display = harness.view.editorAccessoryDebugSnapshot(
                gridID: 2)?.displayRange
        else {
            Issue.record("minimap request missing")
            return
        }
        #expect(request.maxColumns == 160)
        let middle = display.lowerBound + display.count / 2
        let firstLines = (display.lowerBound..<middle).map {
            MinimapLine(text: "line \($0)")
        }
        harness.view.provideMinimapContent(MinimapContentChunk(
            requestID: request.requestID, gridID: 2,
            topology: request.topology, firstLine: display.lowerBound,
            lastLine: middle, complete: false, lines: firstLines))
        var snapshot = harness.view.editorAccessoryDebugSnapshot(gridID: 2)!
        #expect(snapshot.acceptedRange == nil)
        #expect(snapshot.pendingRange == request.lineRange)
        #expect(snapshot.accumulatedLineCount == firstLines.count)

        let secondLines = (middle..<display.upperBound).map {
            MinimapLine(text: "line \($0)")
        }
        harness.view.provideMinimapContent(MinimapContentChunk(
            requestID: request.requestID, gridID: 2,
            topology: request.topology, firstLine: middle,
            lastLine: display.upperBound, complete: false, lines: secondLines))
        snapshot = harness.view.editorAccessoryDebugSnapshot(gridID: 2)!
        #expect(snapshot.acceptedRange == display)
        #expect(snapshot.pendingRange == request.lineRange,
                "coverage may publish, but only complete terminates the request")

        let tailStart = display.upperBound
        let tailEnd = min(request.lineRange.upperBound, tailStart + 16)
        let tailLines = (tailStart..<tailEnd).map {
            MinimapLine(text: "tail \($0)")
        }
        harness.view.provideMinimapContent(MinimapContentChunk(
            requestID: request.requestID, gridID: 2,
            topology: request.topology, firstLine: tailStart,
            lastLine: tailEnd, complete: false, lines: tailLines))
        snapshot = harness.view.editorAccessoryDebugSnapshot(gridID: 2)!
        #expect(snapshot.acceptedRange == display,
                "tail chunks must not republish and restart CoreText work")
        #expect(snapshot.accumulatedLineCount
            == firstLines.count + secondLines.count + tailLines.count)

        harness.view.provideMinimapContent(MinimapContentChunk(
            requestID: request.requestID, gridID: 2,
            topology: request.topology, firstLine: request.lineRange.upperBound,
            lastLine: request.lineRange.upperBound, complete: true, lines: []))
        snapshot = harness.view.editorAccessoryDebugSnapshot(gridID: 2)!
        #expect(snapshot.pendingRange == nil)
        #expect(snapshot.acceptedRange == request.lineRange,
                "the final chunk publishes the complete prefetched window once")
    }

    @Test func fullChunkInstallsAndPresentsColoredMiniaturePixels() async throws {
        let harness = AccessoryHarness()
        var sizeRequest: GridAccessorySizeRequest?
        var contentRequest: MinimapContentRangeRequest?
        harness.view.onGridAccessorySizeRequest = { sizeRequest = $0 }
        harness.view.onMinimapContentRangeRequest = { contentRequest = $0 }
        harness.presentInitial()
        harness.acknowledge(sizeRequest!)

        guard let request = contentRequest else {
            Issue.record("content request missing")
            return
        }
        let lines = request.lineRange.map { line in
            MinimapLine(
                text: "let value\(line) = \(line)",
                spans: [MinimapHighlightSpan(
                    byteRange: 0..<3, foregroundRGB: 0xFF2020)])
        }
        harness.view.provideMinimapContent(MinimapContentChunk(
            requestID: request.requestID, gridID: 2,
            topology: request.topology,
            firstLine: request.lineRange.lowerBound,
            lastLine: request.lineRange.upperBound,
            complete: true, lines: lines))

        let startedGeneration = harness.view.editorAccessoryDebugSnapshot(
            gridID: 2)!.renderGeneration
        for _ in 0..<12 {
            // Ordinary redraw/config refreshes with identical raster inputs
            // must retain the in-flight CoreText job instead of starving it.
            harness.view.updateMinimapTopology(request.topology)
        }
        #expect(harness.view.editorAccessoryDebugSnapshot(
            gridID: 2)?.renderGeneration == startedGeneration)

        var snapshot = harness.view.editorAccessoryDebugSnapshot(gridID: 2)!
        for _ in 0..<200 where snapshot.minimapImage == nil {
            try await Task.sleep(for: .milliseconds(5))
            snapshot = harness.view.editorAccessoryDebugSnapshot(gridID: 2)!
        }

        guard let rendered = snapshot.minimapImage else {
            Issue.record("detached minimap render never installed")
            return
        }
        #expect(!snapshot.renderIsInFlight)
        #expect(snapshot.contentLayerHasContents)
        #expect(dominantRedPixelCount(rendered) > 0,
                "authoritative minimap bitmap must contain syntax-colored glyphs")
        if let gutter = snapshot.gutterFrame, let content = snapshot.contentFrame {
            let localGutter = CGRect(origin: .zero, size: gutter.size)
            #expect(content.intersects(localGutter),
                    "installed content must intersect the clipped gutter")
        } else {
            Issue.record("presented minimap geometry missing")
        }

        guard let presented = harness.view.editorAccessoryPresentedImage(gridID: 2)
        else {
            Issue.record("minimap layer-tree capture failed")
            return
        }
        #expect(dominantRedPixelCount(presented) > 0,
                "the visible gutter crop must present colored glyph pixels")
    }

    @Test func minimapWindowTracksAuthoritativeStepsContinuously() {
        let harness = AccessoryHarness()
        var request: GridAccessorySizeRequest?
        harness.view.onGridAccessorySizeRequest = { request = $0 }
        harness.presentInitial()
        harness.acknowledge(request!)
        let before = harness.view.editorAccessoryDebugSnapshot(gridID: 2)!

        harness.view.present(accessoryFlush(harness.store, [
            .gridScroll(
                grid: 2, top: 0, bottom: request!.rows,
                left: 0, right: request!.cols, rows: 1, cols: 0),
            .winViewport(
                grid: 2, win: harness.windowHandle, topline: 101,
                botline: 101 + request!.rows, curline: 105, curcol: 2,
                lineCount: 2_000, scrollDelta: 1),
        ]))
        let retargeted = harness.view.editorAccessoryDebugSnapshot(gridID: 2)!
        #expect(abs((before.viewportFrame?.minY ?? 0)
            - (retargeted.viewportFrame?.minY ?? 0)) <= 0.5,
            "an authoritative row advance must be visually continuous")
        let beforeOrigin = CGFloat(before.displayRange?.lowerBound ?? 0)
            + before.displayRangeResidual
        let retargetedOrigin = CGFloat(retargeted.displayRange?.lowerBound ?? 0)
            + retargeted.displayRangeResidual
        #expect(abs(retargetedOrigin - beforeOrigin) < 0.01,
            "the rail window must be stationary at insertion, like the grid")

        _ = harness.view.advanceAnimations(
            by: 0.08, nominalDisplayPeriod: 1.0 / 60.0)
        let advanced = harness.view.editorAccessoryDebugSnapshot(gridID: 2)!
        let advancedOrigin = CGFloat(advanced.displayRange?.lowerBound ?? 0)
            + advanced.displayRangeResidual
        #expect(advancedOrigin > retargetedOrigin,
            "catch-up decay slides the window toward the authoritative position")
    }

    @Test func farJumpsSweepContinuouslyAndTeleportsCut() {
        let harness = AccessoryHarness()
        var request: GridAccessorySizeRequest?
        harness.view.onGridAccessorySizeRequest = { request = $0 }
        harness.presentInitial()
        harness.acknowledge(request!)
        let rows = request!.rows
        guard let interaction = harness.view.editorAccessoryDebugSnapshot(
            gridID: 2)?.interactionFrame
        else {
            Issue.record("interaction geometry missing")
            return
        }
        let capacity = GridAccessoryPolicy.railCapacity(
            railHeight: interaction.height, scale: 2,
            minimapScale: harness.view.minimapScale,
            minimapPitch: harness.view.minimapPitch)

        func origin() -> CGFloat {
            let snapshot = harness.view.editorAccessoryDebugSnapshot(gridID: 2)!
            return CGFloat(snapshot.displayRange?.lowerBound ?? 0)
                + snapshot.displayRangeResidual
        }

        // A ctrl-f-sized jump stays within the tracked catch-up limit: the
        // window is continuous at the flush and sweeps monotonically after.
        let before = origin()
        harness.view.present(accessoryFlush(harness.store, [
            .winViewport(
                grid: 2, win: harness.windowHandle, topline: 250,
                botline: 250 + rows, curline: 250, curcol: 0,
                lineCount: 2_000, scrollDelta: 0),
        ]))
        #expect(abs(origin() - before) < 0.01,
            "a tracked far jump must not teleport the window")

        var previous = origin()
        for _ in 0..<600 where !harness.view.animationsAreIdle {
            _ = harness.view.advanceAnimations(
                by: 1.0 / 120.0, nominalDisplayPeriod: 1.0 / 120.0)
            let current = origin()
            #expect(current >= previous - 0.001,
                "the catch-up sweep must be monotonic — no ease-out strobing")
            previous = current
        }
        let target = GridAccessoryPolicy.windowOrigin(
            totalLines: 2_000, capacity: capacity,
            visualTopline: 250, visibleLineCount: rows)
        #expect(abs(previous - target) < 0.1,
            "the sweep must land exactly on the authoritative position")

        // A teleport beyond the tracked limit cuts immediately.
        harness.view.present(accessoryFlush(harness.store, [
            .winViewport(
                grid: 2, win: harness.windowHandle, topline: 1_800,
                botline: 1_800 + rows, curline: 1_800, curcol: 0,
                lineCount: 2_000, scrollDelta: 0),
        ]))
        let cutTarget = GridAccessoryPolicy.windowOrigin(
            totalLines: 2_000, capacity: capacity,
            visualTopline: 1_800, visibleLineCount: rows)
        #expect(abs(origin() - cutTarget) < 0.01,
            "a teleport beyond the catch-up limit must jump-cut")
    }

    @Test func proportionalWindowMapsRailEndsToDocumentEnds() {
        let harness = AccessoryHarness()
        var sizeRequest: GridAccessorySizeRequest?
        harness.view.onGridAccessorySizeRequest = { sizeRequest = $0 }
        harness.presentInitial()
        harness.acknowledge(sizeRequest!)
        guard let interaction = harness.view.editorAccessoryDebugSnapshot(
            gridID: 2)?.interactionFrame
        else {
            Issue.record("acknowledged interaction geometry missing")
            return
        }
        let rows = sizeRequest!.rows
        let pitch = GridAccessoryPolicy.linePitch(
            scale: 2, minimapScale: harness.view.minimapScale,
            minimapPitch: harness.view.minimapPitch)
        let capacity = GridAccessoryPolicy.railCapacity(
            railHeight: interaction.height, scale: 2,
            minimapScale: harness.view.minimapScale,
            minimapPitch: harness.view.minimapPitch)

        harness.view.present(accessoryFlush(harness.store, [
            .winViewport(
                grid: 2, win: harness.windowHandle, topline: 0,
                botline: rows, curline: 0, curcol: 0,
                lineCount: 2_000, scrollDelta: 0),
        ]))
        harness.settleAccessoryMotion()
        let top = harness.view.editorAccessoryDebugSnapshot(gridID: 2)!
        #expect(top.displayRange?.lowerBound == 0)
        #expect(top.viewportFrame?.minY == 0,
            "the document start pins the indicator to the rail top")

        harness.view.present(accessoryFlush(harness.store, [
            .winViewport(
                grid: 2, win: harness.windowHandle, topline: 990,
                botline: 990 + rows, curline: 995, curcol: 0,
                lineCount: 2_000, scrollDelta: 0),
        ]))
        harness.settleAccessoryMotion()
        let middle = harness.view.editorAccessoryDebugSnapshot(gridID: 2)!
        let expectedOrigin = Int(
            (CGFloat(990) / CGFloat(2_000 - rows)
                * CGFloat(2_000 - capacity)).rounded(.down))
        #expect(middle.displayRange?.lowerBound == expectedOrigin,
            "the window position is proportional to the document position")

        harness.view.present(accessoryFlush(harness.store, [
            .winViewport(
                grid: 2, win: harness.windowHandle, topline: 2_000 - rows,
                botline: 2_000, curline: 1_999, curcol: 0,
                lineCount: 2_000, scrollDelta: 0),
        ]))
        harness.settleAccessoryMotion()
        let end = harness.view.editorAccessoryDebugSnapshot(gridID: 2)!
        #expect(end.displayRange?.upperBound == 2_000)
        guard let indicator = end.viewportFrame else {
            Issue.record("end-of-document indicator missing")
            return
        }
        #expect(abs(indicator.maxY - CGFloat(capacity) * pitch) <= 0.5,
            "the document end pins the indicator to the rail's content end")
        #expect(indicator.maxY <= interaction.height + 0.5)
    }
}

@Suite struct MinimapRasterizerTests {
    @Test func coreTextMiniaturePreservesSyntaxForegrounds() {
        let text = "let answer = 42"
        let image = MinimapRasterizer.render(
            lines: [MinimapLine(text: text, spans: [
                MinimapHighlightSpan(byteRange: 0..<3, foregroundRGB: 0xFF3030),
                MinimapHighlightSpan(byteRange: 13..<15, foregroundRGB: 0x30FF30),
            ])], width: 88, scale: 2,
            backgroundRGB: 0x000000, defaultForegroundRGB: 0xE0E0E0)!
        let bytes = image.dataProvider!.data! as Data
        var sawRed = false
        var sawGreen = false
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let blue = bytes[index]
            let green = bytes[index + 1]
            let red = bytes[index + 2]
            sawRed = sawRed || (red > 80 && red > green * 2 && red > blue * 2)
            sawGreen = sawGreen || (green > 80 && green > red * 2 && green > blue * 2)
        }
        #expect(sawRed)
        #expect(sawGreen)
    }

    @Test func topologyTabstopControlsMiniatureIndentation() {
        func firstInkX(_ text: String) -> Int? {
            let image = MinimapRasterizer.render(
                lines: [MinimapLine(text: text)], width: 88, scale: 2,
                backgroundRGB: 0x000000, defaultForegroundRGB: 0xFFFFFF,
                minimapScale: 0.20, minimapPitch: 3, tabstop: 4,
                editorFontSize: 13)!
            let bytes = image.dataProvider!.data! as Data
            for x in 0..<image.width {
                for y in 0..<image.height {
                    let index = y * image.bytesPerRow + x * 4
                    if bytes[index] > 20 || bytes[index + 1] > 20
                        || bytes[index + 2] > 20
                    { return x }
                }
            }
            return nil
        }
        let plain = firstInkX("x")!
        let indented = firstInkX("\tx")!
        #expect(indented > plain + 4)
    }
}
